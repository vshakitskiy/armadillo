import armadillo/dns
import armadillo/udp
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision

pub fn factory(
  named: process.Name(factory.Message(#(udp.Peer, dns.Message), Nil)),
) {
  factory.worker_child(worker)
  |> factory.named(named)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.supervised
}

fn worker(arg: #(udp.Peer, dns.Message)) {
  let #(peer, message) = arg

  actor.new_with_initialiser(1000, fn(self) {
    process.send(self, Nil)

    actor.initialised(Nil)
    |> actor.returning(Nil)
    |> Ok
  })
  |> actor.on_message(fn(_state, _message) {
    case message {
      dns.Response(..) -> actor.stop()
      dns.Query(..) as message -> {
        echo message

        actor.stop()
      }
    }
  })
  |> actor.start()
}
