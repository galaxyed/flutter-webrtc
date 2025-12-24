#import "WindowRendererDisposer.h"
#import "FlutterWebRTCPlugin.h"

@implementation WindowRendererDisposer

+ (void)disposeRenderersForWindowId:(int64_t)windowId
                          messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  if (windowId == -1 || !messenger) {
    NSLog(@"WindowRendererDisposer: Invalid windowId or messenger");
    return;
  }

  // Try to get FlutterWebRTCPlugin instance
  // Since each window may have its own plugin instance, we need to find the right one
  // For now, use sharedSingleton which should work for most cases
  FlutterWebRTCPlugin* plugin = [FlutterWebRTCPlugin sharedSingleton];

  if (!plugin || !plugin.videoRendererManager) {
    NSLog(@"WindowRendererDisposer: No FlutterWebRTCPlugin instance or VideoRendererManager found");
    return;
  }

  NSLog(@"WindowRendererDisposer: Disposing renderers for windowId %lld", windowId);

  // CRITICAL: Stop producers (WebRTC tracks) immediately
  // This is called from windowWillClose, BEFORE channel dies
  [plugin.videoRendererManager disposeRenderersForWindow:windowId];

  NSLog(@"WindowRendererDisposer: Completed disposing renderers for windowId %lld", windowId);
}

@end

