import 'dart:typed_data';

import '../entities/group_post_envelope.dart';

/// Result of a Double Ratchet DM encryption.
///
/// Contains everything needed to build a wire envelope:
/// the ciphertext, the ratchet counter, and optional ephemeral
/// public keys for session bootstrap / DH ratchet step.
class EncryptedDm {
  /// Encrypted message body (DR ciphertext).
  final Uint8List ciphertext;

  /// Ratchet send counter at time of encryption.
  final int counter;

  /// Present on the first message of a new session (X3DH bootstrap).
  final Uint8List? senderEphPub;

  /// Present when a DH ratchet step was performed.
  final Uint8List? newEphPub;

  const EncryptedDm({
    required this.ciphertext,
    required this.counter,
    this.senderEphPub,
    this.newEphPub,
  });
}

/// Metadata extracted from an incoming DM wire payload.
///
/// Passed into [CryptoPort.decryptDm] alongside the ciphertext.
class IncomingDmMeta {
  final int counter;
  final Uint8List? senderEphPub;
  final Uint8List? newEphPub;
  /// Ed25519 signature of [senderEphPub] by sender's signing key.
  final Uint8List? senderEphSig;
  /// Ed25519 signature of [newEphPub] by sender's signing key.
  final Uint8List? newEphSig;

  const IncomingDmMeta({
    required this.counter,
    this.senderEphPub,
    this.newEphPub,
    this.senderEphSig,
    this.newEphSig,
  });
}

/// Metadata extracted from an incoming group message wire payload.
class IncomingGroupMeta {
  final String groupId;
  final int counter;
  final Uint8List? newRatchetPub;

  const IncomingGroupMeta({
    required this.groupId,
    required this.counter,
    this.newRatchetPub,
  });
}

/// Reason why decryption failed.
enum DecryptError {
  /// No DR session and no bootstrap key in message.
  noSession,
  /// senderEphPub or newEphPub signature verification failed.
  badSignature,
  /// AEAD decryption failed (corrupt, tampered, or out-of-sync).
  aeadFailed,
  /// Counter is a replay of an already-processed message.
  counterReplay,
}

/// Result of a DM decryption attempt with error discrimination.
class DecryptResult {
  final String? plaintext;
  final DecryptError? error;

  const DecryptResult.success(this.plaintext) : error = null;
  const DecryptResult.failure(this.error) : plaintext = null;

  bool get ok => plaintext != null;
}

/// Abstract cryptography port.
///
/// Defines *what* operations the application needs; the concrete
/// algorithm (Double Ratchet, Sender Keys, NaCl box) lives in
/// `infrastructure/crypto/` and never leaks into application or domain.
///
/// ## Dependency Rule
/// This file lives in `domain/ports/` — it MUST NOT import anything
/// outside `dart:` core libraries.
abstract class CryptoPort {
  // ── Direct Messages (Double Ratchet) ──────────────────────────────────────

  /// Encrypt [plaintext] for [recipientMasterPub58] using Double Ratchet.
  ///
  /// Throws [StateError] if no session exists. Callers must ensure a session
  /// is established via [SessionPort] before calling this.
  Future<EncryptedDm> encryptDm(String recipientMasterPub58, String plaintext);

  /// Decrypt an incoming DM ciphertext from [senderMasterPub58].
  ///
  /// Returns the plaintext string, or null if decryption fails.
  Future<String?> decryptDm(
    String senderMasterPub58,
    Uint8List ciphertext,
    IncomingDmMeta meta,
  );

  /// Decrypt with detailed error information.
  Future<DecryptResult> decryptDmDetailed(
    String senderMasterPub58,
    Uint8List ciphertext,
    IncomingDmMeta meta,
  );

  // ── Signing ──────────────────────────────────────────────────────────────

  /// Sign [data] with the current signing key.
  Uint8List sign(Uint8List data);

  /// Verify [signature] over [data] using contact's signing key.
  Future<bool> verifyContact(
    String contactMasterPub58,
    Uint8List data,
    Uint8List signature,
  );

  /// Verify a SigningCert blob against a master public key.
  bool verifySigningCert(Uint8List certBytes, Uint8List masterPub);

  // ── System Messages (stateless NaCl box) ─────────────────────────────────

  /// Encrypt [plaintext] for [recipientMasterPub58] using a stateless
  /// NaCl box (no session required).
  Future<Uint8List> encryptBox(String recipientMasterPub58, Uint8List plaintext);

  /// Decrypt a stateless NaCl box addressed to us.
  Uint8List? decryptBox(Uint8List ciphertext);

  // ── Groups (Sender Keys — legacy, will be removed in P7 Phase 5) ─────────

  /// Encrypt [plaintext] for [groupId] using the local member's sender chain.
  Future<Uint8List> encryptGroup(String groupId, String plaintext);

  /// Decrypt an incoming group message from [senderMasterPub58].
  Future<String?> decryptGroup(
    String senderMasterPub58,
    IncomingGroupMeta meta,
    Uint8List ciphertext,
  );

  // ── Groups & channels (Per-Post Wrap, scheme B — P7) ────────────────────

  /// Build one per-post-wrap envelope per recipient. Signs the transcript
  /// once with our long-term Ed25519 signing key; wraps a fresh content
  /// key into a NaCl box for each recipient's X25519 pub.
  Future<GroupPostBuild> encryptGroupPost({
    required String groupId,
    required int epoch,
    required String messageId,
    required Uint8List plaintext,
    required List<GroupPostRecipient> recipients,
    int? ttlSeconds,
  });

  /// Verify and decrypt a per-post-wrap envelope addressed to us.
  ///
  /// Looks up the sender's Ed25519 signing key via [senderMasterPub58] in
  /// the contacts repository, then verifies the envelope signature and
  /// AEAD-decrypts the content using our long-term X25519 private key.
  Future<GroupPostDecryptResult> decryptGroupPost({
    required GroupPostEnvelope envelope,
    required String senderMasterPub58,
  });
}
