import armadillo/listener
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
  supervisor.new(supervisor.OneForAll)
  |> supervisor.add(listener.supervised())
  |> supervisor.start()
  |> result.map(fn(started) { started.pid })
}

pub fn stop(_state: List(empty)) -> Nil {
  Nil
}
