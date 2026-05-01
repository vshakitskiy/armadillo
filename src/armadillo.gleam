import armadillo/udp
import gleam/erlang/process
import gleam/io
import gleam/otp/actor
import gleam/result

pub fn main() -> Nil {
  echo udp.new(state: Nil, handler: handle_udp)
    |> udp.port(3000)
    |> udp.bind("0.0.0.0")
    |> udp.with_ipv6
    |> udp.reuse_address
    |> udp.start

  process.sleep_forever()
}

fn handle_udp(
  socket: udp.Socket,
  state: Nil,
  message: udp.Message(Nil),
) -> udp.Next(Nil, Nil) {
  echo message

  udp.continue(state)
}
