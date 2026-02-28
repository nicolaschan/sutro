import lustre/element.{type Element}
import sunset/model.{type Model, type Msg, Dev, Home, Room}
import sunset/view/dev
import sunset/view/home
import sunset/view/room

pub fn view(model: Model) -> Element(Msg) {
  case model.route {
    Home -> home.view(model)
    Room(_) -> room.view(model)
    Dev -> dev.view(model)
  }
}
