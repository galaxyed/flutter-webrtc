#ifndef FLUTTER_WEBRTC_VIDEO_RENDERER_INSTANCE_HXX
#define FLUTTER_WEBRTC_VIDEO_RENDERER_INSTANCE_HXX

#include "flutter_common.h"
#include "flutter_webrtc_base.h"
#include "rtc_video_frame.h"
#include "rtc_video_renderer.h"
#include <mutex>
#include <memory>

namespace flutter_webrtc_plugin {

using namespace libwebrtc;

/**
 * VideoRendererInstance represents a single renderer instance attached to a VideoTrack.
 * Each instance owns its own texture and textureId for rendering in Flutter windows.
 * Multiple instances can be attached to the same VideoTrack.
 */
class VideoRendererInstance : public RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>,
                              public RefCountInterface {
 public:
  VideoRendererInstance(TextureRegistrar* registrar,
                       BinaryMessenger* messenger,
                       TaskRunner* task_runner,
                       scoped_refptr<RTCVideoTrack> track);

  ~VideoRendererInstance();

  void Initialize();

  virtual const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width,
                                                          size_t height) const override;

  virtual void OnFrame(scoped_refptr<RTCVideoFrame> frame) override;

  int64_t texture_id() const { return texture_id_; }

  void Dispose();

 private:
  TextureRegistrar* registrar_;
  BinaryMessenger* messenger_;
  TaskRunner* task_runner_;
  scoped_refptr<RTCVideoTrack> track_;

  int64_t texture_id_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  std::shared_ptr<FlutterDesktopPixelBuffer> pixel_buffer_;
  mutable std::shared_ptr<uint8_t> rgb_buffer_;
  mutable std::mutex mutex_;

  scoped_refptr<RTCVideoFrame> frame_;
  bool disposed_;
  bool first_frame_rendered_;
  size_t last_width_;
  size_t last_height_;
  RTCVideoFrame::VideoRotation rotation_;
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_WEBRTC_VIDEO_RENDERER_INSTANCE_HXX
