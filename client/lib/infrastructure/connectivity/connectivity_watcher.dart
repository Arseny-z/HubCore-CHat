import 'dart:async';

import '../../reticulum/reticulum_node.dart';
import '../../yggdrasil/yggdrasil_node.dart';

/// Monitors connectivity across all transports by polling periodically.
///
/// Emits [peerCount] (Yggdrasil) and [reticulumUp] streams.
/// Fires [addOnPeersAppeared] callbacks when ANY transport transitions
/// from unavailable to available (0 → N peers, or RNS offline → online).
///
/// Call [start] after transport nodes are running.
/// Call [dispose] when done.
class ConnectivityWatcher {
  final Duration _interval;

  Timer? _timer;

  // Yggdrasil state.
  int _lastYggCount = -1;
  final _peerCountCtrl = StreamController<int>.broadcast();
  Stream<int> get peerCount => _peerCountCtrl.stream;

  // Reticulum state.
  bool _lastRnsUp = false;
  int _lastRnsCount = 0;
  final _rnsUpCtrl = StreamController<bool>.broadcast();
  Stream<bool> get reticulumUp => _rnsUpCtrl.stream;

  /// Current number of online Reticulum interfaces.
  int get rnsInterfaceCount => _lastRnsCount;

  /// Legacy single callback — kept for backward compat.
  @Deprecated('Use addOnPeersAppeared instead')
  set onPeersAppeared(void Function()? cb) {
    _legacyCallback = cb;
  }
  void Function()? _legacyCallback;

  /// Registered callbacks invoked when any transport appears.
  final _onPeersAppearedCallbacks = <void Function()>[];

  void Function() addOnPeersAppeared(void Function() cb) {
    _onPeersAppearedCallbacks.add(cb);
    return () => _onPeersAppearedCallbacks.remove(cb);
  }

  ConnectivityWatcher({Duration interval = const Duration(seconds: 5)})
      : _interval = interval;

  void start() {
    _timer?.cancel();
    _poll();
    _timer = Timer.periodic(_interval, (_) => _poll());
  }

  void updateInterval(Duration interval) {
    _timer?.cancel();
    if (interval == Duration.zero) return;
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  Future<void> _poll() async {
    bool anyAppeared = false;

    // ── Yggdrasil ──
    try {
      final peers = await YggdrasilNode.peers();
      final count = peers.where((p) => p.up).length;
      if (!_peerCountCtrl.isClosed) _peerCountCtrl.add(count);
      if (count > 0 && _lastYggCount <= 0) anyAppeared = true;
      _lastYggCount = count;
    } catch (_) {}

    // ── Reticulum ──
    try {
      final running = await ReticulumNode.isRunning();
      if (running) {
        final count = await ReticulumNode.interfaceCount();
        if (!_rnsUpCtrl.isClosed) _rnsUpCtrl.add(count > 0);
        if (count > 0 && !_lastRnsUp) anyAppeared = true;
        _lastRnsUp = count > 0;
        _lastRnsCount = count;
      } else {
        if (!_rnsUpCtrl.isClosed) _rnsUpCtrl.add(false);
        _lastRnsUp = false;
        _lastRnsCount = 0;
      }
    } catch (_) {}

    // Fire callbacks if any transport appeared.
    if (anyAppeared) {
      _legacyCallback?.call();
      for (final cb in List.of(_onPeersAppearedCallbacks)) {
        cb();
      }
    }
  }

  /// True if any transport has connectivity.
  bool get hasConnectivity => _lastYggCount > 0 || _lastRnsUp;

  /// Current Yggdrasil peer count (-1 if unknown).
  int get yggPeerCount => _lastYggCount;

  /// Whether Reticulum node is running.
  bool get isReticulumUp => _lastRnsUp;

  void dispose() {
    _timer?.cancel();
    _peerCountCtrl.close();
    _rnsUpCtrl.close();
    _onPeersAppearedCallbacks.clear();
  }
}
