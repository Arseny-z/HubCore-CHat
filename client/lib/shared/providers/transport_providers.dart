import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/transport_port.dart';
import '../../infrastructure/transport/composite_transport.dart';
import '../../yggdrasil/yggdrasil_node.dart';
import '../../infrastructure/transport/yggdrasil_transport.dart';
import '../../infrastructure/transport/reticulum_transport.dart';
import '../../infrastructure/transport/meshcore_transport.dart';
import '../../infrastructure/transport/polling_service.dart';
import '../../infrastructure/connectivity/connectivity_watcher.dart';
import '../../shared/utils/logger.dart';

// ── Yggdrasil pub key ─────────────────────────────────────────────────────────

/// Our own Yggdrasil Ed25519 public key (hex). Set after node starts.
final yggPubKeyProvider = StateProvider<String>((_) => '');

// ── Transport enable/disable ──────────────────────────────────────────────────

final disabledTransportsProvider =
    StateNotifierProvider<DisabledTransportsNotifier, Set<String>>(
  (_) => DisabledTransportsNotifier(),
);

class DisabledTransportsNotifier extends StateNotifier<Set<String>> {
  DisabledTransportsNotifier() : super(const {});

  void load(String? stored) {
    if (stored == null || stored.isEmpty) return;
    try {
      final list = (jsonDecode(stored) as List).cast<String>();
      state = Set.unmodifiable(list.toSet());
    } catch (e) {
      AppLogger.w('Transport', 'failed to parse disabled transports setting', error: e);
    }
  }

  void toggle(String protocolId) {
    final next = {...state};
    if (next.contains(protocolId)) {
      next.remove(protocolId);
    } else {
      next.add(protocolId);
    }
    state = Set.unmodifiable(next);
  }

  bool isEnabled(String protocolId) => !state.contains(protocolId);
}

// ── Composite Transport ───────────────────────────────────────────────────────

final compositeTransportProvider = Provider<CompositeTransport>((ref) {
  final disabled = ref.watch(disabledTransportsProvider);
  bool enabled(String id) => !disabled.contains(id);

  final transport = CompositeTransport([
    if (enabled(TransportProtocol.yggdrasil)) YggdrasilTransport(),
    if (enabled(TransportProtocol.reticulum)) ReticulumTransport(),
    if (enabled(TransportProtocol.meshcore))  MeshcoreTransport(),
  ]);
  ref.onDispose(transport.dispose);
  return transport;
});

// ── Connectivity Watcher ──────────────────────────────────────────────────────

final connectivityWatcherProvider = Provider<ConnectivityWatcher>((ref) {
  final watcher = ConnectivityWatcher();
  watcher.start();
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Live peer count stream — emits whenever ConnectivityWatcher polls Yggdrasil.
/// Initial value is -1 (unknown) until first poll completes.
final peerCountProvider = StreamProvider<int>((ref) {
  final watcher = ref.watch(connectivityWatcherProvider);
  return watcher.peerCount;
});

/// Status for each transport protocol.
class TransportStatus {
  /// null = not implemented / disabled; -1 = connecting; N>=0 = peers
  final int? yggdrasil;
  final int? reticulum;
  final int? meshcore;

  const TransportStatus({
    this.yggdrasil,
    this.reticulum,
    this.meshcore,
  });
}

final transportStatusProvider = StreamProvider<TransportStatus>((ref) {
  final watcher = ref.watch(connectivityWatcherProvider);
  return watcher.peerCount.map((yggCount) => TransportStatus(
    yggdrasil: yggCount,
    reticulum: watcher.isReticulumUp ? watcher.rnsInterfaceCount : 0,
    meshcore:  null,
  ));
});

/// True once the Yggdrasil routing tree has more than 1 entry (routing works).
/// Polls every 3 seconds until ready, then stops. Used to show loading screen.
final yggTreeReadyProvider = StateNotifierProvider<_YggTreeReadyNotifier, bool>(
  (_) => _YggTreeReadyNotifier(),
);

class _YggTreeReadyNotifier extends StateNotifier<bool> {
  _YggTreeReadyNotifier() : super(false) {
    _poll();
  }

  Future<void> _poll() async {
    while (!state) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final tree = await YggdrasilNode.tree();
        if (tree.length > 1) {
          state = true;
          return;
        }
      } catch (_) {}
    }
  }
}

// ── Polling interval (kept for lock_screen compat) ────────────────────────────

final pollingIntervalProvider =
    StateProvider<PollingInterval>((_) => PollingInterval.disabled);
