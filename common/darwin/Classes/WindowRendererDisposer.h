#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#elif TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#endif

/**
 * Helper class to dispose WebRTC renderers by windowId from native side.
 * This is used in windowWillClose to stop producers BEFORE channel dies.
 */
@interface WindowRendererDisposer : NSObject

/**
 * Disposes all renderers for a given window ID.
 * This stops WebRTC video tracks (producers) immediately.
 *
 * @param windowId The window ID (hashed from String UUID to int64)
 * @param messenger The Flutter binary messenger to find the plugin instance
 */
+ (void)disposeRenderersForWindowId:(int64_t)windowId
                          messenger:(NSObject<FlutterBinaryMessenger>*)messenger;

@end

