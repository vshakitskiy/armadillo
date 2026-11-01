import armadillo/server/cache
import armadillo/server/env
import armadillo/shared/ip
import armadillo/shared/record
import filepath
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import simplifile

pub type Message {
  GetRecords(reply_to: process.Subject(List(record.Record)))
  InsertDomain(
    reply_to: process.Subject(Result(Nil, ZoneError)),
    name: String,
    entries: List(record.RecordEntry),
  )
  PutDomain(
    reply_to: process.Subject(Result(Nil, ZoneError)),
    name: String,
    entries: List(record.RecordEntry),
  )
  DeleteDomain(reply_to: process.Subject(Result(Nil, ZoneError)), name: String)
}

pub type ZoneError {
  Conflict
  CnameConflict
  WriteFailure(simplifile.FileError)
  InvalidRecord(name: String, reason: record.ValidationError)
}

pub fn worker(
  name: process.Name(Message),
  path: String,
  default_ttl: Int,
) -> supervision.ChildSpecification(process.Subject(Message)) {
  let builder =
    actor.new_with_initialiser(5000, fn(self) {
      let zone = case read(path, default_ttl) {
        Ok(zone) -> zone
        Error(IoError(simplifile.Enoent)) -> {
          logging.log(
            logging.Warning,
            "Zone file not found at " <> path <> ", creating default",
          )

          write_default_zone(path, default_ttl)
        }
        Error(error) -> {
          let reason = case error {
            ParseError(message) -> "parse error: " <> message
            IoError(error) -> "io error: " <> simplifile.describe_error(error)
          }
          let backup = backup_path(path)
          logging.log(
            logging.Warning,
            "Zone file unreadable (" <> reason <> "), backing up to " <> backup,
          )
          let assert Ok(Nil) = simplifile.rename(at: path, to: backup)
            as "back up is not possible!"

          write_default_zone(path, default_ttl)
        }
      }

      list.each(zone.records, fn(local_record) {
        case record.validate(local_record) {
          Ok(Nil) -> Nil
          Error(reason) ->
            logging.log(
              logging.Warning,
              "Preserving invalid zone record for "
                <> local_record.name
                <> ": "
                <> record.describe_validation_error(reason),
            )
        }
      })

      cache.replace_local(zone.records)

      actor.initialised(zone)
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.named(name)

  supervision.worker(fn() { actor.start(builder) })
}

fn write_default_zone(path: String, default_ttl: Int) -> Zone {
  let soa_minimum =
    env.get_or(
      "DNS_SOA_MINIMUM",
      parse: int.parse,
      or: 3600,
      log: "3600 seconds",
    )

  let zone =
    Zone(
      file_path: path,
      serial: next_serial(0),
      ttl: default_ttl,
      soa_minimum:,
      records: [],
    )

  let directory = filepath.directory_name(path)
  let _created_directory = simplifile.create_directory_all(directory)
  let assert Ok(Nil) = write(zone)
    as "writing to zone file path is not possible!"

  zone
}

fn backup_path(path: String) -> String {
  let #(year, month, day) = erlang_date()

  path
  <> "."
  <> int.to_string(year)
  <> string.pad_start(int.to_string(month), 2, "0")
  <> string.pad_start(int.to_string(day), 2, "0")
  <> ".bak"
}

pub fn get_records(subject: process.Subject(Message)) -> List(record.Record) {
  process.call(subject, waiting: 10_000, sending: GetRecords)
}

pub fn insert_domain(
  subject: process.Subject(Message),
  name: String,
  entries: List(record.RecordEntry),
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: InsertDomain(_, name, entries))
}

pub fn put_domain(
  subject: process.Subject(Message),
  name: String,
  entries: List(record.RecordEntry),
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: PutDomain(_, name, entries))
}

pub fn delete_domain(
  subject: process.Subject(Message),
  name: String,
) -> Result(Nil, ZoneError) {
  process.call(subject, waiting: 10_000, sending: DeleteDomain(_, name))
}

fn handle_message(zone: Zone, message: Message) -> actor.Next(Zone, Message) {
  case message {
    GetRecords(reply_to:) -> {
      process.send(reply_to, zone.records)
      actor.continue(zone)
    }
    InsertDomain(reply_to:, name:, entries:) -> {
      let normalized = record.normalize_name(name)

      case
        list.any(zone.records, fn(local_record) {
          local_record.name == normalized
        })
      {
        True -> {
          process.send(reply_to, Error(Conflict))
          actor.continue(zone)
        }
        False -> apply_domain_put(zone, reply_to, name, entries)
      }
    }
    PutDomain(reply_to:, name:, entries:) ->
      apply_domain_put(zone, reply_to, name, entries)
    DeleteDomain(reply_to:, name:) -> commit_domain(zone, name, [], reply_to)
  }
}

fn apply_domain_put(
  zone: Zone,
  reply_to: process.Subject(Result(Nil, ZoneError)),
  name: String,
  entries: List(record.RecordEntry),
) -> actor.Next(Zone, Message) {
  let has_cname =
    list.any(entries, fn(entry) { record.entry_type(entry) == record.Cname })

  case has_cname && list.length(entries) != 1 {
    True -> {
      process.send(reply_to, Error(CnameConflict))
      actor.continue(zone)
    }
    False -> commit_domain(zone, name, entries, reply_to)
  }
}

fn commit_domain(
  zone: Zone,
  name: String,
  entries: List(record.RecordEntry),
  reply_to: process.Subject(Result(Nil, ZoneError)),
) -> actor.Next(Zone, Message) {
  let domain_records = list.map(entries, record.from_entry(_, name))

  let committed = {
    use _validated <- result.try(
      list.try_each(domain_records, fn(local_record) {
        record.validate(local_record)
        |> result.map_error(InvalidRecord(name, _))
      }),
    )

    let domain_records = list.map(domain_records, record.normalize)
    let name = record.normalize_name(name)
    let retained_records =
      list.filter(zone.records, fn(local_record) { local_record.name != name })

    let updated =
      Zone(
        ..zone,
        serial: next_serial(zone.serial),
        records: list.append(retained_records, domain_records),
      )

    use _written <- result.try(write(updated) |> result.map_error(WriteFailure))

    Ok(#(updated, domain_records))
  }

  case committed {
    Ok(#(updated, domain_records)) -> {
      cache.replace_domain(name, domain_records)

      process.send(reply_to, Ok(Nil))
      actor.continue(updated)
    }
    Error(error) -> {
      process.send(reply_to, Error(error))
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
    records: List(record.Record),
  )
}

const serial_modulus = 4_294_967_296

const serial_half_range = 2_147_483_648

fn next_serial(current: Int) -> Int {
  let #(year, month, day) = erlang_date()
  let date_serial = { year * 10_000 + month * 100 + day } * 100

  advance_serial(current, date_serial)
}

fn advance_serial(current: Int, date_serial: Int) -> Int {
  let current = int.bitwise_and(current, 0xFFFFFFFF)
  let date_serial = int.bitwise_and(date_serial, 0xFFFFFFFF)
  let distance = { date_serial - current + serial_modulus } % serial_modulus

  case distance > 0 && distance < serial_half_range {
    True -> date_serial
    False -> { current + 1 } % serial_modulus
  }
}

@external(erlang, "erlang", "date")
fn erlang_date() -> #(Int, Int, Int)

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
  |> result.map(fn(zone) {
    Zone(..zone, records: list.map(zone.records, record.normalize))
  })
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
        _record_line -> {
          let parts =
            case string.split_once(line, ";") {
              Ok(#(before, _after)) -> before
              Error(Nil) -> line
            }
            |> string.trim
            |> string.split(" ")
            |> list.filter(fn(part) { !string.is_empty(part) })

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
                Error(Nil), _minimum ->
                  Error(ParseError("invalid serial specified"))
                _serial, Error(Nil) ->
                  Error(ParseError("invalid soa minimum specified"))
              }
            }

            [domain, ttl, "IN", type_, value] -> {
              case int.parse(ttl) {
                Ok(ttl) -> {
                  use parsed_record <- result.try(parse_record(
                    domain,
                    ttl,
                    type_,
                    value,
                  ))

                  let records = case parsed_record {
                    option.Some(local_record) -> [local_record, ..zone.records]
                    option.None -> zone.records
                  }

                  parse(remaining, Zone(..zone, records:))
                }
                Error(Nil) -> Error(ParseError("invalid record ttl specified"))
              }
            }

            [domain, "IN", type_, value] -> {
              use parsed_record <- result.try(parse_record(
                domain,
                zone.ttl,
                type_,
                value,
              ))

              let records = case parsed_record {
                option.Some(local_record) -> [local_record, ..zone.records]
                option.None -> zone.records
              }

              parse(remaining, Zone(..zone, records:))
            }

            _unsupported_line -> parse(remaining, zone)
          }
        }
      }
    }
  }
}

pub fn parse_record(
  domain: String,
  ttl: Int,
  type_: String,
  value: String,
) -> Result(option.Option(record.Record), ReadError) {
  case type_ {
    "A" ->
      case ip.ipv4_from_string(value) {
        Ok(ip) -> Ok(option.Some(record.ARecord(name: domain, ttl:, ip:)))
        Error(Nil) -> Error(ParseError("invalid ip provided"))
      }
    "AAAA" ->
      case ip.ipv6_from_string(value) {
        Ok(ip) -> Ok(option.Some(record.AaaaRecord(name: domain, ttl:, ip:)))
        Error(Nil) -> Error(ParseError("invalid ip provided"))
      }
    "CNAME" ->
      Ok(option.Some(record.CnameRecord(name: domain, ttl:, target: value)))
    _unsupported_type -> Ok(option.None)
  }
}

fn write(zone: Zone) -> Result(Nil, simplifile.FileError) {
  let content =
    [
      "; Managed by armadillo - do not edit",
      "$TTL " <> int.to_string(zone.ttl),
      "@ IN SOA ns.armadillo. hostmaster.armadillo. "
        <> int.to_string(zone.serial)
        <> " 3600 900 604800 "
        <> int.to_string(zone.soa_minimum),
      ..list.map(zone.records, with: fn(local_record) {
        let prefix = case local_record.ttl == zone.ttl {
          True -> local_record.name <> " IN "
          False ->
            local_record.name
            <> " "
            <> int.to_string(local_record.ttl)
            <> " IN "
        }

        case local_record {
          record.ARecord(ip:, ..) -> prefix <> "A " <> ip.ipv4_to_string(ip)
          record.AaaaRecord(ip:, ..) ->
            prefix <> "AAAA " <> ip.ipv6_to_string(ip)
          record.CnameRecord(target:, ..) -> prefix <> "CNAME " <> target
        }
      })
    ]
    |> string.join("\n")

  let temporary_path = zone.file_path <> ".tmp"
  let written = {
    use _created <- result.try(simplifile.write(
      to: temporary_path,
      contents: "",
    ))
    use _permissions <- result.try(copy_permissions(
      zone.file_path,
      temporary_path,
    ))
    use _written <- result.try(simplifile.write(
      to: temporary_path,
      contents: content,
    ))
    simplifile.rename(at: temporary_path, to: zone.file_path)
  }

  case written {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> {
      let _deleted = simplifile.delete_file(temporary_path)
      Error(error)
    }
  }
}

fn copy_permissions(
  from: String,
  to: String,
) -> Result(Nil, simplifile.FileError) {
  case simplifile.file_info(from) {
    Ok(info) ->
      simplifile.set_permissions_octal(
        to,
        simplifile.file_info_permissions_octal(info),
      )
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}
