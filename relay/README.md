# Sunset Relay

Minimal libp2p circuit relay server. Enables browser peers on HTTPS to connect to each other via WSS by relaying through this server, then upgrading to direct WebRTC.

By default the relay listens with **plain WebSocket**, designed to run behind a TLS-terminating reverse proxy (e.g. Traefik, Caddy, nginx). Optionally, pass `--autotls` to use [p2p-forge](https://github.com/ipshipyard/p2p-forge) (`libp2p.direct`) for automatic TLS certificates from Let's Encrypt.

## Build

Requires [Nix](https://nixos.org/) with flakes enabled.

```bash
# Binary
nix build .#default

# Docker image
nix build .#docker
docker load < result
```

## Run

### Behind a reverse proxy (recommended)

Run the relay behind a TLS-terminating reverse proxy that forwards WebSocket traffic. The relay listens on plain WS on port 4001:

```bash
docker run --network host -v sunset-relay-data:/data -it sunset-relay:latest
```

Configure your reverse proxy to route your domain (e.g. `relay.sunset.chat`) to the relay's WS port. With Traefik, expose the relay container and add the appropriate router/service labels.

### Standalone with AutoTLS

To run without a reverse proxy, use `--autotls` to provision TLS certificates automatically via `libp2p.direct`. The relay must be reachable on the specified port (TCP+UDP):

```bash
docker run --network host -v sunset-relay-data:/data -it sunset-relay:latest \
  --autotls --certs /data/certs
```

After a few seconds, AutoTLS obtains a wildcard cert and WSS addresses appear:

```
AutoTLS certificate loaded. Updated addresses:
  /ip6/<addr>/tcp/4001/tls/sni/<peerid>.libp2p.direct/ws/p2p/<peerid>
```

### Debug logging

```bash
docker run --network host -v sunset-relay-data:/data \
  -e GOLOG_LOG_LEVEL="p2p-forge/client=debug" \
  -it sunset-relay:latest
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port` | `4001` | TCP/UDP port to listen on |
| `--identity` | `identity.key` | Path to persistent peer identity key |
| `--autotls` | `false` | Enable p2p-forge AutoTLS for `libp2p.direct` (not needed behind a reverse proxy) |
| `--certs` | `certs` | Path to certificate storage directory (only used with `--autotls`) |
| `--max-reservations` | `256` | Max concurrent circuit relay reservations |

## Transports

- TCP
- QUIC v1
- WebTransport
- WebRTC-direct
- WS (plain, for use behind a reverse proxy) — or WSS via AutoTLS (`*.{peerid}.libp2p.direct`) with `--autotls`
