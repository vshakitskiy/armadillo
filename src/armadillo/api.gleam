import armadillo/cache
import armadillo/dns/protocol as dns
import armadillo/env
import armadillo/ip
import armadillo/sql
import ewe
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import sqlight
import wisp
import wisp/wisp_ewe

pub fn supervised(conn: sqlight.Connection) {
  let secret_key_base =
    env.get_string_or("API_SECRET_KEY_BASE", or: wisp.random_string(32))

  let context = Context(conn)

  handler(_, context)
  |> wisp_ewe.handler(secret_key_base)
  |> ewe.new
  |> ewe.bind("0.0.0.0")
  |> ewe.listening(port: env.get_int_or("API_PORT", or: 3000))
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
          json.array(records, of: sql.record_to_json)
          |> json.to_string
          |> wisp.json_response(200)
        Error(_error) -> wisp.internal_server_error()
      }

    http.Post, ["api", "records"] -> {
      use form_data <- wisp.require_form(request)

      case form_data.values {
        [#("domain", domain), #("ip", string_ip)]
        | [#("ip", string_ip), #("domain", domain)] -> {
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
        _ -> wisp.bad_request("Invalid form data")
      }
    }

    http.Put, ["api", "records", domain] -> {
      use form_data <- wisp.require_form(request)

      case form_data.values {
        [#("ip", string_ip)] -> {
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
        _ -> wisp.bad_request("Invalid form data")
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
