import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/app_providers.dart';
import '../../shared/providers/crypto_providers.dart'
    show kExtraYggPeersKey, yggPeersProvider;
import '../../shared/providers/transport_providers.dart';
import '../../shared/utils/l10n.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import '../../reticulum/reticulum_node.dart';
import '../../yggdrasil/yggdrasil_node.dart';

// ── Settings keys ─────────────────────────────────────────────────────────────

const kYggPeerModeEnabled  = 'ygg_peer_mode_enabled';
const kYggPeerModeWifiOnly = 'ygg_peer_mode_wifi_only';
const kYggPeerModePort     = 'ygg_peer_mode_port';
const kYggPeerDdnsProvider = 'ygg_peer_ddns_provider';
const kYggPeerDdnsDomain   = 'ygg_peer_ddns_domain';
const kYggPeerDdnsToken    = 'ygg_peer_ddns_token';

// ── Screen ────────────────────────────────────────────────────────────────────

class NetworkSettingsScreen extends ConsumerWidget {
  final String protocol;
  const NetworkSettingsScreen({super.key, required this.protocol});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = switch (protocol) {
      'yggdrasil' => 'Yggdrasil',
      'reticulum'  => 'Reticulum',
      'meshcore'   => 'Meshcore',
      _            => context.l10n.networkSettingsTitle,
    };

    return Scaffold(
      appBar: HubCoreAppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: Text('${context.l10n.networkSettingsTitle}: $title'),
      ),
      body: switch (protocol) {
        'yggdrasil' => const _YggdrasilSettings(),
        'reticulum'  => const _ReticulumSettings(),
        'meshcore'   => const _StubSettings(name: 'Meshcore'),
        _            => const _YggdrasilSettings(),
      },
    );
  }
}

// ── Yggdrasil settings ────────────────────────────────────────────────────────

class _YggdrasilSettings extends StatelessWidget {
  const _YggdrasilSettings();

  @override
  Widget build(BuildContext context) => ListView(
        children: [
          _SectionHeader(context.l10n.peersList),
          _YggPeersList(),
          const Divider(),
          _SectionHeader(context.l10n.trustedPeersOnly),
          _YggSecurityPanel(),
          const Divider(),
          _SectionHeader(context.l10n.publicPeerMode),
          _YggPeerModePanel(),
        ],
      );
}

// ── Settings keys: Reticulum ─────────────────────────────────────────────────

const kRnsTcpPeers    = 'rns_tcp_peers';     // comma-separated host:port
const kRnsAutoEnabled = 'rns_auto_enabled';  // 'true'/'false'
// kRnsYggPeersKey storage key is kRnsYggPeersKeyKey from reticulum_node.dart

// ── Reticulum settings ───────────────────────────────────────────────────────

class _ReticulumSettings extends ConsumerStatefulWidget {
  const _ReticulumSettings();

  @override
  ConsumerState<_ReticulumSettings> createState() => _ReticulumSettingsState();
}

class _ReticulumSettingsState extends ConsumerState<_ReticulumSettings> {
  List<String> _tcpPeers = [];
  List<String> _yggPeers = [];
  bool _autoEnabled = true;
  bool _running = false;
  String _address = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) { setState(() => _loading = false); return; }

    final peersStr    = await storage.settings.get(kRnsTcpPeers) ?? '';
    final yggPeersStr = await storage.settings.get(kRnsYggPeersKey) ?? '';
    final autoStr     = await storage.settings.get(kRnsAutoEnabled) ?? 'true';
    final running     = await ReticulumNode.isRunning();
    final addr        = running ? await ReticulumNode.address() : '';

    if (mounted) setState(() {
      _tcpPeers    = peersStr.isEmpty ? [] : peersStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      _yggPeers    = yggPeersStr.isEmpty ? [] : yggPeersStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      _autoEnabled  = autoStr != 'false';
      _running      = running;
      _address      = addr;
      _loading      = false;
    });
  }

  Future<void> _savePeers() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    await storage.settings.set(kRnsTcpPeers, _tcpPeers.join(','));
  }

  Future<void> _saveYggPeers() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    await storage.settings.set(kRnsYggPeersKey, _yggPeers.join(','));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final disabled = ref.watch(disabledTransportsProvider);
    final isEnabled = !disabled.contains('reticulum');

    return ListView(children: [
      // Enable/disable
      SwitchListTile(
        secondary: const Icon(Icons.router),
        title: const Text('Reticulum'),
        subtitle: Text(
          _running ? 'Работает · ${_address.isNotEmpty ? _address.substring(0, 8) : ""}…' : 'Отключён',
          style: TextStyle(fontSize: 12, color: _running ? Colors.green : Colors.white38),
        ),
        value: isEnabled,
        onChanged: (v) {
          ref.read(disabledTransportsProvider.notifier).toggle('reticulum');
          _saveDisabled(ref);
        },
      ),
      const Divider(),

      // AutoInterface
      _SectionHeader(context.l10n.wifiLanDiscovery),
      SwitchListTile(
        secondary: const Icon(Icons.wifi),
        title: Text(context.l10n.autoInterface),
        subtitle: Text(context.l10n.autoInterfaceDesc, style: const TextStyle(fontSize: 12)),
        value: _autoEnabled,
        onChanged: (v) async {
          setState(() => _autoEnabled = v);
          final storage = ref.read(storageProvider);
          if (storage.isOpen) {
            await storage.settings.set(kRnsAutoEnabled, v.toString());
          }
        },
      ),
      const Divider(),

      // TCP Peers
      _SectionHeader(context.l10n.tcpTransportNodes),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          context.l10n.tcpTransportDesc,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
      // Default (built-in) peers
      ...kReticulumDefaultPeers.map((peer) => ListTile(
        dense: true,
        leading: const Icon(Icons.lock_outline, size: 20, color: Colors.white38),
        title: Text(peer, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        subtitle: Text(context.l10n.builtIn, style: const TextStyle(fontSize: 11, color: Colors.white38)),
      )),
      // User-added peers
      ..._tcpPeers.map((peer) => ListTile(
        dense: true,
        leading: const Icon(Icons.dns_outlined, size: 20),
        title: Text(peer, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: () async {
            setState(() => _tcpPeers.remove(peer));
            await _savePeers();
          },
        ),
      )),
      ListTile(
        dense: true,
        leading: const Icon(Icons.add, size: 20),
        title: Text(context.l10n.addTransportNode),
        onTap: () async {
          final ctrl = TextEditingController();
          final result = await showDialog<String>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(context.l10n.rnsTransportNode),
              content: TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  hintText: context.l10n.addNodeHint,
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
                FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: Text(context.l10n.addTransportNode)),
              ],
            ),
          );
          if (result != null && result.isNotEmpty) {
            setState(() => _tcpPeers.add(result));
            await _savePeers();
          }
        },
      ),
      const Divider(),

      // Yggdrasil RNS nodes
      _SectionHeader(context.l10n.reticulumViaYgg),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          context.l10n.tcpTransportDesc,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
      // Default (built-in) Ygg peers
      ...kReticulumYggDefaultPeers.map((peer) => ListTile(
        dense: true,
        leading: const Icon(Icons.hub_outlined, size: 20, color: Colors.white38),
        title: Text(peer, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        subtitle: Text('${context.l10n.builtIn} · Yggdrasil', style: const TextStyle(fontSize: 11, color: Colors.white38)),
      )),
      // User-added Ygg peers
      ..._yggPeers.map((peer) => ListTile(
        dense: true,
        leading: const Icon(Icons.hub_outlined, size: 20),
        title: Text(peer, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          onPressed: () async {
            setState(() => _yggPeers.remove(peer));
            await _saveYggPeers();
          },
        ),
      )),
      ListTile(
        dense: true,
        leading: const Icon(Icons.add, size: 20),
        title: Text(context.l10n.addYggRnsNode),
        onTap: () async {
          final ctrl = TextEditingController();
          final result = await showDialog<String>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(context.l10n.reticulumViaYgg),
              content: TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  hintText: '[200:...]:4242',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
                FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: Text(context.l10n.addYggRnsNode)),
              ],
            ),
          );
          if (result != null && result.isNotEmpty) {
            setState(() => _yggPeers.add(result));
            await _saveYggPeers();
          }
        },
      ),
      const Divider(),

      // Restart button
      Padding(
        padding: const EdgeInsets.all(16),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.restartReticulum),
          onPressed: () async {
            setState(() => _loading = true);
            try {
              await ReticulumNode.stop();
              await Future.delayed(const Duration(milliseconds: 500));
              final allPeers = [...kReticulumDefaultPeers, ..._tcpPeers].join(',');
              await ReticulumNode.start(
                tcpPeers: allPeers,
                enableAuto: _autoEnabled,
              );
            } catch (_) {}
            await _load();
          },
        ),
      ),
    ]);
  }

  void _saveDisabled(WidgetRef ref) async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    final set = ref.read(disabledTransportsProvider);
    await storage.settings.set('disabled_transports', jsonEncode(set.toList()));
  }
}

// ── Stub for not-yet-implemented protocols ────────────────────────────────────

class _StubSettings extends StatelessWidget {
  final String name;
  const _StubSettings({required this.name});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            context.l10n.notImplementedYet(name),
            style: const TextStyle(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        ),
      );
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ── Yggdrasil Peers List ──────────────────────────────────────────────────────

class _YggPeersList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers   = ref.watch(yggPeersProvider);
    final storage = ref.watch(storageProvider);

    Future<void> savePeers() async {
      if (!storage.isOpen) return;
      final extra = ref.read(yggPeersProvider.notifier).extra;
      await storage.settings.set(kExtraYggPeersKey, jsonEncode(extra));
    }

    String uriWithoutQuery(String uri) {
      final i = uri.indexOf('?');
      return i < 0 ? uri : uri.substring(0, i);
    }

    String uriBase(String uri) => uriWithoutQuery(uri);

    return Column(
      children: [
        ...peers.map((uri) {
          final isBuiltIn = kYggdrasilDefaultPeers.any((p) =>
              uri == p || uri.startsWith('$p?') || uriBase(uri) == p);
          final parsedUri    = Uri.tryParse(uri);
          final priorityStr  = parsedUri?.queryParameters['priority'] ?? '';
          final hasPriority  = priorityStr.isNotEmpty;

          return ListTile(
            dense: true,
            leading: Icon(
              isBuiltIn ? Icons.lock_outline : Icons.dns_outlined,
              size: 20,
              color: isBuiltIn ? Colors.white38 : null,
            ),
            title: Text(
              uriWithoutQuery(uri),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
            subtitle: Row(
              children: [
                if (isBuiltIn)
                  Text(context.l10n.builtIn,
                      style: const TextStyle(fontSize: 11, color: Colors.white38)),
                if (hasPriority) ...[
                  if (isBuiltIn)
                    const Text(' · ', style: TextStyle(color: Colors.white38)),
                  Text('${context.l10n.priority} $priorityStr',
                      style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.low_priority, size: 18),
                  tooltip: context.l10n.priority,
                  color: hasPriority ? Colors.blue : Colors.white38,
                  onPressed: () async {
                    final ctrl = TextEditingController(text: priorityStr);
                    final result = await showDialog<String>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(context.l10n.peerPriority),
                        content: TextField(
                          controller: ctrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: context.l10n.notSet,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(context.l10n.cancel)),
                          FilledButton(
                              onPressed: () =>
                                  Navigator.pop(context, ctrl.text.trim()),
                              child: Text(context.l10n.save)),
                        ],
                      ),
                    );
                    if (result == null) return;
                    final notifier = ref.read(yggPeersProvider.notifier);
                    notifier.remove(uri);
                    final baseUri = uriWithoutQuery(uri);
                    final newUri =
                        result.isEmpty ? baseUri : '$baseUri?priority=$result';
                    notifier.add(newUri);
                    await savePeers();
                  },
                ),
                if (!isBuiltIn)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      ref.read(yggPeersProvider.notifier).remove(uri);
                      await savePeers();
                    },
                  ),
              ],
            ),
          );
        }),
        ListTile(
          dense: true,
          leading: const Icon(Icons.add, size: 20),
          title: Text(context.l10n.addPeer),
          onTap: () async {
            final ctrl = TextEditingController();
            final result = await showDialog<String>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(context.l10n.addYggPeer),
                content: TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    hintText: 'tls://example.com:443',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.l10n.cancel)),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                      child: Text(context.l10n.addPeer)),
                ],
              ),
            );
            if (result != null && result.isNotEmpty) {
              ref.read(yggPeersProvider.notifier).add(result);
              await savePeers();
            }
          },
        ),
      ],
    );
  }
}

// ── Yggdrasil Security Panel ──────────────────────────────────────────────────

class _YggSecurityPanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_YggSecurityPanel> createState() => _YggSecurityPanelState();
}

class _YggSecurityPanelState extends ConsumerState<_YggSecurityPanel> {
  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(storageProvider);

    return Column(
      children: [
        FutureBuilder<String?>(
          future: storage.isOpen
              ? storage.settings.get('ygg_allowed_pubkeys')
              : Future.value(null),
          builder: (context, snap) {
            final enabled = snap.data != null &&
                snap.data!.isNotEmpty &&
                snap.data != '[]';
            return SwitchListTile(
              secondary: const Icon(Icons.verified_user_outlined),
              title: Text(context.l10n.trustedPeersOnly),
              subtitle: Text(
                enabled
                    ? context.l10n.trustedPeersOnlyDesc
                    : context.l10n.allInboundAllowed,
                style: const TextStyle(fontSize: 12),
              ),
              value: enabled,
              onChanged: (v) async {
                if (!storage.isOpen) return;
                if (v) {
                  await storage.settings
                      .set('ygg_allowed_pubkeys_enabled', 'true');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l10n.trustedPeersModeOn)),
                    );
                  }
                } else {
                  await storage.settings.set('ygg_allowed_pubkeys_enabled', '');
                  await storage.settings.set('ygg_allowed_pubkeys', '');
                }
                setState(() {});
              },
            );
          },
        ),
        FutureBuilder<String?>(
          future: storage.isOpen
              ? storage.settings.get('ygg_multicast_pass')
              : Future.value(null),
          builder: (context, snap) {
            final pass = snap.data ?? '';
            return ListTile(
              leading: const Icon(Icons.password),
              title: Text(context.l10n.lanDiscoveryPassword),
              subtitle: Text(
                pass.isEmpty
                    ? context.l10n.openDiscovery
                    : context.l10n.protectedDiscovery,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.edit, size: 18),
              onTap: () async {
                final ctrl = TextEditingController(text: pass);
                final result = await showDialog<String>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(context.l10n.lanDiscoveryPasswordTitle),
                    content: TextField(
                      controller: ctrl,
                      decoration: InputDecoration(
                        hintText: context.l10n.openDiscoveryHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(context.l10n.cancel)),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, ctrl.text),
                          child: Text(context.l10n.save)),
                    ],
                  ),
                );
                if (result != null && storage.isOpen) {
                  await storage.settings.set('ygg_multicast_pass', result);
                  setState(() {});
                }
              },
            );
          },
        ),
      ],
    );
  }
}

// ── Ygg Peer Mode Panel ───────────────────────────────────────────────────────

class _YggPeerModePanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_YggPeerModePanel> createState() => _YggPeerModePanelState();
}

class _YggPeerModePanelState extends ConsumerState<_YggPeerModePanel> {
  bool   _enabled   = false;
  bool   _wifiOnly  = true;
  String _port      = '8362';
  String _provider  = 'duckdns';
  String _domain    = '';
  String _token     = '';
  String _peerAddr  = '';
  bool   _loading   = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) { setState(() => _loading = false); return; }
    final enabled  = await storage.settings.get(kYggPeerModeEnabled)  ?? '';
    final wifiOnly = await storage.settings.get(kYggPeerModeWifiOnly) ?? 'true';
    final port     = await storage.settings.get(kYggPeerModePort)     ?? '8362';
    final provider = await storage.settings.get(kYggPeerDdnsProvider) ?? 'duckdns';
    final domain   = await storage.settings.get(kYggPeerDdnsDomain)   ?? '';
    final token    = await storage.settings.get(kYggPeerDdnsToken)    ?? '';
    // Build current peer address
    final listenPort = await storage.settings.get(kYggPeerModePort) ?? port;
    final yggAddr    = await YggdrasilNode.address().catchError((_) => '');
    if (mounted) {
      setState(() {
        _enabled  = enabled == 'true';
        _wifiOnly = wifiOnly != 'false';
        _port     = port;
        _provider = provider;
        _domain   = domain;
        _token    = token;
        _peerAddr = domain.isNotEmpty
            ? 'tls://$domain:$listenPort'
            : (yggAddr ?? '').isNotEmpty
                ? 'tls://[${yggAddr ?? ''}]:$listenPort'
                : '';
        _loading  = false;
      });
    }
  }

  Future<void> _save() async {
    final storage = ref.read(storageProvider);
    if (!storage.isOpen) return;
    await storage.settings.set(kYggPeerModeEnabled,  _enabled.toString());
    await storage.settings.set(kYggPeerModeWifiOnly, _wifiOnly.toString());
    await storage.settings.set(kYggPeerModePort,     _port);
    await storage.settings.set(kYggPeerDdnsProvider, _provider);
    await storage.settings.set(kYggPeerDdnsDomain,   _domain);
    await storage.settings.set(kYggPeerDdnsToken,    _token);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Вкл/выкл
        SwitchListTile(
          secondary: const Icon(Icons.cell_tower),
          title: Text(context.l10n.publicPeerMode),
          subtitle: Text(
            context.l10n.publicPeerModeDesc,
            style: const TextStyle(fontSize: 12),
          ),
          value: _enabled,
          onChanged: (v) async {
            setState(() => _enabled = v);
            await _save();
          },
        ),

        if (_enabled) ...[
          // Только на WiFi
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: Text(context.l10n.wifiOnly),
            subtitle: Text(
              context.l10n.disableOnMobile,
              style: const TextStyle(fontSize: 12),
            ),
            value: _wifiOnly,
            onChanged: (v) async {
              setState(() => _wifiOnly = v);
              await _save();
            },
          ),

          // Порт
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: Text(context.l10n.port),
            subtitle: Text(_port, style: const TextStyle(fontFamily: 'monospace')),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () async {
              final ctrl = TextEditingController(text: _port);
              final result = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(context.l10n.port),
                  content: TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      hintText: '8362',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                        child: Text(context.l10n.save)),
                  ],
                ),
              );
              if (result != null && result.isNotEmpty) {
                setState(() => _port = result);
                await _save();
              }
            },
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(context.l10n.ddns,
                style: const TextStyle(color: Colors.white54, fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),

          // DDNS провайдер
          ListTile(
            leading: const Icon(Icons.dns),
            title: Text(context.l10n.ddnsProvider),
            subtitle: Text(_providerLabel(_provider)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showModalBottomSheet<String>(
                context: context,
                backgroundColor: const Color(0xFF182533),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (ctx) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    for (final p in ['duckdns', 'noip', 'custom'])
                      ListTile(
                        title: Text(_providerLabel(p),
                            style: const TextStyle(color: Colors.white)),
                        trailing: _provider == p
                            ? const Icon(Icons.check, color: Color(0xFF2AABEE))
                            : null,
                        onTap: () => Navigator.pop(ctx, p),
                      ),
                    const SizedBox(height: 8),
                  ],
                ),
              );
              if (result != null) {
                setState(() => _provider = result);
                await _save();
              }
            },
          ),

          // DDNS домен
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(context.l10n.ddnsDomain),
            subtitle: Text(
              _domain.isEmpty ? context.l10n.notSet : _domain,
              style: TextStyle(
                fontFamily: 'monospace',
                color: _domain.isEmpty ? Colors.white38 : null,
              ),
            ),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () async {
              final ctrl = TextEditingController(text: _domain);
              final hint = _provider == 'duckdns'
                  ? 'mynode.duckdns.org'
                  : _provider == 'noip'
                      ? 'mynode.hopto.org'
                      : 'example.com';
              final result = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(context.l10n.ddnsDomain),
                  content: TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      hintText: hint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                        child: Text(context.l10n.save)),
                  ],
                ),
              );
              if (result != null) {
                setState(() => _domain = result);
                await _save();
                await _load(); // обновить адрес пира
              }
            },
          ),

          // DDNS токен
          ListTile(
            leading: const Icon(Icons.key),
            title: Text(context.l10n.ddnsToken),
            subtitle: Text(
              _token.isEmpty ? context.l10n.notSet : '••••••••',
              style: TextStyle(color: _token.isEmpty ? Colors.white38 : null),
            ),
            trailing: const Icon(Icons.edit, size: 18),
            onTap: () async {
              final ctrl = TextEditingController(text: _token);
              final result = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(context.l10n.ddnsToken),
                  content: TextField(
                    controller: ctrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: context.l10n.ddnsToken,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.cancel)),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                        child: Text(context.l10n.save)),
                  ],
                ),
              );
              if (result != null) {
                setState(() => _token = result);
                await _save();
              }
            },
          ),

          // Текущий адрес пира
          if (_peerAddr.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.share, color: Color(0xFF52B8EA)),
              title: Text(context.l10n.peerAddress),
              subtitle: Text(
                _peerAddr,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Color(0xFF52B8EA)),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _peerAddr));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.addressCopied),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ),

          // Статус
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.peerModeHelp,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  static String _providerLabel(String p) {
    switch (p) {
      case 'duckdns': return 'DuckDNS (бесплатно)';
      case 'noip':    return 'No-IP';
      default:        return 'Custom';
    }
  }
}
