import envoy
import ewe
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/result
import logging
import server/cache
import server/dns/protocol as dns
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
  use <- wisp.rescue_crashes

  case request.method, wisp.path_segments(request) {
    http.Get, ["api", "records"] -> {
      zone.get_records(context.zone)
      |> json.array(of: records.record_to_json)
      |> json.to_string
      |> wisp.json_response(200)
    }

    http.Post, ["api", "records"] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, records.record_decoder()) {
        Ok(record) -> {
          case zone.insert_record(context.zone, record) {
            Ok(Nil) -> {
              cache.set(record)
              wisp.no_content()
            }
            Error(zone.Conflict) ->
              wisp.response(409)
              |> wisp.string_body(
                "Incomming record conflicting with current records",
              )
            Error(zone.WriteFailure(_)) -> wisp.internal_server_error()
            Error(zone.NotFound) -> panic as "unreachable!"
          }
        }
        Error(_errors) -> wisp.bad_request("Invalid body")
      }
    }

    http.Patch, ["api", "records"] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, records.record_decoder()) {
        Ok(record) -> {
          case zone.update_record(context.zone, record) {
            Ok(Nil) -> {
              cache.set(record)
              wisp.no_content()
            }
            Error(zone.WriteFailure(_)) -> wisp.internal_server_error()
            Error(zone.NotFound) ->
              wisp.not_found()
              |> wisp.string_body("Record not found")
            Error(zone.Conflict) -> panic as "unreachable!"
          }
        }
        Error(_errors) -> wisp.bad_request("Invalid body")
      }
    }

    http.Delete, ["api", "records"] -> {
      use json <- wisp.require_json(request)

      let decoder = {
        use name <- decode.field("name", decode.string)
        use type_ <- decode.field("type", records.type_decoder())

        decode.success(#(name, type_))
      }

      case decode.run(json, decoder) {
        Ok(#(name, type_)) -> {
          let type_ = dns.from_record_type(type_)

          case zone.delete_record(context.zone, name, type_) {
            Ok(Nil) -> {
              cache.delete(name, type_)
              wisp.no_content()
            }
            Error(zone.WriteFailure(_)) -> wisp.internal_server_error()
            Error(zone.Conflict) | Error(zone.NotFound) ->
              panic as "unreachable!"
          }
        }
        Error(_errors) -> wisp.bad_request("Invalid body")
      }
    }

    _, _ -> {
      let assert Ok(priv) = wisp.priv_directory("server")

      wisp.serve_static(request, under: "/", from: priv, next: fn() {
        wisp.not_found()
      })
    }
  }
}
