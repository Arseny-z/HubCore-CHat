import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/transport_providers.dart' show transportStatusProvider, TransportStatus;

/// AppBar с полоской статуса сети под заголовком — как в Telegram.
class HubCoreAppBar extends ConsumerStatefulWidget implements PreferredSizeWidget {
  final Widget title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final bool automaticallyImplyLeading;
  final double? titleSpacing;

  const HubCoreAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.automaticallyImplyLeading = true,
    this.titleSpacing,
  });

  static const double _statusBarHeight = 24.0;

  @override
  Size get preferredSize {
    final bottomHeight = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(kToolbarHeight + _statusBarHeight + bottomHeight);
  }

  @override
  ConsumerState<HubCoreAppBar> createState() => _HubCoreAppBarState();
}

class _HubCoreAppBarState extends ConsumerState<HubCoreAppBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotsCtrl;

  @override
  void initState() {
    super.initState();
    _dotsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dotsCtrl.dispose();
    super.dispose();
  }

  Widget _buildConnecting(Color textColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 10, height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: textColor),
        ),
        const SizedBox(width: 6),
        AnimatedBuilder(
          animation: _dotsCtrl,
          builder: (_, __) {
            final dots = '.' * ((_dotsCtrl.value * 4).floor() % 4);
            return Text('Подключение$dots',
                style: TextStyle(color: textColor, fontSize: 11,
                    fontWeight: FontWeight.w500));
          },
        ),
      ],
    );
  }

  /// Overall connectivity: online if any transport has active peers.
  static bool _isOnline(TransportStatus s) =>
      (s.yggdrasil != null && s.yggdrasil! > 0) ||
      (s.reticulum  != null && s.reticulum!  > 0);

  /// Connecting: at least one transport is running but has 0 peers, none online.
  static bool _isConnecting(TransportStatus s) =>
      !_isOnline(s) &&
      ((s.yggdrasil != null && s.yggdrasil! == 0) ||
       (s.reticulum  != null && s.reticulum!  == 0));

  Widget _globalStatusChip(TransportStatus status, Color textColor) {
    if (_isOnline(status)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7, height: 7,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF4CAF50), // green
            ),
          ),
          const SizedBox(width: 5),
          const Text('Онлайн',
              style: TextStyle(
                  color: Color(0xFF4CAF50),
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      );
    }
    if (_isConnecting(status)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8, height: 8,
            child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: const Color(0xFFFFB300)),
          ),
          const SizedBox(width: 5),
          AnimatedBuilder(
            animation: _dotsCtrl,
            builder: (_, __) {
              final dots = '.' * ((_dotsCtrl.value * 4).floor() % 4);
              return Text('Подключение$dots',
                  style: const TextStyle(
                      color: Color(0xFFFFB300),
                      fontSize: 11,
                      fontWeight: FontWeight.w600));
            },
          ),
        ],
      );
    }
    // Offline
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7, height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: textColor.withOpacity(0.5),
          ),
        ),
        const SizedBox(width: 5),
        Text('Нет связи',
            style: TextStyle(
                color: textColor.withOpacity(0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _buildStatusRow(TransportStatus status, Color textColor, Color activeColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _globalStatusChip(status, textColor),
        _divider(textColor),
        _protocolChip('Ygg', status.yggdrasil, textColor, activeColor),
        _divider(textColor),
        _protocolChip('Reticulum', status.reticulum, textColor, activeColor),
        _divider(textColor),
        _protocolChip('Meshcore', status.meshcore, textColor, activeColor),
      ],
    );
  }

  Widget _protocolChip(String name, int? peers, Color textColor, Color activeColor) {
    final bool connected = peers != null && peers > 0;
    final bool connecting = peers != null && peers == 0;
    final color = connected ? activeColor : textColor;
    String label;
    if (peers == null) {
      label = '—';
    } else if (peers == 0) {
      label = name;
    } else {
      label = '$name · $peers';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (connecting)
          SizedBox(
            width: 8, height: 8,
            child: CircularProgressIndicator(strokeWidth: 1.2, color: textColor),
          )
        else
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? activeColor : textColor.withOpacity(0.3),
            ),
          ),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(color: color, fontSize: 11,
                fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _divider(Color textColor) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text('·', style: TextStyle(color: textColor.withOpacity(0.3), fontSize: 11)),
  );

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(transportStatusProvider);

    const bgColor   = Color(0xFF162330);
    const textColor = Colors.white38;
    const activeColor = Color(0xFF52B8EA);

    final statusStrip = PreferredSize(
      preferredSize: const Size.fromHeight(HubCoreAppBar._statusBarHeight),
      child: Container(
        width: double.infinity,
        height: HubCoreAppBar._statusBarHeight,
        color: bgColor,
        child: Center(
          child: statusAsync.when(
            loading: () => _buildConnecting(textColor),
            error: (_, __) => _buildConnecting(textColor),
            data: (status) => _buildStatusRow(status, textColor, activeColor),
          ),
        ),
      ),
    );

    // Combine status strip + optional custom bottom
    final PreferredSizeWidget combinedBottom;
    if (widget.bottom != null) {
      combinedBottom = PreferredSize(
        preferredSize: Size.fromHeight(
            HubCoreAppBar._statusBarHeight + widget.bottom!.preferredSize.height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [statusStrip, widget.bottom!],
        ),
      );
    } else {
      combinedBottom = statusStrip;
    }

    return AppBar(
      title: widget.title,
      actions: widget.actions,
      leading: widget.leading,
      automaticallyImplyLeading: widget.automaticallyImplyLeading,
      titleSpacing: widget.titleSpacing,
      bottom: combinedBottom,
    );
  }
}
