import armadillo/server/env
import armadillo/server/zone
import armadillo/shared/record
import armadillo/wisp/wisp_ewe
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
import gleam/otp/supervision
import gleam/result
import gleam/uri
import logging
import simplifile
import wisp

pub fn supervised(
  zone: process.Subject(zone.Message),
) -> supervision.ChildSpecification(ewe.SocketAddress) {
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
  |> ewe.listening(on: port)
  |> ewe.on_start(fn(scheme, address) {
    let assert ewe.TcpSocketAddress(ip_address:, port:) = address
    let port = int.to_string(port)
    let address = case ip_address {
      ewe.IpV6(..) -> "[" <> ewe.ip_address_to_string(ip_address) <> "]"
      ewe.IpV4(..) -> ewe.ip_address_to_string(ip_address)
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
      |> list.group(fn(local_record) { local_record.name })
      |> dict.to_list
      |> list.map(fn(pair) {
        let #(name, domain_records) = pair

        record.DomainGroup(
          name:,
          records: list.map(domain_records, record.to_entry),
        )
      })
      |> json.array(of: record.domain_group_to_json)
      |> json.to_string
      |> wisp.json_response(200)
    }

    http.Post, ["api", "domains"] -> {
      use json <- wisp.require_json(request)

      case decode.run(json, record.domain_group_decoder()) {
        Ok(group) ->
          zone.insert_domain(context.zone, group.name, group.records)
          |> mutation_response
        Error(_error) -> wisp.bad_request("Invalid body")
      }
    }

    http.Put, ["api", "domains", ..path] -> {
      use name <- require_domain_name(request, path)
      use json <- wisp.require_json(request)

      case decode.run(json, decode.list(of: record.entry_decoder())) {
        Ok(entries) ->
          zone.put_domain(context.zone, name, entries)
          |> mutation_response
        Error(_error) -> wisp.bad_request("Invalid body")
      }
    }

    http.Delete, ["api", "domains", ..path] -> {
      use name <- require_domain_name(request, path)

      zone.delete_domain(context.zone, name)
      |> mutation_response
    }

    _method, _segments -> {
      case wisp.priv_directory("server") {
        Ok(priv) -> {
          let request = case request.path {
            "/" -> request.Request(..request, path: "/index.html")
            _path -> request
          }

          use <- wisp.serve_static(request, under: "/", from: priv)
          wisp.not_found()
        }
        Error(Nil) -> wisp.internal_server_error()
      }
    }
  }
}

fn mutation_response(result: Result(Nil, zone.ZoneError)) -> wisp.Response {
  case result {
    Ok(Nil) -> wisp.no_content()
    Error(error) -> zone_error_response(error)
  }
}

fn zone_error_response(error: zone.ZoneError) -> wisp.Response {
  case error {
    zone.Conflict ->
      wisp.response(409)
      |> wisp.string_body("Domain already exists")
    zone.InvalidRecord(_name, reason) ->
      wisp.bad_request(record.describe_validation_error(reason))
    zone.CnameConflict ->
      wisp.response(422)
      |> wisp.string_body("A CNAME must be the domain's only record")
    zone.WriteFailure(reason) -> {
      logging.log(
        logging.Error,
        "Failed to write zone file: " <> simplifile.describe_error(reason),
      )

      wisp.response(503)
      |> wisp.string_body("Failed to write zone file")
    }
  }
}

fn require_domain_name(
  request: wisp.Request,
  path: List(String),
  next: fn(String) -> wisp.Response,
) -> wisp.Response {
  let name = case path {
    [] -> request.get_query(request) |> result.try(list.key_find(_, "name"))
    [encoded] -> uri.percent_decode(encoded)
    _extra_segments -> Error(Nil)
  }

  case name {
    Ok(name) if name != "" -> next(name)
    Ok(_empty_name) | Error(Nil) ->
      wisp.bad_request("Missing or invalid domain name")
  }
}
