import armadillo/cache
import armadillo/dns
import armadillo/ip
import armadillo/sql
import gleam/erlang/application
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result

// oi, for the seek of testing, just run that:
// dig @127.0.0.1 -p 5003 google.com A

pub fn main() -> Nil {
  process.sleep_forever()
}

pub fn start(
  _type: application.StartType,
  _args: List(arg),
) -> Result(process.Pid, actor.StartError) {
  let conn = sql.open()
  let assert Ok(rows) = sql.get_records(conn)
  let records =
    list.filter_map(rows, fn(r) {
      case ip.from_string(r.ip) {
        Ok(addr) -> Ok(#(r.domain, addr))
        Error(_) -> Error(Nil)
      }
    })
  cache.init(records)

  let resolver_name = process.new_name("resolver_factory")

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(dns.supervised(resolver_name))
  |> supervisor.add(cache.worker())
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state: List(empty)) -> Nil {
  Nil
}
