import envoy
import ewe
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import logging
import server/cache
import server/env
import server/zone
import shared/records
import wisp
import wisp/wisp_ewe

pub fn supervised(zone: process.Subject(zone.Message)) {
  let secret_key_base =
    envoy.get("API_SECRET_KEY_BASE")
    |> result.lazy_unwrap(fn() {
      logging.log(
        logging.Warning,
        "No API_SECRET_KEY_BASE provided, using random value",
      )

      wisp.random_string(32)
    })
  let port = env.get_or("API_PORT", parse: int.parse, or: 3000, log: "3000")

  handler(_, Context(zone))
  |> wisp_ewe.handler(secret_key_base)
  |> ewe.new
  |> ewe.bind("0.0.0.0")
  |> ewe.listening(port:)
  |> ewe.on_start(fn(scheme, address) {
    let port = int.to_string(address.port)
    let address = case address.ip {
      ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(address.ip) <> "]"
      ewe.IpV4(..) -> ewe.ip_address_to_string(address.ip)
    }

    let url = http.scheme_to_string(scheme) <> "://" <> address <> ":" <> port
    logging.log(logging.Info, "UI listening on " <> url)
  })
  |> ewe.supervised
}

type Context {
  Context(zone: process.Subject(zone.Message))
}

fn handler(
  request: request.Request(wisp.Connection),
  context: Context,
) -> response.Response(wisp.Body) {
  let request = wisp.method_override(request)
  use <- wisp.rescue_crashes
  use request <- wisp.handle_head(request)
  use request <- wisp.csrf_known_header_protection(request)

  case request.method, wisp.path_segments(request) {
    http.Get, ["api", "domains"] -> {
      zone.get_records(context.zone)
      |> list.group(fn(record) { record.name })
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(name, records) = pair

        records.DomainGroup(
          name:,
          records: list.map(records, records.record_to_entry),
        )
      })
      |> json.array(of: records.domain_group_to_json)
      |> json.to_string
      |> wisp.json_response(200)
    }

    http.Post, ["api", "domains"] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, records.domain_group_decoder()) {
        Ok(group) -> {
          case zone.insert_domain(context.zone, group.name, group.records) {
            Ok(Nil) -> {
              list.each(group.records, fn(entry) {
                cache.set(records.entry_to_record(group.name, entry))
              })
              wisp.no_content()
            }
            Error(zone.Conflict) ->
              wisp.response(409)
              |> wisp.string_body("Domain already exists")
            Error(zone.CnameConflict) ->
              wisp.response(422)
              |> wisp.string_body("CNAME cannot coexist with A or AAAA records")
            Error(zone.WriteFailure(_)) ->
              wisp.response(503)
              |> wisp.string_body("Failed to write zone file")
            Error(zone.NotFound) -> panic as "unreachable!"
          }
        }
        Error(_) -> wisp.bad_request("Invalid body")
      }
    }

    http.Put, ["api", "domains", name] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, decode.list(of: records.record_entry_decoder())) {
        Ok(entries) -> {
          case zone.put_domain(context.zone, name, entries) {
            Ok(Nil) -> {
              cache.delete_domain(name)
              list.each(entries, fn(entry) {
                cache.set(records.entry_to_record(name, entry))
              })
              wisp.no_content()
            }
            Error(zone.CnameConflict) ->
              wisp.response(422)
              |> wisp.string_body("CNAME cannot coexist with A or AAAA records")
            Error(zone.WriteFailure(_)) ->
              wisp.response(503)
              |> wisp.string_body("Failed to write zone file")
            Error(zone.Conflict) -> panic as "unreachable!"
            Error(zone.NotFound) -> panic as "unreachable!"
          }
        }
        Error(_) -> wisp.bad_request("Invalid body")
      }
    }

    http.Delete, ["api", "domains", name] -> {
      case zone.delete_domain(context.zone, name) {
        Ok(Nil) -> {
          cache.delete_domain(name)
          wisp.no_content()
        }
        Error(zone.WriteFailure(_)) ->
          wisp.response(503)
          |> wisp.string_body("Failed to write zone file")
        Error(_) -> panic as "unreachable!"
      }
    }

    _, _ -> {
      case wisp.priv_directory("server") {
        Ok(priv) -> {
          use <- wisp.serve_static(request, under: "/", from: priv)
          wisp.not_found()
        }
        Error(Nil) -> wisp.internal_server_error()
      }
    }
  }
}
