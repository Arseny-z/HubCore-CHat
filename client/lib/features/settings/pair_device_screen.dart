import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../application/events/app_events.dart';
import '../../infrastructure/crypto/device_pairing_crypto.dart';
import '../../domain/entities/device_pairing_payload.dart';
import '../../yggdrasil/yggdrasil_node.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/storage_providers.dart' show eventBusProvider;
import '../../shared/providers/transport_providers.dart';
import '../../shared/widgets/hubcore_app_bar.dart';

/// Device A: shows the pairing QR containing an encrypted identity bundle.
/// Device B scans this from the onboarding screen to link the account.
class PairDeviceScreen extends ConsumerStatefulWidget {
  const PairDeviceScreen({super.key});

  @override
  ConsumerState<PairDeviceScreen> createState() => _PairDeviceScreenState();
}

class _PairDeviceScreenState extends ConsumerState<PairDeviceScreen> {
  PairingQrPayload? _payload;
  Timer? _countdownTimer;
  StreamSubscription<dynamic>? _pairingSub;
  int _secondsLeft = 0;
  bool _loading = true;
  bool _success = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generateQr();
    // Show success when Device B's handshake is processed.
    final bus = ref.read(eventBusProvider);
    _pairingSub = bus.on<DevicePairingCompleteEvent>().listen((_) {
      if (mounted) {
        _countdownTimer?.cancel();
        setState(() => _success = true);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pairingSub?.cancel();
    super.dispose();
  }

  Future<void> _generateQr() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _countdownTimer?.cancel();

    try {
      final sodium   = await ref.read(sodiumProvider.future);
      final identity = ref.read(identityNotifierProvider);
      if (identity == null) throw StateError('No identity');

      final yggPub = ref.read(yggPubKeyProvider);
      String yggAddr = '';
      try { yggAddr = await YggdrasilNode.address() ?? ''; } catch (_) {}

      final storage = ref.read(storageProvider);
      final myAlias       = storage.isOpen ? await storage.settings.get('my_alias')        ?? '' : '';
      final myPublicAlias = storage.isOpen ? await storage.settings.get('my_public_alias') ?? '' : '';

      final crypto  = DevicePairingCrypto(sodium);
      final payload = crypto.generatePairingQr(identity, yggPub, yggAddr, myAlias, myPublicAlias);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      setState(() {
        _payload     = payload;
        _secondsLeft = payload.expiresAt - now;
        _loading     = false;
      });

      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _secondsLeft--);
        if (_secondsLeft <= 0) {
          _countdownTimer?.cancel();
          _generateQr(); // auto-refresh
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error   = 'Ошибка генерации QR: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: HubCoreAppBar(title: const Text('Добавить устройство')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'Откройте HubCore Chat на новом устройстве, выберите '
                '"Войти с другого устройства" и наведите камеру на этот QR-код.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: _success
                      ? _SuccessView(onDone: () => Navigator.of(context).pop())
                      : _loading
                      ? const CircularProgressIndicator()
                      : _error != null
                          ? _ErrorView(
                              message: _error!,
                              onRetry: _generateQr,
                            )
                          : _QrView(
                              payload: _payload!,
                              secondsLeft: _secondsLeft,
                              onRefresh: _generateQr,
                            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final VoidCallback onDone;
  const _SuccessView({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 72),
      const SizedBox(height: 16),
      const Text(
        'Устройство успешно добавлено!',
        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      const Text(
        'Новое устройство получит ваши сообщения.',
        style: TextStyle(color: Colors.white54),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: onDone, child: const Text('Готово')),
    ]);
  }
}

class _QrView extends StatelessWidget {
  final PairingQrPayload payload;
  final int secondsLeft;
  final VoidCallback onRefresh;

  const _QrView({
    required this.payload,
    required this.secondsLeft,
    required this.onRefresh,
  });

  String _formatCountdown(int s) {
    if (s <= 0) return '0:00';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(12),
          child: QrImageView(
            data: payload.encode(),
            version: QrVersions.auto,
            size: 240,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.timer_outlined, size: 18, color: Colors.white54),
            const SizedBox(width: 6),
            Text(
              'Истекает через ${_formatCountdown(secondsLeft)}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.white54),
            ),
          ],
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          message,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.error),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить'),
        ),
      ],
    );
  }
}
