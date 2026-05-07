# Yggdrasil Roadmap

Full task list for bringing the Yggdrasil transport to production state.
Tasks are grouped by topic, within each group — priority top to bottom.

---

## 1. Build and Infrastructure

### YGG-BUILD-1: Makefile for AAR build ✅
**Status:** Done — `yggbind/Makefile`
**Problem:** `gomobile bind` without flags failed with "unsupported API version 16" on NDK 28.
**Solution:** `-androidapi 21` flag + javac from JDK in PATH.

```makefile
AAR_OUT = ../client/android/libs/yggbind.aar
UNITY_JDK = /home/ars/Unity/Hub/Editor/6000.3.8f1/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin
NDK = /media/ars/Storage-1t/android-sdk/ndk/28.2.13676358

build:
	PATH="$(UNITY_JDK):$$PATH" \
	ANDROID_NDK_HOME=$(NDK) \
	gomobile bind -target=android/arm64 -androidapi 21 -o $(AAR_OUT)
```

### YGG-BUILD-2: CI AAR build on yggbind/ changes ✅
**Status:** Done — `yggbind/rebuild.sh --check` rebuilds AAR if .go/go.mod changed since last build.

---

## 2. Network Connectivity (peers)

### YGG-PEERS-1: Editable peer list in UI ✅
**Status:** Done — `_YggPeersList` in Settings
**Description:** Like Signal's server screen — list of `tls://`, `tcp://`, `quic://` peers.
- Built-in defaults (read-only, but can be disabled)
- User-added custom peers (add/delete)
- Stored in `SharedPreferences` or `settings` DB table
- Passed to `YggdrasilNode.start(peers: [...])` on launch

### YGG-PEERS-2: Expand default peer list ✅
**Status:** Done — QUIC + TLS 443 + Europe peers in `kYggdrasilDefaultPeers`
**Task:** add QUIC and TCP variants of same nodes + peers on port 443:
- `quic://` peers — work over UDP, often pass through NAT/VPN where TLS is blocked
- Port 443 peers — indistinguishable from HTTPS traffic, pass strict firewalls
- Peers from other countries as backup (DE, FI, NL)
- Current list: https://publicpeers.neilalexander.dev/

### YGG-PEERS-3: RemovePeer / replace peer on the fly ✅
**Status:** Done — `Node.RemovePeer()` in `yggbind.go`

### YGG-PEERS-4: Persist successful peers ✅
**Status:** Done — after 15s since start, save `peer.up == true` to `ygg_successful_peers`. On next launch they're added first.

---

## 3. Listen (accepting incoming connections)

### YGG-LISTEN-1: Enable listen port ✅
**Status:** Done — `listenAddr` parameter in `Start()`, default `tls://0.0.0.0:0`

```go
func Start(privKeyHex string, listenAddr string) (*Node, error) {
    // listenAddr = "tls://0.0.0.0:0" — random port (OS chooses)
    // listenAddr = ""                — don't listen (current behavior)
    if listenAddr != "" {
        u, _ := url.Parse(listenAddr)
        c.Listen(u, "")
    }
}
```

### YGG-LISTEN-2: Display listen address in settings ✅
**Status:** Done — NetworkStatusScreen shows "Listening (inbound peers): tls://0.0.0.0:PORT".

---

## 4. Multicast — LAN Discovery

### YGG-MCAST-1: Enable multicast discovery ✅
**Status:** Done — `enableMulticast` parameter in `Start()`, permissions in AndroidManifest.
Note: replaced `anet` with standard `net` in fork (Go 1.24 incompatible with anet@v0.0.5)

```go
import "github.com/yggdrasil-network/yggdrasil-go/src/multicast"

type Node struct {
    c   *core.Core
    mc  *multicast.Multicast
    ...
}

// In Start():
mc, err := multicast.New(c, nil,
    multicast.MulticastInterface{
        Regex:  regexp.MustCompile(".*"),
        Beacon: true,
        Listen: true,
    },
)
mc._start()
n.mc = mc
```

### YGG-MCAST-2: Multicast via Wi-Fi Hotspot (point-to-point) ✅
**Status:** Done — regex `.*` already matches all interfaces including `wlan0`, `ap0`, `softap0`.

### YGG-MCAST-3: InterfacePeers — explicit IP in LAN ✅
**Status:** Done — `interfacePeersJson string` parameter in `Start()`. JSON object `{"wlan0":["tls://192.168.1.5:8362"]}`, added via `c.AddPeer(u, sintf)`.

---

## 5. Status and Monitoring

### YGG-STATUS-1: Detailed peer info (PeersJson) ✅
**Status:** Done in Go, Kotlin, Dart, Settings UI
- URI, up/down, inbound/outbound, latency ms, uptime seconds, lastError

### YGG-STATUS-2: Detailed routing info ✅
**Status:** Done — `TreeJson()`, `PathsJson()`, `SessionsJson()` in `yggbind.go`. NetworkStatusScreen shows "Active Sessions" section with rx/tx/uptime.

### YGG-STATUS-3: Per-peer traffic statistics ✅
**Status:** Done — `rx_bytes`, `tx_bytes`, `rx_rate`, `tx_rate`, `cost`, `priority` added to `PeersJson()`.

### YGG-STATUS-4: Peer count in foreground service notification ✅
**Status:** Done — `ScheduledExecutorService` updates notification every 30s: "Connected · N peers" or "No peers · reconnecting…"

---

## 6. Network Change Reaction

### YGG-NET-1: Reconnect peers on network change ✅
**Status:** Done — `ConnectivityManager.NetworkCallback` in `YggdrasilService.kt`, `reconnectPeers()` calls `RemovePeer` + `AddPeer` for all peers on `onAvailable`.

```kotlin
val networkCallback = object : ConnectivityManager.NetworkCallback() {
    override fun onAvailable(network: Network) {
        peers.forEach { uri -> node?.addPeer(uri) }
    }
}
connectivityManager.registerDefaultNetworkCallback(networkCallback)
```

### YGG-NET-2: Adaptive peer selection by network type ✅
**Status:** Done — `hubcore/connectivity` MethodChannel, `getNetworkType()` → wifi/mobile/vpn/none. On mobile/vpn: port 443 and QUIC peers go first.

---

## 7. Security and AllowedPublicKeys

### YGG-SEC-1: AllowedPublicKeys — incoming connection whitelist ✅
**Status:** Done — `allowedPubKeysJson` parameter in `Start()`, UI toggle "Trusted peers only" in Settings → Yggdrasil Security.

### YGG-SEC-2: Link-local peering encryption with password ✅
**Status:** Done — `MulticastInterface.Password` passed via `multicastPass` in `Start()`. UI "LAN discovery password" in Settings → Yggdrasil Security.

---

## 8. Optimization and Reliability

### YGG-OPT-1: Peer priority ✅
**Status:** Done — `low_priority` button per peer in Settings, saves as `tls://host:port?priority=X`.

### YGG-OPT-2: Cost-based peer selection ✅
**Status:** Done — `cost` field in `PeersJson()` and `YggPeerInfo`. NetworkStatusScreen shows `· cost N` next to latency if cost > 0.

### YGG-OPT-3: Watchdog — restart on hang ✅
**Status:** Done in `YggdrasilService.kt`:
- 0 peers ≥90s → soft reconnect (RemovePeer + AddPeer)
- 0 peers ≥5 min → hard restart (stop + Start again)

---

## 9. Diagnostics: VPN + blocked internet

**Symptom:** YouTube/Telegram work with VPN, but Yggdrasil peers don't connect.

**Likely causes:**
1. VPN blocks non-standard ports — YouTube/Telegram use port 443, our peers use 8362, 7992, 9003
2. VPN doesn't pass TLS to unknown IPs (whitelist VPN)
3. Mobile internet blocked except whitelist — VPN enabled via whitelist, but Yggdrasil peers not in it

**Solutions (by priority):**
1. Add peers on port **443** — indistinguishable from HTTPS
2. Add **QUIC** peers — UDP, different path through NAT
3. Use **SOCKS proxy** (`socks://localhost:PORT/peer.host:8362`) — tunnel Yggdrasil through VPN SOCKS proxy if VPN provides one
4. Add **own peer** on VPS with port 443

---

## Priority Summary

| ID | Task | Priority |
|----|------|----------|
| YGG-BUILD-1 | Makefile for AAR build | ✅ Done |
| YGG-BUILD-2 | CI rebuild.sh script | ✅ Done |
| YGG-PEERS-1 | Editable peer list in UI | ✅ Done |
| YGG-PEERS-2 | QUIC + port 443 in defaults | ✅ Done |
| YGG-PEERS-3 | RemovePeer / CallPeer in yggbind | ✅ Done |
| YGG-PEERS-4 | Persist successful peers | ✅ Done |
| YGG-LISTEN-1 | Enable listen port | ✅ Done |
| YGG-LISTEN-2 | Display listen address in UI | ✅ Done |
| YGG-MCAST-1 | Multicast LAN discovery | ✅ Done |
| YGG-MCAST-2 | Multicast via Wi-Fi Hotspot | ✅ Done |
| YGG-MCAST-3 | InterfacePeers | ✅ Done |
| YGG-STATUS-1 | PeersJson in UI | ✅ Done |
| YGG-STATUS-2 | TreeJson / PathsJson / SessionsJson | ✅ Done |
| YGG-STATUS-3 | RX/TX peer statistics | ✅ Done |
| YGG-STATUS-4 | Peer count in notification | ✅ Done |
| YGG-NET-1 | Reconnect peers on network change | ✅ Done |
| YGG-NET-2 | Adaptive peer selection | ✅ Done |
| YGG-SEC-1 | AllowedPublicKeys whitelist | ✅ Done |
| YGG-SEC-2 | Multicast group password | ✅ Done |
| YGG-OPT-1 | Peer priority in UI | ✅ Done |
| YGG-OPT-2 | Cost in peer list | ✅ Done |
| YGG-OPT-3 | Watchdog node restart | ✅ Done |
