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

pub fn from_bit_array(data: BitArray) -> Result(Address, Nil) {
  case data {
    <<a:8, b:8, c:8, d:8>> -> Ok(IpV4(a, b, c, d))
    <<a:16, b:16, c:16, d:16, e:16, f:16, g:16, h:16>> ->
      Ok(IpV6(a, b, c, d, e, f, g, h))
    _ -> Error(Nil)
  }
}
