import 'dart:typed_data';

/// Abstract session-management port.
///
/// Encapsulates the lifecycle of a Double Ratchet session with a contact:
/// checking existence, bootstrapping outbound (X3DH initiator) and
/// inbound (X3DH responder) sessions.
///
/// The concrete implementation lives in `infrastructure/crypto/`
/// and depends on Sodium + DAO; nothing above this layer needs to know that.
///
/// ## Dependency Rule
/// This file lives in `domain/ports/` — it MUST NOT import anything
/// outside `dart:` core libraries.
abstract class SessionPort {
  /// Returns true if an active Double Ratchet session exists for
  /// [contactMasterPub58].
  Future<bool> hasSession(String contactMasterPub58);

  /// Initialise an **outbound** session (X3DH initiator side).
  ///
  /// Called before the first message to a contact who has published
  /// an identity key. [peerEphPub] is optional: if the contact has
  /// pre-published a one-time ephemeral key, pass it here.
  Future<void> initOutbound({
    required String contactMasterPub58,
    required Uint8List peerIdentityPub,
    Uint8List? peerEphPub,
  });

  /// Initialise an **inbound** session (X3DH responder side).
  ///
  /// Called when we receive the first message from a new contact.
  /// [senderEphPub] is the initiator's ephemeral public key extracted
  /// from the wire payload. [myEphPub] / [myEphPriv] are the ephemeral
  /// key pair we used for this exchange.
  Future<void> initInbound({
    required String contactMasterPub58,
    required Uint8List senderEphPub,
    required Uint8List myEphPub,
    required Uint8List myEphPriv,
  });

  /// Delete the session for [contactMasterPub58], if it exists.
  ///
  /// Used when a contact is removed or when manually resetting a session.
  Future<void> deleteSession(String contactMasterPub58);
}
