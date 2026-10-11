import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Encrypted private media storage. The PIN is never stored in plain text.
class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();
  static const _storage = FlutterSecureStorage();
  static const _pinVerifierKey = 'samirnet_vault_pin_verifier';
  static const _saltKey = 'samirnet_vault_pin_salt';
  final Random _random = Random.secure();

  Future<bool> get isConfigured async =>
      (await _storage.read(key: _pinVerifierKey)) != null;

  String _randomHex(int count) =>
      List<int>.generate(count, (_) => _random.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> setPin(String pin) async {
    if (pin.length < 4) throw ArgumentError('يجب أن يتكون الرقم السري من 4 أرقام على الأقل');
    final salt = _randomHex(16);
    await _storage.write(key: _saltKey, value: salt);
    await _storage.write(
      key: _pinVerifierKey,
      value: sha256.convert(utf8.encode('$salt:$pin')).toString(),
    );
  }

  Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _saltKey);
    final expected = await _storage.read(key: _pinVerifierKey);
    if (salt == null || expected == null) return false;
    return sha256.convert(utf8.encode('$salt:$pin')).toString() == expected;
  }

  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/private_vault');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Uint8List _deriveKey(String pin, List<int> salt) =>
      Uint8List.fromList(sha256.convert([...utf8.encode(pin), ...salt]).bytes);

  Future<void> importFile(File source, String pin) async {
    if (!await verifyPin(pin)) throw StateError('الرقم السري غير صحيح');
    final bytes = await source.readAsBytes();
    final salt = List<int>.generate(16, (_) => _random.nextInt(256));
    final ivBytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final key = enc.Key(_deriveKey(pin, salt));
    final iv = enc.IV(Uint8List.fromList(ivBytes));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
    final encrypted = encrypter.encryptBytes(bytes, iv: iv).bytes;
    final output = BytesBuilder()
      ..add([83, 78, 86, 49]) // SNV1 format marker
      ..add(salt)
      ..add(ivBytes)
      ..add(encrypted);
    final safeName = DateTime.now().microsecondsSinceEpoch.toString() + '.snv';
    await File('${(await _directory()).path}/$safeName')
        .writeAsBytes(output.takeBytes(), flush: true);
  }

  Future<List<File>> listEncryptedFiles() async {
    final dir = await _directory();
    return dir.listSync().whereType<File>()
        .where((file) => file.path.endsWith('.snv')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<File> decryptToTemporary(File encryptedFile, String pin) async {
    if (!await verifyPin(pin)) throw StateError('الرقم السري غير صحيح');
    final all = await encryptedFile.readAsBytes();
    if (all.length < 36 || all[0] != 83 || all[1] != 78 ||
        all[2] != 86 || all[3] != 49) {
      throw const FormatException('ملف الخزنة تالف أو غير معروف');
    }
    final salt = all.sublist(4, 20);
    final iv = enc.IV(Uint8List.fromList(all.sublist(20, 36)));
    final payload = all.sublist(36);
    final key = enc.Key(_deriveKey(pin, salt));
    final decrypted = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc))
        .decryptBytes(enc.Encrypted(Uint8List.fromList(payload)), iv: iv);
    final temp = await getTemporaryDirectory();
    final output = File('${temp.path}/vault_preview_${DateTime.now().microsecondsSinceEpoch}.bin');
    await output.writeAsBytes(decrypted, flush: true);
    return output;
  }

  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
  }
}
