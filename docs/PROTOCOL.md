# Wire Protocol

All messages are serialized with **MessagePack**. Transport: WebSocket (binary frame) or direct P2P connection.

## Message Types

```
MessageType:
  10  HANDSHAKE_INIT       — session establishment (X3DH)
  11  HANDSHAKE_RESPONSE   — handshake response
  20  MESSAGE              — encrypted message
  21  MESSAGE_ACK          — delivery acknowledgement
  30  FILE_OFFER           — file transfer offer
  31  FILE_ACCEPT          — accept file
  32  FILE_REJECT          — reject file
  33  FILE_CHUNK           — file chunk
  34  FILE_COMPLETE        — file fully transferred
  40  GROUP_CREATE         — create group
  41  GROUP_ADD_MEMBER     — add member
  42  GROUP_REMOVE_MEMBER  — remove member
  43  GROUP_KEY_ROTATION   — rotate group keys
  44  GROUP_MESSAGE        — group message
  50  WEBRTC_OFFER         — SDP offer (signaling)
  51  WEBRTC_ANSWER        — SDP answer
  52  WEBRTC_ICE           — ICE candidate
  60  KEY_PACKAGE          — upload KeyPackage
  61  KEY_PACKAGE_REQUEST  — request KeyPackage
  70  PING                 — heartbeat
  71  PONG
  80  ERROR                — error
```

## Envelope (wrapper for all messages)

```msgpack
Envelope {
  v:    uint8         // protocol version, current = 1
  t:    uint8         // MessageType
  id:   bytes[16]     // random message ID (for deduplication)
  from: bytes[32]     // Ed25519 pubkey of sender
  to:   bytes[32]     // Ed25519 pubkey of recipient (or group_id)
  ts:   uint64        // unix timestamp (milliseconds)
  sig:  bytes[64]     // Ed25519 signature of entire envelope except sig
  body: bytes         // encrypted payload (type-specific)
}
```

Signature: `sig = Ed25519.sign(privkey, v || t || id || from || to || ts || body)`

## Direct Messages

### HANDSHAKE_INIT (type: 10)

```msgpack
HandshakeInit {
  ek:  bytes[32]   // ephemeral X25519 pubkey Alice
  pk:  bytes[32]   // prekey Bob (from KeyPackage)
  ct:  bytes       // ChaCha20-Poly1305(shared_secret, initial_message)
}
```

### HANDSHAKE_RESPONSE (type: 11)

```msgpack
HandshakeResponse {
  ek:  bytes[32]   // ephemeral X25519 pubkey Bob
  ct:  bytes       // encrypted response
}
```

### MESSAGE (type: 20)

```msgpack
MessagePayload {
  ct:   bytes      // ChaCha20-Poly1305(MessageKey, plaintext)
  n:    uint64     // message counter (in ratchet chain)
  pn:   uint64     // previous chain message count (for skipped keys)
  ek:   bytes[32]  // new ephemeral DH key (if DH ratchet step)
  // ek present only on DH ratchet (every 100 messages)
}

Plaintext (before encryption):
  ContentMessage {
    type:    uint8    // 1=text, 2=file_ref, 3=voice, 4=video_circle
    text:    string   // if type=1
    file_id: bytes[16] // if type=2,3,4 — reference to FileRecord
    reply_to: bytes[16] // optional, quoted message ID
  }
```

### MESSAGE_ACK (type: 21)

```msgpack
MessageAck {
  msg_id: bytes[16]   // ID of acknowledged message
  status: uint8       // 1=delivered, 2=read
}
```

## File Transfer

### FILE_OFFER (type: 30)

```msgpack
FileOffer {
  file_id:   bytes[16]    // random file ID
  name:      string       // file name
  size:      uint64       // size in bytes (original)
  mime:      string       // MIME type
  chunks:    uint32       // number of chunks
  file_key:  bytes        // ChaCha20-Poly1305(session_key, FileKey)
  file_hash: bytes[32]    // BLAKE3 hash of original file
}
```

### FILE_CHUNK (type: 33)

```msgpack
FileChunk {
  file_id: bytes[16]
  index:   uint32      // chunk index
  data:    bytes       // encrypted chunk (ChaCha20-Poly1305)
}
```

## Group Messages

### GROUP_CREATE (type: 40)

```msgpack
GroupCreate {
  group_id:   bytes[16]   // random group ID
  name:       string      // group name
  members:    [{          // member list
    pubkey:   bytes[32]
    enc_sk:   bytes       // ChaCha20-Poly1305(session_key_member, sender_chain_key)
  }]
}
```

### GROUP_KEY_ROTATION (type: 43)

```msgpack
GroupKeyRotation {
  group_id:  bytes[16]
  epoch:     uint64     // epoch counter (monotonic)
  members:   [{
    pubkey:  bytes[32]
    enc_sk:  bytes      // new sender_chain_key encrypted for member
  }]
  reason:    uint8      // 1=periodic, 2=member_removed, 3=manual
}
```

### GROUP_MESSAGE (type: 44)

```msgpack
GroupMessagePayload {
  group_id: bytes[16]
  epoch:    uint64      // key epoch (must match for all members)
  counter:  uint64      // counter in sender's ratchet chain
  ct:       bytes       // ChaCha20-Poly1305(MessageKey, plaintext)
}
```

## WebRTC Signaling

### WEBRTC_OFFER (type: 50)

```msgpack
WebRTCOffer {
  session_id: bytes[16]
  sdp:        string    // SDP offer (encrypted with session key)
}
```

### WEBRTC_ICE (type: 52)

```msgpack
WebRTCIce {
  session_id:  bytes[16]
  candidate:   string   // ICE candidate JSON
}
```

## Versioning

The `v` field in Envelope is the protocol version. Current: `1`.

On breaking changes the version is incremented. The client shows a warning if versions are incompatible.

## Padding

All encrypted payloads are padded to a block boundary to protect against size analysis:

```
Text messages:   padding to 256 bytes (small) or 1KB
File metadata:   padding to 512 bytes
Group messages:  padding to 1KB
```
