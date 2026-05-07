import 'dart:convert';
import 'dart:typed_data';

import '../../shared/utils/logger.dart';

/// Persisted ratchet session state for a contact.
class SessionRecord {
  final int? id;
  final int contactId;
  final Uint8List rootKey;
  final Uint8List sendChainKey;
  final Uint8List recvChainKey;
  final Uint8List myEphPub;
  final Uint8List myEphPriv;
  final Uint8List? peerEphPub;
  final int sendCounter;
  final int recvCounter;
  final int sendSinceRatchet;
  final int recvCounterInChain;
  final int recvChainIndex;

  /// Skipped message keys serialised as a JSON array:
  /// [{"ci": <chainIndex>, "ct": <counter>, "k": "<hex key>"}]
  ///
  /// Stored as TEXT so SQLCipher can encrypt them at the DB level.
  final String skippedKeysJson;

  final int updatedAt;
  final Uint8List? hmac;

  const SessionRecord({
    this.id,
    required this.contactId,
    required this.rootKey,
    required this.sendChainKey,
    required this.recvChainKey,
    required this.myEphPub,
    required this.myEphPriv,
    this.peerEphPub,
    required this.sendCounter,
    required this.recvCounter,
    required this.sendSinceRatchet,
    this.recvCounterInChain = 0,
    this.recvChainIndex = 0,
    this.skippedKeysJson = '[]',
    required this.updatedAt,
    this.hmac,
  });

  factory SessionRecord.fromMap(Map<String, dynamic> m) => SessionRecord(
        id: m['id'] as int?,
        contactId: m['contact_id'] as int,
        rootKey: m['root_key'] as Uint8List,
        sendChainKey: m['send_chain_key'] as Uint8List,
        recvChainKey: m['recv_chain_key'] as Uint8List,
        myEphPub: m['my_eph_pub'] as Uint8List,
        myEphPriv: m['my_eph_priv'] as Uint8List,
        peerEphPub: m['peer_eph_pub'] as Uint8List?,
        sendCounter: m['send_counter'] as int,
        recvCounter: m['recv_counter'] as int,
        sendSinceRatchet: m['send_since_ratchet'] as int,
        recvCounterInChain: (m['recv_counter_in_chain'] as int?) ?? 0,
        recvChainIndex: (m['recv_chain_index'] as int?) ?? 0,
        skippedKeysJson: (m['skipped_keys'] as String?) ?? '[]',
        updatedAt: m['updated_at'] as int,
        hmac: m['hmac'] as Uint8List?,
      );

  Map<String, dynamic> toMap() => {
        'contact_id': contactId,
        'root_key': rootKey,
        'send_chain_key': sendChainKey,
        'recv_chain_key': recvChainKey,
        'my_eph_pub': myEphPub,
        'my_eph_priv': myEphPriv,
        if (peerEphPub != null) 'peer_eph_pub': peerEphPub,
        'send_counter': sendCounter,
        'recv_counter': recvCounter,
        'send_since_ratchet': sendSinceRatchet,
        'recv_counter_in_chain': recvCounterInChain,
        'recv_chain_index': recvChainIndex,
        'skipped_keys': skippedKeysJson,
        'updated_at': updatedAt,
        if (hmac != null) 'hmac': hmac,
      };
}

/// Codec for the skipped-key map stored in SessionRecord.
class SkippedKeysCodec {
  /// Composite cache key (same encoding as DoubleRatchet._skippedCacheKey).
  static int cacheKey(int chainIndex, int counter) =>
      (chainIndex << 32) | (counter & 0xFFFFFFFF);

  static int chainIndexFromKey(int k) => k >> 32;
  static int counterFromKey(int k) => k & 0xFFFFFFFF;

  static String encode(Map<int, Uint8List> skipped, {Map<int, int>? createdAt}) {
    final list = skipped.entries.map((e) {
      return {
        'ci': chainIndexFromKey(e.key),
        'ct': counterFromKey(e.key),
        'k': e.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        if (createdAt != null && createdAt.containsKey(e.key))
          'ts': createdAt[e.key],
      };
    }).toList();
    return jsonEncode(list);
  }

  /// Decode skipped keys JSON, returning both keys and their creation timestamps.
  /// Keys without a 'ts' field get [fallbackTimestamp] (defaults to now).
  static ({Map<int, Uint8List> keys, Map<int, int> timestamps}) decodeWithTimestamps(
    String json, {
    int? fallbackTimestamp,
  }) {
    final now = fallbackTimestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    try {
      final list = jsonDecode(json) as List<dynamic>;
      final keys = <int, Uint8List>{};
      final timestamps = <int, int>{};
      for (final item in list) {
        final m = item as Map<String, dynamic>;
        final ci = m['ci'] as int;
        final ct = m['ct'] as int;
        final hexKey = m['k'] as String;
        final keyBytes = Uint8List(hexKey.length ~/ 2);
        for (var i = 0; i < keyBytes.length; i++) {
          keyBytes[i] = int.parse(hexKey.substring(i * 2, i * 2 + 2), radix: 16);
        }
        final ck = cacheKey(ci, ct);
        keys[ck] = keyBytes;
        timestamps[ck] = (m['ts'] as int?) ?? now;
      }
      return (keys: keys, timestamps: timestamps);
    } catch (e) {
      AppLogger.w('SkippedKeys', 'Failed to decode skipped_keys JSON: $e — returning empty');
      return (keys: <int, Uint8List>{}, timestamps: <int, int>{});
    }
  }

  static Map<int, Uint8List> decode(String json) {
    return decodeWithTimestamps(json).keys;
  }
}
