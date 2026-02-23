use std::{
    collections::HashMap,
    net::{Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use clap::Parser;
use futures::StreamExt;
use libp2p::{
    core::multiaddr::Protocol,
    identify, identity,
    multiaddr::Multiaddr,
    noise,
    relay,
    request_response::{self, ProtocolSupport},
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, PeerId, StreamProtocol,
};
use serde::{Deserialize, Serialize};
use tokio::{fs, signal, sync::Mutex};
use tracing::{debug, info, warn};
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "sunset-relay", about = "Minimal libp2p circuit relay with room-based peer discovery")]
struct Opt {
    /// Port to listen on
    #[arg(long, default_value = "4001")]
    port: u16,

    /// Path to persistent identity key
    #[arg(long, default_value = "identity.key")]
    identity: PathBuf,

    /// Max circuit relay reservations
    #[arg(long, default_value = "256")]
    max_reservations: u32,
}

// -- Discovery protocol types --

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DiscoveryRequest {
    room: String,
    peer_id: String,
    addrs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PeerInfo {
    peer_id: String,
    addrs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DiscoveryResponse {
    peers: Vec<PeerInfo>,
}

// -- Room registry --

struct PeerEntry {
    addrs: Vec<String>,
    last_seen: Instant,
}

type RoomRegistry = Arc<Mutex<HashMap<String, HashMap<String, PeerEntry>>>>;

const PEER_TTL: Duration = Duration::from_secs(30);

async fn handle_discovery(
    registry: &RoomRegistry,
    req: DiscoveryRequest,
) -> DiscoveryResponse {
    let mut rooms = registry.lock().await;

    // Expire stale entries in this room
    let now = Instant::now();
    if let Some(room) = rooms.get_mut(&req.room) {
        room.retain(|_, entry| now.duration_since(entry.last_seen) < PEER_TTL);
    }

    // Insert/update the requesting peer
    let room = rooms.entry(req.room.clone()).or_default();
    room.insert(
        req.peer_id.clone(),
        PeerEntry {
            addrs: req.addrs,
            last_seen: now,
        },
    );

    // Collect all other peers in the room
    let peers: Vec<PeerInfo> = room
        .iter()
        .filter(|(pid, _)| *pid != &req.peer_id)
        .map(|(pid, entry)| PeerInfo {
            peer_id: pid.clone(),
            addrs: entry.addrs.clone(),
        })
        .collect();

    DiscoveryResponse { peers }
}

/// Clean up a peer from all rooms when they disconnect.
async fn remove_peer(registry: &RoomRegistry, peer_id: &PeerId) {
    let peer_str = peer_id.to_string();
    let mut rooms = registry.lock().await;
    let mut empty_rooms = Vec::new();
    for (room_name, peers) in rooms.iter_mut() {
        peers.remove(&peer_str);
        if peers.is_empty() {
            empty_rooms.push(room_name.clone());
        }
    }
    for room_name in empty_rooms {
        rooms.remove(&room_name);
    }
}

// -- libp2p behaviour --

#[derive(NetworkBehaviour)]
struct Behaviour {
    relay: relay::Behaviour,
    identify: identify::Behaviour,
    discovery: request_response::json::Behaviour<DiscoveryRequest, DiscoveryResponse>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .try_init();

    let opt = Opt::parse();

    let local_key = load_or_create_identity(&opt.identity).await?;
    let local_peer_id = local_key.public().to_peer_id();

    info!("Local PeerID: {local_peer_id}");

    // Configure relay with reservation limits
    let relay_config = relay::Config {
        max_reservations: opt.max_reservations as usize,
        ..Default::default()
    };

    let mut swarm = libp2p::SwarmBuilder::with_existing_identity(local_key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_dns()?
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await?
        .with_behaviour(|key| Behaviour {
            relay: relay::Behaviour::new(key.public().to_peer_id(), relay_config),
            identify: identify::Behaviour::new(identify::Config::new(
                "/sunset-relay/0.1.0".to_string(),
                key.public(),
            )),
            discovery: request_response::json::Behaviour::new(
                [(
                    StreamProtocol::new("/sunset/discovery/1.0.0"),
                    ProtocolSupport::Full,
                )],
                request_response::Config::default(),
            ),
        })?
        .build();

    // Listen on all interfaces — WebSocket (for browsers) and QUIC (for native peers)
    let port = opt.port;

    // WebSocket over TCP (IPv4 + IPv6) — browsers connect here
    swarm.listen_on(
        Multiaddr::empty()
            .with(Protocol::from(Ipv4Addr::UNSPECIFIED))
            .with(Protocol::Tcp(port))
            .with(Protocol::Ws("/".into())),
    )?;
    swarm.listen_on(
        Multiaddr::empty()
            .with(Protocol::from(Ipv6Addr::UNSPECIFIED))
            .with(Protocol::Tcp(port))
            .with(Protocol::Ws("/".into())),
    )?;

    // QUIC (IPv4 + IPv6)
    swarm.listen_on(
        Multiaddr::empty()
            .with(Protocol::from(Ipv4Addr::UNSPECIFIED))
            .with(Protocol::Udp(port))
            .with(Protocol::QuicV1),
    )?;
    swarm.listen_on(
        Multiaddr::empty()
            .with(Protocol::from(Ipv6Addr::UNSPECIFIED))
            .with(Protocol::Udp(port))
            .with(Protocol::QuicV1),
    )?;

    info!("Relay listening on port {port}");

    let registry: RoomRegistry = Arc::new(Mutex::new(HashMap::new()));

    // Event loop
    loop {
        tokio::select! {
            event = swarm.next() => {
                match event.expect("swarm stream should be infinite") {
                    SwarmEvent::NewListenAddr { address, .. } => {
                        info!("Listening on {address}/p2p/{local_peer_id}");
                    }
                    SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received {
                        info: identify::Info { observed_addr, .. },
                        ..
                    })) => {
                        swarm.add_external_address(observed_addr);
                    }
                    SwarmEvent::Behaviour(BehaviourEvent::Relay(
                        relay::Event::ReservationReqAccepted { src_peer_id, .. },
                    )) => {
                        info!("Relay reservation accepted for {src_peer_id}");
                    }
                    SwarmEvent::Behaviour(BehaviourEvent::Discovery(
                        request_response::Event::Message {
                            peer,
                            message: request_response::Message::Request {
                                request,
                                channel,
                                ..
                            },
                            ..
                        },
                    )) => {
                        debug!(
                            "Discovery request from {peer}: room={} addrs={}",
                            request.room,
                            request.addrs.len()
                        );
                        let response = handle_discovery(&registry, request).await;
                        debug!("Responding with {} peers", response.peers.len());
                        if swarm
                            .behaviour_mut()
                            .discovery
                            .send_response(channel, response)
                            .is_err()
                        {
                            warn!("Failed to send discovery response to {peer}");
                        }
                    }
                    SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                        info!("Connection established with {peer_id} via {}", endpoint.get_remote_address());
                    }
                    SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
                        info!("Connection closed with {peer_id}: {cause:?}");
                        remove_peer(&registry, &peer_id).await;
                    }
                    _ => {}
                }
            }
            _ = signal::ctrl_c() => {
                info!("Shutting down...");
                break;
            }
        }
    }

    Ok(())
}

/// Load an Ed25519 identity from disk, or generate and save a new one.
async fn load_or_create_identity(
    path: &PathBuf,
) -> Result<identity::Keypair, Box<dyn std::error::Error>> {
    if let Ok(data) = fs::read(path).await {
        // Try to decode as a libp2p protobuf-encoded keypair first
        if let Ok(keypair) = identity::Keypair::from_protobuf_encoding(&data) {
            info!("Loaded identity from {}", path.display());
            return Ok(keypair);
        }
        // Try as raw Ed25519 secret key bytes (32 bytes)
        if data.len() == 32 {
            if let Ok(keypair) = identity::Keypair::ed25519_from_bytes(data) {
                info!("Loaded raw Ed25519 identity from {}", path.display());
                return Ok(keypair);
            }
        }
        warn!(
            "Could not decode identity file {}, generating new key",
            path.display()
        );
    }

    let keypair = identity::Keypair::generate_ed25519();
    let encoded = keypair.to_protobuf_encoding()?;
    fs::write(path, &encoded).await?;
    info!("Generated new identity, saved to {}", path.display());
    Ok(keypair)
}
