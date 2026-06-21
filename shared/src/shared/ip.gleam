import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Ipv4 {
  Ipv4(Int, Int, Int, Int)
}

pub fn ipv4_decoder() -> decode.Decoder(Ipv4) {
  use ip <- decode.then(decode.string)

  case ipv4_from_string(ip) {
    Ok(ip) -> decode.success(ip)
    Error(Nil) -> decode.failure(Ipv4(0, 0, 0, 0), "Ipv4")
  }
}

pub fn ipv4_to_json(ip: Ipv4) -> json.Json {
  ipv4_to_string(ip)
  |> json.string
}

pub fn ipv4_from_string(text: String) -> Result(Ipv4, Nil) {
  case string.split(text, on: ".") |> list.try_map(with: int.parse) {
    Ok([a, b, c, d]) -> Ok(Ipv4(a, b, c, d))
    _ -> Error(Nil)
  }
}

pub fn ipv4_from_bit_array(data: BitArray) -> Result(Ipv4, Nil) {
  case data {
    <<a:8, b:8, c:8, d:8>> -> Ok(Ipv4(a, b, c, d))
    _ -> Error(Nil)
  }
}

pub fn ipv4_to_string(ip: Ipv4) -> String {
  let Ipv4(a, b, c, d) = ip
  list.map([a, b, c, d], int.to_string) |> string.join(".")
}

pub fn ipv4_to_bit_array(ip: Ipv4) -> BitArray {
  let Ipv4(a, b, c, d) = ip
  <<a:8, b:8, c:8, d:8>>
}

pub type Ipv6 {
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn ipv6_decoder() -> decode.Decoder(Ipv6) {
  use ip <- decode.then(decode.string)

  case ipv6_from_string(ip) {
    Ok(ip) -> decode.success(ip)
    Error(Nil) -> decode.failure(Ipv6(0, 0, 0, 0, 0, 0, 0, 0), "Ipv6")
  }
}

pub fn ipv6_to_json(ip: Ipv6) -> json.Json {
  ipv6_to_string(ip)
  |> json.string
}

pub fn ipv6_from_string(text: String) -> Result(Ipv6, Nil) {
  case
    string.split(text, on: ":") |> list.try_map(with: int.base_parse(_, 16))
  {
    Ok([a, b, c, d, e, f, g, h]) -> Ok(Ipv6(a, b, c, d, e, f, g, h))
    _ -> Error(Nil)
  }
}

pub fn ipv6_from_bit_array(data: BitArray) -> Result(Ipv6, Nil) {
  case data {
    <<a:16, b:16, c:16, d:16, e:16, f:16, g:16, h:16>> ->
      Ok(Ipv6(a, b, c, d, e, f, g, h))
    _ -> Error(Nil)
  }
}

pub fn ipv6_to_string(ip: Ipv6) -> String {
  let Ipv6(a, b, c, d, e, f, g, h) = ip
  list.map([a, b, c, d, e, f, g, h], int.to_base16) |> string.join(":")
}

pub fn ipv6_to_bit_array(ip: Ipv6) -> BitArray {
  let Ipv6(a, b, c, d, e, f, g, h) = ip
  <<
    a:16,
    b:16,
    c:16,
    d:16,
    e:16,
    f:16,
    g:16,
    h:16,
  >>
}

pub type Address {
  V4(Ipv4)
  V6(Ipv6)
}

pub fn from_string(text: String) -> Result(Address, Nil) {
  case string.contains(text, "."), string.contains(text, ":") {
    True, False -> ipv4_from_string(text) |> result.map(V4)
    False, True -> ipv6_from_string(text) |> result.map(V6)
    _, _ -> Error(Nil)
  }
}

pub fn to_string(ip: Address) -> String {
  case ip {
    V4(ip) -> ipv4_to_string(ip)
    V6(ip) -> ipv6_to_string(ip)
  }
}
