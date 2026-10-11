import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Local authenticated HTTP upload receiver for devices on the same Wi-Fi.
class WifiTransferService {
  HttpServer? _server;
  String? _token;
  Directory? _inbox;

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  String? get token => _token;

  Future<List<String>> get localIpv4Addresses async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return interfaces.expand((i) => i.addresses)
        .where((a) => !a.isLoopback).map((a) => a.address).toSet().toList();
  }

  String _newToken() {
    final random = Random.secure();
    return List<int>.generate(24, (_) => random.nextInt(256))
        .map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> start() async {
    if (_server != null) return;
    final docs = await getApplicationDocumentsDirectory();
    _inbox = Directory('${docs.path}/wifi_received');
    if (!await _inbox!.exists()) await _inbox!.create(recursive: true);
    _token = _newToken();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: false);
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    if (request.method == 'GET' && request.uri.path == '/health') {
      if (!_authorized(request)) {
        response.statusCode = HttpStatus.unauthorized;
        response.write(jsonEncode({'error': 'unauthorized'}));
      } else {
        response.write(jsonEncode({'service': 'SamirNet Player', 'ready': true}));
      }
      await response.close();
      return;
    }
    if (request.method != 'POST' || request.uri.path != '/upload') {
      response.statusCode = HttpStatus.notFound;
      response.write(jsonEncode({'error': 'not_found'}));
      await response.close();
      return;
    }
    if (!_authorized(request)) {
      response.statusCode = HttpStatus.unauthorized;
      response.write(jsonEncode({'error': 'unauthorized'}));
      await response.close();
      return;
    }
    final rawName = request.uri.queryParameters['name'] ?? 'received_file.bin';
    final name = rawName.split(RegExp(r'[/\\\\]')).last
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'invalid_filename'}));
      await response.close();
      return;
    }
    final file = File('${_inbox!.path}/${DateTime.now().microsecondsSinceEpoch}_$name');
    final sink = file.openWrite();
    final digestSink = AccumulatorSink<Digest>();
    final digestInput = sha256.startChunkedConversion(digestSink);
    var size = 0;
    try {
      await for (final chunk in request) {
        size += chunk.length;
        if (size > 2 * 1024 * 1024 * 1024) {
          throw const HttpException('File exceeds 2 GiB limit');
        }
        sink.add(chunk);
        digestInput.add(chunk);
      }
      digestInput.close();
      await sink.flush();
      await sink.close();
      final digest = digestSink.events.single.toString();
      response.statusCode = HttpStatus.created;
      response.write(jsonEncode({
        'saved': true,
        'file': name,
        'bytes': size,
        'sha256': digest,
        'message': 'تم حفظ الملف. قارن SHA-256 للتحقق من سلامته.',
      }));
    } catch (error) {
      await sink.close();
      if (await file.exists()) await file.delete();
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode({'error': 'upload_failed', 'details': error.toString()}));
    }
    await response.close();
  }

  bool _authorized(HttpRequest request) {
    final expected = _token;
    final supplied = request.headers.value(HttpHeaders.authorizationHeader);
    return expected != null && supplied == 'Bearer $expected';
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _token = null;
    if (server != null) await server.close(force: true);
  }
}
