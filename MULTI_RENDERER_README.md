# Multi-Renderer API Documentation

## Overview

The Multi-Renderer API allows you to create multiple renderer instances for the same `VideoTrack`, enabling each Flutter window to have its own independent renderer with a unique `textureId`. This is essential for multi-window video rendering scenarios where the same video stream needs to be displayed in multiple windows simultaneously.

## Architecture

The implementation follows a **1 VideoTrack → N Renderers → N textureIds → N Flutter Windows** architecture:

- Each renderer owns its own GPU surface and textureId
- Renderers are explicitly managed (create/dispose)
- No sharing of renderer instances or textureIds across windows
- Thread-safe rendering on platform-specific GPU queues

## Supported Platforms

- ✅ **macOS** (Metal)
- ✅ **Windows** (D3D11)
- ✅ **Linux** (shared implementation)

> **Note:** Android and iOS are not required for this feature as they use different rendering mechanisms.

## API Reference

### `MultiRendererAPI.createRenderer(String trackId)`

Creates a new renderer instance for the given video track.

**Parameters:**
- `trackId` (String): The ID of the video track to render

**Returns:**
- `Future<int>`: The textureId that can be used with Flutter's `Texture` widget

**Throws:**
- `PlatformException` if the track is not found or renderer creation fails

**Example:**
```dart
final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);
```

### `MultiRendererAPI.disposeRenderer(int textureId)`

Disposes a renderer instance and releases its resources.

**Parameters:**
- `textureId` (int): The textureId of the renderer to dispose

**Throws:**
- `PlatformException` if the textureId is invalid or disposal fails

**Example:**
```dart
await MultiRendererAPI.disposeRenderer(textureId);
```

## Usage Examples

### Basic Usage

```dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class VideoWindow extends StatefulWidget {
  final MediaStreamTrack videoTrack;

  const VideoWindow({Key? key, required this.videoTrack}) : super(key: key);

  @override
  State<VideoWindow> createState() => _VideoWindowState();
}

class _VideoWindowState extends State<VideoWindow> {
  int? _textureId;

  @override
  void initState() {
    super.initState();
    _createRenderer();
  }

  Future<void> _createRenderer() async {
    try {
      final textureId = await MultiRendererAPI.createRenderer(widget.videoTrack.id);
      setState(() {
        _textureId = textureId;
      });
    } catch (e) {
      print('Error creating renderer: $e');
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

### Multi-Window Scenario

```dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class MultiWindowVideoApp extends StatefulWidget {
  final MediaStreamTrack videoTrack;

  const MultiWindowVideoApp({Key? key, required this.videoTrack}) : super(key: key);

  @override
  State<MultiWindowVideoApp> createState() => _MultiWindowVideoAppState();
}

class _MultiWindowVideoAppState extends State<MultiWindowVideoApp> {
  final List<int> _textureIds = [];

  @override
  void initState() {
    super.initState();
    _createRendererForMainWindow();
  }

  Future<void> _createRendererForMainWindow() async {
    try {
      final textureId = await MultiRendererAPI.createRenderer(widget.videoTrack.id);
      setState(() {
        _textureIds.add(textureId);
      });
    } catch (e) {
      print('Error creating renderer: $e');
    }
  }

  Future<void> _openNewWindow() async {
    try {
      // Create a new renderer for the new window
      final textureId = await MultiRendererAPI.createRenderer(widget.videoTrack.id);

      // In a real multi-window app, you would pass this textureId to the new window
      // For demonstration, we'll just add it to our list
      setState(() {
        _textureIds.add(textureId);
      });

      // TODO: Create new Flutter window and pass textureId
    } catch (e) {
      print('Error creating renderer for new window: $e');
    }
  }

  @override
  void dispose() {
    // Dispose all renderers
    for (final textureId in _textureIds) {
      MultiRendererAPI.disposeRenderer(textureId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multi-Window Video')),
      body: Column(
        children: [
          Expanded(
            child: _textureIds.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    color: Colors.black,
                    child: Texture(textureId: _textureIds.first),
                  ),
          ),
          ElevatedButton(
            onPressed: _openNewWindow,
            child: const Text('Open New Window'),
          ),
        ],
      ),
    );
  }
}
```

### Integration with Existing WebRTC Code

```dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCVideoWidget extends StatefulWidget {
  final RTCPeerConnection peerConnection;
  final String trackId;

  const WebRTCVideoWidget({
    Key? key,
    required this.peerConnection,
    required this.trackId,
  }) : super(key: key);

  @override
  State<WebRTCVideoWidget> createState() => _WebRTCVideoWidgetState();
}

class _WebRTCVideoWidgetState extends State<WebRTCVideoWidget> {
  int? _textureId;
  RTCVideoTrack? _videoTrack;

  @override
  void initState() {
    super.initState();
    _findAndCreateRenderer();
  }

  Future<void> _findAndCreateRenderer() async {
    try {
      // Get remote streams from peer connection
      final remoteStreams = widget.peerConnection.getRemoteStreams();

      // Find the video track
      for (final stream in remoteStreams) {
        final videoTracks = stream.getVideoTracks();
        for (final track in videoTracks) {
          if (track.id == widget.trackId) {
            _videoTrack = track;

            // Create renderer for this track
            final textureId = await MultiRendererAPI.createRenderer(track.id);
            setState(() {
              _textureId = textureId;
            });
            return;
          }
        }
      }
    } catch (e) {
      print('Error finding or creating renderer: $e');
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

## Lifecycle Management

Proper lifecycle management is critical for preventing memory leaks and crashes. Follow this order:

1. **Create**: Call `createRenderer(trackId)` when the window/widget is created
2. **Render**: Use the returned `textureId` with Flutter's `Texture` widget
3. **Dispose**: Call `disposeRenderer(textureId)` when the window/widget is disposed

**Important:** Always dispose renderers in the reverse order of creation, and ensure disposal happens before the widget is destroyed.

```dart
@override
void dispose() {
  // Dispose renderer BEFORE calling super.dispose()
  if (_textureId != null) {
    MultiRendererAPI.disposeRenderer(_textureId!);
    _textureId = null;
  }
  super.dispose();
}
```

## Error Handling

Always wrap API calls in try-catch blocks:

```dart
try {
  final textureId = await MultiRendererAPI.createRenderer(trackId);
  // Use textureId
} on PlatformException catch (e) {
  print('Platform error: ${e.code} - ${e.message}');
  // Handle error (e.g., show error message to user)
} catch (e) {
  print('Unexpected error: $e');
  // Handle unexpected errors
}
```

Common error codes:
- `createRendererFailed`: Track not found or renderer creation failed
- `disposeRendererFailed`: Invalid textureId or disposal failed

## Best Practices

1. **One Renderer Per Window**: Create one renderer instance per Flutter window/widget that needs to display the video.

2. **Track Lifecycle**: Ensure the video track exists and is active before creating a renderer. Check `track.enabled` and `track.muted` properties.

3. **Dispose Order**: Always dispose renderers before disposing the widget or closing the window.

4. **Error Recovery**: Implement proper error handling and recovery mechanisms. If renderer creation fails, retry or show an error message.

5. **Resource Management**: Don't create more renderers than necessary. Each renderer consumes GPU resources.

6. **Thread Safety**: The API is thread-safe, but ensure Flutter widget operations happen on the main thread.

## Platform-Specific Notes

### macOS
- Uses Metal for rendering
- Thread-safe with `os_unfair_lock`
- Frame delivery happens on WebRTC's render thread
- Flutter callbacks are dispatched to the main queue

### Windows
- Uses D3D11 for rendering
- Thread-safe with `std::mutex`
- Frame delivery happens on WebRTC's render thread
- Flutter callbacks use `TaskRunner`

### Linux
- Uses the same C++ implementation as Windows
- Thread-safe with `std::mutex`

## Troubleshooting

### Renderer Creation Fails

**Problem:** `createRenderer` throws an error or returns -1.

**Solutions:**
- Verify the trackId exists and is valid
- Ensure the video track is active (`track.enabled == true`)
- Check that the track is not already disposed
- Verify platform support (macOS/Windows/Linux only)

### Black Screen or No Video

**Problem:** Texture displays but shows black screen.

**Solutions:**
- Ensure the video track is receiving frames
- Check that `disposeRenderer` was not called prematurely
- Verify the textureId is correct
- Check WebRTC connection status

### Memory Leaks

**Problem:** Memory usage increases over time.

**Solutions:**
- Ensure all renderers are disposed when windows close
- Check for duplicate renderer creation
- Verify proper widget lifecycle management

### Crashes on Window Close

**Problem:** App crashes when closing a window with video.

**Solutions:**
- Ensure `disposeRenderer` is called before window closes
- Check disposal order (renderer → texture → widget)
- Verify no race conditions in multi-threaded scenarios

## Migration from Single Renderer

If you're migrating from the existing `RTCVideoRenderer` API:

**Old Code:**
```dart
final renderer = RTCVideoRenderer();
await renderer.initialize();
renderer.srcObject = stream;
// Use RTCVideoView(renderer)
```

**New Code:**
```dart
final videoTracks = stream.getVideoTracks();
if (videoTracks.isNotEmpty) {
  final textureId = await MultiRendererAPI.createRenderer(videoTracks.first.id);
  // Use Texture(textureId: textureId)
}
```

## Performance Considerations

- Each renderer instance consumes GPU memory
- Multiple renderers for the same track share the video decoding but have separate rendering pipelines
- Frame copying happens per renderer, so more renderers = more CPU/GPU usage
- For best performance, limit the number of simultaneous renderers

## Limitations

1. **Platform Support**: Only supported on macOS, Windows, and Linux. Android and iOS use different rendering mechanisms.

2. **Track Sharing**: While multiple renderers can attach to the same track, each renderer maintains its own frame buffer.

3. **Synchronization**: Frame delivery to multiple renderers may have slight timing differences due to threading.

## See Also

- [Flutter Texture Widget Documentation](https://api.flutter.dev/flutter/widgets/Texture-class.html)
- [flutter_webrtc Main Documentation](../README.md)
- [WebRTC Video Rendering Best Practices](https://webrtc.org/getting-started/video-rotation)

## License

This feature is part of the flutter_webrtc plugin and follows the same license terms.
