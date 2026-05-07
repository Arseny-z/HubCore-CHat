import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/src/platforms/sodium_linux.dart';
import 'package:hubcore_chat/crypto/double_ratchet.dart';
import 'package:hubcore_chat/crypto/keys.dart';

void main() {
  late Sodium sodium;
  late DoubleRatchet ratchet;

  setUpAll(() async {
    SodiumLinux.registerWith();
    sodium = await SodiumInit.init();
    ratchet = DoubleRatchet(sodium);
  });

  (RatchetState alice, RatchetState bob) initPair() {
    final kg = KeyGen(sodium);
    final bobIdentity = kg.generateX25519();
    final bobEphemeral = kg.generateX25519();

    final alice = ratchet.initSender(
      peerIdentityPubkey: bobIdentity.publicKey,
      peerEphemeralPubkey: bobEphemeral.publicKey,
    );

    final bob = ratchet.initReceiver(
      myIdentityPrivkey: bobIdentity.privateKey,
      myIdentityPubkey: bobIdentity.publicKey,
      myEphemeralPrivkey: bobEphemeral.privateKey,
      myEphemeralPubkey: bobEphemeral.publicKey,
      senderEphemeralPubkey: alice.myEphemeral.publicKey,
    );

    return (alice, bob);
  }

  group('DoubleRatchet', () {
    test('basic encrypt / tryDecrypt roundtrip', () {
      final (alice, bob) = initPair();
      final plaintext = Uint8List.fromList('hello bob'.codeUnits);

      final enc = ratchet.encrypt(alice, plaintext);
      final dec = ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter,
          newPeerEphemeral: enc.newEphemeralKey);

      expect(dec, equals(plaintext));
    });

    test('multiple sequential messages', () {
      final (alice, bob) = initPair();

      for (var i = 0; i < 10; i++) {
        final msg = Uint8List.fromList('message $i'.codeUnits);
        final enc = ratchet.encrypt(alice, msg);
        final dec = ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter,
            newPeerEphemeral: enc.newEphemeralKey);
        expect(dec, equals(msg), reason: 'message $i mismatch');
      }
    });

    test('forward secrecy: replaying ciphertext fails after chain advanced', () {
      final (alice, bob) = initPair();
      final msg = Uint8List.fromList('secret'.codeUnits);

      final enc = ratchet.encrypt(alice, msg);
      ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter,
          newPeerEphemeral: enc.newEphemeralKey);

      // Chain key has advanced — same ciphertext / counter should return null
      final replay = ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter);
      expect(replay, isNull, reason: 'replay should fail');
    });

    test('DH ratchet triggers after dhRatchetAfterMessages', () {
      final (alice, bob) = initPair();

      for (var i = 0; i < dhRatchetAfterMessages; i++) {
        final enc = ratchet.encrypt(alice, Uint8List.fromList([i]));
        expect(enc.newEphemeralKey, isNull,
            reason: 'no ratchet before limit at msg $i');
        ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter);
      }

      final enc = ratchet.encrypt(alice, Uint8List.fromList([0xFF]));
      expect(enc.newEphemeralKey, isNotNull,
          reason: 'DH ratchet should trigger at message $dhRatchetAfterMessages');

      final dec = ratchet.tryDecrypt(bob, enc.ciphertext, enc.counter,
          newPeerEphemeral: enc.newEphemeralKey);
      expect(dec, equals(Uint8List.fromList([0xFF])));
    });

    test('wrong session cannot decrypt', () {
      final (alice, _) = initPair();
      final (_, bobOther) = initPair();

      final enc = ratchet.encrypt(alice, Uint8List.fromList('secret'.codeUnits));
      final dec = ratchet.tryDecrypt(bobOther, enc.ciphertext, enc.counter);
      expect(dec, isNull, reason: 'wrong session should return null');
    });

    test('counter in AD prevents ciphertext substitution', () {
      final (alice, bob) = initPair();

      final enc0 = ratchet.encrypt(alice, Uint8List.fromList('msg0'.codeUnits));
      final enc1 = ratchet.encrypt(alice, Uint8List.fromList('msg1'.codeUnits));

      ratchet.tryDecrypt(bob, enc0.ciphertext, enc0.counter);

      // enc0 ciphertext with enc1 counter — AD mismatch → should return null
      final bad = ratchet.tryDecrypt(bob, enc0.ciphertext, enc1.counter);
      expect(bad, isNull, reason: 'AD mismatch should fail');
    });
  });
}
