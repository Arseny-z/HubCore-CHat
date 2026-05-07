import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/device_pairing_payload.dart';
import '../../storage/storage_service.dart';
import '../../storage/lock_manager.dart';
import '../../storage/wipe_service.dart';
import '../../application/events/app_event_bus.dart';

import 'crypto_providers.dart' show sodiumProvider, keystoreProvider;

// ── Storage ───────────────────────────────────────────────────────────────────

final storageProvider = Provider<StorageService>((_) => StorageService());

// ── Event Bus ─────────────────────────────────────────────────────────────────

final eventBusProvider = Provider<AppEventBus>((ref) {
  final bus = AppEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

// ── Lock ──────────────────────────────────────────────────────────────────────

final lockManagerProvider = Provider<LockManager?>((ref) {
  final sodium = ref.watch(sodiumProvider).valueOrNull;
  if (sodium == null) return null;
  final storage = ref.watch(storageProvider);
  return LockManager(sodium, storage);
});

// ── Wipe ──────────────────────────────────────────────────────────────────────

final wipeServiceProvider = Provider<WipeService>((ref) {
  final keystore = ref.watch(keystoreProvider);
  final storage  = ref.watch(storageProvider);
  return WipeService(keystore, storage);
});

// ── Pending pairing profile (held in memory until DB opens after PIN setup) ──

/// Alias data from a pairing QR scan, waiting to be persisted after DB opens.
class PendingPairingProfile {
  final String myAlias;
  final String myPublicAlias;
  const PendingPairingProfile({required this.myAlias, required this.myPublicAlias});
}

final pendingPairingProfileProvider =
    StateProvider<PendingPairingProfile?>((ref) => null);

/// QR payload from a pairing scan, waiting to be sent as handshake after DB opens.
final pendingPairingQrProvider =
    StateProvider<PairingQrPayload?>((ref) => null);

// ── Notification badge count ─────────────────────────────────────────────────

final pendingNotificationCountProvider = StreamProvider<int>((ref) async* {
  final storage = ref.watch(storageProvider);
  while (true) {
    if (storage.isOpen) {
      yield await storage.notifications.pendingCount();
    } else {
      yield 0;
    }
    await Future.delayed(const Duration(seconds: 3));
  }
});
