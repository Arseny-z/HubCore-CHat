import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../shared/utils/logger.dart';

/// Sensitivity preset for the panic shake gesture.
///
/// Maps to acceleration thresholds (m/s²) above which a single jerk counts.
enum ShakeSensitivity { low, medium, high }

extension ShakeSensitivityX on ShakeSensitivity {
  /// Acceleration threshold (m/s²) — magnitude above gravity that counts as
  /// a "jerk". Higher values require more vigorous shaking.
  double get threshold => switch (this) {
        ShakeSensitivity.low    => 25.0, // very firm shakes only
        ShakeSensitivity.medium => 18.0, // typical phone-shake
        ShakeSensitivity.high   => 12.0, // light shakes (more false-positives)
      };

  String get id => switch (this) {
        ShakeSensitivity.low    => 'low',
        ShakeSensitivity.medium => 'medium',
        ShakeSensitivity.high   => 'high',
      };

  static ShakeSensitivity fromId(String? s) => switch (s) {
        'low'  => ShakeSensitivity.low,
        'high' => ShakeSensitivity.high,
        _      => ShakeSensitivity.medium,
      };
}

/// Detects "panic shake": 3 jerks within a 1-second window.
///
/// A jerk is a single accelerometer sample whose magnitude exceeds the
/// configured threshold. Consecutive jerks within ~50 ms are debounced so a
/// single hard shake counts once. Three distinct jerks within 1 s emit a
/// shake event on [shakes].
class ShakeDetectorService {
  ShakeDetectorService({this.sensitivity = ShakeSensitivity.medium});

  ShakeSensitivity sensitivity;

  StreamSubscription<AccelerometerEvent>? _sub;
  final _ctrl = StreamController<void>.broadcast();

  /// Timestamps (ms since epoch) of recent jerks; trimmed to the last 1 s.
  final List<int> _jerks = [];
  static const _windowMs        = 1000; // 3 jerks within this window → shake
  static const _debounceMs      = 50;   // ignore samples this close together
  static const _shakesRequired  = 3;
  static const _cooldownMs      = 2000; // after firing, wait before next

  int _lastFiredAt = 0;

  /// Stream of shake events (no payload — just "user shook the phone").
  Stream<void> get shakes => _ctrl.stream;

  bool get isRunning => _sub != null;

  /// Start listening to the accelerometer. Safe to call repeatedly.
  void start() {
    if (_sub != null) return;
    _jerks.clear();
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 50), // ~20 Hz
    ).listen(_onSample, onError: (e, _) {
      AppLogger.w('ShakeDetector', 'accelerometer error: $e');
    });
    AppLogger.d('ShakeDetector', 'started (sensitivity=${sensitivity.id})');
  }

  /// Stop listening (and forget any in-progress shake state).
  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    _jerks.clear();
    await s?.cancel();
    AppLogger.d('ShakeDetector', 'stopped');
  }

  Future<void> dispose() async {
    await stop();
    await _ctrl.close();
  }

  void _onSample(AccelerometerEvent e) {
    // Magnitude relative to free-fall (subtract gravity).
    // accel.x/y/z include gravity, so |a| is ~9.8 at rest.
    final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) - 9.81;
    if (mag.abs() < sensitivity.threshold) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_jerks.isNotEmpty && now - _jerks.last < _debounceMs) return;
    if (now - _lastFiredAt < _cooldownMs) return;

    _jerks.add(now);
    // Drop jerks outside the window.
    _jerks.removeWhere((t) => now - t > _windowMs);

    if (_jerks.length >= _shakesRequired) {
      _lastFiredAt = now;
      _jerks.clear();
      AppLogger.w('ShakeDetector', 'PANIC SHAKE detected');
      _ctrl.add(null);
    }
  }
}
