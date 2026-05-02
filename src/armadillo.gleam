import armadillo/udp
import gleam/erlang/process

pub fn main() -> Nil {
  let _ =
    udp.new(state: Nil, handler: handle_udp)
    |> udp.port(5003)
    |> udp.reuse_address
    |> udp.start
    |> echo

  process.sleep_forever()
}

fn handle_udp(state: Nil, message: udp.Message(Nil)) -> udp.Next(Nil, Nil) {
  case message {
    udp.Packet(peer:, data:) -> {
      let _ = udp.send(peer, data)
      udp.continue(state)
    }
    udp.User(_) -> udp.continue(state)
  }
}
