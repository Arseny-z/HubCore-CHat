import 'dart:async';

import 'package:flutter/material.dart';

import '../../shared/utils/l10n.dart';

/// Full-screen warning shown after a panic shake in Soft mode.
///
/// Counts down from [seconds] (default 3). Tapping anywhere cancels.
/// When the countdown completes, [onWipe] is invoked.
class PanicCountdownOverlay extends StatefulWidget {
  final int seconds;
  final VoidCallback onWipe;
  final VoidCallback onCancel;

  const PanicCountdownOverlay({
    super.key,
    this.seconds = 3,
    required this.onWipe,
    required this.onCancel,
  });

  @override
  State<PanicCountdownOverlay> createState() => _PanicCountdownOverlayState();
}

class _PanicCountdownOverlayState extends State<PanicCountdownOverlay> {
  late int _remaining = widget.seconds;
  Timer? _timer;
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining -= 1);
      if (_remaining <= 0) {
        _timer?.cancel();
        if (!_fired) {
          _fired = true;
          widget.onWipe();
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _cancel() {
    if (_fired) return;
    _timer?.cancel();
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _cancel,
      child: Container(
        color: Colors.red.shade900.withAlpha(230),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 64),
                  const SizedBox(height: 16),
                  Text(context.l10n.panicWipeImminent,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text('$_remaining',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 96,
                          fontWeight: FontWeight.w300)),
                  const SizedBox(height: 12),
                  Text(context.l10n.panicTapToCancel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
