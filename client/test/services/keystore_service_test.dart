import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:sodium_libs/src/platforms/sodium_linux.dart';
import 'package:hubcore_chat/crypto/identity.dart';
import 'package:hubcore_chat/infrastructure/keystore/keystore_service.dart';

void main() {
  late Sodium sodium;
  late KeystoreService keystore;

  setUpAll(() async {
    SodiumLinux.registerWith();
    sodium = await SodiumInit.init();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    keystore = KeystoreService(sodium);
  });

  group('KeystoreService', () {
    test('hasIdentity returns false when empty', () async {
      expect(await keystore.hasIdentity(), isFalse);
    });

    test('save and load roundtrip', () async {
      final original = Identity.generate(sodium);
      await keystore.saveIdentity(original);

      expect(await keystore.hasIdentity(), isTrue);

      final loaded = await keystore.loadIdentity();
      expect(loaded, isNotNull);
      expect(loaded!.masterPublicKey, equals(original.masterPublicKey));
      expect(loaded.signingPublicKey, equals(original.signingPublicKey));
      expect(loaded.x25519PublicKey, equals(original.x25519PublicKey));
      expect(loaded.fingerprint, equals(original.fingerprint));
    });

    test('loaded identity can sign and verify', () async {
      final original = Identity.generate(sodium);
      await keystore.saveIdentity(original);

      final loaded = (await keystore.loadIdentity())!;
      final msg = 'hello from loaded identity'.codeUnits;
      final sig = loaded.sign(Uint8List.fromList(msg));
      expect(loaded.verify(Uint8List.fromList(msg), sig), isTrue);
    });

    test('loaded signing cert is valid and verifiable', () async {
      final original = Identity.generate(sodium);
      await keystore.saveIdentity(original);

      final loaded = (await keystore.loadIdentity())!;
      expect(loaded.signingCert.isValid, isTrue);
      expect(loaded.signingCert.verify(sodium, loaded.masterPublicKey), isTrue);
    });

    test('loaded identity after rotation has new signing key', () async {
      final original = Identity.generate(sodium);
      final rotated = original.rotateSigningKey();
      await keystore.saveIdentity(rotated);

      final loaded = (await keystore.loadIdentity())!;
      expect(loaded.masterPublicKey, equals(original.masterPublicKey));
      expect(loaded.signingPublicKey, equals(rotated.signingPublicKey));
      expect(loaded.signingCert.verify(sodium, loaded.masterPublicKey), isTrue);
    });

    test('loaded x25519 private key matches original', () async {
      final original = Identity.generate(sodium);
      final origPrivBytes = original.x25519PrivateKeyBytes;
      await keystore.saveIdentity(original);

      final loaded = (await keystore.loadIdentity())!;
      final loadedPrivBytes = loaded.x25519PrivateKeyBytes;
      expect(loadedPrivBytes, equals(origPrivBytes));
    });

    test('wipe removes all keys', () async {
      await keystore.saveIdentity(Identity.generate(sodium));
      expect(await keystore.hasIdentity(), isTrue);

      await keystore.wipe();
      expect(await keystore.hasIdentity(), isFalse);
      expect(await keystore.loadIdentity(), isNull);
    });
  });
}
