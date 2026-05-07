import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/ports/transport_port.dart';
import '../../domain/entities/envelope.dart';
import '../../shared/utils/logger.dart';
import '../../yggdrasil/yggdrasil_node.dart';

/// Delivers envelopes directly over the Yggdrasil overlay network (fd00::/8).
///
/// Addresses use [TransportProtocol.yggdrasil]; [TransportAddress.value] is
/// the recipient's Ed25519 public key in hex (same key used to derive the
/// fd00:: address).
class YggdrasilTransport implements TransportPort {
  @override
  String get id => TransportProtocol.yggdrasil;

  @override
  Future<bool> get isAvailable => YggdrasilNode.isRunning();

  @override
  Future<bool> canReach(TransportAddress address) async {
    if (address.protocol != TransportProtocol.yggdrasil) return false;
    if (!(await YggdrasilNode.isRunning())) return false;
    // Optimistic: we have the address, assume reachable.
    // A real TCP-ping can be added here later (Phase 8 todo).
    return address.value.isNotEmpty;
  }

  @override
  Future<void> send(Uint8List encryptedEnvelope, TransportAddress destination) async {
    if (destination.protocol != TransportProtocol.yggdrasil) {
      throw ArgumentError('YggdrasilTransport cannot send to ${destination.protocol}');
    }
    // Adaptive timeout: 5s base + 1s per 64KB for large payloads.
    final timeoutSec = 5 + (encryptedEnvelope.length ~/ (64 * 1024));
    await YggdrasilNode.send(
      destPubKeyHex: destination.value,
      data: encryptedEnvelope,
    ).timeout(Duration(seconds: timeoutSec));
    AppLogger.d('Ygg', 'sent ${encryptedEnvelope.length}b to ${destination.value.substring(0, 8)}…');
  }

  @override
  Stream<IncomingEnvelope> get incoming => YggdrasilNode.messages.map(
        (msg) => IncomingEnvelope(
          data: msg.data,
          from: TransportAddress(
            protocol: TransportProtocol.yggdrasil,
            value: msg.fromPubKeyHex,
          ),
          rawBufId: msg.rawBufId,
        ),
      );

  // No registration needed — Yggdrasil address is derived from the node key.
  @override
  Future<void> register(TransportAddress myAddress) async {}

  @override
  void dispose() {}
}

/// Helper: wrap a legacy [Envelope] JSON into bytes for [YggdrasilTransport.send].
Uint8List envelopeToBytes(Envelope envelope) =>
    Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson())));
