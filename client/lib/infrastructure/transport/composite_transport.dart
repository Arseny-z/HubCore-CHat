import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../domain/ports/transport_port.dart';
import '../../domain/entities/envelope.dart';
import '../../shared/utils/logger.dart';
import 'yggdrasil_transport.dart'; // envelopeToBytes

/// Routes outgoing envelopes to the best available transport.
///
/// Priority (highest → lowest):
///   1. Yggdrasil P2P  — direct, low-latency, no server
///   2. Reticulum      — RNS over TCP/WiFi (LoRa/BLE planned)
///   3. Meshcore       — LoRa mesh (stub until implemented)

///
/// Tracks which transport last succeeded for each contact so subsequent
/// messages try the known-good path first (falls through to priority order
/// if the preferred transport fails).
///
/// ## Adding a new protocol
/// 1. Implement [TransportPort] in `infrastructure/transport/`
/// 2. Add it to the [_transports] list in [CompositeTransport] constructor
/// 3. Done — no other files need to change.
class CompositeTransport implements TransportPort {
  final List<TransportPort> _transports;

  /// Merged broadcast stream of all transports' incoming messages.
  /// Created once and reused — callers may subscribe multiple times safely.
  late final Stream<IncomingEnvelope> _incomingStream = _buildIncomingStream();

  /// Last successful transport per destination address (contact pubkey → protocol id).
  /// Used to try the known-good path first before falling through to priority order.
  /// LRU-bounded to prevent unbounded growth.
  static const _preferredMaxSize = 512;
  final _preferred = LinkedHashMap<String, String>();

  /// Per-protocol health: protocol id → consecutive failure count.
  /// Reset to 0 on success. Used to deprioritize flaky transports.
  final _failureCount = <String, int>{};

  CompositeTransport(this._transports);

  /// All registered transport IDs (for status reporting).
  List<String> get transportIds => _transports.map((t) => t.id).toList();

  Stream<IncomingEnvelope> _buildIncomingStream() {
    // Subscribe to individual transports only when first consumer joins.
    // This prevents IncomingRawDb drain messages from being dropped
    // between CompositeTransport creation and MessageRouter.start().
    final subs = <StreamSubscription<IncomingEnvelope>>[];
    late final StreamController<IncomingEnvelope> ctrl;
    ctrl = StreamController<IncomingEnvelope>.broadcast(
      onListen: () {
        if (subs.isNotEmpty) return;
        for (final t in _transports) {
          subs.add(t.incoming.listen(ctrl.add, onError: ctrl.addError));
        }
      },
    );
    return ctrl.stream;
  }

  @override
  String get id => 'composite';

  @override
  Future<bool> get isAvailable async => true; // always present

  /// Tries each transport in priority order. Returns after first success.
  /// If a preferred transport is known for the destination, tries it first.
  @override
  Future<void> send(Uint8List encryptedEnvelope, TransportAddress destination) async {
    final errors = <String>[];

    // Try preferred transport first if known and still in our list.
    final prefId = _preferred[destination.value];
    if (prefId != null) {
      final pref = _transports.where((t) => t.id == prefId).firstOrNull;
      if (pref != null) {
        try {
          if (await pref.isAvailable && await pref.canReach(destination)) {
            await pref.send(encryptedEnvelope, destination);
            _recordSuccess(destination.value, prefId);
            return;
          }
        } catch (e) {
          AppLogger.w('Composite', 'preferred $prefId failed: $e — trying others');
          errors.add('$prefId(pref): $e');
          _recordFailure(prefId);
        }
      }
    }

    // Fall through to priority order.
    for (final t in _transports) {
      if (t.id == prefId) continue; // already tried
      if (!await t.isAvailable) continue;
      if (!await t.canReach(destination)) continue;
      try {
        await t.send(encryptedEnvelope, destination);
        _recordSuccess(destination.value, t.id);
        return;
      } catch (e) {
        AppLogger.w('Composite', '${t.id} failed: $e — trying next');
        errors.add('${t.id}: $e');
        _recordFailure(t.id);
      }
    }

    final msg = errors.isEmpty
        ? 'no available transport for $destination'
        : 'all transports failed for $destination: $errors';
    AppLogger.w('Composite', msg);
    throw StateError(msg);
  }

  @override
  Future<bool> canReach(TransportAddress address) async {
    for (final t in _transports) {
      if (await t.isAvailable && await t.canReach(address)) return true;
    }
    return false;
  }

  @override
  Stream<IncomingEnvelope> get incoming => _incomingStream;

  @override
  Future<void> register(TransportAddress myAddress) async {
    for (final t in _transports) {
      await t.register(myAddress);
    }
  }

  @override
  void dispose() {
    for (final t in _transports) {
      t.dispose();
    }
  }

  // ── Health tracking ──────────────────────────────────────────────────────────

  void _recordSuccess(String contactKey, String protocolId) {
    _failureCount[protocolId] = 0;
    // Update preferred, maintain LRU bound.
    _preferred.remove(contactKey);
    _preferred[contactKey] = protocolId;
    while (_preferred.length > _preferredMaxSize) {
      _preferred.remove(_preferred.keys.first);
    }
  }

  void _recordFailure(String protocolId) {
    _failureCount[protocolId] = (_failureCount[protocolId] ?? 0) + 1;
  }

  /// Consecutive failures for a protocol. 0 = healthy.
  int failuresFor(String protocolId) => _failureCount[protocolId] ?? 0;

  /// Which transport last succeeded for [contactKey] (pubkey or address value).
  String? preferredTransport(String contactKey) => _preferred[contactKey];

  // ── Convenience: bridge to legacy Envelope API ────────────────────────────

  /// Send a legacy [Envelope] using all available transport addresses.
  ///
  /// [transportAddresses] maps protocol → address for the destination contact.
  /// Tries preferred transport first, then falls through in priority order.
  /// Returns [TransportResult] with protocol that succeeded.
  ///
  /// For backward compatibility [destYggPubKeyHex] is still accepted and merged
  /// into [transportAddresses] under the 'yggdrasil' key if not already present.
  Future<TransportResult> sendEnvelope(
    Envelope envelope, {
    Map<String, String>? transportAddresses,
    String? destYggPubKeyHex,
  }) async {
    // Build effective address map: merge legacy param into map
    final addrs = <String, String>{
      if (transportAddresses != null) ...transportAddresses,
    };
    if (destYggPubKeyHex != null &&
        destYggPubKeyHex.isNotEmpty &&
        !addrs.containsKey(TransportProtocol.yggdrasil)) {
      addrs[TransportProtocol.yggdrasil] = destYggPubKeyHex;
    }

    if (addrs.isEmpty) {
      return const TransportResult.failure('no transport addresses for contact');
    }

    final bytes = envelopeToBytes(envelope);
    final errors = <String>[];

    // Determine contact key for preferred transport lookup.
    final contactKey = envelope.to;

    // Try preferred transport first.
    final prefId = _preferred[contactKey];
    if (prefId != null && addrs.containsKey(prefId)) {
      final pref = _transports.where((t) => t.id == prefId).firstOrNull;
      if (pref != null) {
        final addr = addrs[prefId]!;
        final destination = TransportAddress(protocol: prefId, value: addr);
        try {
          if (await pref.isAvailable && await pref.canReach(destination)) {
            await pref.send(bytes, destination);
            _recordSuccess(contactKey, prefId);
            AppLogger.d('Composite', 'sent via $prefId (preferred)');
            return TransportResult.success(prefId);
          }
        } catch (e) {
          AppLogger.w('Composite', 'preferred $prefId failed: $e — trying others');
          errors.add('$prefId(pref): $e');
          _recordFailure(prefId);
        }
      }
    }

    // Fall through to priority order.
    for (final t in _transports) {
      if (t.id == prefId) continue; // already tried
      final addr = addrs[t.id];
      if (addr == null || addr.isEmpty) continue;
      if (!await t.isAvailable) continue;
      final destination = TransportAddress(protocol: t.id, value: addr);
      if (!await t.canReach(destination)) continue;
      try {
        await t.send(bytes, destination);
        _recordSuccess(contactKey, t.id);
        AppLogger.d('Composite', 'sent via ${t.id}');
        return TransportResult.success(t.id);
      } catch (e) {
        AppLogger.w('Composite', '${t.id} failed: $e — trying next');
        errors.add('${t.id}: $e');
        _recordFailure(t.id);
      }
    }

    AppLogger.w('Composite', 'all transports failed: $errors');
    return TransportResult.failure(errors.isEmpty
        ? 'no available transport for contact'
        : errors.join('; '));
  }
}
