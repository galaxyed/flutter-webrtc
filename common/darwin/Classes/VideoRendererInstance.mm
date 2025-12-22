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
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry
                       videoTrack:(RTCVideoTrack*)track {
  self = [super init];
  if (self) {
    _registry = registry;
    _videoTrack = track;
    _lock = OS_UNFAIR_LOCK_INIT;
    _frameSize = CGSizeZero;
    _rotation = -1;
    _lastPixelBuffer = nil;
    _frameAvailable = false;
    _disposed = false;

    // Register Flutter texture
    _textureId = [_registry registerTexture:self];
    if (_textureId == -1) {
      return nil;
    }

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
  if (_disposed || !_videoTrack) {
    return;
  }

  os_unfair_lock_lock(&_lock);

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

  os_unfair_lock_unlock(&_lock);

  // Notify Flutter to redraw on main queue
  if (_textureId != -1 && !_disposed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_disposed && self->_textureId != -1) {
        [self->_registry textureFrameAvailable:self->_textureId];
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
    uint8_t* dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t* dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
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
    uint8_t* dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
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
  if (_disposed) {
    return;
  }

  os_unfair_lock_lock(&_lock);
  _disposed = true;

  // Detach renderer from VideoTrack
  if (_videoTrack) {
    [_videoTrack removeRenderer:self];
    _videoTrack = nil;
  }

  // Unregister Flutter texture
  if (_textureId != -1) {
    [_registry unregisterTexture:_textureId];
    _textureId = -1;
  }

  // Release GPU resources
  if (_lastPixelBuffer) {
    CVBufferRelease(_lastPixelBuffer);
    _lastPixelBuffer = nil;
  }

  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
}

@end
