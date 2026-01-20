#import "VideoRendererInstance.h"
#import "VideoRendererManager.h"
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
@synthesize manager = _manager;

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
  // This is the FIRST line of defense - drop frame immediately if shutting down
  if (_shuttingDown) {
    return;  // Producer may still feed frames, but we drop them here
  }

  os_unfair_lock_lock(&_lock);

  // Double-check after acquiring lock (second line of defense)
  // Check multiple conditions to ensure we're still valid
  if (_disposed || _shuttingDown || _textureId == -1 || !_videoTrack) {
    os_unfair_lock_unlock(&_lock);
    return;  // Drop frame - we're shutting down or already disposed
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
  VideoRendererManager* manager = _manager;

  os_unfair_lock_unlock(&_lock);

  // CRITICAL: Check if registry is still valid
  // If registry became nil, texture was likely unregistered by Flutter engine
  if (!registry && textureId != -1 && manager) {
    // Registry is nil but textureId is still valid - texture was unregistered externally
    // Dispose immediately to prevent further calls
    [manager handleTextureUnregistered:textureId];
    return;
  }

  // CRITICAL: Only notify if NOT shutting down and textureId is valid
  // This prevents calling markTextureFrameAvailable after dispose
  // Third line of defense - check again before dispatching to main queue
  if (textureId != -1 && !isShuttingDown && registry) {
    // Use weak self to avoid retain cycle and check if instance still exists
    __weak VideoRendererInstance* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      VideoRendererInstance* strongSelf = weakSelf;
      if (!strongSelf) {
        return;  // Instance was deallocated
      }

      // Final check on main queue (fourth line of defense)
      // By the time we reach main queue, dispose may have completed
      // Check all conditions one more time before calling markTextureFrameAvailable
      os_unfair_lock_lock(&strongSelf->_lock);
      BOOL shouldCall = !strongSelf->_shuttingDown &&
                        strongSelf->_textureId != -1 &&
                        strongSelf->_textureId == textureId &&
                        strongSelf->_registry != nil &&
                        !strongSelf->_disposed;
      int64_t currentTextureId = strongSelf->_textureId;
      VideoRendererManager* manager = strongSelf->_manager;
      os_unfair_lock_unlock(&strongSelf->_lock);

      if (!shouldCall) {
        return;  // Already disposed or invalid state
      }

      @try {
        [strongSelf->_registry textureFrameAvailable:textureId];
      } @catch (NSException* exception) {
        // Any exception from textureFrameAvailable indicates texture was unregistered
        // (Flutter engine may unregister textures during window/engine teardown)
        // Dispose this instance immediately to prevent further calls
        os_unfair_lock_lock(&strongSelf->_lock);
        // Double-check if already disposed (may have been disposed by another thread)
        if (strongSelf->_disposed || strongSelf->_textureId != currentTextureId) {
          os_unfair_lock_unlock(&strongSelf->_lock);
          return;
        }
        // Zero textureId immediately to prevent further renderFrame calls
        strongSelf->_textureId = -1;
        VideoRendererManager* currentManager = strongSelf->_manager;
        os_unfair_lock_unlock(&strongSelf->_lock);

        // Notify manager to dispose this instance (will remove from dictionary and call dispose)
        if (currentManager && currentTextureId != -1) {
          [currentManager handleTextureUnregistered:currentTextureId];
        } else {
          // Fallback: dispose directly if manager is not available
          [strongSelf dispose];
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
  // This must be set BEFORE removing renderer to prevent race condition
  _shuttingDown = true;
  int64_t textureId = _textureId;
  RTCVideoTrack* videoTrack = _videoTrack;
  id<FlutterTextureRegistry> registry = _registry;
  // Clear registry reference to help detect unregistration in renderFrame
  _registry = nil;
  os_unfair_lock_unlock(&_lock);

  // STEP 2: STOP PRODUCER (WebRTC video track) - CRITICAL
  // This stops the source of frames BEFORE we unregister texture
  // Without this, WebRTC will continue feeding frames even after texture is unregistered
  if (videoTrack) {
    // Remove this renderer from the track (stops producer)
    [videoTrack removeRenderer:self];

    // CRITICAL: Wait for WebRTC to process removal and stop queuing frames
    // WebRTC may have frames already queued in its internal queue
    // We need to wait long enough for those to be processed/dropped
    // 50ms should be enough for WebRTC to flush its queue
    usleep(50000);  // 50ms - ensures WebRTC stops feeding frames

    NSLog(@"VideoRendererInstance: Stopped video track (producer) for texture %lld", textureId);
  }

  // STEP 3: Zero textureId BEFORE unregister (prevents any remaining renderFrame from using it)
  // Even if a frame somehow gets through, textureId check will fail
  os_unfair_lock_lock(&_lock);
  _textureId = -1;  // CRITICAL: Zero immediately - any renderFrame after this will see -1 and return
  _videoTrack = nil;
  os_unfair_lock_unlock(&_lock);

  // STEP 4: Unregister texture (now safe - producer stopped, textureId zeroed)
  // Note: texture may have already been unregistered externally by Flutter engine
  if (textureId != -1 && registry) {
    @try {
      [registry unregisterTexture:textureId];
      NSLog(@"VideoRendererInstance: Unregistered texture %lld", textureId);
    } @catch (NSException* exception) {
      // Texture may have already been unregistered externally (e.g., during engine teardown)
      // This is expected and safe to ignore
      NSLog(@"VideoRendererInstance: Texture %lld already unregistered (expected if unregistered externally)", textureId);
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

  NSLog(@"VideoRendererInstance: Completed disposal for texture %lld", textureId);
}

@end
