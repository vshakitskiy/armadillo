import gleam/bool
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import server/dns/protocol as dns
import server/env
import shared/ip
import simplifile

pub type Zone {
  Zone(
    file_path: String,
    serial: Int,
    ttl: Int,
    soa_minimum: Int,
    records: List(ZoneRecord),
  )
}

pub type ZoneRecord {
  ARecord(name: String, ttl: Int, ip: ip.Address)
  AaaaRecord(name: String, ttl: Int, ip: ip.Address)
  CnameRecord(name: String, ttl: Int, target: String)
}

pub fn record_type(record: ZoneRecord) -> dns.Type {
  case record {
    ARecord(..) -> dns.A
    AaaaRecord(..) -> dns.Aaaa
    CnameRecord(..) -> dns.Cname
  }
}

pub type ReadError {
  IoError(simplifile.FileError)
  ParseError(String)
}

pub type ZoneError {
  RecordNotFound
  DuplicateRecord
}

pub fn read(path: String) -> Result(Zone, ReadError) {
  use content <- result.try(
    simplifile.read(from: path)
    |> result.map_error(IoError),
  )

  let ttl = env.get_or("DNS_TTL", parse: int.parse, or: 300, log: "300 seconds")
  let soa_minimum =
    env.get_or(
      "DNS_SOA_MINIMUM",
      parse: int.parse,
      or: 3600,
      log: "3600 seconds",
    )

  parse(
    content,
    Zone(file_path: path, serial: 0, ttl:, soa_minimum:, records: []),
  )
}

fn parse(data: String, zone: Zone) -> Result(Zone, ReadError) {
  case data {
    "" -> Ok(Zone(..zone, records: list.reverse(zone.records)))
    content -> {
      let #(line, remaining) = case string.split_once(content, "\n") {
        Ok(tuple) -> tuple
        Error(Nil) -> #(data, "")
      }

      case string.trim(line) {
        ";" <> _remaining | "$ORIGIN" <> _remaining | "" ->
          parse(remaining, zone)
        _ -> {
          let parts =
            case string.split_once(line, ";") {
              Ok(#(before, _after)) -> before
              Error(Nil) -> line
            }
            |> string.trim
            |> string.split(" ")
            |> list.filter(fn(x) { !string.is_empty(x) })

          case parts {
            ["$TTL", value] -> {
              case int.parse(value) {
                Ok(ttl) -> parse(remaining, Zone(..zone, ttl:))
                Error(Nil) -> Error(ParseError("invalid ttl specified"))
              }
            }

            [
              "@",
              "IN",
              "SOA",
              _ns,
              _email,
              serial,
              _refresh,
              _retry,
              _expire,
              soa_minimum,
            ] -> {
              case int.parse(serial), int.parse(soa_minimum) {
                Ok(serial), Ok(soa_minimum) ->
                  parse(remaining, Zone(..zone, serial:, soa_minimum:))
                Error(Nil), _ -> Error(ParseError("invalid serial specified"))
                _, Error(Nil) ->
                  Error(ParseError("invalid soa minimum specified"))
              }
            }

            [domain, "IN", type_, value] -> {
              use maybe <- result.try(case type_ {
                "A" ->
                  case ip.from_string(value) {
                    Ok(ip) ->
                      Ok(option.Some(ARecord(name: domain, ttl: zone.ttl, ip:)))
                    Error(Nil) -> Error(ParseError("invalid ip provided"))
                  }
                "AAAA" ->
                  case ip.from_string(value) {
                    Ok(ip) ->
                      Ok(
                        option.Some(AaaaRecord(name: domain, ttl: zone.ttl, ip:)),
                      )
                    Error(Nil) -> Error(ParseError("invalid ip provided"))
                  }
                "CNAME" ->
                  Ok(
                    option.Some(CnameRecord(
                      name: domain,
                      ttl: zone.ttl,
                      target: value,
                    )),
                  )
                _ -> Ok(option.None)
              })

              let records = case maybe {
                option.Some(record) -> [record, ..zone.records]
                option.None -> zone.records
              }
              parse(remaining, Zone(..zone, records:))
            }

            _ -> parse(remaining, zone)
          }
        }
      }
    }
  }
}

pub fn write(zone: Zone) -> Result(Nil, simplifile.FileError) {
  [
    "; Managed by armadillo - do not edit",
    "$TTL " <> int.to_string(zone.ttl),
    "@ IN SOA ns.armadillo. hostmaster.armadillo. "
      <> int.to_string(zone.serial)
      <> " 3600 900 604800 "
      <> int.to_string(zone.soa_minimum),
    ..list.map(zone.records, with: fn(record) {
      let line = record.name <> " IN "
      case record {
        ARecord(ip:, ..) ->
          line <> "A " <> ip.to_string(ip) |> result.unwrap("")
        AaaaRecord(ip:, ..) ->
          line <> "AAAA " <> ip.to_string(ip) |> result.unwrap("")
        CnameRecord(target:, ..) -> line <> "CNAME " <> target
      }
    })
  ]
  |> string.join("\n")
  |> simplifile.write(to: zone.file_path)
}

pub fn add(zone: Zone, record: ZoneRecord) -> Result(Zone, Nil) {
  let conflict =
    list.filter(zone.records, fn(current) { current.name == record.name })
    |> list.any(fn(current) {
      case record, current {
        CnameRecord(..), _ | _, CnameRecord(..) -> True
        ARecord(..), ARecord(..) | AaaaRecord(..), AaaaRecord(..) -> True
        _, _ -> False
      }
    })

  case conflict {
    True -> Error(Nil)
    False -> Ok(Zone(..zone, records: list.append(zone.records, [record])))
  }
}

pub fn update(zone: Zone, record: ZoneRecord) -> Result(Zone, Nil) {
  let #(found, records) =
    list.map_fold(zone.records, False, fn(found, current) {
      let check = case record, current {
        ARecord(..), ARecord(..)
        | AaaaRecord(..), AaaaRecord(..)
        | CnameRecord(..), CnameRecord(..)
        -> record.name == current.name
        _, _ -> False
      }

      case check {
        True -> #(True, record)
        False -> #(found, current)
      }
    })

  case found {
    False -> Error(Nil)
    True -> Ok(Zone(..zone, records:))
  }
}

pub fn delete(zone: Zone, name: String, type_: dns.Type) -> Zone {
  Zone(
    ..zone,
    records: list.filter(zone.records, fn(record) {
      case record, type_ {
        ARecord(..), dns.A
        | AaaaRecord(..), dns.Aaaa
        | CnameRecord(..), dns.Cname
        -> record.name == name
        _, _ -> False
      }
      |> bool.negate
    }),
  )
}
