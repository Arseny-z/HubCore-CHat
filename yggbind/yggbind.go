// Package yggbind exposes a minimal Yggdrasil node API for gomobile binding.
// Only types and methods compatible with gomobile are exported (no slices of structs, etc).
package yggbind

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"net/url"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
	"golang.zx2c4.com/wireguard/tun"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// ── Netstack (userspace TCP/IP over Yggdrasil) ────────────────────────────────

// netstackState holds the wireguard userspace TCP/IP stack.
// Allows connecting to 200::/7 Yggdrasil-addressed servers without Android VPN.
type netstackState struct {
	tunDev   tun.Device
	net      *netstack.Net
	iprwc    *ipv6rwc.ReadWriteCloser
	mu       sync.Mutex
	bridges  []*net.TCPListener
}

// injectIPv6 feeds an IPv6 packet received from Yggdrasil into the netstack.
func (ns *netstackState) injectIPv6(pkt []byte) {
	buf := make([]byte, len(pkt))
	copy(buf, pkt)
	_, _ = ns.tunDev.Write([][]byte{buf}, 0)
}

// outboundLoop reads outgoing IPv6 packets from the netstack and sends them
// into the Yggdrasil overlay via ipv6rwc. The ipv6rwc handles key lookup
// (200:... → Ed25519 pubkey) and sends via core.WriteTo.
func (ns *netstackState) outboundLoop() {
	bufs := [][]byte{make([]byte, 65535)}
	sizes := make([]int, 1)
	for {
		n, err := ns.tunDev.Read(bufs, sizes, 0)
		if err != nil || n == 0 {
			return
		}
		if sizes[0] > 0 {
			_, _ = ns.iprwc.Write(bufs[0][:sizes[0]])
		}
	}
}

// ── Node ─────────────────────────────────────────────────────────────────────

// Node is the Yggdrasil node instance.
type Node struct {
	c          *core.Core
	listener   *core.Listener
	privKeyHex string

	recvMu    sync.Mutex
	recvLoops int

	nsMu sync.Mutex
	ns   *netstackState
}

// MessageHandler receives incoming messages from the Yggdrasil network.
// Implement this interface in Kotlin via gomobile.
//
//   - fromPubKeyHex: sender's Ed25519 public key as hex string
//   - data: raw message payload bytes
type MessageHandler interface {
	OnMessage(fromPubKeyHex string, data []byte)
}

// LogHandler receives log lines from Go. Implement in Kotlin for file logging.
type LogHandler interface {
	OnLog(line string)
}

var yggLogHandler LogHandler

func yggLog(format string, args ...interface{}) {
	line := fmt.Sprintf(format, args...)
	log.Print(line)
	if yggLogHandler != nil {
		yggLogHandler.OnLog(line)
	}
}

// Start creates and starts a Yggdrasil node with the given private key (hex-encoded ed25519).
// privKeyHex must be 128 hex chars (64 bytes). If empty, a new key is generated.
//
// listenAddr: address to accept inbound peer connections, e.g. "tls://0.0.0.0:0"
// (OS picks port). Pass "" to disable inbound listening (outbound only).
//
// allowedPubKeysJson: JSON array of hex-encoded Ed25519 public keys that are
// allowed to connect as inbound peers. Pass "" or "[]" to allow all peers.
//
// interfacePeersJson: JSON object mapping interface name to list of peer URIs,
// e.g. {"wlan0":["tls://192.168.1.5:8362"]}. Pass "" to skip.
func Start(privKeyHex string, listenAddr string,
	allowedPubKeysJson string, interfacePeersJson string) (n *Node, err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := string(debug.Stack())
			yggLog("[yggbind] PANIC in Start: %v\n%s", r, stack)
			err = fmt.Errorf("panic in Start: %v", r)
		}
	}()
	yggLog("[yggbind] Start called: listen=%q", listenAddr)

	cfg := config.GenerateConfig()

	if privKeyHex != "" {
		b, err := hex.DecodeString(privKeyHex)
		if err != nil {
			return nil, fmt.Errorf("invalid privKeyHex: %w", err)
		}
		if len(b) != 64 {
			return nil, fmt.Errorf("privKeyHex must be 64 bytes (128 hex chars), got %d", len(b))
		}
		cfg.PrivateKey = config.KeyBytes(b)
	}

	yggLog("[yggbind] generating self-signed certificate")
	if err := cfg.GenerateSelfSignedCertificate(); err != nil {
		return nil, fmt.Errorf("cert: %w", err)
	}
	yggLog("[yggbind] certificate OK")

	// ── AllowedPublicKeys (SEC-1) ──────────────────────────────────────────────
	var coreOpts []core.SetupOption
	if allowedPubKeysJson != "" && allowedPubKeysJson != "[]" {
		var hexKeys []string
		if err := json.Unmarshal([]byte(allowedPubKeysJson), &hexKeys); err == nil {
			for _, hk := range hexKeys {
				b, err := hex.DecodeString(hk)
				if err == nil && len(b) == 32 {
					coreOpts = append(coreOpts, core.AllowedPublicKey(b))
				}
			}
		}
	}

	yggLog("[yggbind] calling core.New")
	c, err := core.New(cfg.Certificate, nil, coreOpts...)
	if err != nil {
		return nil, fmt.Errorf("core.New: %w", err)
	}
	yggLog("[yggbind] core.New OK, pubkey=%s", hex.EncodeToString(c.PublicKey()))

	node := &Node{c: c, privKeyHex: hex.EncodeToString(cfg.PrivateKey[:])}

	// ── Listen (inbound peer connections) ─────────────────────────────────────
	if listenAddr != "" {
		u, err := url.Parse(listenAddr)
		if err != nil {
			return nil, fmt.Errorf("invalid listenAddr: %w", err)
		}
		yggLog("[yggbind] calling c.Listen(%s)", listenAddr)
		ln, err := c.Listen(u, "")
		if err != nil {
			return nil, fmt.Errorf("listen: %w", err)
		}
		node.listener = ln
		yggLog("[yggbind] listening OK, port=%d", node.ListenPort())
	}

	// ── InterfacePeers ────────────────────────────────────────────────────────
	if interfacePeersJson != "" && interfacePeersJson != "{}" {
		var ifPeers map[string][]string
		if err := json.Unmarshal([]byte(interfacePeersJson), &ifPeers); err == nil {
			for sintf, uris := range ifPeers {
				for _, peerURI := range uris {
					u, err := url.Parse(peerURI)
					if err == nil {
						_ = c.AddPeer(u, sintf)
					}
				}
			}
		}
	}

	yggLog("[yggbind] Start complete, address=%s", node.Address())
	return node, nil
}

// SetLogHandler installs a handler that receives Go log lines.
func (n *Node) SetLogHandler(h LogHandler) {
	yggLogHandler = h
}

func (n *Node) PrivateKeyHex() string {
	return n.privKeyHex
}

// AddPeer connects to a Yggdrasil peer URI, e.g. "tls://host:port".
func (n *Node) AddPeer(peerURI string) error {
	u, err := url.Parse(peerURI)
	if err != nil {
		return fmt.Errorf("invalid peer URI: %w", err)
	}
	return n.c.AddPeer(u, "")
}

// Address returns the node's Yggdrasil IPv6 address (e.g. "200:...").
func (n *Node) Address() string {
	return n.c.Address().String()
}

// PublicKeyHex returns the node's Ed25519 public key as hex string.
func (n *Node) PublicKeyHex() string {
	return hex.EncodeToString(n.c.PublicKey())
}

// PeerCount returns the number of currently connected peers.
func (n *Node) PeerCount() int {
	return len(n.c.GetPeers())
}

// PeerEntry is a gomobile-compatible peer descriptor (unused directly — use PeersJson).
type PeerEntry struct {
	URI       string
	Up        bool
	Inbound   bool
	Key       string
	Uptime    float64 // seconds
	LatencyMs float64 // milliseconds
	LastError string
}

// PeersJson returns the current peer list as a JSON array string.
func (n *Node) PeersJson() string {
	type peerJSON struct {
		URI       string  `json:"uri"`
		Up        bool    `json:"up"`
		Inbound   bool    `json:"inbound"`
		Key       string  `json:"key"`
		Uptime    float64 `json:"uptime"`
		LatencyMs float64 `json:"latency_ms"`
		LastError string  `json:"last_error,omitempty"`
		RXBytes   uint64  `json:"rx_bytes"`
		TXBytes   uint64  `json:"tx_bytes"`
		RXRate    uint64  `json:"rx_rate"`
		TXRate    uint64  `json:"tx_rate"`
		Cost      uint64  `json:"cost"`
		Priority  uint8   `json:"priority"`
	}
	peers := n.c.GetPeers()
	out := make([]peerJSON, 0, len(peers))
	for _, p := range peers {
		lastErr := ""
		if p.LastError != nil {
			lastErr = p.LastError.Error()
		}
		out = append(out, peerJSON{
			URI:       p.URI,
			Up:        p.Up,
			Inbound:   p.Inbound,
			Key:       hex.EncodeToString(p.Key[:]),
			Uptime:    p.Uptime.Seconds(),
			LatencyMs: float64(p.Latency.Nanoseconds()) / 1e6,
			LastError: lastErr,
			RXBytes:   p.RXBytes,
			TXBytes:   p.TXBytes,
			RXRate:    p.RXRate,
			TXRate:    p.TXRate,
			Cost:      p.Cost,
			Priority:  p.Priority,
		})
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// TreeJson returns the routing tree as a JSON array string.
func (n *Node) TreeJson() string {
	type treeJSON struct {
		Key      string `json:"key"`
		Parent   string `json:"parent"`
		Sequence uint64 `json:"sequence"`
	}
	entries := n.c.GetTree()
	out := make([]treeJSON, 0, len(entries))
	for _, e := range entries {
		out = append(out, treeJSON{
			Key:      hex.EncodeToString(e.Key),
			Parent:   hex.EncodeToString(e.Parent),
			Sequence: e.Sequence,
		})
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// PathsJson returns known paths to other nodes as a JSON array string.
func (n *Node) PathsJson() string {
	type pathJSON struct {
		Key      string   `json:"key"`
		Sequence uint64   `json:"sequence"`
		Path     []uint64 `json:"path"`
	}
	entries := n.c.GetPaths()
	out := make([]pathJSON, 0, len(entries))
	for _, e := range entries {
		out = append(out, pathJSON{
			Key:      hex.EncodeToString(e.Key),
			Sequence: e.Sequence,
			Path:     e.Path,
		})
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// SessionsJson returns active sessions as a JSON array.
func (n *Node) SessionsJson() string {
	type sessionJSON struct {
		Key     string  `json:"key"`
		RXBytes uint64  `json:"rx_bytes"`
		TXBytes uint64  `json:"tx_bytes"`
		Uptime  float64 `json:"uptime"`
	}
	sessions := n.c.GetSessions()
	out := make([]sessionJSON, 0, len(sessions))
	for _, s := range sessions {
		out = append(out, sessionJSON{
			Key:     hex.EncodeToString(s.Key),
			RXBytes: s.RXBytes,
			TXBytes: s.TXBytes,
			Uptime:  s.Uptime.Seconds(),
		})
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// Stop shuts down the Yggdrasil node and any active TCP bridges.
func (n *Node) Stop() {
	n.c.Stop()
	n.StopNetstack()
}

// ListenPort returns the actual TCP/UDP port the node is listening on.
func (n *Node) ListenPort() int {
	if n.listener == nil {
		return 0
	}
	addr := n.listener.Addr()
	if addr == nil {
		return 0
	}
	_, portStr, err := net.SplitHostPort(addr.String())
	if err != nil {
		return 0
	}
	port := 0
	fmt.Sscanf(portStr, "%d", &port)
	return port
}

// RemovePeer disconnects from a peer by URI.
func (n *Node) RemovePeer(peerURI string) error {
	u, err := url.Parse(peerURI)
	if err != nil {
		return fmt.Errorf("invalid peer URI: %w", err)
	}
	return n.c.RemovePeer(u, "")
}

// ── Userspace TCP/IP (Yggdrasil RNS bridge) ──────────────────────────────────

// StartNetstack initialises the wireguard userspace TCP/IP stack.
// Called automatically by OpenTCPBridge if not yet started. Safe to call
// multiple times (idempotent).
func (n *Node) StartNetstack() error {
	n.nsMu.Lock()
	defer n.nsMu.Unlock()
	if n.ns != nil {
		return nil
	}

	addr, err := netip.ParseAddr(n.c.Address().String())
	if err != nil {
		return fmt.Errorf("parse ygg address: %w", err)
	}

	mtu := int(n.c.MTU())
	if mtu <= 0 {
		mtu = 65535
	}

	tunDev, netstackNet, err := netstack.CreateNetTUN(
		[]netip.Addr{addr},
		[]netip.Addr{}, // no DNS needed — we dial IPv6 directly
		mtu,
	)
	if err != nil {
		return fmt.Errorf("CreateNetTUN: %w", err)
	}

	iprwc := ipv6rwc.NewReadWriteCloser(n.c)

	ns := &netstackState{
		tunDev: tunDev,
		net:    netstackNet,
		iprwc:  iprwc,
	}

	// Outbound: netstack → Yggdrasil overlay.
	go ns.outboundLoop()

	// Drain tun events to prevent goroutine leak.
	go func() {
		for range tunDev.Events() {
		}
	}()

	n.ns = ns
	yggLog("[yggbind] netstack started, addr=%s mtu=%d", addr, mtu)
	return nil
}

// StopNetstack shuts down the userspace TCP/IP stack and closes all TCP bridges.
func (n *Node) StopNetstack() {
	n.nsMu.Lock()
	ns := n.ns
	n.ns = nil
	n.nsMu.Unlock()
	if ns == nil {
		return
	}
	_ = ns.tunDev.Close()
	_ = ns.iprwc.Close()
	ns.mu.Lock()
	for _, ln := range ns.bridges {
		_ = ln.Close()
	}
	ns.bridges = nil
	ns.mu.Unlock()
	yggLog("[yggbind] netstack stopped")
}

// OpenTCPBridge creates a local TCP proxy to a Yggdrasil-addressed TCP server.
//
// yggIPv6Addr: the 200:... address without brackets, e.g. "200:73eb:2e4:..."
// remotePort:  port on the remote Yggdrasil node (e.g. 4242)
//
// Returns a local port on 127.0.0.1. Pass "127.0.0.1:<port>" as a standard
// RNS TCP peer — traffic is tunnelled through the Yggdrasil overlay.
//
// Key lookup (200:... → Ed25519 pubkey) is handled automatically by ipv6rwc
// via the Yggdrasil DHT. First connection attempt may take a few seconds while
// the path is discovered; subsequent attempts are fast.
func (n *Node) OpenTCPBridge(yggIPv6Addr string, remotePort int) (int, error) {
	if err := n.StartNetstack(); err != nil {
		return 0, fmt.Errorf("netstack init: %w", err)
	}

	n.nsMu.Lock()
	ns := n.ns
	n.nsMu.Unlock()
	if ns == nil {
		return 0, fmt.Errorf("netstack unavailable")
	}

	// Strip brackets if present: [200:...] → 200:...
	addr := strings.TrimPrefix(strings.TrimSuffix(
		strings.TrimSpace(yggIPv6Addr), "]"), "[")

	remoteIP := net.ParseIP(addr)
	if remoteIP == nil {
		return 0, fmt.Errorf("invalid Yggdrasil address: %q", addr)
	}
	remoteAddr := &net.TCPAddr{IP: remoteIP, Port: remotePort}

	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0, fmt.Errorf("listen: %w", err)
	}
	localPort := ln.Addr().(*net.TCPAddr).Port

	ns.mu.Lock()
	ns.bridges = append(ns.bridges, ln.(*net.TCPListener))
	ns.mu.Unlock()

	go n.bridgeLoop(ns, ln, remoteAddr)

	yggLog("[yggbind] bridge: [%s]:%d ← 127.0.0.1:%d", addr, remotePort, localPort)
	return localPort, nil
}

func (n *Node) bridgeLoop(ns *netstackState, ln net.Listener, remote *net.TCPAddr) {
	defer ln.Close()
	for {
		local, err := ln.Accept()
		if err != nil {
			return
		}
		go n.handleBridge(ns, local, remote)
	}
}

func (n *Node) handleBridge(ns *netstackState, local net.Conn, remote *net.TCPAddr) {
	defer local.Close()

	// Allow up to 30s for Yggdrasil path/key discovery on first connection.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := ns.net.DialContextTCP(ctx, remote)
	if err != nil {
		yggLog("[yggbind] bridge dial [%s]:%d: %v", remote.IP, remote.Port, err)
		return
	}
	defer conn.Close()

	errc := make(chan error, 2)
	go func() { _, e := io.Copy(conn, local); errc <- e }()
	go func() { _, e := io.Copy(local, conn); errc <- e }()
	<-errc
}

// ── Send ─────────────────────────────────────────────────────────────────────

// Send delivers data to the node identified by destPubKeyHex (Ed25519 public key hex).
// Uses a simple framing: 4-byte big-endian length prefix + payload.
func (n *Node) Send(destPubKeyHex string, data []byte) error {
	pubKey, err := hex.DecodeString(destPubKeyHex)
	if err != nil {
		return fmt.Errorf("invalid destPubKeyHex: %w", err)
	}
	if len(pubKey) != 32 {
		return fmt.Errorf("pubkey must be 32 bytes, got %d", len(pubKey))
	}

	frame := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(data)))
	copy(frame[4:], data)

	addr := iwt.Addr(pubKey)
	_, err = n.c.WriteTo(frame, addr)
	return err
}

// ── Receive ───────────────────────────────────────────────────────────────────

// StartReceiving starts a background goroutine that reads incoming packets
// and delivers them to handler.OnMessage. Call Stop to exit.
func (n *Node) StartReceiving(handler MessageHandler) {
	n.recvMu.Lock()
	n.recvLoops++
	n.recvMu.Unlock()

	go n.recvLoop(handler)
}

func (n *Node) recvLoop(handler MessageHandler) {
	defer func() {
		if r := recover(); r != nil {
			stack := string(debug.Stack())
			yggLog("[yggbind] PANIC in recvLoop: %v\n%s", r, stack)
		}
	}()

	mtu := int(n.c.MTU())
	if mtu < 1500 {
		mtu = 65535
	}
	yggLog("[yggbind] recvLoop started, mtu=%d", mtu)
	buf := make([]byte, mtu)

	for {
		nr, from, err := n.c.ReadFrom(buf)
		if err != nil {
			yggLog("[yggbind] recvLoop exit: %v", err)
			return
		}
		if nr == 0 {
			continue
		}

		// IPv6 packet detection: version nibble = 6 (first byte 0x60–0x6F).
		// These are raw IPv6 packets from ipv6rwc (no length prefix).
		// Route to netstack for TCP bridge support.
		if (buf[0] >> 4) == 6 {
			n.nsMu.Lock()
			ns := n.ns
			n.nsMu.Unlock()
			if ns != nil {
				pkt := make([]byte, nr)
				copy(pkt, buf[:nr])
				ns.injectIPv6(pkt)
			}
			continue
		}

		// Standard HubCore Chat framing: 4-byte length prefix + payload.
		if nr < 4 {
			continue
		}
		payloadLen := int(binary.BigEndian.Uint32(buf[:4]))
		if payloadLen != nr-4 {
			continue // malformed
		}

		payload := make([]byte, payloadLen)
		copy(payload, buf[4:nr])

		fromHex := hex.EncodeToString([]byte(from.(iwt.Addr)))
		handler.OnMessage(fromHex, payload)
	}
}
