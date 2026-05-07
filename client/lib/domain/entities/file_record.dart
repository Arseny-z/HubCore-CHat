import 'dart:typed_data';

class FileRecord {
  final int? id;
  final int? messageId;
  final Uint8List fileKey;   // 32-byte XChaCha20-Poly1305 key
  final Uint8List fileNonce; // 24-byte nonce
  final String localPath;    // path to encrypted file on disk
  final String? mimeType;
  final int sizeBytes;
  final int createdAt;

  const FileRecord({
    this.id,
    this.messageId,
    required this.fileKey,
    required this.fileNonce,
    required this.localPath,
    this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
  });

  factory FileRecord.fromMap(Map<String, dynamic> m) => FileRecord(
        id: m['id'] as int?,
        messageId: m['message_id'] as int?,
        fileKey: _toUint8List(m['file_key']),
        fileNonce: _toUint8List(m['file_nonce']),
        localPath: m['local_path'] as String,
        mimeType: m['mime_type'] as String?,
        sizeBytes: m['size_bytes'] as int,
        createdAt: m['created_at'] as int,
      );

  static Uint8List _toUint8List(dynamic v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(v.cast<int>());
    throw ArgumentError('Cannot convert ${v.runtimeType} to Uint8List');
  }

  Map<String, dynamic> toMap() => {
        if (messageId != null) 'message_id': messageId,
        'file_key': fileKey,
        'file_nonce': fileNonce,
        'local_path': localPath,
        if (mimeType != null) 'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'created_at': createdAt,
      };
}
