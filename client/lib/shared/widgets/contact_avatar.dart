import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/avatar_providers.dart';

// ── Deterministic avatar generation ──────────────────────────────────────────

/// 12 gradient pairs — each is (topLeft color, bottomRight color).
const _kGradients = [
  [Color(0xFF4158D0), Color(0xFFC850C0)],
  [Color(0xFF0093E9), Color(0xFF80D0C7)],
  [Color(0xFF8EC5FC), Color(0xFFE0C3FC)],
  [Color(0xFF00DBDE), Color(0xFFFC00FF)],
  [Color(0xFFFF3CAC), Color(0xFF784BA0)],
  [Color(0xFFF7971E), Color(0xFFFFD200)],
  [Color(0xFF11998E), Color(0xFF38EF7D)],
  [Color(0xFFFC354C), Color(0xFF9500AF)],
  [Color(0xFF1FA2FF), Color(0xFF12D8FA)],
  [Color(0xFFFF416C), Color(0xFFFF4B2B)],
  [Color(0xFF56CCF2), Color(0xFF2F80ED)],
  [Color(0xFF43E97B), Color(0xFF38F9D7)],
];

/// Picks a gradient pair deterministically from [masterPub].
List<Color> _gradientFor(String masterPub) {
  if (masterPub.isEmpty) return _kGradients[0];
  int seed = 0;
  for (int i = 0; i < masterPub.length && i < 8; i++) {
    seed = (seed * 31 + masterPub.codeUnitAt(i)) & 0xFFFFFF;
  }
  return _kGradients[seed % _kGradients.length];
}

/// Generates 5 random-ish floats in [0,1] from [masterPub] for pattern drawing.
List<double> _patternSeeds(String masterPub) {
  final seeds = <double>[];
  int h = 2166136261;
  for (int i = 0; i < masterPub.length; i++) {
    h ^= masterPub.codeUnitAt(i);
    h = (h * 16777619) & 0xFFFFFFFF;
  }
  for (int i = 0; i < 5; i++) {
    h = (h ^ (h >> 16)) & 0xFFFFFFFF;
    h = (h * 0x45d9f3b) & 0xFFFFFFFF;
    h = (h ^ (h >> 16)) & 0xFFFFFFFF;
    seeds.add((h & 0xFFFF) / 0xFFFF);
  }
  return seeds;
}

/// Draws a gradient circle with a soft geometric pattern.
class _GeneratedAvatarPainter extends CustomPainter {
  final String masterPub;
  final String initial;

  const _GeneratedAvatarPainter({required this.masterPub, required this.initial});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);
    final colors = _gradientFor(masterPub);
    final seeds = _patternSeeds(masterPub);

    // Clip to circle
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));

    // Gradient background
    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, bgPaint);

    // Subtle arc pattern
    final arcPaint = Paint()
      ..color = Colors.white.withOpacity(0.12)
      ..style = PaintingStyle.fill;

    final angle1 = seeds[0] * math.pi * 2;
    final angle2 = angle1 + math.pi * (0.5 + seeds[1] * 0.8);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(r * 0.4, r * 0.35), radius: r * 1.1),
      angle1, angle2 - angle1, true, arcPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(r * 1.6, r * 1.65), radius: r * 0.9),
      angle1 + math.pi, angle2 - angle1, true, arcPaint,
    );

    // Small accent circle
    canvas.drawCircle(
      Offset(r + seeds[2] * r * 0.4 - r * 0.2, r * 0.3 + seeds[3] * r * 0.2),
      r * (0.15 + seeds[4] * 0.1),
      Paint()..color = Colors.white.withOpacity(0.15),
    );
  }

  @override
  bool shouldRepaint(_GeneratedAvatarPainter old) =>
      old.masterPub != masterPub || old.initial != initial;
}

/// A generated avatar widget — gradient + geometric pattern, no photo needed.
class GeneratedAvatar extends StatelessWidget {
  final String masterPub;
  final String name;
  final double radius;

  const GeneratedAvatar({
    super.key,
    required this.masterPub,
    required this.name,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final size = radius * 2;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _GeneratedAvatarPainter(masterPub: masterPub, initial: initial),
          ),
          Text(
            initial,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: radius * 0.72,
              shadows: const [
                Shadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── ContactAvatar ─────────────────────────────────────────────────────────────

Color avatarColor(String name) {
  final colors = _kGradients.map((g) => g[0]).toList();
  final idx = name.isEmpty ? 0 : name.codeUnitAt(0) % colors.length;
  return colors[idx];
}

/// Circular avatar for a contact.
///
/// Shows photo if one has been received/set. Falls back to a deterministic
/// gradient avatar generated from [masterPub] — unique per contact, no files needed.
class ContactAvatar extends ConsumerWidget {
  final String name;
  final String masterPub;
  final double radius;

  const ContactAvatar({
    super.key,
    required this.name,
    required this.masterPub,
    this.radius = 26,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(avatarVersionProvider(masterPub));
    final file = ref.watch(avatarFileProvider(masterPub));

    final hasPhoto = file != null && file.existsSync();

    final Widget avatar = hasPhoto
        ? ClipOval(
            child: Image.file(
              file,
              key: ValueKey(version),
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
            ),
          )
        : ClipOval(
            child: GeneratedAvatar(
              masterPub: masterPub,
              name: name,
              radius: radius,
            ),
          );

    return Hero(tag: 'avatar_$masterPub', child: avatar);
  }
}
