import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hubcore_chat/domain/entities/group_post_envelope.dart';
import 'package:hubcore_chat/infrastructure/crypto/group_post_codec.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/src/platforms/sodium_linux.dart';

void main() {
  late Sodium sodium;
  late GroupPostCodec codec;

  // Sender Ed25519 (signing) keypair
  late KeyPair senderSign;

  // Three recipients with X25519 keypairs (the long-term ones)
  late KeyPair aliceX;
  late KeyPair bobX;
  late KeyPair eveX;

  late List<GroupPostRecipient> recipients;

  setUpAll(() async {
    SodiumLinux.registerWith();
    sodium = await SodiumInit.init();
    codec  = GroupPostCodec(sodium);

    senderSign = sodium.crypto.sign.keyPair();
    aliceX = sodium.crypto.box.keyPair();
    bobX   = sodium.crypto.box.keyPair();
    eveX   = sodium.crypto.box.keyPair();

    recipients = [
      GroupPostRecipient(
        masterPub58: 'alice',
        x25519Pub: Uint8List.fromList(aliceX.publicKey),
      ),
      GroupPostRecipient(
        masterPub58: 'bob',
        x25519Pub: Uint8List.fromList(bobX.publicKey),
      ),
    ];
  });

  GroupPostBuild buildPost(Uint8List plaintext) {
    return codec.encryptForRecipients(
      groupId:       'group-A',
      epoch:         1,
      messageId:     '0123abcd',
      plaintext:     plaintext,
      senderPub58:   'sender-base58',
      recipients:    recipients,
      ttlSeconds:    null,
      signFn: (bytes) => Uint8List.fromList(
        sodium.crypto.sign.detached(
          message:   bytes,
          secretKey: senderSign.secretKey,
        ),
      ),
    );
  }

  group('GroupPostCodec', () {
    test('roundtrip — every recipient decrypts the same plaintext', () {
      final plaintext = Uint8List.fromList('hello group'.codeUnits);
      final build = buildPost(plaintext);
      expect(build.envelopes.length, 2);

      final aliceEnv = build.envelopes[0].envelope;
      final bobEnv   = build.envelopes[1].envelope;

      final aliceResult = codec.decrypt(
        envelope:         aliceEnv,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     aliceX.secretKey,
      );
      final bobResult = codec.decrypt(
        envelope:         bobEnv,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     bobX.secretKey,
      );

      expect(aliceResult, isA<GroupPostDecryptSuccess>());
      expect(bobResult,   isA<GroupPostDecryptSuccess>());
      expect((aliceResult as GroupPostDecryptSuccess).plaintext, equals(plaintext));
      expect((bobResult   as GroupPostDecryptSuccess).plaintext, equals(plaintext));
    });

    test('per-recipient envelopes share content + signature, differ in wrap', () {
      final build = buildPost(Uint8List.fromList('share content'.codeUnits));
      final a = build.envelopes[0].envelope;
      final b = build.envelopes[1].envelope;

      // Identical across recipients
      expect(a.contentNonce,      equals(b.contentNonce));
      expect(a.contentCiphertext, equals(b.contentCiphertext));
      expect(a.signature,         equals(b.signature));
      expect(a.epoch,             equals(b.epoch));
      expect(a.messageId,         equals(b.messageId));
      expect(a.groupId,           equals(b.groupId));

      // Per-recipient — must differ (fresh ephemeral key + nonce)
      expect(a.wrapEphPub,   isNot(equals(b.wrapEphPub)));
      expect(a.wrapBoxNonce, isNot(equals(b.wrapBoxNonce)));
      expect(a.wrapBox,      isNot(equals(b.wrapBox)));
    });

    test('wrong recipient (Eve) cannot open the wrap', () {
      final build = buildPost(Uint8List.fromList('top secret'.codeUnits));
      final aliceEnv = build.envelopes[0].envelope;

      final result = codec.decrypt(
        envelope:         aliceEnv,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     eveX.secretKey, // not a recipient
      );

      expect(result, isA<GroupPostDecryptFailure>());
      expect((result as GroupPostDecryptFailure).reason,
          equals(GroupPostDecryptError.wrapOpenFailed));
    });

    test('tampered ciphertext is rejected (signature catches it)', () {
      final build = buildPost(Uint8List.fromList('untouched'.codeUnits));
      final orig  = build.envelopes[0].envelope;

      // Flip a bit in ciphertext
      final mutated = Uint8List.fromList(orig.contentCiphertext)
        ..[0] = orig.contentCiphertext[0] ^ 0x01;

      final tampered = GroupPostEnvelope(
        groupId:           orig.groupId,
        epoch:             orig.epoch,
        messageId:         orig.messageId,
        contentNonce:      orig.contentNonce,
        contentCiphertext: mutated,
        wrapBoxNonce:      orig.wrapBoxNonce,
        wrapEphPub:        orig.wrapEphPub,
        wrapBox:           orig.wrapBox,
        senderPub:         orig.senderPub,
        signature:         orig.signature,
      );

      final result = codec.decrypt(
        envelope:         tampered,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     aliceX.secretKey,
      );

      expect(result, isA<GroupPostDecryptFailure>());
      expect((result as GroupPostDecryptFailure).reason,
          equals(GroupPostDecryptError.badSignature));
    });

    test('tampered signature is rejected', () {
      final build = buildPost(Uint8List.fromList('msg'.codeUnits));
      final orig  = build.envelopes[0].envelope;

      final mutatedSig = Uint8List.fromList(orig.signature)
        ..[10] = orig.signature[10] ^ 0xFF;

      final tampered = GroupPostEnvelope(
        groupId:           orig.groupId,
        epoch:             orig.epoch,
        messageId:         orig.messageId,
        contentNonce:      orig.contentNonce,
        contentCiphertext: orig.contentCiphertext,
        wrapBoxNonce:      orig.wrapBoxNonce,
        wrapEphPub:        orig.wrapEphPub,
        wrapBox:           orig.wrapBox,
        senderPub:         orig.senderPub,
        signature:         mutatedSig,
      );

      final result = codec.decrypt(
        envelope:         tampered,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     aliceX.secretKey,
      );

      expect(result, isA<GroupPostDecryptFailure>());
      expect((result as GroupPostDecryptFailure).reason,
          equals(GroupPostDecryptError.badSignature));
    });

    test('different signing key fails verification', () {
      final build = buildPost(Uint8List.fromList('signed'.codeUnits));
      final env   = build.envelopes[0].envelope;

      final otherSigner = sodium.crypto.sign.keyPair();
      final result = codec.decrypt(
        envelope:         env,
        senderSigningPub: Uint8List.fromList(otherSigner.publicKey),
        myX25519Priv:     aliceX.secretKey,
      );

      expect(result, isA<GroupPostDecryptFailure>());
      expect((result as GroupPostDecryptFailure).reason,
          equals(GroupPostDecryptError.badSignature));
    });

    test('cross-epoch replay fails AEAD (epoch is in AAD via transcript)', () {
      // Build at epoch=1, then construct an envelope claiming epoch=2 with
      // the same content. Signature won't match — reject as badSignature.
      final build = buildPost(Uint8List.fromList('hello'.codeUnits));
      final orig  = build.envelopes[0].envelope;

      final replayed = GroupPostEnvelope(
        groupId:           orig.groupId,
        epoch:             999, // claim a different epoch
        messageId:         orig.messageId,
        contentNonce:      orig.contentNonce,
        contentCiphertext: orig.contentCiphertext,
        wrapBoxNonce:      orig.wrapBoxNonce,
        wrapEphPub:        orig.wrapEphPub,
        wrapBox:           orig.wrapBox,
        senderPub:         orig.senderPub,
        signature:         orig.signature,
      );

      final result = codec.decrypt(
        envelope:         replayed,
        senderSigningPub: Uint8List.fromList(senderSign.publicKey),
        myX25519Priv:     aliceX.secretKey,
      );

      expect(result, isA<GroupPostDecryptFailure>());
      expect((result as GroupPostDecryptFailure).reason,
          equals(GroupPostDecryptError.badSignature));
    });

    test('encode → decode roundtrip preserves all fields', () {
      final build = buildPost(Uint8List.fromList('wire'.codeUnits));
      final orig  = build.envelopes[0].envelope;

      final bytes = orig.encode();
      final back  = GroupPostEnvelope.tryDecode(bytes);

      expect(back, isNotNull);
      expect(back!.groupId,           equals(orig.groupId));
      expect(back.epoch,              equals(orig.epoch));
      expect(back.messageId,          equals(orig.messageId));
      expect(back.contentNonce,       equals(orig.contentNonce));
      expect(back.contentCiphertext,  equals(orig.contentCiphertext));
      expect(back.wrapBoxNonce,       equals(orig.wrapBoxNonce));
      expect(back.wrapEphPub,         equals(orig.wrapEphPub));
      expect(back.wrapBox,            equals(orig.wrapBox));
      expect(back.senderPub,          equals(orig.senderPub));
      expect(back.signature,          equals(orig.signature));
      expect(back.ttlSeconds,         equals(orig.ttlSeconds));
    });

    test('tryDecode returns null for non-group_post payloads', () {
      final notUs = Uint8List.fromList(
          '{"type":"group_msg","gid":"x"}'.codeUnits);
      expect(GroupPostEnvelope.tryDecode(notUs), isNull);

      final notJson = Uint8List.fromList('not json'.codeUnits);
      expect(GroupPostEnvelope.tryDecode(notJson), isNull);
    });

    test('ttlSeconds is preserved when set', () {
      final build = codec.encryptForRecipients(
        groupId:       'g',
        epoch:         0,
        messageId:     'aabbccdd',
        plaintext:     Uint8List.fromList([1, 2, 3]),
        senderPub58:   'sender',
        recipients:    [recipients.first],
        ttlSeconds:    3600,
        signFn: (bytes) => Uint8List.fromList(
          sodium.crypto.sign.detached(
            message:   bytes,
            secretKey: senderSign.secretKey,
          ),
        ),
      );
      final env = build.envelopes.first.envelope;
      expect(env.ttlSeconds, equals(3600));

      final reEncoded = GroupPostEnvelope.tryDecode(env.encode());
      expect(reEncoded?.ttlSeconds, equals(3600));
    });
  });
}
