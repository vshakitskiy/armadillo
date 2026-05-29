import armadillo/cache
import armadillo/listener
import armadillo/resolver
import armadillo/sql
import gleam/erlang/application
import gleam/erlang/process
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
  cache.init(conn)

  let listener = process.new_name("listener")
  let resolver_factory = process.new_name("resolver_factory")

  let dns =
    supervisor.new(supervisor.OneForAll)
    |> supervisor.add(resolver.factory(resolver_factory))
    |> supervisor.add(listener.supervised(listener, resolver_factory))
    |> supervisor.supervised()

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(dns)
  |> supervisor.add(cache.worker())
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state: List(empty)) -> Nil {
  Nil
}
