import gleam/erlang/process
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import logging
import server/dns/protocol as dns
import server/dns/resolver
import server/dns/udp
import server/env
import shared/ip

pub fn supervised(
  resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
) {
  let upstream =
    env.get_or(
      "DNS_UPSTREAM",
      parse: ip.from_string,
      or: ip.IpV4(8, 8, 8, 8),
      log: "8.8.8.8",
    )

  case ip.to_string(upstream) {
    Ok(upstream) ->
      logging.log(logging.Info, "Using " <> upstream <> " as a DNS upstream")
    Error(Nil) -> Nil
  }

  let port = env.get_or("DNS_PORT", parse: int.parse, or: 53, log: "53")

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(resolver.factory(resolver_name))
  |> supervisor.add(
    udp.new(state: State(upstream:, resolver_name:), handler: handle_message)
    |> udp.port(port)
    |> udp.bind("0.0.0.0")
    |> udp.on_start(fn(address, port) {
      let assert Ok(address) = ip.to_string(address)
      logging.log(
        logging.Info,
        "DNS listening on " <> address <> ":" <> int.to_string(port),
      )
    })
    |> udp.reuse_address
    |> udp.supervised,
  )
  |> supervisor.supervised
}

pub type State {
  State(
    upstream: ip.Address,
    resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
  )
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
            resolver.Resolve(peer:, query:, upstream: state.upstream)

          let factory = factory.get_by_name(state.resolver_name)
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
