import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
import gleam/string
import logging
import server/cache
import server/dns/protocol as dns
import server/dns/udp
import shared/ip

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

  let peer_ip = ip.to_string(peer.ip) |> result.unwrap("?")

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
        Ok(#(_peer, data)) -> {
          udp.close(socket)
          case dns.decode(data) {
            Ok(dns.DecodedResponse(response)) -> {
              list.each(response.answers, fn(record) {
                case record.rdata {
                  dns.AData(a) -> cache.set(record.name, dns.A, a, record.ttl)
                  dns.AaaaData(a) ->
                    cache.set(record.name, dns.Aaaa, a, record.ttl)
                  dns.CnameData(target) ->
                    cache.set_cname(record.name, target, record.ttl)
                  dns.RawData(_, _) -> Nil
                }
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
            Ok(dns.DecodedQuery(_))
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
        dns.AData(a) -> Ok(ip.to_string(a) |> result.unwrap("?"))
        dns.AaaaData(a) -> Ok(ip.to_string(a) |> result.unwrap("?"))
        dns.CnameData(_) | dns.RawData(_, _) -> Error(Nil)
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
    Ok(cache.Record(ips:)) ->
      Ok(
        list.map(ips, fn(entry) {
          let remaining = case entry.remaining {
            -1 -> 300
            remaining -> remaining
          }
          resource_record(qname, entry.ip, remaining)
        }),
      )
    Error(_) ->
      case cache.get_cname(qname) {
        Ok(cnames) ->
          list.try_fold(over: cnames, from: [], with: fn(acc, entry) {
            let #(target, remaining) = entry
            let cname_record =
              dns.ResourceRecord(
                name: qname,
                class: dns.In,
                ttl: remaining,
                rdata: dns.CnameData(target),
              )
            case lookup_chain(target, qtype) {
              Ok(tail) -> Ok(list.append(acc, [cname_record, ..tail]))
              Error(_) -> Error(Nil)
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

fn resource_record(name: String, addr: ip.Address, ttl: Int) {
  let rdata = case addr {
    ip.IpV4(..) -> dns.AData(addr)
    ip.IpV6(..) -> dns.AaaaData(addr)
  }

  dns.ResourceRecord(name:, class: dns.In, ttl:, rdata:)
}
