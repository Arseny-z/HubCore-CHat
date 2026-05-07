import 'dart:convert';
import 'dart:typed_data';

/// One encrypted copy of the message for a specific device.
class DeviceEnvelope {
  final String deviceId;
  final Uint8List ciphertext;
  final int counter;
  final Uint8List? newEphPub; // always null in symmetric-only mode

  const DeviceEnvelope({
    required this.deviceId,
    required this.ciphertext,
    required this.counter,
    this.newEphPub,
  });

  Map<String, dynamic> toJson() => {
    'did': deviceId,
    'c':   base64Encode(ciphertext),
    'n':   counter,
    if (newEphPub != null) 'e': base64Encode(newEphPub!),
  };

  factory DeviceEnvelope.fromJson(Map<String, dynamic> j) => DeviceEnvelope(
    deviceId:   j['did'] as String,
    ciphertext: base64Decode(j['c'] as String),
    counter:    j['n'] as int,
    newEphPub:  j['e'] != null ? base64Decode(j['e'] as String) : null,
  );
}

/// Wire format v=2: one logical message encrypted for N devices.
///
/// Backward compat: existing v=1 DmPayload is unchanged.
/// Receiver detects version from top-level "v" field.
class MultiDevicePayload {
  static const version = 2;

  final String senderDeviceId;
  final String senderMasterPub;   // base58 master public key — needed for contact lookup
  final Uint8List senderEphPub;   // device public key (Ed25519)
  final Uint8List senderEphSig;   // Sign(signingKey, senderEphPub)
  final List<DeviceEnvelope> recipients;
  final int? ttlSeconds;
  final String messageId;
  final String? replyToId;

  const MultiDevicePayload({
    required this.senderDeviceId,
    required this.senderMasterPub,
    required this.senderEphPub,
    required this.senderEphSig,
    required this.recipients,
    this.ttlSeconds,
    required this.messageId,
    this.replyToId,
  });

  Uint8List encode() {
    final json = <String, dynamic>{
      'v':    version,
      'sdid': senderDeviceId,
      'smp':  senderMasterPub,
      'se':   base64Encode(senderEphPub),
      'ss':   base64Encode(senderEphSig),
      'r':    recipients.map((r) => r.toJson()).toList(),
      'id':   messageId,
      if (ttlSeconds != null) 't': ttlSeconds,
      if (replyToId != null) 'rid': replyToId,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// Returns null if not a v=2 payload (caller should try v=1 DmPayload).
  static MultiDevicePayload? tryDecode(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (json['v'] != version) return null;
      return MultiDevicePayload(
        senderDeviceId:  json['sdid'] as String,
        senderMasterPub: json['smp'] as String? ?? '',
        senderEphPub:    base64Decode(json['se'] as String),
        senderEphSig:    base64Decode(json['ss'] as String),
        recipients: (json['r'] as List)
            .map((e) => DeviceEnvelope.fromJson(e as Map<String, dynamic>))
            .toList(),
        messageId:  json['id'] as String,
        ttlSeconds: json['t'] as int?,
        replyToId:  json['rid'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
