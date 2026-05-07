# Reticulum Integration Roadmap

> Reticulum is the dominant transport for HubCore Chat. Works over any medium:
> LoRa, WiFi, BLE, Serial, internet. Yggdrasil remains as an accelerator
> for pure internet connectivity.

---

## Current State (after 2026-04 audit)

Phases 1-5 from TRANSPORT_ROADMAP.md **complete**:

- [x] `CompositeTransport.sendEnvelope()` — multi-protocol, preferred per-contact
- [x] Delivery-based queue (ack_pending, receipt removes from queue)
- [x] `QueueRecipient.transportAddresses` — Map<protocol, address>
- [x] `contact_hello` passes all transport addresses
- [x] `ConnectivityWatcher` — multiple listeners
- [x] Per-sender serialization in MessageRouter
- [x] DB indexes for prod load
- [x] Receipt retry, jitter, key zeroing

**Remaining:** native Reticulum layer + address exchange + monitoring.

---

## Architecture After Integration

```
CompositeTransport
  ├── ReticulumTransport  ← primary: LoRa + WiFi + BLE + Serial + Internet
  │     └── ReticulumNode (MethodChannel → Kotlin → RNS daemon)
  │
  └── YggdrasilTransport  ← accelerator: low latency over internet
        └── YggdrasilNode (MethodChannel → Kotlin → gomobile .aar)
```

Reticulum sends over all available interfaces simultaneously.
Yggdrasil connects when IP connectivity is available — delivery in ~50ms.
Dedup on receive discards duplicates (SHA-256 cache in MessageRouter).

Both run in parallel. `CompositeTransport` tries Yggdrasil first
(faster), Reticulum — fallback and delivery guarantee.

---

## Phase R1 — RNS daemon on Android

**Goal:** run Reticulum Network Stack on the phone as a background service.

### R1.1 Integration strategy: Go + gomobile (like Yggdrasil)

The project already has a working chain:
```
yggbind.go (Go) → gomobile bind → yggbind.aar → YggdrasilService.kt → MethodChannel → Dart
```

Reticulum integrates by the same pattern:
```
rnsbind.go (Go) → gomobile bind → rnsbind.aar → ReticulumService.kt → MethodChannel → Dart
```

**`rnsbind.go`** modeled after `yggbind.go` (~400 lines):
- `type Node struct` — RNS instance
- `type MessageHandler interface { OnMessage(fromHash string, data []byte) }` — callback
- `Start(identity, interfaces)` → create node
- `Send(destHash, data)` → send
- `StartReceiving(handler)` → receive goroutine
- `Address()` → destination hash
- `InterfacesJson()` → list of active interfaces
- `Stop()`

**Key question:** RNS is written in Python. A Go port of core functionality is needed:
- Identity (Ed25519/X25519)
- Destination (SHAKE-256 hash)
- Transport (TCP, UDP, Serial, BLE interface abstraction)
- Packet framing + routing
- Announce / path discovery

- [ ] Estimate scope of porting core RNS to Go (transport + routing + identity)
- [ ] Alternative: use Python RNS daemon via Unix socket / stdin-stdout from Go wrapper
- [ ] Alternative: find existing Go/Rust implementations of RNS protocol

### R1.2 ReticulumService (Kotlin)

Modeled after `YggdrasilService.kt` (current ~450 lines):

```kotlin
class ReticulumService : Service() {
    private var node: Rnsbind.Node? = null

    fun startNode(identityHex: String, interfacesJson: String) {
        node = Rnsbind.start(identityHex, interfacesJson)
        node?.startReceiving(IncomingHandler())
    }
}
```

- [ ] Create `ReticulumService.kt` — foreground service
- [ ] MethodChannel `hubcore/reticulum` — start, stop, send, isRunning, address
- [ ] EventChannel `hubcore/reticulum/incoming` — incoming stream
- [ ] Reuse `IncomingRawDb` (add `transport` column)
- [ ] Shared notification with YggdrasilService (one status line)
- [ ] Packet size limit (16MB, like YggdrasilService)

### R1.3 ReticulumNode (Dart)

Modeled after `yggdrasil_node.dart` (current ~180 lines):

```dart
class ReticulumNode {
  static const _method = MethodChannel('hubcore/reticulum');
  static const _incoming = EventChannel('hubcore/reticulum/incoming');

  static Future<void> start({
    required String identityHex,
    required String interfacesJson,
  });
  static Future<void> stop();
  static Future<bool> isRunning();
  static Future<String?> address();      // destination hash hex (20 bytes)
  static Future<void> send({required String destHash, required Uint8List data});
  static Future<String> interfacesJson(); // active interfaces status
  static Stream<ReticulumMessage> get messages;
  static Future<void> ackBuffered(List<int> ids);
}
```

- [ ] Create `client/lib/reticulum/reticulum_node.dart`
- [ ] Implement all methods via MethodChannel
- [ ] Incoming stream via EventChannel
- [ ] `ackBuffered` for IncomingRawDb

### R1.4 Android permissions

```xml
<!-- Bluetooth (Reticulum over BLE/LoRa) -->
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />

<!-- USB Serial (Reticulum over serial/LoRa hardware) -->
<uses-feature android:name="android.hardware.usb.host" android:required="false" />
```

- [ ] Add permissions to `AndroidManifest.xml`
- [ ] Declare `ReticulumService` in manifest
- [ ] Runtime permission requests (Android 12+)

### R1.5 Reticulum identity storage

RNS generates its own identity (Curve25519). Needs to:
- Store in Android Keystore (like Yggdrasil key)
- Bind to HubCore Chat master key
- Restore on backup/restore

- [ ] Generate Reticulum identity on first start
- [ ] Store in Keystore
- [ ] Include in backup bundle

**Phase R1 result:** `ReticulumNode.isRunning()` returns true,
`ReticulumNode.address()` returns destination hash.

---

## Phase R2 — ReticulumTransport Implementation

**Goal:** Reticulum sends and receives messages via transport abstraction.

### R2.1 Implement reticulum_transport.dart

```dart
class ReticulumTransport implements TransportPort {
  @override
  String get id => TransportProtocol.reticulum;

  @override
  Future<bool> get isAvailable => ReticulumNode.isRunning();

  @override
  Future<bool> canReach(TransportAddress addr) async =>
      addr.protocol == id && await isAvailable && addr.value.isNotEmpty;

  @override
  Future<void> send(Uint8List data, TransportAddress dest) async {
    await ReticulumNode.send(destHash: dest.value, data: data)
        .timeout(Duration(seconds: 30)); // LoRa can be slow
  }

  @override
  Stream<IncomingEnvelope> get incoming => ReticulumNode.messages.map(
    (msg) => IncomingEnvelope(
      data: msg.data,
      from: TransportAddress(protocol: id, value: msg.fromHash),
      rawBufId: msg.rawBufId,
    ),
  );
}
```

- [ ] Implement `ReticulumTransport` fully
- [ ] Adaptive timeout: 30s for LoRa, 5s for TCP/WiFi
- [ ] Test: message arrives via RNS with Yggdrasil disabled

### R2.2 Integration with CompositeTransport

Already ready — `ReticulumTransport()` included in `compositeTransportProvider`.
As soon as `isAvailable` returns true — CompositeTransport will use it.

**Phase R2 result:** message sent via LoRa reaches recipient.

---

## Phase R3 — Reticulum Address Exchange

**Goal:** contacts automatically learn each other's Reticulum addresses.

### R3.1 QR code

```dart
// my_qr_code.dart — add rk field
{
  "mp": "<masterPub58>",
  "sp": "<signingPub58>",
  "x":  "<x25519Pub58>",
  "yk": "<yggPubKeyHex>",
  "rk": "<reticulumDestHash>"  // NEW
}
```

### R3.2 contact_hello

```dart
// messaging_service.dart buildContactHello()
{
  "type": "contact_hello",
  "mp": "...", "sp": "...", "x": "...",
  "yk": "<yggHex>",
  "rk": "<reticulumHash>"  // NEW
}
```

- [ ] `buildContactHello()` — include Reticulum address
- [ ] `handleContactHelloJson()` — parse `rk`, update contact.transportAddresses
- [ ] `MessageRouter.setReticulumAddress()` — analog of `setYggPubKey()`

**Phase R3 result:** after hello both contacts know each other's Reticulum addresses.

---

## Phase R4 — Monitoring and ConnectivityWatcher

**Goal:** app knows Reticulum state and reacts to changes.

### R4.1 ReticulumHealthChecker

```dart
Future<int> _pollReticulum() async {
  if (!await ReticulumNode.isRunning()) return 0;
  final interfaces = await ReticulumNode.interfaces();
  return interfaces.where((i) => i.active).length;
}
```

- [ ] Add Reticulum interface polling to ConnectivityWatcher
- [ ] `addOnPeersAppeared` fires when Reticulum interfaces appear
- [ ] QueueService flush on Reticulum interface appearing

### R4.2 TransportStatus

Already ready — `TransportStatus.reticulum` field exists.

- [ ] Update `transportStatusProvider` with real Reticulum peer count
- [ ] UI: NetworkStatusBar shows Reticulum status

### R4.3 Settings UI

- [ ] `network_settings_screen.dart` — replace stub with real UI
- [ ] List of active interfaces (LoRa, BLE, TCP, Serial)
- [ ] Toggle individual interfaces
- [ ] Status per interface (connected, peers, latency)

**Phase R4 result:** UI shows "Reticulum: 2 interfaces active (LoRa, WiFi)".

---

## Phase R5 — RNS Interfaces (LoRa, BLE, Serial)

**Goal:** connect physical radio interfaces.

### R5.1 LoRa via RNode

RNode — USB LoRa transceiver. RNS supports it natively.

- [ ] USB permission + detection in Android
- [ ] Configure RNS interface for RNode
- [ ] Test: message via LoRa (2-20 km)

### R5.2 LoRa via Bluetooth (Heltec/LILYGO)

BLE connection to LoRa module.

- [ ] BLE scanning + pairing UI
- [ ] RNS interface for BLE serial
- [ ] Test: message via BLE→LoRa

### R5.3 WiFi interface

TCP/UDP interface for local network.

- [ ] RNS auto-discovery on local network (broadcast)
- [ ] Test: two phones on same WiFi without internet

### R5.4 Internet interface

TCP transport over internet (like Yggdrasil peers).

- [ ] List of public RNS transport nodes
- [ ] Auto-connect with internet available
- [ ] Test: delivery over internet via RNS

**Phase R5 result:** HubCore Chat works via LoRa radio in the field without internet.

---

## Phase R6 — Store-and-forward (optional)

**Goal:** use RNS propagation nodes for offline delivery.

**Two options:**

**A. Our send_queue (current approach):**
- Sender stores in SQLite, retry on contact appearance
- Pro: full control, works with any transport
- Con: sender must be online for delivery

**B. RNS propagation node:**
- Sender hands message to propagation node
- Node stores and delivers on recipient appearance
- Pro: sender can go offline after sending
- Con: depends on propagation node availability

**Solution:** both simultaneously:
1. Send via RNS (node will store if possible)
2. Keep in send_queue until receipt (safety net)

---

## Implementation Order

```
R1 (native daemon)     ← BLOCKS everything else
  │
  ├── R2 (transport)   ← main integration
  │     │
  │     ├── R3 (addresses)   ← exchange via QR + hello
  │     │
  │     └── R4 (monitoring)
  │
  └── R5 (interfaces)  ← physical radio
        │
        └── R6 (store-and-forward)  ← optional
```

R1 — critical path. Without a working daemon nothing else works.
R2-R4 can be parallelized after R1.
R5 — when LoRa hardware is available.
R6 — optimization, does not block.

---

## Effort Estimates

| Phase | Work | Estimate |
|-------|------|----------|
| R1.1 | `rnsbind.go` — Go port of core RNS | 1-3 weeks |
| R1.2 | `ReticulumService.kt` — modeled after YggdrasilService | 2-3 days |
| R1.3 | `ReticulumNode.dart` — modeled after YggdrasilNode | 1 day |
| R1.4-5 | Permissions + identity storage | 1 day |
| R2 | `ReticulumTransport` implementation | 1-2 days |
| R3 | QR + hello + UI — address exchange | 1-2 days |
| R4 | Monitoring + settings UI | 2-3 days |
| R5 | LoRa/BLE/WiFi interfaces in Go | 1-2 weeks |
| R6 | Store-and-forward (propagation nodes) | 3-5 days |

**Critical path:** R1.1 (`rnsbind.go`). Kotlin/Dart wrappers — template from Yggdrasil, ~3-4 days total.

**MVP (R1+R2, TCP interface):** 2-4 weeks.
**Full (with LoRa):** 4-7 weeks.

---

## Principles

1. **Reticulum = delivery guarantee.** Yggdrasil = accelerator. Both in parallel.
2. **Our wire format.** Both ends are HubCore Chat. LXMF not needed for compatibility.
3. **One APK.** Reticulum daemon embedded, no separate installation required.
4. **Transport-agnostic crypto.** Double Ratchet and Sender Keys don't change.
5. **Graceful degradation.** No LoRa → WiFi. No WiFi → internet. Nothing → send_queue.
