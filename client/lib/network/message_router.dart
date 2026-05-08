import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/ports/transport_port.dart';
import '../infrastructure/notifications/notification_service.dart';
import '../infrastructure/transport/composite_transport.dart';
import '../shared/services/avatar_service.dart';
import '../shared/utils/logger.dart';
import '../storage/storage_service.dart';
import '../yggdrasil/yggdrasil_node.dart';
import '../domain/entities/envelope.dart';

/// Routes all incoming P2P envelopes from any transport.
///
/// Pure infrastructure class — knows nothing about application or services.
/// All domain logic is delegated via callbacks supplied at construction time.
class MessageRouter {
  /// Called for every incoming envelope. Returns plaintext if a notification
  /// should be shown, null otherwise.
  final Future<String?> Function(Envelope) onIncoming;

  /// Builds a contact_hello envelope for [recipientMasterPub58] including
  /// our current Yggdrasil public key and device list.
  final Envelope Function({
    required String recipientMasterPub58,
    required String myYggPubKeyHex,
    String? myReticulumAddress,
    String? myName,
    String? myAvatar,
    List<Map<String, dynamic>>? myDevices,
    int devicesVersion,
  }) buildContactHello;

  /// Registers the callback that should fire when the peer sends a hello reply.
  /// Called once when [setYggPubKey] is invoked.
  final void Function(void Function(Envelope)) setOnContactHelloReply;

  /// Registers the raw-send callback on the messaging service.
  final void Function(void Function(Envelope)) setOnSendRawEnvelope;

  final StorageService? _storage;
  String _yggPubKey = '';
  String _reticulumAddress = '';

  /// Returns display name for [recipientMasterPub]:
  /// — contacts see 'my_alias' (personal name)
  /// — strangers/unknown see 'my_public_alias' (public name, may be null)
  Future<String?> _myNameFor(String? recipientMasterPub) async {
    final s = _storage;
    if (s == null || !s.isOpen) return null;
    final isContact = recipientMasterPub != null &&
        (await s.contacts.findByMasterPub(recipientMasterPub))?.isContact == true;
    if (isContact) {
      final v = await s.settings.get('my_alias');
      return (v != null && v.isNotEmpty) ? v : null;
    } else {
      // Strangers get ONLY explicitly set public alias — no fallback to private
      final v = await s.settings.get('my_public_alias');
      return (v != null && v.isNotEmpty) ? v : null;
    }
  }

  Future<String?> _myAvatarFor(String? recipientMasterPub) async {
    final s = _storage;
    final isContact = recipientMasterPub != null && s != null && s.isOpen &&
        (await s.contacts.findByMasterPub(recipientMasterPub))?.isContact == true;
    if (isContact) {
      // Contacts see private avatar — no fallback to public
      return AvatarService.instance.myAvatarBase64(publicProfile: false);
    } else {
      // Strangers get ONLY explicitly set public avatar — never the private one
      return AvatarService.instance.myAvatarBase64(publicProfile: true);
    }
  }

  /// Builds devices list for inclusion in contact_hello.
  /// Returns (devicesList, devicesVersion).
  Future<(List<Map<String, dynamic>>, int)> _myDevicesPayload() async {
    final s = _storage;
    if (s == null || !s.isOpen) return (<Map<String, dynamic>>[], 0);
    try {
      final devices = await s.myDevices.active();
      if (devices.isEmpty) return (<Map<String, dynamic>>[], 0);
      final version = devices.fold(0, (v, d) => d.registeredAt > v ? d.registeredAt : v);
      final list = devices.map((d) => <String, dynamic>{
        'device_id': d.deviceId,
        'device_pubkey': base64Encode(d.devicePubkey),
        if (d.deviceEphPub != null) 'device_eph_pub': base64Encode(d.deviceEphPub!),
        if (d.deviceCert != null) 'device_cert': base64Encode(d.deviceCert!),
        if (d.deviceOs.isNotEmpty) 'os': d.deviceOs,
        if (d.transportAddresses.isNotEmpty)
          'transport_addresses': d.transportAddresses,
        if (d.registeredAt > 0) 'registered_at': d.registeredAt,
      }).toList();
      return (list, version);
    } catch (_) {
      return (<Map<String, dynamic>>[], 0);
    }
  }
  final CompositeTransport? _transport;

  StreamSubscription<IncomingEnvelope>? _incomingSub;

  /// Per-sender processing queue: serialises message handling per sender
  /// to prevent Double Ratchet state corruption from parallel decryptions.
  final _senderQueue = <String, Future<void>>{};

  /// Rolling dedup cache: SHA-256 of envelope body → seen timestamp.
  /// Prevents the same encrypted blob from being processed twice when it
  /// arrives via multiple transports simultaneously.
  static const _dedupMaxSize = 256;
  static const _dedupTtlMs   = 60 * 1000; // 1 minute
  final _dedupCache = LinkedHashMap<String, int>();

  MessageRouter({
    required this.onIncoming,
    required this.buildContactHello,
    required this.setOnContactHelloReply,
    required this.setOnSendRawEnvelope,
    StorageService? storage,
    CompositeTransport? transport,
  })  : _storage = storage,
        _transport = transport {
    setOnSendRawEnvelope(_sendRawEnvelope);
  }

  /// Update ygg pubkey and broadcast hello to all contacts.
  Future<void> setYggPubKey(String yggPubKey) async {
    _yggPubKey = yggPubKey;
    setOnContactHelloReply(_sendHelloReply);
    await _broadcastHello();
    // Re-broadcast after routing converges (~60s) — the first broadcast is sent
    // before Yggdrasil's gossip routing has built paths to all contacts.
    Future.delayed(const Duration(seconds: 60), _broadcastHello)
        .catchError((Object e) => AppLogger.w('Router', 'delayed broadcastHello(60s) error: $e'));
    Future.delayed(const Duration(seconds: 180), _broadcastHello)
        .catchError((Object e) => AppLogger.w('Router', 'delayed broadcastHello(180s) error: $e'));
  }

  /// Broadcast contact_hello to all contacts immediately (e.g. after profile update).
  Future<void> broadcastHello() => _broadcastHello();

  /// Update our Reticulum destination hash — included in future hello broadcasts.
  void setReticulumAddress(String reticulumAddress) {
    _reticulumAddress = reticulumAddress;
  }

  Future<void> _broadcastHello() async {
    final storage = _storage;
    if (storage == null || !storage.isOpen) {
      return;
    }
    final contacts = await storage.contacts.all(relationship: 'contact');
    AppLogger.d('Router', 'broadcastHello to ${contacts.length} contact(s)');
    final (devList, devVer) = await _myDevicesPayload();
    for (final c in contacts) {
      AppLogger.d('Router', '→ ${c.masterPub.substring(0, 8)}… addrs=${c.transportAddresses.keys.join(",")}');
      final env = buildContactHello(
        recipientMasterPub58: c.masterPub,
        myYggPubKeyHex: _yggPubKey,
        myReticulumAddress: _reticulumAddress.isNotEmpty ? _reticulumAddress : null,
        myName: await _myNameFor(c.masterPub),
        myAvatar: await _myAvatarFor(c.masterPub),
        myDevices: devList.isNotEmpty ? devList : null,
        devicesVersion: devVer,
      );
      final result = await _transport?.sendEnvelope(
        env,
        transportAddresses: c.transportAddresses,
      );
      AppLogger.d('Router', 'broadcastHello result: ${result?.success == true ? "ok (${result?.protocol})" : result?.error ?? "no transport"}');
    }
  }

  void _sendRawEnvelope(Envelope env) {
    final storage = _storage;
    if (storage == null || !storage.isOpen) return;
    storage.contacts.findByMasterPub(env.to).then((contact) async {
      final result = await _transport?.sendEnvelope(
        env,
        transportAddresses: contact?.transportAddresses,
      );
      if (result != null && !result.success) {
        AppLogger.w('Router', 'sendRaw to ${env.to.substring(0, 8)}… failed: ${result.error}');
      }
    }).catchError((Object e) {
      AppLogger.w('Router', 'sendRaw to ${env.to.substring(0, 8)}… error: $e');
    });
  }

  void _sendHelloReply(Envelope env) {
    final storage = _storage;
    if (storage == null || !storage.isOpen) return;
    storage.contacts.findByMasterPub(env.to).then((contact) async {
      final (devList, devVer) = await _myDevicesPayload();
      final fullEnv = buildContactHello(
        recipientMasterPub58: env.to,
        myYggPubKeyHex: _yggPubKey,
        myReticulumAddress: _reticulumAddress.isNotEmpty ? _reticulumAddress : null,
        myName: await _myNameFor(env.to),
        myAvatar: await _myAvatarFor(env.to),
        myDevices: devList.isNotEmpty ? devList : null,
        devicesVersion: devVer,
      );
      final result = await _transport?.sendEnvelope(
        fullEnv,
        transportAddresses: contact?.transportAddresses,
      );
      if (result != null && !result.success) {
        AppLogger.w('Router', 'helloReply to ${env.to.substring(0, 8)}… failed: ${result.error}');
      }
    }).catchError((Object e) {
      AppLogger.w('Router', 'helloReply to ${env.to.substring(0, 8)}… error: $e');
    });
  }

  /// Start routing — listen for incoming messages from all transports.
  void start() {
    if (_transport == null) return;
    _incomingSub?.cancel();
    _incomingSub = _transport.incoming.listen(_handleIncomingEnvelope);
  }

  /// Returns a short hex key for dedup based on the raw payload hash.
  String _dedupKey(Uint8List data) =>
      sha256.convert(data).toString().substring(0, 16);

  bool _isDuplicate(Uint8List data) {
    final key = _dedupKey(data);
    final now = DateTime.now().millisecondsSinceEpoch;

    // Evict expired entries.
    _dedupCache.removeWhere((_, ts) => now - ts > _dedupTtlMs);
    // Evict oldest if over capacity.
    while (_dedupCache.length >= _dedupMaxSize) {
      _dedupCache.remove(_dedupCache.keys.first);
    }

    if (_dedupCache.containsKey(key)) return true;
    _dedupCache[key] = now;
    return false;
  }

  Future<void> _handleIncomingEnvelope(IncomingEnvelope incoming) async {
    try {
      final proto = incoming.from.protocol;
      final src = incoming.from.value.length > 8
          ? incoming.from.value.substring(0, 8)
          : incoming.from.value;

      if (_isDuplicate(incoming.data)) {
        AppLogger.d('Router', 'dedup: dropped duplicate ${incoming.data.length}b via $proto from $src…');
        // Still ack buffered duplicates so they don't clog the DB.
        if (incoming.rawBufId != null) {
          await YggdrasilNode.ackBuffered(
            [incoming.rawBufId!],
            transport: incoming.from.protocol,
          );
        }
        return;
      }

      AppLogger.d('Router', 'recv ${incoming.data.length}b via $proto from $src…');
      final json = jsonDecode(utf8.decode(incoming.data)) as Map<String, dynamic>;

      // Raw system packets from Kotlin (no envelope wrapper) — e.g. msg_received.
      // These arrive as {"type":"...","mid":"..."} without from/to/body fields.
      if (!json.containsKey('body')) {
        AppLogger.d('Router', 'raw system packet type=${json['type']} from $src…');
        final senderPub = await _yggHexToMasterPub(incoming.from.value);
        if (senderPub != null) {
          final fakeEnvelope = Envelope(from: senderPub, to: '', body: Uint8List.fromList(utf8.encode(jsonEncode(json))));
          await _serializedHandle(senderPub, fakeEnvelope);
        } else {
          AppLogger.w('Router', 'raw system packet: unknown ygg key $src, dropping');
        }
        if (incoming.rawBufId != null) {
          await YggdrasilNode.ackBuffered([incoming.rawBufId!], transport: incoming.from.protocol);
        }
        return;
      }

      final envelope = Envelope.fromJson(json);
      final envWithTransport = Envelope(
        from: envelope.from,
        to: envelope.to,
        body: envelope.body,
        transport: incoming.from.protocol,
      );
      // Serialize processing per-sender to preserve message order and
      // prevent Double Ratchet state corruption from concurrent decryptions.
      await _serializedHandle(envWithTransport.from, envWithTransport);
      // Ack disk-buffered packet — tells Kotlin to delete the row in IncomingRawDb.
      if (incoming.rawBufId != null) {
        await YggdrasilNode.ackBuffered(
          [incoming.rawBufId!],
          transport: incoming.from.protocol,
        );
      }
    } catch (e) {
      AppLogger.w('Router', 'recv parse error: $e');
      // Do NOT ack on failure — row stays in IncomingRawDb and will be retried
      // on next app start.
    }
  }

  /// Serialize envelope processing per sender — prevents DR state corruption
  /// when multiple messages from the same sender arrive simultaneously.
  Future<void> _serializedHandle(String senderKey, Envelope envelope) {
    final prev = _senderQueue[senderKey] ?? Future<void>.value();
    final next = prev.then((_) => _handleEnvelope(envelope)).catchError((e) {
      AppLogger.w('Router', 'serialized handle error for ${senderKey.substring(0, 8)}…: $e');
    });
    // Remove the entry once this future completes so the map doesn't grow
    // unboundedly when a sender sends many messages over a long session.
    next.whenComplete(() {
      if (_senderQueue[senderKey] == next) _senderQueue.remove(senderKey);
    });
    _senderQueue[senderKey] = next;
    return next;
  }

  Future<void> _handleEnvelope(Envelope envelope) async {
    final plaintext = await onIncoming(envelope);
    if (plaintext != null) {
      await _notify(envelope.from);
    }
  }

  /// Look up a contact's masterPub by their Yggdrasil hex pubkey.
  Future<String?> _yggHexToMasterPub(String yggHex) async {
    final storage = _storage;
    if (storage == null || !storage.isOpen) return null;
    final contact = await storage.contacts.findByYggPubKeyHex(yggHex);
    return contact?.masterPub;
  }

  Future<void> _notify(String senderPub) async {
    String label = senderPub.length > 8 ? senderPub.substring(0, 8) : senderPub;
    bool silent = false;
    final storage = _storage;
    if (storage != null && storage.isOpen) {
      final contact = await storage.contacts.findByMasterPub(senderPub);
      if (contact != null && contact.alias.isNotEmpty) {
        label = contact.alias;
      }
      if (contact?.muted == true) return;
      // Strangers get a silent notification (no sound/vibration)
      if (contact?.isStranger == true) silent = true;
    }
    await NotificationService().showMessage(senderLabel: label, silent: silent);
  }

  /// Rate limit for desync recovery hellos — one per contact per 30 seconds.
  static const _desyncCooldownMs = 30 * 1000;
  final _lastDesyncHello = <String, int>{};

  /// Send a contact_hello to [contactMasterPub] — used to reset a desync'd session.
  /// Rate-limited to prevent flooding when many broken messages arrive at once.
  Future<void> sendHelloTo(String contactMasterPub) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastDesyncHello[contactMasterPub] ?? 0;
    if (now - last < _desyncCooldownMs) {
      AppLogger.d('Router', 'desync hello to ${contactMasterPub.substring(0, 8)}… rate-limited');
      return;
    }
    _lastDesyncHello[contactMasterPub] = now;

    final storage = _storage;
    if (storage == null || !storage.isOpen) return;
    final contact = await storage.contacts.findByMasterPub(contactMasterPub);
    if (contact == null) return;
    final env = buildContactHello(
      recipientMasterPub58: contactMasterPub,
      myYggPubKeyHex: _yggPubKey,
      myReticulumAddress: _reticulumAddress.isNotEmpty ? _reticulumAddress : null,
      myName: await _myNameFor(contactMasterPub),
      myAvatar: await _myAvatarFor(contactMasterPub),
    );
    await _transport?.sendEnvelope(env, transportAddresses: contact.transportAddresses);
    AppLogger.d('Router', 'hello reply sent to ${contactMasterPub.substring(0, 8)}…');
  }

  void dispose() {
    _incomingSub?.cancel();
  }
}
