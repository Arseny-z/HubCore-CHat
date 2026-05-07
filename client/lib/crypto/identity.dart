import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:sodium_libs/sodium_libs.dart';

import 'keys.dart';

/// Signing certificate: proves [signingPubkey] was issued by the master key.
class SigningCert {
  final Uint8List signingPubkey;
  final int validFrom;
  final int validUntil;
  final Uint8List signature; // Ed25519 sig over (signingPubkey || validFrom || validUntil)

  const SigningCert({
    required this.signingPubkey,
    required this.validFrom,
    required this.validUntil,
    required this.signature,
  });

  bool get isValid {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now >= validFrom && now <= validUntil;
  }

  /// Encode as 112-byte blob: signingPub(32) || validFrom(8BE) || validUntil(8BE) || sig(64)
  Uint8List encode() {
    final buf = ByteData(32 + 8 + 8 + 64);
    for (var i = 0; i < 32; i++) buf.setUint8(i, signingPubkey[i]);
    buf.setInt64(32, validFrom, Endian.big);
    buf.setInt64(40, validUntil, Endian.big);
    for (var i = 0; i < 64; i++) buf.setUint8(48 + i, signature[i]);
    return buf.buffer.asUint8List();
  }

  /// Decode from 112-byte blob produced by [encode].
  static SigningCert decode(Uint8List blob) {
    if (blob.length != 112) {
      throw FormatException(
          'SigningCert: invalid blob length ${blob.length}, expected 112');
    }
    final signingPubkey = blob.sublist(0, 32);
    final bd = ByteData.sublistView(blob, 32, 48);
    final validFrom = bd.getInt64(0, Endian.big);
    final validUntil = bd.getInt64(8, Endian.big);
    final signature = blob.sublist(48, 112);
    return SigningCert(
      signingPubkey: signingPubkey,
      validFrom: validFrom,
      validUntil: validUntil,
      signature: signature,
    );
  }

  bool verify(Sodium sodium, Uint8List masterPubkey) {
    return sodium.crypto.sign.verifyDetached(
      signature: signature,
      message: _message(signingPubkey, validFrom, validUntil),
      publicKey: masterPubkey,
    );
  }

  static Uint8List _message(Uint8List pk, int from, int until) {
    final buf = ByteData(32 + 8 + 8);
    for (var i = 0; i < 32; i++) { buf.setUint8(i, pk[i]); }
    buf.setInt64(32, from, Endian.big);
    buf.setInt64(40, until, Endian.big);
    return buf.buffer.asUint8List();
  }
}

/// Certificate proving a device belongs to a user's identity.
/// Structure: devicePubkey(32) || os(1) || registeredAt(8) || masterSig(64) = 105 bytes
class DeviceCert {
  final Uint8List devicePubkey;   // Ed25519 device public key
  final int osCode;               // 0=android, 1=ios, 2=web, 3=linux
  final int registeredAt;         // unix seconds
  final Uint8List masterSig;      // Ed25519 sig by master key

  const DeviceCert({
    required this.devicePubkey,
    required this.osCode,
    required this.registeredAt,
    required this.masterSig,
  });

  Uint8List encode() {
    final buf = ByteData(32 + 1 + 8 + 64);
    for (var i = 0; i < 32; i++) buf.setUint8(i, devicePubkey[i]);
    buf.setUint8(32, osCode);
    buf.setInt64(33, registeredAt, Endian.big);
    for (var i = 0; i < 64; i++) buf.setUint8(41 + i, masterSig[i]);
    return buf.buffer.asUint8List();
  }

  static DeviceCert decode(Uint8List blob) {
    if (blob.length != 105) {
      throw FormatException('DeviceCert: invalid length ${blob.length}');
    }
    return DeviceCert(
      devicePubkey: blob.sublist(0, 32),
      osCode: blob[32],
      registeredAt: ByteData.sublistView(blob, 33, 41).getInt64(0, Endian.big),
      masterSig: blob.sublist(41, 105),
    );
  }

  bool verify(Sodium sodium, Uint8List masterPubkey) {
    return sodium.crypto.sign.verifyDetached(
      signature: masterSig,
      message: _message(devicePubkey, osCode, registeredAt),
      publicKey: masterPubkey,
    );
  }

  static Uint8List _message(Uint8List pk, int os, int ts) {
    final buf = ByteData(32 + 1 + 8);
    for (var i = 0; i < 32; i++) buf.setUint8(i, pk[i]);
    buf.setUint8(32, os);
    buf.setInt64(33, ts, Endian.big);
    return buf.buffer.asUint8List();
  }
}

/// User identity: two-level key scheme + X25519 keypair for DH sessions
/// + per-device keypair for multi-device DR sessions.
///
///   Master Key   — permanent Ed25519 ID, used only to certify Signing Key
///   Signing Key  — rotated weekly Ed25519, used for all message signatures
///   X25519 Key   — permanent, used as the DH identity key in Double Ratchet
///   Device Key   — per-device Ed25519, used for multi-device session init
class Identity {
  final Uint8List masterPublicKey;
  final Uint8List signingPublicKey;
  /// X25519 public key used as identity input in Double Ratchet handshake.
  final Uint8List x25519PublicKey;
  final SigningCert signingCert;

  // ── Device keys (multi-device support) ──────────────────────────────────
  /// Unique device identifier: SHA-256(masterPub || osCode || registeredAt).
  final String deviceId;
  /// Per-device Ed25519 public key — used as ephemeral in multi-device DR init.
  final Uint8List devicePublicKey;
  /// Certificate: Sign(masterPriv, devicePubkey || os || registeredAt).
  final DeviceCert deviceCert;
  /// Whether this device is the master device (owns signing key rotation).
  final bool isMasterDevice;

  final SecureKey _masterPrivateKey;
  final SecureKey _signingPrivateKey;
  final SecureKey _x25519PrivateKey;
  final SecureKey _devicePrivateKey;
  final Sodium _sodium;

  Identity._({
    required this.masterPublicKey,
    required this.signingPublicKey,
    required this.x25519PublicKey,
    required this.signingCert,
    required this.deviceId,
    required this.devicePublicKey,
    required this.deviceCert,
    required this.isMasterDevice,
    required SecureKey masterPrivateKey,
    required SecureKey signingPrivateKey,
    required SecureKey x25519PrivateKey,
    required SecureKey devicePrivateKey,
    required Sodium sodium,
  })  : _masterPrivateKey = masterPrivateKey,
        _signingPrivateKey = signingPrivateKey,
        _x25519PrivateKey = x25519PrivateKey,
        _devicePrivateKey = devicePrivateKey,
        _sodium = sodium;

  /// Reconstruct Identity from persisted key material (e.g. from KeystoreService).
  factory Identity.fromParts({
    required Sodium sodium,
    required Uint8List masterPublicKey,
    required SecureKey masterPrivateKey,
    required Uint8List signingPublicKey,
    required SecureKey signingPrivateKey,
    required Uint8List x25519PublicKey,
    required SecureKey x25519PrivateKey,
    required SigningCert signingCert,
    // Device fields — optional for backward compat (generated if missing)
    String? deviceId,
    Uint8List? devicePublicKey,
    SecureKey? devicePrivateKey,
    DeviceCert? deviceCert,
    bool isMasterDevice = true,
  }) {
    // Generate device keys if not provided (e.g. upgrading from pre-multidevice)
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final Uint8List devPub;
    final SecureKey devPriv;
    if (devicePublicKey != null && devicePrivateKey != null) {
      devPub  = devicePublicKey;
      devPriv = devicePrivateKey;
    } else {
      final kp = KeyGen(sodium).generateEd25519();
      devPub  = kp.publicKey;
      devPriv = kp.privateKey;
    }

    final dId   = deviceId ?? _computeDeviceId(masterPublicKey, 0, now);
    final dCert = deviceCert ?? _issueDeviceCert(
      sodium: sodium,
      masterPrivateKey: masterPrivateKey,
      devicePubkey: devPub,
      osCode: 0,
      registeredAt: now,
    );

    return Identity._(
      masterPublicKey: masterPublicKey,
      signingPublicKey: signingPublicKey,
      x25519PublicKey: x25519PublicKey,
      signingCert: signingCert,
      deviceId: dId,
      devicePublicKey: devPub,
      deviceCert: dCert,
      isMasterDevice: isMasterDevice,
      masterPrivateKey: masterPrivateKey,
      signingPrivateKey: signingPrivateKey,
      x25519PrivateKey: x25519PrivateKey,
      devicePrivateKey: devPriv,
      sodium: sodium,
    );
  }

  static Identity generate(
    Sodium sodium, {
    Duration signingKeyLifetime = const Duration(days: 7),
  }) {
    final kg = KeyGen(sodium);
    final masterKP  = kg.generateEd25519();
    final signingKP = kg.generateEd25519();
    final x25519KP  = kg.generateX25519();
    final deviceKP  = kg.generateEd25519();

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cert = _issueCert(
      sodium: sodium,
      masterPrivateKey: masterKP.privateKey,
      signingPubkey: signingKP.publicKey,
      validFrom: now,
      validUntil: now + signingKeyLifetime.inSeconds,
    );
    final deviceId = _computeDeviceId(masterKP.publicKey, 0, now);
    final deviceCert = _issueDeviceCert(
      sodium: sodium,
      masterPrivateKey: masterKP.privateKey,
      devicePubkey: deviceKP.publicKey,
      osCode: 0,
      registeredAt: now,
    );

    return Identity._(
      masterPublicKey: masterKP.publicKey,
      signingPublicKey: signingKP.publicKey,
      x25519PublicKey: x25519KP.publicKey,
      signingCert: cert,
      deviceId: deviceId,
      devicePublicKey: deviceKP.publicKey,
      deviceCert: deviceCert,
      isMasterDevice: true,
      masterPrivateKey: masterKP.privateKey,
      signingPrivateKey: signingKP.privateKey,
      x25519PrivateKey: x25519KP.privateKey,
      devicePrivateKey: deviceKP.privateKey,
      sodium: sodium,
    );
  }

  Identity rotateSigningKey({Duration lifetime = const Duration(days: 7)}) {
    final newKP = KeyGen(_sodium).generateEd25519();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cert = _issueCert(
      sodium: _sodium,
      masterPrivateKey: _masterPrivateKey,
      signingPubkey: newKP.publicKey,
      validFrom: now,
      validUntil: now + lifetime.inSeconds,
    );

    _signingPrivateKey.dispose();

    return Identity._(
      masterPublicKey: masterPublicKey,
      signingPublicKey: newKP.publicKey,
      x25519PublicKey: x25519PublicKey,
      signingCert: cert,
      deviceId: deviceId,
      devicePublicKey: devicePublicKey,
      deviceCert: deviceCert,
      isMasterDevice: isMasterDevice,
      masterPrivateKey: _masterPrivateKey,
      signingPrivateKey: newKP.privateKey,
      x25519PrivateKey: _x25519PrivateKey,
      devicePrivateKey: _devicePrivateKey,
      sodium: _sodium,
    );
  }

  /// Extracts raw private key bytes for secure persistence.
  /// Caller must zero the returned buffer after use.
  Uint8List get masterPrivateKeyBytes  => _masterPrivateKey.extractBytes();
  Uint8List get signingPrivateKeyBytes => _signingPrivateKey.extractBytes();
  Uint8List get x25519PrivateKeyBytes  => _x25519PrivateKey.extractBytes();
  Uint8List get devicePrivateKeyBytes  => _devicePrivateKey.extractBytes();
  SecureKey get x25519PrivateKey       => _x25519PrivateKey;
  SecureKey get devicePrivateKey       => _devicePrivateKey;

  Uint8List sign(Uint8List message) {
    return Uint8List.fromList(
      _sodium.crypto.sign.detached(
        message: message,
        secretKey: _signingPrivateKey,
      ),
    );
  }

  bool verify(Uint8List message, Uint8List signature) {
    return _sodium.crypto.sign.verifyDetached(
      signature: signature,
      message: message,
      publicKey: signingPublicKey,
    );
  }

  /// Stable fingerprint tied to master key — does not change on rotation.
  String get fingerprint {
    final h = masterPublicKey.sublist(0, 16);
    final s = hex.encode(h).toUpperCase();
    return '${s.substring(0, 4)}-${s.substring(4, 8)}-'
        '${s.substring(8, 12)}-${s.substring(12, 16)}';
  }

  void dispose() {
    _masterPrivateKey.dispose();
    _signingPrivateKey.dispose();
    _x25519PrivateKey.dispose();
    _devicePrivateKey.dispose();
  }

  // ── Device helpers ─────────────────────────────────────────────────────────

  /// Compute device_id = hex(SHA-256(masterPub || osCode || registeredAt)).
  static String _computeDeviceId(Uint8List masterPub, int osCode, int registeredAt) {
    final buf = ByteData(32 + 1 + 8);
    for (var i = 0; i < 32; i++) buf.setUint8(i, masterPub[i]);
    buf.setUint8(32, osCode);
    buf.setInt64(33, registeredAt, Endian.big);
    final digest = crypto.sha256.convert(buf.buffer.asUint8List());
    return digest.toString(); // 64-char hex
  }

  static DeviceCert _issueDeviceCert({
    required Sodium sodium,
    required SecureKey masterPrivateKey,
    required Uint8List devicePubkey,
    required int osCode,
    required int registeredAt,
  }) {
    final msg = DeviceCert._message(devicePubkey, osCode, registeredAt);
    final sig = Uint8List.fromList(
      sodium.crypto.sign.detached(message: msg, secretKey: masterPrivateKey),
    );
    return DeviceCert(
      devicePubkey: devicePubkey,
      osCode: osCode,
      registeredAt: registeredAt,
      masterSig: sig,
    );
  }

  static SigningCert _issueCert({
    required Sodium sodium,
    required SecureKey masterPrivateKey,
    required Uint8List signingPubkey,
    required int validFrom,
    required int validUntil,
  }) {
    final msg = SigningCert._message(signingPubkey, validFrom, validUntil);
    final sig = Uint8List.fromList(
      sodium.crypto.sign.detached(message: msg, secretKey: masterPrivateKey),
    );
    return SigningCert(
      signingPubkey: signingPubkey,
      validFrom: validFrom,
      validUntil: validUntil,
      signature: sig,
    );
  }
}
