import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import '../../crypto/identity.dart';
import '../../domain/entities/device_pairing_payload.dart';

const _kPairingTtlSeconds = 5 * 60; // 5 minutes
const _kFixedBundleSize = 304; // masterPriv(64)+signingPriv(64)+x25519Priv(32)+x25519Pub(32)+cert(112)

/// Result of decrypting a pairing QR — identity plus profile data.
class PairingDecryptResult {
  final Identity identity;
  final String myAlias;
  final String myPublicAlias;

  const PairingDecryptResult({
    required this.identity,
    required this.myAlias,
    required this.myPublicAlias,
  });
}

class DevicePairingCrypto {
  final Sodium _sodium;

  DevicePairingCrypto(this._sodium);

  // ── Device A: generate QR ───────────────────────────────────────────────────

  PairingQrPayload generatePairingQr(
    Identity identity,
    String yggPubHex, // hex pubkey for Yggdrasil transport routing
    String yggAddr,   // IPv6 address (unused in QR, kept for logging)
    String myAlias,
    String myPublicAlias,
  ) {
    final expiresAt =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + _kPairingTtlSeconds;

    final masterPriv  = identity.masterPrivateKeyBytes;
    final signingPriv = identity.signingPrivateKeyBytes;
    final x25519Priv  = identity.x25519PrivateKeyBytes;
    final x25519Pub   = identity.x25519PublicKey;
    final certBlob    = identity.signingCert.encode();

    final aliasBytes       = utf8.encode(myAlias);
    final publicAliasBytes = utf8.encode(myPublicAlias);

    // Bundle: fixed(304) + uint16(alias_len) + alias + uint16(pub_alias_len) + pub_alias
    final bundleLen = _kFixedBundleSize + 2 + aliasBytes.length + 2 + publicAliasBytes.length;
    final bundle = Uint8List(bundleLen);
    var off = 0;

    bundle.setRange(off, off + 64,  masterPriv);  off += 64;
    bundle.setRange(off, off + 64,  signingPriv); off += 64;
    bundle.setRange(off, off + 32,  x25519Priv);  off += 32;
    bundle.setRange(off, off + 32,  x25519Pub);   off += 32;
    bundle.setRange(off, off + 112, certBlob);     off += 112;

    bundle[off] = aliasBytes.length & 0xFF;
    bundle[off + 1] = (aliasBytes.length >> 8) & 0xFF; off += 2;
    bundle.setRange(off, off + aliasBytes.length, aliasBytes); off += aliasBytes.length;

    bundle[off] = publicAliasBytes.length & 0xFF;
    bundle[off + 1] = (publicAliasBytes.length >> 8) & 0xFF; off += 2;
    bundle.setRange(off, off + publicAliasBytes.length, publicAliasBytes);

    masterPriv.fillRange(0, masterPriv.length, 0);
    signingPriv.fillRange(0, signingPriv.length, 0);
    x25519Priv.fillRange(0, x25519Priv.length, 0);

    final tempKeyBytes = _sodium.randombytes.buf(_sodium.crypto.secretBox.keyBytes);
    final tempKey = SecureKey.fromList(_sodium, tempKeyBytes);
    final nonce   = _sodium.randombytes.buf(_sodium.crypto.secretBox.nonceBytes);

    final ciphertext = _sodium.crypto.secretBox.easy(
      message: bundle,
      nonce:   nonce,
      key:     tempKey,
    );
    tempKey.dispose();

    return PairingQrPayload(
      nonce:           nonce,
      tempKey:         tempKeyBytes,
      encryptedBundle: ciphertext,
      expiresAt:       expiresAt,
      yggPubHex:       yggPubHex,
    );
  }

  // ── Device B: decrypt QR ────────────────────────────────────────────────────

  PairingDecryptResult decryptIdentityFromQr(PairingQrPayload qr) {
    if (qr.isExpired) throw ArgumentError('Pairing QR has expired');

    final tempKey = SecureKey.fromList(_sodium, qr.tempKey);

    final Uint8List plain;
    try {
      plain = _sodium.crypto.secretBox.openEasy(
        cipherText: qr.encryptedBundle,
        nonce:      qr.nonce,
        key:        tempKey,
      );
    } on SodiumException {
      tempKey.dispose();
      throw ArgumentError('Failed to decrypt pairing bundle');
    } finally {
      tempKey.dispose();
    }

    if (plain.length < _kFixedBundleSize + 4) {
      throw ArgumentError('Bundle too short: ${plain.length}');
    }

    var off = 0;
    final masterPrivB  = plain.sublist(off, off + 64); off += 64;
    final signingPrivB = plain.sublist(off, off + 64); off += 64;
    final x25519PrivB  = plain.sublist(off, off + 32); off += 32;
    final x25519PubB   = plain.sublist(off, off + 32); off += 32;
    final certBlob     = plain.sublist(off, off + 112); off += 112;

    final aliasLen = plain[off] | (plain[off + 1] << 8); off += 2;
    final myAlias  = off + aliasLen <= plain.length
        ? utf8.decode(plain.sublist(off, off + aliasLen))
        : '';
    off += aliasLen;

    String myPublicAlias = '';
    if (off + 2 <= plain.length) {
      final pubAliasLen = plain[off] | (plain[off + 1] << 8); off += 2;
      if (off + pubAliasLen <= plain.length) {
        myPublicAlias = utf8.decode(plain.sublist(off, off + pubAliasLen));
      }
    }

    // Ed25519: second 32 bytes of 64-byte private key = public key
    final masterPub  = Uint8List.fromList(masterPrivB.sublist(32));
    final signingPub = Uint8List.fromList(signingPrivB.sublist(32));

    final masterPrivKey  = SecureKey.fromList(_sodium, masterPrivB);
    final signingPrivKey = SecureKey.fromList(_sodium, signingPrivB);
    final x25519PrivKey  = SecureKey.fromList(_sodium, x25519PrivB);

    masterPrivB.fillRange(0, masterPrivB.length, 0);
    signingPrivB.fillRange(0, signingPrivB.length, 0);
    x25519PrivB.fillRange(0, x25519PrivB.length, 0);

    final identity = Identity.fromParts(
      sodium:            _sodium,
      masterPublicKey:   masterPub,
      masterPrivateKey:  masterPrivKey,
      signingPublicKey:  signingPub,
      signingPrivateKey: signingPrivKey,
      x25519PublicKey:   x25519PubB,
      x25519PrivateKey:  x25519PrivKey,
      signingCert:       SigningCert.decode(certBlob),
      isMasterDevice:    false,
    );

    return PairingDecryptResult(
      identity:      identity,
      myAlias:       myAlias,
      myPublicAlias: myPublicAlias,
    );
  }

  // ── Handshake validation ────────────────────────────────────────────────────

  bool validateHandshake(DevicePairingHandshake handshake, Uint8List masterPub) {
    try {
      final cert = DeviceCert.decode(handshake.deviceCert);
      return cert.verify(_sodium, masterPub);
    } catch (_) {
      return false;
    }
  }
}
