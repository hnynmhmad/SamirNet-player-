import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'services/vault_service.dart';
import 'services/wifi_transfer_service.dart';

const coral = Color(0xFFEF4444);
const ink = Color(0xFF111827);

// Background audio is optional. Do not initialize its Android service during app startup:
// a service/notification configuration problem must never prevent the main UI from opening.
Future<AudioHandler>? _backgroundAudioHandlerFuture;

Future<AudioHandler> _getBackgroundAudioHandler() {
  return _backgroundAudioHandlerFuture ??= (() async {
    // Android 13+ may hide media notifications until notification permission is requested.
    try {
      await const MethodChannel('com.samirnet.snplayer/notifications').invokeMethod<bool>('requestPermission');
    } catch (error) {
      debugPrint('Notification permission request was unavailable: $error');
    }
    return AudioService.init(
      builder: () => SNBackgroundAudioHandler(),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.samirnet.player.audio',
        androidNotificationChannelName: 'SM Player · موسيقى وفيديو',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
  })();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep startup minimal and resilient; media permissions are requested after the UI appears.
  runApp(const SamirNetApp());
}

class SNBackgroundAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  SNBackgroundAudioHandler() {
    _player.positionStream.listen((position) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position,
        bufferedPosition: _player.bufferedPosition,
        playing: _player.playing,
        speed: _player.speed,
      ));
    });
    _player.playbackEventStream.listen((event) {
      final playing = _player.playing;
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
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
      if (index != null && index < queue.value.length) mediaItem.add(queue.value[index]);
    });
    _player.durationStream.listen((duration) {
      final current = mediaItem.value;
      if (duration != null && current != null) mediaItem.add(current.copyWith(duration: duration));
    });
  }
  Future<void> playFileInBackground(File file, String title, {Duration startPosition = Duration.zero}) async {
    await playQueueInBackground([file], [title], 0, startPosition: startPosition);
  }
  Future<void> playQueueInBackground(List<File> files, List<String> titles, int initialIndex, {Duration startPosition = Duration.zero}) async {
    if (files.isEmpty || files.length != titles.length) {
      throw ArgumentError('The music queue is empty or invalid');
    }
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
    // Do not await play(): just_audio completes this future when playback ends.
    // Awaiting it blocked the caller, leaving the video player audible at the same time.
    unawaited(_player.play());
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
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
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

class SamirNetApp extends StatefulWidget {
  const SamirNetApp({super.key});
  @override
  State<SamirNetApp> createState() => _SamirNetAppState();
}

class _SamirNetAppState extends State<SamirNetApp> {
  ThemeMode mode = ThemeMode.light;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString('theme') ?? 'light';
    if (!mounted) return;
    setState(() => mode = v == 'dark' ? ThemeMode.dark : ThemeMode.light);
  }
  Future<void> _setMode(ThemeMode value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('theme', value == ThemeMode.dark ? 'dark' : value == ThemeMode.light ? 'light' : 'system');
    if (mounted) setState(() => mode = value);
  }
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SM Player', debugShowCheckedModeBanner: false, locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    themeMode: mode,
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: coral), scaffoldBackgroundColor: const Color(0xFFF8FAFC), cardTheme: CardThemeData(elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Color(0xFFE5E7EB)))), appBarTheme: const AppBarTheme(centerTitle: false, scrolledUnderElevation: 0)),
    darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: ColorScheme.fromSeed(seedColor: coral, brightness: Brightness.dark), scaffoldBackgroundColor: ink, cardTheme: CardThemeData(elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)))),
    home: LibraryScreen(mode: mode, onMode: _setMode),
  );
}

class MediaEntry {
  MediaEntry(this.asset);
  final AssetEntity asset;
  String get id => asset.id;
  String get name => asset.title ?? 'فيديو بدون اسم';
  Duration get duration => Duration(seconds: asset.duration);
}

List<MediaEntry> _sortEntries(Iterable<MediaEntry> source, String sort) {
  final result = source.toList();
  result.sort((a, b) {
    switch (sort) {
      case 'nameAsc':
      case 'nameAZ': return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case 'nameDesc': return b.name.toLowerCase().compareTo(a.name.toLowerCase());
      case 'durationAsc': return a.duration.compareTo(b.duration);
      case 'durationDesc': return b.duration.compareTo(a.duration);
      case 'dateAsc': return a.asset.createDateTime.compareTo(b.asset.createDateTime);
      case 'dateDesc':
      default: return b.asset.createDateTime.compareTo(a.asset.createDateTime);
    }
  });
  return result;
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.mode, required this.onMode, super.key});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int tab = 0, filter = 0;
  bool loading = true, denied = false, grid = true, showAllVideos = false;
  Set<String> newMediaIds = {};
  Set<String> seenFolderPaths = {};
  String? scanError;
  String query = '';
  final search = TextEditingController();
  List<MediaEntry> videos = [];
  Set<String> favorites = {};
  List<String> history = [];
  bool foldersGrid = false;
  String videoSort = 'dateDesc';
  String backgroundMode = 'audio';
  @override
  void initState() {
    super.initState();
    _loadLocal();
    _scan();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestFirstRunPermissions());
  }
  Future<void> _requestFirstRunPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('first_run_notifications_requested') != true) {
      try {
        await const MethodChannel('com.samirnet.snplayer/notifications').invokeMethod<bool>('requestPermission');
      } catch (error) {
        debugPrint('Notification permission request failed: $error');
      }
      await prefs.setBool('first_run_notifications_requested', true);
    }
    if (prefs.getBool('first_run_all_files_prompted') != true && Platform.isAndroid) {
      try {
        await const MethodChannel('com.samirnet.snplayer/notifications').invokeMethod<bool>('requestAllFilesAccess');
      } catch (error) {
        debugPrint('All-files access settings unavailable: $error');
      }
      await prefs.setBool('first_run_all_files_prompted', true);
    }
  }
  @override
  void dispose() { search.dispose(); super.dispose(); }
  Future<void> _loadLocal() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { favorites = (p.getStringList('favorites') ?? []).toSet(); history = p.getStringList('history') ?? []; backgroundMode = p.getString('background_mode') ?? 'audio'; videoSort = p.getString('video_sort') ?? 'dateDesc'; grid = p.getBool('global_media_grid') ?? p.getBool('video_grid') ?? true; foldersGrid = p.getBool('global_media_grid') ?? p.getBool('folders_grid') ?? false; newMediaIds = (p.getStringList('new_media_ids') ?? []).toSet(); seenFolderPaths = (p.getStringList('seen_folder_paths') ?? []).toSet(); });
  }
  Future<void> _openPermissionSettings() async {
    try {
      await PhotoManager.openSetting();
    } catch (error) {
      if (mounted) _toast('تعذر فتح إعدادات الأذونات: $error');
    }
  }
  Future<void> _scan() async {
    if (mounted) setState(() { loading = true; denied = false; scanError = null; });
    try {
      final permission = await PhotoManager.requestPermissionExtend(requestOption: const PermissionRequestOption(androidPermission: AndroidPermission(type: RequestType.video, mediaLocation: false)));
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) setState(() { denied = true; loading = false; scanError = 'لم يمنح Android التطبيق صلاحية قراءة الفيديوهات. افتح إعدادات التطبيق ثم الأذونات وتأكد من السماح بالصور والفيديوهات.'; });
        return;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: true);
      final assets = <AssetEntity>[];
      if (paths.isNotEmpty) {
        final all = paths.first;
        final total = await all.assetCountAsync;
        for (var start = 0; start < total; start += 200) {
          assets.addAll(await all.getAssetListRange(start: start, end: (start + 200).clamp(0, total).toInt()));
        }
      }
      final prefs = await SharedPreferences.getInstance();
      final previousIds = (prefs.getStringList('known_media_ids') ?? []).toSet();
      final currentIds = assets.map((asset) => asset.id).toSet();
      final discovered = previousIds.isEmpty ? <String>{} : currentIds.difference(previousIds);
      final retainedNew = (prefs.getStringList('new_media_ids') ?? []).toSet().intersection(currentIds);
      retainedNew.addAll(discovered);
      await prefs.setStringList('known_media_ids', currentIds.toList());
      await prefs.setStringList('new_media_ids', retainedNew.toList());
      if (mounted) setState(() { videos = assets.map(MediaEntry.new).toList(); newMediaIds = retainedNew; loading = false; denied = false; scanError = null; });
    } catch (error, stack) {
      debugPrint('SamirNet media scan failed: $error\\n$stack');
      if (mounted) setState(() { loading = false; denied = false; scanError = 'تعذر فحص مكتبة الفيديوهات: $error'; });
    }
  }
  List<MediaEntry> get shown {
    Iterable<MediaEntry> list = videos;
    if (tab == 0 && !showAllVideos) list = history.map((id) => videos.where((v) => v.id == id).firstOrNull).whereType<MediaEntry>();
    if (tab == 2) list = list.where((v) => favorites.contains(v.id));
    if (tab == 3) list = history.map((id) => videos.where((v) => v.id == id).firstOrNull).whereType<MediaEntry>();
    if (filter == 1) list = list.where((v) => v.duration.inMinutes < 10);
    if (filter == 2) list = list.where((v) => v.duration.inMinutes >= 10);
    if (query.trim().isNotEmpty) list = list.where((v) => v.name.toLowerCase().contains(query.trim().toLowerCase()));
    return _sortEntries(list, videoSort);
  }
  Future<void> _favorite(MediaEntry v) async {
    setState(() { if (!favorites.add(v.id)) favorites.remove(v.id); });
    final p = await SharedPreferences.getInstance(); await p.setStringList('favorites', favorites.toList());
  }
  Future<void> _play(MediaEntry v) async {
    newMediaIds.remove(v.id);
    final p = await SharedPreferences.getInstance();
    await p.setStringList('new_media_ids', newMediaIds.toList());
    history.remove(v.id); history.insert(0, v.id); history = history.take(100).toList();
    await p.setStringList('history', history);
    if (!mounted) return;
    await _openPlayer(v, replace: false);
    if (mounted) setState(() {});
  }
  Future<void> _openPlayer(MediaEntry v, {required bool replace}) async {
    final file = await v.asset.file;
    if (file == null || !mounted) { _toast('تعذّر الوصول إلى الملف'); return; }
    final page = MaterialPageRoute(builder: (_) => PlayerScreen(entry: v, file: file, favorite: favorites.contains(v.id), playlist: _sortEntries(videos, videoSort), onFavorite: () => _favorite(v), onNavigate: (next) => _openPlayer(next, replace: true)));
    if (replace) { await Navigator.pushReplacement(context, page); } else { await Navigator.push(context, page); }
  }
  Future<void> _saveViewPreferences() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('video_grid', grid);
    await p.setBool('folders_grid', foldersGrid);
    await p.setBool('global_media_grid', grid);
    await p.setString('video_sort', videoSort);
  }
  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  @override
  Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(
    appBar: AppBar(title: const Row(children: [
      CircleAvatar(backgroundColor: coral, child: Icon(Icons.play_arrow_rounded, color: Colors.white)),
      SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SM Player', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('مشغّل الوسائط الخاص بك', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    ]), actions: [
      IconButton(tooltip: grid ? 'عرض كقائمة' : 'عرض كشبكة', onPressed: () { setState(() { grid = !grid; foldersGrid = grid; }); _saveViewPreferences(); }, icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded)),
      IconButton(tooltip: 'تحديث المكتبة', onPressed: _scan, icon: const Icon(Icons.refresh_rounded)),
      PopupMenuButton<String>(tooltip: 'ترتيب الفيديوهات', icon: const Icon(Icons.sort_rounded), onSelected: (v) async { setState(() => videoSort = v); await _saveViewPreferences(); }, itemBuilder: (_) => const [
        PopupMenuItem(value: 'dateDesc', child: Text('الأحدث أولًا')),
        PopupMenuItem(value: 'dateAsc', child: Text('الأقدم أولًا')),
        PopupMenuItem(value: 'nameAsc', child: Text('الاسم: أ إلى ي')),
        PopupMenuItem(value: 'nameDesc', child: Text('الاسم: ي إلى أ')),
        PopupMenuItem(value: 'durationDesc', child: Text('المدة: الأطول أولًا')),
        PopupMenuItem(value: 'durationAsc', child: Text('المدة: الأقصر أولًا')),
      ]),
      IconButton(tooltip: 'نقل عبر Wi-Fi', onPressed: () => _toast('ميزة نقل Wi-Fi ضمن مرحلة التطوير التالية'), icon: const Icon(Icons.wifi_rounded)),
    ]),
    body: tab == 4 ? _settings() : tab == 1 ? _folders() : _library(),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() { tab = v; if (v != 0) showAllVideos = false; }), destinations: const [
      NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library), label: 'الرئيسية'),
      NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: 'المجلدات'),
      NavigationDestination(icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: 'المفضلة'),
      NavigationDestination(icon: Icon(Icons.history), selectedIcon: Icon(Icons.history_rounded), label: 'السجل'),
      NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'الإعدادات'),
    ]),
  ));
  Widget _library() {
    final items = shown;
    return RefreshIndicator(onRefresh: _scan, child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(['الرئيسية', 'المجلدات', 'المفضلة', 'السجل'][tab], style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4), Text('${videos.length} فيديو على الجهاز', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        TextField(controller: search, onChanged: (v) => setState(() => query = v), decoration: InputDecoration(hintText: 'ابحث عن فيديو...', prefixIcon: const Icon(Icons.search), filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none))),
        const SizedBox(height: 12),
        if (tab != 0 || showAllVideos) ...[
          Row(children: [
            _chip('الكل', 0), const SizedBox(width: 8), _chip('قصيرة', 1), const SizedBox(width: 8), _chip('طويلة', 2), const Spacer(),
            IconButton.filledTonal(onPressed: () { setState(() => grid = !grid); _saveViewPreferences(); }, icon: Icon(grid ? Icons.view_list : Icons.grid_view)),
          ]),
          const SizedBox(height: 10),
        ],
        if (tab == 0) ...[
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: _homeShortcut(Icons.video_library_rounded, 'الفيديوهات', coral, () { Navigator.push(context, MaterialPageRoute(builder: (_) => VideosLibraryScreen(entries: videos, initialFavorites: favorites, onPlay: _play, onFavorite: _favorite, onDeleted: _scan))); })),
            const SizedBox(width: 10),
            Expanded(child: _homeShortcut(Icons.music_note_rounded, 'الصوتيات', const Color(0xFF3979D5), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AudioLibraryScreen())))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _homeShortcut(Icons.folder_rounded, 'المجلدات', const Color(0xFFFF9800), () => setState(() => tab = 1))),
            const SizedBox(width: 10),
            Expanded(child: _homeShortcut(Icons.favorite_rounded, 'المفضلة', const Color(0xFFE84C8A), () => setState(() => tab = 2))),
          ]),
          const SizedBox(height: 16),
          Text(showAllVideos ? 'كل الفيديوهات' : 'متابعة المشاهدة', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        ] else if (tab == 2) const Text('المفضلة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold))
        else if (tab == 3) const Text('سجل المشاهدة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ]))),
      if (loading) const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: coral)))
      else if (denied) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.perm_media_outlined, 'نحتاج إلى إذن الوصول للوسائط', scanError ?? 'اسمح بالوصول إلى الصور والفيديوهات من إعدادات التطبيق، ثم ارجع واضغط إعادة المحاولة.', 'فتح إعدادات الأذونات', _openPermissionSettings))
      else if (scanError != null) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.error_outline, 'تعذر تحميل مكتبة الوسائط', scanError!, 'إعادة المحاولة', _scan))
      else if (items.isEmpty && tab == 0 && history.isNotEmpty) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.play_circle_outline, 'ابدأ المشاهدة', 'ستظهر الفيديوهات التي شاهدتها مؤخرًا هنا.', 'تحديث المكتبة', _scan))
      else if (items.isEmpty) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.video_library_outlined, query.isNotEmpty ? 'لا توجد نتائج' : tab == 2 ? 'لا توجد فيديوهات مفضلة' : tab == 3 ? 'سجل المشاهدة فارغ' : 'لم نعثر على فيديوهات', 'يمكنك تحديث مكتبة الوسائط أو تغيير الفلتر.', 'تحديث المكتبة', _scan))
      else if (grid) SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverGrid(delegate: SliverChildBuilderDelegate((context, i) => _videoCard(items[i], true), childCount: items.length), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: .78)))
      else SliverPadding(padding: const EdgeInsets.all(16), sliver: SliverList(delegate: SliverChildBuilderDelegate((context, i) => Padding(padding: const EdgeInsets.only(bottom: 8), child: _videoCard(items[i], false)), childCount: items.length))),
    ]));
  }
  Widget _homeShortcut(IconData icon, String label, Color color, VoidCallback onTap) => Material(color: color.withValues(alpha: .16), borderRadius: BorderRadius.circular(14), child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, color: color), const SizedBox(width: 8), Text(label, style: const TextStyle(fontWeight: FontWeight.bold))]))));
  Widget _chip(String label, int value) => ChoiceChip(label: Text(label), selected: filter == value, onSelected: (_) => setState(() => filter = value), selectedColor: coral.withValues(alpha: .15));
  Widget _videoCard(MediaEntry v, bool asGrid) {
    final thumb = v.asset.thumbnailDataWithSize(const ThumbnailSize(480, 320));
    final duration = _format(v.duration);
    return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: () => _play(v), child: asGrid
      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: Stack(fit: StackFit.expand, children: [
            FutureBuilder<Uint8List?>(future: thumb, builder: (_, s) => s.data == null ? const ColoredBox(color: Colors.black12, child: Icon(Icons.movie_outlined, size: 40)) : Image.memory(s.data!, fit: BoxFit.cover)),
            Positioned(bottom: 7, left: 7, child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)), child: Text(duration, style: const TextStyle(color: Colors.white, fontSize: 11)))),
            Positioned(top: 2, left: 2, child: IconButton(onPressed: () => _favorite(v), icon: Icon(favorites.contains(v.id) ? Icons.favorite : Icons.favorite_border, color: favorites.contains(v.id) ? coral : Colors.white))),
            const Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 40)),
            if (newMediaIds.contains(v.id)) Positioned(top: 7, right: 7, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), decoration: BoxDecoration(color: coral, borderRadius: BorderRadius.circular(5)), child: const Text('NEW', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900)))),
          ])),
          Padding(padding: const EdgeInsets.all(10), child: Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        ])
      : ListTile(leading: SizedBox(width: 86, height: 64, child: FutureBuilder<Uint8List?>(future: thumb, builder: (_, s) => s.data == null ? const Icon(Icons.movie) : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(s.data!, fit: BoxFit.cover)))), title: Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text(newMediaIds.contains(v.id) ? 'NEW · $duration' : duration, style: TextStyle(color: newMediaIds.contains(v.id) ? coral : null, fontWeight: newMediaIds.contains(v.id) ? FontWeight.bold : null)), trailing: IconButton(onPressed: () => _favorite(v), icon: Icon(favorites.contains(v.id) ? Icons.favorite : Icons.favorite_border, color: coral)))));
  }
  Future<void> _openFolder(String path, List<MediaEntry> entries) async {
    seenFolderPaths.add(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('seen_folder_paths', seenFolderPaths.toList());
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => FolderVideosScreen(title: _folderLabel(path), entries: entries, onPlay: _play, isFavorite: (v) => favorites.contains(v.id), onFavorite: _favorite)));
    if (mounted) setState(() {});
  }
  Widget _folders() {
    final groups = <String, List<MediaEntry>>{};
    for (final v in videos) {
      final raw = (v.asset.relativePath ?? '').replaceAll('\\\\', '/').replaceAll(RegExp(r'/+$'), '');
      groups.putIfAbsent(raw.isEmpty ? '__root__' : raw, () => []).add(v);
    }
    final entries = groups.entries.toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Row(children: [
        const Expanded(child: Text('المجلدات', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800))),
        IconButton(tooltip: foldersGrid ? 'عرض كقائمة' : 'عرض كشبكة', onPressed: () { setState(() => foldersGrid = !foldersGrid); _saveViewPreferences(); }, icon: Icon(foldersGrid ? Icons.view_list : Icons.grid_view)),
      ])),
      Expanded(child: entries.isEmpty ? const Center(child: Text('لا توجد مجلدات فيديو متاحة')) : foldersGrid
        ? GridView.builder(padding: const EdgeInsets.all(12), itemCount: entries.length, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.35, crossAxisSpacing: 10, mainAxisSpacing: 10), itemBuilder: (context, i) {
            final e = entries[i];
            return Card(child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => _openFolder(e.key, e.value), child: Padding(padding: const EdgeInsets.all(12), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.folder_rounded, color: coral, size: 34), const SizedBox(height: 8), Text(_folderLabel(e.key) + (e.value.any((v) => newMediaIds.contains(v.id)) && !seenFolderPaths.contains(e.key) ? ' · NEW' : ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)), Text('${e.value.length} فيديو', style: const TextStyle(color: Colors.grey))]))));
          })
        : ListView.builder(padding: const EdgeInsets.all(12), itemCount: entries.length, itemBuilder: (context, i) {
            final e = entries[i];
            return Card(child: ListTile(leading: const Icon(Icons.folder_rounded, color: coral), title: Text(_folderLabel(e.key), maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('${e.value.length} فيديو'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FolderVideosScreen(title: e.key, entries: e.value, onPlay: _play, isFavorite: (v) => favorites.contains(v.id), onFavorite: _favorite)))));
          })),
    ]);
  }
  Widget _settings() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('الإعدادات', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
    const SizedBox(height: 12),
    Card(child: Column(children: [
      const ListTile(leading: Icon(Icons.play_circle_outline, color: coral), title: Text('التشغيل خارج التطبيق', style: TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('اختر طريقة التشغيل بالخلفية')),
      RadioListTile<String>(value: 'audio', groupValue: backgroundMode, onChanged: (v) async { if (v == null) return; final p = await SharedPreferences.getInstance(); await p.setString('background_mode', v); if (mounted) setState(() => backgroundMode = v); }, title: const Text('الصوت فقط في الخلفية'), subtitle: const Text('إشعار للتحكم بالصوت')),
      RadioListTile<String>(value: 'pip', groupValue: backgroundMode, onChanged: (v) async { if (v == null) return; final p = await SharedPreferences.getInstance(); await p.setString('background_mode', v); if (mounted) setState(() => backgroundMode = v); }, title: const Text('فيديو في نافذة عائمة'), subtitle: const Text('Picture-in-Picture من Android')),
    ])),
    const SizedBox(height: 12),
    Card(child: Column(children: [
      const ListTile(leading: Icon(Icons.palette_outlined), title: Text('المظهر', style: TextStyle(fontWeight: FontWeight.bold))),
      RadioListTile<ThemeMode>(title: const Text('اتباع مظهر النظام'), value: ThemeMode.system, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      RadioListTile<ThemeMode>(title: const Text('الوضع الفاتح'), value: ThemeMode.light, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      RadioListTile<ThemeMode>(title: const Text('الوضع الداكن'), value: ThemeMode.dark, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      SwitchListTile(value: grid, onChanged: (v) { setState(() => grid = v); _saveViewPreferences(); }, title: const Text('عرض الشبكة'), subtitle: const Text('إيقاف الخيار يعرض الملفات في قائمة')),
      ListTile(leading: const Icon(Icons.refresh), title: const Text('تحديث مكتبة الوسائط'), onTap: _scan),
      ListTile(leading: const Icon(Icons.lock_outline, color: coral), title: const Text('الخزنة الخاصة'), subtitle: const Text('تشفير ملفاتك وحمايتها برقم سري'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultScreen()))),
      ListTile(leading: const Icon(Icons.wifi, color: coral), title: const Text('نقل عبر Wi-Fi'), subtitle: const Text('استقبال ملفات من جهاز آخر على الشبكة نفسها'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WifiTransferScreen()))),
    ])),
    const SizedBox(height: 20), const Center(child: Text('SM Player · 0.1.0', style: TextStyle(color: Colors.grey))),
  ]);
  Widget _empty(IconData icon, String title, String subtitle, String action, VoidCallback onTap) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Icon(icon, size: 60, color: coral), const SizedBox(height: 16), Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)), const SizedBox(height: 16), FilledButton.icon(onPressed: onTap, icon: const Icon(Icons.refresh), label: Text(action)),
  ])));
  String _format(Duration d) { final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2, '0'); final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return h > 0 ? '$h:$m:$s' : '$m:$s'; }
}



class VideosLibraryScreen extends StatefulWidget {
  const VideosLibraryScreen({required this.entries, required this.initialFavorites, required this.onPlay, required this.onFavorite, required this.onDeleted, super.key});
  final List<MediaEntry> entries;
  final Set<String> initialFavorites;
  final ValueChanged<MediaEntry> onPlay;
  final ValueChanged<MediaEntry> onFavorite;
  final VoidCallback onDeleted;
  @override
  State<VideosLibraryScreen> createState() => _VideosLibraryScreenState();
}
class _VideosLibraryScreenState extends State<VideosLibraryScreen> {
  bool grid = true, selecting = false;
  String sort = 'dateDesc';
  @override
  void initState() { super.initState(); _loadViewPrefs(); }
  Future<void> _loadViewPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { sort = p.getString('video_sort') ?? 'dateDesc'; grid = p.getBool('global_media_grid') ?? p.getBool('video_grid') ?? true; });
  }
  Future<void> _saveViewPrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('video_sort', sort);
    await p.setBool('video_grid', grid);
    await p.setBool('global_media_grid', grid);
  }
  final Set<String> selected = {};
  List<MediaEntry> get sorted {
    return _sortEntries(widget.entries, sort);
  }
  Future<void> _shareExternal() async {
    final files = <XFile>[];
    try {
      for (final entry in sorted.where((v) => selected.contains(v.id))) {
        final file = await entry.asset.file;
        if (file != null) files.add(XFile(file.path, name: entry.name));
      }
      if (files.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الوصول إلى الملفات المحددة')));
        return;
      }
      await Share.shareXFiles(files, text: 'مشاركة من SM Player');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم فتح المشاركة لـ ${files.length} ملف')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذرت مشاركة الملفات: $e')));
    }
  }
  void _toggleSelect(MediaEntry e) => setState(() {
    if (!selected.add(e.id)) selected.remove(e.id);
    selecting = selected.isNotEmpty;
  });
  Future<void> _deleteSelected() async {
    if (selected.isEmpty) return;
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('تأكيد حذف الفيديوهات'),
      content: Text('هل تريد طلب حذف ${selected.length} فيديو من الهاتف؟ قد يعرض Android تأكيدًا إضافيًا.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف'))],
    ));
    if (confirm != true || !mounted) return;
    try {
      final ids = sorted.where((v) => selected.contains(v.id)).map((v) => v.id).toList();
      final deleted = await PhotoManager.editor.deleteWithIds(ids);
      if (!mounted) return;
      setState(() { selected.clear(); selecting = false; });
      widget.onDeleted();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم طلب حذف ${deleted.length} فيديو')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر حذف الملفات: $e'))); }
  }
  @override
  Widget build(BuildContext context) {
    final items = sorted;
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(selecting ? 'تم تحديد ${selected.length} فيديو' : 'كل الفيديوهات'), actions: [
        if (selecting) IconButton(tooltip: 'مشاركة مع التطبيقات', onPressed: _shareExternal, icon: const Icon(Icons.share)),
        if (selecting) IconButton(tooltip: 'حذف المحدد', onPressed: _deleteSelected, icon: const Icon(Icons.delete_outline)),
        if (selecting) IconButton(tooltip: 'إرسال عبر SM Player', onPressed: () {
          final files = items.where((v) => selected.contains(v.id)).toList();
          Navigator.push(context, MaterialPageRoute(builder: (_) => InternalSendScreen(entries: files)));
        }, icon: const Icon(Icons.send_rounded)),
        IconButton(tooltip: 'تغيير العرض', onPressed: () { setState(() => grid = !grid); _saveViewPrefs(); }, icon: Icon(grid ? Icons.view_list : Icons.grid_view)),
        PopupMenuButton<String>(tooltip: 'ترتيب الفيديوهات', icon: const Icon(Icons.sort), onSelected: (v) { setState(() => sort = v); _saveViewPrefs(); }, itemBuilder: (_) => const [
          PopupMenuItem(value: 'nameAsc', child: Text('الاسم: أ إلى ي')),
          PopupMenuItem(value: 'nameDesc', child: Text('الاسم: ي إلى أ')),
          PopupMenuItem(value: 'nameAZ', child: Text('الاسم: A إلى Z')),
          PopupMenuItem(value: 'dateDesc', child: Text('الأحدث أولًا')),
          PopupMenuItem(value: 'dateAsc', child: Text('الأقدم أولًا')),
          PopupMenuItem(value: 'durationDesc', child: Text('المدة: الأطول أولًا')),
          PopupMenuItem(value: 'durationAsc', child: Text('المدة: الأقصر أولًا')),
        ]),
      ]),
      body: items.isEmpty ? const Center(child: Text('لا توجد فيديوهات')) : grid
        ? GridView.builder(padding: const EdgeInsets.all(12), itemCount: items.length, gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: .78), itemBuilder: (_,i) {
            final e=items[i]; final picked=selected.contains(e.id);
            return Card(clipBehavior: Clip.antiAlias, child: InkWell(onTap: () { if (selecting) { _toggleSelect(e); } else { widget.onPlay(e); } }, onLongPress: () => _toggleSelect(e), child: Column(children: [
              Expanded(child: Stack(fit: StackFit.expand, children: [
                FutureBuilder<Uint8List?>(future: e.asset.thumbnailDataWithSize(const ThumbnailSize(480,320)), builder: (_,s) => s.data == null ? const ColoredBox(color: Colors.black12, child: Icon(Icons.movie, size: 40)) : Image.memory(s.data!, fit: BoxFit.cover)),
                if (selecting) Positioned(top: 4,right:4,child: Icon(picked ? Icons.check_circle : Icons.radio_button_unchecked,color: picked ? coral : Colors.white,size:28)),
                Positioned(bottom:5,left:5,child: Container(padding: const EdgeInsets.all(4), color: Colors.black87, child: Text(_formatDuration(e.duration),style: const TextStyle(color:Colors.white,fontSize:11)))),
              ])),
              Padding(padding: const EdgeInsets.all(8), child: Text(e.name,maxLines:2,overflow:TextOverflow.ellipsis)),
            ])));
          })
        : ListView.builder(padding: const EdgeInsets.all(12), itemCount: items.length, itemBuilder: (_,i) {
            final e=items[i]; final picked=selected.contains(e.id);
            return Card(child: ListTile(onLongPress: () => _toggleSelect(e), onTap: () { if (selecting) { _toggleSelect(e); } else { widget.onPlay(e); } }, leading: SizedBox(width:80,height:60,child: FutureBuilder<Uint8List?>(future:e.asset.thumbnailDataWithSize(const ThumbnailSize(160,120)),builder:(_,s)=>s.data==null?const Icon(Icons.movie):Image.memory(s.data!,fit:BoxFit.cover))),title: Text(e.name,maxLines:2,overflow:TextOverflow.ellipsis),subtitle: Text(_formatDuration(e.duration)),trailing: selecting ? Icon(picked?Icons.check_circle:Icons.radio_button_unchecked,color:coral) : const Icon(Icons.play_arrow)));
          }),
    ));
  }
}

class AudioLibraryScreen extends StatefulWidget {
  const AudioLibraryScreen({super.key});
  @override
  State<AudioLibraryScreen> createState() => _AudioLibraryScreenState();
}
class _AudioLibraryScreenState extends State<AudioLibraryScreen> {
  bool loading = true, showAll = false, musicPlaying = false;
  String? error, selectedFolder, currentTitle;
  List<MediaEntry> audio = [];
  AudioHandler? _handler;
  StreamSubscription<MediaItem?>? _itemSub;
  StreamSubscription<PlaybackState>? _stateSub;

  @override
  void initState() { super.initState(); _load(); _watchPlayer(); }
  @override
  void dispose() { _itemSub?.cancel(); _stateSub?.cancel(); super.dispose(); }

  Future<void> _watchPlayer() async {
    try {
      final handler = await _getBackgroundAudioHandler();
      if (!mounted) return;
      _handler = handler;
      currentTitle = handler.mediaItem.value?.title;
      musicPlaying = handler.playbackState.value.playing;
      _itemSub = handler.mediaItem.listen((item) {
        if (mounted) setState(() => currentTitle = item?.title);
      });
      _stateSub = handler.playbackState.listen((state) {
        if (mounted) setState(() => musicPlaying = state.playing);
      });
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Music handler initialization deferred: $e');
    }
  }
  Future<void> _load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final permission = await PhotoManager.requestPermissionExtend(requestOption: const PermissionRequestOption(androidPermission: AndroidPermission(type: RequestType.audio, mediaLocation: false)));
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) setState(() => error = 'اسمح بالوصول إلى الوسائط من إعدادات Android.');
        return;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.audio, onlyAll: true);
      final assets = <AssetEntity>[];
      if (paths.isNotEmpty) {
        final all = paths.first;
        final total = await all.assetCountAsync;
        for (var start = 0; start < total; start += 200) {
          assets.addAll(await all.getAssetListRange(start: start, end: (start + 200).clamp(0, total).toInt()));
        }
      }
      if (mounted) setState(() { audio = assets.map(MediaEntry.new).toList(); selectedFolder = null; });
    } catch (e) { if (mounted) setState(() => error = 'تعذر تحميل الصوتيات: $e'); }
    finally { if (mounted) setState(() => loading = false); }
  }
  Map<String, List<MediaEntry>> get folders {
    final result = <String, List<MediaEntry>>{};
    for (final item in audio) {
      final raw = (item.asset.relativePath ?? '').replaceAll('\\\\', '/').replaceAll(RegExp(r'/+$'), '');
      final name = parts.isEmpty ? 'المجلد الرئيسي' : parts.last;
      result.putIfAbsent(raw.isEmpty ? '__root__' : raw, () => []).add(item);
    }
    return result;
  }
  Future<void> _openMusicPlayer(List<MediaEntry> source, int selected) async {
    final files = <File>[];
    final titles = <String>[];
    var target = 0;
    for (var i = 0; i < source.length; i++) {
      final file = await source[i].asset.file;
      if (file == null) continue;
      if (i == selected) target = files.length;
      files.add(file);
      titles.add(source[i].name);
    }
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر الوصول إلى ملفات الموسيقى')));
      return;
    }
    try {
      final handler = _handler ?? await _getBackgroundAudioHandler();
      _handler = handler;
      await (handler as SNBackgroundAudioHandler).playQueueInBackground(files, titles, target);
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayerScreen(files: files, titles: titles, initialIndex: target, handler: handler)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تشغيل الموسيقى: $e')));
    }
  }
  Widget _miniPlayer() {
    final handler = _handler;
    if (handler == null || currentTitle == null) return const SizedBox.shrink();
    return SafeArea(top: false, child: Material(
      color: const Color(0xFF191919),
      child: InkWell(
        onTap: () {
          final items = handler.queue.value;
          if (items.isEmpty) return;
          final files = items.map((e) => File(e.id)).toList();
          final titles = items.map((e) => e.title).toList();
          final index = handler.playbackState.value.queueIndex ?? 0;
          Navigator.push(context, MaterialPageRoute(builder: (_) => MusicPlayerScreen(files: files, titles: titles, initialIndex: index, handler: handler)));
        },
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Row(children: [
          const CircleAvatar(backgroundColor: coral, child: Icon(Icons.music_note, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(child: Text(currentTitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
          IconButton(color: Colors.white, tooltip: musicPlaying ? 'إيقاف مؤقت' : 'متابعة', onPressed: () => musicPlaying ? handler.pause() : handler.play(), icon: Icon(musicPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded)),
          IconButton(color: Colors.white, tooltip: 'التالي', onPressed: () => handler.skipToNext(), icon: const Icon(Icons.skip_next_rounded)),
        ])),
      ),
    ));
  }
  @override
  Widget build(BuildContext context) {
    final groups = folders;
    final items = selectedFolder == null ? audio : (groups[selectedFolder] ?? <MediaEntry>[]);
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: Text(selectedFolder ?? 'الصوتيات'), actions: [
        IconButton(tooltip: 'تحديث الصوتيات', onPressed: _load, icon: const Icon(Icons.refresh)),
        if (selectedFolder != null) IconButton(tooltip: 'رجوع للمجلدات', onPressed: () => setState(() => selectedFolder = null), icon: const Icon(Icons.folder)),
      ]),
      bottomNavigationBar: _miniPlayer(),
      body: loading ? const Center(child: CircularProgressIndicator())
        : error != null ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!, textAlign: TextAlign.center), const SizedBox(height: 12), FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة'))])))
        : audio.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.music_off, size: 56, color: coral), const SizedBox(height: 12), const Text('لم يتم العثور على ملفات صوتية'), const SizedBox(height: 8), const Text('تأكد من منح إذن الصوتيات ثم اضغط تحديث.', textAlign: TextAlign.center), const SizedBox(height: 12), FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('تحديث المكتبة'))])))
        : selectedFolder == null && !showAll ? Column(children: [
            Padding(padding: const EdgeInsets.all(12), child: Row(children: [Expanded(child: Text('${audio.length} ملف صوتي · ${groups.length} مجلد')), TextButton.icon(onPressed: () => setState(() => showAll = true), icon: const Icon(Icons.library_music), label: const Text('عرض الكل'))])),
            Expanded(child: ListView.builder(itemCount: groups.length, itemBuilder: (context, i) {
              final entry = groups.entries.elementAt(i);
              return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(leading: const CircleAvatar(child: Icon(Icons.folder, color: Color(0xFF3979D5))), title: Text(entry.key), subtitle: Text('${entry.value.length} ملف صوتي'), trailing: const Icon(Icons.chevron_left), onTap: () => setState(() => selectedFolder = entry.key)));
            })),
          ])
        : Column(children: [
            if (selectedFolder == null) Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => setState(() => showAll = false), icon: const Icon(Icons.folder), label: const Text('عرض المجلدات'))),
            Expanded(child: ListView.builder(itemCount: items.length, itemBuilder: (context, i) {
              final e = items[i];
              return ListTile(
                leading: const CircleAvatar(backgroundColor: Color(0xFF252525), child: Icon(Icons.album_rounded, color: Color(0xFFEF4444))),
                title: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(_formatDuration(e.duration)),
                trailing: const Icon(Icons.play_circle_fill_rounded, color: coral, size: 30),
                onTap: () => _openMusicPlayer(items, i),
              );
            })),
          ]),
    ));
  }
}

class AudioStudioScreen extends StatefulWidget {
  const AudioStudioScreen({required this.handler, super.key});
  final AudioHandler handler;
  @override
  State<AudioStudioScreen> createState() => _AudioStudioScreenState();
}

class _AudioStudioScreenState extends State<AudioStudioScreen> {
  bool loading = true;
  bool enabled = false;
  bool equalizerAvailable = true;
  String? error;
  double minDb = -15, maxDb = 15, speed = 1;
  List<double> gains = [];
  List<double> frequencies = [];

  @override
  void initState() {
    super.initState();
    speed = widget.handler.playbackState.value.speed.clamp(.5, 2.0).toDouble();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    speed = (prefs.getDouble('music_speed_v1') ?? speed).clamp(.5, 2.0).toDouble();
    try {
      final raw = await widget.handler.customAction('getEqualizerParameters') as Map?;
      if (raw == null) throw StateError('لم تصل إعدادات المعادل');
      final bands = (raw['bands'] as List? ?? const []).cast<Map>();
      minDb = (raw['minDecibels'] as num?)?.toDouble() ?? -15;
      maxDb = (raw['maxDecibels'] as num?)?.toDouble() ?? 15;
      frequencies = bands.map((b) => (b['centerFrequency'] as num).toDouble()).toList();
      final saved = prefs.getStringList('music_eq_gains_v1') ?? [];
      gains = List<double>.generate(bands.length, (i) => i < saved.length
          ? (double.tryParse(saved[i]) ?? (bands[i]['gain'] as num).toDouble()).clamp(minDb, maxDb).toDouble()
          : (bands[i]['gain'] as num).toDouble());
      enabled = prefs.getBool('music_eq_enabled_v1') ?? false;
      await widget.handler.customAction('setEqualizerEnabled', {'enabled': enabled});
      for (var i = 0; i < saved.length && i < gains.length; i++) {
        await widget.handler.customAction('setEqualizerBandGain', {'index': i, 'gain': gains[i]});
      }
    } catch (_) {
      // Some Android devices cannot create a native Equalizer instance. Keep playback and speed controls available.
      equalizerAvailable = false;
      enabled = false;
    }
    try { await widget.handler.customAction('setMusicSpeed', {'speed': speed}); } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _toggle(bool value) async {
    await widget.handler.customAction('setEqualizerEnabled', {'enabled': value});
    final p = await SharedPreferences.getInstance();
    await p.setBool('music_eq_enabled_v1', value);
    if (mounted) setState(() => enabled = value);
  }

  Future<void> _gain(int index, double value) async {
    setState(() => gains[index] = value);
    await widget.handler.customAction('setEqualizerBandGain', {'index': index, 'gain': value});
    final p = await SharedPreferences.getInstance();
    await p.setStringList('music_eq_gains_v1', gains.map((v) => v.toString()).toList());
  }

  Future<void> _preset(String mode) async {
    final values = frequencies.map((hz) {
      if (mode == 'bass') return hz < 250 ? 5.0 : hz >= 4000 ? 2.0 : 0.0;
      if (mode == 'soft') return hz < 250 ? 1.5 : hz >= 4000 ? -2.0 : -1.0;
      if (mode == 'clear') return hz < 250 ? -1.0 : hz >= 4000 ? 4.0 : 2.0;
      return 0.0;
    }).map((v) => v.clamp(minDb, maxDb).toDouble()).toList();
    for (var i = 0; i < values.length; i++) {
      await widget.handler.customAction('setEqualizerBandGain', {'index': i, 'gain': values[i]});
    }
    final p = await SharedPreferences.getInstance();
    await p.setStringList('music_eq_gains_v1', values.map((v) => v.toString()).toList());
    if (mounted) setState(() => gains = values);
  }

  Future<void> _speed(double value) async {
    setState(() => speed = value);
    final p = await SharedPreferences.getInstance();
    await p.setDouble('music_speed_v1', value);
    await widget.handler.customAction('setMusicSpeed', {'speed': value});
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      backgroundColor: const Color(0xFF090909),
      appBar: AppBar(backgroundColor: const Color(0xFF090909), foregroundColor: Colors.white, title: const Text('استوديو الصوت')),
      body: loading ? const Center(child: CircularProgressIndicator(color: coral))
        : ListView(padding: const EdgeInsets.all(16), children: [
          if (!equalizerAvailable) const Padding(padding: EdgeInsets.only(bottom: 12), child: Text('المعادل الصوتي غير متاح على هذا الجهاز؛ بقي التحكم بسرعة الموسيقى متاحًا.', style: TextStyle(color: Colors.orangeAccent))),
          if (equalizerAvailable) Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF191919), borderRadius: BorderRadius.circular(20), border: Border.all(color: coral.withOpacity(.5))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [Icon(Icons.graphic_eq, color: coral, size: 30), SizedBox(width: 10), Text('المعادل الصوتي', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))]),
              const SizedBox(height: 6),
              const Text('تحكم بالجهير والنعومة والوضوح للموسيقى.', style: TextStyle(color: Colors.white70)),
              SwitchListTile(contentPadding: EdgeInsets.zero, activeColor: coral, title: const Text('تفعيل المعادل', style: TextStyle(color: Colors.white)), value: enabled, onChanged: _toggle),
              const Divider(color: Colors.white12),
              const Text('أنماط سريعة', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              Wrap(spacing: 6, children: [
                _presetButton('متوازن', 'flat'),
                _presetButton('جهير قوي', 'bass'),
                _presetButton('ناعم', 'soft'),
                _presetButton('أوضح', 'clear'),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          if (equalizerAvailable) Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF191919), borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('الترددات يدويًا', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              Text('من ${minDb.toStringAsFixed(0)} إلى ${maxDb.toStringAsFixed(0)} dB', style: const TextStyle(color: Colors.white60)),
              for (var i = 0; i < gains.length; i++) ...[
                Row(children: [
                  Expanded(child: Text(frequencies[i] >= 1000 ? '${(frequencies[i] / 1000).toStringAsFixed(1)} kHz' : '${frequencies[i].round()} Hz', style: const TextStyle(color: Colors.white))),
                  Text('${gains[i].toStringAsFixed(1)} dB', style: const TextStyle(color: coral)),
                ]),
                Slider(min: minDb, max: maxDb, value: gains[i].clamp(minDb, maxDb).toDouble(), activeColor: coral, onChanged: enabled ? (v) => _gain(i, v) : null),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFF191919), borderRadius: BorderRadius.circular(20)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('سرعة الموسيقى', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              Text('${speed.toStringAsFixed(2)}×', style: const TextStyle(color: coral, fontSize: 28, fontWeight: FontWeight.bold)),
              Slider(min: .5, max: 2, divisions: 15, value: speed, activeColor: coral, onChanged: _speed),
            ]),
          ),
          const SizedBox(height: 12),
          const Text('هذه الإعدادات للموسيقى فقط؛ الفيديو لا يتأثر بها.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
        ]),
    ),
  );

  Widget _presetButton(String label, String value) => OutlinedButton(
    onPressed: () => _preset(value),
    style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: BorderSide(color: value == 'flat' ? coral : Colors.white24)),
    child: Text(label),
  );
}

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({required this.files, required this.titles, required this.initialIndex, required this.handler, super.key});
  final List<File> files;
  final List<String> titles;
  final int initialIndex;
  final AudioHandler handler;
  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}
class _MusicPlayerScreenState extends State<MusicPlayerScreen> with SingleTickerProviderStateMixin {
  bool _shuffle = false, _repeat = false;
  double? _dragPosition;
  StreamSubscription<MediaItem?>? _mediaSub;
  StreamSubscription<PlaybackState>? _playbackSub;
  late final AnimationController _discController;
  @override
  void initState() {
    super.initState();
    _discController = AnimationController(vsync: this, duration: const Duration(seconds: 12));
    _loadPlaybackPreferences();
    _mediaSub = widget.handler.mediaItem.listen((_) { if (mounted) setState(() {}); });
    _playbackSub = widget.handler.playbackState.listen((state) {
      if (state.playing && !_discController.isAnimating) { _discController.repeat(); }
      else if (!state.playing && _discController.isAnimating) { _discController.stop(); }
    });
    if (widget.handler.playbackState.value.playing) { _discController.repeat(); }
  }
  Future<void> _loadPlaybackPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final shuffle = prefs.getBool('music_shuffle_v1') ?? false;
    final repeat = prefs.getBool('music_repeat_v1') ?? false;
    if (!mounted) return;
    setState(() { _shuffle = shuffle; _repeat = repeat; });
    await widget.handler.customAction('setShuffle', {'enabled': shuffle});
    await widget.handler.customAction('setLoopMode', {'value': repeat ? 'all' : 'off'});
  }
  Future<void> _toggleShuffle() async {
    final next = !_shuffle;
    setState(() => _shuffle = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('music_shuffle_v1', next);
    await widget.handler.customAction('setShuffle', {'enabled': next});
  }
  Future<void> _toggleRepeat() async {
    final next = !_repeat;
    setState(() => _repeat = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('music_repeat_v1', next);
    await widget.handler.customAction('setLoopMode', {'value': next ? 'all' : 'off'});
  }
  @override
  void dispose() {
    _mediaSub?.cancel();
    _playbackSub?.cancel();
    _discController.dispose();
    super.dispose();
  }
  String _time(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }
  Future<void> _savePlaylist() async {
    final controller = TextEditingController(text: 'قائمة الموسيقى');
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('حفظ قائمة التشغيل'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'اسم القائمة')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('حفظ'))],
    ));
    if (name == null || name.isEmpty) { controller.dispose(); return; }
    final prefs = await SharedPreferences.getInstance();
    final playlists = <String, dynamic>{};
    try { playlists.addAll((jsonDecode(prefs.getString('music_playlists_v1') ?? '{}') as Map).cast<String, dynamic>()); } catch (_) {}
    playlists[name] = widget.files.map((file) => file.path).toList();
    await prefs.setString('music_playlists_v1', jsonEncode(playlists));
    controller.dispose();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم حفظ القائمة «$name»')));
  }
  Future<void> _showSavedPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> playlists = {};
    try { playlists = (jsonDecode(prefs.getString('music_playlists_v1') ?? '{}') as Map).cast<String, dynamic>(); } catch (_) {}
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: playlists.isEmpty
      ? const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('لا توجد قوائم محفوظة بعد')))
      : ListView(children: [
          const ListTile(title: Text('قوائم التشغيل المحفوظة', style: TextStyle(fontWeight: FontWeight.bold))),
          ...playlists.entries.map((entry) => ListTile(
            leading: const Icon(Icons.queue_music_rounded, color: coral),
            title: Text(entry.key),
            subtitle: Text('${(entry.value as List).length} مسار'),
            trailing: IconButton(tooltip: 'حذف القائمة', icon: const Icon(Icons.delete_outline), onPressed: () async {
              final current = <String, dynamic>{...playlists}..remove(entry.key);
              await prefs.setString('music_playlists_v1', jsonEncode(current));
              if (context.mounted) Navigator.pop(context);
              if (mounted) _showSavedPlaylists();
            }),
            onTap: () async {
              final paths = (entry.value as List).whereType<String>().toList();
              final files = paths.map(File.new).where((f) => f.existsSync()).toList();
              if (files.isEmpty) { Navigator.pop(context); return; }
              final titles = files.map((f) => f.uri.pathSegments.isEmpty ? f.path : f.uri.pathSegments.last).toList();
              final handler = widget.handler;
              await (handler as SNBackgroundAudioHandler).playQueueInBackground(files, titles, 0);
              if (context.mounted) Navigator.pop(context);
              if (mounted) setState(() {});
            },
          )),
        ])));
  }
  Future<void> _showQueue() async {
    final handler = widget.handler;
    final items = handler.queue.value;
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (context) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .65, child: Column(children: [
      const Padding(padding: EdgeInsets.all(16), child: Text('قائمة الانتظار', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
      Expanded(child: ReorderableListView.builder(
        itemCount: items.length,
        onReorder: (oldIndex, newIndex) async {
          if (newIndex > oldIndex) newIndex--;
          final reordered = [...items];
          final item = reordered.removeAt(oldIndex);
          reordered.insert(newIndex, item);
          final files = reordered.map((e) => File(e.id)).toList();
          final titles = reordered.map((e) => e.title).toList();
          final currentPath = handler.mediaItem.value?.id;
          final newCurrent = reordered.indexWhere((e) => e.id == currentPath).clamp(0, reordered.length - 1);
          await (handler as SNBackgroundAudioHandler).playQueueInBackground(files, titles, newCurrent);
          if (context.mounted) Navigator.pop(context);
          if (mounted) setState(() {});
        },
        itemBuilder: (context, i) => ListTile(
          key: ValueKey(items[i].id), leading: Icon(i == (handler.playbackState.value.queueIndex ?? 0) ? Icons.equalizer_rounded : Icons.music_note),
          title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(items[i].artist ?? 'SM Player'),
        ),
      )),
    ]))));
  }
  @override
  Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(
    backgroundColor: const Color(0xFF090909),
    appBar: AppBar(
      backgroundColor: const Color(0xFF090909), foregroundColor: Colors.white,
      title: const Text('SM PLAYER · MUSIC', style: TextStyle(fontSize: 14, letterSpacing: 1.3, fontWeight: FontWeight.w800)),
      actions: [
        IconButton(tooltip: 'قائمة الانتظار', onPressed: _showQueue, icon: const Icon(Icons.queue_music_rounded)),
        IconButton(tooltip: 'قوائم التشغيل المحفوظة', onPressed: _showSavedPlaylists, icon: const Icon(Icons.library_music_rounded)),
        IconButton(tooltip: 'حفظ قائمة التشغيل', onPressed: _savePlaylist, icon: const Icon(Icons.playlist_add_rounded)),
        IconButton(tooltip: 'استوديو الصوت', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AudioStudioScreen(handler: widget.handler))), icon: const Icon(Icons.equalizer_rounded, color: coral)),
      ],
    ),
    body: StreamBuilder<PlaybackState>(
      stream: widget.handler.playbackState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.handler.playbackState.value;
        final item = widget.handler.mediaItem.value;
        final duration = item?.duration ?? Duration.zero;
        final position = _dragPosition == null ? state.position : Duration(milliseconds: _dragPosition!.round());
        final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
        return SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(22, 14, 22, 24), children: [
          const Center(child: Text('NOW PLAYING', style: TextStyle(color: Color(0xFFEF4444), letterSpacing: 3, fontWeight: FontWeight.w700))),
          const SizedBox(height: 26),
          Center(child: SizedBox(width: 270, height: 270, child: Stack(alignment: Alignment.center, children: [
            RotationTransition(
              turns: _discController,
              child: Container(
                width: 260, height: 260,
                decoration: BoxDecoration(shape: BoxShape.circle, gradient: const RadialGradient(colors: [Color(0xFFF5F5F5), Color(0xFF8A8A8A), Color(0xFFDADADA), Color(0xFF454545), Color(0xFFBEBEBE), Color(0xFF242424)], stops: [0, .18, .34, .49, .68, 1]), boxShadow: [BoxShadow(color: coral.withOpacity(.32), blurRadius: 28, spreadRadius: 2)]),
                child: Stack(alignment: Alignment.center, children: [
                  for (int i = 0; i < 8; i++) Container(width: 238 - i * 20.0, height: 238 - i * 20.0, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x66000000), width: 1))),
                  Container(width: 92, height: 92, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF181818), border: Border.all(color: const Color(0xFFEF4444), width: 3), boxShadow: const [BoxShadow(color: Color(0x88EF4444), blurRadius: 14)]), child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.play_arrow_rounded, color: Color(0xFFEF4444), size: 34), Text('SM', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 19)), Text('PLAYER', style: TextStyle(color: Colors.white70, fontSize: 8, letterSpacing: 1.5))])),
                ]),
              ),
            ),
          ]))),
          const SizedBox(height: 28),
          Text(item?.title ?? 'لا توجد أغنية', textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(item?.artist ?? 'SM Player · Music Library', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          const SizedBox(height: 22),
          SliderTheme(data: SliderTheme.of(context).copyWith(activeTrackColor: coral, thumbColor: Colors.white, inactiveTrackColor: Colors.white24), child: Slider(
            value: position.inMilliseconds.clamp(0, maxMs.toInt()).toDouble().clamp(0, maxMs).toDouble(),
            max: maxMs,
            onChangeStart: (v) => setState(() => _dragPosition = v),
            onChanged: (v) => setState(() => _dragPosition = v),
            onChangeEnd: (v) { widget.handler.seek(Duration(milliseconds: v.round())); setState(() => _dragPosition = null); },
          )),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_time(position), style: const TextStyle(color: Colors.white54, fontSize: 12)), Text('-${_time(duration > position ? duration - position : Duration.zero)}', style: const TextStyle(color: Colors.white54, fontSize: 12))])),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(tooltip: _shuffle ? 'العشوائي مفعّل' : 'تشغيل عشوائي', onPressed: _toggleShuffle, style: IconButton.styleFrom(backgroundColor: _shuffle ? coral.withOpacity(.22) : Colors.transparent), color: _shuffle ? coral : Colors.white70, icon: const Icon(Icons.shuffle_rounded)),
            IconButton(onPressed: () => widget.handler.skipToPrevious(), color: Colors.white, iconSize: 38, icon: const Icon(Icons.skip_previous_rounded)),
            Container(width: 72, height: 72, decoration: const BoxDecoration(shape: BoxShape.circle, color: coral, boxShadow: [BoxShadow(color: Color(0x66EF4444), blurRadius: 20)]), child: IconButton(color: Colors.white, iconSize: 40, onPressed: () => state.playing ? widget.handler.pause() : widget.handler.play(), icon: Icon(state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded))),
            IconButton(onPressed: () => widget.handler.skipToNext(), color: Colors.white, iconSize: 38, icon: const Icon(Icons.skip_next_rounded)),
            IconButton(tooltip: _repeat ? 'تكرار القائمة مفعّل' : 'تفعيل تكرار القائمة', onPressed: _toggleRepeat, style: IconButton.styleFrom(backgroundColor: _repeat ? coral.withOpacity(.22) : Colors.transparent), color: _repeat ? coral : Colors.white70, icon: const Icon(Icons.repeat_rounded)),
          ]),
          const SizedBox(height: 20),
          OutlinedButton.icon(onPressed: _showQueue, icon: const Icon(Icons.queue_music_rounded), label: const Text('عرض قائمة الانتظار'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Color(0xFF444444)), padding: const EdgeInsets.symmetric(vertical: 14))),
          const SizedBox(height: 10),
          const Text('تشغيل بالخلفية وشاشة القفل عبر خدمة Android media playback', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]));
      },
    ),
  ));
}

class InternalSendScreen extends StatelessWidget {
  const InternalSendScreen({required this.entries, super.key});
  final List<MediaEntry> entries;
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('إرسال عبر SM Player')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('الملفات المحددة: ${entries.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text('ميزة الإرسال الداخلي تحتاج إلى ربطها بخادم الاستقبال قبل استخدامها. يمكنك استخدام زر المشاركة الخارجية مؤقتًا.'),
        const SizedBox(height: 12),
        ...entries.map((e) => ListTile(leading: const Icon(Icons.video_file), title: Text(e.name))),
      ]),
    ),
  );
}

class FolderVideosScreen extends StatefulWidget {
  const FolderVideosScreen({required this.title, required this.entries, required this.onPlay, required this.isFavorite, required this.onFavorite, super.key});
  final String title;
  final List<MediaEntry> entries;
  final ValueChanged<MediaEntry> onPlay;
  final bool Function(MediaEntry) isFavorite;
  final ValueChanged<MediaEntry> onFavorite;
  @override
  State<FolderVideosScreen> createState() => _FolderVideosScreenState();
}
class _FolderVideosScreenState extends State<FolderVideosScreen> {
  bool grid = true;
  String sort = 'dateDesc';
  @override
  void initState() { super.initState(); _loadViewPrefs(); }
  Future<void> _loadViewPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { sort = p.getString('video_sort') ?? 'dateDesc'; grid = p.getBool('global_media_grid') ?? p.getBool('video_grid') ?? true; });
  }
  Future<void> _saveViewPrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('video_sort', sort);
    await p.setBool('video_grid', grid);
    await p.setBool('global_media_grid', grid);
  }
  List<MediaEntry> get sortedEntries => _sortEntries(widget.entries, sort);
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        IconButton(tooltip: grid ? 'عرض كقائمة' : 'عرض كشبكة', onPressed: () { setState(() => grid = !grid); _saveViewPrefs(); }, icon: Icon(grid ? Icons.view_list : Icons.grid_view)),
        PopupMenuButton<String>(tooltip: 'ترتيب الفيديوهات', icon: const Icon(Icons.sort), onSelected: (v) { setState(() => sort = v); _saveViewPrefs(); }, itemBuilder: (_) => const [
          PopupMenuItem(value: 'dateDesc', child: Text('الأحدث أولًا')),
          PopupMenuItem(value: 'dateAsc', child: Text('الأقدم أولًا')),
          PopupMenuItem(value: 'nameAsc', child: Text('الاسم: أ إلى ي')),
          PopupMenuItem(value: 'nameDesc', child: Text('الاسم: ي إلى أ')),
          PopupMenuItem(value: 'durationDesc', child: Text('المدة: الأطول أولًا')),
          PopupMenuItem(value: 'durationAsc', child: Text('المدة: الأقصر أولًا')),
        ]),
      ]),
      body: sortedEntries.isEmpty ? const Center(child: Text('لا توجد فيديوهات في هذا المجلد')) : grid
        ? GridView.builder(padding: const EdgeInsets.all(12), itemCount: sortedEntries.length, gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: .8), itemBuilder: (context, index) {
            final entry = sortedEntries[index];
            return Card(child: InkWell(onTap: () => widget.onPlay(entry), child: Column(children: [
              Expanded(child: Stack(fit: StackFit.expand, children: [
                FutureBuilder<Uint8List?>(future: entry.asset.thumbnailDataWithSize(const ThumbnailSize(480,320)), builder: (_, snap) => snap.data == null ? const Center(child: Icon(Icons.movie_outlined, size: 40)) : Image.memory(snap.data!, fit: BoxFit.cover, width: double.infinity)),
                Positioned(bottom: 6, right: 6, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(5)), child: Text(_formatDuration(entry.duration), style: const TextStyle(color: Colors.white, fontSize: 11)))),
              ])),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis)),
              IconButton(onPressed: () => widget.onFavorite(entry), icon: Icon(widget.isFavorite(entry) ? Icons.favorite : Icons.favorite_border, color: widget.isFavorite(entry) ? coral : coral)),
            ])));
          })
        : ListView.builder(padding: const EdgeInsets.all(12), itemCount: sortedEntries.length, itemBuilder: (context, index) {
            final entry = sortedEntries[index];
            return Card(child: ListTile(
              leading: SizedBox(width: 76, height: 62, child: Stack(fit: StackFit.expand, children: [
                FutureBuilder<Uint8List?>(future: entry.asset.thumbnailDataWithSize(const ThumbnailSize(240, 180)), builder: (_, snap) => snap.data == null ? const ColoredBox(color: Color(0x22111111), child: Icon(Icons.movie_outlined)) : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(snap.data!, fit: BoxFit.cover))),
                Positioned(bottom: 2, left: 2, child: Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)), child: Text(_formatDuration(entry.duration), style: const TextStyle(color: Colors.white, fontSize: 10)))),
              ])),
              title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: IconButton(onPressed: () => widget.onFavorite(entry), icon: Icon(widget.isFavorite(entry) ? Icons.favorite : Icons.favorite_border, color: coral)),
              onTap: () => widget.onPlay(entry)));
          }),
    ),
  );
}

String _folderLabel(String path) {
  if (path == '__root__' || path.trim().isEmpty) return 'المجلد الرئيسي';
  final parts = path.replaceAll('\\\\', '/').split('/').where((part) => part.trim().isNotEmpty).toList();
  return parts.isEmpty ? 'المجلد الرئيسي' : parts.last;
}

String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({required this.entry, required this.file, required this.favorite, required this.onFavorite, required this.playlist, required this.onNavigate, super.key});
  final MediaEntry entry; final File file; final bool favorite; final VoidCallback onFavorite;
  final List<MediaEntry> playlist;
  final ValueChanged<MediaEntry> onNavigate;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}
class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController controller;
  bool ready = false, controls = true, locked = false, fillScreen = false, _longPressActive = false, _backgroundAudioActive = false;
  bool _isFavorite = false, _repeat = false, _shuffle = false;
  int _playlistIndex = 0;
  Duration _seekStartPosition = Duration.zero;
  String? subtitleText;
  Duration subtitleOffset = Duration.zero;
  double? subtitleSize;
  Offset? _gestureStart;
  double _startLevel = .5;
  bool _brightnessGesture = false;
  String? _levelOverlayText;
  IconData _levelOverlayIcon = Icons.volume_up_rounded;
  double _levelOverlay = .5;
  Timer? _overlayTimer;
  Timer? _hideTimer;
  StreamSubscription<PlaybackState>? _backgroundPlaybackSub;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _lastVideoPlaying;
  DateTime _lastBackgroundSync = DateTime.fromMillisecondsSinceEpoch(0);
  bool _syncingBackgroundAudio = false;
  @override
  void initState() {
    super.initState();
    _isFavorite = widget.favorite;
    _loadVideoModes();
    _playlistIndex = widget.playlist.indexWhere((e) => e.id == widget.entry.id);
    if (_playlistIndex < 0) _playlistIndex = 0;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight, DeviceOrientation.portraitUp]);
    controller = VideoPlayerController.file(widget.file);
    controller.initialize().then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final resume = prefs.getInt('resume_${widget.entry.id}') ?? 0;
      if (resume > 0 && resume < controller.value.duration.inMilliseconds - 3000) {
        await controller.seekTo(Duration(milliseconds: resume));
      }
      if (mounted) setState(() => ready = true);
      final modePrefs = await SharedPreferences.getInstance();
      await controller.setLooping(modePrefs.getBool('video_repeat_v1') ?? false);
      await controller.play();
      _scheduleHide();
    }).catchError((Object error) {
      if (mounted) setState(() => ready = false);
    });
    controller.addListener(_update);
  }
  void _update() {
    if (!mounted) return;
    if (_backgroundAudioActive && !_syncingBackgroundAudio && controller.value.isInitialized) {
      final playing = controller.value.isPlaying;
      if (_lastVideoPlaying != playing) {
        _lastVideoPlaying = playing;
        _syncingBackgroundAudio = true;
        _getBackgroundAudioHandler().then((handler) async {
          if (playing) {
            await handler.seek(controller.value.position);
            await handler.play();
          } else {
            await handler.pause();
          }
        }).catchError((Object error) {
          debugPrint('Background playback synchronization failed: $error');
        }).whenComplete(() { _syncingBackgroundAudio = false; });
      } else if (playing && DateTime.now().difference(_lastBackgroundSync).inSeconds >= 2) {
        _lastBackgroundSync = DateTime.now();
        _syncingBackgroundAudio = true;
        _getBackgroundAudioHandler().then((handler) async {
          final delta = (handler.playbackState.value.updatePosition - controller.value.position).inMilliseconds.abs();
          if (delta > 1500) await handler.seek(controller.value.position);
        }).catchError((Object error) {
          debugPrint('Background position synchronization failed: $error');
        }).whenComplete(() { _syncingBackgroundAudio = false; });
      }
    }
    if (controller.value.isInitialized && DateTime.now().difference(_lastSaved).inSeconds >= 5) {
      _lastSaved = DateTime.now();
      SharedPreferences.getInstance().then((p) => p.setInt('resume_${widget.entry.id}', controller.value.position.inMilliseconds));
    }
    setState(() {});
  }
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (controls && !locked && controller.value.isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => controls = false);
      });
    }
  }
  void _showControls() {
    setState(() => controls = true);
    _scheduleHide();
  }
  Future<void> _loadSubtitle() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['srt', 'vtt', 'txt']);
    final path = picked?.files.singleOrNull?.path;
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      if (mounted) setState(() => subtitleText = text);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذرت قراءة ملف الترجمة')));
    }
  }
  String? _subtitleAt(Duration position) {
    final raw = subtitleText;
    if (raw == null) return null;
    final adjusted = position + subtitleOffset;
    for (final block in raw.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
      final lines = block.split('\n').where((line) => line.trim().isNotEmpty).toList();
      final index = lines.indexWhere((line) => line.contains('-->'));
      if (index < 0) continue;
      final times = lines[index].split('-->');
      if (times.length != 2) continue;
      Duration parse(String input) {
        final parts = input.trim().replaceAll(',', '.').split(':');
        if (parts.length != 3) return Duration.zero;
        final sec = parts[2].split('.');
        return Duration(hours: int.tryParse(parts[0]) ?? 0, minutes: int.tryParse(parts[1]) ?? 0, seconds: int.tryParse(sec[0]) ?? 0, milliseconds: sec.length > 1 ? int.tryParse(sec[1].padRight(3, '0').substring(0, 3)) ?? 0 : 0);
      }
      if (adjusted >= parse(times[0]) && adjusted <= parse(times[1])) return lines.skip(index + 1).join('\n').replaceAll(RegExp(r'<[^>]*>'), '');
    }
    return null;
  }
  Future<void> _loadVideoModes() async {
    final prefs = await SharedPreferences.getInstance();
    final repeat = prefs.getBool('video_repeat_v1') ?? false;
    final shuffle = prefs.getBool('video_shuffle_v1') ?? false;
    if (!mounted) return;
    setState(() { _repeat = repeat; _shuffle = shuffle; });
    if (controller.value.isInitialized) await controller.setLooping(repeat);
  }
  void _showLevelOverlay(String label, IconData icon, double level) {
    _overlayTimer?.cancel();
    if (!mounted) return;
    setState(() { _levelOverlayText = '$label ${ (level * 100).round() }%'; _levelOverlayIcon = icon; _levelOverlay = level; });
    _overlayTimer = Timer(const Duration(milliseconds: 1100), () { if (mounted) setState(() => _levelOverlayText = null); });
  }
  Future<void> _gestureStartAt(DragStartDetails d) async {
    _gestureStart = d.localPosition;
    _brightnessGesture = d.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
    try {
      _startLevel = _brightnessGesture ? await ScreenBrightness().current : await VolumeController().getVolume();
      _showLevelOverlay(_brightnessGesture ? 'السطوع' : 'الصوت', _brightnessGesture ? Icons.brightness_6_rounded : Icons.volume_up_rounded, _startLevel);
    } catch (_) { _startLevel = .5; }
  }
  void _gestureUpdate(DragUpdateDetails d) {
    final start = _gestureStart;
    if (start == null) return;
    final level = (_startLevel + (start.dy - d.localPosition.dy) / MediaQuery.sizeOf(context).height * 2).clamp(0.0, 1.0);
    if (_brightnessGesture) { ScreenBrightness().setScreenBrightness(level); _showLevelOverlay('السطوع', Icons.brightness_6_rounded, level); }
    else { VolumeController().setVolume(level); _showLevelOverlay('الصوت', Icons.volume_up_rounded, level); }
  }
  Future<void> _startBackgroundAudio() async {
    final resumePosition = controller.value.position;
    try {
      final prefs = await SharedPreferences.getInstance();
      final mode = prefs.getString('background_mode') ?? 'audio';
      if (mode == 'pip') {
        final result = await const MethodChannel('com.samirnet.snplayer/pip').invokeMethod<bool>('enterPip');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result == true ? 'تم طلب نافذة الفيديو العائمة.' : 'تعذر تشغيل النافذة العائمة؛ تحقق من دعم Picture-in-Picture في Android.')));
        return;
      }
      if (_backgroundAudioActive) {
        await _backgroundPlaybackSub?.cancel();
        _backgroundPlaybackSub = null;
        final handler = await _getBackgroundAudioHandler();
        await handler.stop();
        await controller.setVolume(1.0);
        if (mounted) setState(() { _backgroundAudioActive = false; _lastVideoPlaying = null; });
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إيقاف صوت الخلفية وإعادة صوت الفيديو.')));
        return;
      }
      // Keep the picture moving, but mute its audio track so the background media
      // service is the only audible source and can keep playing after the app is hidden.
      await controller.setVolume(0.0);
      if (!controller.value.isPlaying) await controller.play();
      await prefs.setInt('resume_${widget.entry.id}', resumePosition.inMilliseconds);
      final handler = await _getBackgroundAudioHandler();
      await handler.customAction('playFileInBackground', {'path': widget.file.path, 'title': 'فيديو · ${widget.entry.name}', 'positionMs': resumePosition.inMilliseconds});
      if (mounted) setState(() { _backgroundAudioActive = true; _lastVideoPlaying = controller.value.isPlaying; _lastBackgroundSync = DateTime.now(); });
      await _backgroundPlaybackSub?.cancel();
      _backgroundPlaybackSub = handler.playbackState.listen((state) async {
        if (!_backgroundAudioActive || !mounted || !controller.value.isInitialized) return;
        if (state.playing && !controller.value.isPlaying) {
          await controller.play();
        } else if (!state.playing && controller.value.isPlaying) {
          await controller.pause();
        }
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('صوت الخلفية يعمل الآن. يستمر الفيديو بصورته، ويظهر إشعار التحكم عند تشغيل الصوت. اضغط الزر مرة أخرى لإيقافه.')));
    } catch (e) {
      try { await controller.setVolume(1.0); } catch (_) {}
      if (mounted) setState(() => _backgroundAudioActive = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تشغيل الخلفية: $e')));
    }
  }
  Future<void> _toggleFullscreen() async {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    await SystemChrome.setPreferredOrientations(landscape ? [DeviceOrientation.portraitUp] : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    if (mounted) setState(() {});
  }
  void _horizontalSeekStart(DragStartDetails d) {
    _gestureStart = d.localPosition;
    _seekStartPosition = controller.value.position;
    _showControls();
  }
  void _horizontalSeekUpdate(DragUpdateDetails d) {
    final start = _gestureStart;
    if (start == null || controller.value.duration <= Duration.zero) return;
    final delta = d.localPosition.dx - start.dx;
    final seconds = (delta / MediaQuery.sizeOf(context).width * 120).round();
    final targetMs = (_seekStartPosition.inMilliseconds + seconds * 1000).clamp(0, controller.value.duration.inMilliseconds);
    controller.seekTo(Duration(milliseconds: targetMs));
    _showControls();
  }
  double _speedForLongPress(Offset p, Size size) {
    final rightSide = p.dx >= size.width / 2;
    final upperHalf = p.dy < size.height / 2;
    if (rightSide && upperHalf) return 2.0;
    if (rightSide && !upperHalf) return 1.25;
    if (!rightSide && upperHalf) return 0.75;
    return 0.5;
  }
  Future<void> _beginSpeedBoost(LongPressStartDetails details) async {
    if (locked || !ready || _longPressActive) return;
    _longPressActive = true;
    final speed = _speedForLongPress(details.localPosition, MediaQuery.sizeOf(context));
    await controller.setPlaybackSpeed(speed);
    _showLevelOverlay('السرعة', Icons.speed_rounded, (speed / 2).clamp(0.0, 1.0));
    if (mounted) { setState(() {}); _levelOverlayText = 'السرعة $speed×'; }
    _showControls();
  }
  Future<void> _endSpeedBoost() async {
    if (!_longPressActive) return;
    _longPressActive = false;
    await controller.setPlaybackSpeed(1.0);
    if (mounted) { setState(() => _levelOverlayText = 'السرعة 1.0×'); _overlayTimer?.cancel(); _overlayTimer = Timer(const Duration(milliseconds: 900), () { if (mounted) setState(() => _levelOverlayText = null); }); }
    _showControls();
  }
  @override
  void dispose() {
    _hideTimer?.cancel();
    _overlayTimer?.cancel();
    _backgroundPlaybackSub?.cancel();
    controller.removeListener(_update);
    controller.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
  void _seek(int seconds) { final target = controller.value.position + Duration(seconds: seconds); controller.seekTo(target < Duration.zero ? Duration.zero : target); }
  void _navigatePlaylist(int direction, {bool randomize = false}) {
    if (widget.playlist.length < 2) return;
    final int nextIndex;
    if (randomize || _shuffle) {
      final choices = List<int>.generate(widget.playlist.length, (i) => i).where((i) => i != _playlistIndex).toList()..shuffle();
      nextIndex = choices.first;
    } else {
      nextIndex = (_playlistIndex + direction + widget.playlist.length) % widget.playlist.length;
    }
    widget.onNavigate(widget.playlist[nextIndex]);
  }
  Future<void> _toggleRepeat() async {
    final next = !_repeat;
    setState(() => _repeat = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('video_repeat_v1', next);
    await controller.setLooping(next);
  }
  Future<void> _toggleShuffle() async {
    final next = !_shuffle;
    setState(() => _shuffle = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('video_shuffle_v1', next);
  }
  void _toggleFavorite() {
    setState(() => _isFavorite = !_isFavorite);
    widget.onFavorite();
  }
  String _time(Duration d) { final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2, '0'); final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return h > 0 ? '$h:$m:$s' : '$m:$s'; }
  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    return Directionality(textDirection: TextDirection.ltr, child: Scaffold(backgroundColor: Colors.black, body: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () { if (!locked) { if (controls) { setState(() => controls = false); _hideTimer?.cancel(); } else { _showControls(); } } }, onDoubleTap: () {}, onDoubleTapDown: (d) { if (!locked) _seek(d.localPosition.dx > MediaQuery.sizeOf(context).width / 2 ? 10 : -10); }, onLongPressStart: locked ? null : _beginSpeedBoost, onLongPressEnd: locked ? null : (_) => _endSpeedBoost(), onHorizontalDragStart: locked ? null : _horizontalSeekStart, onHorizontalDragUpdate: locked ? null : _horizontalSeekUpdate, onHorizontalDragEnd: (_) => _gestureStart = null, onVerticalDragStart: locked ? null : _gestureStartAt, onVerticalDragUpdate: locked ? null : _gestureUpdate, onVerticalDragEnd: (_) => _gestureStart = null, child: Stack(alignment: Alignment.center, children: [
      if (ready) Center(child: fillScreen ? SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: MediaQuery.sizeOf(context).width, height: MediaQuery.sizeOf(context).width / (v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio), child: VideoPlayer(controller)))) : AspectRatio(aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio, child: VideoPlayer(controller))) else if (v.hasError) const Center(child: Text('تعذّر تشغيل هذا الملف', style: TextStyle(color: Colors.white))) else const CircularProgressIndicator(color: coral),
      if (ready && _subtitleAt(v.position) != null) Positioned(bottom: 90, left: 20, right: 20, child: IgnorePointer(child: Text(_subtitleAt(v.position)!, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: subtitleSize ?? 22, fontWeight: FontWeight.bold, shadows: const [Shadow(color: Colors.black, blurRadius: 5), Shadow(color: Colors.black, blurRadius: 10)])))),
      if (controls && !locked) Positioned.fill(child: DecoratedBox(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent, Colors.black87], stops: [0, .5, 1])), child: SafeArea(child: Column(children: [
        Row(children: [
          IconButton(onPressed: () => Navigator.pop(context), tooltip: 'رجوع', icon: const Icon(Icons.arrow_back, color: Colors.white)),
          Expanded(child: Text(widget.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))),
          IconButton(tooltip: _backgroundAudioActive ? 'إيقاف صوت الخلفية' : 'تشغيل الصوت في الخلفية', onPressed: _startBackgroundAudio, icon: Icon(Icons.headphones_rounded, color: _backgroundAudioActive ? coral : Colors.white)),
          IconButton(tooltip: 'تدوير الشاشة', onPressed: _toggleFullscreen, icon: const Icon(Icons.screen_rotation, color: Colors.white)),
          IconButton(tooltip: locked ? 'إلغاء قفل اللمس' : 'قفل اللمس', onPressed: () { setState(() { locked = !locked; if (!locked) controls = true; }); _hideTimer?.cancel(); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); if (!locked) _scheduleHide(); }, icon: Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded, color: locked ? coral : Colors.white)),
          PopupMenuButton<String>(icon: const Icon(Icons.more_vert, color: Colors.white), onSelected: (value) {
          if (value.startsWith('speed:')) { final speed = double.parse(value.substring(6)); controller.setPlaybackSpeed(speed); setState(() => _levelOverlayText = 'السرعة $speed×'); _overlayTimer?.cancel(); _overlayTimer = Timer(const Duration(milliseconds: 1200), () { if (mounted) setState(() => _levelOverlayText = null); }); }
          if (value == 'fit') setState(() => fillScreen = !fillScreen);
          if (value == 'rotate') _toggleFullscreen();
          if (value == 'subtitle') _loadSubtitle();
          if (value == 'subminus') setState(() => subtitleOffset -= const Duration(milliseconds: 500));
          if (value == 'subplus') setState(() => subtitleOffset += const Duration(milliseconds: 500));
          if (value == 'subsize') setState(() => subtitleSize = (subtitleSize ?? 22) >= 30 ? 16 : (subtitleSize ?? 22) + 2);
        }, itemBuilder: (_) => [
          const PopupMenuItem(value: 'fit', child: Text('تبديل ملء الشاشة / احتواء')),
          const PopupMenuItem(value: 'rotate', child: Text('تدوير الشاشة')),
          const PopupMenuItem(value: 'subtitle', child: Text('اختيار ملف ترجمة')),
          const PopupMenuItem(value: 'subminus', child: Text('تأخير الترجمة -0.5 ثانية')),
          const PopupMenuItem(value: 'subplus', child: Text('تقديم الترجمة +0.5 ثانية')),
          const PopupMenuItem(value: 'subsize', child: Text('تكبير / تصغير الترجمة')),
          const PopupMenuDivider(),
          ...[0.5, .75, 1.0, 1.25, 1.5, 2.0].map((s) => PopupMenuItem(value: 'speed:$s', child: Text('سرعة $s×'))),
        ])]),
        const Spacer(),
        const Spacer(),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Column(children: [
          VideoProgressIndicator(controller, allowScrubbing: true, colors: const VideoProgressColors(playedColor: coral, bufferedColor: Colors.white38, backgroundColor: Colors.white24)),
          Row(children: [
            Text(_time(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)),
            const Spacer(),
            Text('-${_time(v.duration - v.position)}', style: const TextStyle(color: Colors.white, fontSize: 12)),
            IconButton(tooltip: 'ملء الشاشة / احتواء', onPressed: () => setState(() => fillScreen = !fillScreen), icon: Icon(fillScreen ? Icons.fit_screen : Icons.fullscreen, color: Colors.white)),
          ]),
          const SizedBox(height: 2),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: _repeat ? 'التكرار مفعّل' : 'تفعيل التكرار', onPressed: _toggleRepeat, style: IconButton.styleFrom(backgroundColor: _repeat ? coral.withOpacity(.22) : Colors.transparent), icon: Icon(Icons.repeat_rounded, color: _repeat ? coral : Colors.white)),
              IconButton(tooltip: _shuffle ? 'العشوائي مفعّل' : 'تشغيل عشوائي', onPressed: _toggleShuffle, style: IconButton.styleFrom(backgroundColor: _shuffle ? coral.withOpacity(.22) : Colors.transparent), icon: Icon(Icons.shuffle_rounded, color: _shuffle ? coral : Colors.white)),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'الفيديو السابق', onPressed: () => _navigatePlaylist(-1), icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 34)),
              IconButton(tooltip: 'تشغيل / إيقاف', onPressed: () => v.isPlaying ? controller.pause() : controller.play(), icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 56)),
              IconButton(tooltip: 'الفيديو التالي', onPressed: () => _navigatePlaylist(1), icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 34)),
            ]),
            IconButton(tooltip: _isFavorite ? 'إزالة من المفضلة' : 'إضافة إلى المفضلة', onPressed: _toggleFavorite, icon: Icon(_isFavorite ? Icons.favorite : Icons.favorite_border, color: _isFavorite ? coral : Colors.white)),
          ]),
        ])),
      ])))),
      if (_levelOverlayText != null) Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(color: const Color(0x55202020), borderRadius: BorderRadius.circular(28), border: Border.all(color: coral.withOpacity(.45), width: 1)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_levelOverlayIcon, color: coral, size: 23),
                const SizedBox(width: 9),
                Text(_levelOverlayText!, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                if (_levelOverlayText!.startsWith('السطوع') || _levelOverlayText!.startsWith('الصوت')) ...[
                  const SizedBox(width: 10),
                  SizedBox(width: 66, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: _levelOverlay, minHeight: 4, backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation<Color>(coral)))),
                ],
              ]),
            ),
          ),
        ),
      ),
      if (locked) Positioned(left: 16, bottom: 32, child: IconButton.filledTonal(onPressed: () { setState(() { locked = false; controls = true; }); SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); }, icon: const Icon(Icons.lock))),
    ]))));
  }
}

class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});
  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  bool busy = false;
  List<File> files = [];
  @override
  void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async {
    final list = await VaultService.instance.listEncryptedFiles();
    if (mounted) setState(() => files = list);
  }
  Future<String?> _askPin({required String title}) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, obscureText: true,
          keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الرقم السري', helperText: 'أدخل 4 أرقام أو أكثر')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('متابعة')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }
  Future<String?> _ensurePin() async {
    final service = VaultService.instance;
    final configured = await service.isConfigured;
    final pin = await _askPin(title: configured ? 'فتح الخزنة' : 'إنشاء رقم سري للخزنة');
    if (pin == null || pin.isEmpty) return null;
    if (configured) {
      if (!await service.verifyPin(pin)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرقم السري غير صحيح')));
        return null;
      }
    } else {
      if (pin.length < 4) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('استخدم 4 أرقام أو أكثر')));
        return null;
      }
      await service.setPin(pin);
    }
    return pin;
  }
  Future<void> _import() async {
    final pin = await _ensurePin();
    if (pin == null) return;
    final picked = await FilePicker.platform.pickFiles(allowMultiple: false);
    final path = picked?.files.singleOrNull?.path;
    if (path == null) return;
    setState(() => busy = true);
    try {
      await VaultService.instance.importFile(File(path), pin);
      await _refresh();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تشفير الملف ونقله إلى الخزنة')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تشفير الملف: $e')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> _restore(File file) async {
    final pin = await _ensurePin();
    if (pin == null) return;
    setState(() => busy = true);
    try {
      final temp = await VaultService.instance.decryptToTemporary(file, pin);
      final meta = await VaultService.instance.metadataFor(file);
      final originalName = meta['name'] as String? ?? 'restored_media.bin';
      final destination = await FilePicker.platform.saveFile(fileName: originalName);
      if (destination != null) {
        await temp.copy(destination);
        await temp.delete();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم فك التشفير وحفظ النسخة التي اخترتها')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر فك التشفير: $e')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> _delete(File file) async {
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('حذف الملف المشفر؟'),
      content: const Text('سيتم حذف النسخة المشفرة من الخزنة.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('حذف'))],
    ));
    if (confirm == true) { await VaultService.instance.delete(file); await _refresh(); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('الخزنة الخاصة')),
    floatingActionButton: FloatingActionButton.extended(onPressed: busy ? null : _import, icon: const Icon(Icons.add_to_drive), label: const Text('إضافة ملف')),
    body: busy ? const Center(child: CircularProgressIndicator(color: coral)) : files.isEmpty
      ? Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.enhanced_encryption, size: 64, color: coral),
          const SizedBox(height: 16), const Text('خزنتك الخاصة', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8), const Text('تُحفظ الملفات داخل مساحة التطبيق بصيغة مشفرة AES. احفظ رقمك السري؛ لا توجد طريقة لاستعادة الملفات بدونه.', textAlign: TextAlign.center),
          const SizedBox(height: 16), FilledButton.icon(onPressed: _import, icon: const Icon(Icons.add), label: const Text('تشفير ملف وإضافته')),
        ])))
      : ListView(padding: const EdgeInsets.all(16), children: [
          const Text('الملفات المشفرة', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...files.map((file) => Card(child: ListTile(
            leading: const CircleAvatar(backgroundColor: Color(0x1AEF4444), child: Icon(Icons.lock, color: coral)),
            title: FutureBuilder<Map<String, dynamic>>(future: VaultService.instance.metadataFor(file), builder: (_, snap) => Text(snap.data?['name'] as String? ?? 'ملف خاص ${files.indexOf(file) + 1}')),
            subtitle: Text('${(file.lengthSync() / 1024).toStringAsFixed(1)} كيلوبايت · مشفر'),
            onTap: () => _restore(file),
            trailing: PopupMenuButton<String>(onSelected: (v) => v == 'restore' ? _restore(file) : _delete(file), itemBuilder: (_) => const [
              PopupMenuItem(value: 'restore', child: Text('فك التشفير / استعادة')),
              PopupMenuItem(value: 'delete', child: Text('حذف نهائي')),
            ]),
          ))),
          const SizedBox(height: 90),
        ]),
  );
}

class WifiTransferScreen extends StatefulWidget {
  const WifiTransferScreen({super.key});
  @override
  State<WifiTransferScreen> createState() => _WifiTransferScreenState();
}

class _WifiTransferScreenState extends State<WifiTransferScreen> {
  final WifiTransferService service = WifiTransferService();
  bool busy = false;
  List<String> addresses = [];
  String? error;
  Future<void> _start() async {
    setState(() { busy = true; error = null; });
    try {
      await service.start();
      addresses = await service.localIpv4Addresses;
      if (addresses.isEmpty) error = 'لم يتم العثور على عنوان شبكة محلية. تأكد من اتصال الهاتف بشبكة Wi-Fi.';
    } catch (e) { error = 'تعذر بدء خادم النقل: $e'; }
    if (mounted) setState(() => busy = false);
  }
  Future<void> _stop() async {
    setState(() => busy = true);
    await service.stop();
    if (mounted) setState(() { busy = false; addresses = []; });
  }
  @override
  void dispose() { service.stop(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('نقل الملفات عبر Wi-Fi')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(22)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.wifi_tethering, size: 42, color: coral),
        const SizedBox(height: 12),
        Text(service.isRunning ? 'الخادم يعمل' : 'استقبال ملفات من جهاز آخر', style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('صل الجهازان بشبكة Wi-Fi نفسها. يتطلب الإرسال طلب HTTP مع رمز المصادقة، وتُعرض بصمة SHA-256 بعد حفظ الملف. أوقف الخادم بعد الانتهاء.'),
        const SizedBox(height: 16),
        if (service.isRunning) ...[
          const Text('عنوان الخادم', style: TextStyle(fontWeight: FontWeight.bold)),
          ...addresses.map((ip) => SelectableText('http://$ip:${service.port}')),
          const SizedBox(height: 12),
          const Text('رمز المصادقة (خاص بك)', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(service.token ?? ''),
          const SizedBox(height: 12),
          const Text('نقطة استقبال: POST /upload?name=filename.mp4\\nالترويسة: Authorization: Bearer TOKEN', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: busy ? null : _stop, icon: const Icon(Icons.stop_circle_outlined), label: const Text('إيقاف الاستقبال')),
        ] else FilledButton.icon(onPressed: busy ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('بدء استقبال الملفات')),
        if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: coral))),
      ])),
      const SizedBox(height: 16),
      const ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('حماية برمز عشوائي'), subtitle: Text('الطلبات التي لا تحمل رمز المصادقة تُرفض.')),
      const ListTile(leading: Icon(Icons.fingerprint), title: Text('فحص سلامة الملف'), subtitle: Text('يُرجع الخادم حجم الملف وبصمة SHA-256 بعد استلامه.')),
      const ListTile(leading: Icon(Icons.folder_outlined), title: Text('مكان الملفات المستلمة'), subtitle: Text('داخل مساحة التطبيق الخاصة، مجلد wifi_received.')),
    ]),
  );
}
