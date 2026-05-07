import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/transport_providers.dart';

/// Compact transport status bar — shows active transports or "no network".
///
/// Displays:
///   - "ygg: N | rns: on"  when both transports active
///   - "ygg: N"             when only Yggdrasil
///   - "rns: on"            when only Reticulum
///   - "Connecting…"        when connecting
///   - "No network"         when both are down
class NetworkStatusBar extends ConsumerWidget {
  const NetworkStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(transportStatusProvider);

    return statusAsync.when(
      data: (status) => _buildBar(status),
      loading: () => _pill(Colors.orange.shade400, 'Connecting…', loading: true),
      error: (_, __) => _pill(Colors.red.shade400, 'No network'),
    );
  }

  Widget _buildBar(TransportStatus status) {
    final ygg = status.yggdrasil;
    final rns = status.reticulum;
    final yggOnline = ygg != null && ygg > 0;
    final rnsOnline = rns != null && rns > 0;

    if (yggOnline || rnsOnline) {
      // At least one transport is up — show compact status
      final parts = <String>[];
      if (yggOnline) parts.add('ygg: $ygg');
      if (rnsOnline) parts.add('rns: on');
      return _pill(const Color(0xFF2AABEE), parts.join(' · '));
    }

    final yggConnecting = ygg != null && ygg < 0;
    final rnsConnecting = rns != null && rns == 0;
    if (yggConnecting || rnsConnecting) {
      return _pill(Colors.orange.shade400, 'Connecting…', loading: true);
    }

    return _pill(Colors.red.shade400, 'No network');
  }

  Widget _pill(Color color, String label, {bool loading = false}) {
    return Material(
      color: color.withAlpha(200),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 22,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const SizedBox(
                    width: 10, height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                  )
                else
                  Icon(
                    color == Colors.red.shade400 ? Icons.wifi_off : Icons.check_circle_outline,
                    size: 11, color: Colors.white,
                  ),
                const SizedBox(width: 5),
                Text(label, style: const TextStyle(
                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
