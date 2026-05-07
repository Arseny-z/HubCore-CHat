import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';

const _infoInit = 'hubcore_init_v1';
const _infoChainKey = 'hubcore_chain_v1';
const _infoMessageKey = 'hubcore_msg_v1';
const _infoRatchet = 'hubcore_ratchet_v1';
const _infoGroupMsg = 'hubcore_group_msg_v1';
const _infoGroupChain = 'hubcore_group_chain_v1';

/// KDF backed by HKDF-SHA512 (HMAC-SHA512 via libsodium crypto_auth).
class KDF {
  final Sodium _sodium;
  KDF(this._sodium);

  Uint8List deriveInitial(Uint8List masterSecret) =>
      _hkdf(masterSecret, _infoInit, 64);

  Uint8List deriveRatchet(Uint8List rootKey, Uint8List dhOutput) {
    final ikm = Uint8List(64)
      ..setRange(0, 32, rootKey)
      ..setRange(32, 64, dhOutput);
    final result = _hkdf(ikm, _infoRatchet, 64);
    ikm.fillRange(0, 64, 0);
    return result;
  }

  Uint8List deriveMessageKey(Uint8List chainKey) =>
      _hkdf(chainKey, _infoMessageKey, 32);

  Uint8List deriveNextChainKey(Uint8List chainKey) =>
      _hkdf(chainKey, _infoChainKey, 32);

  Uint8List deriveGroupMessageKey(Uint8List senderChainKey) =>
      _hkdf(senderChainKey, _infoGroupMsg, 32);

  Uint8List deriveNextSenderChainKey(Uint8List senderChainKey) =>
      _hkdf(senderChainKey, _infoGroupChain, 32);

  /// HKDF using libsodium genericHash (BLAKE2b) as PRF.
  /// genericHash supports variable output up to 64 bytes.
  ///
  /// Extract: PRK = BLAKE2b(key=salt[32], msg=ikm, outLen=32)
  /// Expand:  T1  = BLAKE2b(key=PRK,      msg=info||0x01, outLen=length)
  ///          T2  = BLAKE2b(key=PRK,       msg=T1||info||0x02, outLen=length)
  ///          OKM = T1 || T2 (truncated to [length])
  Uint8List _hkdf(Uint8List ikm, String info, int length) {
    if (length > 64) {
      throw ArgumentError('two-block HKDF supports up to 64 bytes, got $length');
    }

    final gh = _sodium.crypto.genericHash;
    final infoBytes = _utf8(info);

    // Extract: PRK = BLAKE2b(key=zeros[32], msg=ikm)
    final saltKey = SecureKey(_sodium, gh.keyBytes);
    final prk = Uint8List.fromList(
      gh.call(outLen: gh.keyBytes, message: ikm, key: saltKey),
    );
    saltKey.dispose();

    // Expand T(1): BLAKE2b(key=PRK, msg=info || 0x01)
    final t1Input = Uint8List(infoBytes.length + 1)
      ..setRange(0, infoBytes.length, infoBytes)
      ..[infoBytes.length] = 0x01;

    final prkKey = SecureKey.fromList(_sodium, prk);
    final blockLen = length <= 32 ? length : 32;
    final t1 = Uint8List.fromList(
      gh.call(outLen: blockLen, message: t1Input, key: prkKey),
    );

    if (length <= 32) {
      prkKey.dispose();
      return t1;
    }

    // Expand T(2): BLAKE2b(key=PRK, msg=T1 || info || 0x02)
    final t2Input = Uint8List(t1.length + infoBytes.length + 1)
      ..setRange(0, t1.length, t1)
      ..setRange(t1.length, t1.length + infoBytes.length, infoBytes)
      ..[t1.length + infoBytes.length] = 0x02;

    final remaining = length - 32;
    final t2 = Uint8List.fromList(
      gh.call(outLen: remaining, message: t2Input, key: prkKey),
    );
    prkKey.dispose();

    return Uint8List(length)
      ..setRange(0, 32, t1)
      ..setRange(32, length, t2);
  }

  static Uint8List _utf8(String s) =>
      Uint8List.fromList(s.codeUnits);
}
