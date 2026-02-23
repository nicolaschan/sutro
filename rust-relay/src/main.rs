use std::{
    hash::{DefaultHasher, Hash, Hasher},
    net::{Ipv4Addr, Ipv6Addr},
    path::PathBuf,
    time::Duration,
};

use clap::Parser;
use futures::StreamExt;
use libp2p::{
    core::multiaddr::Protocol,
    gossipsub, identify, identity,
    multiaddr::Multiaddr,
    noise, relay,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux,
};
use tokio::{fs, signal};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "sunset-relay", about = "Minimal libp2p circuit relay with gossipsub")]
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

#[derive(NetworkBehaviour)]
struct Behaviour {
    relay: relay::Behaviour,
    identify: identify::Behaviour,
    gossipsub: gossipsub::Behaviour,
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

    // Configure gossipsub
    let message_id_fn = |message: &gossipsub::Message| {
        let mut s = DefaultHasher::new();
        message.data.hash(&mut s);
        message.source.hash(&mut s);
        message.sequence_number.hash(&mut s);
        gossipsub::MessageId::from(s.finish().to_string())
    };

    let gossipsub_config = gossipsub::ConfigBuilder::default()
        .heartbeat_interval(Duration::from_secs(1))
        .validation_mode(gossipsub::ValidationMode::Permissive)
        .message_id_fn(message_id_fn)
        .build()
        .map_err(|e| format!("gossipsub config error: {e}"))?;

    let mut gossipsub = gossipsub::Behaviour::new(
        gossipsub::MessageAuthenticity::Signed(local_key.clone()),
        gossipsub_config,
    )
    .map_err(|e| format!("gossipsub error: {e}"))?;

    // Subscribe to the global discovery topic so we participate in the mesh
    // and forward messages between browser peers.
    let discovery_topic = gossipsub::IdentTopic::new("/sunset/discovery");
    gossipsub.subscribe(&discovery_topic)?;
    info!("Subscribed to /sunset/discovery");

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
            gossipsub,
        })?
        .build();

    // Listen on all interfaces — WebSocket (for browsers) and QUIC (for native peers)
    // Note: We don't listen on plain TCP separately because rust-libp2p's WebSocket
    // transport creates its own TCP listener. The Go relay used ShareTCPListener() to
    // share a port; rust-libp2p doesn't have that, so we only listen on WS (which uses
    // TCP underneath) and QUIC. Browsers connect via WS/WSS (through a reverse proxy).
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
                    SwarmEvent::Behaviour(BehaviourEvent::Gossipsub(
                        gossipsub::Event::Message { message, .. },
                    )) => {
                        // We receive messages on /sunset/discovery but don't need to
                        // process them — gossipsub automatically forwards to mesh peers.
                        info!(
                            "Discovery message from {:?} ({} bytes)",
                            message.source,
                            message.data.len()
                        );
                    }
                    SwarmEvent::Behaviour(BehaviourEvent::Gossipsub(
                        gossipsub::Event::Subscribed { peer_id, topic },
                    )) => {
                        info!("Peer {peer_id} subscribed to {topic}");
                    }
                    SwarmEvent::Behaviour(BehaviourEvent::Gossipsub(
                        gossipsub::Event::Unsubscribed { peer_id, topic },
                    )) => {
                        info!("Peer {peer_id} unsubscribed from {topic}");
                    }
                    SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                        info!("Connection established with {peer_id} via {}", endpoint.get_remote_address());
                    }
                    SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
                        info!("Connection closed with {peer_id}: {cause:?}");
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
