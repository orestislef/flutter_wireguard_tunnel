// A WireGuard server for example/integration_test/tunnel_test.dart, userspace
// with wireguard-go and gVisor's netstack, nothing to install.
//
//	UDP 51820       WireGuard
//	TCP 8080        GET /peer?key=<b64> adds that peer, GET /peer?generate=1
//	                makes a key pair and a preshared key for one. Both answer
//	                the peer's config as JSON.
//	10.8.0.1:80     inside the tunnel, answers "hello from the tunnel"
//
// Android emulator (the emulator reaches the computer's 127.0.0.1 as 10.0.2.2):
//
//	go run .
//
// Phone on the same Wi-Fi:
//
//	go run . -listen 0.0.0.0 -endpoint 192.168.1.20:51820
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"sync"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// ---- a Bind on one address, 127.0.0.1 by default so no firewall asks ----

type endpoint struct{ ap netip.AddrPort }

func (e endpoint) ClearSrc()           {}
func (e endpoint) SrcToString() string { return "" }
func (e endpoint) DstToString() string { return e.ap.String() }
func (e endpoint) DstToBytes() []byte  { b, _ := e.ap.MarshalBinary(); return b }
func (e endpoint) DstIP() netip.Addr   { return e.ap.Addr() }
func (e endpoint) SrcIP() netip.Addr   { return netip.Addr{} }

type bind struct {
	ip net.IP
	mu sync.Mutex
	c  *net.UDPConn
}

func (b *bind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: b.ip, Port: int(port)})
	if err != nil {
		return nil, 0, err
	}
	b.c = c
	recv := func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		n, ap, err := c.ReadFromUDPAddrPort(packets[0])
		if err != nil {
			return 0, err
		}
		sizes[0] = n
		eps[0] = endpoint{netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port())}
		return 1, nil
	}
	return []conn.ReceiveFunc{recv}, uint16(c.LocalAddr().(*net.UDPAddr).Port), nil
}

func (b *bind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.c == nil {
		return nil
	}
	err := b.c.Close()
	b.c = nil
	return err
}

func (b *bind) SetMark(uint32) error { return nil }
func (b *bind) BatchSize() int       { return 1 }

func (b *bind) Send(bufs [][]byte, ep conn.Endpoint) error {
	b.mu.Lock()
	c := b.c
	b.mu.Unlock()
	if c == nil {
		return net.ErrClosed
	}
	for _, buf := range bufs {
		if _, err := c.WriteToUDPAddrPort(buf, ep.(endpoint).ap); err != nil {
			return err
		}
	}
	return nil
}

func (b *bind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	return endpoint{ap}, err
}

// ---- server ----

func main() {
	listen := flag.String("listen", "127.0.0.1", "address to listen on")
	endpoint := flag.String("endpoint", "10.0.2.2:51820", "endpoint handed to peers")
	flag.Parse()
	ip := net.ParseIP(*listen)
	if ip == nil {
		log.Fatalf("bad -listen %q", *listen)
	}

	tun, tnet, err := netstack.CreateNetTUN(
		[]netip.Addr{netip.MustParseAddr("10.8.0.1")}, nil, 1420)
	if err != nil {
		log.Fatal(err)
	}
	dev := device.NewDevice(tun, &bind{ip: ip}, device.NewLogger(device.LogLevelError, "wg "))

	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		log.Fatal(err)
	}
	priv[0] &= 248
	priv[31] = (priv[31] & 127) | 64
	pub, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		log.Fatal(err)
	}
	if err := dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=51820\n", hex.EncodeToString(priv[:]))); err != nil {
		log.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		log.Fatal(err)
	}

	inner, err := tnet.ListenTCP(&net.TCPAddr{Port: 80})
	if err != nil {
		log.Fatal(err)
	}
	go http.Serve(inner, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("tunnel: %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)
		fmt.Fprint(w, "hello from the tunnel")
	}))

	var mu sync.Mutex
	next := 2
	control := http.NewServeMux()
	control.HandleFunc("/peer", func(w http.ResponseWriter, r *http.Request) {
		answer := map[string]string{}
		q := r.URL.Query()
		if q.Get("generate") != "" {
			// A key pair and a preshared key made here, for testing own keys.
			var cpriv, psk [32]byte
			rand.Read(cpriv[:])
			rand.Read(psk[:])
			cpriv[0] &= 248
			cpriv[31] = (cpriv[31] & 127) | 64
			cpub, _ := curve25519.X25519(cpriv[:], curve25519.Basepoint)
			q.Set("key", base64.StdEncoding.EncodeToString(cpub))
			q.Set("psk", base64.StdEncoding.EncodeToString(psk[:]))
			answer["privateKey"] = base64.StdEncoding.EncodeToString(cpriv[:])
			answer["presharedKey"] = q.Get("psk")
		}
		r.URL.RawQuery = q.Encode()
		key, err := base64.StdEncoding.DecodeString(r.URL.Query().Get("key"))
		if err != nil || len(key) != 32 {
			http.Error(w, "bad key", 400)
			return
		}
		mu.Lock()
		addr := fmt.Sprintf("10.8.0.%d", next)
		next++
		mu.Unlock()
		cfg := fmt.Sprintf("public_key=%s\nallowed_ip=%s/32\n", hex.EncodeToString(key), addr)
		if psk := r.URL.Query().Get("psk"); psk != "" {
			raw, err := base64.StdEncoding.DecodeString(psk)
			if err != nil || len(raw) != 32 {
				http.Error(w, "bad psk", 400)
				return
			}
			cfg += "preshared_key=" + hex.EncodeToString(raw) + "\n"
		}
		if err := dev.IpcSet(cfg); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		log.Printf("peer %s at %s", r.URL.Query().Get("key"), addr)
		answer["address"] = addr + "/32"
		answer["serverPublicKey"] = base64.StdEncoding.EncodeToString(pub)
		answer["endpoint"] = *endpoint
		json.NewEncoder(w).Encode(answer)
	})
	log.Printf("ready, server key %s", base64.StdEncoding.EncodeToString(pub))
	log.Fatal(http.ListenAndServe(net.JoinHostPort(*listen, "8080"), control))
}
