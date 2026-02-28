import lustre/attribute.{autofocus, class, href, placeholder, type_, value}
import lustre/element.{type Element, text}
import lustre/element/html.{a, button, div, form, h1, input}
import lustre/event.{on_input, on_submit}
import sunset/model.{
  type Model, type Msg, UserClickedJoinRoom, UserUpdatedRoomInput,
}

pub fn view(model: Model) -> Element(Msg) {
  div([class("landing")], [
    div([class("landing-glow")], []),
    div([class("landing-content")], [
      div([class("landing-sun")], []),
      h1([class("landing-title")], [text("Sunset Chat")]),
      div([class("landing-horizon")], []),
      form([on_submit(fn(_) { UserClickedJoinRoom }), class("room-form")], [
        input([
          type_("text"),
          placeholder("Room name"),
          value(model.room_input),
          on_input(UserUpdatedRoomInput),
          class("room-input"),
          autofocus(True),
        ]),
        button([type_("submit"), class("room-button")], [text("Join")]),
      ]),
      a([href("/dev"), class("landing-link")], [text("Dev dashboard")]),
    ]),
  ])
}
