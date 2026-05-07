import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/src/platforms/sodium_linux.dart';
import 'package:hubcore_chat/crypto/identity.dart';

void main() {
  late Sodium sodium;

  setUpAll(() async {
    SodiumLinux.registerWith();
    sodium = await SodiumInit.init();
  });

  group('Identity', () {
    test('generate creates distinct master and signing keys', () {
      final id = Identity.generate(sodium);
      expect(id.masterPublicKey.length, 32);
      expect(id.signingPublicKey.length, 32);
      expect(id.masterPublicKey, isNot(equals(id.signingPublicKey)));
    });

    test('fingerprint is formatted XXXX-XXXX-XXXX-XXXX', () {
      final id = Identity.generate(sodium);
      expect(
        id.fingerprint,
        matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$')),
      );
    });

    test('fingerprint is stable after signing key rotation', () {
      final id = Identity.generate(sodium);
      final fp1 = id.fingerprint;
      final rotated = id.rotateSigningKey();
      expect(rotated.fingerprint, equals(fp1));
    });

    test('sign and verify with signing key', () {
      final id = Identity.generate(sodium);
      final msg = Uint8List.fromList('hello hubcore'.codeUnits);
      final sig = id.sign(msg);
      expect(id.verify(msg, sig), isTrue);
    });

    test('verify rejects tampered message', () {
      final id = Identity.generate(sodium);
      final msg = Uint8List.fromList('hello'.codeUnits);
      final sig = id.sign(msg);
      final tampered = Uint8List.fromList('hXllo'.codeUnits);
      expect(id.verify(tampered, sig), isFalse);
    });

    test('signing cert is valid and verifiable by master key', () {
      final id = Identity.generate(sodium);
      expect(id.signingCert.isValid, isTrue);
      expect(id.signingCert.verify(sodium, id.masterPublicKey), isTrue);
    });

    test('rotation produces new signing key certified by same master', () {
      final id = Identity.generate(sodium);
      final rotated = id.rotateSigningKey();

      expect(rotated.signingPublicKey, isNot(equals(id.signingPublicKey)));
      expect(rotated.masterPublicKey, equals(id.masterPublicKey));
      expect(rotated.signingCert.verify(sodium, rotated.masterPublicKey), isTrue);
    });

    test('cert from different master is rejected', () {
      final id1 = Identity.generate(sodium);
      final id2 = Identity.generate(sodium);
      expect(id2.signingCert.verify(sodium, id1.masterPublicKey), isFalse);
    });
  });
}
