import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/events/app_event_bus.dart';
import '../../shared/utils/logger.dart';
import '../../yggdrasil/yggdrasil_node.dart';
import 'crypto_providers.dart' show yggPeersProvider;
import 'storage_providers.dart';
import 'transport_providers.dart';
import 'messaging_providers.dart';

const _connectivityChannel = MethodChannel('hubcore/connectivity');

/// Exposes [start] and [stop] for the Yggdrasil foreground service.
///
/// Used by [MainScreen] on app launch and by [SettingsScreen] when the user
/// toggles the Yggdrasil switch on/off.
final yggdrasilControllerProvider = Provider<YggdrasilController>((ref) {
  return YggdrasilController(ref);
});

class YggdrasilController {
  final Ref _ref;
  YggdrasilController(this._ref);

  /// Start the Yggdrasil node and wait for it to be ready.
  /// No-op if already running.
  Future<void> start() async {
    try {
      final storage = _ref.read(storageProvider);
      if (!storage.isOpen) return;

      final privKeyHex = await storage.settings.get('ygg_privkey') ?? '';

      final successfulJson = await storage.settings.get('ygg_successful_peers');
      final successfulPeers = <String>[];
      if (successfulJson != null && successfulJson.isNotEmpty) {
        try {
          successfulPeers
              .addAll((jsonDecode(successfulJson) as List).cast<String>());
        } catch (_) {}
      }
      final allPeers = _ref.read(yggPeersProvider);
      final orderedPeers = <String>[
        ...successfulPeers.where(allPeers.contains),
        ...allPeers.where((p) => !successfulPeers.contains(p)),
      ];

      List<String> activePeers = orderedPeers;
      try {
        final networkType =
            await _connectivityChannel.invokeMethod<String>('getNetworkType') ??
                'other';
        if (networkType == 'mobile' || networkType == 'vpn') {
          final preferred = orderedPeers
              .where((p) => p.contains(':443') || p.startsWith('quic://'))
              .toList();
          final rest = orderedPeers
              .where(
                  (p) => !p.contains(':443') && !p.startsWith('quic://'))
              .toList();
          activePeers = [...preferred, ...rest];
        }
      } catch (_) {}

      String allowedPubKeysJson = '';
      final allowedEnabled =
          await storage.settings.get('ygg_allowed_pubkeys_enabled') ?? '';
      if (allowedEnabled == 'true') {
        allowedPubKeysJson =
            await storage.settings.get('ygg_allowed_pubkeys') ?? '[]';
      }

      await YggdrasilNode.start(
        privKeyHex: privKeyHex,
        peers: activePeers,
        allowedPubKeysJson: allowedPubKeysJson,
      );
      await Future.delayed(const Duration(seconds: 3));

      if (privKeyHex.isEmpty) {
        final generatedKey = await YggdrasilNode.privateKey();
        if (generatedKey != null && generatedKey.isNotEmpty) {
          await storage.settings.set('ygg_privkey', generatedKey);
        }
      }

      String? yggAddr;
      for (int i = 0; i < 10; i++) {
        yggAddr = await YggdrasilNode.address();
        if (yggAddr != null && yggAddr.isNotEmpty) break;
        await Future.delayed(const Duration(seconds: 3));
      }

      final yggPub = await YggdrasilNode.publicKey();
      if (yggPub != null && yggPub.isNotEmpty) {
        _ref.read(yggPubKeyProvider.notifier).state = yggPub;

        _ref.read(sweepExpiredProvider);
        _ref.read(queueServiceProvider);

        var router = _ref.read(messageRouterProvider);
        for (int i = 0; router == null && i < 15; i++) {
          await Future.delayed(const Duration(seconds: 1));
          router = _ref.read(messageRouterProvider);
        }
        if (router != null) {
          await router.setYggPubKey(yggPub);
        } else {
          AppLogger.w('Ygg', 'messageRouter not ready after 15s — hello broadcast skipped');
        }
      }

      if (yggAddr != null && yggAddr.isNotEmpty) {
        AppLogger.d('Ygg', 'started · address: $yggAddr');
      } else {
        AppLogger.w('Ygg', 'address not available after 30s');
      }

      // Request sync from own devices once Yggdrasil address is confirmed.
      // Poll instead of fixed delay — Yggdrasil may be slow on some networks.
      Future(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(seconds: 5));
          try {
            final addr = await YggdrasilNode.address();
            if (addr != null && addr.isNotEmpty) {
              await _ref.read(deviceSyncServiceProvider)?.requestSyncFromAll();
              AppLogger.d('Ygg', 'device sync requested (Yggdrasil ready)');
              return;
            }
          } catch (_) {}
        }
        AppLogger.w('Ygg', 'device sync skipped — Yggdrasil not ready after 90s');
      }).catchError((_) {});

      // Save successful peers for next launch.
      Future.delayed(const Duration(seconds: 15), () async {
        try {
          final storage = _ref.read(storageProvider);
          final peers = await YggdrasilNode.peers();
          final up = peers.where((p) => p.up).map((p) => p.uri).toList();
          if (up.isNotEmpty && storage.isOpen) {
            await storage.settings.set('ygg_successful_peers', jsonEncode(up));
          }
          final sorted = peers
              .where((p) => p.up && p.latencyMs > 0)
              .toList()
            ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
          final best = sorted.take(2).map((p) => p.uri).toList();
          if (best.isNotEmpty && storage.isOpen) {
            await storage.settings.set('ygg_best_peers', jsonEncode(best));
          }
        } catch (e) {
          AppLogger.w('Ygg', 'peer save failed', error: e);
        }
      });
    } catch (e) {
      AppLogger.e('Ygg', 'start failed', error: e);
      _ref.read(eventBusProvider).emit(ErrorEvent(
        source: 'Ygg',
        code: ErrorEventCode.yggdrasilStartFailed,
        details: e.toString(),
        severity: ErrorSeverity.critical,
      ));
    }
  }

  /// Stop the Yggdrasil node and clear the pubkey state.
  Future<void> stop() async {
    try {
      await YggdrasilNode.stop();
      _ref.read(yggPubKeyProvider.notifier).state = '';
      AppLogger.d('Ygg', 'stopped by user');
    } catch (e) {
      AppLogger.w('Ygg', 'stop failed', error: e);
    }
  }
}
