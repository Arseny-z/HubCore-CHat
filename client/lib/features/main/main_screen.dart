import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';


import 'chats_screen.dart';
import 'contacts_tab.dart';
import 'profile_tab.dart';
import '../settings/settings_screen.dart';
import '../../application/events/app_event_bus.dart';
import '../../infrastructure/notifications/notification_service.dart';
import '../../shared/providers/app_providers.dart';
import '../../shared/providers/avatar_providers.dart';
import '../../shared/providers/yggdrasil_controller.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/utils/logger.dart';
import '../../reticulum/reticulum_node.dart';
import '../../yggdrasil/yggdrasil_node.dart';

const _batteryChannel = MethodChannel('hubcore/battery');

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _tab = 0;

  final _chatsKey    = GlobalKey<ChatsScreenState>();
  final _contactsKey = GlobalKey<ContactsTabState>();
  late final AppLifecycleListener _lifecycleListener;

  String _lastNetworkType = '';

  /// When app went to background (for auto-lock timeout).
  DateTime? _pausedAt;
  static const _autoLockTimeout = Duration(minutes: 5);

  /// Timestamp of first back-press on the Chats tab (for double-tap exit).
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();
    ref.read(connectivityWatcherProvider);
    ref.read(yggdrasilControllerProvider).start();
    ref.read(avatarRefresherProvider);
    _startReticulum();
    _initPermissionsSequentially();
    _lifecycleListener = AppLifecycleListener(
      onStateChange: _onAppLifecycleChanged,
    );

    // React to network type changes (WiFi ↔ mobile).
    ReticulumNode.networkTypeStream.listen(_onNetworkTypeChanged);
  }

  void _onNetworkTypeChanged(String type) {
    if (type == _lastNetworkType) return;
    final prev = _lastNetworkType;
    _lastNetworkType = type;
    if (prev.isEmpty) return; // first emission — already started with correct peers
    AppLogger.d('Main', 'Network type changed: $prev → $type — restarting Reticulum');
    _restartReticulum();
  }

  Future<void> _restartReticulum() async {
    try {
      await ReticulumNode.stop();
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (_) {}
    await _startReticulum();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// Request all permissions sequentially to avoid PlatformException
  /// "permissionRequestInProgress" from concurrent permission dialogs.
  Future<void> _initPermissionsSequentially() async {
    // Step 1: notification permission (Android 13+)
    try {
      await NotificationService().init();
    } catch (e) {
      AppLogger.w('Main', 'notification init failed', error: e);
    }
    // Step 2: battery optimization — after notification dialog dismissed
    await _requestBatteryOptimizationExclusion();
  }

  /// Ask Android to exclude this app from Doze battery optimization.
  /// Without this, Doze can freeze Yggdrasil TCP connections after ~1h idle.
  /// Only asks once — stores a flag in settings to avoid repeated prompts.
  Future<void> _requestBatteryOptimizationExclusion() async {
    try {
      final storage = ref.read(storageProvider);
      if (!storage.isOpen) return;
      final asked = await storage.settings.get('battery_opt_asked');
      if (asked == '1') return;

      final isIgnoring = await _batteryChannel.invokeMethod<bool>('isIgnoring') ?? false;
      if (!isIgnoring) {
        await _batteryChannel.invokeMethod('requestIgnore');
      }
      await storage.settings.set('battery_opt_asked', '1');
    } catch (e) {
      AppLogger.w('Battery', 'battery optimization request failed', error: e);
    }
  }

  /// Start Reticulum node — peer list adapts to current network type.
  ///
  /// WiFi:    all 8 clearnet nodes + 7 Yggdrasil bridges
  /// Mobile:  3 most reliable clearnet nodes only (saves battery + data)
  Future<void> _startReticulum() async {
    try {
      final disabled = ref.read(disabledTransportsProvider);
      if (disabled.contains('reticulum')) return;

      final running = await ReticulumNode.isRunning();
      if (running) return;

      final storage = ref.read(storageProvider);
      final extraPeers = storage.isOpen
          ? (await storage.settings.get('rns_tcp_peers') ?? '')
          : '';
      final autoStr = storage.isOpen
          ? (await storage.settings.get('rns_auto_enabled') ?? 'true')
          : 'true';

      // Detect network type — choose peers accordingly.
      final netType = await ReticulumNode.networkType();
      if (_lastNetworkType.isEmpty) _lastNetworkType = netType;
      final isMobile = netType == 'mobile';

      final clearnetPeers = isMobile
          ? kReticulumMobilePeers          // 3 stable nodes on cellular
          : kReticulumDefaultPeers;        // all 8 on WiFi

      final allPeers = [
        ...clearnetPeers,
        ...extraPeers.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      ].join(',');

      // Ygg bridges: only on WiFi (Yggdrasil is battery-heavy on cellular)
      String allYggPeers = '';
      if (!isMobile) {
        final yggPeersStr = storage.isOpen
            ? (await storage.settings.get(kRnsYggPeersKey) ?? '')
            : '';
        allYggPeers = [
          ...kReticulumYggDefaultPeers,
          ...yggPeersStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
        ].join(',');
      }

      await ReticulumNode.start(
        tcpPeers: allPeers,
        enableAuto: autoStr != 'false',
        yggPeers: allYggPeers,
      );
      AppLogger.d('Main',
          'Reticulum started [$netType] (${isMobile ? "mobile" : "wifi"} peers=${allPeers.split(",").length})');
    } catch (e) {
      AppLogger.w('Main', 'Reticulum start failed', error: e);
      ref.read(eventBusProvider).emit(ErrorEvent(
        source: 'Reticulum',
        code: ErrorEventCode.reticulumStartFailed,
        details: e.toString(),
        severity: ErrorSeverity.error,
      ));
    }
  }

  /// Switch to best 1-2 peers when going to background (saves battery).
  /// Restores all peers when coming back to foreground.
  Future<void> _onAppLifecycleChanged(AppLifecycleState state) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;

    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();

      // Background: use only top-2 peers to reduce keepalive traffic.
      final bestJson = await storage.settings.get('ygg_best_peers');
      if (bestJson == null || bestJson.isEmpty) return;
      try {
        final best = (jsonDecode(bestJson) as List).cast<String>();
        final all  = ref.read(yggPeersProvider);
        for (final peer in all) {
          if (!best.contains(peer)) {
            try { await YggdrasilNode.removePeer(peer); } catch (_) {}
          }
        }
        AppLogger.d('Ygg', 'background mode: using ${best.length} best peer(s)');
      } catch (e) {
        AppLogger.w('Ygg', 'background peer switch failed', error: e);
      }
    } else if (state == AppLifecycleState.resumed) {
      // Auto-lock: if app was in background longer than timeout → lock DB
      final paused = _pausedAt;
      _pausedAt = null;
      if (paused != null) {
        final elapsed = DateTime.now().difference(paused);
        if (elapsed >= _autoLockTimeout) {
          AppLogger.d('Main', 'auto-lock: ${elapsed.inMinutes}min in background → locking DB');
          await storage.close();
          if (mounted) context.go('/lock');
          return;
        }
      }

      // Foreground: restore all peers for reliable routing.
      final all = ref.read(yggPeersProvider);
      for (final peer in all) {
        try { await YggdrasilNode.addPeer(peer); } catch (_) {}
      }
      AppLogger.d('Ygg', 'foreground mode: restored ${all.length} peer(s)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      ChatsScreen(key: _chatsKey),
      ContactsTab(key: _contactsKey),
      const ProfileTab(),
      const SettingsScreen(),
    ];

    return PopScope(
      canPop: false, // we handle back ourselves
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab != 0) {
          // Not on Chats tab → go to Chats
          setState(() => _tab = 0);
          return;
        }
        // On Chats tab — double-tap exit
        final now = DateTime.now();
        if (_lastBackPress != null &&
            now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
          SystemNavigator.pop(); // minimize / exit
        } else {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.pressAgainToExit),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      child: Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              heroTag: 'fab_chats',
              onPressed: () => context
                  .push('/contacts/add')
                  .then((_) => _chatsKey.currentState?.load()),
              tooltip: 'New chat',
              child: const Icon(Icons.edit_outlined),
            )
          : _tab == 1
              ? FloatingActionButton(
                  heroTag: 'fab_contacts',
                  onPressed: () => context.push('/contacts/add').then((_) {
                    _contactsKey.currentState?.load();
                    _chatsKey.currentState?.load();
                  }),
                  tooltip: 'Add contact',
                  child: const Icon(Icons.person_add),
                )
              : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: context.l10n.tabChats,
          ),
          NavigationDestination(
            icon: const Icon(Icons.people_outline),
            selectedIcon: const Icon(Icons.people),
            label: context.l10n.tabContacts,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline),
            selectedIcon: const Icon(Icons.person),
            label: context.l10n.tabProfile,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: context.l10n.tabSettings,
          ),
        ],
      ),
      ), // Scaffold
    ); // PopScope
  }
}
