import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/identity.dart';

/// Persists Identity keys using platform secure storage.
///
/// Android: EncryptedSharedPreferences backed by Android Keystore (AES-256-GCM).
/// Web:     SubtleCrypto AES-GCM with key derived from a Web Crypto-backed key.
///
/// Key layout in secure storage:
///   hubcore.master.pub      — base64(masterPublicKey)
///   hubcore.master.priv     — base64(masterPrivateKey bytes)
///   hubcore.signing.pub     — base64(signingPublicKey)
///   hubcore.signing.priv    — base64(signingPrivateKey bytes)
///   hubcore.x25519.pub      — base64(x25519PublicKey)
///   hubcore.x25519.priv     — base64(x25519PrivateKey bytes)
///   hubcore.cert.spub       — base64(cert.signingPubkey)
///   hubcore.cert.from       — int (validFrom unix seconds)
///   hubcore.cert.until      — int (validUntil unix seconds)
///   hubcore.cert.sig        — base64(cert.signature)
class KeystoreService {
  static const _kMasterPub  = 'hubcore.master.pub';
  static const _kMasterPriv = 'hubcore.master.priv';
  static const _kSigningPub  = 'hubcore.signing.pub';
  static const _kSigningPriv = 'hubcore.signing.priv';
  static const _kX25519Pub  = 'hubcore.x25519.pub';
  static const _kX25519Priv = 'hubcore.x25519.priv';
  static const _kCertSpub  = 'hubcore.cert.spub';
  static const _kCertFrom  = 'hubcore.cert.from';
  static const _kCertUntil = 'hubcore.cert.until';
  static const _kCertSig   = 'hubcore.cert.sig';
  // Device keys (multi-device support, v24+)
  static const _kDeviceId     = 'hubcore.device.id';
  static const _kDevicePub    = 'hubcore.device.pub';
  static const _kDevicePriv   = 'hubcore.device.priv';
  static const _kDeviceCert   = 'hubcore.device.cert';
  static const _kDeviceMaster = 'hubcore.device.is_master';

  final FlutterSecureStorage _storage;
  final Sodium _sodium;

  KeystoreService(this._sodium)
      : _storage = const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
        );

  /// Returns true if an identity is already persisted.
  Future<bool> hasIdentity() async {
    final v = await _storage.read(key: _kMasterPub);
    return v != null;
  }

  /// Saves [identity] to secure storage.
  Future<void> saveIdentity(Identity identity) async {
    final masterPrivBytes  = identity.masterPrivateKeyBytes;
    final signingPrivBytes = identity.signingPrivateKeyBytes;
    final x25519PrivBytes  = identity.x25519PrivateKeyBytes;
    final devicePrivBytes  = identity.devicePrivateKeyBytes;

    await _storage.write(key: _kMasterPub,  value: _b64(identity.masterPublicKey));
    await _storage.write(key: _kMasterPriv, value: _b64(masterPrivBytes));
    await _storage.write(key: _kSigningPub,  value: _b64(identity.signingPublicKey));
    await _storage.write(key: _kSigningPriv, value: _b64(signingPrivBytes));
    await _storage.write(key: _kX25519Pub,  value: _b64(identity.x25519PublicKey));
    await _storage.write(key: _kX25519Priv, value: _b64(x25519PrivBytes));
    await _storage.write(key: _kCertSpub,  value: _b64(identity.signingCert.signingPubkey));
    await _storage.write(key: _kCertFrom,  value: identity.signingCert.validFrom.toString());
    await _storage.write(key: _kCertUntil, value: identity.signingCert.validUntil.toString());
    await _storage.write(key: _kCertSig,   value: _b64(identity.signingCert.signature));
    // Device keys
    await _storage.write(key: _kDeviceId,     value: identity.deviceId);
    await _storage.write(key: _kDevicePub,    value: _b64(identity.devicePublicKey));
    await _storage.write(key: _kDevicePriv,   value: _b64(devicePrivBytes));
    await _storage.write(key: _kDeviceCert,   value: _b64(identity.deviceCert.encode()));
    await _storage.write(key: _kDeviceMaster, value: identity.isMasterDevice ? '1' : '0');

    masterPrivBytes.fillRange(0, masterPrivBytes.length, 0);
    signingPrivBytes.fillRange(0, signingPrivBytes.length, 0);
    x25519PrivBytes.fillRange(0, x25519PrivBytes.length, 0);
    devicePrivBytes.fillRange(0, devicePrivBytes.length, 0);
  }

  /// Loads the persisted identity, or returns null if none exists.
  Future<Identity?> loadIdentity() async {
    final masterPubB64 = await _storage.read(key: _kMasterPub);
    if (masterPubB64 == null) return null;

    final masterPub = _unb64(masterPubB64);
    final masterPrivBytes = _unb64(await _storage.read(key: _kMasterPriv) ?? '');
    final signingPub = _unb64(await _storage.read(key: _kSigningPub) ?? '');
    final signingPrivBytes = _unb64(await _storage.read(key: _kSigningPriv) ?? '');
    final x25519Pub = _unb64(await _storage.read(key: _kX25519Pub) ?? '');
    final x25519PrivBytes = _unb64(await _storage.read(key: _kX25519Priv) ?? '');
    final certSpub = _unb64(await _storage.read(key: _kCertSpub) ?? '');
    final certFrom = int.parse(await _storage.read(key: _kCertFrom) ?? '0');
    final certUntil = int.parse(await _storage.read(key: _kCertUntil) ?? '0');
    final certSig = _unb64(await _storage.read(key: _kCertSig) ?? '');

    final masterPrivKey = SecureKey.fromList(_sodium, masterPrivBytes);
    masterPrivBytes.fillRange(0, masterPrivBytes.length, 0);

    final signingPrivKey = SecureKey.fromList(_sodium, signingPrivBytes);
    signingPrivBytes.fillRange(0, signingPrivBytes.length, 0);

    final x25519PrivKey = SecureKey.fromList(_sodium, x25519PrivBytes);
    x25519PrivBytes.fillRange(0, x25519PrivBytes.length, 0);

    final cert = SigningCert(
      signingPubkey: certSpub,
      validFrom: certFrom,
      validUntil: certUntil,
      signature: certSig,
    );

    // Device keys — may be absent on pre-multidevice installs (auto-generated in fromParts)
    final deviceIdStr    = await _storage.read(key: _kDeviceId);
    final devicePubB64   = await _storage.read(key: _kDevicePub);
    final devicePrivB64  = await _storage.read(key: _kDevicePriv);
    final deviceCertB64  = await _storage.read(key: _kDeviceCert);
    final isMasterStr    = await _storage.read(key: _kDeviceMaster);

    Uint8List? devicePub;
    SecureKey? devicePrivKey;
    DeviceCert? deviceCert;
    if (devicePubB64 != null && devicePrivB64 != null) {
      devicePub = _unb64(devicePubB64);
      final devicePrivBytes = _unb64(devicePrivB64);
      devicePrivKey = SecureKey.fromList(_sodium, devicePrivBytes);
      devicePrivBytes.fillRange(0, devicePrivBytes.length, 0);
    }
    if (deviceCertB64 != null) {
      try { deviceCert = DeviceCert.decode(_unb64(deviceCertB64)); } catch (_) {}
    }

    return Identity.fromParts(
      sodium: _sodium,
      masterPublicKey: masterPub,
      masterPrivateKey: masterPrivKey,
      signingPublicKey: signingPub,
      signingPrivateKey: signingPrivKey,
      x25519PublicKey: x25519Pub,
      x25519PrivateKey: x25519PrivKey,
      signingCert: cert,
      deviceId: deviceIdStr,
      devicePublicKey: devicePub,
      devicePrivateKey: devicePrivKey,
      deviceCert: deviceCert,
      isMasterDevice: (isMasterStr ?? '1') == '1',
    );
  }

  /// Wipes all identity keys from secure storage.
  Future<void> wipe() async {
    await _storage.deleteAll();
  }

  static String _b64(Uint8List bytes) => base64.encode(bytes);
  static Uint8List _unb64(String s) => base64.decode(s);
}
