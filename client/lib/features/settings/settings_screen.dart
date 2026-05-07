import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/providers/yggdrasil_controller.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import '../../shared/utils/pubkey_codec.dart';
import '../../shared/widgets/pin_pad.dart';
import '../../reticulum/reticulum_node.dart';
import '../../yggdrasil/yggdrasil_node.dart';

/// True if Android Keystore is hardware-backed (API 28+ = Android 9+).
/// On API 26-27 (Android 8.x) may use software Keystore.
final _hardwareKeystoreProvider = FutureProvider<bool>((ref) async {
  try {
    const ch = MethodChannel('hubcore/security');
    final result = await ch.invokeMethod<bool>('isKeystoreHardwareBacked');
    return result ?? false;
  } catch (_) {
    return false;
  }
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: HubCoreAppBar(title: Text(context.l10n.settingsTitle)),
      body: ListView(
        children: [
          // Identity section
          _SectionHeader(context.l10n.sectionIdentity),
          if (identity != null) ...[
            ListTile(
              title: Text(context.l10n.fingerprint),
              subtitle: Text(
                identity.fingerprint,
                style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2),
              ),
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () {
                Clipboard.setData(ClipboardData(text: identity.fingerprint));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l10n.fingerprintCopied)),
                );
              },
            ),
            ListTile(
              title: Text(context.l10n.publicKeyBase58),
              subtitle: Text(
                PubkeyCodec.encode(identity.masterPublicKey),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () {
                Clipboard.setData(ClipboardData(text: PubkeyCodec.encode(identity.masterPublicKey)));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l10n.publicKeyCopied)),
                );
              },
            ),
            ListTile(
              title: Text(context.l10n.rotateSigningKey),
              subtitle: Text(context.l10n.rotateSigningKeyDesc),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                final sodium = await ref.read(sodiumProvider.future);
                await ref.read(identityNotifierProvider.notifier).rotateSigningKey(sodium);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(context.l10n.signingKeyRotated)),
                  );
                }
              },
            ),
          ],

          const Divider(),
          _SectionHeader(context.l10n.sectionNetwork),
          _TransportPanel(),

          ListTile(
            title: Text(context.l10n.networkStatus),
            subtitle: Text(context.l10n.yggdrasilReticulum),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/network-status'),
          ),
          _RetryIntervalTile(),
          _MaxAttemptsTile(),

          const Divider(),
          _SectionHeader(context.l10n.sectionBackup),

          ListTile(
            title: Text(context.l10n.exportBackup),
            subtitle: Text(context.l10n.exportBackupDesc),
            trailing: const Icon(Icons.download),
            onTap: () => _exportBackup(context, ref),
          ),
          ListTile(
            title: Text(context.l10n.importBackup),
            subtitle: Text(context.l10n.importBackupDesc),
            trailing: const Icon(Icons.upload_file),
            onTap: () => _importBackup(context, ref),
          ),

          const Divider(),
          _SectionHeader(context.l10n.sectionSecurity),

          // Hardware Keystore status
          ref.watch(_hardwareKeystoreProvider).when(
            data: (isHardware) => isHardware
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange),
                    title: Text(context.l10n.softwareKeystore,
                        style: const TextStyle(color: Colors.orange)),
                    subtitle: Text(context.l10n.softwareKeystoreDesc,
                        style: const TextStyle(fontSize: 12)),
                    dense: true,
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),

          ListTile(
            title: const Text('Мои устройства'),
            subtitle: const Text('Управление связанными устройствами'),
            leading: const Icon(Icons.devices_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/devices'),
          ),
          ListTile(
            title: const Text('Сменить PIN'),
            subtitle: const Text('Изменить PIN-код разблокировки'),
            leading: const Icon(Icons.pin_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _changePin(context, ref),
          ),
          ListTile(
            title: Text(context.l10n.duressPin),
            subtitle: Text(context.l10n.duressPinDesc),
            leading: const Icon(Icons.shield_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _manageDuressPin(context, ref),
          ),
          ListTile(
            title: Text(
              context.l10n.wipeAllData,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: Text(context.l10n.wipeAllDataDesc),
            leading: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
            onTap: () => _confirmWipe(context, ref),
          ),

          _SectionHeader('Приватность'),

          _IncomingPolicyTile(),
          ListTile(
            title: const Text('Заблокированные контакты'),
            subtitle: const Text('Просмотр и управление'),
            leading: const Icon(Icons.block_outlined),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/blocked-contacts'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final backup = ref.read(keyBackupProvider);
    if (backup == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.identityNotLoaded)),
      );
      return;
    }

    final password = await _askPassword(context, title: context.l10n.backupPassword);
    if (password == null || password.isEmpty) return;

    try {
      final path = await backup.exportBackup(password);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.backupSavedTo(path))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.exportFailed('$e'))),
        );
      }
    }
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    final backup = ref.read(keyBackupProvider);
    if (backup == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.sodiumNotReady)),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.importBackupDialogTitle),
        content: Text(context.l10n.importBackupDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.continueAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final password = await _askPassword(context, title: context.l10n.backupPassword);
    if (password == null || password.isEmpty) return;

    try {
      final ok = await backup.importBackup(password);
      if (!ok) return;
      if (!context.mounted) return;
      final sodium = await ref.read(sodiumProvider.future);
      await ref.read(identityNotifierProvider.notifier).load(sodium);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.identityRestored)),
        );
      }
    } on ArgumentError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.importFailed('$e'))),
        );
      }
    }
  }

  Future<String?> _askPassword(BuildContext context, {required String title}) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: InputDecoration(
            hintText: context.l10n.enterPassword,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _changePin(BuildContext context, WidgetRef ref) async {
    final lock = ref.read(lockManagerProvider);
    if (lock == null) return;

    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Сменить PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null) ...[
                Text(error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: oldCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Текущий PIN'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: newCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Новый PIN'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Повторите новый PIN'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () async {
                final oldPin = oldCtrl.text.trim();
                final newPin = newCtrl.text.trim();
                final confirm = confirmCtrl.text.trim();
                if (oldPin.isEmpty || newPin.isEmpty) {
                  setDialogState(() => error = 'Заполните все поля');
                  return;
                }
                if (newPin.length < 4) {
                  setDialogState(() => error = 'PIN должен быть не менее 4 цифр');
                  return;
                }
                if (newPin != confirm) {
                  setDialogState(() => error = 'Новые PIN-коды не совпадают');
                  return;
                }
                final ok = await lock.changePin(oldPin, newPin);
                if (!ctx.mounted) return;
                if (ok) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PIN успешно изменён')),
                  );
                } else {
                  setDialogState(() => error = 'Неверный текущий PIN');
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    oldCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
  }

  Future<void> _manageDuressPin(BuildContext context, WidgetRef ref) async {
    final lock = ref.read(lockManagerProvider);
    if (lock == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.appNotUnlocked)),
      );
      return;
    }
    final result = await showDialog<_DuressPinResult>(
      context: context,
      builder: (_) => _DuressPinDialog(lock: lock),
    );
    if (result == null || !context.mounted) return;
    switch (result) {
      case _DuressPinResult.set:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.duressPinSet)),
        );
      case _DuressPinResult.removed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.duressPinRemoved)),
        );
      case _DuressPinResult.wrongPin:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.wrongCurrentPin)),
        );
    }
  }

  Future<void> _confirmWipe(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(context.l10n.wipeAllDataTitle),
        content: Text(context.l10n.wipeAllDataContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.wipeButton),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final wipe = ref.read(wipeServiceProvider);
      await wipe.wipe();
      if (context.mounted) context.go('/onboarding');
    }
  }
}

// ── Duress PIN dialog ─────────────────────────────────────────────────────────

enum _DuressPinResult { set, removed, wrongPin }

class _DuressPinDialog extends StatefulWidget {
  final LockManager lock;
  const _DuressPinDialog({required this.lock});

  @override
  State<_DuressPinDialog> createState() => _DuressPinDialogState();
}

class _DuressPinDialogState extends State<_DuressPinDialog> {
  static const _len = 4;

  int _step = 0;
  String _pin = '';
  String _duress1 = '';
  String _duress2 = '';
  String? _error;
  bool _loading = false;

  String get _currentEntry => switch (_step) {
        0 => _pin,
        1 => _duress1,
        _ => _duress2,
      };

  String _title(BuildContext context) => switch (_step) {
        0 => context.l10n.enterCurrentPin,
        1 => context.l10n.setDuressPin,
        _ => context.l10n.confirmDuressPin,
      };

  String _subtitle(BuildContext context) => switch (_step) {
        0 => context.l10n.pinConfirmIdentity,
        1 => context.l10n.duressPinSetHelp,
        _ => context.l10n.duressPinConfirmHelp,
      };

  void _onDigit(String d) {
    if (_loading) return;
    final entry = _currentEntry;
    if (entry.length >= _len) return;
    setState(() {
      _error = null;
      switch (_step) {
        case 0:
          _pin += d;
        case 1:
          _duress1 += d;
        default:
          _duress2 += d;
      }
    });
    if (_currentEntry.length == _len) {
      Future.delayed(const Duration(milliseconds: 120), _submit);
    }
  }

  void _onDelete() {
    if (_loading) return;
    setState(() {
      _error = null;
      switch (_step) {
        case 0:
          if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
        case 1:
          if (_duress1.isNotEmpty) _duress1 = _duress1.substring(0, _duress1.length - 1);
        default:
          if (_duress2.isNotEmpty) _duress2 = _duress2.substring(0, _duress2.length - 1);
      }
    });
  }

  Future<void> _submit() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (_step == 0) {
        final ok = await widget.lock.checkPin(_pin);
        if (!ok) {
          setState(() { _error = context.l10n.wrongPin; _pin = ''; });
          return;
        }
        setState(() => _step = 1);
      } else if (_step == 1) {
        final sameAsReal = await widget.lock.checkPin(_duress1);
        if (sameAsReal) {
          setState(() {
            _error = context.l10n.duressMustDiffer;
            _duress1 = '';
          });
          return;
        }
        setState(() => _step = 2);
      } else {
        if (_duress2 != _duress1) {
          setState(() { _error = context.l10n.pinsDoNotMatch; _duress2 = ''; _step = 1; _duress1 = ''; });
          return;
        }
        await widget.lock.setDuressPin(_duress1);
        if (mounted) Navigator.pop(context, _DuressPinResult.set);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeDuressPin() async {
    await widget.lock.clearDuressPin();
    if (mounted) Navigator.pop(context, _DuressPinResult.removed);
  }

  @override
  Widget build(BuildContext context) {
    final entry = _currentEntry;
    return Dialog(
      backgroundColor: const Color(0xFF17212B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 40, color: Color(0xFF2AABEE)),
            const SizedBox(height: 16),
            Text(
              _title(context),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _subtitle(context),
              style: const TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            PinDots(filled: entry.length, total: _len),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _error != null
                  ? Padding(
                      key: ValueKey(_error),
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Color(0xFFEF5350), fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : const SizedBox(height: 30),
            ),
            const SizedBox(height: 12),
            _loading
                ? const CircularProgressIndicator()
                : PinPad(onDigit: _onDigit, onDelete: _onDelete),
            if (_step == 1) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: _removeDuressPin,
                child: Text(
                  context.l10n.removeDuressPin,
                  style: const TextStyle(color: Color(0xFFEF5350)),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel, style: const TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Transport Panel ───────────────────────────────────────────────────────────

class _TransportPanel extends ConsumerStatefulWidget {
  const _TransportPanel();

  @override
  ConsumerState<_TransportPanel> createState() => _TransportPanelState();
}

class _TransportPanelState extends ConsumerState<_TransportPanel> {
  final Map<String, String?> _status = {};
  final Map<String, bool> _checking = {};

  Future<void> _check(String protocolId) async {
    if (_checking[protocolId] == true) return;
    setState(() { _checking[protocolId] = true; _status[protocolId] = null; });

    try {
      final result = await _runCheck(protocolId);
      if (mounted) setState(() { _status[protocolId] = result; });
    } catch (e) {
      if (mounted) setState(() { _status[protocolId] = 'error: $e'; });
    } finally {
      if (mounted) setState(() { _checking[protocolId] = false; });
    }
  }

  Future<String> _runCheck(String protocolId) async {
    switch (protocolId) {
      case TransportProtocol.yggdrasil:
        final running = await YggdrasilNode.isRunning();
        if (!running) return 'not running';
        final peerList = await YggdrasilNode.peers();
        if (peerList.isEmpty) return 'running · no peers';
        final up = peerList.where((p) => p.up).length;
        final lines = <String>['running · $up/${peerList.length} up'];
        for (final p in peerList) {
          final uri = p.uri.length > 40 ? '…${p.uri.substring(p.uri.length - 37)}' : p.uri;
          final lat = p.latencyMs > 0 ? ' ${p.latencyMs.toStringAsFixed(0)}ms' : '';
          final dir = p.inbound ? '↓' : '↑';
          final st  = p.up ? '✓' : '✗';
          final err = p.lastError.isNotEmpty ? ' (${p.lastError})' : '';
          lines.add('$st $dir $uri$lat$err');
        }
        return lines.join('\n');

      case TransportProtocol.reticulum:
        final rnsRunning = await ReticulumNode.isRunning();
        if (!rnsRunning) return 'not running';
        final addr = await ReticulumNode.address();
        if (addr.isEmpty) return 'running · no address';
        return 'running · ${addr.substring(0, 8)}…';

      case TransportProtocol.meshcore:
        return 'not implemented yet';

      default:
        return 'unknown';
    }
  }

  Future<void> _toggle(String protocolId) async {
    ref.read(disabledTransportsProvider.notifier).toggle(protocolId);
    final disabled = ref.read(disabledTransportsProvider);
    final enabled = !disabled.contains(protocolId);

    final storage = ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set(
          'disabled_transports', jsonEncode(disabled.toList()));
    }

    // For Yggdrasil: also start/stop the Kotlin foreground service.
    if (protocolId == TransportProtocol.yggdrasil) {
      final ctrl = ref.read(yggdrasilControllerProvider);
      if (enabled) {
        ctrl.start();
      } else {
        await ctrl.stop();
      }
    }

    // For Reticulum: start/stop the Kotlin foreground service.
    if (protocolId == TransportProtocol.reticulum) {
      if (enabled) {
        await ReticulumNode.start();
      } else {
        await ReticulumNode.stop();
      }
    }

  }

  @override
  Widget build(BuildContext context) {
    final disabled = ref.watch(disabledTransportsProvider);

    const protocols = [
      (TransportProtocol.yggdrasil, Icons.hub,       'Yggdrasil'),
      (TransportProtocol.reticulum, Icons.podcasts,  'Reticulum'),
      (TransportProtocol.meshcore,  Icons.bluetooth, 'Meshcore'),
    ];

    return Column(
      children: protocols.map(((String, IconData, String) p) {
        final (id, icon, label) = p;
        final enabled = !disabled.contains(id);
        final checking = _checking[id] == true;
        final status = _status[id];

        return ListTile(
          leading: Icon(
            icon,
            color: enabled ? Theme.of(context).colorScheme.primary : Colors.white24,
          ),
          title: Text(label),
          subtitle: status != null
              ? Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: _statusColor(status),
                  ),
                )
              : null,
          onTap: () => context.push('/network-settings/$id'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: checking
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        icon: const Icon(Icons.network_check, size: 20),
                        tooltip: 'Check connectivity',
                        onPressed: enabled ? () => _check(id) : null,
                        color: Colors.white54,
                      ),
              ),
              const SizedBox(width: 4),
              Switch(
                value: enabled,
                onChanged: (_) => _toggle(id),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Color _statusColor(String status) {
    if (status.startsWith('running') || status.startsWith('OK')) return Colors.greenAccent;
    if (status.startsWith('not running')) return Colors.orangeAccent;
    if (status.startsWith('not implemented')) return Colors.white38;
    return Colors.orangeAccent;
  }
}

// ── Yggdrasil Peers List ──────────────────────────────────────────────────────

/// Returns the URI without query parameters.
String _uriWithoutQuery(String uri) {
  final idx = uri.indexOf('?');
  return idx == -1 ? uri : uri.substring(0, idx);
}

/// Returns the base URI (without query) for comparison.
String _uriBase(String uri) => _uriWithoutQuery(uri);

class _YggPeersList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(yggPeersProvider);
    final storage = ref.watch(storageProvider);

    Future<void> savePeers() async {
      if (!storage.isOpen) return;
      final extra = ref.read(yggPeersProvider.notifier).extra;
      await storage.settings.set(kExtraYggPeersKey, jsonEncode(extra));
    }

    return Column(
      children: [
        ...peers.map((uri) {
          final isBuiltIn = kYggdrasilDefaultPeers.any((p) =>
              uri == p || uri.startsWith('$p?') || _uriBase(uri) == p);
          // OPT-1: extract priority from URI query param
          final parsedUri = Uri.tryParse(uri);
          final priorityStr = parsedUri?.queryParameters['priority'] ?? '';
          final hasPriority = priorityStr.isNotEmpty;

          return ListTile(
            dense: true,
            leading: Icon(
              isBuiltIn ? Icons.lock_outline : Icons.dns_outlined,
              size: 20,
              color: isBuiltIn ? Colors.white38 : null,
            ),
            title: Text(
              _uriWithoutQuery(uri),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            subtitle: Row(
              children: [
                if (isBuiltIn)
                  Text(context.l10n.builtIn,
                      style: const TextStyle(fontSize: 11, color: Colors.white38)),
                if (hasPriority) ...[
                  if (isBuiltIn) const Text(' · ', style: TextStyle(color: Colors.white38)),
                  Text('${context.l10n.priority} $priorityStr',
                      style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // OPT-1: edit priority button
                IconButton(
                  icon: const Icon(Icons.low_priority, size: 18),
                  tooltip: context.l10n.priority,
                  color: hasPriority ? Colors.blue : Colors.white38,
                  onPressed: () async {
                    final ctrl = TextEditingController(text: priorityStr);
                    final result = await showDialog<String>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(context.l10n.peerPriority),
                        content: TextField(
                          controller: ctrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: context.l10n.notSet,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(context.l10n.cancel),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                            child: Text(context.l10n.save),
                          ),
                        ],
                      ),
                    );
                    if (result == null) return;
                    final notifier = ref.read(yggPeersProvider.notifier);
                    notifier.remove(uri);
                    final baseUri = _uriWithoutQuery(uri);
                    final newUri = result.isEmpty ? baseUri : '$baseUri?priority=$result';
                    notifier.add(newUri);
                    await savePeers();
                  },
                ),
                if (!isBuiltIn)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      ref.read(yggPeersProvider.notifier).remove(uri);
                      await savePeers();
                    },
                  ),
              ],
            ),
          );
        }),
        ListTile(
          dense: true,
          leading: const Icon(Icons.add, size: 20),
          title: Text(context.l10n.addPeer),
          onTap: () async {
            final ctrl = TextEditingController();
            final result = await showDialog<String>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(context.l10n.addYggPeer),
                content: TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    hintText: 'tls://example.com:443',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                    child: Text(context.l10n.addPeer),
                  ),
                ],
              ),
            );
            if (result != null && result.isNotEmpty) {
              ref.read(yggPeersProvider.notifier).add(result);
              await savePeers();
            }
          },
        ),
      ],
    );
  }
}

// ── Yggdrasil Security Panel (SEC-1 + SEC-2) ─────────────────────────────────

class _YggSecurityPanel extends ConsumerStatefulWidget {
  const _YggSecurityPanel();

  @override
  ConsumerState<_YggSecurityPanel> createState() => _YggSecurityPanelState();
}

class _YggSecurityPanelState extends ConsumerState<_YggSecurityPanel> {
  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(storageProvider);

    return Column(
      children: [
        // SEC-1: AllowedPublicKeys whitelist
        FutureBuilder<String?>(
          future: storage.isOpen
              ? storage.settings.get('ygg_allowed_pubkeys')
              : Future.value(null),
          builder: (context, snap) {
            final enabled = snap.data != null && snap.data!.isNotEmpty && snap.data != '[]';
            return SwitchListTile(
              secondary: const Icon(Icons.verified_user_outlined),
              title: Text(context.l10n.trustedPeersOnly),
              subtitle: Text(
                enabled
                    ? context.l10n.trustedPeersOnlyDesc
                    : context.l10n.allInboundAllowed,
                style: const TextStyle(fontSize: 12),
              ),
              value: enabled,
              onChanged: (v) async {
                if (!storage.isOpen) return;
                if (v) {
                  // Collect Yggdrasil pub keys from contacts
                  // Keys are stored in contacts DB — for now save a placeholder
                  // that the user fills via contact management.
                  // We store "enabled" flag; actual keys collected at node start.
                  await storage.settings.set('ygg_allowed_pubkeys_enabled', 'true');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l10n.trustedPeersModeOn)),
                    );
                  }
                } else {
                  await storage.settings.set('ygg_allowed_pubkeys_enabled', '');
                  await storage.settings.set('ygg_allowed_pubkeys', '');
                }
                setState(() {});
              },
            );
          },
        ),

        // SEC-2: Multicast group password
        FutureBuilder<String?>(
          future: storage.isOpen
              ? storage.settings.get('ygg_multicast_pass')
              : Future.value(null),
          builder: (context, snap) {
            final pass = snap.data ?? '';
            return ListTile(
              leading: const Icon(Icons.password),
              title: Text(context.l10n.lanDiscoveryPassword),
              subtitle: Text(
                pass.isEmpty
                    ? context.l10n.openDiscovery
                    : context.l10n.protectedDiscovery,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.edit, size: 18),
              onTap: () async {
                final ctrl = TextEditingController(text: pass);
                final result = await showDialog<String>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(context.l10n.lanDiscoveryPasswordTitle),
                    content: TextField(
                      controller: ctrl,
                      decoration: InputDecoration(
                        hintText: context.l10n.openDiscoveryHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.cancel),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, ctrl.text),
                        child: Text(context.l10n.save),
                      ),
                    ],
                  ),
                );
                if (result != null && storage.isOpen) {
                  await storage.settings.set('ygg_multicast_pass', result);
                  setState(() {});
                }
              },
            );
          },
        ),
      ],
    );
  }
}

// ── Retry interval tile ───────────────────────────────────────────────────────

class _RetryIntervalTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(storageProvider);

    return FutureBuilder<String?>(
      future: storage.isOpen
          ? storage.settings.get('queue_retry_minutes')
          : Future.value(null),
      builder: (context, snap) {
        final minutes = int.tryParse(snap.data ?? '') ?? 5;
        final label = _label(minutes);

        return ListTile(
          leading: const Icon(Icons.schedule),
          title: Text(context.l10n.retryInterval),
          subtitle: Text(label),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pick(context, ref, minutes),
        );
      },
    );
  }

  static String _label(int minutes) {
    if (minutes == 0) return 'Никогда';
    if (minutes == 1) return 'Каждую минуту';
    return 'Каждые $minutes минут';
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, int current) async {
    const options = {0: 'Никогда', 1: '1 минута', 5: '5 минут', 15: '15 минут', 30: '30 минут'};
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.retryInterval,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          ...options.entries.map((e) {
            final isCurrent = e.key == current;
            return ListTile(
              title: Text(
                e.value,
                style: TextStyle(
                  color: isCurrent ? const Color(0xFF2AABEE) : Colors.white,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.check, color: Color(0xFF2AABEE), size: 20)
                  : null,
              onTap: () => Navigator.pop(ctx, e.key),
            );
          }),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (chosen == null) return;
    final storage = ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set('queue_retry_minutes', '$chosen');
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${context.l10n.retryInterval}: ${_label(chosen)}')),
      );
    }
  }
}

// ── Max attempts tile ─────────────────────────────────────────────────────────

class _MaxAttemptsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(storageProvider);

    return FutureBuilder<String?>(
      future: storage.isOpen
          ? storage.settings.get('queue_max_attempts')
          : Future.value(null),
      builder: (context, snap) {
        final attempts = int.tryParse(snap.data ?? '') ?? 30;
        final label = attempts == 0 ? 'Без ограничений' : '$attempts попыток';

        return ListTile(
          leading: const Icon(Icons.repeat),
          title: Text(context.l10n.maxAttempts),
          subtitle: Text(label),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pick(context, ref, attempts),
        );
      },
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, int current) async {
    const options = {5: '5', 10: '10', 30: '30', 50: '50', 0: 'Без ограничений'};
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C2733),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              context.l10n.maxAttempts,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
          ...options.entries.map((e) {
            final isCurrent = e.key == current;
            return ListTile(
              title: Text(
                e.key == 0 ? 'Без ограничений' : '${e.value} попыток',
                style: TextStyle(
                  color: isCurrent ? const Color(0xFF2AABEE) : Colors.white,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              trailing: isCurrent
                  ? const Icon(Icons.check, color: Color(0xFF2AABEE), size: 20)
                  : null,
              onTap: () => Navigator.pop(ctx, e.key),
            );
          }),
          const SizedBox(height: 16),
        ],
      ),
    );
    if (chosen == null) return;
    final storage = ref.read(storageProvider);
    if (storage.isOpen) {
      await storage.settings.set('queue_max_attempts', '$chosen');
    }
    if (context.mounted) {
      final label = chosen == 0 ? 'Без ограничений' : '$chosen попыток';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${context.l10n.maxAttempts}: $label')),
      );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 1.5,
            ),
      ),
    );
  }
}

/// Radio-group tile for "Who can message me" setting.
class _IncomingPolicyTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_IncomingPolicyTile> createState() => _IncomingPolicyTileState();
}

class _IncomingPolicyTileState extends ConsumerState<_IncomingPolicyTile> {
  String _policy = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final v = await storage.settings.get('incoming_contacts_policy') ?? 'all';
    if (mounted) setState(() => _policy = v);
  }

  Future<void> _set(String value) async {
    final storage = ref.read(storageProvider);
    await storage.settings.set('incoming_contacts_policy', value);
    if (mounted) setState(() => _policy = value);
  }

  @override
  Widget build(BuildContext context) {
    const options = [
      ('all',           'Все',                    'Любой знающий ваш ключ'),
      ('contacts_only', 'Только мои контакты',    'Незнакомцы не попадут в чаты'),
      ('nobody',        'Никто',                  'Полная тишина'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('Кто может писать мне',
              style: TextStyle(fontSize: 14, color: Colors.white70)),
        ),
        ...options.map((o) => RadioListTile<String>(
              value: o.$1,
              groupValue: _policy,
              title: Text(o.$2),
              subtitle: Text(o.$3, style: const TextStyle(fontSize: 12)),
              dense: true,
              onChanged: (v) { if (v != null) _set(v); },
            )),
      ],
    );
  }
}
