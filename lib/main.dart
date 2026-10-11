import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

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
    title: 'SamirNet Player', debugShowCheckedModeBanner: false, locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    themeMode: mode,
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: coral), scaffoldBackgroundColor: const Color(0xFFF8FAFC)),
    darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: ColorScheme.fromSeed(seedColor: coral, brightness: Brightness.dark), scaffoldBackgroundColor: ink),
    home: LibraryScreen(mode: mode, onMode: _setMode),
  );
}

class MediaEntry {
  MediaEntry(this.asset);
  final AssetEntity asset;
  String get id => asset.id;
  String get name => asset.title;
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
    if (mounted) setState(() { loading = true; denied = false; });
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth && !permission.hasAccess) {
        if (mounted) setState(() { denied = true; loading = false; });
        return;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.video, onlyAll: true);
      final assets = paths.isEmpty ? <AssetEntity>[] : await paths.first.getAssetListRange(start: 0, end: 1000);
      if (mounted) setState(() { videos = assets.map(MediaEntry.new).toList(); loading = false; });
    } catch (_) { if (mounted) setState(() => loading = false); }
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
        Text('SamirNet Player', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        Text('مشغّل الوسائط الخاص بك', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    ]), actions: [
      IconButton(tooltip: 'تحديث المكتبة', onPressed: _scan, icon: const Icon(Icons.refresh_rounded)),
      IconButton(tooltip: 'نقل عبر Wi-Fi', onPressed: () => _toast('ميزة نقل Wi-Fi ضمن مرحلة التطوير التالية'), icon: const Icon(Icons.wifi_rounded)),
    ]),
    body: tab == 4 ? _settings() : tab == 1 ? _folders() : _library(),
    bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: const [
      NavigationDestination(icon: Icon(Icons.video-library_outlined), selectedIcon: Icon(Icons.video-library), label: 'الرئيسية'),
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
        const SizedBox(height: 4), Text(videos.length.toString() + ' فيديو على الجهاز', style: const TextStyle(color: Colors.grey)),
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
      else if (denied) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.perm_media_outlined, 'نحتاج إلى إذن الوصول للوسائط', 'اسمح بالوصول إلى الفيديوهات المحلية.', 'إعادة المحاولة', _scan))
      else if (items.isEmpty) SliverFillRemaining(hasScrollBody: false, child: _empty(Icons.video_library_outlined, query.isNotEmpty ? 'لا توجد نتائج' : 'لم نعثر على فيديوهات', 'أضف فيديو إلى الهاتف ثم حدّث المكتبة.', 'تحديث المكتبة', _scan))
      else if (grid) SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverGrid(delegate: SliverChildBuilderDelegate((context, i) => _videoCard(items[i], true), childCount: items.length), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: .82)))
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
      ...groups.entries.map((e) => Card(child: ExpansionTile(leading: const Icon(Icons.folder, color: coral), title: Text(e.key.isEmpty ? 'المجلد الرئيسي' : e.key), subtitle: Text(e.value.length.toString() + ' فيديو'), children: e.value.map((v) => ListTile(title: Text(v.name), leading: const Icon(Icons.movie_outlined), onTap: () => _play(v))).toList()))),
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
      const ListTile(leading: Icon(Icons.lock_outline), title: Text('الخزنة الخاصة'), subtitle: Text('التشفير قيد التطوير')),
      const ListTile(leading: Icon(Icons.wifi), title: Text('نقل عبر Wi-Fi'), subtitle: Text('النقل المحلي قيد التطوير')),
    ])),
    const SizedBox(height: 20), const Center(child: Text('SamirNet Player · 0.1.0', style: TextStyle(color: Colors.grey))),
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
  bool ready = false, controls = true, locked = false;
  @override
  void initState() { super.initState(); controller = VideoPlayerController.file(widget.file)..initialize().then((_) { if (mounted) setState(() => ready = true); controller.play(); }); controller.addListener(_update); }
  void _update() { if (mounted) setState(() {}); }
  @override
  void dispose() { controller.removeListener(_update); controller.dispose(); SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); super.dispose(); }
  void _seek(int seconds) { final target = controller.value.position + Duration(seconds: seconds); controller.seekTo(target < Duration.zero ? Duration.zero : target); }
  String _time(Duration d) { final h = d.inHours; final m = d.inMinutes.remainder(60).toString().padLeft(2, '0'); final s = d.inSeconds.remainder(60).toString().padLeft(2, '0'); return h > 0 ? '$h:$m:$s' : '$m:$s'; }
  @override
  Widget build(BuildContext context) {
    final v = controller.value;
    return Directionality(textDirection: TextDirection.ltr, child: Scaffold(backgroundColor: Colors.black, body: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () { if (!locked) setState(() => controls = !controls); }, onDoubleTapDown: (d) { if (!locked) _seek(d.localPosition.dx > MediaQuery.sizeOf(context).width / 2 ? 10 : -10); }, child: Stack(alignment: Alignment.center, children: [
      if (ready) Center(child: AspectRatio(aspectRatio: v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio, child: VideoPlayer(controller))) else if (v.hasError) const Center(child: Text('تعذّر تشغيل هذا الملف', style: TextStyle(color: Colors.white))) else const CircularProgressIndicator(color: coral),
      if (controls && !locked) Positioned.fill(child: DecoratedBox(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent, Colors.black87], stops: [0, .5, 1])), child: SafeArea(child: Column(children: [
        Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Colors.white)), Expanded(child: Text(widget.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white))), IconButton(onPressed: widget.onFavorite, icon: Icon(widget.favorite ? Icons.favorite : Icons.favorite_border, color: coral)), PopupMenuButton<double>(icon: const Icon(Icons.speed, color: Colors.white), onSelected: controller.setPlaybackSpeed, itemBuilder: (_) => [0.5, .75, 1.0, 1.25, 1.5, 2.0].map((s) => PopupMenuItem(value: s, child: Text(s.toString() + 'x'))).toList())]),
        const Spacer(),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(onPressed: () => _seek(-10), icon: const Icon(Icons.replay_10, color: Colors.white, size: 36)), const SizedBox(width: 24), IconButton(onPressed: () => v.isPlaying ? controller.pause() : controller.play(), icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill, color: Colors.white, size: 64)), const SizedBox(width: 24), IconButton(onPressed: () => _seek(10), icon: const Icon(Icons.forward_10, color: Colors.white, size: 36))]),
        const Spacer(),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Column(children: [
          VideoProgressIndicator(controller, allowScrubbing: true, colors: const VideoProgressColors(playedColor: coral, bufferedColor: Colors.white38, backgroundColor: Colors.white24)),
          Row(children: [Text(_time(v.position), style: const TextStyle(color: Colors.white, fontSize: 12)), const Spacer(), Text('-' + _time(v.duration - v.position), style: const TextStyle(color: Colors.white, fontSize: 12)), IconButton(onPressed: () { setState(() => locked = true); SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); }, icon: const Icon(Icons.lock_open, color: Colors.white))]),
        ])),
      ])))),
      if (locked) Positioned(left: 16, bottom: 32, child: IconButton.filledTonal(onPressed: () { setState(() { locked = false; controls = true; }); SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); }, icon: const Icon(Icons.lock))),
    ])));
  }
}
