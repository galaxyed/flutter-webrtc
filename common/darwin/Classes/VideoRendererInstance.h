#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <WebRTC/WebRTC.h>

@class RTCVideoTrack;

/**
 * VideoRendererInstance represents a single renderer instance attached to a VideoTrack.
 * Each instance owns its own GPU surface and textureId for rendering in Flutter windows.
 * Multiple instances can be attached to the same VideoTrack.
 */
@interface VideoRendererInstance : NSObject <FlutterTexture, RTCVideoRenderer>

@property(nonatomic, readonly) int64_t textureId;
@property(nonatomic, weak, readonly) id<FlutterTextureRegistry> registry;
@property(nonatomic, strong, readonly) RTCVideoTrack* videoTrack;
@property(nonatomic, readonly) int64_t windowId;

/**
 * Initialize a new renderer instance for the given video track.
 * @param registry Flutter texture registry for registering the texture
 * @param track The RTCVideoTrack to render
 * @param windowId Optional window ID to associate with this renderer (for lifecycle management)
 * @return Initialized instance, or nil if initialization fails
 */
- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry
                       videoTrack:(RTCVideoTrack*)track
                         windowId:(int64_t)windowId;

/**
 * Dispose the renderer instance and release all resources.
 * This must be called before the instance is deallocated.
 * Order: detach track → unregister texture → release GPU resources
 */
- (void)dispose;

@end
