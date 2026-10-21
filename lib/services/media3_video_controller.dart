import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'media_session_service.dart';

class Media3VideoValue {
  const Media3VideoValue({
    this.isInitialized = false, this.isPlaying = false, this.isBuffering = false, this.isEnded = false,
    this.duration = Duration.zero, this.position = Duration.zero, this.size = Size.zero,
    this.errorDescription,
  });
  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final bool isEnded;
  final Duration duration;
  final Duration position;
  final Size size;
  final String? errorDescription;
  bool get hasError => errorDescription != null && errorDescription!.isNotEmpty;
  double get aspectRatio => size.height <= 0 ? 0 : size.width / size.height;
}

class Media3VideoController extends ChangeNotifier {
  Media3VideoController({required this.file, required this.title});
  final File file;
  final String title;
  static const MethodChannel _channel = MethodChannel('com.samirnet.snplayer/media3');
  Media3VideoValue _value = const Media3VideoValue();
  Timer? _pollTimer;
  bool _disposed = false;
  bool _polling = false;
  Media3VideoValue get value => _value;

  Future<void> initialize({
    required List<File> queueFiles, required List<String> queueTitles,
    required int initialIndex, Duration initialPosition = Duration.zero, bool looping = false,
  }) async {
    if (queueFiles.isEmpty || queueFiles.length != queueTitles.length) throw ArgumentError('قائمة الفيديوهات فارغة أو غير صالحة');
    final handler = await getBackgroundAudioHandler();
    if (handler is! SNBackgroundAudioHandler) throw StateError('خدمة Media3 غير جاهزة');
    await handler.playQueueInBackground(queueFiles, queueTitles, initialIndex, startPosition: initialPosition);
    await _channel.invokeMethod<bool>('setRepeatMode', {'mode': looping ? 1 : 0});
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      await _refresh();
      if (_value.isInitialized || _value.hasError) break;
      await Future.delayed(const Duration(milliseconds: 120));
    }
    if (_value.hasError) throw StateError(_value.errorDescription!);
    if (!_value.isInitialized) throw TimeoutException('انتهت مهلة تهيئة محرك Media3 للفيديو');
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 220), (_) => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (_disposed || _polling) return;
    _polling = true;
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>('getState');
      if (state == null || _disposed) return;
      final durationMs = (state['durationMs'] as num?)?.toInt() ?? 0;
      final positionMs = (state['positionMs'] as num?)?.toInt() ?? 0;
      final width = (state['width'] as num?)?.toInt() ?? 0;
      final height = (state['height'] as num?)?.toInt() ?? 0;
      final error = (state['error'] as String?)?.trim();
      _value = Media3VideoValue(
        isInitialized: state['isReady'] == true, isPlaying: state['isPlaying'] == true,
        isBuffering: state['isBuffering'] == true, isEnded: state['isEnded'] == true,
        duration: Duration(milliseconds: durationMs < 0 ? 0 : durationMs),
        position: Duration(milliseconds: positionMs < 0 ? 0 : positionMs),
        size: Size(width.toDouble(), height.toDouble()),
        errorDescription: error == null || error.isEmpty ? null : error,
      );
      notifyListeners();
    } catch (error) {
      debugPrint('Media3 video state refresh failed: $error');
    } finally {
      _polling = false;
    }
  }

  Future<void> play() async { await _channel.invokeMethod<bool>('play'); await _refresh(); }
  Future<void> pause() async { await _channel.invokeMethod<bool>('pause'); await _refresh(); }
  Future<void> seekTo(Duration position) async {
    await _channel.invokeMethod<bool>('seek', {'positionMs': position.inMilliseconds < 0 ? 0 : position.inMilliseconds});
    await _refresh();
  }
  Future<void> setLooping(bool looping) async { await _channel.invokeMethod<bool>('setRepeatMode', {'mode': looping ? 1 : 0}); await _refresh(); }
  Future<void> setPlaybackSpeed(double speed) async { await _channel.invokeMethod<bool>('setSpeed', {'speed': speed.clamp(0.5, 2.0)}); }
  Future<void> setVolume(double volume) async { await _channel.invokeMethod<bool>('setVolume', {'volume': volume.clamp(0.0, 1.0)}); }
  @override
  void dispose() { _disposed = true; _pollTimer?.cancel(); super.dispose(); }
}

