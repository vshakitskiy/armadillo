import armadillo/dns
import armadillo/internal/udp

pub fn supervised() {
  udp.new(state: Nil, handler: handle_message)
  |> udp.port(5003)
  |> udp.reuse_address
  |> udp.supervised
}

fn handle_message(state: Nil, message: udp.Message(a)) -> udp.Next(Nil, a) {
  case message {
    udp.Packet(peer:, data:) -> {
      echo dns.decode(data)
      udp.continue(state)
    }
    udp.User(_) -> udp.continue(state)
  }
}
