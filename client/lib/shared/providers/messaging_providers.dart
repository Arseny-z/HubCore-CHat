import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/events/app_event_bus.dart';
import '../../application/events/app_events.dart';
import '../../application/use_cases/contacts/send_contact_hello_use_case.dart';
import '../../application/use_cases/messaging/process_receipt_use_case.dart';
import '../../application/use_cases/messaging/receive_envelope_use_case.dart';
import '../../application/use_cases/messaging/ensure_session_use_case.dart';
import '../../application/use_cases/messaging/sweep_expired_use_case.dart';
import '../../network/message_router.dart';
import '../../services/queue_service.dart';
import '../../services/device_sync_service.dart';
import '../../services/device_pairing_service.dart';
import '../../infrastructure/crypto/device_pairing_crypto.dart';
import '../../shared/utils/logger.dart';
import '../../shared/utils/pubkey_codec.dart';

import 'crypto_providers.dart'
    show
        identityNotifierProvider,
        messagingServiceProvider,
        groupMessagingProvider,
        fileServiceProvider,
        cryptoServiceProvider,
        sessionManagerProvider,
        multiSessionManagerProvider,
        sodiumProvider;
import '../../storage/dao/notifications_dao.dart';
import 'storage_providers.dart'
    show storageProvider, eventBusProvider, pendingPairingQrProvider;
import 'transport_providers.dart'
    show compositeTransportProvider, connectivityWatcherProvider, yggPubKeyProvider;

// ── Messaging Use Cases ───────────────────────────────────────────────────────

final receiveEnvelopeUseCaseProvider = Provider<ReceiveEnvelopeUseCase?>((ref) {
  final crypto         = ref.watch(cryptoServiceProvider);
  final storage        = ref.watch(storageProvider);
  final bus            = ref.read(eventBusProvider);
  final messaging      = ref.watch(messagingServiceProvider);
  final groupMessaging = ref.watch(groupMessagingProvider);
  final identity       = ref.watch(identityNotifierProvider);
  if (crypto == null || !storage.isOpen || messaging == null || identity == null) return null;

  final myPub58 = PubkeyCodec.encode(identity.masterPublicKey);
  final fileSvc = ref.watch(fileServiceProvider);

  return ReceiveEnvelopeUseCase(
    crypto:   crypto,
    contacts: storage.contactRepo,
    messages: storage.messageRepo,
    bus:      bus,
    myPub58:  myPub58,
    readTtl:  (convId) async {
      final v = await storage.settings.get('ttl_seconds:$convId');
      return v != null ? int.tryParse(v) : null;
    },
    onSendRaw:      (env) => messaging.onSendRawEnvelope?.call(env),
    onContactHello: (pub, json) => messaging.handleContactHelloJson(pub, json),
    onCertUpdate:   (pub, json) => messaging.handleCertUpdateJson(pub, json),
    onFileOffer: fileSvc == null ? null : (senderPub, yggKey, offer) =>
        fileSvc.handleFileOffer(senderPub, yggKey, offer),
    onFileChunk: fileSvc == null ? null : (senderPub, chunk) =>
        fileSvc.handleIncomingChunk(
          senderPub,
          chunk,
          myPub58,
          (env) async => messaging.onSendRawEnvelope?.call(env),
        ),
    onFileAck: fileSvc == null ? null : (ack) => fileSvc.injectAck(ack),
    onFileCancel: fileSvc == null ? null : (tid) => fileSvc.injectCancel(tid),
    onGroupMessage: groupMessaging == null ? null : (env) =>
        groupMessaging.receiveGroupEnvelope(env),
    onGroupInvite: groupMessaging == null ? null : (invite) =>
        groupMessaging.acceptInvite(invite),
    onImportMemberChain: groupMessaging == null ? null :
        (groupId, memberPub, chainBlob) =>
            groupMessaging.importMemberChain(groupId, memberPub, chainBlob),
    onGroupRename: !storage.isOpen ? null :
        (groupId, newName) => storage.groups.renameGroup(groupId, newName),
    onGroupRemoveMember: !storage.isOpen ? null :
        (groupId, pub) => groupMessaging != null
            ? groupMessaging.evictMemberChain(groupId, pub)
            : storage.groups.removeMember(groupId, pub),
    onGroupDelete: !storage.isOpen ? null :
        (groupId) => storage.groups.deleteGroup(groupId),
    onSetGroupAdmin: !storage.isOpen ? null :
        (groupId, newAdminPub) => storage.groups.setAdmin(groupId, newAdminPub),
    onSetMemberRole: !storage.isOpen ? null :
        (groupId, pub, role) => storage.groups.setMemberRole(groupId, pub, role),
    onGetMemberRole: !storage.isOpen ? null :
        (groupId, pub) => storage.groups.memberRole(groupId, pub),
    onGetAdminCount: !storage.isOpen ? null :
        (groupId) => storage.groups.adminCount(groupId),
    onGetOwnerPub: !storage.isOpen ? null :
        (groupId) => storage.groups.ownerPub(groupId),
    onSaveNotification: (type, payload, fromPub) async {
      if (!storage.isOpen) return;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await storage.notifications.insert(AppNotification(
        type: type,
        payload: payload,
        fromPub: fromPub,
        createdAt: now,
      ));
    },
    processReceipt: ProcessReceiptUseCase(
      messages: storage.messageRepo,
      receipts: storage.messageReceipts,
      queue: storage.sendQueue,
      bus: bus,
    ),
    getGroupAdmin: !storage.isOpen ? null : (groupId) => storage.groups.adminPub(groupId),
    multiSessionManager: ref.read(multiSessionManagerProvider),
    onReceiveMultiDevice: (env, payload) {
      final multiSvc = ref.read(multiSessionManagerProvider);
      if (multiSvc == null) return Future.value(null);
      return messaging.receiveEnvelopeMultiDevice(env, payload, multiSvc);
    },
    onDeviceSyncRequest: (deviceId, addrs, sinceTs) async {
      final svc = ref.read(deviceSyncServiceProvider);
      await svc?.handleSyncRequest(deviceId, addrs, sinceTs);
    },
    onDeviceSyncResponse: (payloads) async {
      final svc = ref.read(deviceSyncServiceProvider);
      await svc?.handleSyncResponse(payloads);
    },
    onProfileSync: (json) async {
      final svc = ref.read(deviceSyncServiceProvider);
      await svc?.handleProfileSync(json);
      // broadcastHello() is triggered by ProfileSyncedEvent listener in messageRouterProvider.
    },
    onDevicePairingHandshake: (json, addrs) async {
      final svc = ref.read(devicePairingServiceProvider);
      await svc?.handleHandshake(json, addrs);
    },
    onDevicePairingAck: (json) async {
      final svc = ref.read(devicePairingServiceProvider);
      await svc?.handleAck(json);
    },
    onSendPublicHello: (senderPub, addrs) {
      // Send public profile hello back to stranger — fire and forget
      final helloUseCase = ref.read(sendContactHelloProvider);
      final yggPub = ref.read(yggPubKeyProvider);
      if (helloUseCase == null || yggPub.isEmpty) return;
      helloUseCase.execute(
        recipientMasterPub58: senderPub,
        myYggPubKeyHex: yggPub,
        destTransportAddresses: addrs.isNotEmpty ? addrs : null,
        publicProfile: true,
      ).catchError((e) =>
          AppLogger.w('ReceiveUC', 'public hello to $senderPub failed: $e'));
    },
  );
});

// ── Contact Use Cases ─────────────────────────────────────────────────────────

final sendContactHelloProvider = Provider<SendContactHelloUseCase?>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  final transport = ref.watch(compositeTransportProvider);
  final storage   = ref.watch(storageProvider);
  if (messaging == null) return null;
  return SendContactHelloUseCase(
    buildHello: messaging.buildContactHello,
    transport:  transport,
    storage:    storage,
  );
});

// ── Message Router ────────────────────────────────────────────────────────────

final messageRouterProvider = Provider<MessageRouter?>((ref) {
  final messaging      = ref.watch(messagingServiceProvider);
  final groupMessaging = ref.watch(groupMessagingProvider);
  final storage        = ref.watch(storageProvider);
  final identity       = ref.watch(identityNotifierProvider);
  if (messaging == null || identity == null) return null;

  messaging.groupMessaging = groupMessaging;

  // Wire group delivery receipts — sent as box-encrypted DM back to sender
  if (groupMessaging != null) {
    groupMessaging.onSendDeliveryReceipt = (recipientPub, mid) async {
      try {
        final plain = Uint8List.fromList(
          utf8.encode(jsonEncode({'type': 'msg_delivered', 'mid': mid})),
        );
        final env = await messaging.encryptBox(recipientPub, plain);
        messaging.onSendRawEnvelope?.call(env);
      } catch (_) {}
    };

    // Wire group file offers (received via Sender Keys) to FileService
    final fileSvc = ref.read(fileServiceProvider);
    if (fileSvc != null) {
      groupMessaging.onFileOffer = (senderPub, yggKey, offer) {
        fileSvc.handleFileOffer(senderPub, yggKey, offer);
      };
    }
  }

  // Key change notification — save to notifications DB
  final bus = ref.read(eventBusProvider);
  messaging.onKeyChange = (contactPub, newEpoch) async {
    bus.emit(ContactKeyChangeEvent(contactPub: contactPub, newEpoch: newEpoch));
    if (storage.isOpen) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await storage.notifications.insert(AppNotification(
        type: 'key_change',
        payload: '{"pub":"$contactPub","epoch":$newEpoch}',
        fromPub: contactPub,
        createdAt: now,
      ));
    }
  };

  final transport      = ref.watch(compositeTransportProvider);
  final receiveUseCase = ref.watch(receiveEnvelopeUseCaseProvider);
  final watcher        = ref.watch(connectivityWatcherProvider);
  final router = MessageRouter(
    onIncoming: (env) async {
      if (receiveUseCase != null) return receiveUseCase.execute(env);
      return messaging.receiveEnvelope(env);
    },
    buildContactHello: ({
      required String recipientMasterPub58,
      required String myYggPubKeyHex,
      String? myReticulumAddress,
      String? myName,
      String? myAvatar,
      List<Map<String, dynamic>>? myDevices,
      int devicesVersion = 0,
    }) => messaging.buildContactHello(
      recipientMasterPub58: recipientMasterPub58,
      myYggPubKeyHex: myYggPubKeyHex,
      myReticulumAddress: myReticulumAddress,
      myName: myName,
      myAvatar: myAvatar,
      myDevices: myDevices,
      devicesVersion: devicesVersion,
    ),
    setOnContactHelloReply: (cb) => messaging.onContactHelloReply = cb,
    setOnSendRawEnvelope:   (cb) => messaging.onSendRawEnvelope   = cb,
    storage:   storage,
    transport: transport,
  );
  receiveUseCase?.onSessionDesync = (senderPub) => router.sendHelloTo(senderPub);
  receiveUseCase?.onContactHelloReply = (senderPub) => router.sendHelloTo(senderPub);
  messaging.onDesyncDetected = (senderPub) => router.sendHelloTo(senderPub);
  // Wire pairing callbacks here to avoid provider cycle.
  final pairingSvc = ref.read(devicePairingServiceProvider);
  pairingSvc?.onPairingComplete = () => router.broadcastHello();
  pairingSvc?.onSyncProfile = () async {
    await ref.read(deviceSyncServiceProvider)?.syncProfile();
  };
  // Keep pairing service's ygg pubkey in sync so ack includes correct address.
  pairingSvc?.myYggPubHex = ref.read(yggPubKeyProvider);
  // Provide masterPub for cert validation of incoming handshakes.
  pairingSvc?.myMasterPublicKey = identity.masterPublicKey;
  // After profile_sync applied on this device, re-broadcast to contacts.
  bus.on<ProfileSyncedEvent>().listen((_) => router.broadcastHello());
  router.start();

  // Send pending pairing handshake if Device B scanned a QR before DB was open.
  // Clear pendingQr BEFORE sending to prevent double-send on provider rebuild.
  final pendingQr = ref.read(pendingPairingQrProvider);
  if (pendingQr != null) {
    ref.read(pendingPairingQrProvider.notifier).state = null;
    Future(() async {
      final svc = ref.read(devicePairingServiceProvider);
      if (svc != null) {
        final myYggPub = ref.read(yggPubKeyProvider);
        await svc.sendHandshake(pendingQr, myYggPubHex: myYggPub);
      }
    });
  }

  // Re-broadcast hello to all contacts whenever peers appear (0→N transition).
  // This handles the race where contact_hello was sent before the remote node
  // connected to the Yggdrasil network.
  void broadcastIfReady() {
    final yggPub = ref.read(yggPubKeyProvider);
    if (yggPub.isNotEmpty) router.setYggPubKey(yggPub);
  }
  final removePeersCb = watcher.addOnPeersAppeared(broadcastIfReady);
  // If peers are already connected when the router is created (e.g. PIN entered
  // after Yggdrasil had already connected), fire immediately.
  if (watcher.hasConnectivity) broadcastIfReady();

  ref.onDispose(() {
    removePeersCb();
    router.dispose();
  });
  return router;
});

// ── TTL Sweep ─────────────────────────────────────────────────────────────────

final sweepExpiredProvider = Provider<SweepExpiredUseCase?>((ref) {
  final crypto    = ref.watch(cryptoServiceProvider);
  final storage   = ref.watch(storageProvider);
  final transport = ref.watch(compositeTransportProvider);
  final bus       = ref.read(eventBusProvider);
  if (crypto == null || !storage.isOpen) return null;

  final svc = SweepExpiredUseCase(
    messages:       storage.messageRepo,
    files:          storage.fileRepo,
    contacts:       storage.contactRepo,
    crypto:         crypto,
    transport:      transport,
    bus:            bus,
    ephemeralKeys:  storage.ephemeralKeys,
  );
  svc.start();
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Ensure Session ────────────────────────────────────────────────────────────

final ensureSessionProvider = Provider<EnsureSessionUseCase?>((ref) {
  final sm      = ref.watch(sessionManagerProvider);
  final storage = ref.watch(storageProvider);
  if (sm == null || !storage.isOpen) return null;
  return EnsureSessionUseCase(
    sessionManager: sm,
    contacts: storage.contactRepo,
  );
});

// ── Queue Service ─────────────────────────────────────────────────────────────

final queueServiceProvider = Provider<QueueService?>((ref) {
  final messaging  = ref.watch(messagingServiceProvider);
  final storage    = ref.watch(storageProvider);
  final transport  = ref.watch(compositeTransportProvider);
  final watcher    = ref.watch(connectivityWatcherProvider);
  if (messaging == null || !storage.isOpen) return null;

  final bus = ref.watch(eventBusProvider);
  final svc = QueueService(
    storage:      storage,
    messaging:    messaging,
    transport:    transport,
    connectivity: watcher,
    bus:          bus,
  );
  svc.multiSessions = ref.read(multiSessionManagerProvider);
  svc.start();
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Device Sync Service ───────────────────────────────────────────────────────

final deviceSyncServiceProvider = Provider<DeviceSyncService?>((ref) {
  final messaging     = ref.watch(messagingServiceProvider);
  final storage       = ref.watch(storageProvider);
  final transport     = ref.watch(compositeTransportProvider);
  final multiSessions = ref.watch(multiSessionManagerProvider);
  if (messaging == null || !storage.isOpen || multiSessions == null) return null;
  final bus = ref.read(eventBusProvider);
  return DeviceSyncService(
    storage:      storage,
    messaging:    messaging,
    multiSessions: multiSessions,
    transport:    transport,
    bus:          bus,
  );
});

final devicePairingServiceProvider = Provider<DevicePairingService?>((ref) {
  final messaging = ref.watch(messagingServiceProvider);
  final storage   = ref.watch(storageProvider);
  final transport = ref.watch(compositeTransportProvider);
  final identity  = ref.watch(identityNotifierProvider);
  if (messaging == null || !storage.isOpen || identity == null) return null;

  final sodium  = ref.read(sodiumProvider).valueOrNull;
  if (sodium == null) return null;
  final bus     = ref.read(eventBusProvider);
  final myPub58 = PubkeyCodec.encode(identity.masterPublicKey);

  return DevicePairingService(
    storage:       storage,
    transport:     transport,
    bus:           bus,
    myMasterPub58: myPub58,
    crypto:        DevicePairingCrypto(sodium),
  );
  // onPairingComplete is wired in messageRouterProvider to avoid a
  // provider dependency cycle (pairingService ↔ messageRouter).
});
