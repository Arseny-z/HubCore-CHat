import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/double_ratchet.dart';
import '../../crypto/keys.dart';
import '../../crypto/identity.dart';
import '../../domain/entities/envelope.dart';
import '../../storage/dao/messages_dao.dart';
import '../../storage/dao/sessions_dao.dart';
import '../../storage/storage_service.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../file_transfer/file_service.dart';
import '../../shared/services/avatar_service.dart';
import 'group_messaging_service.dart';
import '../../shared/utils/logger.dart';
import '../../storage/dao/notifications_dao.dart';
import 'dm_payload_codec.dart';
import 'multi_device_payload_codec.dart';
import 'multi_session_manager.dart';

/// Emitted when a delivery/read receipt updates a message status.
class StatusUpdate {
  final int messageId;       // local DB id
  final MessageStatus status;
  const StatusUpdate({required this.messageId, required this.status});
}


/// Manages Double Ratchet sessions and message encryption/decryption.
///
/// One instance per app session; must be initialised after DB is open.
class MessagingService {
  final Sodium _sodium;
  final Identity _identity;
  final StorageService _storage;
  final DoubleRatchet _ratchet;

  String get myMasterPub58 => PubkeyCodec.encode(_identity.masterPublicKey);

  /// Optional: called when a group_invite plaintext is received.
  GroupMessagingService? groupMessaging;

  /// Optional: called with a reply envelope when contact_hello is received.
  /// The caller should send this envelope via P2PTransport.
  void Function(Envelope replyEnvelope)? onContactHelloReply;

  /// Optional: called when a contact is added or updated via contact_hello.
  void Function()? onContactUpdated;

  /// Optional: called when contact's epoch advances (reinstall detected).
  /// UI should show "security key changed" notification.
  void Function(String contactPub, int newEpoch)? onKeyChange;

  /// Optional: called when DR decrypt fails — signals desync.
  /// Caller should send a contact_hello to trigger session re-negotiation.
  void Function(String contactMasterPub)? onDesyncDetected;

  /// Optional: file service for handling incoming file messages.
  FileService? fileService;

  /// Optional: called to send a raw (non-DR) envelope (e.g. file_ack).
  /// Wired by MessageRouter to P2PTransport.send.
  void Function(Envelope)? onSendRawEnvelope;

  /// Stream of status updates from incoming delivery/read receipts.
  final _statusCtrl = StreamController<StatusUpdate>.broadcast();
  Stream<StatusUpdate> get statusUpdated => _statusCtrl.stream;

  /// In-memory cache: contactId → RatchetState.
  final _sessions = <int, RatchetState>{};

  /// Per-contact send queue: serialises concurrent encrypt+save operations
  /// so two simultaneous sendMessage calls never overwrite each other's state.
  final _sessionQueue = <int, Future<void>>{};

  /// Optional HMAC key (32 bytes) for session integrity verification.
  /// Set after unlock via [setMacKey]. Null = HMAC disabled (backward compat).
  Uint8List? _macKey;

  void setMacKey(Uint8List? key) { _macKey = key; }

  MessagingService({
    required Sodium sodium,
    required Identity identity,
    required StorageService storage,
  })  : _sodium = sodium,
        _identity = identity,
        _storage = storage,
        _ratchet = DoubleRatchet(sodium);

  // ── Stateless box encryption (for file_offer) ─────────────────────────────

  /// Encrypt [plaintext] for [contactMasterPub58] using a single NaCl box
  /// (X25519 + XSalsa20-Poly1305). Stateless — no ratchet state required.
  ///
  /// Wire format: {"box": "<base64 nonce+ciphertext>", "epk": "<base64 ephemeral pubkey>"}
  Future<Envelope> encryptBox(
    String contactMasterPub58,
    Uint8List plaintext,
  ) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $contactMasterPub58');
    if (contact.x25519Pub == null) throw StateError('No X25519 key for contact');

    final peerPub = PubkeyCodec.decode(contact.x25519Pub!);
    final ephKP   = KeyGen(_sodium).generateX25519();
    final nonce   = _sodium.randombytes.buf(
      _sodium.crypto.box.nonceBytes,
    );

    final ciphertext = Uint8List.fromList(_sodium.crypto.box.easy(
      message:    plaintext,
      nonce:      nonce,
      publicKey:  peerPub,
      secretKey:  ephKP.privateKey,
    ));
    final ephPubBytes = Uint8List.fromList(ephKP.publicKey);
    ephKP.dispose();

    final body = Uint8List.fromList(utf8.encode(jsonEncode({
      'box': base64.encode(Uint8List.fromList([...nonce, ...ciphertext])),
      'epk': base64.encode(ephPubBytes),
    })));

    return Envelope(
      from: PubkeyCodec.encode(_identity.masterPublicKey),
      to:   contactMasterPub58,
      body: body,
    );
  }

  /// Decrypt a box envelope created by [encryptBox].
  /// Returns null if the body is not a box envelope or decryption fails.
  Uint8List? decryptBox(Uint8List body) {
    try {
      final m   = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (!m.containsKey('box') || !m.containsKey('epk')) return null;
      final raw = base64.decode(m['box'] as String);
      final epk = base64.decode(m['epk'] as String);
      final nonceLen = _sodium.crypto.box.nonceBytes;
      final nonce      = raw.sublist(0, nonceLen);
      final ciphertext = raw.sublist(nonceLen);
      return Uint8List.fromList(_sodium.crypto.box.openEasy(
        cipherText: ciphertext,
        nonce:      nonce,
        publicKey:  epk,
        secretKey:  _identity.x25519PrivateKey,
      ));
    } catch (e) {
      // Not a box message, or decryption failed — expected for non-box envelopes.
      return null;
    }
  }

  // ── Outgoing ───────────────────────────────────────────────────────────────

  /// Encrypt [plaintext] for [contactMasterPub58] and return a relay-ready [Envelope].
  ///
  /// Requires an existing session (created via [initOutboundSession]).
  /// Saves the encrypted message to the DB and persists updated session state.
  /// Encrypt [plaintext] for [contactMasterPub58] without saving to DB.
  /// Used for file chunks — only the placeholder message is saved, not each chunk.
  Future<Envelope> encryptForSend(
    String contactMasterPub58,
    String plaintext, {
    String? messageId,
  }) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $contactMasterPub58');

    return _withSessionLock(contact.id!, () async {
      final state = await _loadSession(contact.id!);
      if (state == null) throw StateError('No session for $contactMasterPub58.');

      final enc = _ratchet.encrypt(state, Uint8List.fromList(utf8.encode(plaintext)));
      await _saveSession(contact.id!, state);

      final senderEphPub = enc.counter == 0
          ? Uint8List.fromList(state.myEphemeral.publicKey)
          : null;

      final senderEphSig = senderEphPub != null
          ? _identity.sign(senderEphPub)
          : null;
      final newEphSig = enc.newEphemeralKey != null
          ? _identity.sign(enc.newEphemeralKey!)
          : null;

      final payload = DmPayload(
        ciphertext: enc.ciphertext,
        counter: enc.counter,
        newEphPub: enc.newEphemeralKey,
        senderEphPub: senderEphPub,
        senderEphSig: senderEphSig,
        newEphSig: newEphSig,
        mid: messageId,
      );

      return Envelope(
        from: PubkeyCodec.encode(_identity.masterPublicKey),
        to: contactMasterPub58,
        body: payload.encode(),
      );
    });
  }

  /// Encrypt [plaintext] for ALL known devices of [contactMasterPub58].
  ///
  /// Returns null if contact has no known devices (caller should fall back to v=1).
  /// Uses symmetric-only ratchet — no DH step — so offline devices stay in sync.
  Future<MultiDevicePayload?> encryptDmMultiDevice(
    String contactMasterPub58,
    String plaintext,
    MultiSessionManager multiSessions, {
    String? replyToId,
    int? ttlSeconds,
  }) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact?.id == null) return null;

    final devices = await _storage.contactDevices.forContact(contact!.id!);
    if (devices.isEmpty) return null;

    final plainBytes = Uint8List.fromList(utf8.encode(plaintext));
    final envelopes  = <DeviceEnvelope>[];

    for (final device in devices) {
      final enc = await multiSessions.encrypt(
        contactId: contact.id!,
        deviceId:  device.deviceId,
        plaintext: plainBytes,
        peerDeviceEphPub: device.deviceEphPub,
      );
      if (enc == null) continue;
      envelopes.add(DeviceEnvelope(
        deviceId:   device.deviceId,
        ciphertext: enc.ciphertext,
        counter:    enc.counter,
      ));
    }

    if (envelopes.isEmpty) return null;

    final mid = _randomMid();
    return MultiDevicePayload(
      senderDeviceId:  _identity.deviceId,
      senderMasterPub: PubkeyCodec.encode(_identity.masterPublicKey),
      senderEphPub:    _identity.devicePublicKey,
      senderEphSig:    _identity.sign(_identity.devicePublicKey),
      recipients:      envelopes,
      messageId:       mid,
      replyToId:       replyToId,
      ttlSeconds:      ttlSeconds,
    );
  }

  /// Returns the envelope and the wire messageId for receipt correlation.
  Future<({Envelope envelope, String messageId})> sendMessage(
    String contactMasterPub58,
    String plaintext, {
    String? replyToId,
  }) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact: $contactMasterPub58');

    // Read TTL and session-confirmed flag before entering the lock
    // (these are read-only and don't need to be serialised).
    final sentNow = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ttlStr  = await _storage.settings.get('ttl_seconds:$contactMasterPub58');
    final ttlSec  = ttlStr != null ? int.tryParse(ttlStr) : null;
    final confirmed = await _storage.settings.get('session_confirmed:$contactMasterPub58');

    // Critical section: encrypt + saveSession must be atomic per contact.
    final result = await _withSessionLock(contact.id!, () async {
      final state = await _loadSession(contact.id!);
      if (state == null) throw StateError('No session for $contactMasterPub58. Call initOutboundSession first.');

      final enc = _ratchet.encrypt(state, Uint8List.fromList(utf8.encode(plaintext)));
      await _saveSession(contact.id!, state);

      final senderEphPub = (enc.counter == 0 || confirmed != '1')
          ? Uint8List.fromList(state.myEphemeral.publicKey)
          : null;
      final senderEphSig = senderEphPub != null ? _identity.sign(senderEphPub) : null;
      final newEphSig    = enc.newEphemeralKey != null ? _identity.sign(enc.newEphemeralKey!) : null;

      return (enc: enc, senderEphPub: senderEphPub, senderEphSig: senderEphSig, newEphSig: newEphSig);
    });

    // Outside the lock: DB writes that don't affect ratchet state.
    final expiresAt = ttlSec != null ? sentNow + ttlSec : null;
    final mid = _randomMid();
    await _storage.messages.insert(Message(
      conversationId: contactMasterPub58,
      isGroup: false,
      senderPub: PubkeyCodec.encode(_identity.masterPublicKey),
      body: plaintext,
      sentAt: sentNow,
      status: MessageStatus.sent,
      expiresAt: expiresAt,
      messageId: mid,
      replyToId: replyToId,
    ));
    await _storage.messageReceipts.markSent(mid, contactMasterPub58, 'pending', sentNow);

    final payload = DmPayload(
      ciphertext:   result.enc.ciphertext,
      counter:      result.enc.counter,
      newEphPub:    result.enc.newEphemeralKey,
      senderEphPub: result.senderEphPub,
      senderEphSig: result.senderEphSig,
      newEphSig:    result.newEphSig,
      ttlSeconds:   ttlSec,
      mid:          mid,
      replyToId:    replyToId,
    );

    return (
      envelope: Envelope(
        from: PubkeyCodec.encode(_identity.masterPublicKey),
        to:   contactMasterPub58,
        body: payload.encode(),
      ),
      messageId: mid,
    );
  }

  // ── Incoming ───────────────────────────────────────────────────────────────

  /// Decrypt an incoming [envelope], persist the plaintext, return the message body.
  /// Process an incoming v=2 multi-device envelope.
  ///
  /// - If this device is in recipients: decrypt and return plaintext.
  /// - If not: store in cross_device_inbox for our other devices.
  /// Returns plaintext, or null if not for this device / failed.
  Future<String?> receiveEnvelopeMultiDevice(
    Envelope envelope,
    MultiDevicePayload payload,
    MultiSessionManager multiSessions,
  ) async {
    final senderPub = envelope.from;
    final contact   = await _storage.contacts.findByMasterPub(senderPub);
    if (contact?.id == null) return null;

    // Find the recipient entry for MY device
    final mine = payload.recipients
        .where((r) => r.deviceId == _identity.deviceId)
        .firstOrNull;

    if (mine == null) {
      // Not for this device — store for our other devices
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ttl = payload.ttlSeconds;
      await _storage.crossDeviceInbox.insert(CrossDeviceInboxEntry(
        messageId:        payload.messageId,
        senderPub:        senderPub,
        senderDeviceId:   payload.senderDeviceId,
        targetDeviceIds:  payload.recipients.map((r) => r.deviceId).toList(),
        encryptedPayload: envelope.body,
        receivedAt:       now,
        expiresAt:        ttl != null ? now + ttl : null,
      ));
      AppLogger.d('MsgSvc',
          'v=2 stored in cross_device_inbox for ${payload.recipients.length} device(s)');
      return null;
    }

    // Decrypt for this device
    final plainBytes = await multiSessions.decrypt(
      contactId:       contact!.id!,
      senderDeviceId:  payload.senderDeviceId,
      message: EncryptedMessage(
        ciphertext:    mine.ciphertext,
        counter:       mine.counter,
        previousCounter: mine.counter,
        newEphemeralKey: mine.newEphPub,
      ),
      senderEphPub: payload.senderEphPub,
    );
    if (plainBytes == null) {
      AppLogger.w('MsgSvc', 'v=2 decrypt failed for device ${_identity.deviceId.substring(0, 8)}…');
      return null;
    }

    final plaintext = utf8.decode(plainBytes);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ttl = payload.ttlSeconds;

    await _storage.messages.insert(Message(
      conversationId: senderPub,
      isGroup: false,
      senderPub: senderPub,
      body: plaintext,
      sentAt: now,
      receivedAt: now,
      status: MessageStatus.delivered,
      expiresAt: ttl != null ? now + ttl : null,
      messageId: payload.messageId,
      replyToId: payload.replyToId,
    ));

    AppLogger.d('MsgSvc', 'v=2 decrypted mid=${payload.messageId.substring(0, 8)}…');

    // Send delivery receipt back to sender (same as v=1 path)
    _sendDeliveredReceipt(senderPub, payload.messageId);

    return plaintext;
  }

  ///
  /// Handles two envelope types:
  ///   - Regular DM (encrypted DmPayload)
  ///   - System "cert_update" — updates the contact's signing pubkey in DB
  Future<String?> receiveEnvelope(Envelope envelope) async {
    final senderPub = envelope.from;
    var contact = await _storage.contacts.findByMasterPub(senderPub);
    if (contact == null) {
      final policy =
          await _storage.settings.get('incoming_contacts_policy') ?? 'all';
      if (policy != 'all') {
        AppLogger.d('Msg',
            'incoming from stranger ${senderPub.substring(0, 8)}… dropped: policy=$policy');
        return null;
      }
      // policy == 'all': create as stranger so they can chat but aren't in contacts
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _storage.contacts.insert(Contact(
        masterPub:    senderPub,
        signingPub:   senderPub,
        alias:        senderPub.substring(0, 8),
        addedAt:      now,
        relationship: 'stranger',
      ));
      contact = await _storage.contacts.findByMasterPub(senderPub);
      if (contact == null) return null;
    }

    // Blocked contacts: silent drop
    if (contact.isBlocked) {
      AppLogger.d('Msg',
          'incoming from blocked ${senderPub.substring(0, 8)}… dropped');
      return null;
    }


    // Check for raw (non-DR) file_ack — inject into FileService ack stream
    final rawAck = FileAck.tryDecode(envelope.body);
    if (rawAck != null) {
      fileService?.injectAck(rawAck);
      return null;
    }

    // Check for box-encrypted payloads (stateless, no ratchet)
    final boxPlain = decryptBox(envelope.body);
    if (boxPlain != null) {
      // group_invite via NaCl box
      final boxInvite = GroupInvite.tryDecode(boxPlain);
      if (boxInvite != null) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await _storage.notifications.insert(AppNotification(
          type: 'group_invite',
          payload: utf8.decode(boxPlain),
          fromPub: senderPub,
          createdAt: now,
        ));
        return null;
      }
      // ttl_delete — peer requests we delete messages by id
      try {
        final sys = jsonDecode(utf8.decode(boxPlain)) as Map<String, dynamic>;
        if (sys['type'] == 'ttl_delete') {
          final ids = (sys['ids'] as List).cast<int>();
          for (final id in ids) {
            await _storage.messages.deleteById(id);
          }
          return null;
        }
        if (sys['type'] == 'msg_delivered') {
          // Mark session as confirmed — stop including senderEphPub in future msgs
          await _storage.settings.set('session_confirmed:$senderPub', '1');
          final mid = sys['mid'] as String?;
          if (mid != null) {
            final msg = await _storage.messages.findByMessageId(mid);
            if (msg?.id != null && msg!.status == MessageStatus.sent) {
              await _storage.messages.updateStatus(msg.id!, MessageStatus.delivered);
              emitStatusUpdate(msg.id!, MessageStatus.delivered);
            }
          }
          return null;
        }
        if (sys['type'] == 'msg_read') {
          final mid = sys['mid'] as String?;
          if (mid != null) {
            final msg = await _storage.messages.findByMessageId(mid);
            final msgId = msg?.id;
            if (msgId != null) {
              await _storage.messages.updateStatus(msgId, MessageStatus.read);
              emitStatusUpdate(msgId, MessageStatus.read);
            }
          }
          return null;
        }
        if (sys['type'] == 'file_cancel') {
          final tid = sys['tid'] as String?;
          AppLogger.d('File', 'received file_cancel tid=$tid');
          if (tid != null) fileService?.injectCancel(tid);
          return null;
        }
      } catch (e) {
        AppLogger.w('MsgSvc', 'box: unknown system message type', error: e);
      }

      final offer = FileOffer.tryDecode(boxPlain);
      if (offer != null && fileService != null) {
        await fileService!.handleFileOffer(senderPub, contact.yggPubKeyHex, offer);
        return null;
      }
    }

    // Check for raw (non-DR) file_chunk
    final rawChunk = FileChunk.tryDecode(envelope.body);
    if (rawChunk != null && fileService != null) {
      final myPub58 = PubkeyCodec.encode(_identity.masterPublicKey);
      Future<void> ackSendFn(Envelope env) async => onSendRawEnvelope?.call(env);
      final fileName = await fileService!.handleIncomingChunk(
        senderPub, rawChunk, myPub58, ackSendFn,
      );
      if (fileName != null) {
        onContactUpdated?.call();
        return fileName;
      }
      return null;
    }

    // Check for system envelope types first
    try {
      final json = jsonDecode(utf8.decode(envelope.body)) as Map<String, dynamic>;
      if (json['type'] == 'contact_hello') {
        // Always reply — ensures both sides always have each other's latest addresses
        final needReply = true;
        await _handleContactHello(senderPub, contact, json);
        if (needReply) {
          final myName = await _storage.settings.get('my_alias');
          final myAvatar = await AvatarService.instance.myAvatarBase64();
          final reply = buildContactHello(
            recipientMasterPub58: senderPub,
            myYggPubKeyHex: '',
            myName: myName?.isNotEmpty == true ? myName : null,
            myAvatar: myAvatar,
          );
          onContactHelloReply?.call(reply);
        }
        return null; // system message — not displayed
      }
      if (json['type'] == 'cert_update') {
        await _handleCertUpdate(senderPub, json);
        return null; // system message — not displayed
      }
    } catch (_) {
      // Not a JSON system message — fall through to DM decryption
    }

    // Check for group message before trying DM decryption
    if (groupMessaging != null) {
      final groupPlain = await groupMessaging!.receiveGroupEnvelope(envelope);
      if (groupPlain != null) return groupPlain;
    }

    late DmPayload payload;
    try {
      payload = DmPayload.decode(envelope.body);
    } catch (e) {
      return null; // malformed
    }

    var state = await _loadSession(contact.id!);
    if (state == null) {
      // No session yet — try to auto-init from the sender's ephemeral key
      // embedded in the first message (field "s").
      if (payload.senderEphPub != null) {
        if (payload.senderEphPub!.length != 32) {
          AppLogger.w('MsgSvc', 'REJECTED: senderEphPub length ${payload.senderEphPub!.length} != 32');
          return null;
        }
        // Verify senderEphPub signature if present.
        // Skip verification if signingPub == masterPub (placeholder before
        // first contact_hello — happens when contact was added via QR without sp field).
        final hasRealSigningKey = contact.signingPub != senderPub;
        if (payload.senderEphSig != null && hasRealSigningKey) {
          try {
            final signingPub = PubkeyCodec.decode(contact.signingPub);
            final valid = _sodium.crypto.sign.verifyDetached(
              signature: payload.senderEphSig!,
              message: payload.senderEphPub!,
              publicKey: signingPub,
            );
            if (!valid) {
              AppLogger.w('MsgSvc', 'REJECTED: invalid senderEphPub signature from ${senderPub.substring(0, 8)}…');
              return null;
            }
            AppLogger.d('MsgSvc', 'senderEphPub signature VERIFIED from ${senderPub.substring(0, 8)}…');
          } catch (e) {
            AppLogger.e('MsgSvc', 'senderEphSig verify error', error: e);
            return null;
          }
        }
        // No sig or placeholder signingPub = skip verification (first message before contact_hello)

        state = _ratchet.initReceiver(
          myIdentityPrivkey: _identity.x25519PrivateKey,
          myIdentityPubkey: _identity.x25519PublicKey,
          myEphemeralPrivkey: _identity.x25519PrivateKey,
          myEphemeralPubkey: _identity.x25519PublicKey,
          senderEphemeralPubkey: payload.senderEphPub!,
        );
        _sessions[contact.id!] = state;
        await _saveSession(contact.id!, state);
      } else {
        return null; // no session and no bootstrap key — drop
      }
    }

    // Verify newEphPub signature before advancing the DH ratchet.
    // Mirrors senderEphSig logic: skip if sig absent (backward compat) or
    // signingPub is still a placeholder (== masterPub).
    if (payload.newEphPub != null && payload.newEphSig != null) {
      final hasRealSigningKey = contact.signingPub != senderPub;
      if (hasRealSigningKey) {
        try {
          final signingPub = PubkeyCodec.decode(contact.signingPub);
          final valid = _sodium.crypto.sign.verifyDetached(
            signature: payload.newEphSig!,
            message:   payload.newEphPub!,
            publicKey: signingPub,
          );
          if (!valid) {
            AppLogger.w('MsgSvc',
                'REJECTED: invalid newEphPub signature from ${senderPub.substring(0, 8)}…');
            return null;
          }
          AppLogger.d('MsgSvc',
              'newEphPub signature VERIFIED from ${senderPub.substring(0, 8)}…');
        } catch (e) {
          AppLogger.e('MsgSvc', 'newEphSig verify error', error: e);
          return null;
        }
      }
    }

    final plainBytes = _ratchet.tryDecrypt(
      state,
      payload.ciphertext,
      payload.counter,
      newPeerEphemeral: payload.newEphPub,
    );
    if (plainBytes == null) {
      await _saveSession(contact.id!, state);
      onDesyncDetected?.call(senderPub);
      return null;
    }

    await _saveSession(contact.id!, state);

    final plaintext = utf8.decode(plainBytes);

    await _storage.contacts.touchLastSeen(senderPub);

    // Check if decrypted plaintext is a group_invite system message
    final invite = GroupInvite.tryDecode(Uint8List.fromList(utf8.encode(plaintext)));
    AppLogger.d('MsgSvc', 'group_invite? ${invite != null}');
    if (invite != null) {
      // Save as pending notification instead of auto-accepting
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _storage.notifications.insert(AppNotification(
        type: 'group_invite',
        payload: plaintext,
        fromPub: senderPub,
        createdAt: now,
      ));
      return null; // not displayed as a chat message
    }

    // Check if decrypted plaintext is a file_offer
    final offer = FileOffer.tryDecode(plainBytes);
    if (offer != null && fileService != null) {
      await fileService!.handleFileOffer(senderPub, contact.yggPubKeyHex, offer);
      return null; // not displayed as a chat message (placeholder created in sender's DB)
    }

    // Check if decrypted plaintext is a legacy file envelope (type=file)
    final legacyFile = await fileService?.receiveFileEnvelope(envelope, plainBytes);
    if (legacyFile != null) {
      final contentType = legacyFile.mimeType.startsWith('image/')
          ? ContentType.image
          : legacyFile.mimeType.startsWith('video/')
              ? ContentType.video
              : ContentType.file;
      final fileName = legacyFile.localPath.split('/').last.replaceAll('.enc', '');
      final msgId = await _storage.messages.insert(Message(
        conversationId: senderPub,
        isGroup: false,
        senderPub: senderPub,
        body: fileName,
        contentType: contentType,
        sentAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        receivedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        status: MessageStatus.delivered,
      ));
      await _storage.files.updateMessageId(legacyFile.fileId, msgId);
      return fileName;
    }

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Determine effective TTL:
    //   payload.ttlSeconds == null  → old client (no "t" field); fall back to local setting
    //   payload.ttlSeconds == 0     → sender explicitly disabled TTL; do NOT apply local TTL
    //   payload.ttlSeconds > 0      → use sender's TTL
    int? effectiveTtl;
    if (payload.ttlSeconds == null) {
      // Old client — fall back to local TTL setting
      final ttlStr = await _storage.settings.get('ttl_seconds:$senderPub');
      effectiveTtl = ttlStr != null ? int.tryParse(ttlStr) : null;
    } else if (payload.ttlSeconds! > 0) {
      effectiveTtl = payload.ttlSeconds;
    }
    // else payload.ttlSeconds == 0 → effectiveTtl stays null (no expiry)
    final recvExpiresAt = effectiveTtl != null ? nowSec + effectiveTtl : null;
    await _storage.messages.insert(Message(
      conversationId: senderPub,
      isGroup: false,
      senderPub: senderPub,
      body: plaintext,
      sentAt: nowSec,
      receivedAt: nowSec,
      status: MessageStatus.delivered,
      expiresAt: recvExpiresAt,
      messageId: payload.mid,
    ));

    // Send delivery receipt back to sender (best-effort, fire-and-forget)
    if (payload.mid != null) {
      _sendDeliveredReceipt(senderPub, payload.mid!);
    }

    return plaintext;
  }

  // ── Cert update ────────────────────────────────────────────────────────────

  Future<void> _handleCertUpdate(
    String senderPub,
    Map<String, dynamic> json,
  ) async {
    try {
      final newSigningPub = base64.decode(json['signing_pub'] as String);
      // Basic sanity check: Ed25519 pubkey is 32 bytes
      if (newSigningPub.length != 32) return;
      await _storage.contacts.updateSigningPub(senderPub, PubkeyCodec.encode(newSigningPub));
    } catch (_) {
      // Malformed cert_update — ignore
    }
  }

  /// Handles a contact_hello system message — verifies signatures and updates keys.
  Future<void> _handleContactHello(
    String senderPub,
    Contact contact,
    Map<String, dynamic> json,
  ) async {
    // Don't process hellos from blocked contacts — no key updates, no reply.
    if (contact.isBlocked) return;
    // ── Verify cert + sig if present ─────────────────────────────────────
    final certB64 = json['cert'] as String?;
    final sigB64 = json['sig'] as String?;

    if (certB64 != null && sigB64 != null) {
      try {
        final certBytes = base64Decode(certB64);
        final cert = SigningCert.decode(certBytes);

        // 1. Verify cert was signed by sender's master key
        final masterPub = PubkeyCodec.decode(senderPub);
        if (!cert.verify(_sodium, masterPub)) {
          AppLogger.w('MsgSvc', 'contact_hello REJECTED: invalid cert signature from ${senderPub.substring(0, 8)}…');
          return;
        }

        // 2. Verify payload signature — use same fixed key order as signing
        final jsonWithoutSig = Map<String, dynamic>.from(json)..remove('sig');
        final canonical = utf8.encode(_helloCanonical(jsonWithoutSig));
        final sig = base64Decode(sigB64);
        final valid = _sodium.crypto.sign.verifyDetached(
          signature: Uint8List.fromList(sig),
          message: Uint8List.fromList(canonical),
          publicKey: cert.signingPubkey,
        );
        if (!valid) {
          AppLogger.w('MsgSvc', 'contact_hello REJECTED: invalid payload signature from ${senderPub.substring(0, 8)}…');
          return;
        }

        // 3. Check cert validity (time window)
        if (!cert.isValid) {
          AppLogger.w('MsgSvc', 'contact_hello REJECTED: expired cert from ${senderPub.substring(0, 8)}…');
          return;
        }

        AppLogger.d('MsgSvc', 'contact_hello VERIFIED from ${senderPub.substring(0, 8)}…');
      } catch (e) {
        AppLogger.e('MsgSvc', 'contact_hello cert/sig parse error', error: e);
        return; // Malformed — reject
      }
    } else {
      // No cert/sig — legacy client. Accept for backward compatibility.
      AppLogger.d('MsgSvc', 'contact_hello from ${senderPub.substring(0, 8)}… (unsigned — legacy)');
    }

    // ── Check epoch (reinstall detection) ───────────────────────────────
    final epoch = json['epoch'] as int?;
    if (epoch != null) {
      final savedStr = await _storage.settings.get('contact_epoch:$senderPub');
      final savedEpoch = savedStr != null ? int.tryParse(savedStr) ?? 0 : 0;
      if (epoch < savedEpoch) {
        AppLogger.w('MsgSvc', 'contact_hello REJECTED: epoch $epoch < saved $savedEpoch (replay)');
        return;
      }
      if (epoch > savedEpoch) {
        // Keys changed (reinstall) — notify via callback, delete old session
        AppLogger.d('MsgSvc', 'contact_hello: epoch advanced $savedEpoch → $epoch (key change)');
        onKeyChange?.call(senderPub, epoch);
        // Delete old session — new one will be created on next message exchange
        final c = await _storage.contacts.findByMasterPub(senderPub);
        if (c?.id != null) {
          await _storage.sessions.deleteForContact(c!.id!);
          _sessions.remove(c.id);
        }
        await _storage.settings.set('session_confirmed:$senderPub', '');
      }
      await _storage.settings.set('contact_epoch:$senderPub', epoch.toString());
    }

    // ── Update contact keys & addresses ─────────────────────────────────
    final x25519PubStr = json['x'] as String?;
    final yggPubKeyHex = json['yk'] as String?;
    final signingPubStr = json['sp'] as String?;
    final reticulumAddress = json['rk'] as String?;
    final senderTs = json['ts'] as int?;
    final senderName = json['name'] as String?;
    final senderAvatar = json['av'] as String?;

    if (x25519PubStr != null) {
      await _storage.contacts.updateX25519Pub(senderPub, x25519PubStr);
    }
    if (yggPubKeyHex != null) {
      await _storage.contacts.updateYggPubKey(senderPub, yggPubKeyHex);
    }
    if (signingPubStr != null) {
      await _storage.contacts.updateSigningPub(senderPub, signingPubStr);
    }
    if (reticulumAddress != null && reticulumAddress.isNotEmpty) {
      await _storage.contacts.updateTransportAddress(senderPub, 'reticulum', reticulumAddress);
      AppLogger.d('MsgSvc', 'contact_hello: saved reticulum address for ${senderPub.substring(0, 8)}…');
    }
    // Always update avatar — contact may have changed it
    if (senderAvatar != null && senderAvatar.isNotEmpty) {
      try {
        await AvatarService.instance.saveFromBase64(senderPub, senderAvatar);
        AppLogger.d('MsgSvc', 'contact_hello: avatar updated for ${senderPub.substring(0, 8)}…');
      } catch (e) {
        AppLogger.w('MsgSvc', 'contact_hello: avatar save failed', error: e);
      }
    }

    // Update alias only if user hasn't customised it manually
    if (senderName != null && senderName.isNotEmpty) {
      final contact = await _storage.contacts.findByMasterPub(senderPub);
      if (contact != null && !contact.aliasCustomized) {
        await _storage.contacts.updateAlias(senderPub, senderName);
        AppLogger.d('MsgSvc', 'contact_hello: alias updated to "$senderName" for ${senderPub.substring(0, 8)}…');
      }
    }

    // Update last_seen from sender's timestamp (or use our local time as fallback)
    final seenAt = senderTs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.contacts.updateLastSeen(senderPub, seenAt);

    // ── Multi-device: process devices list ──────────────────────────────────
    final devicesVersion = json['devices_version'] as int?;
    final devicesChanged = json['devices_changed'] as List?;
    final devicesRemoved = json['devices_removed'] as List?;

    if (devicesVersion != null && devicesChanged != null) {
      final contact = await _storage.contacts.findByMasterPub(senderPub);
      if (contact?.id != null) {
        final cachedVersion = contact!.devicesVersion;
        if (devicesVersion > cachedVersion) {
          for (final d in devicesChanged) {
            try {
              final dm = d as Map<String, dynamic>;
              final deviceId  = dm['device_id'] as String?;
              final devicePub = dm['device_pubkey'] as String?;
              final deviceEph = dm['device_eph_pub'] as String?;
              final certB64   = dm['device_cert'] as String?;
              final addrs     = dm['transport_addresses'] as Map?;
              if (deviceId == null || devicePub == null) continue;

              await _storage.contactDevices.upsert(ContactDevice(
                contactId: contact.id!,
                deviceId: deviceId,
                devicePubkey: base64Decode(devicePub),
                deviceEphPub: deviceEph != null
                    ? base64Decode(deviceEph) : null,
                deviceCert: certB64 != null
                    ? base64Decode(certB64) : null,
                deviceOs: dm['os'] as String?,
                transportAddresses: addrs != null
                    ? Map<String, String>.from(addrs) : {},
                registeredAt: dm['registered_at'] as int?,
              ));
            } catch (e) {
              AppLogger.w('MsgSvc', 'devices_changed parse error: $e');
            }
          }
          for (final id in (devicesRemoved ?? [])) {
            try {
              await _storage.contactDevices.deactivate(contact.id!, id as String);
            } catch (_) {}
          }
          await _storage.contacts.updateDevicesVersion(senderPub, devicesVersion);
          AppLogger.d('MsgSvc',
              'contact_hello: updated ${devicesChanged.length} devices for ${senderPub.substring(0, 8)}…');
        }
      }
    }

    onContactUpdated?.call();
  }

  // ── Session init ───────────────────────────────────────────────────────────

  /// Initiator side: we send first.
  ///
  /// [peerIdentityPub] is the contact's X25519 identity key (from QR or KeyPackage).
  /// [peerEphemeralPub] is optional: if null, [peerIdentityPub] is used as both
  /// identity and ephemeral key (simplified X3DH without relay KeyPackages).
  Future<void> initOutboundSession({
    required String contactMasterPub58,
    required Uint8List peerIdentityPub,
    Uint8List? peerEphemeralPub,
  }) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact');

    final state = _ratchet.initSender(
      peerIdentityPubkey: peerIdentityPub,
      // Use identity key as ephemeral when no one-time prekey is available.
      peerEphemeralPubkey: peerEphemeralPub ?? peerIdentityPub,
    );

    _sessions[contact.id!] = state;
    await _saveSession(contact.id!, state);
  }

  /// Responder side: they sent first.
  ///
  /// Called when we receive the very first message from a contact and need
  /// to establish the inbound session.
  ///
  /// [senderEphemeralPub] — Alice's ephemeral X25519 pubkey from her KeyPackage
  ///   or QR handshake payload.
  /// [myEphemeralPub] / [myEphemeralPriv] — our one-time pre-key that Alice used
  ///   (fetched from relay KeyPackage store and now consumed).
  Future<void> initInboundSession({
    required String contactMasterPub58,
    required Uint8List senderEphemeralPub,
    required Uint8List myEphemeralPub,
    required SecureKey myEphemeralPriv,
  }) async {
    final contact = await _storage.contacts.findByMasterPub(contactMasterPub58);
    if (contact == null) throw StateError('Unknown contact');

    final state = _ratchet.initReceiver(
      myIdentityPrivkey: _identity.x25519PrivateKey,
      myIdentityPubkey: _identity.x25519PublicKey,
      myEphemeralPrivkey: myEphemeralPriv,
      myEphemeralPubkey: myEphemeralPub,
      senderEphemeralPubkey: senderEphemeralPub,
    );

    _sessions[contact.id!] = state;
    await _saveSession(contact.id!, state);
  }

  // ── Contact hello ─────────────────────────────────────────────────────────

  /// Produce a deterministic JSON string for contact_hello signing.
  ///
  /// Keys are emitted in a fixed order so the canonical form is identical
  /// regardless of Map insertion order or future Dart runtime changes.
  static String _helloCanonical(Map<String, dynamic> payload) {
    const order = ['type','mp','sp','x','yk','rk','name','av','epoch','cert','ts'];
    final ordered = <String, dynamic>{};
    for (final k in order) {
      if (payload.containsKey(k)) ordered[k] = payload[k];
    }
    for (final k in payload.keys) {
      if (!ordered.containsKey(k)) ordered[k] = payload[k];
    }
    return jsonEncode(ordered);
  }

  /// Build a contact_hello envelope addressed to [recipientMasterPub58].
  /// The caller is responsible for sending it via P2PTransport.
  Envelope buildContactHello({
    required String recipientMasterPub58,
    required String myYggPubKeyHex,
    String? myReticulumAddress,
    int epoch = 0,
    String? myName,
    String? myAvatar,
    List<Map<String, dynamic>>? myDevices,
    int devicesVersion = 0,
  }) {
    final payload = <String, dynamic>{
      'type': 'contact_hello',
      'mp': PubkeyCodec.encode(_identity.masterPublicKey),
      'sp': PubkeyCodec.encode(_identity.signingPublicKey),
      'x': PubkeyCodec.encode(_identity.x25519PublicKey),
      if (myYggPubKeyHex.isNotEmpty) 'yk': myYggPubKeyHex,
      if (myReticulumAddress != null && myReticulumAddress.isNotEmpty) 'rk': myReticulumAddress,
      if (myName != null && myName.isNotEmpty) 'name': myName,
      if (myAvatar != null && myAvatar.isNotEmpty) 'av': myAvatar,
      'epoch': epoch,
      'cert': base64Encode(_identity.signingCert.encode()),
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      // Multi-device: include own devices list
      if (myDevices != null && myDevices.isNotEmpty) ...{
        'devices_version': devicesVersion,
        'devices_changed': myDevices,
      },
    };
    final canonical = utf8.encode(_helloCanonical(payload));
    final sig = _identity.sign(Uint8List.fromList(canonical));
    payload['sig'] = base64Encode(sig);

    return Envelope(
      from: PubkeyCodec.encode(_identity.masterPublicKey),
      to: recipientMasterPub58,
      body: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
  }

  // ── Convenience ───────────────────────────────────────────────────────────

  /// True if we have an established session for [contactPub58].
  Future<bool> hasSession(String contactPub58) async {
    final contact = await _storage.contacts.findByMasterPub(contactPub58);
    if (contact?.id == null) return false;
    return await _storage.sessions.forContact(contact!.id!) != null;
  }

  /// Public wrapper: handle a contact_hello JSON payload from [senderPub].
  Future<void> handleContactHelloJson(
      String senderPub, Map<String, dynamic> json) async {
    final contact = await _storage.contacts.findByMasterPub(senderPub);
    if (contact == null) return;
    await _handleContactHello(senderPub, contact, json);
  }

  /// Public wrapper: handle a cert_update JSON payload from [senderPub].
  Future<void> handleCertUpdateJson(
      String senderPub, Map<String, dynamic> json) async {
    await _handleCertUpdate(senderPub, json);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Run [fn] exclusively for [contactId]: waits for any in-progress
  /// encrypt+save to finish before starting, then chains the next one.
  static const _sessionLockTimeout = Duration(seconds: 30);

  Future<T> _withSessionLock<T>(int contactId, Future<T> Function() fn) {
    final completer = Completer<T>();
    final prev = _sessionQueue[contactId] ?? Future<void>.value();
    _sessionQueue[contactId] = prev.then((_) async {
      try {
        completer.complete(
          await fn().timeout(
            _sessionLockTimeout,
            onTimeout: () => throw TimeoutException(
              'Session lock timed out for contact $contactId after ${_sessionLockTimeout.inSeconds}s',
            ),
          ),
        );
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<RatchetState?> _loadSession(int contactId) async {
    if (_sessions.containsKey(contactId)) return _sessions[contactId];

    final record = await _storage.sessions.forContact(contactId);
    if (record == null) return null;

    // HMAC integrity check — same algorithm as SessionManager.
    final macKey = _macKey;
    if (macKey != null && record.hmac != null) {
      final expected = _computeSessionHmac(record, macKey);
      if (!_hmacEqual(expected, record.hmac!)) {
        AppLogger.e('Msg', 'Session HMAC mismatch for contact $contactId — deleting, will re-negotiate');
        await _storage.sessions.deleteForContact(contactId);
        return null;
      }
    }

    final state = _recordToState(record);
    _sessions[contactId] = state;
    return state;
  }

  /// Compute BLAKE2b-32 MAC over critical session fields (mirrors SessionManager).
  Uint8List _computeSessionHmac(SessionRecord r, Uint8List macKey) {
    final buf = ByteData(8 + 5 * 32 + 5 * 8);
    buf.setInt64(0, r.contactId, Endian.big);
    for (var i = 0; i < 32; i++) buf.setUint8(8 + i,   r.rootKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(40 + i,  r.sendChainKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(72 + i,  r.recvChainKey[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(104 + i, r.myEphPub[i]);
    for (var i = 0; i < 32; i++) buf.setUint8(136 + i, r.myEphPriv[i]);
    buf.setInt64(168, r.sendCounter,        Endian.big);
    buf.setInt64(176, r.recvCounter,        Endian.big);
    buf.setInt64(184, r.sendSinceRatchet,   Endian.big);
    buf.setInt64(192, r.recvCounterInChain, Endian.big);
    buf.setInt64(200, r.recvChainIndex,     Endian.big);
    final key = SecureKey.fromList(_sodium, macKey);
    try {
      return Uint8List.fromList(_sodium.crypto.genericHash.call(
        outLen: 32,
        message: buf.buffer.asUint8List(),
        key: key,
      ));
    } finally {
      key.dispose();
    }
  }

  static bool _hmacEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
    return diff == 0;
  }

  Future<void> _saveSession(int contactId, RatchetState state) async {
    final existing = await _storage.sessions.forContact(contactId);
    final record = _stateToRecord(contactId, state, existingId: existing?.id);

    if (existing == null) {
      await _storage.sessions.insert(record);
    } else {
      await _storage.sessions.update(record);
    }
  }

  RatchetState _recordToState(SessionRecord r) {
    final myEphPriv = SecureKey.fromList(_sodium, r.myEphPriv);
    final state = RatchetState(
      rootKey: Uint8List.fromList(r.rootKey),
      sendChainKey: Uint8List.fromList(r.sendChainKey),
      recvChainKey: Uint8List.fromList(r.recvChainKey),
      myEphemeral: X25519KeyPair(
        publicKey: Uint8List.fromList(r.myEphPub),
        privateKey: myEphPriv,
      ),
      peerEphemeral: r.peerEphPub != null ? Uint8List.fromList(r.peerEphPub!) : null,
    )
      ..sendCounter = r.sendCounter
      ..recvCounter = r.recvCounter
      ..sendCounterSinceRatchet = r.sendSinceRatchet
      ..recvCounterInChain = r.recvCounterInChain
      ..recvChainIndex = r.recvChainIndex;

    // Restore skipped-key cache with persisted timestamps.
    final decoded = SkippedKeysCodec.decodeWithTimestamps(r.skippedKeysJson);
    state.skippedKeys.addAll(decoded.keys);
    state.skippedKeysCreatedAt.addAll(decoded.timestamps);

    return state;
  }

  SessionRecord _stateToRecord(
    int contactId,
    RatchetState state, {
    int? existingId,
  }) {
    final privBytes = state.myEphemeral.privateKey.extractBytes();
    final record = SessionRecord(
      id: existingId,
      contactId: contactId,
      rootKey: Uint8List.fromList(state.rootKey),
      sendChainKey: Uint8List.fromList(state.sendChainKey),
      recvChainKey: Uint8List.fromList(state.recvChainKey),
      myEphPub: Uint8List.fromList(state.myEphemeral.publicKey),
      myEphPriv: privBytes,
      peerEphPub: state.peerEphemeral != null
          ? Uint8List.fromList(state.peerEphemeral!)
          : null,
      sendCounter: state.sendCounter,
      recvCounter: state.recvCounter,
      sendSinceRatchet: state.sendCounterSinceRatchet,
      recvCounterInChain: state.recvCounterInChain,
      recvChainIndex: state.recvChainIndex,
      skippedKeysJson: SkippedKeysCodec.encode(state.skippedKeys, createdAt: state.skippedKeysCreatedAt),
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    privBytes.fillRange(0, privBytes.length, 0);
    return record;
  }

  /// Generate a random hex-8 message ID for delivery receipt correlation.
  static String _randomMid() {
    final rng = Random.secure();
    return List.generate(4, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Emit a status update (called by FileService after file transfer confirmed).
  void emitStatusUpdate(int dbId, MessageStatus status) {
    if (!_statusCtrl.isClosed) {
      _statusCtrl.add(StatusUpdate(messageId: dbId, status: status));
    }
  }

  static const _receiptMaxAttempts = 3;
  static const _receiptBaseDelayMs = 2000;

  /// Send a receipt envelope with retry + jitter. Returns true if sent.
  Future<bool> _sendReceiptWithRetry(String recipientPub58, Map<String, dynamic> payload) async {
    final send = onSendRawEnvelope;
    if (send == null) {
      AppLogger.w('Msg', 'receipt send skipped: onSendRawEnvelope not wired');
      return false;
    }
    for (int attempt = 1; attempt <= _receiptMaxAttempts; attempt++) {
      try {
        final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
        final env = await encryptBox(recipientPub58, plain);
        send(env);
        return true;
      } catch (e) {
        AppLogger.w('Msg', 'receipt ${payload['type']} attempt $attempt failed: $e');
        if (attempt < _receiptMaxAttempts) {
          // Exponential backoff with jitter to prevent thundering herd.
          final delayMs = _receiptBaseDelayMs * attempt + Random.secure().nextInt(1000);
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }
    AppLogger.e('Msg', 'receipt ${payload['type']} to ${recipientPub58.substring(0, 8)}… '
        'failed after $_receiptMaxAttempts attempts');
    return false;
  }

  /// Send a msg_delivered receipt to [recipientPub58] for message [mid].
  void _sendDeliveredReceipt(String recipientPub58, String mid) {
    _sendReceiptWithRetry(recipientPub58, {'type': 'msg_delivered', 'mid': mid})
        .then((sent) {
          if (!sent) AppLogger.w('Msg', 'msg_delivered receipt failed for mid=${mid.substring(0, 8)}…');
        })
        .catchError((Object e) {
          AppLogger.w('Msg', 'msg_delivered receipt error for mid=${mid.substring(0, 8)}…: $e');
        });
  }

  /// Send a msg_read receipt to [recipientPub58] for message [mid].
  void sendReadReceipt(String recipientPub58, String mid) {
    AppLogger.d('Msg', 'sendReadReceipt mid=${mid.substring(0, 8)}… to=${recipientPub58.substring(0, 8)}…');
    _sendReceiptWithRetry(recipientPub58, {'type': 'msg_read', 'mid': mid})
        .then((sent) {
          if (!sent) AppLogger.w('Msg', 'msg_read receipt failed for mid=${mid.substring(0, 8)}…');
        })
        .catchError((Object e) {
          AppLogger.w('Msg', 'msg_read receipt error for mid=${mid.substring(0, 8)}…: $e');
        });
  }

  void dispose() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
    if (!_statusCtrl.isClosed) _statusCtrl.close();
  }
}
