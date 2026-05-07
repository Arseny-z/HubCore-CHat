import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/utils/l10n.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _generating = false;

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      final sodium = await ref.read(sodiumProvider.future);
      await ref.read(identityNotifierProvider.notifier).generate(sodium);
      if (mounted) context.go('/lock');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Use CustomScrollView + SliverFillRemaining so the layout keeps spacing
    // when keyboard is closed, but scrolls gracefully when keyboard is open.
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  children: [
                    const Spacer(flex: 2),

                    // ── Logo ────────────────────────────────────────────────
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2AABEE),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(Icons.lock_outline, color: Colors.white, size: 52),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'HubCore Chat',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.onboardingSubtitle,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.white60,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const Spacer(flex: 2),

                    // ── Feature list ────────────────────────────────────────
                    _FeatureTile(
                      icon: Icons.enhanced_encryption_outlined,
                      title: context.l10n.featureE2eTitle,
                      subtitle: context.l10n.featureE2eSubtitle,
                    ),
                    const SizedBox(height: 12),
                    _FeatureTile(
                      icon: Icons.hub_outlined,
                      title: context.l10n.featureP2pTitle,
                      subtitle: context.l10n.featureP2pSubtitle,
                    ),
                    const SizedBox(height: 12),
                    _FeatureTile(
                      icon: Icons.no_accounts_outlined,
                      title: context.l10n.featureNoRegTitle,
                      subtitle: context.l10n.featureNoRegSubtitle,
                    ),

                    const Spacer(flex: 2),

                    // ── Action ───────────────────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _generating ? null : _generate,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        child: _generating
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(context.l10n.createIdentity),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _generating
                            ? null
                            : () => context.push('/onboarding/scan-pairing'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          side: const BorderSide(color: Colors.white38),
                          foregroundColor: Colors.white70,
                        ),
                        child: const Text('Войти с другого устройства'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.keyLocalWarning,
                      style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF2AABEE).withAlpha(30),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: const Color(0xFF2AABEE), size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
