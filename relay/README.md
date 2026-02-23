# Sunset Relay

Minimal libp2p circuit relay server with AutoTLS. Enables browser peers on HTTPS to connect to each other via WSS by relaying through this server, then upgrading to direct WebRTC.

Uses [p2p-forge](https://github.com/ipshipyard/p2p-forge) (`libp2p.direct`) for automatic TLS certificates from Let's Encrypt.

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

The relay must run on a host with a **public IP** reachable on port 4001 (TCP+UDP). Use `--network host` so libp2p binds directly to the host's interfaces:

```bash
docker run --network host -v sunset-relay-data:/data -it sunset-relay:latest
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
| `--certs` | `certs` | Path to certificate storage directory |
| `--max-reservations` | `256` | Max concurrent circuit relay reservations |

## Transports

- TCP
- QUIC v1
- WebTransport
- WebRTC-direct
- WSS via AutoTLS (`*.{peerid}.libp2p.direct`)
