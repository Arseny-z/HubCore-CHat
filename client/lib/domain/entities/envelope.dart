import 'dart:convert';
import 'dart:typed_data';

/// Wire envelope for all message transport (P2P, queue).
class Envelope {
  final String from; // base58 master pubkey
  final String to;   // base58 master pubkey
  final Uint8List body;

  /// Transport protocol that delivered this envelope (local metadata, not serialized).
  final String? transport;

  const Envelope({required this.from, required this.to, required this.body, this.transport});

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        'body': base64.encode(body),
      };

  factory Envelope.fromJson(Map<String, dynamic> j) => Envelope(
        from: j['from'] as String,
        to: j['to'] as String,
        body: base64.decode(j['body'] as String),
      );
}
