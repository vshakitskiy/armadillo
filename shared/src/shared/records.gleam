import gleam/dynamic/decode
import gleam/json
import shared/ip

pub type Record {
  ARecord(name: String, ttl: Int, ip: ip.Ipv4)
  AaaaRecord(name: String, ttl: Int, ip: ip.Ipv6)
  CnameRecord(name: String, ttl: Int, target: String)
}

pub fn decoder() -> decode.Decoder(Record) {
  use variant <- decode.field("type", decode.string)
  case variant {
    "a_record" -> {
      use name <- decode.field("name", decode.string)
      use ttl <- decode.field("ttl", decode.int)
      use ip <- decode.field("ip", ip.ipv4_decoder())
      decode.success(ARecord(name:, ttl:, ip:))
    }
    "aaaa_record" -> {
      use name <- decode.field("name", decode.string)
      use ttl <- decode.field("ttl", decode.int)
      use ip <- decode.field("ip", ip.ipv6_decoder())
      decode.success(AaaaRecord(name:, ttl:, ip:))
    }
    "cname_record" -> {
      use name <- decode.field("name", decode.string)
      use ttl <- decode.field("ttl", decode.int)
      use target <- decode.field("target", decode.string)
      decode.success(CnameRecord(name:, ttl:, target:))
    }
    _ ->
      decode.failure(
        ARecord(name: "", ttl: 0, ip: ip.Ipv4(0, 0, 0, 0)),
        "Record",
      )
  }
}

pub fn to_json(record: Record) -> json.Json {
  case record {
    ARecord(name:, ttl:, ip:) ->
      json.object([
        #("type", json.string("a_record")),
        #("name", json.string(name)),
        #("ttl", json.int(ttl)),
        #("ip", ip.ipv4_to_json(ip)),
      ])
    AaaaRecord(name:, ttl:, ip:) ->
      json.object([
        #("type", json.string("aaaa_record")),
        #("name", json.string(name)),
        #("ttl", json.int(ttl)),
        #("ip", ip.ipv6_to_json(ip)),
      ])
    CnameRecord(name:, ttl:, target:) ->
      json.object([
        #("type", json.string("cname_record")),
        #("name", json.string(name)),
        #("ttl", json.int(ttl)),
        #("target", json.string(target)),
      ])
  }
}
