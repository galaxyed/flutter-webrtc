#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@class RTCVideoTrack;
@class VideoRendererInstance;

/**
 * VideoRendererManager manages multiple VideoRendererInstance objects.
 * Each renderer instance is keyed by its textureId.
 * This allows multiple Flutter windows to render the same VideoTrack.
 */
@interface VideoRendererManager : NSObject

/**
 * Initialize the manager with a Flutter texture registry.
 * @param registry The Flutter texture registry for registering textures
 */
- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry;

/**
 * Create a new renderer instance for the given video track.
 * @param track The RTCVideoTrack to render
 * @return The textureId of the created renderer, or -1 if creation fails
 */
- (int64_t)createRendererForTrack:(RTCVideoTrack*)track;

/**
 * Dispose a renderer instance by its textureId.
 * @param textureId The textureId of the renderer to dispose
 */
- (void)disposeRenderer:(int64_t)textureId;

/**
 * Get a renderer instance by textureId.
 * @param textureId The textureId to lookup
 * @return The renderer instance, or nil if not found
 */
- (VideoRendererInstance*)rendererForTextureId:(int64_t)textureId;

/**
 * Dispose all renderer instances.
 * Called when the manager is being deallocated.
 */
- (void)disposeAll;

@end
