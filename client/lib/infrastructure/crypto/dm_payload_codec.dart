import 'dart:convert';
import 'dart:typed_data';

/// Wire format for an encrypted DM envelope body.
///
/// Serialised as JSON (base64-encoded fields) inside Envelope.body.
/// Layout:
///   { "c": "<base64 ciphertext>",
///     "n": <counter int>,
///     "e": "<base64 newEphPub>" | null,
///     "s": "<base64 senderEphPub>" | null,   -- only in the very first message
///     "t": <ttl_seconds int> | null,          -- sender's TTL; receiver applies it
///     "id": "<hex-8 mid>" | null }
class DmPayload {
  final Uint8List ciphertext;
  final int counter;
  final Uint8List? newEphPub;

  /// Sender's ephemeral X25519 pubkey — included only in the first message
  /// to let the receiver bootstrap an inbound Double Ratchet session.
  final Uint8List? senderEphPub;

  /// Sender's TTL for this conversation (seconds). Receiver saves expiresAt
  /// based on this value so both sides delete the message at the same time.
  ///
  /// Encoding:
  ///   field absent   → old client (no TTL support); receiver may use local TTL
  ///   "t": 0         → sender explicitly disabled TTL; receiver must NOT apply local TTL
  ///   "t": N (N > 0) → sender's TTL is N seconds
  ///
  /// [ttlSeconds] == null means field is absent (old client / unknown).
  /// [ttlSeconds] == 0    means sender explicitly turned TTL off.
  final int? ttlSeconds;

  /// Hex-8 message ID for delivery receipt correlation.
  final String? mid;

  /// messageId of the quoted/replied-to message. Null = not a reply.
  final String? replyToId;

  /// Ed25519 signature of [senderEphPub] by sender's signing key.
  /// Present only when [senderEphPub] is set. Proves ephemeral key ownership.
  final Uint8List? senderEphSig;

  /// Ed25519 signature of [newEphPub] by sender's signing key.
  /// Present when DH ratchet provides a new ephemeral key.
  final Uint8List? newEphSig;

  const DmPayload({
    required this.ciphertext,
    required this.counter,
    this.newEphPub,
    this.senderEphPub,
    this.ttlSeconds,
    this.mid,
    this.senderEphSig,
    this.newEphSig,
    this.replyToId,
  });

  Uint8List encode() {
    final m = <String, dynamic>{
      'c': base64.encode(ciphertext),
      'n': counter,
      if (newEphPub != null) 'e': base64.encode(newEphPub!),
      if (senderEphPub != null) 's': base64.encode(senderEphPub!),
      if (senderEphSig != null) 'ss': base64.encode(senderEphSig!),
      if (newEphPub != null && newEphSig != null) 'es': base64.encode(newEphSig!),
      't': ttlSeconds ?? 0,
      if (mid != null) 'id': mid,
      if (replyToId != null) 'rid': replyToId,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  factory DmPayload.decode(Uint8List bytes) {
    final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return DmPayload(
      ciphertext:    base64.decode(m['c'] as String),
      counter:       m['n'] as int,
      newEphPub:     m['e'] != null ? base64.decode(m['e'] as String) : null,
      senderEphPub:  m['s'] != null ? base64.decode(m['s'] as String) : null,
      senderEphSig:  m['ss'] != null ? base64.decode(m['ss'] as String) : null,
      newEphSig:     m['es'] != null ? base64.decode(m['es'] as String) : null,
      ttlSeconds:    m.containsKey('t') ? (m['t'] as int) : null,
      mid:           m['id'] as String?,
      replyToId:     m['rid'] as String?,
    );
  }
}
