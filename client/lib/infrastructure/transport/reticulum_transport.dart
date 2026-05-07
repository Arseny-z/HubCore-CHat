import 'dart:async';
import 'dart:typed_data';

import '../../domain/ports/transport_port.dart';
import '../../reticulum/reticulum_node.dart';
import '../../shared/utils/logger.dart';

/// Delivers envelopes via the Reticulum Network Stack.
///
/// Reticulum works over any physical medium: LoRa, WiFi, BLE, Serial, Internet.
/// It handles routing, path discovery, and fragmentation internally.
///
/// Address format:
///   [TransportAddress.protocol] = [TransportProtocol.reticulum]
///   [TransportAddress.value]    = destination hash hex (32 chars = 16 bytes)
///
/// Fragmentation for payloads > 374 bytes is handled by the Go rnsbind layer.
class ReticulumTransport implements TransportPort {
  @override
  String get id => TransportProtocol.reticulum;

  @override
  Future<bool> get isAvailable => ReticulumNode.isRunning();

  @override
  Future<bool> canReach(TransportAddress address) async {
    if (address.protocol != TransportProtocol.reticulum) return false;
    if (!(await ReticulumNode.isRunning())) return false;
    if (address.value.isEmpty) return false;
    // Always attempt — Go layer requests path discovery on send if needed.
    // Path discovery can take seconds; blocking here would delay all sends.
    // If send fails (no path), CompositeTransport catches and retries later.
    return true;
  }

  @override
  Future<void> send(Uint8List encryptedEnvelope, TransportAddress destination) async {
    if (destination.protocol != TransportProtocol.reticulum) {
      throw ArgumentError('ReticulumTransport cannot send to ${destination.protocol}');
    }
    // Timeout: 30s base for LoRa, shorter paths will return sooner.
    await ReticulumNode.send(
      destHash: destination.value,
      data: encryptedEnvelope,
    ).timeout(const Duration(seconds: 30));
    AppLogger.d('RNS', 'sent ${encryptedEnvelope.length}b to ${destination.value.substring(0, 8)}…');
  }

  @override
  Stream<IncomingEnvelope> get incoming => ReticulumNode.messages.map(
        (msg) => IncomingEnvelope(
          data: msg.data,
          from: TransportAddress(
            protocol: TransportProtocol.reticulum,
            value: msg.fromHashHex,
          ),
          rawBufId: msg.rawBufId,
        ),
      );

  @override
  Future<void> register(TransportAddress myAddress) async {
    // Announce our destination so peers can discover us.
    await ReticulumNode.announce();
  }

  @override
  void dispose() {}
}
