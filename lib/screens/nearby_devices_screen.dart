import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'transfer_media_picker_screen.dart';

const _nearbyServiceId = 'com.samirnet.snplayer.transfer';
const _nearbyRed = Color(0xFFEF4444);

/// Direct, internet-free device transfer using Google Nearby Connections.
/// Both devices can send and receive after the connection is accepted.
class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key, required this.receiveMode, this.initialFiles = const []});

  final bool receiveMode;
  final List<File> initialFiles;

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
  final Map<int, String> _receivedDigests = {};
  final Set<int> _completedPayloads = {};
  final Map<int, int> _progressBytes = {};
  final Map<int, int> _progressTotals = {};
  final Map<int, String> _progressNames = {};

  bool _starting = false;
  bool _advertising = false;
  bool _discovering = false;
  bool _sending = false;
  String? _error;
  String? _status;
  String _localName = 'SM Player';
  String? _scanTargetName;
  bool _scanHandled = false;

  @override
  void initState() {
    super.initState();
    _localName = 'SM Player ${DateTime.now().millisecondsSinceEpoch % 10000}';
    _queue.addAll(widget.initialFiles.where((file) => file.existsSync()));
    _start();
  }

  Future<bool> _requestPermissions() async {
    if (!Platform.isAndroid) {
      _error = 'النقل المباشر متاح حاليًا على Android فقط.';
      return false;
    }
    final android = await DeviceInfoPlugin().androidInfo;
    final sdk = android.version.sdkInt;
    final requiredPermissions = <Permission>[
      if (sdk >= 31) ...[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ] else ...[
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ],
      if (sdk >= 33) Permission.nearbyWifiDevices,
    ];
    final statuses = await requiredPermissions.request();
    final denied = statuses.entries
        .where((entry) => entry.value.isDenied || entry.value.isPermanentlyDenied)
        .map((entry) => entry.key.toString().split('.').last)
        .toList();
    if (denied.isNotEmpty) {
      _error = 'يلزم السماح بصلاحيات الاتصال بالأجهزة القريبة. افتح أذونات التطبيق وحاول مجددًا.';
      return false;
    }
    if (sdk <= 32) {
      final locationService = await Permission.location.serviceStatus;
      if (!locationService.isEnabled) {
        _error = 'فعّل خدمة الموقع من إعدادات الهاتف؛ يحتاجها Android القديم لاكتشاف الأجهزة القريبة، ولا يلزم تشغيل الإنترنت.';
        return false;
      }
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
          Strategy.P2P_POINT_TO_POINT,
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
          Strategy.P2P_POINT_TO_POINT,
          onEndpointFound: (id, name, serviceId) {
            if (serviceId != _nearbyServiceId || !mounted) return;
            setState(() {
              _discovered[id] = name;
              _status = 'تم العثور على جهاز قريب.';
              if (_scanTargetName != null && name == _scanTargetName && !_connected.containsKey(id)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _connect(id, name);
                });
              }
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
      _error = 'تعذر بدء الاتصال: $e. تأكد من تفعيل Bluetooth وWi-Fi والأجهزة القريبة على الهاتفين، ولا يلزم الإنترنت.';
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
            _receivedNames[id] = _safeFileName(Uri.decodeComponent(parts[2]));
            if (parts.length >= 4 &&
                parts[3].length == 64 &&
                parts[3].codeUnits.every((code) =>
                    (code >= 48 && code <= 57) ||
                    (code >= 65 && code <= 70) ||
                    (code >= 97 && code <= 102))) {
              _receivedDigests[id] = parts[3].toLowerCase();
              _progressNames[id] = _receivedNames[id]!;
            }
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
    final expectedDigest = _receivedDigests[payloadId];
    if (uri == null || name == null || expectedDigest == null || !_completedPayloads.contains(payloadId)) return;
    _receivedUris.remove(payloadId);
    _receivedNames.remove(payloadId);
    _receivedDigests.remove(payloadId);
    _completedPayloads.remove(payloadId);
    try {
      var inbox = Directory('/storage/emulated/0/Download/SM Player Received');
      if (!await inbox.parent.exists()) {
        inbox = Directory('/sdcard/Download/SM Player Received');
      }
      await inbox.create(recursive: true);
      final destination = await _uniqueFile(inbox, name);
      final saved = await _nearby.copyFileAndDeleteOriginal(uri, destination.path);
      if (!saved) throw Exception('لم يتمكن التطبيق من حفظ الملف المستلم.');
      final actualDigest = (await sha256.bind(destination.openRead()).first).toString();
      if (actualDigest != expectedDigest) {
        await destination.delete();
        throw Exception('فشل التحقق من سلامة الملف بعد النقل؛ حُذف الملف غير المطابق.');
      }
      if (mounted) setState(() => _status = 'تم استلام الملف والتحقق من سلامته: ${destination.path}');
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
    final safe = leaf.replaceAll(RegExp(r'[\x00-\x1F<>:"/\\|?*]'), '_').trim();
    return safe.isEmpty || safe == '.' || safe == '..' ? 'received_file.bin' : safe;
  }

  Future<void> _scanQr() async {
    _scanHandled = false;
    try {
      final cameraPermission = await Permission.camera.request();
      if (!cameraPermission.isGranted) {
        if (mounted) {
          setState(() => _error = cameraPermission.isPermanentlyDenied
              ? 'إذن الكاميرا مرفوض نهائيًا. افتح إعدادات التطبيق واسمح باستخدام الكاميرا.'
              : 'يجب السماح باستخدام الكاميرا لمسح رمز QR.');
        }
        if (cameraPermission.isPermanentlyDenied) {
          await openAppSettings();
        }
        return;
      }

      final controller = MobileScannerController(
        facing: CameraFacing.back,
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
      );
      try {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.all(18),
            child: SizedBox(
              height: 460,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    const Expanded(child: Text('امسح رمز QR الخاص بالمستلم', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
                    IconButton(onPressed: () => Navigator.pop(dialogContext), icon: const Icon(Icons.close)),
                  ]),
                ),
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: MobileScanner(
                    controller: controller,
                    errorBuilder: (context, error, child) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'تعذر تشغيل الكاميرا: ${error.errorCode.name}. تحقق من إذن الكاميرا وأغلق أي تطبيق آخر يستخدمها ثم حاول مجددًا.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    onDetect: (capture) {
                      if (_scanHandled || capture.barcodes.isEmpty) return;
                      final value = capture.barcodes.first.rawValue;
                      if (value == null || !value.startsWith('SMPLAYER|')) return;
                      final target = value.substring('SMPLAYER|'.length).trim();
                      if (target.isEmpty) return;
                      _scanHandled = true;
                      _scanTargetName = target;
                      Navigator.pop(dialogContext);
                      if (mounted) {
                        setState(() {
                          _status = 'تم مسح رمز الجهاز $target. جارٍ إنشاء الاتصال المباشر...';
                          _error = null;
                        });
                        final match = _discovered.entries.where((entry) => entry.value == target).firstOrNull;
                        if (match != null) {
                          _connect(match.key, match.value);
                        } else {
                          _status = 'تمت قراءة الرمز. انتظر ظهور الجهاز المستلم في البحث؛ سيُطلب الاتصال تلقائيًا.';
                        }
                      }
                    },
                  ),
                )),
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('يجب أن يكون الهاتف المستلم في وضع الاستقبال وقريبًا منك. لا يلزم الإنترنت.', textAlign: TextAlign.center),
                ),
              ]),
            ),
          ),
        );
      } finally {
        await controller.dispose();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر فتح ماسح QR: $e');
    }
  }

  Future<void> _pickMediaFiles() async {
    try {
      final result = await Navigator.push<List<File>>(
        context,
        MaterialPageRoute(builder: (_) => const TransferMediaPickerScreen()),
      );
      if (result == null || !mounted) return;
      setState(() {
        for (final file in result) {
          if (!_queue.any((old) => old.path == file.path)) _queue.add(file);
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر إضافة الوسائط: $e');
    }
  }

  Future<void> _pickOtherFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || !mounted) return;
      setState(() {
        for (final picked in result.files) {
          final path = picked.path;
          if (path == null) continue;
          final file = File(path);
          if (file.existsSync() && !_queue.any((old) => old.path == path)) {
            _queue.add(file);
          }
        }
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر اختيار الملفات الأخرى: $e');
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
          _progressNames[payloadId] = file.uri.pathSegments.isEmpty ? file.path.split(Platform.pathSeparator).last : file.uri.pathSegments.last;
          final digest = (await sha256.bind(file.openRead()).first).toString();
          await _nearby.sendBytesPayload(
            endpointId,
            Uint8List.fromList(utf8.encode('SMFILE1|$payloadId|${file.uri.pathSegments.last}|$digest')),
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
              if (widget.receiveMode) ...[
                Card(
                  color: const Color(0xFFFFEEEE),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      const Icon(Icons.wifi_tethering_rounded, color: _nearbyRed, size: 36),
                      const SizedBox(height: 8),
                      const Text('هذا الهاتف جاهز للاستقبال', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('أبقِ هذه الشاشة مفتوحة ليتمكن الهاتف الآخر من العثور عليك.', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      QrImageView(data: 'SMPLAYER|$_localName', version: QrVersions.auto, size: 190, backgroundColor: Colors.white),
                      const SizedBox(height: 6),
                      Text(_localName, style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      const Text('يمكن مسح الرمز لتحديد اسم الجهاز، ثم يتم الاتصال عبر الأجهزة القريبة.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: _nearbyRed, padding: const EdgeInsets.symmetric(vertical: 12)),
                    onPressed: _scanQr,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('مسح QR للاتصال السريع'),
                  ),
                ),
              ],
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
                Expanded(child: OutlinedButton.icon(onPressed: _pickMediaFiles, icon: const Icon(Icons.perm_media_outlined), label: const Text('الفيديوهات والمجلدات والموسيقى'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: _pickOtherFiles, icon: const Icon(Icons.insert_drive_file_outlined), label: const Text('ملفات أخرى'))),
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
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('إجمالي تقدم النقل', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text('${_formatBytes(_progressBytes.values.fold<int>(0, (sum, value) => sum + value))} من ${_formatBytes(_progressTotals.values.fold<int>(0, (sum, value) => sum + value))}'),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: _progressTotals.values.fold<int>(0, (sum, value) => sum + value) <= 0
                            ? null
                            : (_progressBytes.values.fold<int>(0, (sum, value) => sum + value) /
                                _progressTotals.values.fold<int>(0, (sum, value) => sum + value)).clamp(0.0, 1.0).toDouble(),
                        color: _nearbyRed,
                      ),
                    ]),
                  ),
                ),
                const Text('تقدم كل ملف', style: TextStyle(fontWeight: FontWeight.bold)),
                ..._progressTotals.entries.map((entry) {
                  final sent = _progressBytes[entry.key] ?? 0;
                  final total = entry.value;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_progressNames[entry.key] ?? 'ملف ${entry.key}', maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('${_formatBytes(sent)} / ${_formatBytes(total)}'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: total <= 0 ? null : (sent / total).clamp(0.0, 1.0).toDouble(), color: _nearbyRed),
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

class DeviceStoragePickerScreen extends StatefulWidget {
  const DeviceStoragePickerScreen({super.key});

  @override
  State<DeviceStoragePickerScreen> createState() => _DeviceStoragePickerScreenState();
}

class _DeviceStoragePickerScreenState extends State<DeviceStoragePickerScreen> {
  Directory _current = Directory('/storage/emulated/0');
  List<FileSystemEntity> _entries = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (!await Permission.manageExternalStorage.isGranted) {
        final result = await Permission.manageExternalStorage.request();
        if (!result.isGranted) {
          _error = 'يلزم السماح بالوصول إلى جميع الملفات من إعدادات Android لاستخدام متصفح الملفات داخل التطبيق.';
          return;
        }
      }
      if (!await _current.exists()) {
        _current = Directory('/sdcard');
      }
      final entries = <FileSystemEntity>[];
      await for (final entity in _current.list(followLinks: false)) {
        final name = entity.uri.pathSegments.isEmpty ? entity.path : entity.uri.pathSegments.last;
        if (name.startsWith('.')) continue;
        entries.add(entity);
      }
      entries.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad.compareTo(bd);
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      _entries = entries;
    } catch (e) {
      _error = 'تعذر فتح المجلد: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _name(FileSystemEntity entity) {
    final path = entity.path.replaceAll('\\\\', '/').replaceAll(RegExp(r'/+$'), '');
    final slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  Future<void> _open(Directory directory) async {
    setState(() { _current = directory; });
    await _load();
  }

  Future<void> _selectFolder(Directory directory) async {
    setState(() { _loading = true; _error = null; });
    var added = 0;
    try {
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (entity.path.contains('/Android/data/') || entity.path.contains('/Android/obb/')) continue;
        _selected.add(entity.path);
        added++;
      }
      if (mounted) setState(() => _error = added == 0 ? 'لم يتم العثور على ملفات قابلة للقراءة داخل هذا المجلد.' : 'تم تحديد $added ملفًا من المجلد.');
    } catch (_) {
      if (mounted) setState(() => _error = 'تم تحديد ما أمكن قراءته من المجلد. بعض المسارات محمية من Android.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleFile(File file) {
    if (_selected.contains(file.path)) {
      setState(() => _selected.remove(file.path));
      return;
    }
    setState(() => _selected.add(file.path));
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('اختيار الملفات والمجلدات'),
        leading: IconButton(
          tooltip: 'رجوع',
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            final parent = _current.parent;
            if (parent.path != _current.path && await parent.exists()) {
              await _open(parent);
            } else if (context.mounted) {
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.map((path) => File(path)).where((file) => file.existsSync()).toList()),
            child: Text('إضافة (${_selected.length})'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(_current.path, maxLines: 2, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Text('تم تحديد ${_selected.length} ملف', style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(onPressed: _selected.isEmpty ? null : () => setState(_selected.clear), child: const Text('مسح التحديد')),
            ]),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(_error!, style: const TextStyle(color: _nearbyRed))),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _nearbyRed))
                : _entries.isEmpty
                    ? const Center(child: Text('هذا المجلد فارغ أو لا يمكن قراءته.'))
                    : ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entity = _entries[index];
                          final isDirectory = entity is Directory;
                          final selected = entity is File && _selected.contains(entity.path);
                          return ListTile(
                            leading: Icon(isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_outlined, color: isDirectory ? _nearbyRed : null),
                            title: Text(_name(entity), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              isDirectory ? 'مجلد — اضغط للفتح أو اضغط مطولًا لتحديد محتوياته' : entity.path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textDirection: isDirectory ? TextDirection.rtl : TextDirection.ltr,
                            ),
                            trailing: entity is File
                                ? Checkbox(value: selected, onChanged: (_) => _toggleFile(entity))
                                : const Icon(Icons.chevron_left_rounded),
                            onTap: () {
                              if (entity is Directory) {
                                _open(entity);
                              } else if (entity is File) {
                                _toggleFile(entity);
                              }
                            },
                            onLongPress: () {
                              if (entity is Directory) {
                                _selectFolder(entity);
                              } else if (entity is File) {
                                _toggleFile(entity);
                              }
                            },
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: _nearbyRed, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.map((path) => File(path)).where((file) => file.existsSync()).toList()),
                  icon: const Icon(Icons.add_rounded),
                  label: Text('إضافة الملفات المحددة (${_selected.length})'),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
