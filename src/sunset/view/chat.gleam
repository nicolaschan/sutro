import gleam/list
import lustre/attribute.{autofocus, class, classes, placeholder, type_, value}
import lustre/element.{type Element, text}
import lustre/element/html.{button, div, form, input, span}
import lustre/event.{on_input, on_submit}
import sunset/model.{type Model, type Msg, UserClickedSend, UserUpdatedChatInput}

/// Room-style message list with empty state.
pub fn view_messages(model: Model) -> Element(Msg) {
  div([class("room-messages")], case model.messages {
    [] -> [
      div([class("room-messages-empty")], [
        div([class("room-messages-empty-icon")], [text("\u{2600}")]),
        div([], [text("No messages yet")]),
        div([class("room-messages-empty-sub")], [
          text("Say something to get the conversation started"),
        ]),
      ]),
    ]
    msgs ->
      list.map(list.reverse(msgs), fn(msg) {
        div(
          [
            classes([
              #("room-msg", True),
              #("room-msg-self", msg.sender == "You"),
              #("room-msg-system", msg.sender == "System"),
            ]),
          ],
          [
            case msg.sender {
              "You" -> text("")
              _ -> span([class("room-msg-sender")], [text(msg.sender)])
            },
            div([class("room-msg-body")], [text(msg.body)]),
          ],
        )
      })
  })
}

/// Room-style chat input bar.
pub fn view_input(model: Model) -> Element(Msg) {
  form([on_submit(fn(_) { UserClickedSend }), class("room-input-bar")], [
    input([
      type_("text"),
      placeholder("Type a message..."),
      value(model.chat_input),
      on_input(UserUpdatedChatInput),
      class("room-chat-input"),
      autofocus(True),
    ]),
    button([type_("submit"), class("room-send-button")], [text("Send")]),
  ])
}
