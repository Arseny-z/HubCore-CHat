# Relay Removal and Migration to RNS Propagation

> Relay was a centralized server. HubCore Chat is a P2P messenger without servers.
> Relay is removed; its role (offline delivery) moves to RNS propagation nodes
> and the local send_queue on the sender's device.

---

## Current State

### What exists
- `RelayClient` — HTTP + WebSocket client to relay server
- `RelayTransport` — transport adapter for CompositeTransport
- `relayClientProvider` — provider, disabled by default (empty URL)
- `Envelope` class in `relay_client.dart` — wire format, used **everywhere** (27 files)
- `send_queue` — local queue on device, retry on contact appearance

### What's wrong
- Relay contradicts the "no servers" model
- Relay sees metadata (who writes to whom, when, size)
- Relay is a single point of failure
- No UI for relay_url configuration (effectively dead code)

---

## Removal Plan

### Phase D1 — Move Envelope to domain layer ✅
**~30 min**

`Envelope` (from/to/body) — basic wire format. It doesn't belong to relay —
it's a common message wrapper.

- [x] Create `client/lib/domain/entities/envelope.dart`
  - Move `class Envelope` + `toJson()` / `fromJson()`
- [x] Update all 27 imports: `relay_client.dart` → `envelope.dart`
- [x] Verify compilation

### Phase D2 — Delete Relay code ✅
**~1 hour**

- [x] Delete `client/lib/network/relay_client.dart`
- [x] Delete `client/lib/infrastructure/transport/relay_transport.dart`
- [x] Delete `relayClientProvider` from `transport_providers.dart`
- [x] Delete `TransportProtocol.relay` and `TransportProtocol.signal`
- [x] Delete `RelayTransport` from `compositeTransportProvider`
- [x] Delete relay from `TransportStatus` and `transportStatusProvider`
- [x] Delete `relay_url` from default settings in `database.dart`
- [x] Delete relay mentions from UI (`chat_widgets.dart`, settings)

### Phase D3 — Cleanup and verification ✅
**~30 min**

- [x] `flutter analyze` — no errors
- [x] Grep 'relay' — no mentions (except ROADMAP docs)
- [x] Verify CompositeTransport works without relay
- [x] Verify send_queue retry works (not dependent on relay)

---

## RNS Propagation — Relay Replacement

### Why propagation node is needed

Without relay and without propagation:
```
A wants to send to B → B is offline → A holds in send_queue →
A must be online when B appears → if A also goes offline — message not delivered
```

With propagation node:
```
A sends → RNS propagation node stores →
A goes offline → B appears → receives from propagation node
```

Propagation node is **not a server**. It's any RNS node with propagation enabled.
Can be:
- Public community node
- User's own server (VPS, Raspberry Pi)
- Another network participant's phone (in the future)

### Phase P1 — API Research
**~1-2 days**

- [ ] Study go-reticulum propagation API (Resource/Link)
- [ ] Determine: are raw RNS packets sufficient or is LXMF needed
- [ ] Assess: what needs to be added to `rnsbind.go`
- [ ] Prototype: sending via propagation node from Go code

**Key question:** go-reticulum v1.1.4 may not contain propagation client.
Options:
- a) Update go-reticulum (if new version supports it)
- b) Add propagation client to rnsbind manually
- c) Use RNS Resource API (file-like transfer with confirmation)

### Phase P2 — Go bindings for propagation
**~3-5 days**

- [ ] Add to `rnsbind.go`:
  ```go
  func (n *Node) SendViaPropagation(destHash string, data []byte) error
  func (n *Node) SetPropagationNode(nodeHash string) error
  func (n *Node) PropagationNodeStatus() string // "connected"/"disconnected"/"none"
  ```
- [ ] Propagation node configuration in `Start()` parameters
- [ ] Rebuild `hubcorebind.aar`

### Phase P3 — Dart integration
**~2-3 days**

- [ ] `ReticulumNode.sendViaPropagation(destHash, data)` — MethodChannel
- [ ] `ReticulumNode.setPropagationNode(nodeHash)` — configuration
- [ ] `ReticulumNode.propagationStatus` — connection status
- [ ] Update `ReticulumTransport.send()`:
  - First attempt direct delivery
  - If no path → send via propagation node
- [ ] Update `QueueService`:
  - On send via propagation: mark `ack_pending`
  - Remove from queue only on `msg_delivered` receipt

### Phase P4 — Settings UI
**~1 day**

- [ ] Settings → Network → Propagation Node
  - Field: hash or hostname of propagation node
  - Status: connected / disconnected / none
  - Toggle: use propagation for offline delivery
- [ ] Status bar indicator: "prop" when propagation node available

### Phase P5 — Testing
**~1-2 days**

- [ ] Test: A sends to B via propagation → A goes offline → B appears → receives
- [ ] Test: propagation node unavailable → fallback to send_queue
- [ ] Test: propagation + direct → dedup (message not duplicated)
- [ ] Test: large file via propagation (chunking)

---

## Execution Order

```
D1 (move Envelope)
  │
  └── D2 (delete relay)
        │
        └── D3 (cleanup)
              │
              └── P1 (research propagation API)
                    │
                    └── P2 (Go bindings)
                          │
                          └── P3 (Dart integration)
                                │
                                ├── P4 (Settings UI)
                                │
                                └── P5 (testing)
```

**D1-D3 can be done now** — relay is dead code, its removal breaks nothing.
**P1-P5 require Go work** — separate sprint after D phase.

---

## Estimates

| Phase | Work | Estimate |
|-------|------|----------|
| D1 | Move Envelope | 30 min |
| D2 | Delete relay | 1 hour |
| D3 | Cleanup + verification | 30 min |
| P1 | Research propagation API | 1-2 days |
| P2 | Go bindings | 3-5 days |
| P3 | Dart integration | 2-3 days |
| P4 | Settings UI | 1 day |
| P5 | Testing | 1-2 days |

**Relay removal (D1-D3):** ~2 hours ✅ Done
**RNS Propagation (P1-P5):** ~1-2 weeks

---

## What remains for offline delivery after relay removal

1. **send_queue** (already works) — sender stores, retry on contact_hello
2. **Yggdrasil** — direct delivery when both online
3. **Reticulum direct** — delivery via LoRa/WiFi when both in range
4. **RNS propagation** (after P1-P5) — store-and-forward via decentralized nodes

Without propagation (D phase only): sender must be online when recipient appears. This is acceptable — all serverless P2P messengers work this way (Briar, for example).

---

## Principles

1. **No servers.** Propagation node is a network participant, not a server
2. **send_queue — safety net.** Even with propagation, device queue remains
3. **Graceful degradation.** No propagation → no LoRa → no WiFi → send_queue
4. **Transport-agnostic.** DR and Sender Keys don't change
5. **One APK.** Everything embedded, nothing needs separate installation
