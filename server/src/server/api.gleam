import envoy
import ewe
import gleam/dynamic/decode
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
import server/sql
import shared/ip
import shared/records
import sqlight
import wisp
import wisp/wisp_ewe

pub fn supervised(conn: sqlight.Connection) {
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

  handler(_, Context(conn))
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
  Context(conn: sqlight.Connection)
}

fn handler(
  request: request.Request(wisp.Connection),
  context: Context,
) -> response.Response(wisp.Body) {
  use <- wisp.rescue_crashes

  case request.method, wisp.path_segments(request) {
    http.Get, ["api", "records"] ->
      case sql.get_records(context.conn) {
        Ok(records) ->
          json.array(records, of: records.to_json)
          |> json.to_string
          |> wisp.json_response(200)
        Error(_error) -> wisp.internal_server_error()
      }

    http.Post, ["api", "records"] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, records.json_decoder()) {
        Ok(records.Record(domain:, ip: string_ip)) -> {
          case ip.from_string(string_ip) {
            Ok(parsed_ip) -> {
              case sql.insert_record(context.conn, domain, string_ip) {
                Ok(Nil) -> {
                  cache.set_permanent(domain, dns.A, parsed_ip)
                  wisp.no_content()
                }
                Error(sqlight.SqlightError(code: sqlight.ConstraintUnique, ..)) ->
                  wisp.bad_request("Record already exists")
                Error(_error) -> wisp.internal_server_error()
              }
            }
            Error(Nil) -> wisp.bad_request("Invalid ip value")
          }
        }
        Error(_) -> wisp.bad_request("Invalid form data")
      }
    }

    http.Patch, ["api", "records", domain] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, decode.string) {
        Ok(string_ip) -> {
          case ip.from_string(string_ip) {
            Ok(parsed_ip) -> {
              case sql.update_record(context.conn, domain, string_ip) {
                Ok(Nil) -> {
                  cache.set_permanent(domain, dns.A, parsed_ip)
                  wisp.no_content()
                }
                Error(_error) -> wisp.internal_server_error()
              }
            }
            Error(Nil) -> wisp.bad_request("Invalid ip value")
          }
        }
        Error(_) -> wisp.bad_request("Invalid form data")
      }
    }

    http.Delete, ["api", "records", domain] -> {
      case sql.delete_record(context.conn, domain) {
        Ok(Nil) -> {
          cache.delete(domain, dns.A)
          wisp.no_content()
        }
        Error(_error) -> wisp.internal_server_error()
      }
    }

    _, _ -> wisp.not_found()
  }
}
