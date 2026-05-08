import 'dart:io';
import 'dart:typed_data';
import 'package:sodium_libs/sodium_libs.dart';


/// Encrypts and decrypts files using XChaCha20-Poly1305.
///
/// Supports two formats:
///   - **v1 (legacy)**: Single AEAD blob — entire file encrypted at once.
///   - **v2 (streaming)**: Chunk-based encryption — bounded memory usage.
///
/// v2 (SF02) on-disk format (legacy — read-only):
/// ```
/// [4 bytes: magic "SF02"]
/// [4 bytes: uint32 BE — plaintext chunk size]
/// For each chunk:
///   [4 bytes: uint32 BE — encrypted chunk length]
///   [encrypted chunk bytes]  (no authenticated metadata)
/// ```
///
/// v3 (SF03) on-disk format (current):
/// ```
/// [4 bytes: magic "SF03"]
/// [4 bytes: uint32 BE — plaintext chunk size]
/// [4 bytes: uint32 BE — total chunk count]     ← prevents truncation
/// For each chunk:
///   [4 bytes: uint32 BE — encrypted chunk length]
///   [encrypted chunk bytes]
///     additionalData = magic(4) + chunkSize(4) + totalChunks(4) + chunkIdx(8)
///     Authenticates header fields and chunk position — prevents tampering,
///     truncation, and reordering attacks.
/// ```
///
/// Per-chunk nonce = base_nonce with last 8 bytes XOR'd with big-endian chunk index.
class FileEncryption {
  final Sodium _sodium;

  FileEncryption(this._sodium);

  static const chunkPlainSize = 1024 * 1024; // 1 MB per encryption chunk
  static final _magic3 = Uint8List.fromList([0x53, 0x46, 0x30, 0x33]); // "SF03"

  // ── Legacy v1 (in-memory) ─────────────────────────────────────────────────

  /// Encrypt [plainBytes] with a fresh random key (v1 — single AEAD blob).
  EncryptedFile encrypt(Uint8List plainBytes) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final key = _sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);

    final ciphertext = Uint8List.fromList(
      aead.encrypt(
        message: plainBytes,
        additionalData: null,
        nonce: nonce,
        key: key,
      ),
    );

    final keyBytes = key.extractBytes();
    key.dispose();

    return EncryptedFile(
      ciphertext: ciphertext,
      key: keyBytes,
      nonce: nonce,
    );
  }

  /// Decrypt [ciphertext] using [keyBytes] and [nonce] (v1 — single AEAD blob).
  ///
  /// Zeroes [keyBytes] after use to minimise key material lifetime in memory.
  Uint8List decrypt(Uint8List ciphertext, Uint8List keyBytes, Uint8List nonce) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final key = SecureKey.fromList(_sodium, keyBytes);
    keyBytes.fillRange(0, keyBytes.length, 0);

    final plain = Uint8List.fromList(
      aead.decrypt(
        cipherText: ciphertext,
        additionalData: null,
        nonce: nonce,
        key: key,
      ),
    );
    key.dispose();
    return plain;
  }

  // ── Streaming v2 (file-to-file) ──────────────────────────────────────────

  /// Encrypt [input] file to [output] file using v3 (SF03) streaming format.
  /// Returns key and nonce. Peak memory ≈ [chunkPlainSize] + 16 bytes.
  Future<({Uint8List key, Uint8List nonce})> encryptFileStream(
    File input,
    File output,
  ) async {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final secureKey = aead.keygen();
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final keyBytes = Uint8List.fromList(secureKey.extractBytes());

    final raf = await input.open(mode: FileMode.read);
    final waf = await output.open(mode: FileMode.write);
    try {
      final inputLen = await raf.length();
      final totalChunks =
          inputLen == 0 ? 0 : (inputLen + chunkPlainSize - 1) ~/ chunkPlainSize;

      // Write SF03 header: magic + chunkSize + totalChunks
      await waf.writeFrom(_magic3);
      final csHeader = ByteData(4)..setUint32(0, chunkPlainSize, Endian.big);
      await waf.writeFrom(csHeader.buffer.asUint8List());
      final tcHeader = ByteData(4)..setUint32(0, totalChunks, Endian.big);
      await waf.writeFrom(tcHeader.buffer.asUint8List());

      int offset = 0;
      int chunkIdx = 0;
      while (offset < inputLen) {
        final remaining = inputLen - offset;
        final readSize = remaining < chunkPlainSize ? remaining : chunkPlainSize;
        await raf.setPosition(offset);
        final plainChunk = await raf.read(readSize);

        final ad = _buildChunkAD(totalChunks, chunkIdx);
        final chunkNonce = _deriveChunkNonce(nonce, chunkIdx);
        final encrypted = Uint8List.fromList(aead.encrypt(
          message: plainChunk,
          additionalData: ad,
          nonce: chunkNonce,
          key: secureKey,
        ));

        final lenBuf = ByteData(4)..setUint32(0, encrypted.length, Endian.big);
        await waf.writeFrom(lenBuf.buffer.asUint8List());
        await waf.writeFrom(encrypted);

        offset += readSize;
        chunkIdx++;
      }
    } finally {
      await raf.close();
      await waf.close();
      secureKey.dispose();
    }

    return (key: keyBytes, nonce: nonce);
  }

  /// Decrypt file using key and nonce. Auto-detects v1/v2/v3 format.
  Future<Uint8List> decryptFileAuto(
    File input,
    Uint8List keyBytes,
    Uint8List nonce,
  ) async {
    final header = await _readFileHeader(input);
    if (_isV3Magic(header)) {
      return _decryptFileV3(input, keyBytes, nonce);
    }
    if (_isV2Magic(header)) {
      return _decryptFileV2(input, keyBytes, nonce);
    }
    // Legacy v1: read entire file and decrypt as single blob
    final ciphertext = await input.readAsBytes();
    return decrypt(ciphertext, Uint8List.fromList(keyBytes), nonce);
  }

  /// Decrypt v2 streaming file. Peak memory ≈ max(plainChunkSize) per chunk.
  Future<Uint8List> _decryptFileV2(
    File input,
    Uint8List keyBytes,
    Uint8List nonce,
  ) async {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final secureKey = SecureKey.fromList(_sodium, keyBytes);

    final raf = await input.open(mode: FileMode.read);
    try {
      final fileLen = await raf.length();

      // Read header
      await raf.setPosition(0);
      final magicBuf = await raf.read(4);
      final csBuf = await raf.read(4);
      if (magicBuf.length < 4 || csBuf.length < 4) {
        throw StateError('Truncated v2 file header');
      }
      // chunkPlainSize from header (for future-proofing, not currently used in decrypt)
      // final storedChunkSize = ByteData.sublistView(csBuf).getUint32(0, Endian.big);

      final output = BytesBuilder(copy: false);
      int chunkIdx = 0;
      int pos = 8; // after header

      while (pos < fileLen) {
        await raf.setPosition(pos);
        final lenBytes = await raf.read(4);
        if (lenBytes.length < 4) break;
        final encLen = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
        pos += 4;

        await raf.setPosition(pos);
        final encChunk = await raf.read(encLen);
        if (encChunk.length < encLen) {
          throw StateError('Truncated chunk $chunkIdx: expected $encLen, got ${encChunk.length}');
        }
        pos += encLen;

        final chunkNonce = _deriveChunkNonce(nonce, chunkIdx);
        final plain = aead.decrypt(
          cipherText: encChunk,
          additionalData: null,
          nonce: chunkNonce,
          key: secureKey,
        );
        output.add(plain);
        chunkIdx++;
      }

      return output.toBytes();
    } finally {
      await raf.close();
      secureKey.dispose();
    }
  }

  /// Decrypt v3 (SF03) streaming file — with authenticated metadata.
  Future<Uint8List> _decryptFileV3(
    File input,
    Uint8List keyBytes,
    Uint8List nonce,
  ) async {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final secureKey = SecureKey.fromList(_sodium, keyBytes);

    final raf = await input.open(mode: FileMode.read);
    try {
      final fileLen = await raf.length();

      await raf.setPosition(0);
      final magicBuf = await raf.read(4);
      final csBuf    = await raf.read(4);
      final tcBuf    = await raf.read(4);
      if (magicBuf.length < 4 || csBuf.length < 4 || tcBuf.length < 4) {
        throw StateError('Truncated SF03 header');
      }
      final totalChunks = ByteData.sublistView(tcBuf).getUint32(0, Endian.big);

      final output = BytesBuilder(copy: false);
      int chunkIdx = 0;
      int pos = 12; // after 12-byte SF03 header

      while (pos < fileLen) {
        await raf.setPosition(pos);
        final lenBytes = await raf.read(4);
        if (lenBytes.length < 4) break;
        final encLen = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
        pos += 4;

        await raf.setPosition(pos);
        final encChunk = await raf.read(encLen);
        if (encChunk.length < encLen) {
          throw StateError('Truncated SF03 chunk $chunkIdx');
        }
        pos += encLen;

        final ad = _buildChunkAD(totalChunks, chunkIdx);
        final chunkNonce = _deriveChunkNonce(nonce, chunkIdx);
        final plain = aead.decrypt(
          cipherText: encChunk,
          additionalData: ad,
          nonce: chunkNonce,
          key: secureKey,
        );
        output.add(plain);
        chunkIdx++;
      }

      if (chunkIdx != totalChunks) {
        throw StateError(
            'SF03 chunk count mismatch: expected $totalChunks, got $chunkIdx');
      }
      return output.toBytes();
    } finally {
      await raf.close();
      secureKey.dispose();
    }
  }

  /// Build authenticated data for chunk [chunkIdx] in a file with [totalChunks].
  /// AD = magic3(4) + chunkPlainSize(4) + totalChunks(4) + chunkIdx(8) = 20 bytes.
  Uint8List _buildChunkAD(int totalChunks, int chunkIdx) {
    final ad = ByteData(20);
    // magic3 "SF03"
    ad.setUint8(0, 0x53); ad.setUint8(1, 0x46); ad.setUint8(2, 0x30); ad.setUint8(3, 0x33);
    ad.setUint32(4, chunkPlainSize, Endian.big);
    ad.setUint32(8, totalChunks, Endian.big);
    ad.setInt64(12, chunkIdx, Endian.big);
    return ad.buffer.asUint8List();
  }

  /// Derive a unique nonce for chunk [index] by XOR'ing the last 8 bytes
  /// of [baseNonce] with the big-endian chunk index.
  static Uint8List _deriveChunkNonce(Uint8List baseNonce, int index) {
    final n = Uint8List.fromList(baseNonce);
    final idxBuf = ByteData(8)..setInt64(0, index, Endian.big);
    final idxBytes = idxBuf.buffer.asUint8List();
    // XOR last 8 bytes of the 24-byte nonce
    for (int i = 0; i < 8; i++) {
      n[16 + i] ^= idxBytes[i];
    }
    return n;
  }

  static Future<Uint8List> _readFileHeader(File f) async {
    final raf = await f.open(mode: FileMode.read);
    try {
      return await raf.read(4);
    } finally {
      await raf.close();
    }
  }

  static bool _isV2Magic(Uint8List header) {
    if (header.length < 4) return false;
    return header[0] == 0x53 && header[1] == 0x46 &&
           header[2] == 0x30 && header[3] == 0x32; // "SF02"
  }

  static bool _isV3Magic(Uint8List header) {
    if (header.length < 4) return false;
    return header[0] == 0x53 && header[1] == 0x46 &&
           header[2] == 0x30 && header[3] == 0x33; // "SF03"
  }

  /// Calculate encrypted file size for v3 (SF03) format.
  static int v2EncryptedSize(int plaintextSize) {
    final numChunks =
        plaintextSize == 0 ? 0 : (plaintextSize + chunkPlainSize - 1) ~/ chunkPlainSize;
    // magic(4) + chunkSize(4) + totalChunks(4) + N*(lenPrefix(4) + plainChunk + aeadTag(16))
    return 4 + 4 + 4 + numChunks * 4 + plaintextSize + numChunks * 16;
  }
}

class EncryptedFile {
  final Uint8List ciphertext;
  final Uint8List key;   // 32 bytes — store encrypted in DB
  final Uint8List nonce; // 24 bytes

  const EncryptedFile({
    required this.ciphertext,
    required this.key,
    required this.nonce,
  });
}
