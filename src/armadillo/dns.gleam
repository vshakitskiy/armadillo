import armadillo/dns/protocol as dns
import armadillo/dns/resolver
import armadillo/dns/udp
import armadillo/ip
import envoy
import gleam/erlang/process
import gleam/int
import gleam/otp/factory_supervisor as factory
import gleam/otp/static_supervisor as supervisor
import gleam/result

pub fn supervised(
  resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
) {
  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(resolver.factory(resolver_name))
  |> supervisor.add(listener(resolver_name))
  |> supervisor.supervised()
}

fn listener(
  resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
) {
  let port =
    envoy.get("DNS_PORT")
    |> result.try(int.parse)
    |> result.unwrap(or: 53)

  udp.new(state: resolver_name, handler: handle_message)
  |> udp.port(port)
  |> udp.bind("0.0.0.0")
  |> udp.reuse_address
  |> udp.supervised
}

fn handle_message(
  resolver_name: process.Name(factory.Message(resolver.Resolve, Nil)),
  message: udp.Message(Nil),
) -> udp.Next(process.Name(factory.Message(resolver.Resolve, Nil)), Nil) {
  case message {
    udp.Packet(peer:, data:) -> {
      case dns.decode(data) {
        Ok(dns.DecodedQuery(query)) -> {
          let resolve =
            resolver.Resolve(peer:, query:, upstream: ip.IpV4(8, 8, 8, 8))

          let factory = factory.get_by_name(resolver_name)
          let _ = factory.start_child(factory, resolve)

          udp.continue(resolver_name)
        }

        Ok(dns.DecodedResponse(_))
        | Error(dns.NotEnough)
        | Error(dns.Malformed) -> udp.continue(resolver_name)
      }
    }
    udp.User(_) -> udp.continue(resolver_name)
  }
}
