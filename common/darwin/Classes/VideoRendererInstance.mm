#import "VideoRendererInstance.h"
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

@implementation VideoRendererInstance {
  CVPixelBufferRef _lastPixelBuffer;
  CGSize _frameSize;
  RTCVideoRotation _rotation;
  os_unfair_lock _lock;
  bool _frameAvailable;
  bool _disposed;
  bool _shuttingDown;  // Atomic flag to stop render loop
  int64_t _windowId;
  int64_t _textureId;  // Local copy for atomic access
}

@synthesize registry = _registry;
@synthesize videoTrack = _videoTrack;
@synthesize windowId = _windowId;

- (int64_t)textureId {
  os_unfair_lock_lock(&_lock);
  int64_t tid = _textureId;
  os_unfair_lock_unlock(&_lock);
  return tid;
}

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry
                       videoTrack:(RTCVideoTrack*)track
                         windowId:(int64_t)windowId {
  self = [super init];
  if (self) {
    _registry = registry;
    _videoTrack = track;
    _windowId = windowId;
    _lock = OS_UNFAIR_LOCK_INIT;
    _frameSize = CGSizeZero;
    _rotation = RTCVideoRotation_0;
    _lastPixelBuffer = nil;
    _frameAvailable = false;
    _disposed = false;
    _shuttingDown = false;
    _textureId = -1;

    // Register Flutter texture
    int64_t textureId = [_registry registerTexture:self];
    if (textureId == -1) {
      return nil;
    }
    os_unfair_lock_lock(&_lock);
    _textureId = textureId;
    os_unfair_lock_unlock(&_lock);

    // Attach track → renderer
    if (_videoTrack) {
      [_videoTrack addRenderer:self];
    }
  }
  return self;
}

- (void)dealloc {
  [self dispose];
}

#pragma mark - FlutterTexture

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
  os_unfair_lock_lock(&_lock);
  if (_lastPixelBuffer != nil && _frameAvailable && !_disposed) {
    buffer = CVBufferRetain(_lastPixelBuffer);
    _frameAvailable = false;
  }
  os_unfair_lock_unlock(&_lock);
  return buffer;
}

#pragma mark - RTCVideoRenderer

- (void)renderFrame:(RTCVideoFrame*)frame {
  // CRITICAL: Check shuttingDown FIRST (atomic, no lock needed for read)
  // This prevents race condition where dispose sets flag but renderFrame still runs
  if (_shuttingDown) {
    return;
  }

  os_unfair_lock_lock(&_lock);

  // Double-check after acquiring lock
  if (_disposed || _shuttingDown || _textureId == -1 || !_videoTrack) {
    os_unfair_lock_unlock(&_lock);
    return;
  }

  // Update frame size if changed
  CGSize newSize = CGSizeMake(frame.width, frame.height);
  if (newSize.width != _frameSize.width || newSize.height != _frameSize.height) {
    if (_lastPixelBuffer) {
      CVBufferRelease(_lastPixelBuffer);
      _lastPixelBuffer = nil;
    }

    NSDictionary* pixelAttributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        newSize.width,
        newSize.height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)(pixelAttributes),
        &_lastPixelBuffer);

    if (status != kCVReturnSuccess) {
      os_unfair_lock_unlock(&_lock);
      return;
    }

    _frameSize = newSize;
  }

  // Convert frame to pixel buffer
  if (_lastPixelBuffer) {
    [self copyI420ToCVPixelBuffer:_lastPixelBuffer withFrame:frame];
    _frameAvailable = true;
  }

  // Capture textureId and registry while holding lock
  int64_t textureId = _textureId;
  id<FlutterTextureRegistry> registry = _registry;
  bool isShuttingDown = _shuttingDown;

  os_unfair_lock_unlock(&_lock);

  // CRITICAL: Only notify if NOT shutting down and textureId is valid
  // This prevents calling markTextureFrameAvailable after dispose
  if (textureId != -1 && !isShuttingDown && registry) {
    dispatch_async(dispatch_get_main_queue(), ^{
      // Final check on main queue (atomic read, no lock needed)
      if (!self->_shuttingDown && self->_textureId != -1 && self->_registry) {
        @try {
          [self->_registry textureFrameAvailable:textureId];
        } @catch (NSException* exception) {
          // Silently ignore - texture already disposed
        }
      }
    });
  }
}

- (void)setSize:(CGSize)size {
  // Size is handled in renderFrame:
}

#pragma mark - Helper Methods

- (id<RTCI420Buffer>)correctRotation:(const id<RTCI420Buffer>)src
                        withRotation:(RTCVideoRotation)rotation {
  int rotated_width = src.width;
  int rotated_height = src.height;

  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    int temp = rotated_width;
    rotated_width = rotated_height;
    rotated_height = temp;
  }

  id<RTCI420Buffer> buffer = [[RTCI420Buffer alloc] initWithWidth:rotated_width
                                                           height:rotated_height];

  [RTCYUVHelper I420Rotate:src.dataY
                srcStrideY:src.strideY
                      srcU:src.dataU
                srcStrideU:src.strideU
                      srcV:src.dataV
                srcStrideV:src.strideV
                      dstY:(uint8_t*)buffer.dataY
                dstStrideY:buffer.strideY
                      dstU:(uint8_t*)buffer.dataU
                dstStrideU:buffer.strideU
                      dstV:(uint8_t*)buffer.dataV
                dstStrideV:buffer.strideV
                     width:src.width
                    height:src.height
                      mode:rotation];

  return buffer;
}

- (void)copyI420ToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                      withFrame:(RTCVideoFrame*)frame {
  id<RTCI420Buffer> i420Buffer = [self correctRotation:[frame.buffer toI420]
                                          withRotation:frame.rotation];
  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer);
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    // NV12
    uint8_t* dstY = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t* dstUV = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
    const size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

    [RTCYUVHelper I420ToNV12:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                        dstY:dstY
                  dstStrideY:(int)dstYStride
                       dstUV:dstUV
                 dstStrideUV:(int)dstUVStride
                       width:i420Buffer.width
                      height:i420Buffer.height];

  } else {
    uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(outputPixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

    if (pixelFormat == kCVPixelFormatType_32BGRA) {
      [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstARGB:dst
                 dstStrideARGB:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
      [RTCYUVHelper I420ToBGRA:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstBGRA:dst
                 dstStrideBGRA:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    }
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
}

#pragma mark - Dispose

- (void)dispose {
  // Prevent multiple dispose calls
  os_unfair_lock_lock(&_lock);
  if (_disposed) {
    os_unfair_lock_unlock(&_lock);
    return;
  }

  // STEP 1: Set shuttingDown flag FIRST (atomic, prevents new renderFrame calls)
  _shuttingDown = true;
  int64_t textureId = _textureId;
  RTCVideoTrack* videoTrack = _videoTrack;
  id<FlutterTextureRegistry> registry = _registry;
  os_unfair_lock_unlock(&_lock);

  // STEP 2: STOP render loop (removeRenderer) - BLOCKING
  // This ensures WebRTC stops calling renderFrame BEFORE we unregister texture
  if (videoTrack) {
    [videoTrack removeRenderer:self];
    // Give WebRTC a moment to process the removal
    // This prevents race condition where renderFrame is already queued
    usleep(10000);  // 10ms - enough for WebRTC to stop queuing frames
  }

  // STEP 3: Zero textureId BEFORE unregister (prevents renderFrame from using it)
  os_unfair_lock_lock(&_lock);
  _textureId = -1;  // CRITICAL: Zero immediately
  _videoTrack = nil;
  os_unfair_lock_unlock(&_lock);

  // STEP 4: Unregister texture (now safe - no renderFrame can use it)
  if (textureId != -1 && registry) {
    @try {
      [registry unregisterTexture:textureId];
    } @catch (NSException* exception) {
      NSLog(@"VideoRendererInstance: Error unregistering texture: %@", exception.reason);
    }
  }

  // STEP 5: Release GPU resources
  os_unfair_lock_lock(&_lock);
  if (_lastPixelBuffer) {
    CVBufferRelease(_lastPixelBuffer);
    _lastPixelBuffer = nil;
  }
  _frameAvailable = false;
  _disposed = true;
  os_unfair_lock_unlock(&_lock);
}

@end
