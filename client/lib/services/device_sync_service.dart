import 'dart:convert';
import 'dart:typed_data';

import '../application/events/app_event_bus.dart';
import '../application/events/app_events.dart';
import '../domain/entities/envelope.dart';
import '../infrastructure/crypto/messaging_service.dart';
import '../infrastructure/crypto/multi_device_payload_codec.dart';
import '../infrastructure/crypto/multi_session_manager.dart';
import '../infrastructure/transport/composite_transport.dart';
import '../shared/services/avatar_service.dart';
import '../shared/utils/logger.dart';
import '../storage/storage_service.dart';

/// Handles synchronisation of messages between own devices.
///
/// When device B comes online, it requests pending cross_device_inbox entries
/// from device A (which received messages while B was offline).
///
/// Wire types (sent as plain JSON NaCl-box to other own devices):
///   device_sync_request  { "type": "device_sync_request", "since_ts": int }
///   device_sync_response { "type": "device_sync_response",
///                          "payloads": [base64...] }
class DeviceSyncService {
  final StorageService _storage;
  final MessagingService _messaging;
  final MultiSessionManager _multiSessions;
  final CompositeTransport _transport;
  final AppEventBus _bus;

  DeviceSyncService({
    required StorageService storage,
    required MessagingService messaging,
    required MultiSessionManager multiSessions,
    required CompositeTransport transport,
    required AppEventBus bus,
  })  : _storage = storage,
        _messaging = messaging,
        _multiSessions = multiSessions,
        _transport = transport,
        _bus = bus;

  // ── Outgoing: request sync from other own devices ────────────────────────

  /// Called at app start. Sends device_sync_request to all own devices.
  Future<void> requestSyncFromAll() async {
    final myDevices = await _storage.myDevices.active();
    final myId = _messaging.myMasterPub58;
    final myDevId = await _myDeviceId();

    for (final d in myDevices) {
      // Skip self and devices with no known address
      if (d.deviceId == myDevId) continue;
      if (d.transportAddresses.isEmpty) continue;

      // Send plain JSON — no NaCl box needed (device sync is between own devices,
      // Yggdrasil provides transport-level encryption)
      final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'type':      'device_sync_request',
        'since_ts':  DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7 * 24 * 3600,
        'device_id': myDevId,
      })));
      try {
        final env = Envelope(
          from: myId,
          to:   myId, // own master pub as recipient
          body: payloadBytes,
        );
        await _transport.sendEnvelope(
          env,
          transportAddresses: d.transportAddresses,
        );
        AppLogger.d('DeviceSync',
            'sync request sent to ${d.deviceId.substring(0, 8)}…');
      } catch (e) {
        AppLogger.w('DeviceSync',
            'requestSync to ${d.deviceId.substring(0, 8)}… failed: $e');
      }
    }
  }

  // ── Incoming: respond to sync request ────────────────────────────────────

  /// Called when we receive a device_sync_request from another own device.
  Future<void> handleSyncRequest(
      String requesterDeviceId,
      Map<String, String> transportAddresses,
      int sinceTs) async {
    final pending = await _storage.crossDeviceInbox
        .pendingFor(requesterDeviceId);

    if (pending.isEmpty) return;

    // Bundle up to 20 payloads per response (avoid huge messages)
    const batchSize = 20;
    for (var i = 0; i < pending.length; i += batchSize) {
      final batch = pending.skip(i).take(batchSize).toList();
      final payloadsB64 = batch
          .map((e) => base64Encode(e.encryptedPayload))
          .toList();

      final response = jsonEncode({
        'type':     'device_sync_response',
        'payloads': payloadsB64,
      });
      try {
        final myId = _messaging.myMasterPub58;
        final env = Envelope(
          from: myId,
          to:   myId,
          body: Uint8List.fromList(utf8.encode(response)),
        );
        await _transport.sendEnvelope(env, transportAddresses: transportAddresses);
        AppLogger.d('DeviceSync',
            'sent ${batch.length} payloads to ${requesterDeviceId.substring(0, 8)}…');
      } catch (e) {
        AppLogger.w('DeviceSync', 'handleSyncRequest response failed: $e');
      }
    }
  }

  // ── Incoming: process sync response ──────────────────────────────────────

  /// Called when we receive a device_sync_response from another own device.
  Future<void> handleSyncResponse(List<String> payloadsB64) async {
    int processed = 0;
    for (final b64 in payloadsB64) {
      try {
        final bytes = base64Decode(b64);
        final mdPayload = MultiDevicePayload.tryDecode(bytes);
        if (mdPayload == null) continue;

        // Use senderMasterPub (not deviceId) for contact lookup
        final senderMasterPub = mdPayload.senderMasterPub;
        if (senderMasterPub.isEmpty) {
          AppLogger.w('DeviceSync', 'skipping payload: missing senderMasterPub');
          continue;
        }

        final syntheticEnv = Envelope(
          from: senderMasterPub,
          to:   _messaging.myMasterPub58,
          body: bytes,
        );

        final plain = await _messaging.receiveEnvelopeMultiDevice(
          syntheticEnv,
          mdPayload,
          _multiSessions,
        );
        if (plain != null) {
          _bus.emit(MessageReceivedEvent(
            conversationId: senderMasterPub,
            isGroup: false,
            senderPub: senderMasterPub,
          ));
          processed++;
        }
      } catch (e) {
        AppLogger.w('DeviceSync', 'handleSyncResponse error: $e');
      }
    }
    AppLogger.d('DeviceSync', 'processed $processed/${payloadsB64.length} synced messages');
  }

  // ── Profile sync ─────────────────────────────────────────────────────────

  /// Called when user changes alias or avatar on this device.
  /// Sends profile_sync to all other own devices so they update their local
  /// settings and re-broadcast contact_hello to contacts.
  Future<void> syncProfile() async {
    final myDevices = await _storage.myDevices.active();
    final myDevId   = await _myDeviceId();
    final myId      = _messaging.myMasterPub58;

    final myAlias       = await _storage.settings.get('my_alias') ?? '';
    final myPublicAlias = await _storage.settings.get('my_public_alias') ?? '';
    final myAvatar      = await AvatarService.instance.myAvatarBase64(publicProfile: false) ?? '';
    final myPublicAvatar= await AvatarService.instance.myAvatarBase64(publicProfile: true) ?? '';

    final payload = jsonEncode({
      'type':              'profile_sync',
      'my_alias':          myAlias,
      'my_public_alias':   myPublicAlias,
      'my_avatar':         myAvatar,
      'my_public_avatar':  myPublicAvatar,
    });

    for (final d in myDevices) {
      if (d.deviceId == myDevId) continue;
      if (d.transportAddresses.isEmpty) continue;

      try {
        final env = Envelope(
          from: myId,
          to:   myId,
          body: Uint8List.fromList(utf8.encode(payload)),
        );
        await _transport.sendEnvelope(env, transportAddresses: d.transportAddresses);
        AppLogger.d('DeviceSync', 'profile_sync sent to ${d.deviceId.substring(0, 8)}…');
      } catch (e) {
        AppLogger.w('DeviceSync', 'profile_sync to ${d.deviceId.substring(0, 8)}… failed: $e');
      }
    }
  }

  /// Called when a profile_sync arrives from another own device.
  /// Updates local settings and saves avatars. Caller should broadcastHello().
  Future<void> handleProfileSync(Map<String, dynamic> json) async {
    final alias       = json['my_alias']        as String? ?? '';
    final publicAlias = json['my_public_alias']  as String? ?? '';
    final avatar      = json['my_avatar']        as String? ?? '';
    final publicAvatar= json['my_public_avatar'] as String? ?? '';

    if (alias.isNotEmpty) {
      await _storage.settings.set('my_alias', alias);
    }
    if (publicAlias.isNotEmpty) {
      await _storage.settings.set('my_public_alias', publicAlias);
    }
    if (avatar.isNotEmpty) {
      try { await AvatarService.instance.saveMyFromBase64(avatar, publicProfile: false); }
      catch (e) { AppLogger.w('DeviceSync', 'profile_sync: save private avatar failed: $e'); }
    }
    if (publicAvatar.isNotEmpty) {
      try { await AvatarService.instance.saveMyFromBase64(publicAvatar, publicProfile: true); }
      catch (e) { AppLogger.w('DeviceSync', 'profile_sync: save public avatar failed: $e'); }
    }

    AppLogger.d('DeviceSync', 'profile_sync applied: alias="$alias" publicAlias="$publicAlias"');
    _bus.emit(const ProfileSyncedEvent());
  }

  // ── Evict expired inbox entries ──────────────────────────────────────────

  Future<void> evictExpired() =>
      _storage.crossDeviceInbox.evictExpired();

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<String> _myDeviceId() async {
    final devices = await _storage.myDevices.active();
    return devices.firstOrNull?.deviceId ?? '';
  }
}
