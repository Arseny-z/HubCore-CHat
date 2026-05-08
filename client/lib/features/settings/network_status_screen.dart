import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/utils/l10n.dart';
import '../../shared/widgets/hubcore_app_bar.dart';
import '../../yggdrasil/yggdrasil_node.dart';

class NetworkStatusScreen extends ConsumerStatefulWidget {
  const NetworkStatusScreen({super.key});

  @override
  ConsumerState<NetworkStatusScreen> createState() => _NetworkStatusScreenState();
}

class _NetworkStatusScreenState extends ConsumerState<NetworkStatusScreen> {
  bool _loading = false;
  String? _yggAddr;
  String? _yggPubKey;
  int _listenPort = 0;
  List<YggPeerInfo> _peers = [];
  List<YggSessionInfo> _sessions = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() { _loading = true; });

    final addr       = await YggdrasilNode.address();
    final pubKey     = await YggdrasilNode.publicKey();
    final peers      = await YggdrasilNode.peers();
    final listenPort = await YggdrasilNode.listenPort();
    final sessions   = await YggdrasilNode.sessions();

    if (mounted) {
      setState(() {
        _yggAddr    = addr;
        _yggPubKey  = pubKey;
        _listenPort = listenPort;
        _peers      = peers;
        _sessions   = sessions;
        _loading    = false;
      });
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upPeers = _peers.where((p) => p.up).length;

    return Scaffold(
      appBar: HubCoreAppBar(
        title: Text(context.l10n.networkStatusTitle),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        children: [
          // ── Yggdrasil Node ───────────────────────────────────────────────
          _SectionHeader(context.l10n.yggdrasilNode),
          _StatusTile(
            icon: Icons.router,
            label: context.l10n.myAddress,
            value: _yggAddr ?? '—',
            ok: _yggAddr != null && _yggAddr!.isNotEmpty,
            monospace: true,
            onCopy: _yggAddr,
          ),
          _StatusTile(
            icon: Icons.key,
            label: context.l10n.nodePublicKey,
            value: _yggPubKey != null
                ? '${_yggPubKey!.substring(0, 16)}…'
                : '—',
            ok: _yggPubKey != null,
            monospace: true,
            onCopy: _yggPubKey,
          ),
          _StatusTile(
            icon: Icons.hearing,
            label: context.l10n.listeningInbound,
            value: _listenPort > 0 ? 'tls://0.0.0.0:$_listenPort' : '—',
            ok: _listenPort > 0,
            monospace: true,
          ),

          const Divider(height: 1),

          // ── Connected Peers ──────────────────────────────────────────────
          _SectionHeader(context.l10n.peersConnectedCount(upPeers, _peers.length)),
          if (_peers.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.l10n.noPeersConnected,
                  style: const TextStyle(color: Colors.white54)),
            ),
          ..._peers.map((p) {
            final latStr = p.latencyMs > 0
                ? '${p.latencyMs.toStringAsFixed(0)} ms'
                : '';
            final dir = p.inbound ? '↓ ${context.l10n.inbound}' : '↑ ${context.l10n.outbound}';
            final uri = p.uri.length > 50
                ? '…${p.uri.substring(p.uri.length - 47)}'
                : p.uri;
            // OPT-2: show cost if non-zero
            final costStr = p.cost > 0 ? ' · cost ${p.cost}' : '';
            final rxStr = p.rxBytes > 0 ? '↓${_fmtBytes(p.rxBytes)}' : '';
            final txStr = p.txBytes > 0 ? '↑${_fmtBytes(p.txBytes)}' : '';
            final trafficStr = [rxStr, txStr].where((s) => s.isNotEmpty).join(' ');
            return ListTile(
              dense: true,
              leading: Icon(
                p.up ? Icons.check_circle_outline : Icons.error_outline,
                color: p.up ? Colors.greenAccent : theme.colorScheme.error,
                size: 20,
              ),
              title: Text(
                uri,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [dir, if (latStr.isNotEmpty) latStr, if (p.lastError.isNotEmpty) p.lastError].join(' · ') + costStr,
                    style: TextStyle(
                      fontSize: 11,
                      color: p.up ? Colors.white54 : theme.colorScheme.error,
                    ),
                  ),
                  if (trafficStr.isNotEmpty)
                    Text(
                      trafficStr,
                      style: const TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                ],
              ),
              trailing: latStr.isNotEmpty
                  ? Text(latStr, style: const TextStyle(fontSize: 11, color: Colors.white38))
                  : null,
            );
          }),

          // ── Active Sessions ──────────────────────────────────────────────
          if (_sessions.isNotEmpty) ...[
            const Divider(height: 1),
            _SectionHeader(context.l10n.activeSessionsCount(_sessions.length)),
            ..._sessions.map((s) {
              final key = s.key.length > 16 ? '${s.key.substring(0, 16)}…' : s.key;
              final rx = _fmtBytes(s.rxBytes);
              final tx = _fmtBytes(s.txBytes);
              final uptime = s.uptime > 3600
                  ? '${(s.uptime / 3600).toStringAsFixed(1)}h'
                  : s.uptime > 60
                      ? '${(s.uptime / 60).toStringAsFixed(0)}m'
                      : '${s.uptime.toStringAsFixed(0)}s';
              return ListTile(
                dense: true,
                leading: const Icon(Icons.swap_horiz, size: 20, color: Colors.blue),
                title: Text(
                  key,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
                subtitle: Text(
                  '↓$rx ↑$tx · $uptime',
                  style: const TextStyle(fontSize: 11, color: Colors.white54),
                ),
              );
            }),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: const Color(0xFF2AABEE),
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool ok;
  final bool monospace;
  final String? onCopy;

  const _StatusTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.ok,
    this.monospace = false,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: ok ? Colors.greenAccent : Colors.white38),
      title: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      subtitle: Text(
        value,
        style: TextStyle(
          color: ok ? Colors.white : Colors.white38,
          fontFamily: monospace ? 'monospace' : null,
          fontSize: 13,
        ),
      ),
      trailing: onCopy != null
          ? IconButton(
              icon: const Icon(Icons.copy, size: 16, color: Colors.white38),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: onCopy!));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.l10n.copied),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            )
          : null,
    );
  }
}
