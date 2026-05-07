# HubCore Chat Architecture

## Overview

HubCore Chat is a fully P2P messenger with E2EE. The transport layer is the **Yggdrasil overlay network**. Each phone gets a permanent IPv6 address derived from its public key. Messages travel directly between devices — no servers.

**Principle:** no servers, no intermediaries. Only direct encrypted connections between devices over the Yggdrasil mesh.

---

## Network Diagram

```
Phone A                      Yggdrasil network                     Phone B
fd00::a1b2                                                    fd00::c3d4
(carrier, CGNAT)             ┌──────────┐              (carrier, CGNAT)
     │                       │  Peer MSK│                        │
     │    TLS                │  Peer SPB│                TLS     │
     └──────────────────────►│  Peer EKB│◄───────────────────────┘
                             │  Peer NSK│
                             └──────────┘

Delivery (recipient online):
A → [Yggdrasil peers] → B  (directly via fd00:: address)

Recipient offline:
Message waits in sender's queue and is delivered on next connection.
```

---

## Components

### 1. Flutter Client (Android)

The only user-facing application. Includes:

- **Yggdrasil node** — embedded via gomobile `.aar`, runs as a foreground service
- **Crypto core** — Double Ratchet, Sender Keys, XChaCha20-Poly1305
- **SQLCipher database** — encrypted local storage
- **Network layer** — direct connections over the Yggdrasil overlay

```
┌─────────────────────────────────────────┐
│            Flutter Client               │
│                                         │
│  UI Layer        — screens, widgets     │
│  Business Layer  — Riverpod providers   │
│  Crypto Layer    — Double Ratchet,      │
│                    Sender Keys          │
│  Storage Layer   — SQLCipher, Keystore  │
│  Network Layer   — Yggdrasil P2P        │
│  Yggdrasil Node  — overlay transport    │
└─────────────────────────────────────────┘
```

### 2. Yggdrasil Node (embedded in APK)

- Go library compiled via gomobile
- Starts automatically on app launch
- Connects to public peers (editable list)
- Generates a permanent `fd00::...` address from PrivateKey
- PrivateKey stored in SQLCipher (address is stable across restarts)
- Supports: TLS, QUIC, TCP peers; multicast LAN discovery

**Built-in peers (Russia):**
```
tls://ygg-msk-1.averyan.ru:8362      — Moscow
tls://ekb.itrus.su:7992              — Ekaterinburg
tls://srv.itrus.su:7992              — Omsk
tls://45.147.200.202:443             — Moscow VPS
tls://ip4.01.msk.ru.dioni.su:9003   — Moscow 10Gbit
```

---

## Data Flows

### First Contact (QR Exchange)

```
1. Alice shows QR: {masterPub, signingPub, yggAddr}
2. Bob scans → saves locally
3. Yggdrasil address is cached by Bob permanently
4. All subsequent connections — directly via fd00:: address
```

### Sending a Message (recipient online)

```
1. Get fd00::bob from local contact cache
2. Open connection to fd00::bob directly via Yggdrasil
3. Encrypt message (Double Ratchet)
4. Send directly — no servers
5. Receive confirmation
```

### File Transfer

```
1. Get fd00::bob from local cache
2. Open P2P connection to fd00::bob
3. Encrypt file with XChaCha20-Poly1305 (unique key)
4. Transfer in chunks with progress
5. File key is sent first (encrypted with session key)
```

Files are transferred **only when the recipient is online**, with no storage anywhere.

---

## User Identity

```
MASTER KEY (permanent)
  Ed25519 keypair
  master_pubkey = permanent user ID
  Shared via QR code
  Stored in Android Keystore

SIGNING KEY (rotatable, weekly)
  Ed25519 keypair
  Signs messages
  Certified by Master Key (SigningCert)

YGGDRASIL KEY (permanent)
  Ed25519 keypair
  Determines fd00:: address on the network
  Stored in SQLCipher

Fingerprint (for verification):
  BLAKE3(master_pubkey)[0:16] → "3985-1406-D404-6E6A"
  Compared verbally / in person
```

---

## Client Storage

```
SQLCipher Database (encrypted with DBKey):
├── contacts        — pubkeys, aliases, ygg_addr, signing_pub
├── sessions        — Double Ratchet states
├── messages        — chat history
├── groups          — group membership, Sender Keys states
├── files           — file metadata
└── settings        — settings, peer list

Android Keystore:
├── master_key      — Ed25519 master privkey
├── signing_key     — Ed25519 signing privkey
└── db_key          — SQLCipher key

SQLCipher (additionally):
└── yggdrasil_key   — Ed25519 privkey (permanent Ygg address)
```

---

## Transport Security

**What ISP/carrier can see:**
- IP of the public Yggdrasil peer (not the peer's address)
- TLS traffic (encrypted)
- Cannot see: who you talk to, content, Yggdrasil addresses

**Triple encryption:**
```
[Double Ratchet message]     ← layer 1: E2EE content
  ↓ wrapped in
[Yggdrasil packet]           ← layer 2: transport encryption (Ed25519+ChaCha20)
  ↓ sent over
[TLS connection to peer]     ← layer 3: TLS to nearest peer
```

**Metadata protection:**
```
Without HubCore Chat:  ISP sees recipient IP
With HubCore Chat:     ISP sees Yggdrasil peer IP — same for all users
                social graph not revealed: no lookup, addresses cached locally
```

---

## Project Structure

```
HubCore-Chat/
├── yggbind/                — Yggdrasil Go bindings (gomobile)
│   ├── yggbind.go          — Node API: start, send, receive, peers
│   └── yggbind.aar         — compiled AAR
├── client/                 — Flutter client
│   ├── lib/
│   │   ├── domain/         — entities, use cases, ports
│   │   ├── application/    — business logic
│   │   ├── network/        — message router, transports
│   │   ├── storage/        — SQLCipher DAO
│   │   ├── yggdrasil/      — Dart MethodChannel wrapper
│   │   └── features/       — chat, contacts, groups, settings
│   ├── android/libs/       — yggbind.aar
│   └── pubspec.yaml
└── docs/
```
