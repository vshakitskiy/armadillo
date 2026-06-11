import gleam/erlang/application
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import server/api
import server/cache
import server/dns
import server/sql
import shared/ip
import wisp

const name = "  __   ____  _  _   __   ____  __  __    __     __  
 / _\\ (  _ \\( \\/ ) / _\\ (    \\(  )(  )  (  )   /  \\ 
/    \\ )   // \\/ \\/    \\ ) D ( )( / (_/\\/ (_/\\(  O )
\\_/\\_/(__\\_)\\_)(_/\\_/\\_/(____/(__)\\____/\\____/ \\__/"

pub fn main() -> Nil {
  io.println("")
  process.sleep_forever()
}

@external(erlang, "terminal_ffi", "clear")
pub fn clear_terminal() -> Nil

pub fn start(
  _type: application.StartType,
  _args: List(arg),
) -> Result(process.Pid, actor.StartError) {
  clear_terminal()
  io.println("\n\n" <> name <> "\n\n")

  wisp.configure_logger()

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
  |> supervisor.add(api.supervised(conn))
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state: List(empty)) -> Nil {
  Nil
}
