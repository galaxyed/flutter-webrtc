import 'package:flutter/services.dart';
import 'native/utils.dart';

/// Multi-renderer API for creating multiple renderers for the same VideoTrack.
///
/// This allows multiple Flutter windows to render the same video track,
/// each with its own textureId.
///
/// ## Usage Example
///
/// ```dart
/// // Create a renderer for a video track
/// final textureId = await MultiRendererAPI.createRenderer(videoTrack.id);
///
/// // Use in widget tree
/// Texture(textureId: textureId)
///
/// // Dispose when done
/// await MultiRendererAPI.disposeRenderer(textureId);
/// ```
///
/// See [MULTI_RENDERER_README.md](../../MULTI_RENDERER_README.md) for detailed documentation.
class MultiRendererAPI {
  MultiRendererAPI._();

  /// Creates a new renderer instance for the given video track.
  ///
  /// [trackId] The ID of the video track to render.
  /// [windowId] Optional window ID to associate with this renderer (for lifecycle management).
  ///
  /// Returns the textureId that can be used with Flutter's Texture widget.
  ///
  /// Throws a PlatformException if the track is not found or renderer creation fails.
  ///
  /// ## Example
  ///
  /// ```dart
  /// try {
  ///   final textureId = await MultiRendererAPI.createRenderer(videoTrack.id, windowId: windowId);
  ///   // Use textureId with Texture widget
  /// } on PlatformException catch (e) {
  ///   print('Error: ${e.message}');
  /// }
  /// ```
  static Future<int> createRenderer(String trackId, {int? windowId}) async {
    try {
      final arguments = <String, dynamic>{
        'trackId': trackId,
      };
      if (windowId != null) {
        arguments['windowId'] = windowId;
      }
      final result = await WebRTC.invokeMethod<int, dynamic>(
        'createRenderer',
        arguments,
      );

      if (result == null) {
        throw PlatformException(
          code: 'createRendererFailed',
          message: 'createRenderer returned null',
        );
      }

      return result;
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: e.message ?? 'Failed to create renderer',
        details: e.details,
      );
    } catch (e) {
      throw PlatformException(
        code: 'createRendererFailed',
        message: 'Unexpected error: $e',
      );
    }
  }

  /// Disposes a renderer instance and releases its resources.
  ///
  /// [textureId] The textureId of the renderer to dispose.
  ///
  /// Throws a PlatformException if the textureId is invalid or disposal fails.
  ///
  /// ## Example
  ///
  /// ```dart
  /// try {
  ///   await MultiRendererAPI.disposeRenderer(textureId);
  /// } on PlatformException catch (e) {
  ///   print('Error: ${e.message}');
  /// }
  /// ```
  ///
  /// **Important:** Always call this method when disposing a widget or closing a window
  /// to prevent memory leaks.
  static Future<void> disposeRenderer(int textureId) async {
    try {
      await WebRTC.invokeMethod('disposeRenderer', <String, dynamic>{
        'textureId': textureId,
      });
    } on PlatformException catch (e) {
      throw PlatformException(
        code: e.code,
        message: e.message ?? 'Failed to dispose renderer',
        details: e.details,
      );
    } catch (e) {
      throw PlatformException(
        code: 'disposeRendererFailed',
        message: 'Unexpected error: $e',
      );
    }
  }
}
