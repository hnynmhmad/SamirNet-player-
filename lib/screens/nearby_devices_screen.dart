import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';

const _serviceId = 'com.samirnet.snplayer.nearbyshare';
const _nearbyRed = Color(0xFFEF4444);

/// Android Nearby Connections: discovers and transfers directly device-to-device
/// using Google's local peer-to-peer transport; no internet server is involved.
class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key, required this.receiveMode});
  final bool receiveMode;

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen> {
  final Nearby _nearby = Nearby();
  final Map<String, String> _devices = {};
  final Set<String> _connected = {};
  final Map<int, String> _incomingNames = {};
  List<File> _files = [];
  bool _running = false;
  bool _busy = false;
  String _status = 'جاهز';
  String? _error;

  String get _deviceName => 'SM Player - ${Platform.localHostname.isEmpty ? 'Android' : Platform.localHostname}';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_running || _busy) return;
    setState(() { _busy = true; _error = null; _status = 'جارٍ تهيئة الاتصال القريب...'; });
    try {
      if (widget.receiveMode) {
        final started = await _nearby.startAdvertising(
          _deviceName,
          Strategy.P2P_CLUSTER,
          serviceId: _serviceId,
          onConnectionInitiated: (id, info) async {
            if (!mounted) return;
            setState(() => _status = 'طلب اتصال من ${info.endpointName}');
            await _nearby.acceptConnection(
              id,
              onPayLoadRecieved: _onPayload,
            );
          },
          onConnectionResult: (id, status) {
            if (!mounted) return;
            setState(() {
              if (status == Status.CONNECTED) {
                _connected.add(id);
                _status = 'تم الاتصال بجهاز مرسل';
              } else {
                _connected.remove(id);
                _status = 'تعذر الاتصال: $status';
              }
            });
          },
          onDisconnected: (id) {
            if (mounted) setState(() { _connected.remove(id); _status = 'انقطع الاتصال'; });
          },
        );
        if (!started) throw Exception('لم يتمكن Android من تشغيل استقبال الأجهزة القريبة');
      } else {
        final started = await _nearby.startDiscovery(
          _deviceName,
          Strategy.P2P_CLUSTER,
          serviceId: _serviceId,
          onEndpointFound: (id, name, serviceId) {
            if (!mounted) return;
            setState(() { _devices[id] = name; _status = 'تم العثور على جهاز قريب'; });
          },
          onEndpointLost: (id) {
            if (mounted) setState(() => _devices.remove(id));
          },
        );
        if (!started) throw Exception('لم يتمكن Android من البحث عن الأجهزة القريبة');
      }
      if (mounted) setState(() { _running = true; _status = widget.receiveMode ? 'جهازك ظاهر للأجهزة القريبة — انتظر اتصال المرسل' : 'جارٍ البحث عن أجهزة SM Player القريبة...'; });
    } catch (e) {
      if (mounted) setState(() { _error = 'تعذر تشغيل الاتصال القريب. تحقق من تفعيل Bluetooth وWi-Fi والموقع وصلاحيات الأجهزة القريبة، ثم حاول مجددًا. التفاصيل: $e'; _status = 'تعذر البدء'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onPayload(String endpointId, Payload payload) async {
    try {
      if (payload.type == PayloadType.BYTES && payload.bytes != null) {
        final text = utf8.decode(payload.bytes!, allowMalformed: true);
        if (text.startsWith('SMFILE:')) {
          final parts = text.substring(7).split(':');
          if (parts.length >= 2) _incomingNames[int.tryParse(parts.first) ?? -1] = parts.sublist(1).join(':');
        }
      } else if (payload.type == PayloadType.FILE && payload.uri != null) {
        final docs = await getApplicationDocumentsDirectory();
        final folder = Directory('${docs.path}/wifi_received');
        if (!await folder.exists()) await folder.create(recursive: true);
        final name = _incomingNames.remove(payload.id) ?? 'received_${payload.id}.bin';
        final safeName = name.split(RegExp(r'[/\\\\]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        final destination = '${folder.path}/${DateTime.now().millisecondsSinceEpoch}_$safeName';
        await _nearby.copyFileAndDeleteOriginal(payload.uri!, destination);
        if (mounted) setState(() => _status = 'تم استلام وحفظ $safeName');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'حدث خطأ أثناء حفظ الملف المستلم: $e');
    }
  }

  Future<void> _connect(String id) async {
    setState(() { _busy = true; _status = 'جارٍ طلب الاتصال...'; _error = null; });
    try {
      await _nearby.requestConnection(
        _deviceName,
        id,
        onConnectionInitiated: (endpointId, info) async {
          await _nearby.acceptConnection(endpointId, onPayLoadRecieved: _onPayload);
        },
        onConnectionResult: (endpointId, status) {
          if (!mounted) return;
          setState(() {
            if (status == Status.CONNECTED) {
              _connected.add(endpointId);
              _status = 'اتصلت بـ ${_devices[endpointId] ?? 'الجهاز القريب'}';
            } else {
              _status = 'رفض الجهاز الاتصال أو فشل: $status';
            }
          });
        },
        onDisconnected: (endpointId) {
          if (mounted) setState(() => _connected.remove(endpointId));
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'فشل الاتصال: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (result == null || !mounted) return;
    setState(() {
      _files = result.files.where((f) => f.path != null).map((f) => File(f.path!)).where((f) => f.existsSync()).toList();
      _error = null;
    });
  }

  Future<void> _sendFiles(String endpointId) async {
    if (_files.isEmpty) {
      await _pickFiles();
      if (_files.isEmpty) return;
    }
    setState(() { _busy = true; _error = null; _status = 'جارٍ إرسال الملفات عبر الاتصال القريب...'; });
    try {
      for (final file in _files) {
        final name = file.uri.pathSegments.isEmpty ? 'file.bin' : file.uri.pathSegments.last;
        final payloadId = await _nearby.sendFilePayload(endpointId, file.path);
        await _nearby.sendBytesPayload(endpointId, utf8.encode('SMFILE:$payloadId:$name'));
        if (mounted) setState(() => _status = 'أُرسل $name');
      }
      if (mounted) setState(() => _status = 'اكتمل إرسال الملفات');
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر إرسال الملفات: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    try {
      await _nearby.stopDiscovery();
      await _nearby.stopAdvertising();
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _nearby.stopDiscovery();
    _nearby.stopAdvertising();
    _nearby.stopAllEndpoints();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.receiveMode ? 'استلام من جهاز قريب' : 'إرسال إلى جهاز قريب'),
      actions: [IconButton(onPressed: _stop, icon: const Icon(Icons.close))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: const Color(0xFFFFEEEE), borderRadius: BorderRadius.circular(20)),
          child: Column(children: [
            Icon(widget.receiveMode ? Icons.phonelink_ring : Icons.radar_rounded, size: 54, color: _nearbyRed),
            const SizedBox(height: 8),
            Text(widget.receiveMode ? 'جهازك جاهز للاستلام' : 'الأجهزة القريبة', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(_status, textAlign: TextAlign.center),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator(color: _nearbyRed)),
          ]),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: _nearbyRed))),
        if (!widget.receiveMode) ...[
          const SizedBox(height: 18),
          if (_devices.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('ضع الهاتفين قريبين من بعضهما وافتح شاشة الاستلام في الهاتف الآخر.', textAlign: TextAlign.center)),
          for (final entry in _devices.entries)
            Card(child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.phone_android)),
              title: Text(entry.value),
              subtitle: Text(_connected.contains(entry.key) ? 'متصل' : 'جهاز قريب'),
              trailing: _connected.contains(entry.key)
                ? FilledButton(onPressed: _busy ? null : () => _sendFiles(entry.key), child: const Text('إرسال'))
                : FilledButton(onPressed: _busy ? null : () => _connect(entry.key), child: const Text('اتصال')),
            )),
          if (_connected.isNotEmpty) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: _busy ? null : _pickFiles, icon: const Icon(Icons.attach_file), label: Text(_files.isEmpty ? 'اختيار الملفات' : 'تم اختيار ${_files.length} ملف')),
            if (_files.isNotEmpty) FilledButton.icon(onPressed: _busy ? null : () => _sendFiles(_connected.first), icon: const Icon(Icons.send), label: const Text('إرسال الملفات المحددة')),
          ],
        ] else const Padding(padding: EdgeInsets.all(18), child: Text('اترك هذه الشاشة مفتوحة. عندما يتصل صديقك سيظهر تأكيد الاتصال ويمكنه إرسال الملفات مباشرة إلى هذا الهاتف.', textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        const Text('النقل مباشر بين الجهازين باستخدام اتصال Android القريب، ولا يحتاج إلى إنترنت. إذا طلب Android تفعيل Bluetooth أو صلاحيات الأجهزة القريبة، وافق على الطلب.', textAlign: TextAlign.center),
      ],
    ),
  );
}
