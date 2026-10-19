import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
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
  // Metadata is sent as a tiny BYTES payload beside each actual file. It is
  // protocol data, not a user file, so never show it in file progress.
  final Set<int> _metadataPayloads = {};
  // sendBytesPayload has no returned payload ID, so identify our tiny protocol
  // metadata updates by their exact encoded byte lengths on the sending device.
  final Set<int> _metadataPayloadSizes = {};
  final Set<int> _outgoingFilePayloads = {};
  final Set<int> _finalizingPayloads = {};
  // A connection is approved once by the user; files from that approved peer
  // are saved without asking the same question for every item in a batch.
  final Set<String> _trustedEndpoints = {};
  final Map<int, String> _payloadEndpoints = {};
  final Map<int, Completer<void>> _payloadCompletions = {};
  final Map<int, int> _progressBytes = {};
  final Map<int, int> _progressTotals = {};
  final Map<int, String> _progressNames = {};
  final Map<int, DateTime> _progressStartedAt = {};
  final ValueNotifier<int> _progressRevision = ValueNotifier<int>(0);

  bool _starting = false;
  bool _advertising = false;
  bool _discovering = false;
  bool _sending = false;
  String? _error;
  String? _status;
  String _localName = 'SM Player';
  String? _scanTargetName;

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
              if (_scanTargetName != null &&
                  name.trim().toLowerCase() == _scanTargetName!.trim().toLowerCase() &&
                  !_connected.containsKey(id)) {
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
                    _trustedEndpoints.add(id);
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
        _trustedEndpoints.remove(id);
      }
    });
  }

  void _onDisconnected(String id) {
    if (!mounted) return;
    setState(() {
      _connected.remove(id);
      _trustedEndpoints.remove(id);
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
      _metadataPayloads.add(payload.id);
      _progressBytes.remove(payload.id);
      _progressTotals.remove(payload.id);
      _progressNames.remove(payload.id);
      _progressStartedAt.remove(payload.id);
      final message = utf8.decode(payload.bytes!, allowMalformed: true);
      if (message.startsWith('SMFILE1|')) {
        final parts = message.split('|');
        if (parts.length >= 3) {
          final id = int.tryParse(parts[1]);
          if (id != null) {
            _payloadEndpoints[id] = endpointId;
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
      _payloadEndpoints[payload.id] = endpointId;
      _receivedUris[payload.id] = payload.uri!;
      _tryFinalizeReceivedFile(payload.id);
    }
    _progressRevision.value++;
  }

  void _onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
    if (!mounted ||
        _metadataPayloads.contains(update.id) ||
        (!_outgoingFilePayloads.contains(update.id) &&
            update.totalBytes < 1024 &&
            _metadataPayloadSizes.contains(update.totalBytes))) {
      return;
    }
    if (update.status == PayloadStatus.IN_PROGRESS) {
      setState(() {
        _progressBytes[update.id] = update.bytesTransferred;
        _progressTotals[update.id] = update.totalBytes;
        _progressStartedAt.putIfAbsent(update.id, DateTime.now);
        final elapsed = DateTime.now().difference(_progressStartedAt[update.id]!).inMilliseconds / 1000.0;
        final speed = elapsed > 0 ? update.bytesTransferred / elapsed : 0.0;
        final remaining = speed > 0 && update.totalBytes >= update.bytesTransferred
            ? Duration(seconds: ((update.totalBytes - update.bytesTransferred) / speed).round())
            : null;
        _status = 'جارٍ نقل ملف: ${_formatBytes(update.bytesTransferred)} من ${_formatBytes(update.totalBytes)} · ${_formatSpeed(speed)}${remaining == null ? '' : ' · متبقٍ ${_formatDuration(remaining)}'}';
      });
      _progressRevision.value++;
    } else if (update.status == PayloadStatus.FAILURE) {
      final completion = _payloadCompletions.remove(update.id);
      if (completion != null && !completion.isCompleted) {
        completion.completeError(StateError('فشل نقل الملف ${_progressNames[update.id] ?? ''}'));
      }
      setState(() => _error = 'فشل نقل أحد الملفات. افحص الاتصال ثم أعد المحاولة.');
      _progressRevision.value++;
    } else if (update.status == PayloadStatus.SUCCESS) {
      _completedPayloads.add(update.id);
      final completion = _payloadCompletions.remove(update.id);
      if (completion != null && !completion.isCompleted) completion.complete();
      _tryFinalizeReceivedFile(update.id);
      setState(() {
        _progressBytes[update.id] = update.totalBytes;
        _progressTotals[update.id] = update.totalBytes;
        _progressStartedAt.putIfAbsent(update.id, DateTime.now);
        _status = 'اكتمل نقل ملف (${_formatBytes(update.totalBytes)}).';
      });
      _progressRevision.value++;
    }
  }

  Future<void> _tryFinalizeReceivedFile(int payloadId) async {
    final uri = _receivedUris[payloadId];
    final name = _receivedNames[payloadId];
    final expectedDigest = _receivedDigests[payloadId];
    final endpointId = _payloadEndpoints[payloadId];
    if (uri == null ||
        name == null ||
        expectedDigest == null ||
        endpointId == null ||
        !_completedPayloads.contains(payloadId) ||
        !_trustedEndpoints.contains(endpointId)) {
      return;
    }
    if (!_finalizingPayloads.add(payloadId)) return;
    try {
      final inbox = Directory('/storage/emulated/0/Download/SM Player Received');
      await inbox.create(recursive: true);
      final destination = await _uniqueFile(inbox, name);
      final saved = await _nearby.copyFileAndDeleteOriginal(uri, destination.path);
      if (!saved) throw Exception('لم يتمكن التطبيق من حفظ الملف المستلم.');
      final actualDigest = (await sha256.bind(destination.openRead()).first).toString();
      if (actualDigest != expectedDigest) {
        await destination.delete();
        throw Exception('فشل التحقق من سلامة الملف بعد النقل؛ حُذف الملف غير المطابق.');
      }
      if (mounted) {
        setState(() {
          _status = 'تم استلام الملف والتحقق من سلامته: ${destination.path}';
          _receivedUris.remove(payloadId);
          _receivedNames.remove(payloadId);
          _receivedDigests.remove(payloadId);
          _payloadEndpoints.remove(payloadId);
          _completedPayloads.remove(payloadId);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'وصل الملف لكن تعذر حفظه: $e');
    } finally {
      _finalizingPayloads.remove(payloadId);
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
    try {
      final cameraPermission = await Permission.camera.request();
      if (!cameraPermission.isGranted) {
        if (mounted) {
          setState(() => _error = cameraPermission.isPermanentlyDenied
              ? 'إذن الكاميرا مرفوض نهائيًا. افتح إعدادات التطبيق واسمح باستخدام الكاميرا.'
              : 'يجب السماح باستخدام الكاميرا لمسح رمز QR.');
        }
        if (cameraPermission.isPermanentlyDenied) await openAppSettings();
        return;
      }
      if (!mounted) return;
      final target = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          fullscreenDialog: true,
          builder: (_) => const _QrScannerPage(),
        ),
      );
      if (target == null || target.trim().isEmpty || !mounted) return;
      _scanTargetName = target.trim();
      setState(() {
        _status = 'تم مسح رمز الجهاز $_scanTargetName. جارٍ إنشاء الاتصال المباشر...';
        _error = null;
      });
      final normalizedTarget = _scanTargetName!.trim().toLowerCase();
      final match = _discovered.entries
          .where((entry) => entry.value.trim().toLowerCase() == normalizedTarget)
          .firstOrNull;
      if (match != null) {
        await _connect(match.key, match.value);
      } else {
        setState(() => _status =
            'تمت قراءة الرمز. انتظر ظهور الجهاز المستلم في البحث؛ سيُطلب الاتصال تلقائيًا.');
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

  Future<void> _pickFolder() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path == null || !mounted) return;
      final directory = Directory(path);
      if (!await directory.exists()) {
        setState(() => _error = 'المجلد المحدد غير موجود أو لم يعد متاحًا.');
        return;
      }
      final found = <File>[];
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) found.add(entity);
      }
      if (!mounted) return;
      setState(() {
        for (final file in found) {
          if (!_queue.any((old) => old.path == file.path)) _queue.add(file);
        }
        _error = found.isEmpty ? 'المجلد المحدد لا يحتوي على ملفات قابلة للإرسال.' : null;
        _status = found.isEmpty ? _status : 'أُضيف ${found.length} ملفًا من المجلد إلى قائمة الإرسال.';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر قراءة المجلد المحدد: $e');
    }
  }

  Future<void> _sendQueue() async {
    if (_queue.isEmpty || _connected.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _status = 'جارٍ إرسال الملفات إلى الأجهزة المتصلة...';
      _error = null;
    });
    _progressBytes.clear();
    _progressTotals.clear();
    _progressNames.clear();
    _progressStartedAt.clear();
    _completedPayloads.clear();
    _progressRevision.value++;
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => TransferProgressScreen(
        progressRevision: _progressRevision,
        progressBytes: _progressBytes,
        progressTotals: _progressTotals,
        progressNames: _progressNames,
        progressStartedAt: _progressStartedAt,
      ),
    )));
    final pending = List<File>.from(_queue);
    try {
      // Serialize large payloads; queuing many at once can contend for the radio.
      for (final file in pending) {
        if (!await file.exists()) {
          if (mounted) setState(() => _error = 'تُخطي ملفًا لم يعد موجودًا: ${file.path}');
          continue;
        }
        final fileName = file.uri.pathSegments.isEmpty
            ? file.path.split(Platform.pathSeparator).last
            : file.uri.pathSegments.last;
        // Hash before transfer so file I/O does not compete with the radio.
        final digest = (await sha256.bind(file.openRead()).first).toString();
        for (final endpointId in _connected.keys.toList()) {
          final payloadId = await _nearby.sendFilePayload(endpointId, file.path);
          _outgoingFilePayloads.add(payloadId);
          _progressNames[payloadId] = fileName;
          _progressTotals[payloadId] = await file.length();
          _progressBytes[payloadId] = 0;
          final completion = Completer<void>();
          _payloadCompletions[payloadId] = completion;
          final metadataBytes = Uint8List.fromList(utf8.encode(
            'SMFILE1|$payloadId|${Uri.encodeComponent(fileName)}|$digest',
          ));
          _metadataPayloadSizes.add(metadataBytes.length);
          _nearby.sendBytesPayload(endpointId, metadataBytes);
          _progressRevision.value++;
          if (!_completedPayloads.contains(payloadId)) {
            await completion.future.timeout(
              const Duration(minutes: 60),
              onTimeout: () => throw TimeoutException('انتهت مهلة نقل الملف: $fileName'),
            );
          }
          _payloadCompletions.remove(payloadId);
        }
        if (mounted) setState(() => _queue.remove(file));
      }
      if (mounted) setState(() => _status = 'اكتمل إرسال الملفات المحددة.');
    } catch (e) {
      if (mounted) setState(() => _error = 'توقف الإرسال: $e');
    } finally {
      for (final completer in _payloadCompletions.values) {
        if (!completer.isCompleted) completer.completeError(StateError('انتهت جلسة الإرسال'));
      }
      _payloadCompletions.clear();
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
    _progressRevision.dispose();
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
              if (!widget.receiveMode) ...[
              const Text('إرسال ملفات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(onPressed: _pickMediaFiles, icon: const Icon(Icons.perm_media_outlined), label: const Text('الفيديوهات والموسيقى')),
                  OutlinedButton.icon(onPressed: _pickOtherFiles, icon: const Icon(Icons.insert_drive_file_outlined), label: const Text('ملفات أخرى')),
                  OutlinedButton.icon(onPressed: _pickFolder, icon: const Icon(Icons.folder_open_rounded), label: const Text('اختيار مجلد كامل')),
                ],
              ),
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
              ],
              if (widget.receiveMode && _progressNames.isNotEmpty) ...[
                const Text('الملفات الواردة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ..._progressNames.entries.map((entry) {
                  final total = _progressTotals[entry.key] ?? 0;
                  final received = _progressBytes[entry.key] ?? 0;
                  final progress = total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;
                  return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(entry.value, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: progress, color: _nearbyRed),
                    const SizedBox(height: 4),
                    Text('${_formatBytes(received)} من ${_formatBytes(total)}'),
                  ])));
                }),
              ],
              const SizedBox(height: 16),
              const Text('ملاحظة: قد يطلب Android تفعيل Bluetooth أو خدمات الموقع/الأجهزة القريبة. اتبع طلبات النظام، ولا يلزم تشغيل بيانات الهاتف أو الإنترنت.', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
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

/// Full-screen QR scanner using Flutter's CameraX-backed Android camera plugin
/// and ML Kit for QR decoding. A fresh controller is created on every retry.
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> with WidgetsBindingObserver {
  CameraController? _cameraController;
  final BarcodeScanner _barcodeScanner = BarcodeScanner(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _starting = false;
  bool _processingFrame = false;
  bool _handled = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      unawaited(_disposeCamera());
    } else if (state == AppLifecycleState.resumed && !_handled && _cameraController == null) {
      unawaited(_startCamera());
    }
  }

  Future<void> _disposeCamera({bool updateUi = true}) async {
    final old = _cameraController;
    _cameraController = null;
    if (updateUi && mounted) setState(() {});
    if (old != null) {
      try {
        if (old.value.isStreamingImages) await old.stopImageStream();
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  Future<void> _startCamera() async {
    if (_starting || !mounted || _handled) return;
    setState(() {
      _starting = true;
      _cameraError = null;
    });
    await _disposeCamera();
    try {
      var permission = await Permission.camera.status;
      if (!permission.isGranted) permission = await Permission.camera.request();
      if (!permission.isGranted) {
        throw Exception(permission.isPermanentlyDenied
            ? 'إذن الكاميرا مرفوض نهائيًا. افتح إعدادات التطبيق واسمح باستخدام الكاميرا.'
            : 'لم يُمنح إذن الكاميرا.');
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('لم يعثر Android على كاميرا متاحة.');
      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (!mounted || _handled) {
        await controller.dispose();
        return;
      }
      _cameraController = controller;
      await controller.startImageStream(_processCameraImage);
      if (mounted) setState(() {});
    } catch (error) {
      await _disposeCamera();
      if (mounted) {
        setState(() {
          _cameraError = 'تعذر تشغيل CameraX: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_processingFrame || _handled || !mounted) return;
    _processingFrame = true;
    try {
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) return;
      final rotation = InputImageRotationValue.fromRawValue(
        controller.description.sensorOrientation,
      );
      if (rotation == null || image.planes.length < 3) return;

      // CameraX provides Android YUV_420_888 planes with row/pixel padding.
      // ML Kit's Android scanner is most reliable with a packed NV21 buffer;
      // concatenating the original planes directly can make QR codes invisible.
      final width = image.width;
      final height = image.height;
      final yPlane = image.planes[0];
      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      final nv21 = Uint8List(width * height * 3 ~/ 2);
      var output = 0;
      final yPixelStride = yPlane.bytesPerPixel ?? 1;
      for (var row = 0; row < height; row++) {
        final rowStart = row * yPlane.bytesPerRow;
        for (var col = 0; col < width; col++) {
          nv21[output++] = yPlane.bytes[rowStart + col * yPixelStride];
        }
      }
      final uPixelStride = uPlane.bytesPerPixel ?? 1;
      final vPixelStride = vPlane.bytesPerPixel ?? 1;
      for (var row = 0; row < height ~/ 2; row++) {
        final uRow = row * uPlane.bytesPerRow;
        final vRow = row * vPlane.bytesPerRow;
        for (var col = 0; col < width ~/ 2; col++) {
          nv21[output++] = vPlane.bytes[vRow + col * vPixelStride];
          nv21[output++] = uPlane.bytes[uRow + col * uPixelStride];
        }
      }
      final inputImage = InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: Size(width.toDouble(), height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: width,
        ),
      );
      final barcodes = await _barcodeScanner.processImage(inputImage);
      for (final barcode in barcodes) {
        final value = barcode.rawValue;
        if (value == null || !value.startsWith('SMPLAYER|')) continue;
        final target = value.substring('SMPLAYER|'.length).trim();
        if (target.isNotEmpty && mounted && !_handled) {
          _handled = true;
          await _disposeCamera();
          if (mounted) Navigator.of(context).pop(target);
          return;
        }
      }
    } catch (error) {
      // A single malformed camera frame must not stop the preview or scanning.
      debugPrint('QR frame analysis failed: $error');
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _retryCamera() async {
    _handled = false;
    await _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeCamera(updateUi: false));
    unawaited(_barcodeScanner.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('مسح رمز QR'),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'وجّه الكاميرا نحو رمز SM Player على الهاتف المستقبِل.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _cameraController != null &&
                          _cameraController!.value.isInitialized &&
                          _cameraController!.value.previewSize != null
                      ? CameraPreview(_cameraController!)
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_starting)
                                  const CircularProgressIndicator()
                                else
                                  const Icon(Icons.no_photography_outlined, size: 52),
                                const SizedBox(height: 16),
                                if (_cameraError != null)
                                  Text(_cameraError!, textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: _starting ? null : _retryCamera,
                                  icon: _starting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        )
                                      : const Icon(Icons.refresh_rounded),
                                  label: Text(_starting ? 'جارٍ تشغيل الكاميرا...' : 'إعادة تشغيل الكاميرا'),
                                ),
                                TextButton(
                                  onPressed: () => openAppSettings(),
                                  child: const Text('إعدادات أذونات الكاميرا'),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('يتم الاتصال مباشرة بين الهاتفين ولا يلزم الإنترنت.'),
            ),
          ],
        ),
      ),
    ),
  );
}

class TransferProgressScreen extends StatelessWidget {
  const TransferProgressScreen({
    super.key,
    required this.progressRevision,
    required this.progressBytes,
    required this.progressTotals,
    required this.progressNames,
    required this.progressStartedAt,
  });

  final ValueListenable<int> progressRevision;
  final Map<int, int> progressBytes;
  final Map<int, int> progressTotals;
  final Map<int, String> progressNames;
  final Map<int, DateTime> progressStartedAt;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('تقدم إرسال الملفات')),
      body: ValueListenableBuilder<int>(
        valueListenable: progressRevision,
        builder: (context, _, __) {
          final ids = progressTotals.keys.toList();
          final sent = ids.fold<int>(0, (sum, id) => sum + (progressBytes[id] ?? 0));
          final total = ids.fold<int>(0, (sum, id) => sum + (progressTotals[id] ?? 0));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                color: const Color(0xFFFFEEEE),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('إجمالي تقدم النقل', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 8),
                    Text('${_formatBytes(sent)} من ${_formatBytes(total)}'),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: total <= 0 ? null : (sent / total).clamp(0.0, 1.0).toDouble(),
                      color: _nearbyRed,
                    ),
                    const SizedBox(height: 6),
                    Text(ids.isEmpty ? 'بانتظار بدء نقل الملفات...' : 'عدد الملفات: ${ids.length}'),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              const Text('تقدم كل ملف', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
              if (ids.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Center(child: Text('جارٍ تجهيز الملفات للاتصال...')),
                ),
              ...ids.map((id) {
                final fileSent = progressBytes[id] ?? 0;
                final fileTotal = progressTotals[id] ?? 0;
                final started = progressStartedAt[id];
                final elapsed = started == null ? 0.0 : DateTime.now().difference(started).inMilliseconds / 1000.0;
                final speed = elapsed > 0 ? fileSent / elapsed : 0.0;
                final remaining = speed > 0 && fileTotal > fileSent
                    ? Duration(seconds: ((fileTotal - fileSent) / speed).round())
                    : null;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(progressNames[id] ?? 'ملف $id', maxLines: 2, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 5),
                      Text('${_formatBytes(fileSent)} من ${_formatBytes(fileTotal)} · ${_formatSpeed(speed)}${remaining == null ? '' : ' · متبقٍ ${_formatDuration(remaining)}'}'),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: fileTotal <= 0 ? null : (fileSent / fileTotal).clamp(0.0, 1.0).toDouble(),
                        color: _nearbyRed,
                      ),
                    ]),
                  ),
                );
              }),
              const SizedBox(height: 16),
              const Text('اترك هذه الصفحة مفتوحة حتى يكتمل الإرسال. يمكنك الرجوع للشاشة السابقة بعد ذلك.', style: TextStyle(color: Colors.grey)),
            ],
          );
        },
      ),
    ),
  );
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
