import armadillo/shared/ip
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

pub type Record {
  ARecord(name: String, ttl: Int, ip: ip.Ipv4)
  AaaaRecord(name: String, ttl: Int, ip: ip.Ipv6)
  CnameRecord(name: String, ttl: Int, target: String)
}

pub type RecordEntry {
  AEntry(ttl: Int, ip: ip.Ipv4)
  AaaaEntry(ttl: Int, ip: ip.Ipv6)
  CnameEntry(ttl: Int, target: String)
}

pub type DomainGroup {
  DomainGroup(name: String, records: List(RecordEntry))
}

pub fn to_entry(record: Record) -> RecordEntry {
  case record {
    ARecord(ttl:, ip:, ..) -> AEntry(ttl:, ip:)
    AaaaRecord(ttl:, ip:, ..) -> AaaaEntry(ttl:, ip:)
    CnameRecord(ttl:, target:, ..) -> CnameEntry(ttl:, target:)
  }
}

pub fn from_entry(entry: RecordEntry, name: String) -> Record {
  case entry {
    AEntry(ttl:, ip:) -> ARecord(name:, ttl:, ip:)
    AaaaEntry(ttl:, ip:) -> AaaaRecord(name:, ttl:, ip:)
    CnameEntry(ttl:, target:) -> CnameRecord(name:, ttl:, target:)
  }
}

pub fn entry_to_json(entry: RecordEntry) -> json.Json {
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
    #("records", json.array(group.records, entry_to_json)),
  ])
}

pub fn entry_decoder() -> decode.Decoder(RecordEntry) {
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
    _unknown_variant ->
      decode.failure(AEntry(ttl: 0, ip: ip.Ipv4(0, 0, 0, 0)), "RecordEntry")
  }
}

pub fn domain_group_decoder() -> decode.Decoder(DomainGroup) {
  use name <- decode.field("name", decode.string)
  use entries <- decode.field("records", decode.list(of: entry_decoder()))

  decode.success(DomainGroup(name:, records: entries))
}

pub type RecordType {
  A
  Aaaa
  Cname
}

pub type NameError {
  BlankName
  ZoneDirective
  InvalidNameCharacters
  InvalidNameLength
}

pub type ValidationError {
  InvalidName(NameError)
  InvalidTarget(NameError)
  InvalidTtl(Int)
  InvalidAddress
}

pub fn describe_name_error(error: NameError) -> String {
  case error {
    BlankName -> "must not be blank"
    ZoneDirective -> "must be a domain name and not a zone directive"
    InvalidNameCharacters ->
      "must not contain whitespace, control characters or zone syntax"
    InvalidNameLength ->
      "must have labels of 1 to 63 bytes and at most 255 bytes on the wire"
  }
}

pub fn describe_validation_error(error: ValidationError) -> String {
  case error {
    InvalidName(reason) -> "Domain name " <> describe_name_error(reason)
    InvalidTarget(reason) -> "CNAME target " <> describe_name_error(reason)
    InvalidTtl(_ttl) -> "TTL must be between 0 and 2147483647 seconds"
    InvalidAddress -> "IP address contains an out-of-range component"
  }
}

pub fn validate_name(name: String) -> Result(Nil, NameError) {
  case name {
    "" -> Error(BlankName)
    "." -> Ok(Nil)
    "@" | "$" <> _directive -> Error(ZoneDirective)
    _name -> {
      let bytes = bit_array.from_string(name)
      let max_length = case string.ends_with(name, ".") {
        True -> 254
        False -> 253
      }

      case bit_array.byte_size(bytes) <= max_length {
        True -> validate_name_bytes(bytes, 0)
        False -> Error(InvalidNameLength)
      }
    }
  }
}

fn validate_name_bytes(
  bytes: BitArray,
  label_length: Int,
) -> Result(Nil, NameError) {
  case bytes {
    <<>> if label_length > 0 -> Ok(Nil)
    <<".">> if label_length > 0 -> Ok(Nil)
    <<".", remaining:bits>> if label_length > 0 ->
      validate_name_bytes(remaining, 0)
    <<".", _remaining:bits>> -> Error(InvalidNameLength)
    <<byte, _remaining:bits>> if byte <= 32 || byte == 127 ->
      Error(InvalidNameCharacters)
    <<"\"", _remaining:bits>>
    | <<"(", _remaining:bits>>
    | <<")", _remaining:bits>>
    | <<";", _remaining:bits>>
    | <<"\\", _remaining:bits>>
    | <<"\u{0085}", _remaining:bits>>
    | <<"\u{2028}", _remaining:bits>>
    | <<"\u{2029}", _remaining:bits>> -> Error(InvalidNameCharacters)
    <<_byte, remaining:bits>> if label_length < 63 ->
      validate_name_bytes(remaining, label_length + 1)
    _invalid_length -> Error(InvalidNameLength)
  }
}

pub fn validate_ttl(ttl: Int) -> Result(Nil, ValidationError) {
  case ttl >= 0 && ttl <= 2_147_483_647 {
    True -> Ok(Nil)
    False -> Error(InvalidTtl(ttl))
  }
}

pub fn validate(record: Record) -> Result(Nil, ValidationError) {
  use _name <- result.try(
    validate_name(record.name) |> result.map_error(InvalidName),
  )
  use _ttl <- result.try(validate_ttl(record.ttl))

  case record {
    ARecord(ip:, ..) -> validate_address(ip.ipv4_is_valid(ip))
    AaaaRecord(ip:, ..) -> validate_address(ip.ipv6_is_valid(ip))
    CnameRecord(target:, ..) ->
      validate_name(target) |> result.map_error(InvalidTarget)
  }
}

pub fn entry_type(entry: RecordEntry) -> RecordType {
  case entry {
    AEntry(..) -> A
    AaaaEntry(..) -> Aaaa
    CnameEntry(..) -> Cname
  }
}

fn validate_address(valid: Bool) -> Result(Nil, ValidationError) {
  case valid {
    True -> Ok(Nil)
    False -> Error(InvalidAddress)
  }
}

pub fn normalize_name(name: String) -> String {
  normalize_name_bytes(bit_array.from_string(name), <<>>)
  |> bit_array.to_string
  |> result.unwrap(name)
}

fn normalize_name_bytes(bytes: BitArray, normalized: BitArray) -> BitArray {
  case bytes {
    <<>> | <<".">> -> {
      case normalized {
        <<>> -> <<".">>
        _name -> normalized
      }
    }
    <<byte, rest:bits>> -> {
      let byte = case byte {
        upper if upper >= 65 && upper <= 90 -> upper + 32
        other -> other
      }

      normalize_name_bytes(rest, <<normalized:bits, byte:8>>)
    }
    _invalid_bytes -> normalized
  }
}

pub fn normalize(record: Record) -> Record {
  let name = normalize_name(record.name)

  case record {
    ARecord(..) -> ARecord(..record, name:)
    AaaaRecord(..) -> AaaaRecord(..record, name:)
    CnameRecord(target:, ..) ->
      CnameRecord(..record, name:, target: normalize_name(target))
  }
}
