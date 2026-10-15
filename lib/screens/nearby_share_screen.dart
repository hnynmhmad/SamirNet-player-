import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/wifi_transfer_service.dart';

const _shareRed = Color(0xFFEF4444);
const _shareBlue = Color(0xFF3979D5);

class NearbyShareScreen extends StatelessWidget {
  const NearbyShareScreen({super.key});

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('نقل الملفات')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFEEEE), Color(0xFFFFF8F5)],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: const Column(
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: _shareRed,
                      child: Icon(Icons.swap_vert_rounded,
                          size: 38, color: Colors.white),
                    ),
                    SizedBox(height: 14),
                    Text('شارك ملفاتك بسهولة',
                        style: TextStyle(
                            fontSize: 23, fontWeight: FontWeight.w900)),
                    SizedBox(height: 8),
                    Text(
                      'انقل الفيديوهات والموسيقى والصور والملفات إلى جهاز قريب عبر شبكة محلية، دون رفعها إلى الإنترنت.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _ActionCard(
                color: _shareRed,
                background: const Color(0xFFFCE8E8),
                icon: Icons.file_upload_outlined,
                title: 'إرسال الملفات',
                subtitle: 'اختر ملفاتك ثم امسح رمز جهاز الاستقبال',
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const _SendScreen())),
              ),
              const SizedBox(height: 14),
              _ActionCard(
                color: _shareBlue,
                background: const Color(0xFFE4EEFC),
                icon: Icons.file_download_outlined,
                title: 'استلام الملفات',
                subtitle: 'اعرض رمز QR ليقوم صديقك بمسحه',
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const _ReceiveScreen())),
              ),
              const SizedBox(height: 18),
              const ListTile(
                leading: Icon(Icons.wifi_tethering_rounded, color: _shareBlue),
                title: Text('نقل محلي دون إنترنت'),
                subtitle: Text(
                    'يمكن استخدام شبكة Wi-Fi أو نقطة اتصال أحد الهاتفين.'),
              ),
            ],
          ),
        ),
      );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.color,
    required this.background,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final Color color;
  final Color background;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: background,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: color,
                  child: Icon(icon, color: Colors.white, size: 29),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 5),
                      Text(subtitle,
                          style: const TextStyle(color: Colors.black54)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_left_rounded),
              ],
            ),
          ),
        ),
      );
}

class _ReceiveScreen extends StatefulWidget {
  const _ReceiveScreen();
  @override
  State<_ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<_ReceiveScreen> {
  final WifiTransferService _service = WifiTransferService();
  List<String> _addresses = [];
  bool _busy = false;
  String? _error;

  Future<void> _start() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _service.start();
      _addresses = await _service.localIpv4Addresses;
      if (_addresses.isEmpty) {
        await _service.stop();
        _error = 'لم نعثر على عنوان شبكة محلية. شغّل Wi-Fi أو اتصل بنقطة اتصال الهاتف الآخر، ثم حاول مجددًا.';
      }
    } catch (e) {
      _error = 'تعذر تشغيل الاستقبال: $e';
      await _service.stop();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    await _service.stop();
    if (mounted) setState(() { _busy = false; _addresses = []; });
  }

  @override
  void dispose() {
    _service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ip = _addresses.isEmpty ? null : _addresses.first;
    final qrData = ip == null || !_service.isRunning
        ? null
        : jsonEncode({
            'app': 'SMPlayerShare',
            'version': 1,
            'url': 'http://$ip:${_service.port}',
            'token': _service.token,
          });
    return Scaffold(
      appBar: AppBar(title: const Text('استلام الملفات')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          const Icon(Icons.phonelink_ring_rounded, size: 68, color: _shareRed),
          const SizedBox(height: 12),
          const Text('جاهز لاستقبال الملفات؟',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text(
            'ابدأ الاستقبال لعرض رمز QR. اجعل الهاتفين على الشبكة المحلية نفسها؛ لا يلزم وجود إنترنت.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          if (qrData != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFF2D7D7))),
                child: QrImageView(data: qrData, size: 230),
              ),
            ),
            const SizedBox(height: 14),
            const Text('امسح هذا الرمز من جهاز المُرسِل',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SelectableText('http://$ip:${_service.port}',
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text('رمز الاتصال البديل', style: TextStyle(fontWeight: FontWeight.bold)),
            SelectableText(_service.token ?? '', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('إيقاف الاستقبال'),
            ),
          ] else
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: _shareRed,
                  padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(_busy ? 'جارٍ التجهيز...' : 'بدء الاستقبال وعرض QR'),
            ),
          if (_busy) const LinearProgressIndicator(color: _shareRed),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: _shareRed),
                textAlign: TextAlign.center),
          ],
          const SizedBox(height: 20),
          const ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text('مكان حفظ الملفات'),
            subtitle: Text('مجلد التطبيق: SM Player'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('إذا لم يظهر الجهاز الآخر'),
            subtitle: Text(
                'تأكد من اتصال الهاتفين بالشبكة نفسها، وأوقف عزل الأجهزة في إعدادات نقطة الاتصال إن كان مفعّلًا.'),
          ),
        ],
      ),
    );
  }
}

class _PickChip extends StatelessWidget {
  const _PickChip({required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => ActionChip(
        avatar: Icon(icon, size: 19, color: _shareRed),
        label: Text(label),
        onPressed: onPressed,
        side: const BorderSide(color: Color(0xFFE8BDBD)),
        backgroundColor: const Color(0xFFFFF5F5),
      );
}

class _SendScreen extends StatefulWidget {
  const _SendScreen();
  @override
  State<_SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<_SendScreen> {
  final List<File> _files = [];
  bool _busy = false;
  int _sent = 0;
  int _total = 0;
  String? _status;
  String? _error;

  Future<void> _pickByType(FileType type, String label) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: type,
        withData: false,
      );
      if (result == null) return;
      final picked = result.files
          .where((f) => f.path != null)
          .map((f) => File(f.path!))
          .where((f) => f.existsSync())
          .toList();
      if (!mounted) return;
      setState(() {
        for (final file in picked) {
          if (!_files.any((old) => old.path == file.path)) _files.add(file);
        }
        _error = null;
        _status = picked.isEmpty ? 'لم يتم اختيار $label' : 'تمت إضافة ${picked.length} ملف';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر اختيار $label: $e');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result != null) {
        final picked = result.files
            .where((f) => f.path != null)
            .map((f) => File(f.path!))
            .where((f) => f.existsSync())
            .toList();
        if (mounted) {
          setState(() {
            for (final file in picked) {
              if (!_files.any((old) => old.path == file.path)) _files.add(file);
            }
            _error = null;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر اختيار الملفات: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return;
      final folder = Directory(path);
      final found = <File>[];
      await for (final entity in folder.list(recursive: true, followLinks: false)) {
        if (entity is File) found.add(entity);
      }
      if (mounted) {
        setState(() {
          for (final file in found) {
            if (!_files.any((old) => old.path == file.path)) _files.add(file);
          }
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر قراءة المجلد: $e');
    }
  }

  Future<String?> _enterConnectionDetails() async {
    final address = TextEditingController();
    final token = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('الاتصال دون QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('أدخل عنوان جهاز الاستقبال ورمز الاتصال الظاهر على هاتف صديقك.'),
            const SizedBox(height: 12),
            TextField(controller: address, decoration: const InputDecoration(labelText: 'العنوان (مثل http://192.168.1.5:12345)', border: OutlineInputBorder()), keyboardType: TextInputType.url),
            const SizedBox(height: 10),
            TextField(controller: token, decoration: const InputDecoration(labelText: 'رمز الاتصال', border: OutlineInputBorder()), autocorrect: false),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            final url = address.text.trim();
            final secret = token.text.trim();
            if (url.isNotEmpty && secret.isNotEmpty) {
              Navigator.pop(dialogContext, jsonEncode({'app': 'SMPlayerShare', 'version': 1, 'url': url, 'token': secret}));
            }
          }, child: const Text('اتصال')),
        ],
      ),
    );
    address.dispose();
    token.dispose();
    return result;
  }

  Future<void> _scanAndSend({bool manual = false}) async {
    if (_files.isEmpty || _busy) return;
    final data = manual ? await _enterConnectionDetails() : await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _ScanReceiverScreen()),
    );
    if (data == null || !mounted) return;
    Map<String, dynamic> target;
    try {
      target = jsonDecode(data) as Map<String, dynamic>;
      if (target['app'] != 'SMPlayerShare' ||
          target['version'] != 1 ||
          target['url'] is! String ||
          target['token'] is! String) {
        throw const FormatException('رمز غير صالح');
      }
      final uri = Uri.parse(target['url'] as String);
      if (uri.scheme != 'http' || uri.host.isEmpty || uri.port == 0) {
        throw const FormatException('عنوان اتصال غير صالح');
      }
    } catch (_) {
      setState(() => _error = 'رمز QR غير صالح. اطلب من صديقك إنشاء رمز جديد.');
      return;
    }

    setState(() { _busy = true; _error = null; _sent = 0; _total = _files.length; _status = 'جارٍ الاتصال بجهاز الاستقبال...'; });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    try {
      for (final file in _files) {
        if (!await file.exists()) throw FileSystemException('الملف غير موجود', file.path);
        final name = file.uri.pathSegments.isEmpty ? 'file.bin' : file.uri.pathSegments.last;
        final uri = Uri.parse(target['url'] as String).replace(
          path: '/upload',
          queryParameters: {'name': name},
        );
        if (mounted) setState(() => _status = 'إرسال $name');
        final request = await client.postUrl(uri);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${target['token']}');
        request.headers.contentType = ContentType.binary;
        request.contentLength = await file.length();
        await request.addStream(file.openRead());
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode != HttpStatus.created) {
          throw HttpException('رفض جهاز الاستقبال الملف (${response.statusCode}): $body', uri: uri);
        }
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        if (decoded['saved'] != true || decoded['sha256'] is! String) {
          throw const HttpException('لم يؤكد جهاز الاستقبال سلامة الملف');
        }
        if (mounted) setState(() => _sent++);
      }
      if (mounted) setState(() => _status = 'اكتمل إرسال جميع الملفات بنجاح');
    } catch (e) {
      if (mounted) setState(() => _error = 'توقف الإرسال: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  String _size(File file) {
    try {
      final bytes = file.lengthSync();
      if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
      if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
      if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
      return '$bytes B';
    } catch (_) { return ''; }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('إرسال الملفات')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _PickChip(icon: Icons.movie_outlined, label: 'الفيديوهات',
                    onPressed: _busy ? null : () => _pickByType(FileType.video, 'الفيديوهات')),
                  _PickChip(icon: Icons.music_note_rounded, label: 'الموسيقى',
                    onPressed: _busy ? null : () => _pickByType(FileType.audio, 'الموسيقى')),
                  _PickChip(icon: Icons.photo_library_outlined, label: 'الصور',
                    onPressed: _busy ? null : () => _pickByType(FileType.image, 'الصور')),
                  _PickChip(icon: Icons.insert_drive_file_outlined, label: 'كل الملفات',
                    onPressed: _busy ? null : _pickFiles),
                  _PickChip(icon: Icons.folder_open_rounded, label: 'المجلدات',
                    onPressed: _busy ? null : _pickFolder),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(child: Text('تم تحديد ${_files.length} ملف',
                      style: const TextStyle(fontWeight: FontWeight.bold))),
                  if (_files.isNotEmpty)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _files.clear()),
                      child: const Text('مسح الكل'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _files.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.drive_folder_upload_outlined,
                                size: 64, color: _shareRed),
                            SizedBox(height: 12),
                            Text('اختر الملفات أو مجلدًا كاملًا',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            SizedBox(height: 6),
                            Text('يمكنك إرسال الفيديوهات والموسيقى والصور وأي ملف يدعمه الجهاز.',
                                textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _files.length,
                      itemBuilder: (context, i) {
                        final file = _files[i];
                        final name = file.uri.pathSegments.isEmpty
                            ? file.path
                            : file.uri.pathSegments.last;
                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFFFCE8E8),
                            child: Icon(Icons.insert_drive_file_outlined,
                                color: _shareRed),
                          ),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_size(file)),
                          trailing: IconButton(
                            tooltip: 'إزالة',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _busy ? null : () => setState(() => _files.removeAt(i)),
                          ),
                        );
                      },
                    ),
            ),
            if (_busy || _status != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Column(
                  children: [
                    if (_busy) LinearProgressIndicator(
                      value: _total == 0 ? null : _sent / _total,
                      color: _shareRed,
                    ),
                    const SizedBox(height: 6),
                    Text(_status ?? 'جارٍ الإرسال...'),
                    if (_total > 0) Text('$_sent من $_total ملف'),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: _shareRed)),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: _shareRed,
                        padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: _busy || _files.isEmpty ? null : _scanAndSend,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('مسح رمز جهاز الاستقبال والإرسال'),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy || _files.isEmpty ? null : () => _scanAndSend(manual: true),
                    icon: const Icon(Icons.link_rounded),
                    label: const Text('الاتصال دون QR'),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

class _ScanReceiverScreen extends StatefulWidget {
  const _ScanReceiverScreen();
  @override
  State<_ScanReceiverScreen> createState() => _ScanReceiverScreenState();
}

class _ScanReceiverScreenState extends State<_ScanReceiverScreen> {
  bool _handled = false;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('مسح رمز جهاز الاستقبال')),
        body: Stack(
          children: [
            MobileScanner(
              errorBuilder: (context, error, child) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.camera_alt_outlined, size: 48, color: Colors.white),
                      const SizedBox(height: 12),
                      Text(
                        'تعذر تشغيل الكاميرا: ${error.errorCode.name}. تأكد من منح إذن الكاميرا وإغلاق أي تطبيق يستخدمها، ثم أعد فتح الماسح.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              onDetect: (capture) {
                if (_handled) return;
                for (final barcode in capture.barcodes) {
                  final value = barcode.rawValue;
                  if (value == null || value.isEmpty) continue;
                  _handled = true;
                  Navigator.pop(context, value);
                  break;
                }
              },
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16)),
                child: const Text(
                  'وجّه الكاميرا نحو رمز QR الظاهر على هاتف المستقبِل.',
                  style: TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      );
}
