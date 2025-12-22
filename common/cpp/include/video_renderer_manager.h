#ifndef FLUTTER_WEBRTC_VIDEO_RENDERER_MANAGER_HXX
#define FLUTTER_WEBRTC_VIDEO_RENDERER_MANAGER_HXX

#include "flutter_common.h"
#include "flutter_webrtc_base.h"
#include "video_renderer_instance.h"
#include <map>
#include <mutex>
#include <memory>

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

/**
 * VideoRendererManager manages multiple VideoRendererInstance objects.
 * Each renderer instance is keyed by its textureId.
 * This allows multiple Flutter windows to render the same VideoTrack.
 */
class VideoRendererManager {
 public:
  VideoRendererManager(TextureRegistrar* registrar,
                      BinaryMessenger* messenger,
                      TaskRunner* task_runner);

  ~VideoRendererManager();

  int64_t CreateRendererForTrack(scoped_refptr<RTCVideoTrack> track);

  void DisposeRenderer(int64_t texture_id);

  scoped_refptr<VideoRendererInstance> RendererForTextureId(int64_t texture_id);

  void DisposeAll();

 private:
  TextureRegistrar* registrar_;
  BinaryMessenger* messenger_;
  TaskRunner* task_runner_;
  std::map<int64_t, scoped_refptr<VideoRendererInstance>> renderers_;
  std::mutex mutex_;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_VIDEO_RENDERER_MANAGER_HXX
