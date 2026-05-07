// Package rnsbind exposes a minimal Reticulum node API for gomobile binding.
// Mirrors the pattern of yggbind.go — only gomobile-compatible types are exported.
//
// Architecture:
//   - Each HubCore Chat instance runs one RNS node with a persistent identity.
//   - The node creates a SINGLE destination "hubcore.message" for receiving.
//   - Sending: create OUT destination from recalled identity → Packet.Send().
//   - Payloads > EncryptedMDU (383 bytes) are fragmented at this layer.
//   - Announce: broadcast our destination so peers discover our identity.
//   - Config file is generated dynamically from interface parameters.
package rnsbind

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	rns "github.com/svanichkin/go-reticulum/rns"
)

// ── Constants ────────────────────────────────────────────────────────────────

const (
	EncryptedMDU    = 383
	fragHeaderSize  = 9
	fragPayloadSize = EncryptedMDU - fragHeaderSize // 374

	flagFragment byte = 0x01
	flagSingle   byte = 0x00

	announceIntervalSec = 300 // 5 minutes

	appName = "hubcore"
	aspect  = "message"
)

// ── Interfaces (gomobile-compatible) ─────────────────────────────────────────

// MessageHandler receives incoming messages. Implement in Kotlin.
type MessageHandler interface {
	OnMessage(fromHashHex string, data []byte)
}

// LogHandler receives log lines from Go. Implement in Kotlin for file logging.
type LogHandler interface {
	OnLog(line string)
}

// global log handler — set via Node.SetLogHandler()
var globalLogHandler LogHandler

func goLog(format string, args ...interface{}) {
	line := fmt.Sprintf(format, args...)
	log.Print(line)
	if globalLogHandler != nil {
		globalLogHandler.OnLog(line)
	}
}

// ── Node ─────────────────────────────────────────────────────────────────────

type Node struct {
	mu           sync.Mutex
	ret          *rns.Reticulum
	identity     *rns.Identity
	dest         *rns.Destination
	identityPath string
	configDir    string
	running      bool
	handler      MessageHandler

	fragMu   sync.Mutex
	fragBufs map[uint32]*fragBuf

	announceDone chan struct{}

}

type fragBuf struct {
	total    int
	received map[int][]byte
	created  time.Time
}

// ── Config generation ────────────────────────────────────────────────────────

// writeConfig generates an RNS config file with the requested interfaces.
//
// interfacesJson is a JSON-like string with interface definitions.
// For simplicity, we use a structured approach: the caller passes individual
// parameters, and we build the INI-style config.
//
// Supported interface types:
//   - AutoInterface: WiFi LAN auto-discovery (mDNS)
//   - TCPClientInterface: connect to RNS transport nodes / Yggdrasil peers
//   - RNodeInterface: USB LoRa via serial
func writeConfig(configDir string, tcpPeers string, enableAuto bool, enableTransport bool) error {
	var b strings.Builder

	b.WriteString("[reticulum]\n")
	if enableTransport {
		b.WriteString("  enable_transport = Yes\n")
	} else {
		b.WriteString("  enable_transport = No\n")
	}
	b.WriteString("  share_instance = No\n")
	// Store known destinations inside app data dir (not /sdcard/)
	b.WriteString(fmt.Sprintf("  storagepath = %s\n\n", filepath.Join(configDir, "storage")))

	b.WriteString("[logging]\n")
	b.WriteString("  loglevel = 4\n\n")

	b.WriteString("[interfaces]\n")

	// AutoInterface — WiFi LAN discovery
	if enableAuto {
		b.WriteString("  [[HubCore Auto]]\n")
		b.WriteString("    type = AutoInterface\n")
		b.WriteString("    enabled = yes\n\n")
	}

	// TCP peers — one TCPClientInterface per peer
	if tcpPeers != "" {
		peers := strings.Split(tcpPeers, ",")
		for i, peer := range peers {
			peer = strings.TrimSpace(peer)
			if peer == "" {
				continue
			}
			// Parse host:port (supports IPv6 like [fd00::1]:4242)
			host, port, splitErr := net.SplitHostPort(peer)
			if splitErr != nil {
				goLog("[rnsbind] skipping malformed peer %q: %v", peer, splitErr)
				continue
			}

			b.WriteString(fmt.Sprintf("  [[HubCore TCP %d]]\n", i+1))
			b.WriteString("    type = TCPClientInterface\n")
			b.WriteString("    enabled = yes\n")
			b.WriteString(fmt.Sprintf("    target_host = %s\n", host))
			b.WriteString(fmt.Sprintf("    target_port = %s\n\n", port))
		}
	}

	configPath := filepath.Join(configDir, "config")
	return os.WriteFile(configPath, []byte(b.String()), 0600)
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

// Start creates and starts a Reticulum node.
//
//   - configDir:    directory for RNS config (created if missing).
//   - identityPath: persistent identity file (created if missing).
//   - tcpPeers:     comma-separated "host:port" list of TCP transport nodes.
//                   Includes Yggdrasil fd00:: addresses. Empty = no TCP peers.
//   - enableAuto:   enable AutoInterface (WiFi LAN mDNS discovery).
//   - enableTransport: enable RNS transport mode (relay packets for others).
func Start(configDir string, identityPath string, tcpPeers string,
	enableAuto bool, enableTransport bool) (n *Node, err error) {
	defer func() {
		if r := recover(); r != nil {
			stack := string(debug.Stack())
			goLog("[rnsbind] PANIC in Start: %v\n%s", r, stack)
			err = fmt.Errorf("panic in Start: %v", r)
		}
	}()

	goLog("[rnsbind] Start: config=%s identity=%s tcp=%s auto=%v transport=%v",
		configDir, identityPath, tcpPeers, enableAuto, enableTransport)

	if err := os.MkdirAll(configDir, 0700); err != nil {
		return nil, fmt.Errorf("mkdir config: %w", err)
	}
	if dir := filepath.Dir(identityPath); dir != "" {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return nil, fmt.Errorf("mkdir identity: %w", err)
		}
	}

	// Generate config with requested interfaces.
	if err := writeConfig(configDir, tcpPeers, enableAuto, enableTransport); err != nil {
		return nil, fmt.Errorf("writeConfig: %w", err)
	}

	// Start Reticulum — reads config from configDir.
	// Create storage directory for known destinations cache.
	os.MkdirAll(filepath.Join(configDir, "storage"), 0700)

	cfgDir := configDir
	ret, err := rns.NewReticulum(&cfgDir, nil, nil, nil, false, nil)
	if err != nil && enableAuto {
		// AutoInterface may fail on Android (permission denied for raw sockets).
		// Retry without AutoInterface.
		goLog("[rnsbind] Start failed with AutoInterface, retrying without: %v", err)
		if err2 := writeConfig(configDir, tcpPeers, false, enableTransport); err2 != nil {
			return nil, fmt.Errorf("writeConfig retry: %w", err2)
		}
		ret, err = rns.NewReticulum(&cfgDir, nil, nil, nil, false, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("NewReticulum: %w", err)
	}

	// Load or create identity.
	var identity *rns.Identity
	if _, statErr := os.Stat(identityPath); statErr == nil {
		identity, err = rns.IdentityFromFile(identityPath)
		if err != nil {
			return nil, fmt.Errorf("IdentityFromFile: %w", err)
		}
		goLog("[rnsbind] loaded identity from %s", identityPath)
	} else {
		identity, err = rns.NewIdentity()
		if err != nil {
			return nil, fmt.Errorf("NewIdentity: %w", err)
		}
		if err := identity.Save(identityPath); err != nil {
			return nil, fmt.Errorf("identity.Save: %w", err)
		}
		goLog("[rnsbind] created new identity, saved to %s", identityPath)
	}

	// Create receiving destination.
	dest, err := rns.NewDestination(identity, rns.DestinationIN, rns.DestinationSINGLE, appName, aspect)
	if err != nil {
		return nil, fmt.Errorf("NewDestination: %w", err)
	}
	_ = dest.SetProofStrategy(rns.DestinationPROVE_ALL)

	node := &Node{
		ret:          ret,
		identity:     identity,
		dest:         dest,
		identityPath: identityPath,
		configDir:    configDir,
		running:      true,
		fragBufs:     make(map[uint32]*fragBuf),
		announceDone: make(chan struct{}),
	}

	// Wire packet callback.
	dest.SetPacketCallback(func(data []byte, pkt *rns.Packet) {
		senderHash := ""
		if pkt != nil && pkt.TransportID != nil {
			senderHash = hex.EncodeToString(pkt.TransportID)
		}
		node.onPacket(senderHash, data)
	})

	// Initial announce + periodic re-announce.
	dest.Announce(nil, false, nil, nil, true)
	go node.announceLoop()

	goLog("[rnsbind] Start complete, address=%s", hex.EncodeToString(dest.Hash()))
	return node, nil
}

// Stop shuts down the node.
func (n *Node) Stop() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.running {
		return
	}
	n.running = false
	close(n.announceDone)
	rns.TransportExitHandler()
	rns.IdentityExitHandler()
	goLog("[rnsbind] stopped")
}

// SetLogHandler installs a log handler that receives Go log lines.
// Call before StartReceiving for full coverage.
func (n *Node) SetLogHandler(h LogHandler) {
	globalLogHandler = h
}

// IsRunning returns true if the node is active.
func (n *Node) IsRunning() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.running
}

func (n *Node) announceLoop() {
	ticker := time.NewTicker(time.Duration(announceIntervalSec) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			n.mu.Lock()
			d := n.dest
			n.mu.Unlock()
			if d != nil {
				d.Announce(nil, false, nil, nil, true)
			}
		case <-n.announceDone:
			return
		}
	}
}

// ── Identity info ────────────────────────────────────────────────────────────

func (n *Node) Address() string {
	n.mu.Lock()
	d := n.dest
	n.mu.Unlock()
	if d == nil {
		return ""
	}
	return hex.EncodeToString(d.Hash())
}

func (n *Node) PublicKeyHex() string {
	n.mu.Lock()
	id := n.identity
	n.mu.Unlock()
	if id == nil {
		return ""
	}
	return hex.EncodeToString(id.GetPublicKey())
}

func (n *Node) IdentityHash() string {
	n.mu.Lock()
	id := n.identity
	n.mu.Unlock()
	if id == nil {
		return ""
	}
	return hex.EncodeToString(rns.TruncatedHash(id.GetPublicKey()))
}

// ── Send ─────────────────────────────────────────────────────────────────────

func (n *Node) Send(destHashHex string, data []byte) error {
	if len(data) == 0 {
		return fmt.Errorf("empty payload")
	}
	if len(data) <= fragPayloadSize {
		return n.sendSingle(destHashHex, data)
	}
	return n.sendFragmented(destHashHex, data)
}

func (n *Node) sendSingle(destHashHex string, data []byte) error {
	frame := make([]byte, 1+len(data))
	frame[0] = flagSingle
	copy(frame[1:], data)
	return n.sendRaw(destHashHex, frame)
}

func (n *Node) sendFragmented(destHashHex string, data []byte) error {
	total := (len(data) + fragPayloadSize - 1) / fragPayloadSize
	if total > 0xFFFF {
		return fmt.Errorf("payload too large: %d bytes", len(data))
	}
	msgID := uint32(time.Now().UnixNano() & 0xFFFFFFFF)

	for i := 0; i < total; i++ {
		start := i * fragPayloadSize
		end := start + fragPayloadSize
		if end > len(data) {
			end = len(data)
		}
		chunk := data[start:end]

		frame := make([]byte, fragHeaderSize+len(chunk))
		frame[0] = flagFragment
		binary.BigEndian.PutUint16(frame[1:3], uint16(total))
		binary.BigEndian.PutUint16(frame[3:5], uint16(i))
		binary.BigEndian.PutUint32(frame[5:9], msgID)
		copy(frame[fragHeaderSize:], chunk)

		if err := n.sendRaw(destHashHex, frame); err != nil {
			return fmt.Errorf("fragment %d/%d: %w", i+1, total, err)
		}
	}
	return nil
}

func (n *Node) sendRaw(destHashHex string, frame []byte) error {
	destHash, err := hex.DecodeString(destHashHex)
	if err != nil {
		return fmt.Errorf("invalid destHashHex: %w", err)
	}

	if !rns.TransportHasPath(destHash) {
		rns.TransportRequestPath(destHash)
		return fmt.Errorf("path not found for %s, requested", destHashHex[:8])
	}

	remoteID := rns.IdentityRecall(destHash)
	if remoteID == nil {
		return fmt.Errorf("identity not recalled for %s", destHashHex[:8])
	}

	outDest, err := rns.NewDestination(remoteID, rns.DestinationOUT, rns.DestinationSINGLE, appName, aspect)
	if err != nil {
		return fmt.Errorf("NewDestination OUT: %w", err)
	}

	pkt := rns.NewPacket(outDest, frame)
	if pkt == nil {
		return fmt.Errorf("NewPacket returned nil")
	}

	receipt := pkt.Send()
	if receipt == nil {
		return fmt.Errorf("send failed")
	}
	return nil
}

// ── Receive ──────────────────────────────────────────────────────────────────

func (n *Node) StartReceiving(handler MessageHandler) {
	n.mu.Lock()
	n.handler = handler
	n.mu.Unlock()
	goLog("[rnsbind] receiver registered")
}

func (n *Node) onPacket(senderHashHex string, frame []byte) {
	if len(frame) < 1 {
		return
	}
	switch frame[0] {
	case flagSingle:
		n.deliver(senderHashHex, frame[1:])
	case flagFragment:
		if len(frame) < fragHeaderSize {
			return
		}
		total := int(binary.BigEndian.Uint16(frame[1:3]))
		index := int(binary.BigEndian.Uint16(frame[3:5]))
		msgID := binary.BigEndian.Uint32(frame[5:9])
		payload := frame[fragHeaderSize:]
		n.handleFragment(senderHashHex, msgID, index, total, payload)
	}
}

func (n *Node) handleFragment(senderHashHex string, msgID uint32, index, total int, payload []byte) {
	n.fragMu.Lock()
	defer n.fragMu.Unlock()

	now := time.Now()
	for id, buf := range n.fragBufs {
		if now.Sub(buf.created) > 60*time.Second {
			delete(n.fragBufs, id)
		}
	}

	buf, ok := n.fragBufs[msgID]
	if !ok {
		buf = &fragBuf{total: total, received: make(map[int][]byte), created: now}
		n.fragBufs[msgID] = buf
	}
	if index >= total || index < 0 {
		return
	}
	buf.received[index] = append([]byte(nil), payload...)

	if len(buf.received) < buf.total {
		return
	}

	var assembled []byte
	for i := 0; i < buf.total; i++ {
		part, ok := buf.received[i]
		if !ok {
			delete(n.fragBufs, msgID)
			return
		}
		assembled = append(assembled, part...)
	}
	delete(n.fragBufs, msgID)
	n.deliver(senderHashHex, assembled)
}

func (n *Node) deliver(senderHashHex string, data []byte) {
	n.mu.Lock()
	h := n.handler
	n.mu.Unlock()
	if h != nil {
		h.OnMessage(senderHashHex, data)
	}
}

// ── Announce & Path ──────────────────────────────────────────────────────────

// InterfaceCount returns the number of currently online RNS interfaces.
// Each connected TCP peer or AutoInterface counts as one.
func (n *Node) InterfaceCount() int {
	n.mu.Lock()
	running := n.running
	n.mu.Unlock()
	if !running {
		return 0
	}
	count := 0
	for _, ifc := range rns.Interfaces {
		if ifc.Online {
			count++
		}
	}
	return count
}

func (n *Node) Announce() {
	n.mu.Lock()
	d := n.dest
	n.mu.Unlock()
	if d != nil {
		d.Announce(nil, false, nil, nil, true)
	}
}

func (n *Node) HasPath(destHashHex string) bool {
	h, err := hex.DecodeString(destHashHex)
	if err != nil {
		return false
	}
	return rns.TransportHasPath(h)
}

func (n *Node) RequestPath(destHashHex string) {
	h, err := hex.DecodeString(destHashHex)
	if err != nil {
		return
	}
	rns.TransportRequestPath(h)
}

func (n *Node) HopsTo(destHashHex string) int {
	h, err := hex.DecodeString(destHashHex)
	if err != nil {
		return -1
	}
	return rns.TransportHopsTo(h)
}
