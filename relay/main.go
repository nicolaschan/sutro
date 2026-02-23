package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/caddyserver/certmagic"
	p2pforge "github.com/ipshipyard/p2p-forge/client"
	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	quic "github.com/libp2p/go-libp2p/p2p/transport/quic"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	webrtc "github.com/libp2p/go-libp2p/p2p/transport/webrtc"
	ws "github.com/libp2p/go-libp2p/p2p/transport/websocket"
	webtransport "github.com/libp2p/go-libp2p/p2p/transport/webtransport"
)

func main() {
	port := flag.String("port", "4001", "port to listen on")
	identityPath := flag.String("identity", "identity.key", "path to persistent identity key")
	certPath := flag.String("certs", "certs", "path to certificate storage (only used with --autotls)")
	maxReservations := flag.Int("max-reservations", 256, "max circuit relay reservations")
	autoTLS := flag.Bool("autotls", false, "enable p2p-forge AutoTLS for libp2p.direct (not needed behind a reverse proxy)")
	flag.Parse()

	privKey := loadOrCreateIdentity(*identityPath)

	// Build libp2p options depending on whether AutoTLS is enabled.
	opts := []libp2p.Option{
		libp2p.Identity(privKey),
		libp2p.ForceReachabilityPublic(),
		libp2p.NATPortMap(),
		libp2p.ShareTCPListener(),
		libp2p.Transport(tcp.NewTCPTransport),
		libp2p.Transport(quic.NewTransport),
		libp2p.Transport(webtransport.New),
		libp2p.Transport(webrtc.New),
	}

	// Base listen addresses (shared by both modes).
	listenAddrs := []string{
		"/ip4/0.0.0.0/tcp/" + *port,
		"/ip4/0.0.0.0/udp/" + *port + "/quic-v1",
		"/ip4/0.0.0.0/udp/" + *port + "/quic-v1/webtransport",
		"/ip4/0.0.0.0/udp/" + *port + "/webrtc-direct",
		"/ip6/::/tcp/" + *port,
		"/ip6/::/udp/" + *port + "/quic-v1",
		"/ip6/::/udp/" + *port + "/quic-v1/webtransport",
		"/ip6/::/udp/" + *port + "/webrtc-direct",
	}

	var certManager *p2pforge.P2PForgeCertMgr
	var certLoaded chan struct{}

	if *autoTLS {
		certLoaded = make(chan struct{}, 1)

		var err error
		certManager, err = p2pforge.NewP2PForgeCertMgr(
			p2pforge.WithCertificateStorage(&certmagic.FileStorage{Path: *certPath}),
			p2pforge.WithUserAgent("sunset-relay/0.1.0"),
			p2pforge.WithOnCertLoaded(func() {
				select {
				case certLoaded <- struct{}{}:
				default:
				}
			}),
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to create cert manager: %s\n", err)
			os.Exit(1)
		}
		if err := certManager.Start(); err != nil {
			fmt.Fprintf(os.Stderr, "failed to start cert manager: %s\n", err)
			os.Exit(1)
		}
		defer certManager.Stop()

		// AutoTLS mode: WSS listeners with TLS/SNI via libp2p.direct
		listenAddrs = append(listenAddrs,
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%s/tls/sni/*.%s/ws", *port, p2pforge.DefaultForgeDomain),
			fmt.Sprintf("/ip6/::/tcp/%s/tls/sni/*.%s/ws", *port, p2pforge.DefaultForgeDomain),
		)
		opts = append(opts,
			libp2p.Transport(ws.New, ws.WithTLSConfig(certManager.TLSConfig())),
			libp2p.AddrsFactory(certManager.AddressFactory()),
		)
	} else {
		// Plain WS mode: intended for use behind a TLS-terminating reverse proxy.
		listenAddrs = append(listenAddrs,
			"/ip4/0.0.0.0/tcp/"+*port+"/ws",
			"/ip6/::/tcp/"+*port+"/ws",
		)
		opts = append(opts,
			libp2p.Transport(ws.New),
		)
	}

	opts = append(opts, libp2p.ListenAddrStrings(listenAddrs...))

	h, err := libp2p.New(opts...)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create libp2p host: %s\n", err)
		os.Exit(1)
	}
	defer h.Close()

	if *autoTLS {
		certManager.ProvideHost(h)
	}

	resources := relayv2.DefaultResources()
	resources.MaxReservations = *maxReservations
	if _, err := relayv2.New(h, relayv2.WithResources(resources)); err != nil {
		fmt.Fprintf(os.Stderr, "failed to create relay: %s\n", err)
		os.Exit(1)
	}

	fmt.Printf("Relay running with PeerID: %s\n", h.ID())
	fmt.Println("Addresses:")
	for _, addr := range h.Addrs() {
		fmt.Printf("  %s/p2p/%s\n", addr, h.ID())
	}

	if *autoTLS {
		go func() {
			<-certLoaded
			fmt.Println("AutoTLS certificate loaded. Updated addresses:")
			for _, addr := range h.Addrs() {
				fmt.Printf("  %s/p2p/%s\n", addr, h.ID())
			}
		}()
	}

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	<-ch
	fmt.Println("\nShutting down...")
}

func loadOrCreateIdentity(path string) crypto.PrivKey {
	data, err := os.ReadFile(path)
	if err == nil {
		key, err := crypto.UnmarshalPrivateKey(data)
		if err == nil {
			return key
		}
		fmt.Fprintf(os.Stderr, "warning: corrupt identity file, generating new key\n")
	}

	key, _, err := crypto.GenerateEd25519Key(nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to generate key: %s\n", err)
		os.Exit(1)
	}

	raw, err := crypto.MarshalPrivateKey(key)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to marshal key: %s\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(path, raw, 0600); err != nil {
		fmt.Fprintf(os.Stderr, "warning: could not save identity: %s\n", err)
	}

	return key
}
