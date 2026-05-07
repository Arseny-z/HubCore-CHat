import 'dart:convert';
import 'dart:typed_data';

import '../application/events/app_event_bus.dart';
import '../application/events/app_events.dart';
import '../domain/entities/device_pairing_payload.dart';
import '../domain/entities/envelope.dart';
import '../infrastructure/crypto/device_pairing_crypto.dart';
import '../infrastructure/transport/composite_transport.dart';
import '../shared/utils/logger.dart';
import '../storage/dao/my_devices_dao.dart';
import '../storage/storage_service.dart';

class DevicePairingService {
  final StorageService _storage;
  final CompositeTransport _transport;
  final AppEventBus _bus;
  final String _myMasterPub58;
  final DevicePairingCrypto _crypto;

  /// Current own Yggdrasil pubkey hex — set by messaging providers after Yggdrasil starts.
  String myYggPubHex = '';

  /// Own master public key — used to validate incoming handshake device certs.
  Uint8List? myMasterPublicKey;

  /// Called after Device A confirms pairing — triggers broadcastHello.
  void Function()? onPairingComplete;

  /// Called after Device A confirms pairing — triggers profile_sync to Device B.
  Future<void> Function()? onSyncProfile;

  DevicePairingService({
    required StorageService storage,
    required CompositeTransport transport,
    required AppEventBus bus,
    required String myMasterPub58,
    required DevicePairingCrypto crypto,
  })  : _storage = storage,
        _transport = transport,
        _bus = bus,
        _myMasterPub58 = myMasterPub58,
        _crypto = crypto;

  // ── Device B: send handshake to Device A ────────────────────────────────

  /// Called on Device B right after [importFromPairing] succeeds.
  /// Sends [DevicePairingHandshake] to Device A (address taken from [qr]).
  Future<void> sendHandshake(PairingQrPayload qr, {String myYggPubHex = ''}) async {
    final myDevice = await _storage.myDevices.active().then(
        (list) => list.firstOrNull);
    if (myDevice == null) {
      AppLogger.w('Pairing', 'sendHandshake: no own device registered yet');
      return;
    }

    // Build our transport addresses using current ygg pubkey.
    final myAddrs = myYggPubHex.isNotEmpty
        ? {'yggdrasil': myYggPubHex}
        : myDevice.transportAddresses;

    // Update own device record with transport address so Device A can reach us.
    if (myYggPubHex.isNotEmpty && myDevice.transportAddresses.isEmpty) {
      await _storage.myDevices.upsert(MyDevice(
        id:                 myDevice.id,
        deviceId:           myDevice.deviceId,
        devicePubkey:       myDevice.devicePubkey,
        deviceCert:         myDevice.deviceCert,
        deviceOs:           myDevice.deviceOs,
        transportAddresses: myAddrs,
        registeredAt:       myDevice.registeredAt,
        isActive:           true,
        isMaster:           myDevice.isMaster,
      ));
    }

    final handshake = DevicePairingHandshake(
      deviceId:           myDevice.deviceId,
      devicePub:          myDevice.devicePubkey,
      deviceCert:         myDevice.deviceCert ?? Uint8List(0),
      yggPubHex:          myYggPubHex,
      transportAddresses: myAddrs,
    );

    final body = Uint8List.fromList(utf8.encode(jsonEncode(handshake.toJson())));
    final env  = Envelope(from: _myMasterPub58, to: _myMasterPub58, body: body);
    final addrs = qr.yggPubHex.isNotEmpty
        ? {'yggdrasil': qr.yggPubHex}
        : <String, String>{};

    try {
      await _transport.sendEnvelope(env, transportAddresses: addrs);
      AppLogger.d('Pairing', 'handshake sent to Device A ygg=${qr.yggPubHex.isNotEmpty ? qr.yggPubHex.substring(0, 8) : "?"}…');
    } catch (e) {
      AppLogger.w('Pairing', 'sendHandshake failed: $e');
    }
  }

  // ── Device A: receive handshake from Device B ────────────────────────────

  /// Called on Device A when a [device_pairing_handshake] arrives.
  /// Validates cert, saves Device B, sends ack, fires broadcastHello.
  Future<void> handleHandshake(
    Map<String, dynamic> json,
    Map<String, String> senderAddresses,
  ) async {
    final handshake = DevicePairingHandshake.tryFromJson(json);
    if (handshake == null) {
      AppLogger.w('Pairing', 'handleHandshake: malformed payload');
      return;
    }

    // Validate device cert — must be signed by our own master key.
    // masterPub is the same on all own devices (shared identity).
    final masterDevice = await _storage.myDevices.masterDevice();
    if (masterDevice == null) {
      AppLogger.w('Pairing', 'handleHandshake: no master device found');
      return;
    }

    final masterPub = myMasterPublicKey;
    if (masterPub != null) {
      if (!_crypto.validateHandshake(handshake, masterPub)) {
        AppLogger.w('Pairing',
            'handleHandshake REJECTED: invalid device cert from ${handshake.deviceId.substring(0, 8)}…');
        return;
      }
      AppLogger.d('Pairing', 'handshake cert verified for ${handshake.deviceId.substring(0, 8)}…');
    } else {
      AppLogger.w('Pairing', 'cert validation skipped — masterPub not set');
    }

    // Save Device B.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.myDevices.upsert(MyDevice(
      deviceId:           handshake.deviceId,
      devicePubkey:       handshake.devicePub,
      deviceCert:         handshake.deviceCert.isNotEmpty ? handshake.deviceCert : null,
      deviceOs:           'android',
      transportAddresses: handshake.transportAddresses.isNotEmpty
          ? handshake.transportAddresses
          : senderAddresses,
      registeredAt:       now,
      isActive:           true,
      isMaster:           false,
    ));
    AppLogger.d('Pairing',
        'Device B ${handshake.deviceId.substring(0, 8)}… saved');

    // Send ack back to Device B.
    await _sendAck(handshake, senderAddresses);

    // Broadcast hello so contacts learn about the new device.
    onPairingComplete?.call();
    // Push profile (alias + avatar) to Device B immediately after pairing.
    onSyncProfile?.call().catchError((_) {});
    _bus.emit(const DevicePairingCompleteEvent());
  }

  // ── Device B: receive ack from Device A ─────────────────────────────────

  /// Called on Device B when a [device_pairing_ack] arrives from Device A.
  Future<void> handleAck(Map<String, dynamic> json) async {
    final ack = DevicePairingAck.tryFromJson(json);
    if (ack == null) {
      AppLogger.w('Pairing', 'handleAck: malformed payload');
      return;
    }

    // Save Device A.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _storage.myDevices.upsert(MyDevice(
      deviceId:           ack.deviceIdA,
      devicePubkey:       ack.devicePubA,
      deviceCert:         ack.deviceCertA.isNotEmpty ? ack.deviceCertA : null,
      deviceOs:           'android',
      transportAddresses: ack.transportAddressesA,
      registeredAt:       now,
      isActive:           true,
      isMaster:           true, // Device A is the master device
    ));
    AppLogger.d('Pairing',
        'Device A ${ack.deviceIdA.substring(0, 8)}… saved — pairing complete');

    _bus.emit(const DevicePairingAckEvent());
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Future<void> _sendAck(
    DevicePairingHandshake handshake,
    Map<String, String> destAddresses,
  ) async {
    final myDevice = await _storage.myDevices.masterDevice();
    if (myDevice == null) return;

    // Include our current ygg pubkey so Device B can reach Device A later.
    final myAddrs = myYggPubHex.isNotEmpty
        ? {'yggdrasil': myYggPubHex}
        : myDevice.transportAddresses;

    final ack = DevicePairingAck(
      deviceIdA:           myDevice.deviceId,
      devicePubA:          myDevice.devicePubkey,
      deviceCertA:         myDevice.deviceCert ?? Uint8List(0),
      transportAddressesA: myAddrs,
    );

    final body = Uint8List.fromList(utf8.encode(jsonEncode(ack.toJson())));
    final env  = Envelope(from: _myMasterPub58, to: _myMasterPub58, body: body);
    final addrs = handshake.transportAddresses.isNotEmpty
        ? handshake.transportAddresses
        : destAddresses;

    try {
      await _transport.sendEnvelope(env, transportAddresses: addrs);
      AppLogger.d('Pairing', 'ack sent to Device B ${handshake.deviceId.substring(0, 8)}…');
    } catch (e) {
      AppLogger.w('Pairing', 'sendAck failed: $e');
    }
  }
}
