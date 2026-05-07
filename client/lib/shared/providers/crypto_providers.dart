import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/identity.dart';
import '../../infrastructure/keystore/keystore_service.dart';
import '../../storage/dao/my_devices_dao.dart';
import 'storage_providers.dart' show storageProvider;
import '../../infrastructure/crypto/double_ratchet_crypto_service.dart';
import '../../infrastructure/crypto/session_manager.dart';
import '../../infrastructure/crypto/messaging_service.dart';
import '../../infrastructure/crypto/multi_session_manager.dart';
import '../../shared/utils/logger.dart';
import 'messaging_providers.dart' show messageRouterProvider;
import '../../infrastructure/crypto/group_messaging_service.dart';
import '../../infrastructure/file_transfer/file_service.dart';
import '../../services/key_backup_service.dart';
import '../../application/events/app_event_bus.dart';
import '../../yggdrasil/yggdrasil_node.dart';
import '../utils/logger.dart';

import 'storage_providers.dart';

// ── Sodium ───────────────────────────────────────────────────────────────────

final sodiumProvider = FutureProvider<Sodium>((ref) => SodiumInit.init());

// ── Keystore ──────────────────────────────────────────────────────────────────

final keystoreProvider = Provider<KeystoreService>((ref) {
  final sodium = ref.watch(sodiumProvider).valueOrNull;
  if (sodium == null) throw StateError('Sodium not ready');
  return KeystoreService(sodium);
});

// ── Identity ──────────────────────────────────────────────────────────────────

final identityProvider = FutureProvider<Identity?>((ref) async {
  final sodium = await ref.watch(sodiumProvider.future);
  final keystore = KeystoreService(sodium);
  return keystore.loadIdentity();
});

final identityNotifierProvider =
    NotifierProvider<IdentityNotifier, Identity?>(IdentityNotifier.new);

class IdentityNotifier extends Notifier<Identity?> {
  @override
  Identity? build() => null;

  Future<void> generate(Sodium sodium) async {
    final identity = Identity.generate(sodium);
    final keystore = KeystoreService(sodium);
    await keystore.saveIdentity(identity);
    state = identity;
    await _registerDeviceIfOpen(identity);
  }

  /// Called on Device B after scanning the pairing QR and decrypting the bundle.
  Future<void> importFromPairing(Sodium sodium, Identity identity) async {
    final keystore = KeystoreService(sodium);
    await keystore.saveIdentity(identity);
    state = identity;
    await _registerDeviceIfOpen(identity);
  }

  Future<void> load(Sodium sodium) async {
    final keystore = KeystoreService(sodium);
    final identity = await keystore.loadIdentity();
    state = identity;
    if (identity != null) await _registerDeviceIfOpen(identity);
  }

  /// Register own device in my_devices table (idempotent).
  Future<void> _registerDeviceIfOpen(Identity identity) async {
    try {
      final storage = ref.read(storageProvider);
      if (!storage.isOpen) return;
      final existing = await storage.myDevices.findById(identity.deviceId);
      if (existing != null) {
        // Update heartbeat and transport addresses (may have changed)
        await storage.myDevices.updateHeartbeat(identity.deviceId);
        return;
      }
      // First time — insert as master device
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await storage.myDevices.upsert(MyDevice(
        deviceId: identity.deviceId,
        devicePubkey: identity.devicePublicKey,
        deviceCert: identity.deviceCert.encode(),
        deviceOs: 'android',
        registeredAt: now,
        isActive: true,
        isMaster: identity.isMasterDevice,
      ));
      // Save device keys (they may have been auto-generated on upgrade)
      final keystore = ref.read(keystoreProvider);
      await keystore.saveIdentity(identity);
      // Broadcast hello so contacts learn about this new device.
      // Use retry loop — router may not be ready yet.
      Future(() async {
        for (var i = 0; i < 20; i++) {
          await Future.delayed(const Duration(seconds: 3));
          try {
            final router = ref.read(messageRouterProvider);
            if (router != null) {
              await router.broadcastHello();
              AppLogger.d('Identity', 'broadcast hello after device registration');
              break;
            }
          } catch (_) {}
        }
      });
    } catch (_) { /* DB may not be open yet — called again after unlock */ }
  }

  Future<void> rotateSigningKey(Sodium sodium) async {
    final current = state;
    if (current == null) return;
    // Only master device performs rotation — others receive new cert via sync
    if (!current.isMasterDevice) {
      AppLogger.d('Identity', 'skipping signing key rotation — not master device');
      return;
    }
    final rotated = current.rotateSigningKey();
    final keystore = KeystoreService(sodium);
    await keystore.saveIdentity(rotated);
    state = rotated;
  }
}

// ── Yggdrasil peers ───────────────────────────────────────────────────────────

/// Settings key for user-added extra Yggdrasil peers (stored as JSON list).
const kExtraYggPeersKey = 'extra_ygg_peers';

/// Full peer list: built-in defaults + user-added extras.
/// Persisted in storage.settings under [kExtraYggPeersKey] (extras only).
final yggPeersProvider =
    StateNotifierProvider<YggPeersNotifier, List<String>>(
  (_) => YggPeersNotifier(),
);

class YggPeersNotifier extends StateNotifier<List<String>> {
  YggPeersNotifier() : super(List.unmodifiable(kYggdrasilDefaultPeers));

  void load(String? stored) {
    if (stored == null || stored.isEmpty) return;
    try {
      final extra = (jsonDecode(stored) as List).cast<String>();
      state = List.unmodifiable([...kYggdrasilDefaultPeers, ...extra]);
    } catch (e) {
      AppLogger.w('Peers', 'failed to parse stored extra peers', error: e);
    }
  }

  void add(String uri) {
    if (!state.contains(uri)) {
      state = List.unmodifiable([...state, uri]);
    }
  }

  void remove(String uri) {
    if (kYggdrasilDefaultPeers.contains(uri)) return;
    state = List.unmodifiable(state.where((p) => p != uri));
  }

  List<String> get extra =>
      state.where((p) => !kYggdrasilDefaultPeers.contains(p)).toList();
}

// ── Crypto infrastructure ─────────────────────────────────────────────────────

/// Multi-device session manager — per-device DR sessions (symmetric-only ratchet).
final multiSessionManagerProvider = Provider<MultiSessionManager?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  if (sodium == null || identity == null || !storage.isOpen) return null;
  return MultiSessionManager(
    sodium:   sodium,
    identity: identity,
    storage:  storage,
  );
});

/// Unified session manager — single source of truth for DR sessions.
final sessionManagerProvider = Provider<SessionManager?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  final lock     = ref.watch(lockManagerProvider);
  if (sodium == null || identity == null || !storage.isOpen) return null;
  return SessionManager(
    sodium:   sodium,
    identity: identity,
    contacts: storage.contactRepo,
    sessions: storage.sessionRepo,
    macKey:   lock?.sessionMacKey,
  );
});

final cryptoServiceProvider = Provider<DoubleRatchetCryptoService?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  final sm       = ref.watch(sessionManagerProvider);
  if (sodium == null || identity == null || !storage.isOpen || sm == null) return null;
  return DoubleRatchetCryptoService(
    sodium:         sodium,
    identity:       identity,
    contacts:       storage.contactRepo,
    sessionManager: sm,
  );
});

// ── File Service ──────────────────────────────────────────────────────────────

final fileServiceProvider = Provider<FileService?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  if (sodium == null || identity == null || !storage.isOpen) return null;
  final eventBus = ref.watch(eventBusProvider);
  final svc = FileService(
    sodium: sodium, identity: identity, storage: storage, eventBus: eventBus);
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Group Messaging ───────────────────────────────────────────────────────────

final groupMessagingProvider = Provider<GroupMessagingService?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  if (sodium == null || identity == null || !storage.isOpen) return null;
  final svc = GroupMessagingService(
    sodium:   sodium,
    identity: identity,
    storage:  storage,
  );
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Messaging ─────────────────────────────────────────────────────────────────

final messagingServiceProvider = Provider<MessagingService?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final identity = ref.watch(identityNotifierProvider);
  final storage  = ref.watch(storageProvider);
  final lock     = ref.watch(lockManagerProvider);
  if (sodium == null || identity == null || !storage.isOpen) return null;
  final svc = MessagingService(
    sodium:   sodium,
    identity: identity,
    storage:  storage,
  );
  svc.setMacKey(lock?.sessionMacKey);
  svc.fileService = ref.read(fileServiceProvider);
  final bus = ref.read(eventBusProvider);
  ref.read(fileServiceProvider)?.onStatusUpdate = (id, status) =>
      bus.emit(MessageStatusUpdatedEvent(messageDbId: id, status: status));
  ref.onDispose(svc.dispose);
  return svc;
});

// ── Key Backup ────────────────────────────────────────────────────────────────

final keyBackupProvider = Provider<KeyBackupService?>((ref) {
  final sodium   = ref.watch(sodiumProvider).valueOrNull;
  final keystore = ref.watch(keystoreProvider);
  if (sodium == null) return null;
  return KeyBackupService(sodium, keystore);
});
