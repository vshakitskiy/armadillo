import gleam/dynamic/decode
import gleam/json

pub type Record {
  Record(domain: String, ip: String)
}

pub fn to_json(record: Record) -> json.Json {
  let Record(domain:, ip:) = record
  json.object([
    #("domain", json.string(domain)),
    #("ip", json.string(ip)),
  ])
}

pub fn keyed_to_json(keyed: #(String, String)) -> json.Json {
  let #(domain, ip) = keyed

  json.object([
    #("domain", json.string(domain)),
    #("ip", json.string(ip)),
  ])
}

pub fn keyed_decoder() -> decode.Decoder(#(String, String)) {
  use domain <- decode.field("domain", decode.string)
  use ip <- decode.field("ip", decode.string)
  decode.success(#(domain, ip))
}

pub fn json_decoder() -> decode.Decoder(Record) {
  use domain <- decode.field("domain", decode.string)
  use ip <- decode.field("ip", decode.string)
  decode.success(Record(domain:, ip:))
}

pub fn index_decoder() -> decode.Decoder(Record) {
  use domain <- decode.field(0, decode.string)
  use ip <- decode.field(1, decode.string)
  decode.success(Record(domain:, ip:))
}
