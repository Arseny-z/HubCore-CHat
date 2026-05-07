# HubCore Chat

Serverless P2P messenger with E2E encryption. No registration, no phone number, no central server.

## Principles

- **No central storage** — messages are stored only on users' devices
- **E2EE** — messages are encrypted on the sender's device and decrypted only on the recipient's device
- **Key-based identity** — no registration, just QR code exchange
- **Yggdrasil transport** — built-in decentralized overlay network, works through any NAT and mobile internet
- **Reticulum transport** — fallback transport over TCP/WiFi, LoRa/BLE planned
- **P2P file transfer** — large files are sent directly between devices

## Cryptography

| Purpose | Algorithm |
|---|---|
| Identity | Ed25519 (permanent Master Key + rotatable Signing Key) |
| Key exchange | X25519 (ECDH) |
| Message encryption | XChaCha20-Poly1305 (Double Ratchet) |
| File encryption | XChaCha20-Poly1305 (streaming SF02) |
| Direct chats | Double Ratchet Protocol |
| Group chats | Sender Keys + DH Ratchet |
| Local storage | SQLCipher (AES-256) |
| Transport | Yggdrasil (Curve25519 + ChaCha20) |

## Components

| Component | Stack | Description |
|---|---|---|
| Flutter client | Flutter/Dart | Android 6+ |
| Yggdrasil node | Go (embedded in APK) | Transport layer, overlay network |
| Reticulum node | Go (embedded in APK) | Fallback transport |

## Transport Architecture

```
Phone A                      Yggdrasil network                     Phone B
(carrier, CGNAT)                                             (carrier, CGNAT)
fd00::a1b2                   public peers                    fd00::c3d4
    │                                                              │
    └──────────────────────────────────────────────────────────►  │
                         encrypted tunnel
```

Each phone gets a **permanent IPv6 address** (`fd00::...`) derived from its public key. The address never changes.

If the recipient is offline, the message stays in a local queue on the sender's device and is delivered on next connection.

## Getting Started

Just install the APK:

1. Install APK
2. Create a PIN
3. Exchange QR codes with a contact
4. Send a message

No server configuration needed. Yggdrasil and Reticulum start automatically inside the app.

## Documentation

- [ROADMAP.md](ROADMAP.md) — development roadmap
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system architecture
- [docs/CRYPTO.md](docs/CRYPTO.md) — cryptographic protocol
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — wire protocol
- [docs/SECURITY.md](docs/SECURITY.md) — threat model

## Repository Structure

```
HubCore-Chat/
├── client/     — Flutter client (Android)
├── docs/       — documentation
├── rnsbind/    — Go binding for Reticulum (.aar)
├── hubcorebind/ — Go binding (Yggdrasil + Reticulum, final .aar)
├── yggbind/    — Go binding for Yggdrasil (.aar)
└── ROADMAP.md
```

## License

GPL-3.0 — see [LICENSE](LICENSE).
