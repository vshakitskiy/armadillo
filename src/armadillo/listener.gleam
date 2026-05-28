import armadillo/dns
import armadillo/ip
import armadillo/resolver
import armadillo/udp
import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/result

pub fn supervised(
  name: process.Name(udp.Message(Nil)),
  resolver_factory: process.Name(factory.Message(resolver.Resolve, Nil)),
) {
  let port =
    envoy.get("DNS_PORT")
    |> result.try(int.parse)
    |> result.unwrap(or: 53)

  udp.new(state: State(resolver_factory:), handler: handle_message)
  |> udp.port(port)
  |> udp.bind("0.0.0.0")
  |> udp.reuse_address
  |> udp.named(name)
  |> udp.supervised
}

type State {
  State(resolver_factory: process.Name(factory.Message(resolver.Resolve, Nil)))
}

fn handle_message(
  state: State,
  message: udp.Message(Nil),
) -> udp.Next(State, Nil) {
  case message {
    udp.Packet(peer:, data:) -> {
      case dns.decode(data) {
        Ok(dns.DecodedQuery(query)) -> {
          let resolve =
            resolver.Resolve(
              peer:,
              query:,
              original: data,
              upstream: ip.IpV4(8, 8, 8, 8),
            )

          let factory = factory.get_by_name(state.resolver_factory)
          let _ = factory.start_child(factory, resolve)

          udp.continue(state)
        }

        Ok(dns.DecodedResponse(_))
        | Error(dns.NotEnough)
        | Error(dns.Malformed) -> udp.continue(state)
      }
    }
    udp.User(_) -> udp.continue(state)
  }
}
