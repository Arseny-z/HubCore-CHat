import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

/// Immutable Ed25519 key pair.
class Ed25519KeyPair {
  final Uint8List publicKey;   // 32 bytes
  final SecureKey privateKey;  // 64 bytes, libsodium SecureKey (protected memory)

  const Ed25519KeyPair({required this.publicKey, required this.privateKey});

  void dispose() => privateKey.dispose();
}

/// Immutable X25519 key pair for ECDH (KX API).
class X25519KeyPair {
  final Uint8List publicKey;   // 32 bytes
  final SecureKey privateKey;  // 32 bytes

  const X25519KeyPair({required this.publicKey, required this.privateKey});

  void dispose() => privateKey.dispose();
}

/// Low-level key generation helpers backed by libsodium CSPRNG.
class KeyGen {
  final Sodium _sodium;
  KeyGen(this._sodium);

  Ed25519KeyPair generateEd25519() {
    final kp = _sodium.crypto.sign.keyPair();
    return Ed25519KeyPair(
      publicKey: Uint8List.fromList(kp.publicKey),
      privateKey: kp.secretKey,
    );
  }

  X25519KeyPair generateX25519() {
    final kp = _sodium.crypto.kx.keyPair();
    return X25519KeyPair(
      publicKey: Uint8List.fromList(kp.publicKey),
      privateKey: kp.secretKey,
    );
  }

  Uint8List randomBytes(int length) => _sodium.randombytes.buf(length);
}
