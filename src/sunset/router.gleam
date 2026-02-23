import gleam/result
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}
import modem
import sunset/model.{type Msg, type Route, Dev, Home, Room, RouteChanged}
import sunset/nav

fn on_url_change(uri: Uri) -> Msg {
  let route = case uri.path_segments(uri.path) {
    ["dev"] -> Dev
    _ -> Home
  }
  RouteChanged(route)
}

pub fn init_route() -> Route {
  // Check hash first — if there's a room name in the hash, go to Room
  let hash = nav.get_hash()
  case hash {
    "" -> {
      modem.initial_uri()
      |> result.map(fn(uri) { uri.path_segments(uri.path) })
      |> fn(path) {
        case path {
          Ok(["dev"]) -> Dev
          _ -> Home
        }
      }
    }
    room_name -> Room(room_name)
  }
}

pub fn init() -> Effect(Msg) {
  modem.init(on_url_change)
}
