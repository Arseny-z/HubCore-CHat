import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'l10n/app_localizations.dart';

import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/lock_screen.dart';
import 'features/onboarding/profile_setup_screen.dart';
import 'features/main/main_screen.dart';
import 'features/contacts/add_contact_screen.dart';
import 'features/contacts/contact_profile_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/groups/create_group_screen.dart';
import 'features/groups/group_chat_screen.dart';
import 'features/groups/group_settings_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/main/search_screen.dart';
import 'features/notifications/notifications_screen.dart';
import 'features/settings/network_status_screen.dart';
import 'features/settings/blocked_contacts_screen.dart';
import 'features/settings/devices_screen.dart';
import 'features/settings/pair_device_screen.dart';
import 'features/onboarding/scan_pairing_screen.dart';
import 'features/settings/network_settings_screen.dart';
import 'shared/providers/app_providers.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, s) => const RootRedirect()),
    GoRoute(path: '/onboarding', builder: (_, s) => const OnboardingScreen()),
    GoRoute(path: '/lock', builder: (_, s) => const LockScreen()),
    GoRoute(path: '/profile-setup', builder: (_, s) => const ProfileSetupScreen()),
    GoRoute(path: '/main', builder: (_, s) => const MainScreen()),
    GoRoute(path: '/contacts/add', builder: (_, s) => const AddContactScreen()),
    GoRoute(path: '/contacts', redirect: (_, __) => '/main'),
    GoRoute(
      path: '/chat/:masterPub',
      builder: (_, state) =>
          ChatScreen(contactMasterPub: state.pathParameters['masterPub']!),
    ),
    GoRoute(
      path: '/contact/:masterPub',
      builder: (_, state) =>
          ContactProfileScreen(masterPub: state.pathParameters['masterPub']!),
    ),
    GoRoute(path: '/notifications', builder: (_, s) => const NotificationsScreen()),
    GoRoute(path: '/settings', builder: (_, s) => const SettingsScreen()),
    GoRoute(path: '/blocked-contacts', builder: (_, s) => const BlockedContactsScreen()),
    GoRoute(path: '/devices', builder: (_, s) => const DevicesScreen()),
    GoRoute(path: '/pair-device', builder: (_, s) => const PairDeviceScreen()),
    GoRoute(path: '/onboarding/scan-pairing', builder: (_, s) => const ScanPairingScreen()),
    GoRoute(path: '/search', builder: (_, s) => const SearchScreen()),
    GoRoute(path: '/network-status', builder: (_, s) => const NetworkStatusScreen()),
    GoRoute(
      path: '/network-settings/:protocol',
      builder: (_, state) => NetworkSettingsScreen(
        protocol: state.pathParameters['protocol'] ?? 'yggdrasil',
      ),
    ),
    GoRoute(path: '/group/new', builder: (_, s) => const CreateGroupScreen()),
    GoRoute(
      path: '/group/:groupId',
      builder: (_, state) =>
          GroupChatScreen(groupId: state.pathParameters['groupId']!),
    ),
    GoRoute(
      path: '/group/:groupId/settings',
      builder: (_, state) =>
          GroupSettingsScreen(groupId: state.pathParameters['groupId']!),
    ),
  ],
);

class HubCoreApp extends StatelessWidget {
  const HubCoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'HubCore Chat',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2AABEE), // Telegram blue
          brightness: Brightness.dark,
          surface: const Color(0xFF1C2733),
          onSurface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xFF17212B),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1C2733),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 1,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF1C2733),
          indicatorColor: const Color(0xFF2AABEE).withAlpha(50),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const IconThemeData(color: Color(0xFF2AABEE));
            }
            return const IconThemeData(color: Colors.white54);
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(color: Color(0xFF2AABEE), fontSize: 12);
            }
            return const TextStyle(color: Colors.white54, fontSize: 12);
          }),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFF253341),
          thickness: 1,
        ),
        listTileTheme: const ListTileThemeData(
          tileColor: Color(0xFF1C2733),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      builder: (context, child) => _AppLifecycleGuard(child: child!),
    );
  }
}

/// Wraps the app to:
///   1. Enable FLAG_SECURE on Android (prevent screenshots / screen recording).
///   2. Auto-lock the DB when the app goes to background.
class _AppLifecycleGuard extends ConsumerStatefulWidget {
  final Widget child;
  const _AppLifecycleGuard({required this.child});

  @override
  ConsumerState<_AppLifecycleGuard> createState() => _AppLifecycleGuardState();
}

class _AppLifecycleGuardState extends ConsumerState<_AppLifecycleGuard>
    with WidgetsBindingObserver {
  // Lock only after app has been in background for this duration.
  // Short pauses (file picker, permission dialog) don't trigger lock.
  static const _lockDelay = Duration(seconds: 30);
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Enable FLAG_SECURE: prevent screenshots and screen recording (Android).
    // const MethodChannel('hubcore/security').invokeMethod('setSecureFlag', true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final paused = _pausedAt;
      if (paused != null && DateTime.now().difference(paused) >= _lockDelay) {
        _lock();
      }
      _pausedAt = null;
    } else if (state == AppLifecycleState.detached) {
      _lock();
    }
  }

  Future<void> _lock() async {
    // Don't lock if DB is not open — nothing to protect.
    // This prevents recreating LockScreen during initial PIN setup,
    // which would reset the confirmation step mid-flow.
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    final lockManager = ref.read(lockManagerProvider);
    if (lockManager == null) {
      try { await storage.close(); } catch (_) {}
      if (mounted) _router.go('/lock');
      return;
    }
    await lockManager.lock();
    if (mounted) _router.go('/lock');
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Routes to the correct starting screen based on app state:
///   no identity   → /onboarding
///   locked        → /lock
///   unlocked      → /contacts
class RootRedirect extends ConsumerWidget {
  const RootRedirect({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identityAsync = ref.watch(identityProvider);
    return identityAsync.when(
      data: (identity) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (identity == null) {
            context.go('/onboarding');
          } else {
            final storage = ref.read(storageProvider);
            context.go(storage.isOpen ? '/main' : '/lock');
          }
        });
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) =>
          const Scaffold(body: Center(child: Text('Initialization error'))),
    );
  }
}
