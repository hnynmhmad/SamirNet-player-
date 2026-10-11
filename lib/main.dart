import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'services/vault_service.dart';
import 'services/wifi_transfer_service.dart';

const coral = Color(0xFFEF4444);
const ink = Color(0xFF111827);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SamirNetApp());
}

class SamirNetApp extends StatefulWidget {
  const SamirNetApp({super.key});
  @override
  State<SamirNetApp> createState() => _SamirNetAppState();
}

class _SamirNetAppState extends State<SamirNetApp> {
  ThemeMode mode = ThemeMode.system;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString('theme') ?? 'system';
    if (!mounted) return;
    setState(() => mode = v == 'dark' ? ThemeMode.dark : v == 'light' ? ThemeMode.light : ThemeMode.system);
  }
  Future<void> _setMode(ThemeMode value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('theme', value == ThemeMode.dark ? 'dark' : value == ThemeMode.light ? 'light' : 'system');
    if (mounted) setState(() => mode = value);
  }
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SN Player', debugShowCheckedModeBanner: false, locale: const Locale('ar'),
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

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.mode, required this.onMode, super.key});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int tab = 0, filter = 0;
  bool loading = true, denied = false, grid = true;
  String? scanError;
  String query = '';
  final search = TextEditingController();
  List<MediaEntry> videos = [];
  Set<String> favorites = {};
  List<String> history = [];
  @override
  void initState() { super.initState(); _loadLocal(); _scan(); }
  @override
  void dispose() { search.dispose(); super.dispose(); }
  Future<void> _loadLocal() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() { favorites = (p.getStringList('favorites') ?? []).toSet(); history = p.getStringList('history') ?? []; });
  }
  Future<void> _scan() async {
    if (mounted) setState(() { loading = true; denied = false; scanError = null; });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) setState(() { denied = true; loading = false; scanError = 'لم يمنح Android التطبيق صلاحية قراءة الفيديوهات. افتح إعدادات التطبيق ثم الأذونات وتأكد من السماح بالصور والفيديوهات.'; });
        return;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: true);
      final assets = paths.isEmpty ? <AssetEntity>[] : await paths.first.getAssetListRange(start: 0, end: 1000);
      if (mounted) setState(() { videos = assets.map(MediaEntry.new).toList(); loading = false; denied = false; scanError = null; });
    } catch (error, stack) {
      debugPrint('SamirNet media scan failed: $error\\n$stack');
      if (mounted) setState(() { loading = false; denied = false; scanError = 'تعذر فحص مكتبة الفيديوهات: $error'; });
    }
  }
  List<MediaEntry> get shown {
    Iterable<MediaEntry> list = videos;
    if (tab == 2) list = list.where((v) => favorites.contains(v.id));
    if (tab == 3) list = history.map((id) => videos.where((v) => v.id == id).firstOrNull).whereType<MediaEntry>();
    if (filter == 1) list = list.where((v) => v.duration.inMinutes < 10);
    if (filter == 2) list = list.where((v) => v.duration.inMinutes >= 10);
    if (query.trim().isNotEmpty) list = list.where((v) => v.name.toLowerCase().contains(query.trim().toLowerCase()));
    return list.toList();
  }
  Future<void> _favorite(MediaEntry v) async {
    setState(() { if (!favorites.add(v.id)) favorites.remove(v.id); });
    final p = await SharedPreferences.getInstance(); await p.setStringList('favorites', favorites.toList());
  }
  Future<void> _play(MediaEntry v) async {
    final file = await v.asset.file;
    if (file == null || !mounted) { _toast('تعذّر الوصول إلى الملف'); return; }
    final p = await SharedPreferences.getInstance();
    history.remove(v.id); history.insert(0, v.id); history = history.take(100).toList();
    await p.setStringList('history', history);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(entry: v, file: file, favorite: favorites.contains(v.id), onFavorite: () => _favorite(v))));
    if (mounted) setState(() {});
  }
  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  @override
  Widget build(BuildContext context) => Directionality(textDirection: TextDirection.rtl, child: Scaffold(
    appBar: AppBar(title: const Row(children: [
      CircleAvatar(backgroundColor: coral, child: Icon(Icons.play_arrow_rounded, color: Colors.white)),
      SizedBox(width: 10),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('SN Player', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('مشغّل الوسائط الخاص بك', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    ]), actions: [
      IconButton(tooltip: 'تحديث المكتبة', onPressed: _scan, icon: const Icon(Icons.refresh_rounded)),
      IconButton(tooltip: 'نقل عبر Wi-Fi', onPressed: () => _toast('ميزة نقل Wi-Fi ضمن مرحلة التطوير التالية'), icon: const Icon(Icons.wifi_rounded)),
    ]),
    body: tab == 4 ? _settings() : tab == 1 ? _folders() : _library(),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: const [
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
        Row(children: [
          _chip('الكل', 0), const SizedBox(width: 8), _chip('قصيرة', 1), const SizedBox(width: 8), _chip('طويلة', 2), const Spacer(),
          IconButton.filledTonal(onPressed: () => setState(() => grid = !grid), icon: Icon(grid ? Icons.view_list : Icons.grid_view)),
        ]),
        const SizedBox(height: 10),
        if (tab == 0 && history.isNotEmpty) const Text('متابعة المشاهدة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      ]))),
      if (loading) const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: coral)))
      else if (denied) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.perm_media_outlined, 'نحتاج إلى إذن الوصول للوسائط', scanError ?? 'اسمح بالوصول إلى الفيديوهات المحلية من إعدادات التطبيق.', 'إعادة المحاولة', _scan))
      else if (scanError != null) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.error_outline, 'تعذر تحميل مكتبة الوسائط', scanError!, 'إعادة المحاولة', _scan))
      else if (items.isEmpty) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.video_library_outlined, query.isNotEmpty ? 'لا توجد نتائج' : 'لم نعثر على فيديوهات', 'لم يعثر فهرس Android على فيديوهات يمكن للتطبيق الوصول إليها. جرّب تحديث المكتبة.', 'تحديث المكتبة', _scan))
      else if (grid) SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverGrid(delegate: SliverChildBuilderDelegate((context, i) => _videoCard(items[i], true), childCount: items.length), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: .78)))
      else SliverPadding(padding: const EdgeInsets.all(16), sliver: SliverList(delegate: SliverChildBuilderDelegate((context, i) => Padding(padding: const EdgeInsets.only(bottom: 8), child: _videoCard(items[i], false)), childCount: items.length))),
    ]));
  }
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
          ])),
          Padding(padding: const EdgeInsets.all(10), child: Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
        ])
      : ListTile(leading: SizedBox(width: 86, height: 64, child: FutureBuilder<Uint8List?>(future: thumb, builder: (_, s) => s.data == null ? const Icon(Icons.movie) : ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(s.data!, fit: BoxFit.cover)))), title: Text(v.name, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text(duration), trailing: IconButton(onPressed: () => _favorite(v), icon: Icon(favorites.contains(v.id) ? Icons.favorite : Icons.favorite_border, color: coral)))));
  }
  Widget _folders() {
    final groups = <String, List<MediaEntry>>{};
    for (final v in videos) { groups.putIfAbsent(v.asset.relativePath ?? 'موقع غير معروف', () => []).add(v); }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('المجلدات', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12),
      if (groups.isEmpty) const Text('لا توجد مجلدات فيديو متاحة'),
      ...groups.entries.map((e) => Card(child: ExpansionTile(leading: const Icon(Icons.folder, color: coral), title: Text(e.key.isEmpty ? 'المجلد الرئيسي' : e.key), subtitle: Text('${e.value.length} فيديو'), children: e.value.map((v) => ListTile(title: Text(v.name), leading: const Icon(Icons.movie_outlined), onTap: () => _play(v))).toList()))),
    ]);
  }
  Widget _settings() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('الإعدادات', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
    const SizedBox(height: 12),
    Card(child: Column(children: [
      const ListTile(leading: Icon(Icons.palette_outlined), title: Text('المظهر', style: TextStyle(fontWeight: FontWeight.bold))),
      RadioListTile<ThemeMode>(title: const Text('اتباع مظهر النظام'), value: ThemeMode.system, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      RadioListTile<ThemeMode>(title: const Text('الوضع الفاتح'), value: ThemeMode.light, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      RadioListTile<ThemeMode>(title: const Text('الوضع الداكن'), value: ThemeMode.dark, groupValue: widget.mode, onChanged: (v) { if (v != null) widget.onMode(v); }),
      SwitchListTile(value: grid, onChanged: (v) => setState(() => grid = v), title: const Text('عرض الشبكة'), subtitle: const Text('إيقاف الخيار يعرض الملفات في قائمة')),
      ListTile(leading: const Icon(Icons.refresh), title: const Text('تحديث مكتبة الوسائط'), onTap: _scan),
      ListTile(leading: const Icon(Icons.lock_outline, color: coral), title: const Text('الخزنة الخاصة'), subtitle: const Text('تشفير ملفاتك وحمايتها برقم سري'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultScreen()))),
      ListTile(leading: const Icon(Icons.wifi, color: coral), title: const Text('نقل عبر Wi-Fi'), subtitle: const Text('استقبال ملفات من جهاز آخر على الشبكة نفسها'), trailing: const Icon(Icons.chevron_left), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WifiTransferScreen()))),
    ])),
    const SizedBox(height: 20), const Center(child: Text('SN Player · 0.1.0', style: TextStyle(color: Colors.grey))),
  ]);
  Widget _empty(IconData icon, String title, String subtitle, String action, VoidCallback onTap) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Icon(icon, size: 60, color: coral), const SizedBox(height: 16), Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 8), Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey)), const SizedBox(height: 16), FilledButton.icon(onPressed: onTap, icon: const Icon(Icons.refresh), label: Text(action)),
  ])));
  String _format(Duration d) { final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2, '0'); final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return h > 0 ? '$h:$m:$s' : '$m:$s'; }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({required this.entry, required this.file, required this.favorite, required this.onFavorite, super.key});
  final MediaEntry entry; final File file; final bool favorite; final VoidCallback onFavorite;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}
class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController controller;
  bool ready = false, controls = true, locked = false, fillScreen = false;
  String? subtitleText;
  Duration subtitleOffset = Duration.zero;
  double? subtitleSize;
  Offset? _gestureStart;
  double _startLevel = .5;
  bool _brightnessGesture = false;
  Timer? _hideTimer;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
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
      await controller.play();
      _scheduleHide();
    }).catchError((Object error) {
      if (mounted) setState(() => ready = false);
    });
    controller.addListener(_update);
  }
  void _update() {
    if (!mounted) return;
    if (controller.value.isInitialized && DateTime.now().difference(_lastSaved).inSeconds >= 5) {
      _lastSaved = DateTime.now();
      SharedPreferences.getInstance().then((p) => p.setInt('resume_${widget.entry.id}', controller.value.position.inMilliseconds));
    }
    setState(() {});
  }
  void _scheduleHide() {
    _hideTimer?.cancel();
    if (controls && !locked && controller.value.isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
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
  void _gestureStartAt(DragStartDetails d) {
    _gestureStart = d.localPosition;
    _brightnessGesture = d.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
    _startLevel = .5;
    if (_brightnessGesture) {
      ScreenBrightness().current.then((v) => _startLevel = v);
    } else {
      VolumeController().getVolume().then((v) => _startLevel = v);
    }
  }
  void _gestureUpdate(DragUpdateDetails d) {
    final start = _gestureStart;
    if (start == null) return;
    final level = (_startLevel + (start.dy - d.localPosition.dy) / MediaQuery.sizeOf(context).height * 2).clamp(0.0, 1.0);
    if (_brightnessGesture) { ScreenBrightness().setScreenBrightness(level); }
    else { VolumeController().setVolume(level); }
  }
  Future<void> _toggleFullscreen() async {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    await SystemChrome.setPreferredOrientations(landscape ? [DeviceOrientation.portraitUp] : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  @override
  void dispose() {
    _hideTimer?.cancel();
    controller.removeListener(_update);
    controller.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
  void _seek(int seconds) { final target = controller.value.position + Duration(seconds: seconds); controller.seekTo(target < Duration.zero ? Duration.zero : target); }
  String _time(Duration d) { final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2, '0'); final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return h > 0 ? '$h:$m:$s' : '$m:$s'; }
  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    return Directionality(textDirection: TextDirection.ltr, child: Scaffold(backgroundColor: Colors.black, body: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () { if (!locked) { if (controls) { setState(() => controls = false); _hideTimer?.cancel(); } else { _showControls(); } } }, onDoubleTapDown: (d) { if (!locked) _seek(d.localPosition.dx > MediaQuery.sizeOf(context).width / 2 ? 10 : -10); }, onVerticalDragStart: locked ? null : _gestureStartAt, onVerticalDragUpdate: locked ? null : _gestureUpdate, onVerticalDragEnd: (_) => _gestureStart = null, child: Stack(alignment: Alignment.center, children: [
      if (ready) Center(child: fillScreen ? SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: MediaQuery.sizeOf(context).width, height: MediaQuery.sizeOf(context).width / (v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio), child: VideoPlayer(controller)))) : AspectRatio(aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio, child: VideoPlayer(controller))) else if (v.hasError) const Center(child: Text('تعذّر تشغيل هذا الملف', style: TextStyle(color: Colors.white))) else const CircularProgressIndicator(color: coral),
      if (ready && _subtitleAt(v.position) != null) Positioned(bottom: 90, left: 20, right: 20, child: IgnorePointer(child: Text(_subtitleAt(v.position)!, textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: subtitleSize ?? 22, fontWeight: FontWeight.bold, shadows: const [Shadow(color: Colors.black, blurRadius: 5), Shadow(color: Colors.black, blurRadius: 10)])))),
      if (controls && !locked) Positioned.fill(child: DecoratedBox(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent, Colors.black87], stops: [0, .5, 1])), child: SafeArea(child: Column(children: [
        Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)), Expanded(child: Text(widget.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))), IconButton(onPressed: widget.onFavorite, icon: Icon(widget.favorite ? Icons.favorite : Icons.favorite_border, color: coral)), PopupMenuButton<String>(icon: const Icon(Icons.more_vert, color: Colors.white), onSelected: (value) {
          if (value.startsWith('speed:')) controller.setPlaybackSpeed(double.parse(value.substring(6)));
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
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(onPressed: () => _seek(-10), icon: const Icon(Icons.replay_10, color: Colors.white, size: 36)), const SizedBox(width: 24), IconButton(onPressed: () => v.isPlaying ? controller.pause() : controller.play(), icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 64)), const SizedBox(width: 24), IconButton(onPressed: () => _seek(10), icon: const Icon(Icons.forward_10, color: Colors.white, size: 36))]),
        const Spacer(),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Column(children: [
          VideoProgressIndicator(controller, allowScrubbing: true, colors: const VideoProgressColors(playedColor: coral, bufferedColor: Colors.white38, backgroundColor: Colors.white24)),
          Row(children: [Text(_time(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)), const Spacer(), Text('-${_time(v.duration - v.position)}', style: const TextStyle(color: Colors.white, fontSize: 12)), IconButton(onPressed: () { setState(() => locked = true); _hideTimer?.cancel(); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); }, icon: const Icon(Icons.lock_open, color: Colors.white))]),
        ])),
      ])))),
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
