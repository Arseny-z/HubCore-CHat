import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/src/platforms/sodium_linux.dart';
import 'package:hubcore_chat/crypto/sender_keys.dart';

void main() {
  late Sodium sodium;
  late SenderKeys sk;

  setUpAll(() async {
    SodiumLinux.registerWith();
    sodium = await SodiumInit.init();
    sk = SenderKeys(sodium);
  });

  const alicePubkey = 'alice_pub_base58_placeholder';
  const bobPubkey = 'bob_pub_base58_placeholder';

  group('SenderKeys', () {
    test('basic encrypt / decrypt roundtrip', () {
      final aliceState = sk.createSenderChain();
      // Bob imports Alice's chain state
      final exported = sk.exportChainState(aliceState);
      final bobState = sk.importChainState(exported);

      final plaintext = Uint8List.fromList('hello group'.codeUnits);
      final msg = sk.encrypt(aliceState, plaintext, alicePubkey);
      final dec = sk.decrypt(bobState, msg);

      expect(dec, equals(plaintext));
    });

    test('multiple sequential messages', () {
      final aliceState = sk.createSenderChain();
      final exported = sk.exportChainState(aliceState);
      final bobState = sk.importChainState(exported);

      for (var i = 0; i < 10; i++) {
        final msg = Uint8List.fromList('msg $i'.codeUnits);
        final enc = sk.encrypt(aliceState, msg, alicePubkey);
        final dec = sk.decrypt(bobState, enc);
        expect(dec, equals(msg), reason: 'message $i mismatch');
      }
    });

    test('wrong sender state cannot decrypt', () {
      final aliceState = sk.createSenderChain();
      final wrongState = sk.createSenderChain(); // different chain

      final msg = sk.encrypt(aliceState, Uint8List.fromList('secret'.codeUnits), alicePubkey);

      expect(
        () => sk.decrypt(wrongState, msg),
        throwsA(anything),
      );
    });

    test('forward secrecy: replay after chain advanced fails', () {
      final aliceState = sk.createSenderChain();
      final exported = sk.exportChainState(aliceState);
      final bobState = sk.importChainState(exported);

      final enc = sk.encrypt(aliceState, Uint8List.fromList('secret'.codeUnits), alicePubkey);
      sk.decrypt(bobState, enc);

      // Chain advanced — same ciphertext should fail
      expect(
        () => sk.decrypt(bobState, enc),
        throwsA(anything),
      );
    });

    test('DH ratchet triggers and recipient can still decrypt', () {
      final aliceState = sk.createSenderChain();
      final exported = sk.exportChainState(aliceState);
      final bobState = sk.importChainState(exported);

      for (var i = 0; i < senderKeyDHRatchetAfterMessages; i++) {
        final enc = sk.encrypt(aliceState, Uint8List.fromList([i]), alicePubkey);
        expect(enc.newSenderKey, isNull, reason: 'no ratchet before limit at msg $i');
        sk.decrypt(bobState, enc);
      }

      final enc = sk.encrypt(aliceState, Uint8List.fromList([0xFF]), alicePubkey);
      expect(enc.newSenderKey, isNotNull, reason: 'DH ratchet should trigger');

      final dec = sk.decrypt(bobState, enc);
      expect(dec, equals(Uint8List.fromList([0xFF])));
    });

    test('export / import preserves counter', () {
      final aliceState = sk.createSenderChain();
      for (var i = 0; i < 5; i++) {
        sk.encrypt(aliceState, Uint8List.fromList([i]), alicePubkey);
      }
      final exported = sk.exportChainState(aliceState);
      final imported = sk.importChainState(exported);
      expect(imported.counter, equals(5));
    });

    test('two senders independent chains', () {
      final aliceState = sk.createSenderChain();
      final bobSendState = sk.createSenderChain();

      final aliceImported = sk.importChainState(sk.exportChainState(aliceState));
      final bobImported = sk.importChainState(sk.exportChainState(bobSendState));

      final aMsg = sk.encrypt(aliceState, Uint8List.fromList('from alice'.codeUnits), alicePubkey);
      final bMsg = sk.encrypt(bobSendState, Uint8List.fromList('from bob'.codeUnits), bobPubkey);

      expect(sk.decrypt(aliceImported, aMsg), equals(Uint8List.fromList('from alice'.codeUnits)));
      expect(sk.decrypt(bobImported, bMsg), equals(Uint8List.fromList('from bob'.codeUnits)));
    });
  });
}
