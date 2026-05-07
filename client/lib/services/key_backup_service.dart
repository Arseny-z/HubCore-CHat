import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../crypto/identity.dart';
import '../infrastructure/keystore/keystore_service.dart';

/// Encrypted backup format (JSON):
///
///   v:    1
///   salt: base64 32 bytes — KDF salt
///   n:    base64 24 bytes — XChaCha20-Poly1305 nonce
///   ct:   base64 ciphertext — encrypted identity JSON
///
/// Identity JSON (plaintext before encryption):
///
///   master_pub, master_priv, signing_pub, signing_priv,
///   x25519_pub, x25519_priv — base64 key bytes
///   cert — base64 112-byte SigningCert blob
class KeyBackupService {
  final Sodium _sodium;
  final KeystoreService _keystore;

  static const _kVersion = 1;
  static const _kFileName = 'hubcore_identity_backup.enc';

  KeyBackupService(this._sodium, this._keystore);

  // ── Export ─────────────────────────────────────────────────────────────────

  /// Export an encrypted backup file.
  ///
  /// Returns the path of the written file, or throws on error.
  Future<String> exportBackup(String password) async {
    final identity = await _keystore.loadIdentity();
    if (identity == null) throw StateError('No identity to export');

    // Collect raw key bytes
    final masterPub = identity.masterPublicKey;
    final masterPriv = identity.masterPrivateKeyBytes;
    final signingPub = identity.signingPublicKey;
    final signingPriv = identity.signingPrivateKeyBytes;
    final x25519Pub = identity.x25519PublicKey;
    final x25519Priv = identity.x25519PrivateKeyBytes;
    final certBlob = identity.signingCert.encode();

    final plainJson = jsonEncode({
      'master_pub': base64.encode(masterPub),
      'master_priv': base64.encode(masterPriv),
      'signing_pub': base64.encode(signingPub),
      'signing_priv': base64.encode(signingPriv),
      'x25519_pub': base64.encode(x25519Pub),
      'x25519_priv': base64.encode(x25519Priv),
      'cert': base64.encode(certBlob),
    });

    // Zero-out private key copies
    masterPriv.fillRange(0, masterPriv.length, 0);
    signingPriv.fillRange(0, signingPriv.length, 0);
    x25519Priv.fillRange(0, x25519Priv.length, 0);

    identity.dispose();

    // Derive encryption key from password via BLAKE2b KDF
    final salt = _sodium.randombytes.buf(32);
    final derivedKey = _deriveKey(password, salt);

    // Encrypt with XChaCha20-Poly1305
    final nonce = _sodium.randombytes.buf(
      _sodium.crypto.secretBox.nonceBytes,
    );
    final plainBytes = Uint8List.fromList(utf8.encode(plainJson));
    final ciphertext = _sodium.crypto.secretBox.easy(
      message: plainBytes,
      nonce: nonce,
      key: derivedKey,
    );
    derivedKey.dispose();

    final envelope = jsonEncode({
      'v': _kVersion,
      'salt': base64.encode(salt),
      'n': base64.encode(nonce),
      'ct': base64.encode(ciphertext),
    });

    // Write to app documents directory
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_kFileName');
    await file.writeAsString(envelope);
    return file.path;
  }

  // ── Import ─────────────────────────────────────────────────────────────────

  /// Let the user pick a backup file and restore the identity.
  ///
  /// Returns true if the identity was successfully restored, false on cancel.
  /// Throws on invalid file or wrong password.
  Future<bool> importBackup(String password) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return false;

    final path = result.files.single.path;
    if (path == null) throw StateError('Could not access selected file');

    final raw = await File(path).readAsString();
    final envelope = jsonDecode(raw) as Map<String, dynamic>;

    if (envelope['v'] != _kVersion) {
      throw FormatException('Unsupported backup version: ${envelope["v"]}');
    }

    final salt = base64.decode(envelope['salt'] as String);
    final nonce = base64.decode(envelope['n'] as String);
    final ciphertext = base64.decode(envelope['ct'] as String);

    final derivedKey = _deriveKey(password, salt);

    final Uint8List plainBytes;
    try {
      plainBytes = _sodium.crypto.secretBox.openEasy(
        cipherText: ciphertext,
        nonce: nonce,
        key: derivedKey,
      );
    } on SodiumException {
      derivedKey.dispose();
      throw ArgumentError('Wrong password or corrupted backup');
    } finally {
      derivedKey.dispose();
    }

    final plainJson = utf8.decode(plainBytes);
    final data = jsonDecode(plainJson) as Map<String, dynamic>;

    // Reconstruct and persist identity via KeystoreService
    final masterPub = base64.decode(data['master_pub'] as String);
    final masterPrivBytes = base64.decode(data['master_priv'] as String);
    final signingPub = base64.decode(data['signing_pub'] as String);
    final signingPrivBytes = base64.decode(data['signing_priv'] as String);
    final x25519Pub = base64.decode(data['x25519_pub'] as String);
    final x25519PrivBytes = base64.decode(data['x25519_priv'] as String);
    final certBlob = base64.decode(data['cert'] as String);

    final masterPrivKey = SecureKey.fromList(_sodium, masterPrivBytes);
    masterPrivBytes.fillRange(0, masterPrivBytes.length, 0);

    final signingPrivKey = SecureKey.fromList(_sodium, signingPrivBytes);
    signingPrivBytes.fillRange(0, signingPrivBytes.length, 0);

    final x25519PrivKey = SecureKey.fromList(_sodium, x25519PrivBytes);
    x25519PrivBytes.fillRange(0, x25519PrivBytes.length, 0);

    final cert = SigningCert.decode(certBlob);
    final identity = Identity.fromParts(
      sodium: _sodium,
      masterPublicKey: masterPub,
      masterPrivateKey: masterPrivKey,
      signingPublicKey: signingPub,
      signingPrivateKey: signingPrivKey,
      x25519PublicKey: x25519Pub,
      x25519PrivateKey: x25519PrivKey,
      signingCert: cert,
    );

    await _keystore.saveIdentity(identity);
    identity.dispose();
    return true;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Derive a 32-byte encryption key from [password] and [salt] using
  /// 1024 rounds of BLAKE2b (crypto_generichash).
  ///
  /// Each round uses the salt as the BLAKE2b MAC key and feeds its 32-byte
  /// output as the message for the next round, starting from password+salt.
  SecureKey _deriveKey(String password, Uint8List salt) {
    final keyBytes = _sodium.crypto.secretBox.keyBytes; // 32
    final pwBytes = Uint8List.fromList(utf8.encode(password));

    // Wrap salt as SecureKey for use as BLAKE2b key
    final hashKey = SecureKey.fromList(_sodium, salt);

    Uint8List state = Uint8List.fromList([...pwBytes, ...salt]);
    for (var i = 0; i < 1024; i++) {
      state = _sodium.crypto.genericHash.call(
        message: state,
        outLen: keyBytes,
        key: hashKey,
      );
    }

    hashKey.dispose();
    return SecureKey.fromList(_sodium, state);
  }
}
