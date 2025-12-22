#include "video_renderer_manager.h"

namespace flutter_webrtc_plugin {

VideoRendererManager::VideoRendererManager(
    TextureRegistrar* registrar,
    BinaryMessenger* messenger,
    TaskRunner* task_runner)
    : registrar_(registrar),
      messenger_(messenger),
      task_runner_(task_runner) {
}

VideoRendererManager::~VideoRendererManager() {
  DisposeAll();
}

int64_t VideoRendererManager::CreateRendererForTrack(
    scoped_refptr<RTCVideoTrack> track) {
  if (!track || !registrar_) {
    return -1;
  }

  auto instance = scoped_refptr<VideoRendererInstance>(
      new RefCountedObject<VideoRendererInstance>(
          registrar_, messenger_, task_runner_, track));

  instance->Initialize();

  int64_t texture_id = instance->texture_id();
  if (texture_id == -1) {
    return -1;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  renderers_[texture_id] = instance;

  return texture_id;
}

void VideoRendererManager::DisposeRenderer(int64_t texture_id) {
  if (texture_id == -1) {
    return;
  }

  scoped_refptr<VideoRendererInstance> instance;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = renderers_.find(texture_id);
    if (it != renderers_.end()) {
      instance = it->second;
      renderers_.erase(it);
    }
  }

  if (instance) {
    instance->Dispose();
  }
}

scoped_refptr<VideoRendererInstance> VideoRendererManager::RendererForTextureId(
    int64_t texture_id) {
  if (texture_id == -1) {
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    return it->second;
  }
  return nullptr;
}

void VideoRendererManager::DisposeAll() {
  std::map<int64_t, scoped_refptr<VideoRendererInstance>> instances;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    instances = std::move(renderers_);
    renderers_.clear();
  }

  for (auto& pair : instances) {
    if (pair.second) {
      pair.second->Dispose();
    }
  }
}

}  // namespace flutter_webrtc_plugin
