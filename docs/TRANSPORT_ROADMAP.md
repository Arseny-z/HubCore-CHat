# Transport Delivery Roadmap

## Goal

Universal delivery module: message is sent via the optimal protocol,
automatically switches to fallback if unavailable, stays in queue
until receipt confirmed.

---

## Current State

| Component | Status |
|---|---|
| `TransportPort` abstraction | ✅ clean, extensible |
| `YggdrasilTransport` | ✅ implemented |
| `ReticulumTransport` | 🔴 stub |
| `MeshcoreTransport` | 🔴 stub |
| `CompositeTransport.send()` | ✅ fallback by priority |
| `CompositeTransport.sendEnvelope()` | ❌ hardcoded Yggdrasil |
| `Contact.transportAddresses` | ✅ Map in DB schema |
| `QueueRecipient` | ❌ only `ygg` field |
| `QueueService._trySend()` | ❌ only `yggPubKeyHex` |
| `MessageRouter` | ❌ only `destYggPubKeyHex` |
| `contact_hello` payload | ❌ only `yk` (Ygg key) |
| `ConnectivityWatcher` | ❌ only Yggdrasil peers |
| Delivery-based queue | ❌ deletes on transport success |

---

## Phase 1 — sendEnvelope → multi-protocol

**Goal:** remove hardcoded Yggdrasil from the send point.

### Changes

**`composite_transport.dart`**
- Rewrite `sendEnvelope(Envelope, destYggPubKeyHex?)` →
  `sendEnvelope(Envelope, Map<String,String> transportAddresses)`
- Inside: for each address from map build `TransportAddress(protocol, value)`,
  call common `send()` by priority
- Return `TransportResult` with the protocol name that succeeded

**`queue_service.dart`**
- `sendOrQueue()`: pass `contact.transportAddresses` instead of `yggPubKeyHex`
- `_trySend()`: same on retry

**`message_router.dart`**
- `_sendRawEnvelope()`, `_broadcastHello()`: use `contact.transportAddresses`

### Result
- When Reticulum/Meshcore are implemented — they'll work automatically
- No DB migration needed (`transportAddresses` already in schema)

### Risks
- Ensure `contact.transportAddresses` is populated on hello exchange
- Backward compatibility: old contacts without `transportAddresses` — fallback to `yggPubKeyHex`

---

## Phase 2 — Delivery-based queue

**Goal:** message stays in queue until `msg_delivered` receipt received,
not removed on transport success.

### Changes

**`send_queue_dao.dart`**
- Add `ack_pending INTEGER DEFAULT 0` field to `send_queue` table
- Add `setPendingAck(id)` and `deleteByMessageId(messageId)` methods

**`queue_service.dart`**
- `_trySend()`: on transport success → `setPendingAck(id)`, message status `sent`
  (do not delete record)
- Add retry for `ack_pending` records: if no receipt after 5 min → retry
- `dueForRetry()` in DAO: include `ack_pending=1 AND next_retry <= now`

**`process_receipt_use_case.dart`**
- On `msg_delivered` → `sendQueue.deleteByMessageId(messageId)`

**UI**
- Status `sent` (1 tick) = sent, waiting for receipt
- Status `delivered` (2 ticks) = receipt received, removed from queue

### Result
- Packet went to Yggdrasil, but recipient offline → retry after 5 min
- Recipient comes online → receipt arrives → record removed from queue

### Risks
- Message duplication on retry (DR ratchet re-encrypt creates new counter)
- Solution: receiver deduplicates by `messageId` (already in `ReceiveEnvelopeUseCase`)

---

## Phase 3 — QueueRecipient multi-protocol

**Goal:** queue stores all recipient addresses, retry uses optimal protocol.

### Changes

**`send_queue_dao.dart`**
- `QueueRecipient`: add `transportAddresses: Map<String,String>` instead of only `ygg`
- JSON serialization: `{"pub":"...","addrs":{"yggdrasil":"...","reticulum":"..."}}`
- Backward compatibility: on deserializing old records (`ygg` field) auto-convert to `{"yggdrasil": ygg}`

**`queue_service.dart`**
- On queue: take full `contact.transportAddresses`
- `_trySend()`: pass `entry.recipients.first.transportAddresses` to `sendEnvelope()`

### Result
- Retry on connection restore uses whichever protocol is available
- If Ygg unavailable but Reticulum exists → message gets through

---

## Phase 4 — contact_hello multi-protocol

**Goal:** on hello exchange contacts learn all each other's addresses.

### Changes

**`hello_use_case.dart`**
- Add `rk` (Reticulum), `mk` (Meshcore) fields to payload when corresponding transports active
- Format:
  ```json
  {
    "type": "contact_hello",
    "xk": "<base64 X25519>",
    "yk": "<hex Ygg>",
    "rk": "<hex Reticulum>",
    "mk": "<hex Meshcore>"
  }
  ```

**`receive_envelope_use_case.dart`**
- On parsing hello: if `rk` present → `updateTransportAddress(pub, 'reticulum', rk)`
- If `mk` present → `updateTransportAddress(pub, 'meshcore', mk)`

### Result
- Contacts automatically learn new addresses on each hello
- Backward compatibility: old clients without `rk`/`mk` work as before

---

## Phase 5 — ConnectivityWatcher multi-transport

**Goal:** watcher monitors all active transports, flush fires on any channel becoming available.

### Changes

**`connectivity_watcher.dart`**
- Accept list of `TransportPort` instead of only Yggdrasil
- For each transport: poll `isAvailable` every 10 sec
- `onPeersAppeared` → `onAnyTransportAvailable` (broader name)
- `hasConnectivity` = any transport available

**`queue_service.dart`**
- Subscribe to `onAnyTransportAvailable` instead of `onPeersAppeared`

### Result
- Phone in LoRa range (Reticulum) but without internet → flush via Reticulum
- Yggdrasil lost, Reticulum appeared → automatic switchover

---

## Phase 6 — Reticulum transport

**Goal:** real implementation for LoRa/radio networks.

### Changes

**`reticulum_transport.dart`**
- Connect to RNS daemon (Unix socket or TCP)
- `isAvailable`: check daemon is running
- `canReach(addr)`: lookup in RNS routing table
- `send()`: send via RNS announce/link
- `incoming`: stream from RNS listener

**Requirements**
- RNS daemon on Android (separate project)
- LoRa hardware (e.g. Meshtastic node as bridge)

---

## Phase 7 — Meshcore transport

**Goal:** LoRa mesh via Bluetooth/USB to Meshcore device.

### Changes

**`meshcore_transport.dart`**
- BLE or USB Serial connection to Meshcore node
- Protocol: Meshcore packet format
- `incoming`: BLE notify / serial read

**Requirements**
- Meshcore node hardware
- flutter_blue_plus or usb_serial package

---

## Implementation Order

```
Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5
  (can parallelize: 1+2, then 3+4, then 5)

Phase 6 — when RNS daemon is ready
Phase 7 — when Meshcore hardware is available
```

Phases 1-5 — refactoring of existing code, no new hardware required.
Phases 6-7 — depend on external components.

---

## Readiness Metrics

| Phase | Criterion |
|---|---|
| 1 | `sendEnvelope` uses `contact.transportAddresses`, test: contact without Ygg address |
| 2 | Message stays in queue after transport success, removed only on receipt |
| 3 | `QueueRecipient` contains all addresses, retry uses available protocol |
| 4 | After hello contact has Reticulum address in `transportAddresses` |
| 5 | Flush fires on any transport appearing |
| 6 | Message arrives via LoRa when Yggdrasil unavailable |
| 7 | Message arrives via Meshcore BLE bridge |
