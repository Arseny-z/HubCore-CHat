import 'dart:convert';
import 'dart:typed_data';

// ── Wire types for file transfer protocol ──────────────────────────────────

/// Sent first by the sender (DR-encrypted) to announce the incoming file.
class FileOffer {
  final String    tid;    // hex-16 transfer ID
  final String    name;
  final String    mime;
  final int       size;   // plaintext bytes
  final int       chunks; // total chunk count
  final Uint8List key;    // 32-byte file encryption key
  final Uint8List nonce;  // 24-byte nonce
  /// Optional group ID. When set, receiver places the file in the group chat.
  final String?   groupId;
  /// Sender's TTL for this conversation (seconds). Receiver applies it when
  /// the file message is saved so both sides expire at the same time.
  ///
  /// [ttlSeconds] == null means field is absent (old client / unknown).
  /// [ttlSeconds] == 0    means sender explicitly turned TTL off.
  final int?      ttlSeconds;
  /// Shared message ID used for read receipts on both sides.
  final String?   mid;
  /// Total encrypted file size (v2 format). If null, receiver uses size+16 (v1).
  final int?      encSize;

  const FileOffer({
    required this.tid,
    required this.name,
    required this.mime,
    required this.size,
    required this.chunks,
    required this.key,
    required this.nonce,
    this.groupId,
    this.ttlSeconds,
    this.mid,
    this.encSize,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'type':   'file_offer',
        'tid':    tid,
        'name':   name,
        'mime':   mime,
        'size':   size,
        'chunks': chunks,
        'key':    base64.encode(key),
        'nonce':  base64.encode(nonce),
        if (groupId != null) 'gid': groupId,
        't':      ttlSeconds ?? 0,
        if (mid != null) 'mid': mid,
        if (encSize != null) 'es': encSize,
      })));

  static FileOffer? tryDecode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['type'] != 'file_offer') return null;
      return FileOffer(
        tid:        m['tid']    as String,
        name:       m['name']   as String,
        mime:       m['mime']   as String,
        size:       m['size']   as int,
        chunks:     m['chunks'] as int,
        key:        base64.decode(m['key']   as String),
        nonce:      base64.decode(m['nonce'] as String),
        groupId:    m['gid']    as String?,
        ttlSeconds: m.containsKey('t') ? (m['t'] as int) : null,
        mid:        m['mid']    as String?,
        encSize:    m['es']     as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Raw (non-DR) data chunk carrying a slice of the encrypted file.
class FileChunk {
  final String    tid;
  final int       idx;
  final int       tot;
  final Uint8List data;

  const FileChunk({
    required this.tid,
    required this.idx,
    required this.tot,
    required this.data,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'type': 'file_chunk',
        'tid':  tid,
        'idx':  idx,
        'tot':  tot,
        'data': base64.encode(data),
      })));

  static FileChunk? tryDecode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['type'] != 'file_chunk') return null;
      return FileChunk(
        tid:  m['tid']  as String,
        idx:  m['idx']  as int,
        tot:  m['tot']  as int,
        data: base64.decode(m['data'] as String),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Raw (non-DR) acknowledgement sent by the receiver back to the sender.
class FileAck {
  final String    tid;
  final List<int> received;
  final List<int> missing;
  final bool      done;

  const FileAck({
    required this.tid,
    required this.received,
    required this.missing,
    required this.done,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'type':     'file_ack',
        'tid':      tid,
        'received': received,
        'missing':  missing,
        'done':     done,
      })));

  static FileAck? tryDecode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (m['type'] != 'file_ack') return null;
      return FileAck(
        tid:      m['tid'] as String,
        received: (m['received'] as List).cast<int>(),
        missing:  (m['missing']  as List).cast<int>(),
        done:     m['done'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}
