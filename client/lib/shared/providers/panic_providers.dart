import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/shake_detector_service.dart';
import 'storage_providers.dart';

/// Soft = 3-sec countdown overlay (cancellable by tap). Hard = instant wipe.
enum PanicMode { soft, hard }

extension PanicModeX on PanicMode {
  String get id => switch (this) {
        PanicMode.soft => 'soft',
        PanicMode.hard => 'hard',
      };

  static PanicMode fromId(String? s) => switch (s) {
        'hard' => PanicMode.hard,
        _      => PanicMode.soft,
      };
}

class PanicConfig {
  final bool enabled;
  final PanicMode mode;
  final ShakeSensitivity sensitivity;

  const PanicConfig({
    this.enabled     = false,
    this.mode        = PanicMode.soft,
    this.sensitivity = ShakeSensitivity.medium,
  });

  PanicConfig copyWith({
    bool? enabled,
    PanicMode? mode,
    ShakeSensitivity? sensitivity,
  }) =>
      PanicConfig(
        enabled:     enabled     ?? this.enabled,
        mode:        mode        ?? this.mode,
        sensitivity: sensitivity ?? this.sensitivity,
      );
}

class PanicConfigNotifier extends StateNotifier<PanicConfig> {
  PanicConfigNotifier(this._ref) : super(const PanicConfig());
  final Ref _ref;

  static const _kEnabled     = 'panic.enabled';
  static const _kMode        = 'panic.mode';
  static const _kSensitivity = 'panic.sensitivity';

  /// Read current values from the DB. Call after the database is unlocked.
  Future<void> load() async {
    final storage = _ref.read(storageProvider);
    if (!storage.isOpen) return;
    final enabled     = (await storage.settings.get(_kEnabled)) == '1';
    final mode        = PanicModeX.fromId(await storage.settings.get(_kMode));
    final sensitivity =
        ShakeSensitivityX.fromId(await storage.settings.get(_kSensitivity));
    state = PanicConfig(
        enabled: enabled, mode: mode, sensitivity: sensitivity);
  }

  Future<void> setEnabled(bool v) async {
    final storage = _ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set(_kEnabled, v ? '1' : '0');
    }
    state = state.copyWith(enabled: v);
  }

  Future<void> setMode(PanicMode mode) async {
    final storage = _ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set(_kMode, mode.id);
    }
    state = state.copyWith(mode: mode);
  }

  Future<void> setSensitivity(ShakeSensitivity s) async {
    final storage = _ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set(_kSensitivity, s.id);
    }
    state = state.copyWith(sensitivity: s);
  }
}

final panicConfigProvider =
    StateNotifierProvider<PanicConfigNotifier, PanicConfig>(
        (ref) => PanicConfigNotifier(ref));

/// Singleton ShakeDetectorService — wired by [_AppLifecycleGuard] in app.dart.
final shakeDetectorProvider = Provider<ShakeDetectorService>((ref) {
  final svc = ShakeDetectorService();
  ref.onDispose(() => svc.dispose());
  return svc;
});
