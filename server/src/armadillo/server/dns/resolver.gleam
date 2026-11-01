import armadillo/server/cache
import armadillo/server/dns/protocol as dns
import armadillo/server/dns/udp
import armadillo/shared/ip
import armadillo/shared/record
import gleam/bool
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
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
    dns.QueryOpcode, [question] if question.class != dns.In ->
      forward_query(peer, query, question, upstream, [])
    dns.QueryOpcode, [question] -> {
      case lookup_chain(question.qname, question.type_) {
        Error(NotCached(name, aliases)) -> {
          let upstream_question = case aliases {
            [] -> question
            [_first, ..] -> dns.Question(..question, qname: name)
          }

          forward_query(peer, query, upstream_question, upstream, aliases)
        }
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

const upstream_timeout_ms = 5000

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

@external(erlang, "crypto", "strong_rand_bytes")
fn random_bytes(size: Int) -> BitArray

fn random_query_id() -> Int {
  let assert <<id:16>> = random_bytes(2)
  id
}

fn forward_query(
  peer: udp.Peer,
  query: dns.Query,
  question: dns.Question,
  upstream: ip.Address,
  aliases: List(dns.ResourceRecord),
) -> Nil {
  let forwarded_query =
    dns.Query(
      ..query,
      id: random_query_id(),
      questions: [question],
      truncated: False,
      authority: [],
      additional: [],
    )

  let socket_options = case upstream {
    ip.V4(_address) -> []
    ip.V6(_address) -> [udp.Ipv6]
  }

  let response_result = {
    use socket <- result.try(
      udp.open(0, [udp.ActiveMode(udp.Passive), ..socket_options]),
    )

    let reply = query_upstream(socket, upstream, forwarded_query)
    udp.close(socket)

    reply
  }

  case response_result {
    Ok(#(response, payload)) -> {
      cache.store_response(response)
      log_resolved("↑", ip.to_string(peer.ip), question, response.answers)
      let reply = case aliases {
        [] -> <<query.id:16, payload:bits>>
        [_first, ..] -> encode_alias_response(query, aliases, response)
      }

      let _sent = udp.send(peer, reply)
      Nil
    }
    Error(reason) -> {
      log_fail(ip.to_string(peer.ip), question)
      logging.log(
        logging.Warning,
        "Upstream query failed: " <> udp.describe_error(reason),
      )
      let _sent = udp.send(peer, encode_error_response(query, dns.ServFail))
      Nil
    }
  }
}

fn encode_alias_response(
  query: dns.Query,
  aliases: List(dns.ResourceRecord),
  response: dns.Response,
) -> BitArray {
  dns.Response(
    ..response,
    id: query.id,
    questions: query.questions,
    authoritative: False,
    answers: list.append(aliases, response.answers),
  )
  |> dns.encode_response
}

fn query_upstream(
  socket: udp.Socket,
  upstream: ip.Address,
  query: dns.Query,
) -> Result(#(dns.Response, BitArray), udp.SocketError) {
  use _sent <- result.try(udp.send(
    udp.Peer(socket:, ip: upstream, port: 53),
    dns.encode_query(query),
  ))

  let deadline = monotonic_time(Millisecond) + upstream_timeout_ms

  receive_response(socket, upstream, query, deadline)
}

fn receive_response(
  socket: udp.Socket,
  upstream: ip.Address,
  query: dns.Query,
  deadline: Int,
) -> Result(#(dns.Response, BitArray), udp.SocketError) {
  let remaining = deadline - monotonic_time(Millisecond)

  use <- bool.guard(when: remaining <= 0, return: Error(udp.Timeout))

  use #(peer, data) <- result.try(udp.recv(socket, remaining))

  case dns.decode(data), data {
    Ok(dns.DecodedResponse(response)), <<_id:16, payload:bits>> -> {
      case matches_response(response, query, peer, upstream) {
        True -> Ok(#(response, payload))
        False -> receive_response(socket, upstream, query, deadline)
      }
    }
    _invalid_response, _packet ->
      receive_response(socket, upstream, query, deadline)
  }
}

fn matches_response(
  response: dns.Response,
  query: dns.Query,
  peer: udp.Peer,
  upstream: ip.Address,
) -> Bool {
  response.id == query.id
  && peer.ip == upstream
  && peer.port == 53
  && response.opcode == query.opcode
  && case response.questions, query.questions {
    [actual], [expected] ->
      actual.type_ == expected.type_
      && actual.class == expected.class
      && record.normalize_name(actual.qname)
      == record.normalize_name(expected.qname)
    _actual, _expected -> False
  }
}

fn log_resolved(
  symbol: String,
  peer_ip: String,
  question: dns.Question,
  answers: List(dns.ResourceRecord),
) -> Nil {
  let answer_values =
    answers
    |> list.filter_map(fn(answer) {
      case answer.rdata {
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
      <> answer_values,
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
  NotCached(name: String, aliases: List(dns.ResourceRecord))
  CnameLoop
  CnameLimit
  InvalidCnameRecords
}

fn lookup_chain(
  qname: String,
  qtype: dns.Type,
) -> Result(List(dns.ResourceRecord), LookupError) {
  follow_chain(record.normalize_name(qname), qtype, [], max_cname_hops)
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
    Ok([]) -> Error(NotCached(qname, list.reverse(aliases)))
    Ok([_first, _second, ..]) if qtype == dns.Cname -> Error(InvalidCnameRecords)
    Ok(matched) ->
      Ok(list.append(
        list.reverse(aliases),
        list.map(matched, dns.record_to_resource_record),
      ))
    Error(cache.NoData) | Error(cache.NotFound) | Error(cache.Expired) ->
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
    Ok([record.CnameRecord(target:, ..) as cname]) if remaining_hops > 0 ->
      follow_chain(
        target,
        qtype,
        [dns.record_to_resource_record(cname), ..aliases],
        remaining_hops - 1,
      )
    Ok([record.CnameRecord(..)]) -> Error(CnameLimit)
    Ok(_invalid_records) -> Error(InvalidCnameRecords)
    Error(cache.NoData) -> Ok(list.reverse(aliases))
    Error(cache.NotFound) | Error(cache.Expired) ->
      Error(NotCached(qname, list.reverse(aliases)))
  }
}

fn encode_error_response(query: dns.Query, rcode: dns.Rcode) -> BitArray {
  dns.Response(
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
  )
  |> dns.encode_response
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
