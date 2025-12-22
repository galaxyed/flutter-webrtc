# Hướng Dẫn Sử Dụng Multi-Renderer API

## Tổng Quan

Multi-Renderer API cho phép tạo nhiều renderer instance cho cùng một `VideoTrack`, giúp mỗi Flutter window có thể hiển thị video độc lập với `textureId` riêng. Tính năng này rất cần thiết cho các ứng dụng multi-window cần hiển thị cùng một video stream trong nhiều cửa sổ.

## Cài Đặt

API này đã được tích hợp sẵn trong flutter_webrtc. Chỉ cần import:

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
```

## Sử Dụng Cơ Bản

### Bước 1: Tạo Renderer

```dart
// Lấy video track từ MediaStream
final videoTracks = stream.getVideoTracks();
if (videoTracks.isNotEmpty) {
  final videoTrack = videoTracks.first;

  // Tạo renderer và lấy textureId
  final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);

  // Lưu textureId để sử dụng
  _textureId = textureId;
}
```

### Bước 2: Hiển Thị Video

```dart
Widget build(BuildContext context) {
  if (_textureId == null) {
    return CircularProgressIndicator();
  }

  return Container(
    color: Colors.black,
    child: Texture(textureId: _textureId!),
  );
}
```

### Bước 3: Giải Phóng Tài Nguyên

```dart
@override
void dispose() {
  if (_textureId != null) {
    MultiRendererAPI.disposeRenderer(_textureId!);
    _textureId = null;
  }
  super.dispose();
}
```

## Ví Dụ Hoàn Chỉnh

```dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoPlayerWidget extends StatefulWidget {
  final MediaStreamTrack videoTrack;

  const VideoPlayerWidget({Key? key, required this.videoTrack})
      : super(key: key);

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> {
  int? _textureId;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeRenderer();
  }

  Future<void> _initializeRenderer() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final textureId = await MultiRendererAPI.createRenderer(
        widget.videoTrack.id,
      );

      setState(() {
        _textureId = textureId;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Lỗi tạo renderer: $e';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    if (_textureId != null) {
      MultiRendererAPI.disposeRenderer(_textureId!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, color: Colors.red),
            SizedBox(height: 8),
            Text(_error!),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializeRenderer,
              child: const Text('Thử Lại'),
            ),
          ],
        ),
      );
    }

    if (_textureId == null) {
      return const Center(child: Text('Không có video'));
    }

    return Container(
      color: Colors.black,
      child: Center(
        child: Texture(textureId: _textureId!),
      ),
    );
  }
}
```

## Multi-Window Scenario

Để hiển thị cùng một video trong nhiều cửa sổ:

```dart
class MultiWindowManager {
  final MediaStreamTrack videoTrack;
  final Map<String, int> windowTextureIds = {};

  MultiWindowManager(this.videoTrack);

  // Tạo renderer cho một window mới
  Future<int> createRendererForWindow(String windowId) async {
    try {
      final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);
      windowTextureIds[windowId] = textureId;
      return textureId;
    } catch (e) {
      print('Lỗi tạo renderer cho window $windowId: $e');
      rethrow;
    }
  }

  // Giải phóng renderer khi đóng window
  Future<void> disposeRendererForWindow(String windowId) async {
    final textureId = windowTextureIds[windowId];
    if (textureId != null) {
      await MultiRendererAPI.disposeRenderer(textureId);
      windowTextureIds.remove(windowId);
    }
  }

  // Giải phóng tất cả renderers
  Future<void> disposeAll() async {
    for (final textureId in windowTextureIds.values) {
      await MultiRendererAPI.disposeRenderer(textureId);
    }
    windowTextureIds.clear();
  }
}
```

## Xử Lý Lỗi

Luôn bọc các API calls trong try-catch:

```dart
try {
  final textureId = await MultiRendererAPI.createRenderer(trackId);
  // Sử dụng textureId
} on PlatformException catch (e) {
  if (e.code == 'createRendererFailed') {
    print('Không tìm thấy track hoặc lỗi tạo renderer');
    // Xử lý lỗi: hiển thị thông báo, retry, etc.
  }
} catch (e) {
  print('Lỗi không mong đợi: $e');
}
```

## Lưu Ý Quan Trọng

### 1. Lifecycle Management

**QUAN TRỌNG:** Luôn dispose renderer trước khi widget bị destroy:

```dart
@override
void dispose() {
  // Dispose renderer TRƯỚC super.dispose()
  if (_textureId != null) {
    MultiRendererAPI.disposeRenderer(_textureId!);
    _textureId = null;
  }
  super.dispose();
}
```

### 2. Một Renderer Một Window

Mỗi Flutter window/widget cần một renderer riêng. Không chia sẻ `textureId` giữa các window.

### 3. Kiểm Tra Track Trước Khi Tạo Renderer

```dart
// Đảm bảo track tồn tại và đang active
if (videoTrack.enabled && !videoTrack.muted) {
  final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);
}
```

### 4. Xử Lý Track Thay Đổi

Nếu track thay đổi, dispose renderer cũ và tạo mới:

```dart
void _onTrackChanged(MediaStreamTrack? newTrack) {
  // Dispose renderer cũ
  if (_textureId != null && _oldTrack != null) {
    MultiRendererAPI.disposeRenderer(_textureId!);
    _textureId = null;
  }

  // Tạo renderer mới
  if (newTrack != null) {
    _createRenderer(newTrack);
  }

  _oldTrack = newTrack;
}
```

## Platform Support

- ✅ **macOS**: Hỗ trợ đầy đủ
- ✅ **Windows**: Hỗ trợ đầy đủ
- ✅ **Linux**: Hỗ trợ đầy đủ
- ❌ **Android/iOS**: Không hỗ trợ (sử dụng cơ chế rendering khác)

## Troubleshooting

### Renderer không tạo được

**Nguyên nhân:**
- TrackId không tồn tại
- Track đã bị dispose
- Platform không hỗ trợ

**Giải pháp:**
```dart
// Kiểm tra track trước khi tạo
if (videoTrack.enabled && videoTrack.readyState == 'live') {
  try {
    final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);
  } catch (e) {
    // Xử lý lỗi
  }
}
```

### Màn hình đen

**Nguyên nhân:**
- Track không nhận được frames
- Renderer bị dispose sớm
- TextureId sai

**Giải pháp:**
- Kiểm tra WebRTC connection
- Đảm bảo track đang active
- Kiểm tra lifecycle management

### Memory Leak

**Nguyên nhân:**
- Không dispose renderer khi đóng window
- Tạo renderer trùng lặp

**Giải pháp:**
- Luôn dispose trong `dispose()` method
- Sử dụng `Set` hoặc `Map` để track các textureId đã tạo

## Best Practices

1. **Một Renderer Một Window**: Mỗi window tạo một renderer riêng
2. **Dispose Đúng Cách**: Luôn dispose trong `dispose()` method
3. **Error Handling**: Bọc tất cả API calls trong try-catch
4. **Resource Management**: Không tạo quá nhiều renderer không cần thiết
5. **Track Validation**: Kiểm tra track trước khi tạo renderer

## Ví Dụ Nâng Cao

### Tích Hợp Với WebRTC PeerConnection

```dart
class WebRTCVideoView extends StatefulWidget {
  final RTCPeerConnection peerConnection;
  final String trackId;

  const WebRTCVideoView({
    Key? key,
    required this.peerConnection,
    required this.trackId,
  }) : super(key: key);

  @override
  State<WebRTCVideoView> createState() => _WebRTCVideoViewState();
}

class _WebRTCVideoViewState extends State<WebRTCVideoView> {
  int? _textureId;
  RTCVideoTrack? _videoTrack;

  @override
  void initState() {
    super.initState();
    _setupVideoTrack();
  }

  Future<void> _setupVideoTrack() async {
    // Lấy remote streams
    final remoteStreams = widget.peerConnection.getRemoteStreams();

    // Tìm video track
    for (final stream in remoteStreams) {
      final videoTracks = stream.getVideoTracks();
      for (final track in videoTracks) {
        if (track.id == widget.trackId) {
          _videoTrack = track;

          // Tạo renderer
          try {
            final textureId = await MultiRendererAPI.createRenderer(track.id);
            setState(() {
              _textureId = textureId;
            });
          } catch (e) {
            print('Lỗi tạo renderer: $e');
          }
          return;
        }
      }
    }
  }

  @override
  void dispose() {
    if (_textureId != null) {
      MultiRendererAPI.disposeRenderer(_textureId!);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_textureId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      color: Colors.black,
      child: Texture(textureId: _textureId!),
    );
  }
}
```

## Tài Liệu Tham Khảo

- [Multi-Renderer README (English)](./MULTI_RENDERER_README.md)
- [Flutter Texture Widget](https://api.flutter.dev/flutter/widgets/Texture-class.html)
- [flutter_webrtc Documentation](../README.md)
