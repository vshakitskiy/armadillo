import armadillo/shared/ip
import gleam/dynamic/decode
import gleam/json

pub type Record {
  ARecord(name: String, ttl: Int, ip: ip.Ipv4)
  AaaaRecord(name: String, ttl: Int, ip: ip.Ipv6)
  CnameRecord(name: String, ttl: Int, target: String)
}

pub fn record_decoder() -> decode.Decoder(Record) {
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

pub fn record_to_json(record: Record) -> json.Json {
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

pub type RecordEntry {
  AEntry(ttl: Int, ip: ip.Ipv4)
  AaaaEntry(ttl: Int, ip: ip.Ipv6)
  CnameEntry(ttl: Int, target: String)
}

pub type DomainGroup {
  DomainGroup(name: String, records: List(RecordEntry))
}

pub fn record_to_entry(record: Record) -> RecordEntry {
  case record {
    ARecord(ttl:, ip:, ..) -> AEntry(ttl:, ip:)
    AaaaRecord(ttl:, ip:, ..) -> AaaaEntry(ttl:, ip:)
    CnameRecord(ttl:, target:, ..) -> CnameEntry(ttl:, target:)
  }
}

pub fn entry_to_record(name: String, entry: RecordEntry) -> Record {
  case entry {
    AEntry(ttl:, ip:) -> ARecord(name:, ttl:, ip:)
    AaaaEntry(ttl:, ip:) -> AaaaRecord(name:, ttl:, ip:)
    CnameEntry(ttl:, target:) -> CnameRecord(name:, ttl:, target:)
  }
}

pub fn record_entry_to_json(entry: RecordEntry) -> json.Json {
  case entry {
    AEntry(ttl:, ip:) ->
      json.object([
        #("type", json.string("a")),
        #("ttl", json.int(ttl)),
        #("ip", ip.ipv4_to_json(ip)),
      ])
    AaaaEntry(ttl:, ip:) ->
      json.object([
        #("type", json.string("aaaa")),
        #("ttl", json.int(ttl)),
        #("ip", ip.ipv6_to_json(ip)),
      ])
    CnameEntry(ttl:, target:) ->
      json.object([
        #("type", json.string("cname")),
        #("ttl", json.int(ttl)),
        #("target", json.string(target)),
      ])
  }
}

pub fn domain_group_to_json(group: DomainGroup) -> json.Json {
  json.object([
    #("name", json.string(group.name)),
    #("records", json.array(group.records, record_entry_to_json)),
  ])
}

pub fn record_entry_decoder() -> decode.Decoder(RecordEntry) {
  use variant <- decode.field("type", decode.string)
  case variant {
    "a" -> {
      use ttl <- decode.field("ttl", decode.int)
      use ip <- decode.field("ip", ip.ipv4_decoder())
      decode.success(AEntry(ttl:, ip:))
    }
    "aaaa" -> {
      use ttl <- decode.field("ttl", decode.int)
      use ip <- decode.field("ip", ip.ipv6_decoder())
      decode.success(AaaaEntry(ttl:, ip:))
    }
    "cname" -> {
      use ttl <- decode.field("ttl", decode.int)
      use target <- decode.field("target", decode.string)
      decode.success(CnameEntry(ttl:, target:))
    }
    _ -> decode.failure(AEntry(ttl: 0, ip: ip.Ipv4(0, 0, 0, 0)), "RecordEntry")
  }
}

pub fn domain_group_decoder() -> decode.Decoder(DomainGroup) {
  use name <- decode.field("name", decode.string)
  use records <- decode.field(
    "records",
    decode.list(of: record_entry_decoder()),
  )
  decode.success(DomainGroup(name:, records:))
}

pub type RecordType {
  A
  Aaaa
  Cname
}

pub fn type_decoder() -> decode.Decoder(RecordType) {
  use variant <- decode.then(decode.string)
  case variant {
    "a" -> decode.success(A)
    "aaaa" -> decode.success(Aaaa)
    "cname" -> decode.success(Cname)
    _ -> decode.failure(A, "RecordType")
  }
}

pub fn record_type_to_json(record_type: RecordType) -> json.Json {
  case record_type {
    A -> json.string("a")
    Aaaa -> json.string("aaaa")
    Cname -> json.string("cname")
  }
}
