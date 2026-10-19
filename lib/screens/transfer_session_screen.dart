import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

const _transferRed = Color(0xFFEF3340);

class TransferProgressScreen extends StatelessWidget {
  const TransferProgressScreen({
    super.key,
    required this.progressRevision,
    required this.progressBytes,
    required this.progressTotals,
    required this.progressNames,
    required this.progressStartedAt,
    required this.completedPayloads,
    required this.completedFiles,
    required this.onAddMore,
    required this.onOpenFile,
    required this.isReceiving,
  });

  final ValueListenable<int> progressRevision;
  final Map<int, int> progressBytes;
  final Map<int, int> progressTotals;
  final Map<int, String> progressNames;
  final Map<int, DateTime> progressStartedAt;
  final Set<int> completedPayloads;
  final Map<int, File> completedFiles;
  final VoidCallback onAddMore;
  final ValueChanged<File> onOpenFile;
  final bool isReceiving;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isReceiving ? 'نقل الملفات' : 'إرسال الملفات'),
          actions: [
            IconButton(
              tooltip: 'إرسال المزيد',
              onPressed: onAddMore,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: progressRevision,
          builder: (context, _, __) {
            final ids = progressTotals.keys.toList()..sort((a, b) => a.compareTo(b));
            final transferred = ids.fold<int>(
              0,
              (sum, id) => sum + (progressBytes[id] ?? 0).clamp(0, progressTotals[id] ?? 0),
            );
            final total = ids.fold<int>(0, (sum, id) => sum + (progressTotals[id] ?? 0));
            var speed = 0.0;
            for (final id in ids) {
              final started = progressStartedAt[id];
              if (started == null) continue;
              final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
              if (elapsed > 0) speed += (progressBytes[id] ?? 0) / elapsed;
            }
            final allDone = ids.isNotEmpty && ids.every((id) =>
                completedPayloads.contains(id) && completedFiles.containsKey(id));
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: _transferRed, width: 1.4),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: _SummaryMetric(
                            icon: Icons.file_download_done_rounded,
                            label: isReceiving ? 'تم الاستلام' : 'تم الإرسال',
                            value: _formatBytes(transferred),
                            color: colors.onSurface,
                          ),
                        ),
                        Container(width: 1, height: 62, color: colors.outlineVariant),
                        Expanded(
                          child: _SummaryMetric(
                            icon: Icons.speed_rounded,
                            label: 'سرعة النقل',
                            value: _formatSpeed(speed),
                            color: colors.onSurface,
                          ),
                        ),
                        Container(width: 1, height: 62, color: colors.outlineVariant),
                        Expanded(
                          child: _SummaryMetric(
                            icon: Icons.folder_copy_outlined,
                            label: 'الحجم الإجمالي',
                            value: _formatBytes(total),
                            color: colors.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          isReceiving ? 'الملفات الواردة' : 'الملفات قيد الإرسال',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text('${ids.length} ملف', style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                Expanded(
                  child: ids.isEmpty
                      ? const Center(child: Text('بانتظار بدء نقل الملفات...'))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                          itemCount: ids.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final id = ids[index];
                            final fileSent = (progressBytes[id] ?? 0).clamp(0, progressTotals[id] ?? 0);
                            final fileTotal = progressTotals[id] ?? 0;
                            final ratio = fileTotal <= 0 ? 0.0 : (fileSent / fileTotal).clamp(0.0, 1.0).toDouble();
                            final started = progressStartedAt[id];
                            final elapsed = started == null ? 0.0 : DateTime.now().difference(started).inMilliseconds / 1000;
                            final fileSpeed = elapsed > 0 ? fileSent / elapsed : 0.0;
                            final remaining = fileSpeed > 0 && fileTotal > fileSent
                                ? Duration(seconds: ((fileTotal - fileSent) / fileSpeed).ceil())
                                : null;
                            final file = completedFiles[id];
                            final completed = completedPayloads.contains(id) && file != null;
                            return Card(
                              color: colors.surfaceContainerLow,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 64,
                                      height: 72,
                                      decoration: BoxDecoration(
                                        color: colors.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(_fileIcon(progressNames[id] ?? ''), color: _transferRed, size: 34),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            progressNames[id] ?? 'ملف $id',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(_formatBytes(fileTotal), style: theme.textTheme.bodySmall),
                                          const SizedBox(height: 8),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(10),
                                            child: LinearProgressIndicator(
                                              minHeight: 8,
                                              value: ratio,
                                              color: _transferRed,
                                              backgroundColor: colors.surfaceContainerHighest,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            '${_formatBytes(fileSent)} / ${_formatBytes(fileTotal)} · ${(ratio * 100).round()}%',
                                            style: theme.textTheme.bodySmall,
                                          ),
                                          if (remaining != null && !completed)
                                            Text(
                                              'متبقٍ ${_formatDuration(remaining)} · ${_formatSpeed(fileSpeed)}',
                                              style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                                            ),
                                          if (completed)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 8),
                                              child: Align(
                                                alignment: AlignmentDirectional.centerStart,
                                                child: FilledButton.icon(
                                                  style: FilledButton.styleFrom(backgroundColor: _transferRed),
                                                  onPressed: () => onOpenFile(file),
                                                  icon: const Icon(Icons.play_arrow_rounded),
                                                  label: const Text('فتح في التطبيق'),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: _transferRed,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        onPressed: onAddMore,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('إرسال المزيد'),
                      ),
                    ),
                  ),
                ),
                if (allDone)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('اكتمل النقل. يمكنك فتح كل ملف أو إضافة ملفات أخرى.',
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.primary)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _transferRed, size: 24),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ],
        ),
      );
}

IconData _fileIcon(String name) {
  final ext = name.split('.').last.toLowerCase();
  if (['mp4', 'mkv', 'mov', 'webm', 'avi', '3gp'].contains(ext)) return Icons.movie_outlined;
  if (['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'].contains(ext)) return Icons.music_note_rounded;
  if (['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(ext)) return Icons.image_outlined;
  return Icons.insert_drive_file_outlined;
}

String _formatSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0 B/s';
  if (bytesPerSecond >= 1024 * 1024) return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  if (bytesPerSecond >= 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) return '${duration.inHours} س ${duration.inMinutes.remainder(60)} د';
  if (duration.inMinutes > 0) return '${duration.inMinutes} د ${duration.inSeconds.remainder(60)} ث';
  return '${duration.inSeconds} ث';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

class TransferFilePreviewScreen extends StatefulWidget {
  const TransferFilePreviewScreen({super.key, required this.file});

  final File file;

  @override
  State<TransferFilePreviewScreen> createState() => _TransferFilePreviewScreenState();
}

class _TransferFilePreviewScreenState extends State<TransferFilePreviewScreen> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  bool _ready = false;
  String? _error;

  String get _extension => widget.file.path.split('.').last.toLowerCase();
  bool get _isVideo => ['mp4', 'mkv', 'mov', 'webm', 'avi', '3gp'].contains(_extension);
  bool get _isAudio => ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'].contains(_extension);
  bool get _isImage => ['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(_extension);

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (_isVideo) {
        _video = VideoPlayerController.file(widget.file);
        await _video!.initialize();
        await _video!.setLooping(false);
      } else if (_isAudio) {
        _audio = AudioPlayer();
        await _audio!.setFilePath(widget.file.path);
      }
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() {
        _error = 'تعذر فتح الملف: $error';
        _ready = true;
      });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _audio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.file.uri.pathSegments.isEmpty
        ? widget.file.path.split(Platform.pathSeparator).last
        : widget.file.uri.pathSegments.last;
    final colors = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: Center(
          child: !_ready
              ? const CircularProgressIndicator(color: _transferRed)
              : _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
                  : _isVideo && _video != null
                      ? AspectRatio(
                          aspectRatio: _video!.value.aspectRatio > 0 ? _video!.value.aspectRatio : 16 / 9,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              VideoPlayer(_video!),
                              IconButton.filled(
                                style: IconButton.styleFrom(backgroundColor: _transferRed),
                                iconSize: 52,
                                onPressed: () {
                                  setState(() {
                                    _video!.value.isPlaying ? _video!.pause() : _video!.play();
                                  });
                                },
                                icon: Icon(_video!.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                              ),
                            ],
                          ),
                        )
                      : _isAudio && _audio != null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.music_note_rounded, color: colors.primary, size: 92),
                                const SizedBox(height: 16),
                                Text(title, textAlign: TextAlign.center),
                                const SizedBox(height: 20),
                                StreamBuilder<PlayerState>(
                                  stream: _audio!.playerStateStream,
                                  builder: (context, snapshot) {
                                    final playing = snapshot.data?.playing ?? false;
                                    return IconButton.filled(
                                      style: IconButton.styleFrom(backgroundColor: _transferRed),
                                      iconSize: 56,
                                      onPressed: () => playing ? _audio!.pause() : _audio!.play(),
                                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                    );
                                  },
                                ),
                              ],
                            )
                          : _isImage
                              ? InteractiveViewer(child: Image.file(widget.file, fit: BoxFit.contain))
                              : Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.insert_drive_file_outlined, size: 64, color: _transferRed),
                                      const SizedBox(height: 12),
                                      Text(title, textAlign: TextAlign.center),
                                      const SizedBox(height: 8),
                                      const Text('تم استلام الملف بنجاح. لا تتوفر معاينة داخل التطبيق لهذا النوع من الملفات.', textAlign: TextAlign.center),
                                    ],
                                  ),
                                ),
        ),
      ),
    );
  }
}
