import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

/// Owns the single Android media session and the playback-control notification.
/// Initialization can be retried if Android/plugin setup fails during startup.
Future<AudioHandler>? _mediaHandlerFuture;

Future<AudioHandler> getBackgroundAudioHandler() async {
  final existing = _mediaHandlerFuture;
  if (existing != null) return existing;

  final future = AudioService.init(
    builder: () => SNBackgroundAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.samirnet.snplayer.media.v3',
      androidNotificationChannelName: 'SM Player · التحكم بالوسائط',
      androidNotificationChannelDescription: 'أزرار التحكم بتشغيل الصوت والفيديو.',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
      androidNotificationClickStartsActivity: true,
      androidNotificationIcon: 'drawable/ic_stat_player',
    ),
  );
  _mediaHandlerFuture = future;
  try {
    final handler = await future;
    return handler;
  } catch (error, stack) {
    if (identical(_mediaHandlerFuture, future)) {
      _mediaHandlerFuture = null;
    }
    debugPrint('Media session initialization failed; allowing retry: $error');
    Error.throwWithStackTrace(error, stack);
  }
}

Future<void> initializeMediaSession() async {
  await getBackgroundAudioHandler();
}

class SNBackgroundAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  VideoPlayerController? _foregroundVideoController;
  String? _foregroundVideoId;
  String? _foregroundVideoTitle;
  bool _backgroundQueueActive = false;
  Duration _lastForegroundPosition = Duration.zero;
  bool? _lastForegroundPlaying;

  void bindForegroundVideo(
    VideoPlayerController controller, {
    required String id,
    required String title,
  }) {
    _foregroundVideoController = controller;
    _foregroundVideoId = id;
    _foregroundVideoTitle = title;
    _backgroundQueueActive = false;
    _lastForegroundPosition = Duration.zero;
    _lastForegroundPlaying = null;
    syncForegroundVideoState(force: true);
  }

  void clearForegroundVideo(VideoPlayerController controller) {
    if (!identical(_foregroundVideoController, controller) || _backgroundQueueActive) return;
    _foregroundVideoController = null;
    _foregroundVideoId = null;
    _foregroundVideoTitle = null;
    mediaItem.add(null);
    unawaited(stop());
  }

  void syncForegroundVideoState({bool force = false}) {
    final controller = _foregroundVideoController;
    if (_backgroundQueueActive || controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    final position = value.position;
    if (!force &&
        _lastForegroundPlaying == value.isPlaying &&
        (position - _lastForegroundPosition).inMilliseconds.abs() < 900) {
      return;
    }
    _lastForegroundPlaying = value.isPlaying;
    _lastForegroundPosition = position;
    final id = _foregroundVideoId;
    if (id == null) return;
    mediaItem.add(MediaItem(
      id: 'foreground:$id',
      title: _foregroundVideoTitle ?? 'SM Player',
      artist: 'SM Player',
      duration: value.duration,
    ));
    playbackState.add(playbackState.value.copyWith(
      controls: [
        value.isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0],
      processingState: AudioProcessingState.ready,
      playing: value.isPlaying,
      updatePosition: position,
      bufferedPosition: position,
      speed: 1.0,
    ));
  }
  SNBackgroundAudioHandler() {
    Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_backgroundQueueActive && _player.playing) {
        playbackState.add(playbackState.value.copyWith(
          updatePosition: _player.position,
          bufferedPosition: _player.bufferedPosition,
          playing: true,
          speed: _player.speed,
        ));
      }
    });
    _player.positionStream.listen((position) {
      if (!_backgroundQueueActive) return;
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
        bufferedPosition: _player.bufferedPosition,
        playing: _player.playing,
        speed: _player.speed,
      ));
    });
    // just_audio's playbackEventStream does not emit for every play/pause
    // command because the playing flag is a separate stream. Publish that flag
    // independently so audio_service can reliably enter Android foreground mode.
    _player.playingStream.listen((playing) {
      if (!_backgroundQueueActive) return;
      debugPrint('SamirNet playingStream: playing=$playing');
      playbackState.add(playbackState.value.copyWith(
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ));
    });
    _player.playbackEventStream.listen((event) {
      if (!_backgroundQueueActive) return;
      final playing = _player.playing;
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ));
    });
    _player.currentIndexStream.listen((index) {
      if (_backgroundQueueActive) _publishCurrentItem(index);
    });
    _player.durationStream.listen((duration) {
      if (_backgroundQueueActive) _publishCurrentDuration(duration);
    });
  }
  void _publishCurrentItem(int? index) {
    if (index == null || index < 0 || index >= queue.value.length) return;
    final queuedItem = queue.value[index];
    final currentItem = mediaItem.value;
    final knownDuration = _player.duration ??
        (currentItem?.id == queuedItem.id ? currentItem?.duration : null) ??
        queuedItem.duration;
    final updatedItem = queuedItem.copyWith(duration: knownDuration);
    final updatedQueue = List<MediaItem>.from(queue.value);
    updatedQueue[index] = updatedItem;
    queue.add(updatedQueue);
    mediaItem.add(updatedItem);
  }

  void _publishCurrentDuration(Duration? duration) {
    if (duration == null) return;
    final index = _player.currentIndex ?? playbackState.value.queueIndex;
    if (index == null || index < 0 || index >= queue.value.length) {
      final current = mediaItem.value;
      if (current != null) mediaItem.add(current.copyWith(duration: duration));
      return;
    }
    final queuedItem = queue.value[index];
    final currentItem = mediaItem.value;
    final baseItem = currentItem != null && currentItem.id == queuedItem.id
        ? currentItem
        : queuedItem;
    final updatedItem = baseItem.copyWith(duration: duration);
    final updatedQueue = List<MediaItem>.from(queue.value);
    updatedQueue[index] = updatedItem;
    queue.add(updatedQueue);
    mediaItem.add(updatedItem);
  }

  Future<void> playFileInBackground(File file, String title, {Duration startPosition = Duration.zero}) async {
    await playQueueInBackground([file], [title], 0, startPosition: startPosition);
  }
  Future<void> playQueueInBackground(List<File> files, List<String> titles, int initialIndex, {Duration startPosition = Duration.zero}) async {
    if (files.isEmpty || files.length != titles.length) {
      throw ArgumentError('The music queue is empty or invalid');
    }
    _backgroundQueueActive = true;
    _foregroundVideoController = null;
    _foregroundVideoId = null;
    _foregroundVideoTitle = null;
    final items = List<MediaItem>.generate(files.length, (i) =>
      MediaItem(id: files[i].path, title: titles[i], artist: 'SM Player'));
    final start = initialIndex.clamp(0, files.length - 1).toInt();
    queue.add(items);
    mediaItem.add(items[start]);
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: files.map((file) => AudioSource.file(file.path)).toList()),
      initialIndex: start,
    );
    if (startPosition > Duration.zero) await _player.seek(startPosition, index: start);
    // Publish duration only after the source is prepared. The duration stream may
    // emit before mediaItem is set, which previously left the UI and media session
    // with a zero/unknown duration and a seek bar stuck at the start.
    // Publish the current track after the source is ready. Duration events can
    // arrive before or after currentIndexStream, so both paths update the item.
    _publishCurrentItem(start);
    _publishCurrentDuration(_player.duration);
    playbackState.add(playbackState.value.copyWith(
      controls: const [
        MediaControl.skipToPrevious,
        MediaControl.pause,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 3],
      processingState: AudioProcessingState.ready,
      playing: false,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      queueIndex: start,
    ));
    // Start playback only after publishing the media item and a ready-but-paused
    // state. The playbackEventStream below publishes playing=true when the
    // underlying player actually starts, which is what Android uses to promote
    // the media service and show its notification.
    // Do not await play(): just_audio completes this future when playback ends.
    unawaited(_player.play().catchError((Object error, StackTrace stack) {
      debugPrint('Background audio playback failed: $error\n$stack');
      playbackState.add(playbackState.value.copyWith(playing: false));
    }));
  }
  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) { await _player.seekToNext(); }
  }
  @override
  Future<void> skipToPrevious() async {
    if (_player.hasPrevious) { await _player.seekToPrevious(); }
    else { await _player.seek(Duration.zero); }
  }
  @override
  Future<void> play() async {
    final video = _foregroundVideoController;
    if (!_backgroundQueueActive && video != null) {
      await video.play();
      syncForegroundVideoState(force: true);
      return;
    }
    await _player.play();
    playbackState.add(playbackState.value.copyWith(playing: true, updatePosition: _player.position));
  }
  @override
  Future<void> pause() async {
    final video = _foregroundVideoController;
    if (!_backgroundQueueActive && video != null) {
      await video.pause();
      syncForegroundVideoState(force: true);
      return;
    }
    await _player.pause();
    playbackState.add(playbackState.value.copyWith(playing: false, updatePosition: _player.position));
  }
  @override
  Future<void> stop() async {
    final video = _foregroundVideoController;
    if (!_backgroundQueueActive && video != null) {
      await video.pause();
      syncForegroundVideoState(force: true);
      return;
    }
    await _player.stop();
    _backgroundQueueActive = false;
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
      updatePosition: Duration.zero,
    ));
    await super.stop();
  }
  @override
  Future<void> seek(Duration position) async {
    final video = _foregroundVideoController;
    if (!_backgroundQueueActive && video != null) {
      await video.seekTo(position);
      syncForegroundVideoState(force: true);
      return;
    }
    await _player.seek(position);
  }
  @override
  Future<void> setSpeed(double speed) async {
    final video = _foregroundVideoController;
    if (!_backgroundQueueActive && video != null) {
      await video.setPlaybackSpeed(speed);
      syncForegroundVideoState(force: true);
      return;
    }
    await _player.setSpeed(speed);
  }
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'playFileInBackground') {
      final path = extras?['path'] as String?;
      final title = extras?['title'] as String? ?? 'SM Player';
      if (path == null || path.isEmpty) throw ArgumentError('Missing media file path');
      final positionMs = extras?['positionMs'] as int? ?? 0;
      await playFileInBackground(File(path), title, startPosition: Duration(milliseconds: positionMs < 0 ? 0 : positionMs));
    } else if (name == 'setLoopMode') {
      final value = extras?['value'] as String? ?? 'off';
      await _player.setLoopMode(value == 'one' ? LoopMode.one : value == 'all' ? LoopMode.all : LoopMode.off);
    } else if (name == 'setShuffle') {
      await _player.setShuffleModeEnabled(extras?['enabled'] == true);
    } else if (name == 'getEqualizerParameters') {
      throw UnsupportedError('المعادل الصوتي غير متاح على هذا الجهاز؛ تم تعطيله لتجنب تعطل تشغيل الموسيقى.');
    } else if (name == 'setEqualizerEnabled' || name == 'setEqualizerBandGain') {
      throw UnsupportedError('المعادل الصوتي غير متاح على هذا الجهاز.');
    } else if (name == 'setMusicSpeed') {
      final v = ((extras?['speed'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0).toDouble();
      await _player.setSpeed(v);
    }
    return null;
  }
}
