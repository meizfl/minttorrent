package main

/*
#include <stdint.h>
#include <stddef.h>
extern void minttorrent_tcp_connect_complete(unsigned long long, long long, int);
extern void minttorrent_tcp_accept_complete(unsigned long long, long long, int);
extern void minttorrent_tcp_read_complete(unsigned long long, long long, int);
extern void minttorrent_tcp_write_complete(unsigned long long, long long, int);
extern void minttorrent_udp_read_complete(unsigned long long, long long, int);
extern void minttorrent_dns_complete(unsigned long long, long long, int);
*/
import "C"

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
)

type stackHandle struct {
	dev          *device.Device
	net          *netstack.Net
	deviceTun    tun.Device
	addresses    []netip.Addr
	ipv4         bool
	ipv6         bool
	mu           sync.Mutex
	children     map[uint64]io.Closer
	closed       bool
	healthMu     sync.RWMutex
	healthy      bool
	healthSet    bool
	checkedAt    time.Time
	healthErr    string
	cancelHealth context.CancelFunc
	healthDone   chan struct{}
}

type tcpListenerHandle struct {
	stackID  uint64
	listener net.Listener
}

type connectOperation struct {
	stackID uint64
	cancel  context.CancelFunc
}

func (l *tcpListenerHandle) Close() error { return l.listener.Close() }

func (s *stackHandle) lookupHost(ctx context.Context, host string) ([]string, error) {
	addresses, err := s.net.LookupContextHost(ctx, host)
	if err != nil {
		return nil, err
	}
	filtered := make([]string, 0, len(addresses))
	for _, value := range addresses {
		address, parseErr := netip.ParseAddr(value)
		if parseErr != nil {
			continue
		}
		if (address.Is4() && s.ipv4) || (address.Is6() && s.ipv6) {
			filtered = append(filtered, address.String())
		}
	}
	if len(filtered) == 0 {
		return nil, fmt.Errorf("name %q has no addresses in the enabled IP families", host)
	}
	return filtered, nil
}

var (
	nextID       atomic.Uint64
	defaultStack atomic.Uint64
	connectOps   sync.Map // uint64 operation ID -> connectOperation
	items        sync.Map // uint64 -> *stackHandle | io.Closer
)

func newID() uint64 { return nextID.Add(1) }

func putChild(parent uint64, c io.Closer) (uint64, error) {
	value, ok := items.Load(parent)
	if !ok {
		_ = c.Close()
		return 0, errors.New("network stack closed while opening socket")
	}
	s, ok := value.(*stackHandle)
	if !ok {
		_ = c.Close()
		return 0, errors.New("invalid network stack handle")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		_ = c.Close()
		return 0, errors.New("network stack closed while opening socket")
	}
	id := newID()
	s.children[id] = c
	items.Store(id, c)
	return id, nil
}

func callbackError(err error) C.int {
	if err == nil {
		return 0
	}
	if errors.Is(err, io.EOF) {
		return 1
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return 3
	}
	return 2
}

func closeItem(id uint64) error {
	v, ok := items.LoadAndDelete(id)
	if !ok {
		return nil
	}
	switch x := v.(type) {
	case *stackHandle:
		defaultStack.CompareAndSwap(id, 0)
		x.mu.Lock()
		if x.closed {
			x.mu.Unlock()
			return nil
		}
		x.closed = true
		children := x.children
		x.children = nil
		x.mu.Unlock()
		if x.cancelHealth != nil {
			x.cancelHealth()
			<-x.healthDone
		}
		for childID, c := range children {
			items.Delete(childID)
			_ = c.Close()
		}
		connectOps.Range(func(key, value any) bool {
			if operation, ok := value.(connectOperation); ok && operation.stackID == id {
				operation.cancel()
				connectOps.Delete(key)
			}
			return true
		})
		x.dev.Close() // also closes the in-process TUN device; no kernel TUN is used
		return nil
	case io.Closer:
		return x.Close()
	default:
		return errors.New("invalid AWG backend handle")
	}
}

const healthProbeAddress = "example.com:443"

func recordHealthResult(s *stackHandle, err error) bool {
	s.healthMu.Lock()
	defer s.healthMu.Unlock()
	changed := !s.healthSet || (s.healthy != (err == nil))
	s.healthSet = true
	s.healthy = err == nil
	s.checkedAt = time.Now()
	if err != nil {
		s.healthErr = err.Error()
	} else {
		s.healthErr = ""
	}
	return changed
}

func monitorHealth(ctx context.Context, s *stackHandle) {
	defer close(s.healthDone)
	probe := func() bool {
		probeCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		conn, err := s.net.DialContext(probeCtx, "tcp", healthProbeAddress)
		if err == nil {
			err = conn.Close()
		}
		changed := recordHealthResult(s, err)
		if changed && ctx.Err() == nil {
			if err != nil {
				log.Printf("VPN data-path health probe failed: %v", err)
			} else {
				log.Printf("VPN data path is healthy")
			}
		}
		return err == nil
	}
	interval := 5 * time.Second
	for {
		healthy := probe()
		if healthy {
			interval = 30 * time.Second
		} else if interval < 5*time.Minute {
			interval *= 2
			if interval > 5*time.Minute {
				interval = 5 * time.Minute
			}
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

//export mt_stack_set_default
func mt_stack_set_default(id C.longlong, errBuf *C.char, errCap C.int) C.int {
	if _, err := stackFor(uint64(id)); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if !defaultStack.CompareAndSwap(0, uint64(id)) && defaultStack.Load() != uint64(id) {
		setError(errBuf, errCap, errors.New("another userspace network stack is already active"))
		return -1
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_stack_get_default
func mt_stack_get_default(errBuf *C.char, errCap C.int) C.longlong {
	id := defaultStack.Load()
	if id == 0 {
		setError(errBuf, errCap, errors.New("userspace network stack is not active"))
		return -1
	}
	if _, err := stackFor(id); err != nil {
		defaultStack.CompareAndSwap(id, 0)
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

func stackFor(id uint64) (*stackHandle, error) {
	v, ok := items.Load(id)
	if !ok {
		return nil, errors.New("unknown or closed stack handle")
	}
	s, ok := v.(*stackHandle)
	if !ok {
		return nil, errors.New("handle is not a stack")
	}
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return nil, errors.New("userspace network stack is closed")
	}
	return s, nil
}

func objectFor[T any](id uint64) (T, error) {
	var zero T
	v, ok := items.Load(id)
	if !ok {
		return zero, errors.New("unknown or closed socket handle")
	}
	x, ok := v.(T)
	if !ok {
		return zero, errors.New("handle has an unexpected type")
	}
	return x, nil
}

func setError(dst *C.char, capacity C.int, err error) {
	if dst == nil || capacity <= 0 {
		return
	}
	msg := ""
	if err != nil {
		msg = err.Error()
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(capacity))
	for i := range buf {
		buf[i] = 0
	}
	copy(buf, msg)
}

func setString(dst *C.char, capacity C.int, value string) error {
	if dst == nil || capacity <= 0 {
		return errors.New("output buffer is missing")
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(capacity))
	for i := range buf {
		buf[i] = 0
	}
	if len(value) >= len(buf) {
		return errors.New("output buffer is too small")
	}
	copy(buf, value)
	return nil
}

func setBytes(dst *C.char, capacity C.int, value []byte) error {
	if dst == nil || capacity <= 0 || len(value) > int(capacity) {
		return errors.New("output buffer is missing or too small")
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(capacity)), value)
	return nil
}

type profile struct {
	ipc        strings.Builder
	addresses  []netip.Addr
	dns        []netip.Addr
	mtu        int
	allowedIPs int
}

func parseProfile(src string, enableIPv4, enableIPv6 bool) (profile, error) {
	p := profile{mtu: 1420}
	const defaultPersistentKeepalive = 25
	addressesV4, addressesV6 := 0, 0
	routesV4, routesV6 := 0, 0
	section := ""
	interfaceSeen := false
	privateKeySeen := false
	peerSeen := false
	peerPublicKeySeen := false
	peerEndpointSeen := false
	peerAllowedSeen := false
	peerKeepaliveSeen := false
	scanner := bufio.NewScanner(strings.NewReader(src))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	lineNo := 0
	var uapi strings.Builder

	for scanner.Scan() {
		lineNo++
		line := strings.TrimSpace(scanner.Text())
		if i := strings.IndexAny(line, "#;"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			if section == "Peer" && (!peerPublicKeySeen || !peerEndpointSeen || !peerAllowedSeen) {
				return p, fmt.Errorf("line %d: peer requires PublicKey, Endpoint, and AllowedIPs", lineNo)
			}
			if section == "Peer" && !peerKeepaliveSeen {
				uapi.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", defaultPersistentKeepalive))
			}
			switch strings.ToLower(strings.TrimSpace(line[1 : len(line)-1])) {
			case "interface":
				if interfaceSeen || peerSeen {
					return p, fmt.Errorf("line %d: Interface section must appear once before peers", lineNo)
				}
				section, interfaceSeen = "Interface", true
			case "peer":
				if !interfaceSeen {
					return p, fmt.Errorf("line %d: Peer appears before Interface", lineNo)
				}
				if peerSeen {
					uapi.WriteString("\n")
				}
				section, peerSeen = "Peer", true
				peerPublicKeySeen, peerEndpointSeen, peerAllowedSeen = false, false, false
				peerKeepaliveSeen = false
			default:
				return p, fmt.Errorf("line %d: unsupported section", lineNo)
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || section == "" {
			return p, fmt.Errorf("line %d: expected Key = Value inside a section", lineNo)
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		if value == "" {
			return p, fmt.Errorf("line %d: %s cannot be empty", lineNo, key)
		}

		if section == "Interface" {
			switch key {
			case "privatekey":
				if privateKeySeen {
					return p, fmt.Errorf("line %d: duplicate PrivateKey", lineNo)
				}
				v, err := base64.StdEncoding.DecodeString(value)
				if err != nil || len(v) != 32 {
					return p, fmt.Errorf("line %d: PrivateKey must be a 32-byte base64 key", lineNo)
				}
				uapi.WriteString("private_key=" + hex.EncodeToString(v) + "\n")
				privateKeySeen = true
			case "address":
				for _, item := range strings.Split(value, ",") {
					prefix, err := netip.ParsePrefix(strings.TrimSpace(item))
					if err != nil {
						return p, fmt.Errorf("line %d: invalid Address prefix: %w", lineNo, err)
					}
					if (prefix.Addr().Is4() && enableIPv4) || (prefix.Addr().Is6() && enableIPv6) {
						p.addresses = append(p.addresses, prefix.Addr())
						if prefix.Addr().Is4() {
							addressesV4++
						} else {
							addressesV6++
						}
					}
				}
			case "dns":
				for _, item := range strings.Split(value, ",") {
					addr, err := netip.ParseAddr(strings.TrimSpace(item))
					if err != nil {
						return p, fmt.Errorf("line %d: DNS must contain numeric IP addresses: %w", lineNo, err)
					}
					if (addr.Is4() && enableIPv4) || (addr.Is6() && enableIPv6) {
						p.dns = append(p.dns, addr)
					}
				}
			case "mtu":
				v, err := strconv.Atoi(value)
				if err != nil || v < 576 || v > 65535 {
					return p, fmt.Errorf("line %d: MTU must be between 576 and 65535", lineNo)
				}
				p.mtu = v
			case "listenport":
				if _, err := strconv.ParseUint(value, 10, 16); err != nil {
					return p, fmt.Errorf("line %d: invalid ListenPort", lineNo)
				}
				uapi.WriteString("listen_port=" + value + "\n")
			case "jc", "jmin", "jmax", "s1", "s2", "s3", "s4":
				if _, err := strconv.ParseUint(value, 10, 32); err != nil {
					return p, fmt.Errorf("line %d: %s must be an unsigned integer", lineNo, key)
				}
				uapi.WriteString(key + "=" + value + "\n")
			case "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5":
				uapi.WriteString(key + "=" + value + "\n")
			case "saveconfig":
				if !strings.EqualFold(value, "false") {
					return p, fmt.Errorf("line %d: SaveConfig=true is unsupported", lineNo)
				}
			default:
				return p, fmt.Errorf("line %d: unsupported Interface key %q", lineNo, key)
			}
			continue
		}

		switch key {
		case "publickey", "presharedkey":
			v, err := base64.StdEncoding.DecodeString(value)
			if err != nil || len(v) != 32 {
				return p, fmt.Errorf("line %d: %s must be a 32-byte base64 key", lineNo, key)
			}
			outKey := "public_key"
			if key == "presharedkey" {
				outKey = "preshared_key"
			}
			uapi.WriteString(outKey + "=" + hex.EncodeToString(v) + "\n")
			if key == "publickey" {
				if peerPublicKeySeen {
					return p, fmt.Errorf("line %d: duplicate PublicKey", lineNo)
				}
				peerPublicKeySeen = true
			}
		case "endpoint":
			if peerEndpointSeen {
				return p, fmt.Errorf("line %d: duplicate Endpoint", lineNo)
			}
			if _, err := netip.ParseAddrPort(value); err != nil {
				return p, fmt.Errorf("line %d: Endpoint must be a numeric IP:port (to avoid host DNS fallback)", lineNo)
			}
			uapi.WriteString("endpoint=" + value + "\n")
			peerEndpointSeen = true
		case "allowedips":
			if peerAllowedSeen {
				return p, fmt.Errorf("line %d: duplicate AllowedIPs", lineNo)
			}
			for _, item := range strings.Split(value, ",") {
				prefix, err := netip.ParsePrefix(strings.TrimSpace(item))
				if err != nil {
					return p, fmt.Errorf("line %d: invalid AllowedIPs prefix: %w", lineNo, err)
				}
				if (prefix.Addr().Is4() && enableIPv4) || (prefix.Addr().Is6() && enableIPv6) {
					uapi.WriteString("allowed_ip=" + strings.TrimSpace(item) + "\n")
					p.allowedIPs++
					if prefix.Addr().Is4() {
						routesV4++
					} else {
						routesV6++
					}
				}
			}
			peerAllowedSeen = true
		case "persistentkeepalive":
			if _, err := strconv.ParseUint(value, 10, 16); err != nil {
				return p, fmt.Errorf("line %d: invalid PersistentKeepalive", lineNo)
			}
			uapi.WriteString("persistent_keepalive_interval=" + value + "\n")
			peerKeepaliveSeen = true
		default:
			return p, fmt.Errorf("line %d: unsupported Peer key %q", lineNo, key)
		}
	}
	if err := scanner.Err(); err != nil {
		return p, err
	}
	if !interfaceSeen || !privateKeySeen {
		return p, errors.New("configuration requires Interface and PrivateKey")
	}
	if len(p.addresses) == 0 {
		return p, errors.New("VPN profile has no interface address in the enabled IP families")
	}
	if p.allowedIPs == 0 {
		return p, errors.New("VPN profile has no AllowedIPs route in the enabled IP families")
	}
	if len(p.dns) == 0 {
		return p, errors.New("VPN profile has no DNS server in the enabled IP families")
	}
	if enableIPv4 && (addressesV4 == 0 || routesV4 == 0) {
		return p, errors.New("IPv4 is enabled but the VPN profile has no IPv4 interface address or AllowedIPs route")
	}
	if enableIPv6 && (addressesV6 == 0 || routesV6 == 0) {
		return p, errors.New("IPv6 is enabled but the VPN profile has no IPv6 interface address or AllowedIPs route")
	}
	if !peerSeen {
		return p, errors.New("configuration requires at least one Peer")
	}
	if section == "Peer" && (!peerPublicKeySeen || !peerEndpointSeen || !peerAllowedSeen) {
		return p, errors.New("last Peer requires PublicKey, Endpoint, and AllowedIPs")
	}
	if peerSeen {
		if !peerKeepaliveSeen {
			uapi.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", defaultPersistentKeepalive))
		}
		uapi.WriteString("\n")
	}
	return profile{ipc: uapi, addresses: p.addresses, dns: p.dns, mtu: p.mtu, allowedIPs: p.allowedIPs}, nil
}

func requiredIP(value string, port uint16) (netip.AddrPort, error) {
	ip, err := netip.ParseAddr(strings.TrimSpace(value))
	if err != nil {
		return netip.AddrPort{}, fmt.Errorf("address must be a numeric IP: %w", err)
	}
	return netip.AddrPortFrom(ip, port), nil
}

//export mt_stack_open
func mt_stack_open(config *C.char, enableIPv4 C.int, enableIPv6 C.int, errBuf *C.char, errCap C.int) C.longlong {
	return mt_stack_open_configured(config, enableIPv4, enableIPv6, 0, 1024, 1<<20, 1<<20, errBuf, errCap)
}

//export mt_stack_open_configured
func mt_stack_open_configured(config *C.char, enableIPv4 C.int, enableIPv6 C.int, mtu C.int, packetQueue C.int, tcpSend C.int, tcpReceive C.int, errBuf *C.char, errCap C.int) C.longlong {
	contents := C.GoString(config)
	ipv4, ipv6 := enableIPv4 != 0, enableIPv6 != 0
	if !ipv4 && !ipv6 {
		setError(errBuf, errCap, errors.New("at least one IP family must be enabled"))
		return -1
	}
	p, err := parseProfile(contents, ipv4, ipv6)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if mtu != 0 {
		if mtu < 576 || mtu > 9000 {
			setError(errBuf, errCap, errors.New("gVisor MTU must be between 576 and 9000"))
			return -1
		}
		p.mtu = int(mtu)
	}
	if packetQueue < 0 || tcpSend < 0 || tcpReceive < 0 {
		setError(errBuf, errCap, errors.New("gVisor options cannot be negative"))
		return -1
	}
	queue, send, receive := int(packetQueue), int(tcpSend), int(tcpReceive)
	if queue == 0 {
		queue = 1024
	}
	if send == 0 {
		send = 1 << 20
	}
	if receive == 0 {
		receive = 1 << 20
	}
	tunDev, tnet, err := netstack.CreateNetTUNWithOptions(p.addresses, p.dns, p.mtu, netstack.Options{PacketQueue: queue, TCPSendBuffer: send, TCPReceiveBuffer: receive})
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	logger := &device.Logger{
		Verbosef: func(string, ...any) {},
		Errorf:   func(format string, args ...any) { log.Printf("AmneziaWG: "+format, args...) },
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	if err = dev.IpcSet(p.ipc.String()); err == nil {
		err = dev.Up()
	}
	if err != nil {
		dev.Close()
		setError(errBuf, errCap, err)
		return -1
	}
	healthCtx, cancelHealth := context.WithCancel(context.Background())
	h := &stackHandle{dev: dev, net: tnet, deviceTun: tunDev, addresses: append([]netip.Addr(nil), p.addresses...), ipv4: ipv4, ipv6: ipv6, children: make(map[uint64]io.Closer), cancelHealth: cancelHealth, healthDone: make(chan struct{})}
	id := newID()
	items.Store(id, h)
	go monitorHealth(healthCtx, h)
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

//export mt_stack_health_status
func mt_stack_health_status(id C.longlong, healthy *C.int, checkedAtNs *C.longlong, message *C.char, messageCap C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if healthy == nil || checkedAtNs == nil {
		setError(errBuf, errCap, errors.New("health output pointer is missing"))
		return -1
	}
	s.healthMu.RLock()
	*healthy = 0
	if s.healthy {
		*healthy = 1
	}
	*checkedAtNs = C.longlong(s.checkedAt.UnixNano())
	healthErr := s.healthErr
	s.healthMu.RUnlock()
	if err := setString(message, messageCap, healthErr); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_stack_addresses
func mt_stack_addresses(id C.longlong, output *C.char, outputCap C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addresses := make([]string, 0, len(s.addresses))
	for _, address := range s.addresses {
		addresses = append(addresses, address.String())
	}
	if err := setString(output, outputCap, strings.Join(addresses, ",")); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.int(len(addresses))
}

//export mt_stack_close
func mt_stack_close(id C.longlong, errBuf *C.char, errCap C.int) C.int {
	if err := closeItem(uint64(id)); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_stack_status
func mt_stack_status(id C.longlong, lastHandshakeNs *C.longlong, txBytes *C.ulonglong, rxBytes *C.ulonglong, peers *C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if lastHandshakeNs == nil || txBytes == nil || rxBytes == nil || peers == nil {
		setError(errBuf, errCap, errors.New("status output pointer is missing"))
		return -1
	}
	// IpcGet includes private key material. Parse only numeric status values and
	// never return or log the raw response.
	status, err := s.dev.IpcGet()
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	var last int64
	var candidateHandshake int64
	var tx, rx uint64
	peerCount := 0
	for _, line := range strings.Split(status, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch key {
		case "public_key":
			peerCount++
			candidateHandshake = 0
		case "last_handshake_time_sec":
			seconds, parseErr := strconv.ParseInt(value, 10, 64)
			if parseErr == nil {
				candidateHandshake = seconds * int64(time.Second)
			}
		case "last_handshake_time_nsec":
			nanos, parseErr := strconv.ParseInt(value, 10, 64)
			if parseErr == nil && candidateHandshake != 0 {
				candidateHandshake += nanos
				if candidateHandshake > last {
					last = candidateHandshake
				}
			}
		case "tx_bytes":
			if v, parseErr := strconv.ParseUint(value, 10, 64); parseErr == nil {
				tx += v
			}
		case "rx_bytes":
			if v, parseErr := strconv.ParseUint(value, 10, 64); parseErr == nil {
				rx += v
			}
		}
	}
	*lastHandshakeNs = C.longlong(last)
	*txBytes = C.ulonglong(tx)
	*rxBytes = C.ulonglong(rx)
	*peers = C.int(peerCount)
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_dial
func mt_tcp_dial(stackID C.longlong, address *C.char, timeoutMs C.int, errBuf *C.char, errCap C.int) C.longlong {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	timeout := 30 * time.Second
	if timeoutMs > 0 {
		timeout = time.Duration(timeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, err := s.net.DialContext(ctx, "tcp", C.GoString(address))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	id, err := putChild(uint64(stackID), c)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

func dialTCPWithBind(ctx context.Context, s *stackHandle, address, localHost string, localPort uint16) (net.Conn, error) {
	remoteHost, remotePortText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	remotePort, err := strconv.ParseUint(remotePortText, 10, 16)
	if err != nil || remotePort == 0 {
		return nil, errors.New("remote TCP port must be nonzero")
	}
	remoteAddresses, err := s.lookupHost(ctx, remoteHost)
	if err != nil {
		return nil, err
	}
	var localAddress netip.Addr
	if localHost != "" {
		localAddress, err = netip.ParseAddr(localHost)
		if err != nil {
			return nil, fmt.Errorf("invalid local TCP address: %w", err)
		}
	}
	var firstErr error
	for _, remoteText := range remoteAddresses {
		remoteIP, parseErr := netip.ParseAddr(remoteText)
		if parseErr != nil || (localAddress.IsValid() && localAddress.Is4() != remoteIP.Is4()) {
			continue
		}
		local := netip.AddrPortFrom(localAddress, localPort)
		remote := netip.AddrPortFrom(remoteIP, uint16(remotePort))
		c, dialErr := s.net.DialContextTCPWithBindAddrPort(ctx, local, remote)
		if dialErr == nil {
			return c, nil
		}
		if firstErr == nil {
			firstErr = dialErr
		}
	}
	if firstErr == nil {
		firstErr = errors.New("no compatible IP address for the requested TCP bind")
	}
	return nil, firstErr
}

//export mt_tcp_dial_bind
func mt_tcp_dial_bind(stackID C.longlong, address *C.char, localHost *C.char, localPort C.int, timeoutMs C.int, errBuf *C.char, errCap C.int) C.longlong {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if localPort < 0 || localPort > 65535 {
		setError(errBuf, errCap, errors.New("local TCP port is out of range"))
		return -1
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(max(int(timeoutMs), 1))*time.Millisecond)
	defer cancel()
	c, err := dialTCPWithBind(ctx, s, C.GoString(address), C.GoString(localHost), uint16(localPort))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	id, err := putChild(uint64(stackID), c)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

//export mt_tcp_async_connect
func mt_tcp_async_connect(stackID C.longlong, operationID C.ulonglong, address *C.char, localHost *C.char, localPort C.int, timeoutMs C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if operationID == 0 || localPort < 0 || localPort > 65535 {
		setError(errBuf, errCap, errors.New("invalid asynchronous TCP connect parameters"))
		return -1
	}
	timeout := 30 * time.Second
	if timeoutMs > 0 {
		timeout = time.Duration(timeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	connectOps.Store(uint64(operationID), connectOperation{stackID: uint64(stackID), cancel: cancel})
	remote, local, localPortValue := C.GoString(address), C.GoString(localHost), uint16(localPort)
	go func() {
		c, dialErr := dialTCPWithBind(ctx, s, remote, local, localPortValue)
		var handle uint64
		if dialErr == nil {
			handle, dialErr = putChild(uint64(stackID), c)
		}
		connectOps.Delete(uint64(operationID))
		cancel()
		if dialErr != nil {
			log.Printf("MintTorrent userspace TCP connect failed: %v", dialErr)
			C.minttorrent_tcp_connect_complete(C.ulonglong(operationID), -1, callbackError(dialErr))
			return
		}
		C.minttorrent_tcp_connect_complete(C.ulonglong(operationID), C.longlong(handle), 0)
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_cancel_connect
func mt_tcp_cancel_connect(operationID C.ulonglong) {
	if value, ok := connectOps.LoadAndDelete(uint64(operationID)); ok {
		value.(connectOperation).cancel()
	}
}

//export mt_tcp_async_read
func mt_tcp_async_read(id C.longlong, operationID C.ulonglong, dst *C.char, length C.int, errBuf *C.char, errCap C.int) C.int {
	c, err := objectFor[net.Conn](uint64(id))
	if err != nil || dst == nil || length <= 0 || operationID == 0 {
		if err == nil {
			err = errors.New("invalid asynchronous TCP read parameters")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	go func() {
		n, readErr := c.Read(unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(length)))
		status := callbackError(readErr)
		if n > 0 {
			status = 0
		}
		C.minttorrent_tcp_read_complete(C.ulonglong(operationID), C.longlong(n), status)
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_async_write
func mt_tcp_async_write(id C.longlong, operationID C.ulonglong, src *C.char, length C.int, errBuf *C.char, errCap C.int) C.int {
	c, err := objectFor[net.Conn](uint64(id))
	if err != nil || length < 0 || (length > 0 && src == nil) || operationID == 0 {
		if err == nil {
			err = errors.New("invalid asynchronous TCP write parameters")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	var payload []byte
	if length > 0 {
		payload = append([]byte(nil), unsafe.Slice((*byte)(unsafe.Pointer(src)), int(length))...)
	}
	go func() {
		n, writeErr := c.Write(payload)
		C.minttorrent_tcp_write_complete(C.ulonglong(operationID), C.longlong(n), callbackError(writeErr))
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_listen
func mt_tcp_listen(stackID C.longlong, host *C.char, port C.int, errBuf *C.char, errCap C.int) C.longlong {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addr, err := requiredIP(C.GoString(host), uint16(port))
	if err != nil || port < 0 || port > 65535 {
		if err == nil {
			err = errors.New("port is out of range")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	ln, err := s.net.ListenTCPAddrPort(addr)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	handle := &tcpListenerHandle{stackID: uint64(stackID), listener: ln}
	id, err := putChild(uint64(stackID), handle)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

//export mt_tcp_accept
func mt_tcp_accept(listenerID C.longlong, errBuf *C.char, errCap C.int) C.longlong {
	ln, err := objectFor[*tcpListenerHandle](uint64(listenerID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	c, err := ln.listener.Accept()
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	id, err := putChild(ln.stackID, c)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

//export mt_tcp_async_accept
func mt_tcp_async_accept(listenerID C.longlong, operationID C.ulonglong, errBuf *C.char, errCap C.int) C.int {
	ln, err := objectFor[*tcpListenerHandle](uint64(listenerID))
	if err != nil || operationID == 0 {
		if err == nil {
			err = errors.New("invalid asynchronous TCP accept operation ID")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	go func() {
		c, acceptErr := ln.listener.Accept()
		var handle uint64
		if acceptErr == nil {
			handle, acceptErr = putChild(ln.stackID, c)
		}
		if acceptErr != nil {
			C.minttorrent_tcp_accept_complete(C.ulonglong(operationID), -1, callbackError(acceptErr))
			return
		}
		C.minttorrent_tcp_accept_complete(C.ulonglong(operationID), C.longlong(handle), 0)
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_listener_endpoint
func mt_tcp_listener_endpoint(listenerID C.longlong, host *C.char, hostCap C.int, port *C.int, errBuf *C.char, errCap C.int) C.int {
	ln, err := objectFor[*tcpListenerHandle](uint64(listenerID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	endpoint, ok := ln.listener.Addr().(*net.TCPAddr)
	if !ok {
		setError(errBuf, errCap, fmt.Errorf("unexpected TCP listener endpoint type %T", ln.listener.Addr()))
		return -1
	}
	if err := setString(host, hostCap, endpoint.IP.String()); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if port != nil {
		*port = C.int(endpoint.Port)
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_read
func mt_tcp_read(id C.longlong, dst *C.char, length C.int, errBuf *C.char, errCap C.int) C.longlong {
	c, err := objectFor[net.Conn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if length < 0 || (length > 0 && dst == nil) {
		setError(errBuf, errCap, errors.New("invalid read buffer"))
		return -1
	}
	if length == 0 {
		return 0
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(length))
	n, err := c.Read(buf)
	if err != nil && n == 0 {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(n)
}

//export mt_tcp_write
func mt_tcp_write(id C.longlong, src *C.char, length C.int, errBuf *C.char, errCap C.int) C.longlong {
	c, err := objectFor[net.Conn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if length < 0 || (length > 0 && src == nil) {
		setError(errBuf, errCap, errors.New("invalid write buffer"))
		return -1
	}
	if length == 0 {
		return 0
	}
	if length < 0 || (length > 0 && src == nil) {
		setError(errBuf, errCap, errors.New("invalid UDP send buffer"))
		return -1
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(src)), int(length))
	n, err := c.Write(buf)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(n)
}

//export mt_tcp_close
func mt_tcp_close(id C.longlong, errBuf *C.char, errCap C.int) C.int {
	if err := closeItem(uint64(id)); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_udp_open
func mt_udp_open(stackID C.longlong, host *C.char, port C.int, errBuf *C.char, errCap C.int) C.longlong {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addr, err := requiredIP(C.GoString(host), uint16(port))
	if err != nil || port < 0 || port > 65535 {
		if err == nil {
			err = errors.New("port is out of range")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	c, err := s.net.ListenUDPAddrPort(addr)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	id, err := putChild(uint64(stackID), c)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(id)
}

//export mt_udp_send
func mt_udp_send(id C.longlong, host *C.char, port C.int, src *C.char, length C.int, errBuf *C.char, errCap C.int) C.longlong {
	c, err := objectFor[*gonet.UDPConn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addr, err := requiredIP(C.GoString(host), uint16(port))
	if err != nil || port < 1 || port > 65535 {
		if err == nil {
			err = errors.New("destination port is out of range")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(src)), int(length))
	n, err := c.WriteTo(buf, net.UDPAddrFromAddrPort(addr))
	if err != nil {
		log.Printf("MintTorrent userspace UDP send failed: %v", err)
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.longlong(n)
}

//export mt_udp_receive
func mt_udp_receive(id C.longlong, dst *C.char, length C.int, host *C.char, hostCap C.int, port *C.int, errBuf *C.char, errCap C.int) C.longlong {
	c, err := objectFor[*gonet.UDPConn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if length <= 0 || dst == nil {
		setError(errBuf, errCap, errors.New("invalid UDP receive buffer"))
		return -1
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(length))
	n, source, err := c.ReadFrom(buf)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addr, ok := source.(*net.UDPAddr)
	if !ok {
		setError(errBuf, errCap, fmt.Errorf("unexpected UDP endpoint type %T", source))
		return -1
	}
	if err := setString(host, hostCap, addr.IP.String()); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if port != nil {
		*port = C.int(addr.Port)
	}
	setError(errBuf, errCap, nil)
	return C.longlong(n)
}

//export mt_udp_async_receive
func mt_udp_async_receive(id C.longlong, operationID C.ulonglong, dst *C.char, length C.int, host *C.char, hostCap C.int, port *C.int, errBuf *C.char, errCap C.int) C.int {
	c, err := objectFor[*gonet.UDPConn](uint64(id))
	if err != nil || operationID == 0 || dst == nil || length <= 0 || host == nil || hostCap <= 0 || port == nil {
		if err == nil {
			err = errors.New("invalid asynchronous UDP receive parameters")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	go func() {
		buf := unsafe.Slice((*byte)(unsafe.Pointer(dst)), int(length))
		n, source, readErr := c.ReadFrom(buf)
		// Closing a UDP socket cancels its pending read with EOF in gVisor.
		// This is an ordinary socket lifecycle event, not a VPN failure.
		if readErr != nil && !errors.Is(readErr, io.EOF) && !errors.Is(readErr, net.ErrClosed) {
			log.Printf("MintTorrent userspace UDP receive failed: %v", readErr)
		}
		if readErr == nil {
			addr, ok := source.(*net.UDPAddr)
			if !ok {
				readErr = fmt.Errorf("unexpected UDP endpoint type %T", source)
			} else {
				readErr = setString(host, hostCap, addr.IP.String())
				*port = C.int(addr.Port)
			}
		}
		C.minttorrent_udp_read_complete(C.ulonglong(operationID), C.longlong(n), callbackError(readErr))
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_tcp_endpoint
func mt_tcp_endpoint(id C.longlong, remote C.int, host *C.char, hostCap C.int, port *C.int, errBuf *C.char, errCap C.int) C.int {
	c, err := objectFor[net.Conn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	addr := c.LocalAddr()
	if remote != 0 {
		addr = c.RemoteAddr()
	}
	endpoint, ok := addr.(*net.TCPAddr)
	if !ok {
		setError(errBuf, errCap, fmt.Errorf("unexpected TCP endpoint type %T", addr))
		return -1
	}
	if err := setString(host, hostCap, endpoint.IP.String()); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if port != nil {
		*port = C.int(endpoint.Port)
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_udp_local_endpoint
func mt_udp_local_endpoint(id C.longlong, host *C.char, hostCap C.int, port *C.int, errBuf *C.char, errCap C.int) C.int {
	c, err := objectFor[*gonet.UDPConn](uint64(id))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	endpoint, ok := c.LocalAddr().(*net.UDPAddr)
	if !ok {
		setError(errBuf, errCap, fmt.Errorf("unexpected UDP endpoint type %T", c.LocalAddr()))
		return -1
	}
	if err := setString(host, hostCap, endpoint.IP.String()); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if port != nil {
		*port = C.int(endpoint.Port)
	}
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_stack_resolve
func mt_stack_resolve(stackID C.longlong, hostname *C.char, timeoutMs C.int, output *C.char, outputCap C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(stackID))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	timeout := 10 * time.Second
	if timeoutMs > 0 {
		timeout = time.Duration(timeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	addresses, err := s.lookupHost(ctx, C.GoString(hostname))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if err = setString(output, outputCap, strings.Join(addresses, ",")); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.int(len(addresses))
}

//export mt_stack_http_get
func mt_stack_http_get(stackID C.longlong, rawURL *C.char, timeoutMs C.int, output *C.char, outputCap C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(stackID))
	if err != nil || rawURL == nil || output == nil || outputCap <= 0 {
		if err == nil {
			err = errors.New("invalid userspace HTTP request parameters")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	timeout := 20 * time.Second
	if timeoutMs > 0 {
		timeout = time.Duration(timeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	transport := &http.Transport{
		DialContext:       s.net.DialContext,
		ForceAttemptHTTP2: false,
		DisableKeepAlives: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 20 {
				return errors.New("stopped after 20 redirects")
			}
			if (request.URL.Scheme != "http") && (request.URL.Scheme != "https") {
				return fmt.Errorf("redirect to unsupported protocol: %s", request.URL.Scheme)
			}
			if (len(via) > 0) && (via[len(via)-1].URL.Scheme == "https") && (request.URL.Scheme != "https") {
				return errors.New("refusing redirect from HTTPS to HTTP")
			}
			return nil
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, C.GoString(rawURL), nil)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	request.Header.Set("User-Agent", "MintTorrent/0.1 RSS torrent fetcher")
	response, err := client.Do(request)
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		setError(errBuf, errCap, fmt.Errorf("HTTP request returned %s", response.Status))
		return -1
	}
	const maxResponseSize = 5 * 1024 * 1024
	if response.ContentLength > maxResponseSize {
		setError(errBuf, errCap, errors.New("HTTP response exceeds the 5 MiB limit"))
		return -1
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponseSize+1))
	if err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	if len(body) > maxResponseSize {
		setError(errBuf, errCap, errors.New("HTTP response exceeds the 5 MiB limit"))
		return -1
	}
	if err = setBytes(output, outputCap, body); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return C.int(len(body))
}

//export mt_stack_async_resolve
func mt_stack_async_resolve(stackID C.longlong, operationID C.ulonglong, hostname *C.char, timeoutMs C.int, output *C.char, outputCap C.int, errBuf *C.char, errCap C.int) C.int {
	s, err := stackFor(uint64(stackID))
	if err != nil || operationID == 0 || output == nil || outputCap <= 0 {
		if err == nil {
			err = errors.New("invalid asynchronous DNS lookup parameters")
		}
		setError(errBuf, errCap, err)
		return -1
	}
	name, capacity := C.GoString(hostname), int(outputCap)
	timeout := 10 * time.Second
	if timeoutMs > 0 {
		timeout = time.Duration(timeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	go func() {
		defer cancel()
		addresses, lookupErr := s.lookupHost(ctx, name)
		if lookupErr == nil {
			lookupErr = setString(output, C.int(capacity), strings.Join(addresses, ","))
		}
		C.minttorrent_dns_complete(C.ulonglong(operationID), C.longlong(len(addresses)), callbackError(lookupErr))
	}()
	setError(errBuf, errCap, nil)
	return 0
}

//export mt_udp_close
func mt_udp_close(id C.longlong, errBuf *C.char, errCap C.int) C.int {
	if err := closeItem(uint64(id)); err != nil {
		setError(errBuf, errCap, err)
		return -1
	}
	setError(errBuf, errCap, nil)
	return 0
}

func main() {}
