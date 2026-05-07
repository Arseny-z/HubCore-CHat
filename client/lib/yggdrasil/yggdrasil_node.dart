import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Incoming message delivered via Yggdrasil P2P transport.
class YggdrasilMessage {
  /// Sender's Ed25519 public key as hex string.
  final String fromPubKeyHex;
  final Uint8List data;

  /// Row id in incoming_raw.db — non-null when message was buffered on disk
  /// (arrived while Flutter was inactive). Must be acked via [YggdrasilNode.ackBuffered]
  /// after successful processing so Kotlin can delete the row.
  final int? rawBufId;

  const YggdrasilMessage({
    required this.fromPubKeyHex,
    required this.data,
    this.rawBufId,
  });
}

/// Dart wrapper around the native Yggdrasil node (gomobile .aar via MethodChannel).
class YggdrasilNode {
  static const _channel  = MethodChannel('hubcore/yggdrasil');
  static const _incoming = EventChannel('hubcore/yggdrasil/incoming');

  static const _incomingRawChannel = MethodChannel('hubcore/incoming_raw');

  /// Stream of incoming P2P messages from other Yggdrasil nodes.
  ///
  /// Cached broadcast stream — safe to subscribe multiple times.
  static final Stream<YggdrasilMessage> messages = _incoming
      .receiveBroadcastStream()
      .map((event) {
        final m = Map<String, dynamic>.from(event as Map);
        return YggdrasilMessage(
          fromPubKeyHex: m['from'] as String,
          data: Uint8List.fromList((m['data'] as List).cast<int>()),
          rawBufId: m['raw_buf_id'] as int?,
        );
      })
      .asBroadcastStream();

  /// Acknowledge that buffered packets have been processed — Kotlin deletes the rows.
  ///
  /// [transport] selects which IncomingRawDb to delete from.
  /// Defaults to `'yggdrasil'` for backwards compatibility.
  static Future<void> ackBuffered(List<int> ids, {String transport = 'yggdrasil'}) async {
    if (ids.isEmpty) return;
    await _incomingRawChannel.invokeMethod('ackPackets', {
      'ids': ids,
      'transport': transport,
    });
  }

  /// Starts the Yggdrasil foreground service.
  ///
  /// [listenAddr]: address to accept inbound peer connections,
  ///   e.g. `"tls://0.0.0.0:0"` (OS picks port). Pass `""` to disable inbound
  ///   listening. Defaults to `"tls://0.0.0.0:0"`.
  ///
  /// [enableMulticast]: enable LAN peer discovery via IPv6 multicast.
  ///   Requires ACCESS_WIFI_STATE + CHANGE_NETWORK_STATE on Android.
  ///
  /// [allowedPubKeysJson]: JSON array of hex public keys allowed for inbound
  ///   peering. Pass `""` or `"[]"` to allow all (default).
  ///
  /// [multicastPass]: shared password for LAN multicast group. Only devices
  ///   with the same password will discover each other. Pass `""` for open LAN.
  ///
  /// [interfacePeersJson]: JSON map of interface→[uris] for interface-specific
  ///   peers, e.g. `'{"wlan0":["tls://192.168.1.5:8362"]}'`. Pass `""` to skip.
  static Future<void> start({
    required String privKeyHex,
    required List<String> peers,
    String listenAddr = 'tls://0.0.0.0:0',
    String allowedPubKeysJson = '',
    String interfacePeersJson = '',
  }) async {
    await _channel.invokeMethod('start', {
      'privKeyHex': privKeyHex,
      'peers': peers,
      'listenAddr': listenAddr,
      'allowedPubKeysJson': allowedPubKeysJson,
      'interfacePeersJson': interfacePeersJson,
    });
  }

  /// Stops the Yggdrasil foreground service.
  static Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  /// Returns the node's Yggdrasil IPv6 address or null if not running.
  static Future<String?> address() async {
    return await _channel.invokeMethod<String>('address');
  }

  /// Returns the node's Ed25519 public key as hex string.
  static Future<String?> publicKey() async {
    return await _channel.invokeMethod<String>('publicKey');
  }

  /// Returns the node's Ed25519 private key as 128-char hex string.
  static Future<String?> privateKey() async {
    return await _channel.invokeMethod<String>('privateKey');
  }

  /// Returns number of connected peers.
  static Future<int> peerCount() async {
    return await _channel.invokeMethod<int>('peerCount') ?? 0;
  }

  /// Returns detailed peer list as parsed JSON list.
  /// Each entry: {uri, up, inbound, key, uptime, latency_ms, last_error?}
  static Future<List<YggPeerInfo>> peers() async {
    final json = await _channel.invokeMethod<String>('peersJson') ?? '[]';
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => YggPeerInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Returns true if the node is running.
  static Future<bool> isRunning() async {
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  /// Returns the actual listen port (inbound peer connections).
  /// Returns 0 if not listening.
  static Future<int> listenPort() async {
    return await _channel.invokeMethod<int>('listenPort') ?? 0;
  }

  /// Returns routing tree entries as a list.
  static Future<List<YggTreeEntry>> tree() async {
    final json = await _channel.invokeMethod<String>('treeJson') ?? '[]';
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => YggTreeEntry.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Returns known paths to other nodes.
  static Future<List<YggPathEntry>> paths() async {
    final json = await _channel.invokeMethod<String>('pathsJson') ?? '[]';
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => YggPathEntry.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Returns active sessions (nodes currently exchanging data).
  static Future<List<YggSessionInfo>> sessions() async {
    final json = await _channel.invokeMethod<String>('sessionsJson') ?? '[]';
    final list = jsonDecode(json) as List<dynamic>;
    return list.map((e) => YggSessionInfo.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Dynamically add a peer URI to the running node.
  static Future<void> addPeer(String peerUri) async {
    await _channel.invokeMethod('addPeer', {'uri': peerUri});
  }

  /// Dynamically remove a peer URI from the running node.
  static Future<void> removePeer(String peerUri) async {
    await _channel.invokeMethod('removePeer', {'uri': peerUri});
  }

  /// Send [data] directly to a peer identified by their Ed25519 public key (hex).
  /// Throws [PlatformException] if the peer is unreachable.
  static Future<void> send({
    required String destPubKeyHex,
    required Uint8List data,
  }) async {
    await _channel.invokeMethod('send', {
      'destPubKeyHex': destPubKeyHex,
      'data': data,
    });
  }
}

/// Peer info returned by [YggdrasilNode.peers].
class YggPeerInfo {
  final String uri;
  final bool up;
  final bool inbound;
  final String key;
  final double uptime;    // seconds
  final double latencyMs; // milliseconds, 0 if unknown
  final String lastError;
  final int rxBytes;
  final int txBytes;
  final int rxRate;       // bytes/sec
  final int txRate;       // bytes/sec
  final int cost;
  final int priority;

  const YggPeerInfo({
    required this.uri,
    required this.up,
    required this.inbound,
    required this.key,
    required this.uptime,
    required this.latencyMs,
    required this.lastError,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.rxRate = 0,
    this.txRate = 0,
    this.cost = 0,
    this.priority = 0,
  });

  factory YggPeerInfo.fromJson(Map<String, dynamic> j) => YggPeerInfo(
    uri:       j['uri'] as String? ?? '',
    up:        j['up'] as bool? ?? false,
    inbound:   j['inbound'] as bool? ?? false,
    key:       j['key'] as String? ?? '',
    uptime:    (j['uptime'] as num?)?.toDouble() ?? 0,
    latencyMs: (j['latency_ms'] as num?)?.toDouble() ?? 0,
    lastError: j['last_error'] as String? ?? '',
    rxBytes:   (j['rx_bytes'] as num?)?.toInt() ?? 0,
    txBytes:   (j['tx_bytes'] as num?)?.toInt() ?? 0,
    rxRate:    (j['rx_rate'] as num?)?.toInt() ?? 0,
    txRate:    (j['tx_rate'] as num?)?.toInt() ?? 0,
    cost:      (j['cost'] as num?)?.toInt() ?? 0,
    priority:  (j['priority'] as num?)?.toInt() ?? 0,
  );
}

/// Routing tree entry returned by [YggdrasilNode.tree].
class YggTreeEntry {
  final String key;
  final String parent;
  final int sequence;

  const YggTreeEntry({required this.key, required this.parent, required this.sequence});

  factory YggTreeEntry.fromJson(Map<String, dynamic> j) => YggTreeEntry(
    key:      j['key'] as String? ?? '',
    parent:   j['parent'] as String? ?? '',
    sequence: (j['sequence'] as num?)?.toInt() ?? 0,
  );
}

/// Known path entry returned by [YggdrasilNode.paths].
class YggPathEntry {
  final String key;
  final int sequence;
  final List<int> path;

  const YggPathEntry({required this.key, required this.sequence, required this.path});

  factory YggPathEntry.fromJson(Map<String, dynamic> j) => YggPathEntry(
    key:      j['key'] as String? ?? '',
    sequence: (j['sequence'] as num?)?.toInt() ?? 0,
    path:     (j['path'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [],
  );
}

/// Active session info returned by [YggdrasilNode.sessions].
class YggSessionInfo {
  final String key;
  final int rxBytes;
  final int txBytes;
  final double uptime; // seconds

  const YggSessionInfo({required this.key, required this.rxBytes, required this.txBytes, required this.uptime});

  factory YggSessionInfo.fromJson(Map<String, dynamic> j) => YggSessionInfo(
    key:     j['key'] as String? ?? '',
    rxBytes: (j['rx_bytes'] as num?)?.toInt() ?? 0,
    txBytes: (j['tx_bytes'] as num?)?.toInt() ?? 0,
    uptime:  (j['uptime'] as num?)?.toDouble() ?? 0,
  );
}

/// Built-in public Yggdrasil peers (read-only, cannot be removed by user).
/// IP-address peers are listed first — Android 10 Go DNS resolver does not
/// work with system DNS, so hostname peers fail on that platform.
const kYggdrasilDefaultPeers = [
  // Russia — TLS by IP (works on Android 10 where Go DNS fails)
  'tls://95.165.105.90:8362',    // ygg-msk-1.averyan.ru
  'tls://92.248.252.139:7992',   // ekb.itrus.su
  'tls://193.169.53.222:7992',   // srv.itrus.su
  'tls://45.147.200.202:443',
  'tls://45.142.208.198:9003',   // ip4.01.msk.ru.dioni.su
  // Russia — QUIC by IP
  'quic://95.165.105.90:8362',   // ygg-msk-1.averyan.ru
  'quic://92.248.252.139:7992',  // ekb.itrus.su
  // Russia — TLS by hostname (fallback for newer Android)
  'tls://ygg-msk-1.averyan.ru:8362',
  'tls://ekb.itrus.su:7992',
  'tls://srv.itrus.su:7992',
  'tls://ip4.01.msk.ru.dioni.su:9003',
  // Russia — QUIC by hostname
  'quic://ygg-msk-1.averyan.ru:8362',
  'quic://ekb.itrus.su:7992',
];

/// @deprecated Use [kYggdrasilDefaultPeers].
const kYggdrasilPeersRu = kYggdrasilDefaultPeers;
