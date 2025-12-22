#import "VideoRendererManager.h"
#import "VideoRendererInstance.h"
#import <WebRTC/WebRTC.h>
#import <os/lock.h>

@implementation VideoRendererManager {
  id<FlutterTextureRegistry> _registry;
  NSMutableDictionary<NSNumber*, VideoRendererInstance*>* _renderers;
  os_unfair_lock _lock;
}

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry {
  self = [super init];
  if (self) {
    _registry = registry;
    _renderers = [NSMutableDictionary dictionary];
    _lock = OS_UNFAIR_LOCK_INIT;
  }
  return self;
}

- (void)dealloc {
  [self disposeAll];
}

- (int64_t)createRendererForTrack:(RTCVideoTrack*)track {
  if (!track || !_registry) {
    return -1;
  }

  VideoRendererInstance* instance =
      [[VideoRendererInstance alloc] initWithRegistry:_registry videoTrack:track];

  if (!instance) {
    return -1;
  }

  int64_t textureId = instance.textureId;
  if (textureId == -1) {
    return -1;
  }

  os_unfair_lock_lock(&_lock);
  _renderers[@(textureId)] = instance;
  os_unfair_lock_unlock(&_lock);

  return textureId;
}

- (void)disposeRenderer:(int64_t)textureId {
  if (textureId == -1) {
    return;
  }

  os_unfair_lock_lock(&_lock);
  NSNumber* key = @(textureId);
  VideoRendererInstance* instance = _renderers[key];
  if (instance) {
    [instance dispose];
    [_renderers removeObjectForKey:key];
  }
  os_unfair_lock_unlock(&_lock);
}

- (VideoRendererInstance*)rendererForTextureId:(int64_t)textureId {
  if (textureId == -1) {
    return nil;
  }

  os_unfair_lock_lock(&_lock);
  VideoRendererInstance* instance = _renderers[@(textureId)];
  os_unfair_lock_unlock(&_lock);

  return instance;
}

- (void)disposeAll {
  os_unfair_lock_lock(&_lock);
  NSArray<VideoRendererInstance*>* allInstances = [_renderers allValues];
  [_renderers removeAllObjects];
  os_unfair_lock_unlock(&_lock);

  for (VideoRendererInstance* instance in allInstances) {
    [instance dispose];
  }
}

@end
