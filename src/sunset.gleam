import gleam/string
import lustre
import lustre/effect.{type Effect}
import sunset/libp2p
import sunset/model.{
  type Model, type Msg, AudioFailed, AudioStarted, ChatMessage,
  ChatMessageReceived, DialFailed, DialSucceeded, HashChanged, Libp2pInitialised,
  Model, RelayConnected, RelayConnecting, RelayDialFailed, RelayDialSucceeded,
  RelayDisconnected, Room, RouteChanged, SendFailed, SendSucceeded, Tick,
  UserClickedConnect, UserClickedJoinRoom, UserClickedLeaveRoom, UserClickedSend,
  UserClickedStartAudio, UserClickedStopAudio, UserToggledNodeInfo,
  UserUpdatedChatInput, UserUpdatedMultiaddr, UserUpdatedRoomInput,
}
import sunset/nav
import sunset/router
import sunset/view

const default_relay = "/dnsname/relay.sunset.chat/tcp/443/wss/p2p/12D3KooWAvzBJHKbkWkn3qVH7DdhyJCNFLxQFUrpUFWYueVKzrNY"

pub fn main() {
  let app = lustre.application(init, update, view.view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

// -- MODEL --

fn init(_flags) -> #(Model, Effect(Msg)) {
  let route = router.init_route()
  let room_name = case route {
    Room(name) -> name
    _ -> ""
  }

  let model =
    Model(
      route: route,
      room_input: "",
      room_name: room_name,
      peer_id: "",
      status: "Initialising...",
      relay_status: RelayDisconnected,
      show_node_info: False,
      multiaddr_input: "",
      addresses: [],
      peers: [],
      connection_count: 0,
      error: "",
      chat_input: "",
      messages: [],
      audio_sending: False,
      audio_receiving: False,
      audio_error: "",
    )

  #(
    model,
    effect.batch([init_libp2p_effect(), router.init(), init_hash_listener()]),
  )
}

// -- UPDATE --

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> {
      #(Model(..model, route: route), effect.none())
    }

    HashChanged(hash) -> {
      case hash {
        "" -> #(Model(..model, route: model.Home, room_name: ""), effect.none())
        room -> {
          let new_model = Model(..model, route: Room(room), room_name: room)
          // If libp2p is ready and relay not connected, auto-dial
          case model.peer_id, model.relay_status {
            "", _ -> #(new_model, effect.none())
            _, RelayDisconnected -> #(
              Model(..new_model, relay_status: RelayConnecting),
              dial_relay_effect(),
            )
            _, _ -> #(new_model, effect.none())
          }
        }
      }
    }

    UserUpdatedRoomInput(val) -> {
      #(Model(..model, room_input: val), effect.none())
    }

    UserClickedJoinRoom -> {
      let room = string.trim(model.room_input)
      case room {
        "" -> #(model, effect.none())
        _ -> {
          let new_model = Model(..model, route: Room(room), room_name: room)
          // If libp2p is ready and relay not connected, auto-dial
          case model.peer_id, model.relay_status {
            "", _ -> #(new_model, set_hash_effect(room))
            _, RelayDisconnected -> #(
              Model(..new_model, relay_status: RelayConnecting),
              effect.batch([set_hash_effect(room), dial_relay_effect()]),
            )
            _, _ -> #(new_model, set_hash_effect(room))
          }
        }
      }
    }

    UserClickedLeaveRoom -> {
      #(
        Model(..model, route: model.Home, room_name: "", room_input: ""),
        clear_hash_effect(),
      )
    }

    UserToggledNodeInfo -> {
      #(Model(..model, show_node_info: !model.show_node_info), effect.none())
    }

    Libp2pInitialised(peer_id) -> {
      let new_model =
        Model(..model, peer_id: peer_id, status: "Online", error: "")
      // If we're already in a room, auto-dial the relay
      let effects = [
        start_polling(),
        register_chat_effect(),
        register_signaling_effect(),
      ]
      case new_model.room_name {
        "" -> #(new_model, effect.batch(effects))
        _ -> #(
          Model(..new_model, relay_status: RelayConnecting),
          effect.batch([dial_relay_effect(), ..effects]),
        )
      }
    }

    RelayDialSucceeded -> {
      #(Model(..model, relay_status: RelayConnected, error: ""), effect.none())
    }

    RelayDialFailed(err) -> {
      #(Model(..model, relay_status: model.RelayFailed(err)), effect.none())
    }

    UserUpdatedMultiaddr(val) -> {
      #(Model(..model, multiaddr_input: val), effect.none())
    }

    UserClickedConnect -> {
      case model.multiaddr_input {
        "" -> #(
          Model(..model, error: "Please enter a multiaddr"),
          effect.none(),
        )
        addr -> #(Model(..model, error: ""), dial_effect(addr))
      }
    }

    DialSucceeded -> {
      #(Model(..model, multiaddr_input: "", error: ""), effect.none())
    }

    DialFailed(err) -> {
      #(Model(..model, error: "Dial failed: " <> err), effect.none())
    }

    Tick -> {
      let addrs = libp2p.get_multiaddrs()
      let peers = libp2p.get_connected_peers()
      let count = libp2p.get_connection_count()
      let sending = libp2p.is_audio_active()
      let receiving = libp2p.is_receiving_audio()
      #(
        Model(
          ..model,
          addresses: addrs,
          peers: peers,
          connection_count: count,
          audio_sending: sending,
          audio_receiving: receiving,
        ),
        schedule_tick(),
      )
    }

    UserUpdatedChatInput(val) -> {
      #(Model(..model, chat_input: val), effect.none())
    }

    UserClickedSend -> {
      case model.chat_input {
        "" -> #(model, effect.none())
        msg_text -> {
          let message = ChatMessage(sender: "You", body: msg_text)
          #(
            Model(..model, chat_input: "", messages: [message, ..model.messages]),
            broadcast_effect(msg_text),
          )
        }
      }
    }

    SendSucceeded -> #(model, effect.none())

    SendFailed(err) -> {
      let message = ChatMessage(sender: "System", body: "Send failed: " <> err)
      #(Model(..model, messages: [message, ..model.messages]), effect.none())
    }

    ChatMessageReceived(sender, body) -> {
      let short_sender = short_peer_id(sender)
      let message = ChatMessage(sender: short_sender, body: body)
      #(Model(..model, messages: [message, ..model.messages]), effect.none())
    }

    UserClickedStartAudio -> {
      #(Model(..model, audio_error: ""), start_audio_effect())
    }

    UserClickedStopAudio -> {
      #(
        Model(..model, audio_sending: False, audio_error: ""),
        stop_audio_effect(),
      )
    }

    AudioStarted -> {
      #(Model(..model, audio_sending: True, audio_error: ""), effect.none())
    }

    AudioFailed(err) -> {
      #(Model(..model, audio_sending: False, audio_error: err), effect.none())
    }
  }
}

// -- EFFECTS --

fn init_libp2p_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.init_libp2p(fn(peer_id) { dispatch(Libp2pInitialised(peer_id)) })
  })
}

fn init_hash_listener() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    nav.on_hash_change(fn(hash) { dispatch(HashChanged(hash)) })
  })
}

fn set_hash_effect(room: String) -> Effect(Msg) {
  effect.from(fn(_dispatch) { nav.set_hash(room) })
}

fn clear_hash_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { nav.clear_hash() })
}

fn dial_relay_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.dial_multiaddr(
      default_relay,
      fn() { dispatch(RelayDialSucceeded) },
      fn(err) { dispatch(RelayDialFailed(err)) },
    )
  })
}

fn dial_effect(addr: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.dial_multiaddr(addr, fn() { dispatch(DialSucceeded) }, fn(err) {
      dispatch(DialFailed(err))
    })
  })
}

fn start_polling() -> Effect(Msg) {
  schedule_tick()
}

fn schedule_tick() -> Effect(Msg) {
  effect.from(fn(dispatch) { libp2p.set_timeout(fn() { dispatch(Tick) }, 1000) })
}

fn register_chat_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.register_chat_handler(fn(sender, body) {
      dispatch(ChatMessageReceived(sender, body))
    })
  })
}

fn register_signaling_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { libp2p.register_signaling_handler() })
}

fn broadcast_effect(msg_text: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.broadcast_message(
      msg_text,
      fn() { dispatch(SendSucceeded) },
      fn(err) { dispatch(SendFailed(err)) },
    )
  })
}

fn start_audio_effect() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    libp2p.start_audio(fn() { dispatch(AudioStarted) }, fn(err) {
      dispatch(AudioFailed(err))
    })
  })
}

fn stop_audio_effect() -> Effect(Msg) {
  effect.from(fn(_dispatch) { libp2p.stop_audio() })
}

fn short_peer_id(peer_id: String) -> String {
  let len = string.length(peer_id)
  case len > 12 {
    True ->
      string.slice(peer_id, 0, 6) <> ".." <> string.slice(peer_id, len - 4, 4)
    False -> peer_id
  }
}
