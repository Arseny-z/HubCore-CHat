import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Incoming message delivered via Reticulum transport.
class ReticulumMessage {
  /// Sender's destination hash as hex string (32 hex chars = 16 bytes).
  final String fromHashHex;
  final Uint8List data;

  /// Row id in incoming_raw.db if buffered while Flutter was inactive.
  final int? rawBufId;

  const ReticulumMessage({
    required this.fromHashHex,
    required this.data,
    this.rawBufId,
  });
}

/// Dart wrapper around the native Reticulum node (gomobile .aar via MethodChannel).
///
/// Mirrors [YggdrasilNode] API pattern — same MethodChannel/EventChannel architecture.
class ReticulumNode {
  static const _channel      = MethodChannel('hubcore/reticulum');
  static const _incoming     = EventChannel('hubcore/reticulum/incoming');
  static const _incomingRawChannel = MethodChannel('hubcore/incoming_raw');
  static const _connectivity = MethodChannel('hubcore/connectivity');
  static const _networkTypeChannel = EventChannel('hubcore/network_type');

  /// Stream of network type changes: "wifi" | "mobile" | "vpn" | "none".
  /// Emits the current type immediately on subscribe, then on each change.
  static final Stream<String> networkTypeStream = _networkTypeChannel
      .receiveBroadcastStream()
      .map((e) => e as String)
      .asBroadcastStream();

  /// Returns the current network type once.
  static Future<String> networkType() async =>
      await _connectivity.invokeMethod<String>('getNetworkType') ?? 'none';

  /// Stream of incoming messages from other Reticulum nodes.
  static final Stream<ReticulumMessage> messages = _incoming
      .receiveBroadcastStream()
      .map((event) {
        final m = Map<String, dynamic>.from(event as Map);
        return ReticulumMessage(
          fromHashHex: m['from'] as String,
          data: Uint8List.fromList((m['data'] as List).cast<int>()),
          rawBufId: m['raw_buf_id'] as int?,
        );
      })
      .asBroadcastStream();

  /// Acknowledge buffered packets — Kotlin deletes the rows from IncomingRawDb.
  static Future<void> ackBuffered(List<int> ids) async {
    if (ids.isEmpty) return;
    await _incomingRawChannel.invokeMethod('ackPackets', {
      'ids': ids,
      'transport': 'reticulum',
    });
  }

  /// Start the Reticulum foreground service.
  ///
  /// [configDir] and [identityPath] are created automatically if missing.
  /// [tcpPeers]: comma-separated "host:port" list of RNS transport nodes.
  ///   Include Yggdrasil fd00:: addresses for Ygg-over-RNS routing.
  /// [enableAuto]: enable AutoInterface (WiFi LAN mDNS peer discovery).
  /// [enableTransport]: relay packets for other nodes (battery-heavy).
  static Future<void> start({
    String configDir = '',
    String identityPath = '',
    String tcpPeers = '',
    bool enableAuto = true,
    bool enableTransport = false,
    String yggPeers = '',
  }) async {
    await _channel.invokeMethod('start', {
      'configDir': configDir,
      'identityPath': identityPath,
      'tcpPeers': tcpPeers,
      'enableAuto': enableAuto,
      'enableTransport': enableTransport,
      'yggPeers': yggPeers,
    });
  }

  /// Stop the Reticulum service.
  static Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  /// Returns our destination hash hex (32 chars = 16 bytes).
  /// This is the address peers use to send us messages.
  static Future<String> address() async {
    return await _channel.invokeMethod<String>('address') ?? '';
  }

  /// Returns our identity public key hex (128 chars = 64 bytes).
  static Future<String> publicKey() async {
    return await _channel.invokeMethod<String>('publicKey') ?? '';
  }

  /// Returns true if the RNS node is running.
  static Future<bool> isRunning() async {
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  /// Send [data] to a Reticulum destination identified by [destHash] (hex).
  /// Fragmentation for payloads > 374 bytes is handled by rnsbind.
  static Future<void> send({
    required String destHash,
    required Uint8List data,
  }) async {
    await _channel.invokeMethod('send', {
      'destHash': destHash,
      'data': data,
    });
  }

  /// Returns true if a path to [destHash] is known.
  static Future<bool> hasPath(String destHash) async {
    return await _channel.invokeMethod<bool>('hasPath', {
      'destHash': destHash,
    }) ?? false;
  }

  /// Request path discovery for [destHash].
  static Future<void> requestPath(String destHash) async {
    await _channel.invokeMethod('requestPath', {
      'destHash': destHash,
    });
  }

  /// Returns number of hops to [destHash], or -1 if unknown.
  static Future<int> hopsTo(String destHash) async {
    return await _channel.invokeMethod<int>('hopsTo', {
      'destHash': destHash,
    }) ?? -1;
  }

  /// Returns number of currently online RNS interfaces (connected TCP peers,
  /// AutoInterface peers, etc.). Returns 0 if not running.
  static Future<int> interfaceCount() async {
    return await _channel.invokeMethod<int>('interfaceCount') ?? 0;
  }

  /// Broadcast announce — makes our destination discoverable by peers.
  static Future<void> announce() async {
    await _channel.invokeMethod('announce');
  }
}

/// Storage key for user-added Yggdrasil-addressed RNS peers.
const kRnsYggPeersKey = 'rns_ygg_peers';

/// Reduced peer list for mobile/cellular networks.
/// Only the most stable clearnet nodes — saves battery and data.
/// No Yggdrasil bridges (Yggdrasil itself is battery-heavy on mobile).
const kReticulumMobilePeers = [
  '78.29.39.97:4242',     // Shadow Chelyabinsk — most stable
  '132.145.75.143:4242',  // Ether Whisperer
  'rns.artdaw.com:4242',  // Helsinki
];

/// Known RNS transport nodes reachable via Yggdrasil overlay.
/// These are NOT passed to TCP — they are used by the Ygg-RNS bridge
/// (RNS packets broadcast over Yggdrasil datagrams to all connected peers).
/// Stored here for display and future TUN-based routing.
const kReticulumYggDefaultPeers = [
  '[202:c6ff:5e33:94ca:512f:b192:36f3:1045]:4343', // Beleth RNS Hub
  '[200:3953:999b:282e:e526:bcd2:c329:31a]:4343',  // Beleth Yggdrasil
  '[201:e73a:61ee:ca68:4bc5:99d5:fd70:ded1]:4343', // Spaceman-ygg
  '[201:1160:3f65:28ea:22b2:efb:a3c0:e012]:9055',  // Triplebit Minneapolis
  '[200:cea:10:1b1:3c23:3bc:34c1:8c82]:4242',       // cea yggdrasil
  '[203:f54a:ffa2:650d:df9d:1473:5228:94dc]:43434', // kemerovo ygg
  '[200:73eb:2e4:14be:aac7:90b3:784b:71a3]:4242',   // rothbard ZA ygg
];

/// Default public RNS TCP transport nodes.
/// Used on first start when user has no custom peers configured.
const kReticulumDefaultPeers = [
  // Clearnet TCP / Backbone nodes
  '78.29.39.97:4242',           // Shadow Chelyabinsk
  'rns.beleth.net:4242',        // Beleth Clearnet
  'rns.noderage.org:4242',      // CRN
  '77.37.146.243:4242',         // Catz Node
  '132.145.75.143:4242',        // Ether Whisperer
  'rns.artdaw.com:4242',        // Helsinki
  'istanbul.reserve.network:9034', // R-Net
  'rmap.world:4242',            // RMAP

  // Yggdrasil overlay nodes — NOT usable on Android without a Yggdrasil TUN adapter.
  // The 200::/7 / 201::/7 / 202::/7 / 203::/7 address space only exists inside the
  // Yggdrasil Go library and is not exposed as a system network interface on Android.
  // Uncomment when Android Yggdrasil TUN support is added.
  //
  // '202:c6ff:5e33:94ca:512f:b192:36f3:1045:4343', // Beleth RNS Hub - Yggdrasil
  // '200:3953:999b:282e:e526:bcd2:c329:31a:4343',   // Beleth Yggdrasil
  // '201:e73a:61ee:ca68:4bc5:99d5:fd70:ded1:4343',  // Spaceman-ygg
  // '201:1160:3f65:28ea:22b2:efb:a3c0:e012:9055',   // Triplebit Minneapolis Backbone
  // '200:cea:10:1b1:3c23:3bc:34c1:8c82:4242',        // cea yggdrasil
  // '203:f54a:ffa2:650d:df9d:1473:5228:94dc:43434',  // kemerovo ygg
  // '200:73eb:2e4:14be:aac7:90b3:784b:71a3:4242',    // rothbard ZA ygg
];
