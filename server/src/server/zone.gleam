import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import server/dns/protocol as dns
import server/env
import shared/ip
import shared/records
import simplifile

pub type Message {
  GetRecords(reply_to: process.Subject(List(records.Record)))
  InsertRecord(
    reply_to: process.Subject(Result(Nil, ZoneError)),
    record: records.Record,
  )
  UpdateRecord(
    reply_to: process.Subject(Result(Nil, ZoneError)),
    record: records.Record,
  )
  DeleteRecord(
    reply_to: process.Subject(Result(Nil, ZoneError)),
    name: String,
    type_: dns.Type,
  )
}

pub type ZoneError {
  Conflict
  NotFound
  WriteFailure(simplifile.FileError)
}

pub fn worker(name: process.Name(Message), path: String, default_ttl: Int) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      // todo: figure out recovery
      let assert Ok(zone) = read(path, default_ttl)

      actor.initialised(zone)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.named(name)

  supervision.worker(fn() { actor.start(builder) })
}

pub fn get_records(subject: process.Subject(Message)) -> List(records.Record) {
  process.call(subject, waiting: 10_000, sending: GetRecords)
}

pub fn insert_record(
  subject: process.Subject(Message),
  record: records.Record,
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: InsertRecord(_, record))
}

pub fn update_record(
  subject: process.Subject(Message),
  record: records.Record,
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: UpdateRecord(_, record))
}

pub fn delete_record(
  subject: process.Subject(Message),
  name: String,
  type_: dns.Type,
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: DeleteRecord(_, name, type_))
}

fn handle_message(zone: Zone, message: Message) {
  case message {
    GetRecords(reply_to:) -> {
      process.send(reply_to, zone.records)
      actor.continue(zone)
    }

    InsertRecord(reply_to:, record:) -> {
      let conflict =
        list.filter(zone.records, fn(current) { current.name == record.name })
        |> list.any(fn(current) {
          case record, current {
            records.CnameRecord(..), _ | _, records.CnameRecord(..) -> True
            records.ARecord(..), records.ARecord(..)
            | records.AaaaRecord(..), records.AaaaRecord(..)
            -> True
            _, _ -> False
          }
        })

      case conflict {
        True -> {
          process.send(reply_to, Error(Conflict))
          actor.continue(zone)
        }
        False -> {
          let zone =
            Zone(
              ..zone,
              serial: next_serial(zone.serial),
              records: list.append(zone.records, [record]),
            )
          handle_write(zone, reply_to)
        }
      }
    }

    UpdateRecord(reply_to:, record:) -> {
      let #(found, records) =
        list.map_fold(zone.records, False, fn(found, current) {
          let check = case record, current {
            records.ARecord(..), records.ARecord(..)
            | records.AaaaRecord(..), records.AaaaRecord(..)
            | records.CnameRecord(..), records.CnameRecord(..)
            -> record.name == current.name
            _, _ -> False
          }

          case check {
            True -> #(True, record)
            False -> #(found, current)
          }
        })

      case found {
        True -> {
          let zone = Zone(..zone, serial: next_serial(zone.serial), records:)
          handle_write(zone, reply_to)
        }
        False -> {
          process.send(reply_to, Error(NotFound))
          actor.continue(zone)
        }
      }
    }

    DeleteRecord(name:, type_:, reply_to:) -> {
      let records =
        list.filter(zone.records, fn(record) {
          case record, type_ {
            records.ARecord(..), dns.A
            | records.AaaaRecord(..), dns.Aaaa
            | records.CnameRecord(..), dns.Cname
            -> record.name == name
            _, _ -> False
          }
          |> bool.negate
        })

      let zone = Zone(..zone, serial: next_serial(zone.serial), records:)
      handle_write(zone, reply_to)
    }
  }
}

fn handle_write(zone: Zone, reply_to: process.Subject(Result(Nil, ZoneError))) {
  case write(zone) {
    Ok(Nil) -> {
      process.send(reply_to, Ok(Nil))
      actor.continue(zone)
    }
    Error(error) -> {
      process.send(reply_to, Error(WriteFailure(error)))
      actor.continue(zone)
    }
  }
}

pub type Zone {
  Zone(
    file_path: String,
    serial: Int,
    ttl: Int,
    soa_minimum: Int,
    records: List(records.Record),
  )
}

fn next_serial(current: Int) -> Int {
  let #(y, m, d) = erlang_date()

  let today_base = { y * 10_000 + m * 100 + d } * 100
  case current >= today_base && current < today_base + 100 {
    True -> current + 1
    False -> today_base
  }
}

@external(erlang, "erlang", "date")
fn erlang_date() -> #(Int, Int, Int)

pub fn record_type(record: records.Record) -> dns.Type {
  case record {
    records.ARecord(..) -> dns.A
    records.AaaaRecord(..) -> dns.Aaaa
    records.CnameRecord(..) -> dns.Cname
  }
}

pub type ReadError {
  IoError(simplifile.FileError)
  ParseError(String)
}

pub fn read(path: String, default_ttl: Int) -> Result(Zone, ReadError) {
  use content <- result.try(
    simplifile.read(from: path)
    |> result.map_error(IoError),
  )

  let soa_minimum =
    env.get_or(
      "DNS_SOA_MINIMUM",
      parse: int.parse,
      or: 3600,
      log: "3600 seconds",
    )

  parse(
    content,
    Zone(
      file_path: path,
      serial: 0,
      ttl: default_ttl,
      soa_minimum:,
      records: [],
    ),
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

            [domain, ttl, "IN", type_, value] -> {
              case int.parse(ttl) {
                Ok(ttl) -> {
                  use maybe <- result.try(parse_record(
                    domain,
                    ttl,
                    type_,
                    value,
                  ))

                  let records = case maybe {
                    option.Some(record) -> [record, ..zone.records]
                    option.None -> zone.records
                  }
                  parse(remaining, Zone(..zone, records:))
                }
                Error(Nil) -> Error(ParseError("invalid record ttl specified"))
              }
            }

            [domain, "IN", type_, value] -> {
              use maybe <- result.try(parse_record(
                domain,
                zone.ttl,
                type_,
                value,
              ))

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

pub fn parse_record(domain: String, ttl: Int, type_: String, value: String) {
  case type_ {
    "A" ->
      case ip.ipv4_from_string(value) {
        Ok(ip) -> Ok(option.Some(records.ARecord(name: domain, ttl:, ip:)))
        Error(Nil) -> Error(ParseError("invalid ip provided"))
      }
    "AAAA" ->
      case ip.ipv6_from_string(value) {
        Ok(ip) -> Ok(option.Some(records.AaaaRecord(name: domain, ttl:, ip:)))
        Error(Nil) -> Error(ParseError("invalid ip provided"))
      }
    "CNAME" ->
      Ok(option.Some(records.CnameRecord(name: domain, ttl:, target: value)))
    _ -> Ok(option.None)
  }
}

fn write(zone: Zone) -> Result(Nil, simplifile.FileError) {
  [
    "; Managed by armadillo - do not edit",
    "$TTL " <> int.to_string(zone.ttl),
    "@ IN SOA ns.armadillo. hostmaster.armadillo. "
      <> int.to_string(zone.serial)
      <> " 3600 900 604800 "
      <> int.to_string(zone.soa_minimum),
    ..list.map(zone.records, with: fn(record) {
      let prefix = case record.ttl == zone.ttl {
        True -> record.name <> " IN "
        False -> record.name <> " " <> int.to_string(record.ttl) <> " IN "
      }
      case record {
        records.ARecord(ip:, ..) -> prefix <> "A " <> ip.ipv4_to_string(ip)
        records.AaaaRecord(ip:, ..) ->
          prefix <> "AAAA " <> ip.ipv6_to_string(ip)
        records.CnameRecord(target:, ..) -> prefix <> "CNAME " <> target
      }
    })
  ]
  |> string.join("\n")
  |> simplifile.write(to: zone.file_path)
}
