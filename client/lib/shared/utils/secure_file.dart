import 'dart:io';
import 'dart:typed_data';

import 'logger.dart';

/// Securely delete a file: overwrite with zeros before unlinking.
///
/// This prevents recovery of plaintext from flash storage sectors.
/// Best-effort: if overwrite fails, still attempts deletion.
Future<void> secureDeleteFile(File file) async {
  try {
    if (!await file.exists()) return;
    final length = await file.length();
    if (length > 0) {
      final raf = await file.open(mode: FileMode.writeOnly);
      try {
        // Overwrite with zeros in 64KB chunks to bound memory
        const chunkSize = 64 * 1024;
        final zeros = Uint8List(chunkSize < length ? chunkSize : length);
        int written = 0;
        while (written < length) {
          final toWrite = (length - written) < chunkSize
              ? (length - written)
              : chunkSize;
          await raf.writeFrom(zeros, 0, toWrite);
          written += toWrite;
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
    }
    await file.delete();
  } catch (e) {
    AppLogger.w('SecureFile', 'secure delete failed for ${file.path}: $e');
    // Last resort: try plain delete
    try {
      await file.delete();
    } catch (_) {}
  }
}
