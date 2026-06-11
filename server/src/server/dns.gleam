import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import logging
import server/dns/protocol as dns
import server/dns/resolver
import server/dns/udp
import shared/ip

pub fn supervised(
  resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
) {
  let upstream = case envoy.get("DNS_UPSTREAM") {
    Ok(upstream_string) -> {
      case ip.from_string(upstream_string) {
        Ok(upstream) -> {
          logging.log(
            logging.Info,
            "Using " <> upstream_string <> " as DNS upstream",
          )
          upstream
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "Invalid DNS_UPSTREAM provided, using default value: 8.8.8.8",
          )

          ip.IpV4(8, 8, 8, 8)
        }
      }
    }
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "No DNS_UPSTREAM provided, using default value: 8.8.8.8",
      )

      ip.IpV4(8, 8, 8, 8)
    }
  }

  let port = case envoy.get("DNS_PORT") {
    Ok(port) -> {
      case int.parse(port) {
        Ok(port) -> port
        Error(Nil) -> {
          logging.log(
            logging.Warning,
            "Invalid DNS_PORT provided, using default value: 53",
          )

          53
        }
      }
    }
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "No DNS_PORT provided, using default value: 53",
      )

      53
    }
  }

  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(resolver.factory(resolver_name))
  |> supervisor.add(
    udp.new(state: State(upstream:, resolver_name:), handler: handle_message)
    |> udp.port(port)
    |> udp.bind("0.0.0.0")
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
