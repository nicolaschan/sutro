import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute.{class, classes, title}
import lustre/element.{type Element, text}
import lustre/element/html.{button, div, li, span, ul}
import lustre/event.{on_click}
import sunset/model.{
  type Model, type Msg, UserClickedPeer, UserClosedPeerModal, classify_transport,
  peer_display_name,
}

/// Count connected peers (excluding self and relay).
pub fn connection_count(model: Model) -> Int {
  list.length(
    list.filter(model.peers, fn(pid) {
      pid != model.peer_id && pid != model.relay_peer_id
    }),
  )
}

/// Look up the first address for a peer from the connections list.
pub fn peer_addr(model: Model, peer_id: String) -> String {
  case list.find(model.connections, fn(pair) { pair.0 == peer_id }) {
    Ok(#(_, addr)) -> addr
    Error(_) -> ""
  }
}

/// Look up the transport type for a peer's connection.
pub fn peer_transport(model: Model, peer_id: String) -> String {
  case list.find(model.connections, fn(pair) { pair.0 == peer_id }) {
    Ok(#(_, addr)) -> classify_transport(addr)
    Error(_) -> ""
  }
}

/// Look up a peer's audio presence from the presence protocol.
/// Returns #(joined, muted).
pub fn peer_audio_state(model: Model, peer_id: String) -> #(Bool, Bool) {
  case list.find(model.peer_presence, fn(entry) { entry.0 == peer_id }) {
    Ok(#(_, presence)) -> #(presence.joined, presence.muted)
    Error(_) -> #(False, False)
  }
}

/// Look up a peer's audio PC connection state.
/// Returns "" if no audio PC, or the connectionState string.
pub fn peer_audio_pc_state(model: Model, peer_id: String) -> String {
  case list.find(model.audio_pc_states, fn(entry) { entry.0 == peer_id }) {
    Ok(#(_, state)) -> state
    Error(_) -> ""
  }
}

fn relay_display_name(addr: String) -> String {
  case string.split(addr, "/") {
    ["", "dns", hostname, ..] -> hostname
    _ -> "relay"
  }
}

/// Render a single peer list item. `is_disconnected` controls whether
/// this peer is shown with the red disconnected dot.
pub fn view_peer_item(
  model: Model,
  peer_id: String,
  is_disconnected: Bool,
) -> Element(Msg) {
  let is_relay = peer_id == model.relay_peer_id
  let transport = peer_transport(model, peer_id)
  let is_circuit = transport == "Circuit Relay"
  let addr = peer_addr(model, peer_id)
  let #(audio_joined, audio_muted) = peer_audio_state(model, peer_id)
  let rtc_state = peer_audio_pc_state(model, peer_id)
  li(
    [
      classes([
        #("room-peer", True),
        #("room-peer-relay", is_relay),
        #("room-peer-disconnected", is_disconnected),
      ]),
      on_click(UserClickedPeer(peer_id)),
    ],
    [
      span(
        [
          classes([
            #("room-peer-dot", True),
            #("room-peer-dot-relay", is_relay),
            #("room-peer-dot-circuit", is_circuit && !is_relay),
            #("room-peer-dot-disconnected", is_disconnected),
            #(
              "room-peer-dot-rtc-connected",
              rtc_state == "connected" && !is_disconnected,
            ),
            #(
              "room-peer-dot-rtc-connecting",
              { rtc_state == "new" || rtc_state == "connecting" }
                && !is_disconnected,
            ),
          ]),
        ],
        [],
      ),
      div([class("room-peer-info")], [
        div([class("room-peer-name")], [
          span([class("room-peer-id")], [
            case is_relay {
              True -> text(relay_display_name(addr))
              False -> text(peer_display_name(model, peer_id))
            },
          ]),
          case is_relay {
            True -> span([class("room-peer-badge")], [text("relay")])
            False -> text("")
          },
          case is_disconnected {
            True ->
              span([class("room-peer-badge room-peer-badge-disconnected")], [
                text("reconnecting"),
              ])
            False -> text("")
          },
          // Audio presence indicator
          case is_relay, audio_joined {
            True, _ -> text("")
            _, False -> text("")
            _, True ->
              span(
                [
                  classes([
                    #("room-peer-audio", True),
                    #("room-peer-audio-muted", audio_muted),
                  ]),
                  title(case audio_muted {
                    True -> "In audio (muted)"
                    False -> "In audio"
                  }),
                ],
                [
                  text(case audio_muted {
                    True -> "\u{1F507}"
                    False -> "\u{1F3A4}"
                  }),
                ],
              )
          },
        ]),
        case is_relay {
          True -> text("")
          False ->
            case addr {
              "" -> text("")
              a ->
                div([class("room-peer-addr"), title(a)], [
                  text(a),
                ])
            }
        },
      ]),
    ],
  )
}

pub fn view_peer_modal(model: Model) -> Element(Msg) {
  case model.selected_peer {
    None -> text("")
    Some(peer_id) -> {
      let is_relay = peer_id == model.relay_peer_id
      // Get all connections for this peer and compute transport
      let addrs =
        list.filter_map(model.connections, fn(conn) {
          case conn.0 == peer_id {
            True -> Ok(#(classify_transport(conn.1), conn.1))
            False -> Error(Nil)
          }
        })
      // Look up version from peer presence
      let version = case
        list.find(model.peer_presence, fn(entry) { entry.0 == peer_id })
      {
        Ok(#(_, presence)) ->
          case presence.version {
            "" -> "unknown"
            v -> v
          }
        Error(_) -> "unknown"
      }
      div([class("modal-overlay")], [
        div([class("modal-backdrop"), on_click(UserClosedPeerModal)], []),
        div([class("modal-card")], [
          div([class("modal-header")], [
            div([class("modal-title-row")], [
              span(
                [
                  classes([
                    #("room-peer-dot", True),
                    #("room-peer-dot-relay", is_relay),
                  ]),
                ],
                [],
              ),
              span([class("modal-title")], [
                text(peer_display_name(model, peer_id)),
              ]),
              case is_relay {
                True -> span([class("room-peer-badge")], [text("relay")])
                False -> text("")
              },
            ]),
            button([on_click(UserClosedPeerModal), class("modal-close")], [
              text("\u{00D7}"),
            ]),
          ]),
          div([class("modal-section")], [
            div([class("modal-section-label")], [text("Peer ID")]),
            div([class("modal-mono")], [text(peer_id)]),
          ]),
          div([class("modal-section")], [
            div([class("modal-section-label")], [text("Version")]),
            div([class("modal-mono")], [text(version)]),
          ]),
          div([class("modal-section")], [
            div([class("modal-section-label")], [
              text("Addresses (" <> int.to_string(list.length(addrs)) <> ")"),
            ]),
            case addrs {
              [] -> div([class("modal-empty")], [text("No connections")])
              _ ->
                ul(
                  [class("modal-addr-list")],
                  list.map(addrs, fn(pair) {
                    li([class("modal-addr-item")], [
                      span([class("modal-addr-transport")], [text(pair.0)]),
                      span([class("modal-addr-value")], [text(pair.1)]),
                    ])
                  }),
                )
            },
          ]),
        ]),
      ])
    }
  }
}
