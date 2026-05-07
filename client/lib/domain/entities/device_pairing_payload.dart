import 'dart:convert';
import 'dart:typed_data';

/// QR payload shown by Device A during pairing.
///
/// Wire format (QR string):
///   S1:<base64(nonce24 + key32 + exp4_le + ciphertext)>:<yggAddr>
///
/// Binary bundle plaintext (variable length):
///   masterPriv        [64]
///   signingPriv       [64]
///   x25519Priv        [32]
///   x25519Pub         [32]
///   cert              [112]   = 304 bytes fixed
///   my_alias_len      [2 LE]
///   my_alias          [N]
///   my_public_alias_len [2 LE]
///   my_public_alias   [M]
///
/// Typical total: ~320-360 bytes plaintext → ~550-580 chars in QR → version ~14
class PairingQrPayload {
  static const _prefix   = 'S1:';
  static const _nonceOff = 0;
  static const _nonceLen = 24;
  static const _keyOff   = _nonceLen;           // 24
  static const _keyLen   = 32;
  static const _expOff   = _keyOff + _keyLen;   // 56
  static const _expLen   = 4;
  static const _cipherOff = _expOff + _expLen;  // 60
  static const _minBlobLen = _cipherOff + 16;   // 76 (empty plaintext + MAC)

  final Uint8List nonce;
  final Uint8List tempKey;
  final Uint8List encryptedBundle;
  final int expiresAt;
  final String yggPubHex; // hex pubkey used by Yggdrasil transport for routing

  const PairingQrPayload({
    required this.nonce,
    required this.tempKey,
    required this.encryptedBundle,
    required this.expiresAt,
    required this.yggPubHex,
  });

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 > expiresAt;

  String encode() {
    final blob = Uint8List(_cipherOff + encryptedBundle.length);
    blob.setRange(_nonceOff, _nonceOff + _nonceLen, nonce);
    blob.setRange(_keyOff,   _keyOff   + _keyLen,   tempKey);
    blob[_expOff]     = expiresAt & 0xFF;
    blob[_expOff + 1] = (expiresAt >> 8) & 0xFF;
    blob[_expOff + 2] = (expiresAt >> 16) & 0xFF;
    blob[_expOff + 3] = (expiresAt >> 24) & 0xFF;
    blob.setRange(_cipherOff, blob.length, encryptedBundle);

    final b64 = base64.encode(blob);
    return yggPubHex.isNotEmpty ? '$_prefix$b64:$yggPubHex' : '$_prefix$b64';
  }

  static PairingQrPayload? tryDecode(String raw) {
    try {
      if (!raw.startsWith(_prefix)) return null;
      final rest = raw.substring(_prefix.length);

      String b64;
      String yggPubHex = '';
      final colonIdx = rest.indexOf(':');
      if (colonIdx != -1) {
        b64       = rest.substring(0, colonIdx);
        yggPubHex = rest.substring(colonIdx + 1);
      } else {
        b64 = rest;
      }

      final blob = base64.decode(b64);
      if (blob.length < _minBlobLen) return null;

      final nonce   = blob.sublist(_nonceOff, _nonceOff + _nonceLen);
      final key     = blob.sublist(_keyOff,   _keyOff   + _keyLen);
      final exp     = blob[_expOff] |
          (blob[_expOff + 1] << 8) |
          (blob[_expOff + 2] << 16) |
          (blob[_expOff + 3] << 24);
      final cipher  = blob.sublist(_cipherOff);

      return PairingQrPayload(
        nonce:           nonce,
        tempKey:         key,
        encryptedBundle: cipher,
        expiresAt:       exp,
        yggPubHex:       yggPubHex,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Sent by Device B → Device A after importing identity from QR.
class DevicePairingHandshake {
  final String deviceId;
  final Uint8List devicePub;
  final Uint8List deviceCert;
  final String yggPubHex;
  final Map<String, String> transportAddresses;

  const DevicePairingHandshake({
    required this.deviceId,
    required this.devicePub,
    required this.deviceCert,
    required this.yggPubHex,
    required this.transportAddresses,
  });

  Map<String, dynamic> toJson() => {
        'type':        'device_pairing_handshake',
        'device_id':   deviceId,
        'device_pub':  base64.encode(devicePub),
        'device_cert': base64.encode(deviceCert),
        'yk':          yggPubHex,
        'addrs':       transportAddresses,
      };

  static DevicePairingHandshake? tryFromJson(Map<String, dynamic> j) {
    try {
      return DevicePairingHandshake(
        deviceId:           j['device_id'] as String,
        devicePub:          base64.decode(j['device_pub'] as String),
        deviceCert:         base64.decode(j['device_cert'] as String),
        yggPubHex:          j['yk'] as String? ?? '',
        transportAddresses: (j['addrs'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Sent by Device A → Device B confirming registration.
class DevicePairingAck {
  final String deviceIdA;
  final Uint8List devicePubA;
  final Uint8List deviceCertA;
  final Map<String, String> transportAddressesA;

  const DevicePairingAck({
    required this.deviceIdA,
    required this.devicePubA,
    required this.deviceCertA,
    required this.transportAddressesA,
  });

  Map<String, dynamic> toJson() => {
        'type':          'device_pairing_ack',
        'device_id_a':   deviceIdA,
        'device_pub_a':  base64.encode(devicePubA),
        'device_cert_a': base64.encode(deviceCertA),
        'addrs_a':       transportAddressesA,
      };

  static DevicePairingAck? tryFromJson(Map<String, dynamic> j) {
    try {
      return DevicePairingAck(
        deviceIdA:           j['device_id_a'] as String,
        devicePubA:          base64.decode(j['device_pub_a'] as String),
        deviceCertA:         base64.decode(j['device_cert_a'] as String),
        transportAddressesA: (j['addrs_a'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
      );
    } catch (_) {
      return null;
    }
  }
}
