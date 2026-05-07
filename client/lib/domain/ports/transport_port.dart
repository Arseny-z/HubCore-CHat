import 'dart:typed_data';

/// Protocol identifier constants — used as [TransportAddress.protocol].
class TransportProtocol {
  static const yggdrasil = 'yggdrasil';
  static const reticulum = 'reticulum';
  static const meshcore  = 'meshcore';

  TransportProtocol._();
}

/// A typed address for a specific transport protocol.
///
/// Each contact can have one [TransportAddress] per protocol.
/// The [value] format depends on [protocol]:
///   - yggdrasil → Ed25519 public key hex (fd00::...)
///   - reticulum → SHAKE-256 destination hash hex
///   - meshcore  → node ID hex
class TransportAddress {
  final String protocol;
  final String value;

  const TransportAddress({required this.protocol, required this.value});

  @override
  String toString() => '$protocol:${value.length > 8 ? value.substring(0, 8) : value}…';

  @override
  bool operator ==(Object other) =>
      other is TransportAddress && protocol == other.protocol && value == other.value;

  @override
  int get hashCode => Object.hash(protocol, value);
}

/// An envelope received from any transport.
class IncomingEnvelope {
  final Uint8List data;
  final TransportAddress from;
  final DateTime receivedAt;

  /// Row id in the transport's on-disk buffer (IncomingRawDb), if applicable.
  /// Non-null means the packet was persisted and must be acked after processing
  /// so the Kotlin side can delete the row.
  final int? rawBufId;

  IncomingEnvelope({
    required this.data,
    required this.from,
    DateTime? receivedAt,
    this.rawBufId,
  }) : receivedAt = receivedAt ?? DateTime.now();
}

/// Result of a send attempt via [TransportPort] or [CompositeTransport].
class TransportResult {
  /// Protocol that successfully delivered the message, or null on failure.
  final String? protocol;

  /// Error description if all transports failed.
  final String? error;

  const TransportResult.success(String this.protocol) : error = null;
  const TransportResult.failure(String this.error) : protocol = null;

  bool get success => protocol != null;

  @override
  String toString() =>
      success ? 'TransportResult.success($protocol)' : 'TransportResult.failure($error)';
}

/// Abstract transport port.
///
/// Each protocol (Yggdrasil, Reticulum, …) implements
/// this interface. [CompositeTransport] selects the best available one at
/// send time, so the rest of the app is transport-agnostic.
///
/// ## Dependency Rule
/// This file lives in `domain/ports/` — it MUST NOT import anything outside
/// `dart:` core libraries. Infrastructure implementations live in
/// `infrastructure/transport/`.
abstract class TransportPort {
  /// Stable identifier for this transport (see [TransportProtocol]).
  String get id;

  /// Whether this transport is currently operational (daemon running,
  /// hardware present, etc.). Checked before [canReach] and [send].
  Future<bool> get isAvailable;

  /// Whether this transport can likely reach [address] right now.
  /// Fast check — allowed to be optimistic (actual send may still fail).
  Future<bool> canReach(TransportAddress address);

  /// Send [encryptedEnvelope] to [destination].
  ///
  /// Throws if the transport is unavailable or the send fails definitively.
  /// Caller should fall through to the next transport on failure.
  Future<void> send(Uint8List encryptedEnvelope, TransportAddress destination);

  /// Stream of raw encrypted envelopes arriving on this transport.
  /// Never closes (lives as long as the transport is active).
  Stream<IncomingEnvelope> get incoming;

  /// Register [myAddress] on this transport so peers can reach us.
  /// No-op for transports that don't require registration (e.g. Yggdrasil).
  Future<void> register(TransportAddress myAddress) async {}

  /// Release resources. After [dispose], the transport must not be used.
  void dispose() {}
}
