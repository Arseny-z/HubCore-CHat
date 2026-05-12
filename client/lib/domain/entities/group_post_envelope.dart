import 'dart:convert';
import 'dart:typed_data';

/// Per-recipient envelope for a group / channel post under scheme B.
///
/// Wire format (canonical JSON, base64-encoded byte fields):
///
/// ```json
/// {
///   "type":  "group_post",
///   "gid":   "<base58 group_id>",
///   "ep":    <epoch: int>,
///   "mid":   "<hex-8 message_id>",
///   "nc":    "<base64 content nonce, 24B>",
///   "ct":    "<base64 AEAD ciphertext>",
///   "wn":    "<base64 box nonce, 24B>",
///   "we":    "<base64 ephemeral X25519 pub, 32B>",
///   "wb":    "<base64 NaCl box of content_key>",
///   "sp":    "<base58 sender signing pub>",
///   "sig":   "<base64 Ed25519 signature, 64B>",
///   "t":     <ttl_seconds: int>?      // optional, omit if not set
/// }
/// ```
///
/// One envelope is produced per recipient. The header fields (gid, ep,
/// mid, nc, ct, sp, sig, t) are identical across recipients of the same
/// post; only the wrap fields (wn, we, wb) differ.
class GroupPostEnvelope {
  /// Discriminator string. Must be `"group_post"`.
  static const kType = 'group_post';

  final String groupId;            // conversation id
  final int epoch;                 // group roster epoch (bumped on add/kick)
  final String messageId;          // hex-8, for receipts and dedup

  // ── Shared content (identical across all recipients) ───────────────────
  final Uint8List contentNonce;     // 24 B
  final Uint8List contentCiphertext;

  // ── Per-recipient key wrap ─────────────────────────────────────────────
  final Uint8List wrapBoxNonce;     // 24 B
  final Uint8List wrapEphPub;       // 32 B (NaCl box ephemeral X25519 pub)
  final Uint8List wrapBox;          // NaCl-box-encrypted content_key

  // ── Sender authentication (identical across recipients) ────────────────
  final String senderPub;           // base58 Ed25519 signing pub
  final Uint8List signature;        // 64 B

  final int? ttlSeconds;            // optional disappearing TTL

  const GroupPostEnvelope({
    required this.groupId,
    required this.epoch,
    required this.messageId,
    required this.contentNonce,
    required this.contentCiphertext,
    required this.wrapBoxNonce,
    required this.wrapEphPub,
    required this.wrapBox,
    required this.senderPub,
    required this.signature,
    this.ttlSeconds,
  });

  Uint8List encode() {
    final m = <String, dynamic>{
      'type': kType,
      'gid':  groupId,
      'ep':   epoch,
      'mid':  messageId,
      'nc':   base64.encode(contentNonce),
      'ct':   base64.encode(contentCiphertext),
      'wn':   base64.encode(wrapBoxNonce),
      'we':   base64.encode(wrapEphPub),
      'wb':   base64.encode(wrapBox),
      'sp':   senderPub,
      'sig':  base64.encode(signature),
      if (ttlSeconds != null) 't': ttlSeconds,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(m)));
  }

  /// Decode bytes that may or may not be a `group_post` envelope.
  ///
  /// Returns `null` for non-JSON input or for JSON without the right
  /// `type` discriminator (so callers can fall through to other codecs).
  /// Throws [FormatException] when the JSON is well-formed but a
  /// required field is missing or malformed — this means the envelope
  /// is corrupted and should be dropped.
  static GroupPostEnvelope? tryDecode(Uint8List bytes) {
    Map<String, dynamic> m;
    try {
      final obj = jsonDecode(utf8.decode(bytes));
      if (obj is! Map<String, dynamic>) return null;
      m = obj;
    } catch (_) {
      return null;
    }
    if (m['type'] != kType) return null;

    return GroupPostEnvelope(
      groupId:           m['gid'] as String,
      epoch:             (m['ep'] as num).toInt(),
      messageId:         m['mid'] as String,
      contentNonce:      base64.decode(m['nc'] as String),
      contentCiphertext: base64.decode(m['ct'] as String),
      wrapBoxNonce:      base64.decode(m['wn'] as String),
      wrapEphPub:        base64.decode(m['we'] as String),
      wrapBox:           base64.decode(m['wb'] as String),
      senderPub:         m['sp'] as String,
      signature:         base64.decode(m['sig'] as String),
      ttlSeconds:        m['t'] != null ? (m['t'] as num).toInt() : null,
    );
  }
}

/// Identifies a recipient for the codec — caller decodes contact
/// material (master pub from base58, X25519 pub from base58) before
/// handing it to the codec.
class GroupPostRecipient {
  /// Recipient's master pub (base58) — used as routing address only.
  /// The codec does not encrypt to this; it is carried up to the
  /// transport so the resulting envelope can be addressed.
  final String masterPub58;

  /// Recipient's long-term X25519 public key (32 B raw).
  final Uint8List x25519Pub;

  const GroupPostRecipient({
    required this.masterPub58,
    required this.x25519Pub,
  });
}

/// Sender-side build result: one [GroupPostEnvelope] per recipient,
/// addressed by their master pub.
class GroupPostBuild {
  /// (recipient master pub, envelope) tuples, in the order the caller
  /// supplied recipients. Each envelope shares the same content and
  /// signature; only the wrap differs.
  final List<({String to, GroupPostEnvelope envelope})> envelopes;

  const GroupPostBuild(this.envelopes);
}

// ── Decrypt result (returned by codec / CryptoPort) ─────────────────────────

/// Outcome of a group_post decryption attempt.
sealed class GroupPostDecryptResult {
  const GroupPostDecryptResult();
}

class GroupPostDecryptSuccess extends GroupPostDecryptResult {
  final Uint8List plaintext;
  const GroupPostDecryptSuccess(this.plaintext);
}

enum GroupPostDecryptError {
  /// Ed25519 signature did not verify against the supplied sender pub
  /// (or sender's signing key is unknown locally).
  badSignature,
  /// NaCl box could not be opened with our X25519 private key
  /// (we are not a recipient, or the wrap is corrupted).
  wrapOpenFailed,
  /// AEAD content decryption failed (the wrapped key was wrong, or the
  /// ciphertext / AAD was tampered with).
  aeadFailed,
  /// Sender of the envelope is not a current member of the referenced
  /// group, or is banned. Receiver dropped the post.
  senderNotMember,
  /// Local group is unknown. Receiver dropped the post.
  unknownGroup,
}

class GroupPostDecryptFailure extends GroupPostDecryptResult {
  final GroupPostDecryptError reason;
  const GroupPostDecryptFailure(this.reason);
}
