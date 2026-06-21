import gleam/erlang/application
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import server/api
import server/cache
import server/dns
import server/zone
import wisp

const name = "  __   ____  _  _   __   ____  __  __    __     __  
 / _\\ (  _ \\( \\/ ) / _\\ (    \\(  )(  )  (  )   /  \\ 
/    \\ )   // \\/ \\/    \\ ) D ( )( / (_/\\/ (_/\\(  O )
\\_/\\_/(__\\_)\\_)(_/\\_/\\_/(____/(__)\\____/\\____/ \\__/"

pub fn main() -> Nil {
  io.println("\n")
  process.sleep_forever()
  // <!-- dig @127.0.0.1 google.com A -->
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

  let assert Ok(zone) = zone.read("../data/local.zone")
  cache.init(zone.records)

  let resolver_name = process.new_name("resolver_factory")
  let zone_name = process.new_name("zone_worker")

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(zone.worker(zone_name, "../data/local.zone"))
  |> supervisor.add(cache.worker())
  |> supervisor.add(dns.supervised(resolver_name))
  |> supervisor.add(api.supervised(process.named_subject(zone_name)))
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state: List(empty)) -> Nil {
  Nil
}
