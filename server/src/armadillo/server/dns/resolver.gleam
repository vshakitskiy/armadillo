import armadillo/server/cache
import armadillo/server/dns/protocol as dns
import armadillo/server/dns/udp
import armadillo/shared/ip
import armadillo/shared/records
import gleam/bool
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

pub fn factory(
  named: process.Name(factory.Message(Resolve, Nil)),
) -> supervision.ChildSpecification(factory.Supervisor(Resolve, Nil)) {
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

  case query.opcode, query.questions {
    dns.QueryOpcode, [] -> {
      let _sent = udp.send(peer, encode_response(query, []))
      Nil
    }
    dns.QueryOpcode, [question] -> {
      case lookup_chain(question.qname, question.type_) {
        Error(NotCached) -> forward_query(peer, query, question, upstream)
        Error(CnameLoop) | Error(CnameLimit) | Error(InvalidCnameRecords) -> {
          log_fail(ip.to_string(peer.ip), question)
          let _sent = udp.send(peer, encode_error_response(query, dns.ServFail))
          Nil
        }
        Ok(answers) -> {
          log_resolved("○", ip.to_string(peer.ip), question, answers)
          let _sent = udp.send(peer, encode_response(query, answers))
          Nil
        }
      }
    }
    dns.QueryOpcode, [_first, _second, ..] -> {
      let _sent = udp.send(peer, encode_error_response(query, dns.FormErr))
      Nil
    }
    dns.Iquery, _questions
    | dns.Status, _questions
    | dns.Notify, _questions
    | dns.Update, _questions
    -> {
      let _sent = udp.send(peer, encode_error_response(query, dns.NotImp))
      Nil
    }
  }
}

fn forward_query(
  peer: udp.Peer,
  query: dns.Query,
  question: dns.Question,
  upstream: ip.Address,
) -> Nil {
  let peer_ip = ip.to_string(peer.ip)
  let upstream_query =
    dns.Query(..query, truncated: False, authority: [], additional: [])
    |> dns.encode_query

  let assert Ok(socket) = udp.open(0, [udp.ActiveMode(udp.Passive)])
  let _sent =
    udp.send(udp.Peer(socket:, ip: upstream, port: 53), upstream_query)

  case udp.recv(socket, 5000) {
    Ok(#(resp_peer, data)) -> {
      udp.close(socket)
      case dns.decode(data) {
        Ok(dns.DecodedResponse(response))
          if response.id == query.id && resp_peer.ip == upstream
        -> {
          cache.store_response(response)

          log_resolved("↑", peer_ip, question, response.answers)
          let _sent = udp.send(peer, data)
          Nil
        }
        Ok(dns.DecodedResponse(_response))
        | Ok(dns.DecodedQuery(_query))
        | Error(dns.NotEnough)
        | Error(dns.Malformed) -> {
          log_fail(peer_ip, question)
          let _sent = udp.send(peer, encode_error_response(query, dns.ServFail))
          Nil
        }
      }
    }
    Error(_reason) -> {
      log_fail(peer_ip, question)
      let _sent = udp.send(peer, encode_error_response(query, dns.ServFail))
      Nil
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
        dns.RawData(_type, _data) -> Error(Nil)
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

const max_cname_hops = 32

type LookupError {
  NotCached
  CnameLoop
  CnameLimit
  InvalidCnameRecords
}

fn lookup_chain(
  qname: String,
  qtype: dns.Type,
) -> Result(List(dns.ResourceRecord), LookupError) {
  follow_chain(qname, qtype, [], max_cname_hops)
}

fn follow_chain(
  qname: String,
  qtype: dns.Type,
  aliases: List(dns.ResourceRecord),
  remaining_hops: Int,
) -> Result(List(dns.ResourceRecord), LookupError) {
  use <- bool.guard(
    when: list.any(aliases, fn(alias) { alias.name == qname }),
    return: Error(CnameLoop),
  )
  case cache.get(qname, qtype) {
    Ok([]) -> Error(NotCached)
    Ok([_first, _second, ..]) if qtype == dns.Cname -> Error(InvalidCnameRecords)
    Ok(matched) ->
      Ok(list.append(
        list.reverse(aliases),
        list.map(matched, dns.record_to_resource_record),
      ))
    Error(cache.NotFound) | Error(cache.Expired) ->
      follow_alias(qname, qtype, aliases, remaining_hops)
  }
}

fn follow_alias(
  qname: String,
  qtype: dns.Type,
  aliases: List(dns.ResourceRecord),
  remaining_hops: Int,
) -> Result(List(dns.ResourceRecord), LookupError) {
  case cache.get(qname, dns.Cname) {
    Ok([records.CnameRecord(target:, ..) as cname]) if remaining_hops > 0 ->
      follow_chain(
        target,
        qtype,
        [dns.record_to_resource_record(cname), ..aliases],
        remaining_hops - 1,
      )
    Ok([records.CnameRecord(..)]) -> Error(CnameLimit)
    Ok(_invalid_records) -> Error(InvalidCnameRecords)
    Error(cache.NotFound) | Error(cache.Expired) -> Error(NotCached)
  }
}

fn encode_error_response(query: dns.Query, rcode: dns.Rcode) -> BitArray {
  dns.encode_response(dns.Response(
    id: query.id,
    opcode: query.opcode,
    truncated: False,
    recursion_desired: query.recursion_desired,
    recursion_available: False,
    authoritative: False,
    rcode:,
    questions: query.questions,
    answers: [],
    authority: [],
    additional: [],
    edns: option.None,
  ))
}

fn encode_response(
  query: dns.Query,
  answers: List(dns.ResourceRecord),
) -> BitArray {
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
