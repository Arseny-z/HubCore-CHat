import 'package:flutter/material.dart';

/// Reusable numeric PIN keypad (dark theme, same style as LockScreen).
class PinPad extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onDelete;

  const PinPad({super.key, required this.onDigit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(['1', '2', '3']),
        _row(['4', '5', '6']),
        _row(['7', '8', '9']),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 80 + 24),
            _DigitButton(label: '0', onTap: () => onDigit('0')),
            const SizedBox(width: 24),
            _DeleteButton(onTap: onDelete),
          ],
        ),
      ],
    );
  }

  Widget _row(List<String> digits) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < digits.length; i++) ...[
            if (i > 0) const SizedBox(width: 24),
            _DigitButton(label: digits[i], onTap: () => onDigit(digits[i])),
          ],
        ],
      ),
    );
  }
}

class _DigitButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _DigitButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80,
        height: 80,
        decoration: const BoxDecoration(
          color: Color(0xFF1C2733),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DeleteButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const SizedBox(
        width: 80,
        height: 80,
        child: Icon(Icons.backspace_outlined, color: Colors.white54, size: 28),
      ),
    );
  }
}

/// PIN dots indicator row.
class PinDots extends StatelessWidget {
  final int filled;
  final int total;

  const PinDots({super.key, required this.filled, this.total = 4});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i < filled;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? const Color(0xFF2AABEE) : Colors.transparent,
            border: Border.all(
              color: active ? const Color(0xFF2AABEE) : Colors.white38,
              width: 2,
            ),
          ),
        );
      }),
    );
  }
}
