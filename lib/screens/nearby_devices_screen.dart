import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const _nearbyServiceId = 'com.samirnet.snplayer.transfer';
const _nearbyRed = Color(0xFFEF4444);

/// Direct, internet-free device transfer using Google Nearby Connections.
/// Both devices can send and receive after the connection is accepted.
class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key, required this.receiveMode});

  final bool receiveMode;

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen> {
  final Nearby _nearby = Nearby();
  final Map<String, ConnectionInfo> _connected = {};
  final Map<String, String> _discovered = {};
  final List<File> _queue = [];
  final Map<int, String> _receivedNames = {};
  final Map<int, String> _receivedUris = {};
  final Set<int> _completedPayloads = {};
  final Map<int, int> _progressBytes = {};
  final Map<int, int> _progressTotals = {};

  bool _starting = false;
  bool _advertising = false;
  bool _discovering = false;
  bool _sending = false;
  String? _error;
  String? _status;
  String _localName = 'SM Player';

  @override
  void initState() {
    super.initState();
    _localName = 'SM Player ${DateTime.now().millisecondsSinceEpoch % 10000}';
    _start();
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) {
      _error = 'النقل المباشر متاح حاليًا على Android فقط.';
      return false;
    }
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    final denied = statuses.entries
        .where((entry) => entry.value.isDenied || entry.value.isPermanentlyDenied)
        .map((entry) => entry.key.toString().split('.').last)
        .toList();
    if (denied.isNotEmpty) {
      _error = 'يلزم السماح بصلاحيات الاتصال بالأجهزة القريبة. افتح أذونات التطبيق وحاول مجددًا.';
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    if (_starting || _advertising || _discovering) return;
    setState(() {
      _starting = true;
      _error = null;
      _status = 'جارٍ تجهيز الاتصال المباشر...';
    });
    try {
      if (!await _requestPermissions()) return;
      if (widget.receiveMode) {
        _advertising = await _nearby.startAdvertising(
          _localName,
          Strategy.P2P_STAR,
          onConnectionInitiated: _onConnectionInitiated,
          onConnectionResult: _onConnectionResult,
          onDisconnected: _onDisconnected,
          serviceId: _nearbyServiceId,
        );
        if (!_advertising) {
          throw Exception('لم يتمكن Android من إظهار هذا الهاتف للأجهزة القريبة.');
        }
        _status = 'هاتفك ظاهر للأجهزة القريبة. اقبل طلب الاتصال عندما يظهر.';
      } else {
        _discovering = await _nearby.startDiscovery(
          _localName,
          Strategy.P2P_STAR,
          onEndpointFound: (id, name, serviceId) {
            if (serviceId != _nearbyServiceId || !mounted) return;
            setState(() {
              _discovered[id] = name;
              _status = 'تم العثور على جهاز قريب.';
            });
          },
          onEndpointLost: (id) {
            if (id != null && mounted) setState(() => _discovered.remove(id));
          },
          serviceId: _nearbyServiceId,
        );
        if (!_discovering) {
          throw Exception('تعذر بدء البحث عن الأجهزة القريبة.');
        }
        _status = 'جارٍ البحث عن أجهزة SM Player القريبة دون إنترنت...';
      }
    } catch (e) {
      _error = 'تعذر بدء الاتصال: $e';
      await _stopDiscoveryAndAdvertising();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('طلب اتصال قريب'),
        content: Text(
          'الجهاز: ${info.endpointName}\nرمز التحقق: ${info.authenticationToken}\nتأكد أن الرمز متطابق على الهاتفين قبل القبول.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _nearby.rejectConnection(id);
            },
            child: const Text('رفض'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              try {
                await _nearby.acceptConnection(
                  id,
                  onPayLoadRecieved: _onPayloadReceived,
                  onPayloadTransferUpdate: _onPayloadTransferUpdate,
                );
                if (mounted) {
                  setState(() {
                    _connected[id] = info;
                    _status = 'اتصلت بـ ${info.endpointName}. يمكنك الإرسال والاستقبال.';
                    _error = null;
                  });
                }
              } catch (e) {
                if (mounted) setState(() => _error = 'تعذر قبول الاتصال: $e');
              }
            },
            child: const Text('قبول الاتصال'),
          ),
        ],
      ),
    );
  }

  void _onConnectionResult(String id, Status status) {
    if (!mounted) return;
    setState(() {
      _status = 'نتيجة الاتصال: $status';
      if (status != Status.CONNECTED) {
        _connected.remove(id);
      }
    });
  }

  void _onDisconnected(String id) {
    if (!mounted) return;
    setState(() {
      _connected.remove(id);
      _status = 'انقطع اتصال أحد الأجهزة.';
    });
  }

  Future<void> _connect(String id, String name) async {
    try {
      setState(() {
        _status = 'جارٍ الاتصال بـ $name...';
        _error = null;
      });
      await _nearby.requestConnection(
        _localName,
        id,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر الاتصال بالجهاز: $e');
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (!mounted) return;
    if (payload.type == PayloadType.BYTES && payload.bytes != null) {
      final message = utf8.decode(payload.bytes!, allowMalformed: true);
      if (message.startsWith('SMFILE1|')) {
        final parts = message.split('|');
        if (parts.length >= 3) {
          final id = int.tryParse(parts[1]);
          if (id != null) {
            _receivedNames[id] = _safeFileName(parts.sublist(2).join('|'));
            _tryFinalizeReceivedFile(id);
          }
        }
      } else {
        setState(() => _status = 'وصلت رسالة من الجهاز الآخر.');
      }
    } else if (payload.type == PayloadType.FILE && payload.uri != null) {
      _receivedUris[payload.id] = payload.uri!;
      _tryFinalizeReceivedFile(payload.id);
    }
  }

  void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (!mounted) return;
    if (update.status == PayloadStatus.IN_PROGRESS) {
      setState(() {
        _progressBytes[update.id] = update.bytesTransferred;
        _progressTotals[update.id] = update.totalBytes;
        _status = 'جارٍ نقل ملف: ${_formatBytes(update.bytesTransferred)} من ${_formatBytes(update.totalBytes)}';
      });
    } else if (update.status == PayloadStatus.FAILURE) {
      setState(() => _error = 'فشل نقل أحد الملفات. افحص الاتصال ثم أعد المحاولة.');
    } else if (update.status == PayloadStatus.SUCCESS) {
      _completedPayloads.add(update.id);
      _tryFinalizeReceivedFile(update.id);
      setState(() {
        _progressBytes[update.id] = update.totalBytes;
        _progressTotals[update.id] = update.totalBytes;
        _status = 'اكتمل نقل ملف (${_formatBytes(update.totalBytes)}).';
      });
    }
  }

  Future<void> _tryFinalizeReceivedFile(int payloadId) async {
    final uri = _receivedUris[payloadId];
    final name = _receivedNames[payloadId];
    if (uri == null || name == null || !_completedPayloads.contains(payloadId)) return;
    _receivedUris.remove(payloadId);
    _receivedNames.remove(payloadId);
    _completedPayloads.remove(payloadId);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final inbox = Directory('${docs.path}/SM Player/Received');
      await inbox.create(recursive: true);
      final destination = await _uniqueFile(inbox, name);
      final saved = await _nearby.copyFileAndDeleteOriginal(uri, destination.path);
      if (!saved) throw Exception('لم يتمكن التطبيق من حفظ الملف المستلم.');
      if (mounted) setState(() => _status = 'تم استلام الملف وحفظه: ${destination.path}');
    } catch (e) {
      if (mounted) setState(() => _error = 'وصل الملف لكن تعذر حفظه: $e');
    }
  }

  Future<File> _uniqueFile(Directory directory, String name) async {
    var candidate = File('${directory.path}/$name');
    if (!await candidate.exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var suffix = 1;
    while (await candidate.exists()) {
      candidate = File('${directory.path}/$stem ($suffix)$ext');
      suffix++;
    }
    return candidate;
  }

  String _safeFileName(String name) {
    final leaf = name.split(RegExp(r'[/\\\\]')).last.trim();
    final safe = leaf.replaceAll(RegExp(r'[^A-Za-z0-9._ ()-]'), '_');
    return safe.isEmpty || safe == '.' || safe == '..' ? 'received_file.bin' : safe;
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || !mounted) return;
      final additions = result.files
          .where((f) => f.path != null)
          .map((f) => File(f.path!))
          .where((f) => f.existsSync());
      setState(() {
        for (final file in additions) {
          if (!_queue.any((old) => old.path == file.path)) _queue.add(file);
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر اختيار الملفات: $e');
    }
  }

  Future<void> _pickFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null) return;
      final found = <File>[];
      await for (final entity in Directory(path).list(recursive: true, followLinks: false)) {
        if (entity is File) found.add(entity);
      }
      if (mounted) {
        setState(() {
          for (final file in found) {
            if (!_queue.any((old) => old.path == file.path)) _queue.add(file);
          }
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر قراءة المجلد: $e');
    }
  }

  Future<void> _sendQueue() async {
    if (_queue.isEmpty || _connected.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _status = 'جارٍ إرسال الملفات إلى الأجهزة المتصلة...';
      _error = null;
    });
    final pending = List<File>.from(_queue);
    try {
      for (final file in pending) {
        if (!await file.exists()) continue;
        for (final endpointId in _connected.keys.toList()) {
          final payloadId = await _nearby.sendFilePayload(endpointId, file.path);
          await _nearby.sendBytesPayload(
            endpointId,
            Uint8List.fromList(utf8.encode('SMFILE1|$payloadId|${file.uri.pathSegments.last}')),
          );
        }
        if (mounted) setState(() => _queue.remove(file));
      }
      if (mounted) setState(() => _status = 'تمت جدولة جميع الملفات للإرسال.');
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر إرسال الملفات: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _stopDiscoveryAndAdvertising() async {
    try {
      await _nearby.stopDiscovery();
    } catch (_) {}
    try {
      await _nearby.stopAdvertising();
    } catch (_) {}
    _discovering = false;
    _advertising = false;
  }

  Future<void> _disconnect() async {
    try {
      await _nearby.stopAllEndpoints();
    } catch (_) {}
    await _stopDiscoveryAndAdvertising();
    if (mounted) {
      setState(() {
        _connected.clear();
        _discovered.clear();
        _status = 'تم إيقاف الاتصال.';
      });
    }
  }

  @override
  void dispose() {
    _nearby.stopAllEndpoints();
    _stopDiscoveryAndAdvertising();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.receiveMode ? 'استلام من جهاز قريب' : 'إرسال إلى جهاز قريب'),
            actions: [
              IconButton(
                tooltip: 'إعادة البحث',
                onPressed: _starting ? null : _start,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEEEE),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.wifi_tethering_rounded, color: _nearbyRed, size: 42),
                    SizedBox(height: 8),
                    Text('نقل مباشر دون إنترنت', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    SizedBox(height: 6),
                    Text('يستخدم التطبيق اتصالًا مشفرًا بين الجهازين. لا يلزم راوتر أو رفع الملفات إلى موقع خارجي.', textAlign: TextAlign.center),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_starting) const LinearProgressIndicator(color: _nearbyRed),
              if (_status != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(_status!))),
              if (_error != null) Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
              if (!widget.receiveMode) ...[
                const SizedBox(height: 8),
                const Text('الأجهزة المكتشفة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                if (_discovered.isEmpty) const ListTile(leading: Icon(Icons.radar), title: Text('جارٍ البحث عن أجهزة قريبة...'), subtitle: Text('افتح شاشة الاستلام على الهاتف الآخر.')),
                ..._discovered.entries.map((entry) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.smartphone_rounded, color: _nearbyRed),
                    title: Text(entry.value),
                    subtitle: const Text('جهاز SM Player قريب'),
                    trailing: FilledButton(onPressed: _connected.containsKey(entry.key) ? null : () => _connect(entry.key, entry.value), child: const Text('اتصال')),
                  ),
                )),
              ] else
                const ListTile(leading: Icon(Icons.visibility_rounded, color: _nearbyRed), title: Text('هذا الهاتف في وضع الاستقبال'), subtitle: Text('افتح شاشة الإرسال على الهاتف الآخر واختر هذا الجهاز.')),
              const SizedBox(height: 8),
              Text('الأجهزة المتصلة: ${_connected.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (_connected.isNotEmpty) ...[
                ..._connected.entries.map((e) => ListTile(leading: const Icon(Icons.link_rounded, color: Colors.green), title: Text(e.value.endpointName), subtitle: const Text('متصل — يمكن الإرسال والاستقبال'))),
                OutlinedButton.icon(onPressed: _disconnect, icon: const Icon(Icons.link_off_rounded), label: const Text('قطع الاتصال')),
              ],
              const Divider(height: 28),
              const Text('إرسال ملفات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: _pickFiles, icon: const Icon(Icons.attach_file), label: const Text('اختيار ملفات'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: _pickFolder, icon: const Icon(Icons.folder_open), label: const Text('إضافة مجلد'))),
              ]),
              if (_queue.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('${_queue.length} ملف في قائمة الإرسال', style: const TextStyle(fontWeight: FontWeight.bold)),
                ..._queue.map((file) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(file.uri.pathSegments.isEmpty ? file.path : file.uri.pathSegments.last, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_formatBytes(file.lengthSync())),
                  trailing: IconButton(onPressed: _sending ? null : () => setState(() => _queue.remove(file)), icon: const Icon(Icons.close_rounded)),
                )),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _nearbyRed, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: _connected.isEmpty || _sending ? null : _sendQueue,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_sending ? 'جارٍ الإرسال...' : 'إرسال الملفات المحددة'),
                ),
              ],
              if (_progressTotals.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('تقدم النقل', style: TextStyle(fontWeight: FontWeight.bold)),
                ..._progressTotals.entries.map((entry) {
                  final sent = _progressBytes[entry.key] ?? 0;
                  final total = entry.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_formatBytes(sent)} / ${_formatBytes(total)}'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: total <= 0 ? null : (sent / total).clamp(0.0, 1.0), color: _nearbyRed),
                    ]),
                  );
                }),
              ],
              const SizedBox(height: 16),
              const Text('ملاحظة: قد يطلب Android تفعيل Bluetooth أو خدمات الموقع/الأجهزة القريبة. اتبع طلبات النظام، ولا يلزم تشغيل بيانات الهاتف أو الإنترنت.', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
