import gleam/bit_array
import gleam/bool
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
  use text <- decode.then(decode.string)

  case ipv4_from_string(text) {
    Ok(address) -> decode.success(address)
    Error(Nil) -> decode.failure(Ipv4(0, 0, 0, 0), "Ipv4")
  }
}

pub fn ipv4_to_json(ip: Ipv4) -> json.Json {
  json.string(ipv4_to_string(ip))
}

pub fn ipv4_from_string(text: String) -> Result(Ipv4, Nil) {
  use <- bool.guard(when: string.byte_size(text) > 15, return: Error(Nil))

  case string.split(text, ".") |> list.try_map(parse_octet) {
    Ok([a, b, c, d]) -> Ok(Ipv4(a, b, c, d))
    _invalid_address -> Error(Nil)
  }
}

fn parse_octet(text: String) -> Result(Int, Nil) {
  use <- bool.guard(
    when: string.byte_size(text) > 1 && string.starts_with(text, "0"),
    return: Error(Nil),
  )

  use value <- result.try(parse_component(text, 10, 3))

  case value <= 255 {
    True -> Ok(value)
    False -> Error(Nil)
  }
}

fn parse_component(
  text: String,
  base: Int,
  max_digits: Int,
) -> Result(Int, Nil) {
  case
    string.byte_size(text) <= max_digits
    && valid_digits(bit_array.from_string(text), base)
  {
    True -> int.base_parse(text, base)
    False -> Error(Nil)
  }
}

fn valid_digits(bytes: BitArray, base: Int) -> Bool {
  case bytes {
    <<>> -> True
    <<digit, rest:bits>> if digit >= 48 && digit <= 57 ->
      valid_digits(rest, base)
    <<digit, rest:bits>> if base == 16 && digit >= 65 && digit <= 70 ->
      valid_digits(rest, base)
    <<digit, rest:bits>> if base == 16 && digit >= 97 && digit <= 102 ->
      valid_digits(rest, base)
    _invalid_digit -> False
  }
}

pub fn ipv4_is_valid(address: Ipv4) -> Bool {
  let Ipv4(a, b, c, d) = address

  list.all([a, b, c, d], fn(value) { value >= 0 && value <= 255 })
}

pub fn ipv4_from_bit_array(data: BitArray) -> Result(Ipv4, Nil) {
  case data {
    <<a:8, b:8, c:8, d:8>> -> Ok(Ipv4(a, b, c, d))
    _invalid_data -> Error(Nil)
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
  use text <- decode.then(decode.string)

  case ipv6_from_string(text) {
    Ok(address) -> decode.success(address)
    Error(Nil) -> decode.failure(Ipv6(0, 0, 0, 0, 0, 0, 0, 0), "Ipv6")
  }
}

pub fn ipv6_to_json(ip: Ipv6) -> json.Json {
  json.string(ipv6_to_string(ip))
}

pub fn ipv6_from_string(text: String) -> Result(Ipv6, Nil) {
  use <- bool.guard(when: string.byte_size(text) > 45, return: Error(Nil))

  use groups <- result.try(case string.split(text, "::") {
    [full] -> parse_groups(full)
    [left, right] -> {
      use <- bool.guard(when: string.contains(left, "."), return: Error(Nil))

      use before <- result.try(parse_groups(left))
      use after <- result.try(parse_groups(right))

      let omitted = 8 - list.length(before) - list.length(after)

      case omitted > 0 {
        True ->
          Ok(list.append(before, list.append(list.repeat(0, omitted), after)))
        False -> Error(Nil)
      }
    }
    _multiple_compressions -> Error(Nil)
  })

  case groups {
    [a, b, c, d, e, f, g, h] -> Ok(Ipv6(a, b, c, d, e, f, g, h))
    _invalid_group_count -> Error(Nil)
  }
}

fn parse_groups(text: String) -> Result(List(Int), Nil) {
  case text {
    "" -> Ok([])
    _groups -> parse_group_parts(string.split(text, ":"))
  }
}

fn parse_group_parts(parts: List(String)) -> Result(List(Int), Nil) {
  case parts {
    [] -> Ok([])
    [last] -> {
      case string.contains(last, ".") {
        True -> {
          use Ipv4(a, b, c, d) <- result.try(ipv4_from_string(last))

          Ok([a * 256 + b, c * 256 + d])
        }
        False ->
          parse_component(last, 16, 4) |> result.map(fn(value) { [value] })
      }
    }
    [part, ..rest] -> {
      use value <- result.try(parse_component(part, 16, 4))
      use remaining <- result.map(parse_group_parts(rest))

      [value, ..remaining]
    }
  }
}

pub fn ipv6_is_valid(address: Ipv6) -> Bool {
  let Ipv6(a, b, c, d, e, f, g, h) = address

  list.all([a, b, c, d, e, f, g, h], fn(value) { value >= 0 && value <= 65_535 })
}

pub fn ipv6_from_bit_array(data: BitArray) -> Result(Ipv6, Nil) {
  case data {
    <<a:16, b:16, c:16, d:16, e:16, f:16, g:16, h:16>> ->
      Ok(Ipv6(a, b, c, d, e, f, g, h))
    _invalid_data -> Error(Nil)
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
  case string.contains(text, ":") {
    True -> ipv6_from_string(text) |> result.map(V6)
    False -> ipv4_from_string(text) |> result.map(V4)
  }
}

pub fn to_string(ip: Address) -> String {
  case ip {
    V4(ip) -> ipv4_to_string(ip)
    V6(ip) -> ipv6_to_string(ip)
  }
}
