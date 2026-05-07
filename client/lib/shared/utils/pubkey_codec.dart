import 'dart:typed_data';
import 'package:bs58/bs58.dart';

/// Base58 encoding/decoding for public keys (display + QR codes).
class PubkeyCodec {
  static String encode(Uint8List pubkey) => base58.encode(pubkey);

  static Uint8List decode(String encoded) =>
      Uint8List.fromList(base58.decode(encoded));
}
