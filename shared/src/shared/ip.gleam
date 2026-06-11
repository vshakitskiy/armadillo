import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Address {
  IpV4(Int, Int, Int, Int)
  IpV6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub fn to_bit_array(ip: Address) -> BitArray {
  case ip {
    IpV4(a, b, c, d) -> <<a:8, b:8, c:8, d:8>>
    IpV6(a, b, c, d, e, f, g, h) -> <<
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
}

pub fn from_string(ip: String) -> Result(Address, Nil) {
  case string.contains(ip, ":"), string.contains(ip, ".") {
    True, False ->
      case string.split(ip, ":") {
        [a, b, c, d, e, f, g, h] -> {
          use a <- result.try(int.base_parse(a, 16))
          use b <- result.try(int.base_parse(b, 16))
          use c <- result.try(int.base_parse(c, 16))
          use d <- result.try(int.base_parse(d, 16))
          use e <- result.try(int.base_parse(e, 16))
          use f <- result.try(int.base_parse(f, 16))
          use g <- result.try(int.base_parse(g, 16))
          use h <- result.try(int.base_parse(h, 16))
          Ok(IpV6(a, b, c, d, e, f, g, h))
        }
        _ -> Error(Nil)
      }
    False, True ->
      case string.split(ip, ".") {
        [a, b, c, d] -> {
          use a <- result.try(int.parse(a))
          use b <- result.try(int.parse(b))
          use c <- result.try(int.parse(c))
          use d <- result.try(int.parse(d))
          Ok(IpV4(a, b, c, d))
        }
        _ -> Error(Nil)
      }
    _, _ -> Error(Nil)
  }
}

pub fn to_string(ip: Address) -> Result(String, Nil) {
  case ip {
    IpV4(a, b, c, d) ->
      Ok([a, b, c, d] |> list.map(int.to_string) |> string.join("."))
    IpV6(a, b, c, d, e, f, g, h) ->
      [a, b, c, d, e, f, g, h]
      |> list.try_map(int.to_base_string(_, 16))
      |> result.map(string.join(_, ":"))
  }
}

pub fn from_bit_array(data: BitArray) -> Result(Address, Nil) {
  case data {
    <<a:8, b:8, c:8, d:8>> -> Ok(IpV4(a, b, c, d))
    <<a:16, b:16, c:16, d:16, e:16, f:16, g:16, h:16>> ->
      Ok(IpV6(a, b, c, d, e, f, g, h))
    _ -> Error(Nil)
  }
}
