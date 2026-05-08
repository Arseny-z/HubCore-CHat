import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../application/events/app_events.dart';
import '../../domain/entities/device_pairing_payload.dart';
import '../../infrastructure/crypto/device_pairing_crypto.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/storage_providers.dart'
    show pendingPairingProfileProvider, PendingPairingProfile,
         pendingPairingQrProvider;
import '../../shared/widgets/hubcore_app_bar.dart';

enum _State { scanning, importing, waitingAck, noPermission, error }

class ScanPairingScreen extends ConsumerStatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  ConsumerState<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends ConsumerState<ScanPairingScreen> {
  final _scannerCtrl = MobileScannerController();
  _State _state = _State.scanning;
  String? _error;
  StreamSubscription<dynamic>? _ackSub;

  @override
  void initState() {
    super.initState();
    // Start camera on next frame so the widget is fully mounted
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCamera());
  }

  Future<void> _startCamera() async {
    try {
      await _scannerCtrl.start();
    } catch (e) {
      if (mounted) {
        setState(() => _state = _State.noPermission);
      }
    }
  }

  @override
  void dispose() {
    _scannerCtrl.dispose();
    _ackSub?.cancel();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_state != _State.scanning) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    final payload = PairingQrPayload.tryDecode(raw);
    if (payload == null) return;

    setState(() => _state = _State.importing);
    await _scannerCtrl.stop();

    try {
      final sodium = await ref.read(sodiumProvider.future);
      final crypto  = DevicePairingCrypto(sodium);
      final result  = crypto.decryptIdentityFromQr(payload);

      await ref
          .read(identityNotifierProvider.notifier)
          .importFromPairing(sodium, result.identity);

      // DB is not open yet (PIN not set). Hold alias in memory —
      // lock_screen will persist it after initPin() opens the DB.
      if (result.myAlias.isNotEmpty || result.myPublicAlias.isNotEmpty) {
        ref.read(pendingPairingProfileProvider.notifier).state =
            PendingPairingProfile(
              myAlias: result.myAlias,
              myPublicAlias: result.myPublicAlias,
            );
      }

      // Store QR for handshake — DB not open yet, will be sent after PIN setup.
      ref.read(pendingPairingQrProvider.notifier).state = payload;

      setState(() => _state = _State.waitingAck);
      _listenForAck();
    } on ArgumentError catch (e) {
      setState(() { _error = e.message; _state = _State.error; });
      await _scannerCtrl.start();
    } catch (e) {
      setState(() { _error = 'Ошибка: $e'; _state = _State.error; });
      await _scannerCtrl.start();
    }
  }

  void _listenForAck() {
    final bus = ref.read(eventBusProvider);
    _ackSub = bus.on<DevicePairingAckEvent>().listen((_) {
      if (mounted) context.go('/main');
    });
    // Fallback: if ack delayed, proceed to main anyway — Device A will still
    // process the handshake when it arrives.
    Future.delayed(const Duration(seconds: 30), () {
      if (mounted && _state == _State.waitingAck) context.go('/main');
    });
  }

  void _retry() {
    setState(() { _state = _State.scanning; _error = null; });
    _scannerCtrl.start();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: HubCoreAppBar(title: const Text('Войти с другого устройства')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(
                'Откройте HubCore Chat на устройстве с аккаунтом, перейдите в '
                'Настройки → Устройства → "+" и наведите камеру на QR-код.',
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Expanded(child: _body(theme)),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    switch (_state) {
      case _State.scanning:
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
            errorBuilder: (_, error, __) => _permissionDeniedView(theme),
          ),
        );

      case _State.noPermission:
        return _permissionDeniedView(theme);

      case _State.importing:
        return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Импорт ключей…', style: TextStyle(color: Colors.white70)),
          ]),
        );

      case _State.waitingAck:
        return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Ожидаем подтверждение от основного устройства…',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ]),
        );

      case _State.error:
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              _error ?? 'Неизвестная ошибка',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Сканировать снова'),
            ),
          ]),
        );
    }
  }

  Widget _permissionDeniedView(ThemeData theme) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.camera_alt_outlined, size: 48, color: Colors.white38),
        const SizedBox(height: 16),
        const Text(
          'Нет доступа к камере.\nРазрешите доступ в настройках устройства.',
          style: TextStyle(color: Colors.white54),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Повторить'),
        ),
      ]),
    );
  }
}
