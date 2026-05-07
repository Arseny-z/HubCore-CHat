import '../../../domain/ports/transport_port.dart' show TransportProtocol;
import '../../../infrastructure/transport/composite_transport.dart';
import '../../../domain/entities/envelope.dart';
import '../../../shared/services/avatar_service.dart';
import '../../../shared/utils/logger.dart';
import '../../../storage/storage_service.dart';

/// Sends a `contact_hello` envelope to a newly-added (or existing) contact.
///
/// Responsibilities:
///   1. Build the envelope via [buildHello] callback.
///   2. Deliver via [CompositeTransport] — Yggdrasil P2P first, then
///      Signal / Relay fallback (handled transparently by CompositeTransport).
///   3. Retry up to [maxAttempts] times on transient P2P failures, then give
///      up silently — the next startup broadcast will re-deliver.
///
/// **Not responsible for:**
///   - Waiting for Yggdrasil to start — the caller (screen or router) must
///     resolve [myYggPubKeyHex] before invoking [execute]. This is a
///     presentation / infrastructure concern, not application logic.
class SendContactHelloUseCase {
  final Envelope Function({
    required String recipientMasterPub58,
    required String myYggPubKeyHex,
    String? myReticulumAddress,
    String? myName,
    String? myAvatar,
  }) buildHello;
  final CompositeTransport _transport;
  final StorageService _storage;

  // Yggdrasil may drop packets until routing table converges (~30-60s).
  // Retry with increasing delays — runs in background, doesn't block UI.
  static const _maxAttempts = 10;
  static const _retryDelay  = Duration(seconds: 10);

  SendContactHelloUseCase({
    required this.buildHello,
    required CompositeTransport transport,
    required StorageService storage,
  }) : _transport = transport,
       _storage = storage;

  /// Send `contact_hello` to [recipientMasterPub58].
  ///
  /// [myYggPubKeyHex] — our Yggdrasil node public key (hex). Pass empty
  ///   string if Yggdrasil has not started yet; the envelope will omit the
  ///   `yk` field and CompositeTransport will fall through to Signal.
  ///
  /// [destTransportAddresses] — recipient's known transport addresses.
  ///   At minimum should contain 'yggdrasil' key from their QR code.
  ///   Null when contact was added by manual key entry (no QR).
  Future<void> execute({
    required String recipientMasterPub58,
    required String myYggPubKeyHex,
    String? myReticulumAddress,
    // Legacy param kept for QR-scan callers that only have Ygg key
    String? destYggPubKeyHex,
    Map<String, String>? destTransportAddresses,
    /// If true — send public profile (name + avatar for strangers).
    /// If false (default) — send contacts profile.
    bool publicProfile = false,
  }) async {
    final nameKey = publicProfile ? 'my_public_alias' : 'my_alias';
    final myName = await _storage.settings.get(nameKey);
    // No fallback: if public profile not set, stranger sees null (anonymous)
    final myAvatar = await AvatarService.instance.myAvatarBase64(
        publicProfile: publicProfile);
    final envelope = buildHello(
      recipientMasterPub58: recipientMasterPub58,
      myYggPubKeyHex: myYggPubKeyHex,
      myReticulumAddress: myReticulumAddress,
      myName: myName?.isNotEmpty == true ? myName : null,
      myAvatar: myAvatar,
    );

    // Merge: explicit map takes priority, legacy ygg key is fallback
    final addrs = <String, String>{
      if (destTransportAddresses != null) ...destTransportAddresses,
      if (destYggPubKeyHex != null && destYggPubKeyHex.isNotEmpty)
        TransportProtocol.yggdrasil: destYggPubKeyHex,
    };

    // Don't send hello to blocked contacts — avoids leaking our address/keys.
    final contact = await _storage.contacts.findByMasterPub(recipientMasterPub58);
    if (contact != null && contact.isBlocked) {
      AppLogger.d('HelloUseCase', 'skipping blocked contact ${recipientMasterPub58.substring(0, 8)}…');
      return;
    }

    AppLogger.d('HelloUseCase', 'sending contact_hello to ${recipientMasterPub58.substring(0, 8)}… addrs=${addrs.keys.join(",")}');
    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final result = await _transport.sendEnvelope(
          envelope,
          transportAddresses: addrs,
        );
        AppLogger.d('HelloUseCase', 'attempt $attempt: ${result.success ? "sent" : "failed: ${result.error}"}');
        if (result.success) break;
      } catch (e) {
        AppLogger.w('HelloUseCase', 'attempt $attempt exception: $e');
      }
      if (attempt < _maxAttempts) await Future.delayed(_retryDelay);
    }
    AppLogger.d('HelloUseCase', 'done ($recipientMasterPub58 — all $_maxAttempts attempts sent)');
  }
}
