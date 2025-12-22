#include "video_renderer_instance.h"
#include <algorithm>

namespace flutter_webrtc_plugin {

VideoRendererInstance::VideoRendererInstance(
    TextureRegistrar* registrar,
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    scoped_refptr<RTCVideoTrack> track)
    : registrar_(registrar),
      messenger_(messenger),
      task_runner_(task_runner),
      track_(track),
      texture_id_(-1),
      disposed_(false),
      first_frame_rendered_(false),
      last_width_(0),
      last_height_(0),
      rotation_(RTCVideoFrame::kVideoRotation_0) {
}

VideoRendererInstance::~VideoRendererInstance() {
  Dispose();
}

void VideoRendererInstance::Initialize() {
  if (disposed_) {
    return;
  }

  // Create texture variant
  auto textureVariant =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [this](size_t width,
                 size_t height) -> const FlutterDesktopPixelBuffer* {
            return this->CopyPixelBuffer(width, height);
          }));

  // Register texture with Flutter
  texture_id_ = registrar_->RegisterTexture(textureVariant.get());
  if (texture_id_ == -1) {
    return;
  }

  texture_ = std::move(textureVariant);

  // Attach track to renderer
  if (track_) {
    track_->AddRenderer(this);
  }
}

const FlutterDesktopPixelBuffer* VideoRendererInstance::CopyPixelBuffer(
    size_t width,
    size_t height) const {
  std::lock_guard<std::mutex> lock(mutex_);

  if (disposed_ || !pixel_buffer_ || !frame_) {
    return nullptr;
  }

  // Update buffer size if frame size changed
  if (pixel_buffer_->width != frame_->width() ||
      pixel_buffer_->height != frame_->height()) {
    size_t buffer_size =
        (size_t(frame_->width()) * size_t(frame_->height())) * (32 >> 3);
    rgb_buffer_.reset(new uint8_t[buffer_size]);
    pixel_buffer_->width = frame_->width();
    pixel_buffer_->height = frame_->height();
  }

  // Convert frame to ARGB format
  frame_->ConvertToARGB(RTCVideoFrame::Type::kABGR, rgb_buffer_.get(), 0,
                       static_cast<int>(pixel_buffer_->width),
                       static_cast<int>(pixel_buffer_->height));

  pixel_buffer_->buffer = rgb_buffer_.get();
  return pixel_buffer_.get();
}

void VideoRendererInstance::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  if (disposed_ || !track_) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!first_frame_rendered_) {
      pixel_buffer_.reset(new FlutterDesktopPixelBuffer());
      pixel_buffer_->width = 0;
      pixel_buffer_->height = 0;
      first_frame_rendered_ = true;
    }

    // Update rotation if changed
    if (rotation_ != frame->rotation()) {
      rotation_ = frame->rotation();
    }

    // Update frame size tracking
    if (last_width_ != frame->width() || last_height_ != frame->height()) {
      last_width_ = frame->width();
      last_height_ = frame->height();
    }

    frame_ = frame;
  }

  // Notify Flutter to redraw on task runner
  if (texture_id_ != -1 && !disposed_) {
    task_runner_->PostTask([this]() {
      if (!this->disposed_ && this->texture_id_ != -1) {
        registrar_->MarkTextureFrameAvailable(texture_id_);
      }
    });
  }
}

void VideoRendererInstance::Dispose() {
  if (disposed_) {
    return;
  }

  std::lock_guard<std::mutex> lock(mutex_);
  disposed_ = true;

  // Detach renderer from VideoTrack
  if (track_) {
    track_->RemoveRenderer(this);
    track_ = nullptr;
  }

  // Unregister Flutter texture
  if (texture_id_ != -1) {
    registrar_->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }

  // Release resources
  texture_.reset();
  pixel_buffer_.reset();
  rgb_buffer_.reset();
  frame_ = nullptr;
}

}  // namespace flutter_webrtc_plugin
