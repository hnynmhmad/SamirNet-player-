import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

const _pickerRed = Color(0xFFEF4444);

/// Media-first selector for SM Player's direct offline transfer.
class TransferMediaPickerScreen extends StatefulWidget {
  const TransferMediaPickerScreen({super.key});

  @override
  State<TransferMediaPickerScreen> createState() => _TransferMediaPickerScreenState();
}

class _TransferMediaPickerScreenState extends State<TransferMediaPickerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final Map<String, AssetEntity> _selected = {};
  List<AssetEntity> _videos = [];
  List<AssetEntity> _audio = [];
  List<AssetPathEntity> _videoAlbums = [];
  AssetPathEntity? _openedAlbum;
  List<AssetEntity> _albumVideos = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)..addListener(() {
      if (mounted && !_tabs.indexIsChanging) setState(() {});
    });
    _loadMedia();
  }

  Future<List<AssetEntity>> _readAllInBatches(
    AssetPathEntity album, {
    void Function(List<AssetEntity> batch, bool hasMore)? onBatch,
  }) async {
    final total = await album.assetCountAsync;
    final all = <AssetEntity>[];
    const batchSize = 200;
    for (var start = 0; start < total; start += batchSize) {
      final end = start + batchSize < total ? start + batchSize : total;
      final batch = await album.getAssetListRange(start: start, end: end);
      if (batch.isEmpty) break;
      all.addAll(batch);
      onBatch?.call(batch, start + batch.length < total);
    }
    return all;
  }

  Future<void> _loadMedia() async {
    if (mounted) setState(() { _loading = true; _loadingMore = false; _error = null; });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        _error = 'اسمح للتطبيق بالوصول إلى الفيديوهات والموسيقى من إعدادات الأذونات.';
        return;
      }
      final videoAlbums = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        hasAll: true,
        onlyAll: false,
      );
      final audioAlbums = await PhotoManager.getAssetPathList(
        type: RequestType.audio,
        hasAll: true,
        onlyAll: false,
      );
      _videoAlbums = videoAlbums;
      _videos = [];
      _audio = [];
      if (mounted) setState(() { _loading = false; _loadingMore = true; });

      if (videoAlbums.isNotEmpty) {
        var firstBatch = true;
        await _readAllInBatches(videoAlbums.first, onBatch: (batch, hasMore) {
          if (!mounted) return;
          setState(() {
            if (firstBatch) {
              _videos = List<AssetEntity>.from(batch);
              firstBatch = false;
            } else {
              _videos.addAll(batch);
            }
            _loading = false;
            _loadingMore = hasMore || audioAlbums.isNotEmpty;
          });
        });
        _videos.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      }
      if (audioAlbums.isNotEmpty) {
        var firstBatch = true;
        await _readAllInBatches(audioAlbums.first, onBatch: (batch, hasMore) {
          if (!mounted) return;
          setState(() {
            if (firstBatch) {
              _audio = List<AssetEntity>.from(batch);
              firstBatch = false;
            } else {
              _audio.addAll(batch);
            }
            _loading = false;
            _loadingMore = hasMore;
          });
        });
        _audio.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      }
    } catch (e) {
      _error = 'تعذر تحميل الوسائط: $e';
    } finally {
      if (mounted) setState(() { _loading = false; _loadingMore = false; });
    }
  }

  Future<void> _openAlbum(AssetPathEntity album) async {
    setState(() { _loading = true; _loadingMore = false; _error = null; _openedAlbum = album; _albumVideos = []; });
    try {
      var firstBatch = true;
      await _readAllInBatches(album, onBatch: (batch, hasMore) {
        if (!mounted) return;
        setState(() {
          if (firstBatch) {
            _albumVideos = List<AssetEntity>.from(batch);
            firstBatch = false;
          } else {
            _albumVideos.addAll(batch);
          }
          _loading = false;
          _loadingMore = hasMore;
        });
      });
      _albumVideos.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
    } catch (e) {
      _error = 'تعذر فتح المجلد: $e';
    } finally {
      if (mounted) setState(() { _loading = false; _loadingMore = false; });
    }
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.containsKey(asset.id)) {
        _selected.remove(asset.id);
      } else {
        _selected[asset.id] = asset;
      }
    });
  }

  Future<void> _finish() async {
    if (_selected.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    final files = <File>[];
    try {
      for (final asset in _selected.values) {
        final file = await asset.file;
        if (file != null && await file.exists()) files.add(file);
      }
      if (!mounted) return;
      if (files.isEmpty) {
        setState(() { _loading = false; _error = 'تعذر الوصول إلى الملفات المحددة. تحقق من أذونات الوسائط.'; });
        return;
      }
      Navigator.pop(context, files);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تجهيز الملفات للإرسال: $e'; });
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('إرسال الملفات'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: _pickerRed,
          labelColor: _pickerRed,
          unselectedLabelColor: Colors.grey.shade700,
          tabs: const [
            Tab(icon: Icon(Icons.movie_creation_outlined), text: 'الفيديوهات'),
            Tab(icon: Icon(Icons.folder_outlined), text: 'المجلدات'),
            Tab(icon: Icon(Icons.music_note_rounded), text: 'الموسيقى'),
          ],
        ),
      ),
      body: Stack(children: [
        Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: const Color(0xFFFFEEEE),
            child: Row(children: [
              const Icon(Icons.swap_vert_rounded, color: _pickerRed, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text(
                _selected.isEmpty ? 'حدد الملفات التي تريد إرسالها' : 'تم تحديد ${_selected.length} ملف',
                style: const TextStyle(fontWeight: FontWeight.w700),
              )),
              if (_selected.isNotEmpty)
                TextButton(onPressed: () => setState(_selected.clear), child: const Text('مسح')),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: _pickerRed))),
          if (_loadingMore) const LinearProgressIndicator(color: _pickerRed),
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: _pickerRed))
            : TabBarView(controller: _tabs, children: [
                _assetList(_videos, empty: 'لا توجد فيديوهات متاحة.'),
                _folderList(),
                _assetList(_audio, empty: 'لا توجد ملفات موسيقى متاحة.'),
              ]),
          ),
        ]),
        if (_loading)
          const Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(color: _pickerRed)),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _pickerRed, foregroundColor: Colors.white),
              onPressed: _selected.isEmpty || _loading ? null : _finish,
              icon: const Icon(Icons.send_rounded),
              label: Text('إرسال (${_selected.length})'),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _folderList() {
    if (_openedAlbum != null) {
      return Column(children: [
        ListTile(
          leading: const Icon(Icons.arrow_forward, color: _pickerRed),
          title: Text(_openedAlbum!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${_albumVideos.length} فيديو'),
          onTap: () => setState(() => _openedAlbum = null),
          trailing: TextButton(onPressed: () {
            setState(() {
              for (final asset in _albumVideos) { _selected[asset.id] = asset; }
            });
          }, child: const Text('تحديد الكل')),
        ),
        const Divider(height: 1),
        Expanded(child: _assetList(_albumVideos, empty: 'هذا المجلد لا يحتوي على فيديوهات.')),
      ]);
    }
    final albums = _videoAlbums.where((a) => a.name.toLowerCase() != 'recent').toList();
    if (albums.isEmpty) return const Center(child: Text('لا توجد مجلدات فيديو.'));
    return ListView.separated(
      itemCount: albums.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 70),
      itemBuilder: (context, index) {
        final album = albums[index];
        return FutureBuilder<int>(
          future: album.assetCountAsync,
          builder: (context, snapshot) => ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0xFFFFEEEE), child: Icon(Icons.folder_rounded, color: _pickerRed)),
            title: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${snapshot.data ?? 0} فيديو'),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => _openAlbum(album),
            onLongPress: () async {
              setState(() { _loadingMore = true; _error = null; });
              try {
                final assets = await _readAllInBatches(album);
                if (!mounted) return;
                setState(() {
                  for (final asset in assets) { _selected[asset.id] = asset; }
                  _error = 'تم تحديد ${assets.length} فيديو من المجلد ${album.name}.';
                });
              } catch (e) {
                if (mounted) setState(() => _error = 'تعذر تحديد ملفات المجلد: $e');
              } finally {
                if (mounted) setState(() => _loadingMore = false);
              }
            },
          ),
        );
      },
    );
  }

  Widget _assetList(List<AssetEntity> assets, {required String empty}) {
    if (assets.isEmpty) return Center(child: Text(empty));
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: .72,
      ),
      itemCount: assets.length,
      itemBuilder: (context, index) {
        final asset = assets[index];
        final selected = _selected.containsKey(asset.id);
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _toggle(asset),
          onLongPress: () => _toggle(asset),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? _pickerRed : Colors.black12, width: selected ? 2 : 1),
              color: selected ? const Color(0xFFFFEEEE) : Theme.of(context).cardColor,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              Expanded(child: Stack(fit: StackFit.expand, children: [
                _assetThumbnail(asset),
                if (asset.type == AssetType.video)
                  const Positioned(left: 6, bottom: 6, child: Icon(Icons.play_circle_fill, color: Colors.white, size: 25)),
                Positioned(left: 6, top: 6, child: Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? _pickerRed : Colors.white, size: 24,
                )),
              ])),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  asset.title ?? (asset.type == AssetType.audio ? 'ملف صوتي' : 'فيديو'),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(_dateLabel(asset.createDateTime), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _assetThumbnail(AssetEntity asset) => FutureBuilder<Uint8List?>(
    future: asset.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) {
        return Container(
          color: const Color(0xFFF3F4F6),
          alignment: Alignment.center,
          child: Icon(asset.type == AssetType.audio ? Icons.music_note_rounded : Icons.movie_outlined, color: _pickerRed, size: 34),
        );
      }
      return Image.memory(bytes, fit: BoxFit.cover, width: double.infinity, height: double.infinity);
    },
  );

  String _dateLabel(DateTime date) => '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}
