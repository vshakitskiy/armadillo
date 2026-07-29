import armadillo/server/cache
import armadillo/server/dns/protocol as dns
import armadillo/server/dns/udp
import armadillo/shared/ip
import armadillo/shared/records
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/string
import logging

pub type Resolve {
  Resolve(peer: udp.Peer, query: dns.Query, upstream: ip.Address)
}

pub fn factory(named: process.Name(factory.Message(Resolve, Nil))) {
  factory.worker_child(fn(resolve) {
    process.spawn(fn() { handle_query(resolve) })
    |> actor.Started(data: Nil)
    |> Ok
  })
  |> factory.named(named)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.supervised
}

fn handle_query(resolve: Resolve) -> Nil {
  let Resolve(peer:, query:, upstream:) = resolve

  let peer_ip = ip.to_string(peer.ip)

  let #(local_answers, upstream_questions) =
    list.fold(query.questions, #([], []), fn(acc, question) {
      let #(answers, questions) = acc
      case lookup_chain(question.qname, question.type_) {
        Ok([]) | Error(Nil) -> #(answers, [question, ..questions])
        Ok(records) -> #(list.append(answers, records), questions)
      }
    })

  case upstream_questions {
    [] -> {
      list.each(query.questions, log_resolved("○", peer_ip, _, local_answers))
      let _ = encode_response(query, local_answers) |> udp.send(peer, _)
      Nil
    }
    questions -> {
      let upstream_query =
        dns.encode_query(dns.Query(
          id: query.id,
          opcode: query.opcode,
          truncated: False,
          recursion_desired: query.recursion_desired,
          questions:,
          authority: [],
          additional: [],
          edns: query.edns,
        ))

      let assert Ok(socket) = udp.open(0, [udp.ActiveMode(udp.Passive)])
      let _ =
        udp.send(udp.Peer(socket:, ip: upstream, port: 53), upstream_query)

      case udp.recv(socket, 5000) {
        Ok(#(resp_peer, data)) -> {
          udp.close(socket)
          case dns.decode(data) {
            Ok(dns.DecodedResponse(response))
              if response.id == query.id && resp_peer.ip == upstream
            -> {
              list.each(response.answers, fn(record) {
                use record <- dns.resource_record_to_record(record)
                cache.set_with_ttl(record, record.ttl)
              })

              list.each(questions, log_resolved(
                "↑",
                peer_ip,
                _,
                response.answers,
              ))
              let _ =
                dns.Response(
                  ..response,
                  id: query.id,
                  questions: query.questions,
                  answers: list.append(local_answers, response.answers),
                )
                |> dns.encode_response
                |> udp.send(peer, _)
              Nil
            }
            Ok(dns.DecodedResponse(_))
            | Ok(dns.DecodedQuery(_))
            | Error(dns.NotEnough)
            | Error(dns.Malformed) -> {
              list.each(questions, log_fail(peer_ip, _))
              let _ = encode_serv_fail(query) |> udp.send(peer, _)
              Nil
            }
          }
        }
        Error(_) -> {
          list.each(questions, log_fail(peer_ip, _))
          let _ = encode_serv_fail(query) |> udp.send(peer, _)
          Nil
        }
      }
    }
  }
}

fn log_resolved(
  symbol: String,
  peer_ip: String,
  question: dns.Question,
  answers: List(dns.ResourceRecord),
) -> Nil {
  let ips =
    answers
    |> list.filter_map(fn(r) {
      case r.rdata {
        dns.AData(ip) -> Ok(ip.ipv4_to_string(ip))
        dns.AaaaData(ip) -> Ok(ip.ipv6_to_string(ip))
        dns.CnameData(target) -> Ok(target)
        dns.RawData(_, _) -> Error(Nil)
      }
    })
    |> string.join(" ")
  logging.log(
    logging.Info,
    symbol
      <> "  "
      <> peer_ip
      <> "  "
      <> question.qname
      <> " "
      <> dns.type_to_string(question.type_)
      <> "  →  "
      <> ips,
  )
}

fn log_fail(peer_ip: String, question: dns.Question) -> Nil {
  logging.log(
    logging.Warning,
    "✗  "
      <> peer_ip
      <> "  "
      <> question.qname
      <> " "
      <> dns.type_to_string(question.type_),
  )
}

fn lookup_chain(
  qname: String,
  qtype: dns.Type,
) -> Result(List(dns.ResourceRecord), Nil) {
  case cache.get(qname, qtype) {
    Ok(matched) -> Ok(list.map(matched, dns.record_to_resource_record))
    Error(_) ->
      case cache.get(qname, dns.Cname) {
        Ok(cnames) ->
          list.try_fold(over: cnames, from: [], with: fn(acc, record) {
            case record {
              records.CnameRecord(target:, ..) ->
                case lookup_chain(target, qtype) {
                  Ok(tail) ->
                    Ok(
                      list.append(acc, [
                        dns.record_to_resource_record(record),
                        ..tail
                      ]),
                    )
                  Error(_) -> Error(Nil)
                }
              _ -> Error(Nil)
            }
          })
        Error(_) -> Error(Nil)
      }
  }
}

fn encode_serv_fail(query: dns.Query) -> BitArray {
  dns.encode_response(dns.Response(
    id: query.id,
    opcode: query.opcode,
    truncated: False,
    recursion_desired: query.recursion_desired,
    recursion_available: False,
    authoritative: False,
    rcode: dns.ServFail,
    questions: query.questions,
    answers: [],
    authority: [],
    additional: [],
    edns: option.None,
  ))
}

fn encode_response(query: dns.Query, answers: List(dns.ResourceRecord)) {
  dns.Response(
    id: query.id,
    opcode: query.opcode,
    truncated: False,
    recursion_desired: query.recursion_desired,
    recursion_available: True,
    authoritative: False,
    rcode: dns.NoError,
    questions: query.questions,
    answers:,
    authority: [],
    additional: [],
    edns: option.None,
  )
  |> dns.encode_response
}
