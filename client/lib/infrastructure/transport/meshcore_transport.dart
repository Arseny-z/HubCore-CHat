import 'dart:async';
import 'dart:typed_data';

import '../../domain/ports/transport_port.dart';

/// Stub implementation of Meshcore transport.
///
/// Meshcore is a LoRa mesh protocol. When implemented, this transport will
/// communicate with a Meshcore node via Bluetooth or USB serial.
///
/// Address format:
///   [TransportAddress.protocol] = [TransportProtocol.meshcore]
///   [TransportAddress.value]    = Meshcore node ID hex
///
/// This stub is wired into [CompositeTransport] from day one.
/// Fill in when Meshcore integration is ready.
class MeshcoreTransport implements TransportPort {
  @override
  String get id => TransportProtocol.meshcore;

  /// Always false until Meshcore integration is implemented.
  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> canReach(TransportAddress address) async => false;

  @override
  Future<void> send(Uint8List encryptedEnvelope, TransportAddress destination) =>
      throw UnimplementedError('MeshcoreTransport: not yet implemented');

  @override
  Stream<IncomingEnvelope> get incoming => const Stream.empty();

  @override
  Future<void> register(TransportAddress myAddress) async {}

  @override
  void dispose() {}
}
