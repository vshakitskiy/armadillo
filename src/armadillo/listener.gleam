import armadillo/dns
import armadillo/udp
import gleam/erlang/process
import gleam/otp/factory_supervisor as factory

pub fn supervised(
  name: process.Name(udp.Message(Nil)),
  resolver_factory: process.Name(factory.Message(#(udp.Peer, dns.Message), Nil)),
) {
  udp.new(state: State(resolver_factory:), handler: handle_message)
  |> udp.port(5003)
  |> udp.reuse_address
  |> udp.named(name)
  |> udp.supervised
}

type State {
  State(
    resolver_factory: process.Name(
      factory.Message(#(udp.Peer, dns.Message), Nil),
    ),
  )
}

fn handle_message(
  state: State,
  message: udp.Message(Nil),
) -> udp.Next(State, Nil) {
  case message {
    udp.Packet(peer:, data:) -> {
      case dns.decode(data) {
        Ok(message) -> {
          let factory = factory.get_by_name(state.resolver_factory)
          let _ = factory.start_child(factory, #(peer, message))

          udp.continue(state)
        }
        Error(dns.NotEnough) -> udp.continue(state)
        Error(dns.Malformed) -> udp.continue(state)
      }
    }
    udp.User(_) -> udp.continue(state)
  }
}
