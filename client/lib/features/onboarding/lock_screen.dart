import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/providers/storage_providers.dart'
    show storageProvider, pendingPairingProfileProvider, pendingPairingQrProvider;
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../shared/widgets/pin_pad.dart';

/// Shown when the DB is locked or PIN has not been configured yet.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String _pin = '';
  String _pin2 = '';       // confirmation (setup mode)
  bool _confirmStep = false; // true = entering confirmation
  bool _loading = false;
  bool _submitting = false; // synchronous guard against double-submit
  bool _isSetup = false;
  String? _error;
  int _failedAttempts = 0;

  static const _pinLength = 4;

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  Future<void> _checkSetup() async {
    final lock = ref.read(lockManagerProvider);
    AppLogger.d('LockScreen', '_checkSetup: lock=${lock != null}');
    if (lock == null) return;
    final has = await lock.hasPin();
    final attempts = has ? await lock.failedAttempts() : 0;
    AppLogger.d('LockScreen', '_checkSetup: hasPin=$has failedAttempts=$attempts');
    if (mounted) {
      setState(() {
        _isSetup = !has;
        _failedAttempts = attempts;
      });
    }
  }

  Future<void> _loadPersistedSettings() async {
    // NotificationService.init() is called from MainScreen.initState()
    // after navigation, to avoid concurrent permission dialogs.
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    final sodium = await ref.read(sodiumProvider.future);
    await ref.read(identityNotifierProvider.notifier).load(sodium);

    final extraPeers = await storage.settings.get(kExtraYggPeersKey);
    final disabledTransports = await storage.settings.get('disabled_transports');

    ref.read(yggPeersProvider.notifier).load(extraPeers);
    ref.read(disabledTransportsProvider.notifier).load(disabledTransports);

  }

  void _onDigit(String d) {
    if (_loading) return;
    setState(() {
      _error = null;
      if (_confirmStep) {
        if (_pin2.length < _pinLength) _pin2 += d;
      } else {
        if (_pin.length < _pinLength) _pin += d;
      }
    });
    _maybeSubmit();
  }

  void _onDelete() {
    if (_loading) return;
    setState(() {
      _error = null;
      if (_confirmStep) {
        if (_pin2.isNotEmpty) _pin2 = _pin2.substring(0, _pin2.length - 1);
      } else {
        if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
      }
    });
  }

  void _maybeSubmit() {
    final currentPin = _confirmStep ? _pin2 : _pin;
    if (currentPin.length == _pinLength) {
      Future.delayed(const Duration(milliseconds: 120), _submit);
    }
  }

  Future<void> _submit() async {
    // Synchronous guard — prevents double-submit from two Future.delayed callbacks
    // scheduled by _maybeSubmit (can happen on rapid input or widget rebuilds).
    if (_submitting || _loading) return;
    _submitting = true;

    final lock = ref.read(lockManagerProvider);
    AppLogger.d('LockScreen', '_submit: lock=${lock != null}, isSetup=$_isSetup, confirmStep=$_confirmStep');
    if (lock == null) {
      _submitting = false;
      AppLogger.e('LockScreen', 'lockManagerProvider returned null!');
      return;
    }

    final enteredPin = _confirmStep ? _pin2 : _pin;
    if (enteredPin.length < _pinLength) {
      _submitting = false;
      setState(() => _error = 'Enter $_pinLength digits');
      return;
    }

    if (_isSetup && !_confirmStep) {
      _submitting = false;
      setState(() => _confirmStep = true);
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      if (_isSetup) {
        if (_pin2 != _pin) {
          if (mounted) setState(() {
            _error = context.l10n.pinsDoNotMatch;
            _pin2 = '';
            _confirmStep = false;
          });
          return;
        }
        AppLogger.d('LockScreen', 'initPin...');
        await lock.initPin(_pin);
        AppLogger.d('LockScreen', 'initPin done, loading settings...');
        await _loadPersistedSettings();
        // If a pairing QR was scanned before PIN setup, persist the alias now
        // that the DB is open, and skip profile-setup.
        final storage = ref.read(storageProvider);
        final pending = ref.read(pendingPairingProfileProvider);
        String? aliasToCheck;
        if (pending != null && storage.isOpen) {
          if (pending.myAlias.isNotEmpty) {
            await storage.settings.set('my_alias', pending.myAlias);
            aliasToCheck = pending.myAlias;
          }
          if (pending.myPublicAlias.isNotEmpty) {
            await storage.settings.set('my_public_alias', pending.myPublicAlias);
          }
          ref.read(pendingPairingProfileProvider.notifier).state = null;
        }
        aliasToCheck ??= storage.isOpen
            ? await storage.settings.get('my_alias')
            : null;
        if (mounted) {
          if (aliasToCheck != null && aliasToCheck.isNotEmpty) {
            AppLogger.d('LockScreen', 'alias exists — navigating to /main');
            context.go('/main');
          } else {
            AppLogger.d('LockScreen', 'navigating to /profile-setup');
            context.go('/profile-setup');
          }
        }

        // Pending pairing handshake is sent from messageRouterProvider
        // once messaging initializes — no ref usage needed here.
      } else {
        AppLogger.d('LockScreen', 'unlock attempt...');
        final result = await lock.unlock(enteredPin, onWipe: () {
          AppLogger.w('LockScreen', 'WIPE triggered!');
          if (mounted) context.go('/onboarding');
        });
        AppLogger.d('LockScreen', 'unlock result: $result');
        switch (result) {
          case UnlockResult.success:
            AppLogger.d('LockScreen', 'success — loading settings...');
            await _loadPersistedSettings();
            AppLogger.d('LockScreen', 'navigating to /main');
            if (mounted) context.go('/main');
          case UnlockResult.wrongPin:
            final attempts = await lock.failedAttempts();
            final remaining = lock.maxAttempts - attempts;
            AppLogger.w('LockScreen', 'wrong PIN, attempts=$attempts remaining=$remaining');
            if (mounted) setState(() {
              _failedAttempts = attempts;
              _error = remaining <= 3
                  ? context.l10n.wrongPinAttemptsLeft(remaining)
                  : context.l10n.wrongPin;
              _pin = '';
            });
          case UnlockResult.wiped:
            break;
          case UnlockResult.notConfigured:
            AppLogger.w('LockScreen', 'notConfigured — switching to setup mode');
            setState(() { _isSetup = true; _pin = ''; _error = null; });
          case UnlockResult.keyMismatch:
            AppLogger.e('LockScreen', 'keyMismatch — prompting user to wipe');
            if (mounted) {
              final wipe = await showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (ctx) => AlertDialog(
                  title: Text(ctx.l10n.keyMismatchTitle),
                  content: Text(ctx.l10n.keyMismatchContent),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(ctx.l10n.cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEF5350),
                      ),
                      child: Text(ctx.l10n.resetButton),
                    ),
                  ],
                ),
              );
              if (wipe == true && mounted) {
                await lock.wipe();
                context.go('/onboarding');
              } else {
                setState(() { _pin = ''; });
              }
            }
        }
      }
    } catch (e, st) {
      AppLogger.e('LockScreen', 'submit error', error: e);
      AppLogger.e('LockScreen', st.toString());
      if (mounted) setState(() => _error = _friendlyError(e));
    } finally {
      _submitting = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('no space') || msg.contains('enospc') || msg.contains('disk full')) {
      return 'Недостаточно места на устройстве';
    }
    if (msg.contains('sql logic error') || msg.contains('not a database') ||
        msg.contains('file is encrypted') || msg.contains('wrong key')) {
      return 'База данных недоступна. Попробуйте ещё раз или сбросьте данные приложения.';
    }
    if (msg.contains('permission') || msg.contains('access')) {
      return 'Нет доступа к хранилищу. Проверьте разрешения приложения.';
    }
    if (msg.contains('ioexception') || msg.contains('i/o')) {
      return 'Ошибка чтения данных. Попробуйте перезапустить приложение.';
    }
    return 'Произошла ошибка. Попробуйте ещё раз.';
  }

  String _title(BuildContext context) {
    if (_isSetup) return _confirmStep ? context.l10n.confirmPinTitle : context.l10n.setPinTitle;
    return context.l10n.enterPinTitle;
  }

  String _subtitle(BuildContext context) {
    if (_isSetup) {
      return _confirmStep
          ? context.l10n.confirmPinSubtitle
          : context.l10n.setPinSubtitle;
    }
    return context.l10n.unlockSubtitle;
  }

  @override
  Widget build(BuildContext context) {
    final currentPin = _confirmStep ? _pin2 : _pin;
    return Scaffold(
      backgroundColor: const Color(0xFF17212B),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // ── Lock icon ──────────────────────────────────────────────────
            const Icon(Icons.lock_outline, size: 56, color: Color(0xFF2AABEE)),
            const SizedBox(height: 20),
            Text(
              _title(context),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _subtitle(context),
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),

            // ── PIN dots ───────────────────────────────────────────────────
            PinDots(filled: currentPin.length, total: _pinLength),

            // ── Error / attempt warning ────────────────────────────────────
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _error != null
                  ? Padding(
                      key: ValueKey(_error),
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Color(0xFFEF5350),
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : !_isSetup && _failedAttempts > 0
                      ? Padding(
                          key: ValueKey('attempts_$_failedAttempts'),
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            context.l10n.failedAttemptsCount(_failedAttempts),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : const SizedBox(height: 38),
            ),

            const Spacer(flex: 2),

            // ── Numpad ─────────────────────────────────────────────────────
            _loading
                ? const CircularProgressIndicator()
                : PinPad(onDigit: _onDigit, onDelete: _onDelete),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
