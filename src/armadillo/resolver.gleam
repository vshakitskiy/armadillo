import armadillo/cache
import armadillo/dns
import armadillo/ip
import armadillo/udp
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision

pub type Resolve {
  Resolve(
    peer: udp.Peer,
    query: dns.Query,
    original: BitArray,
    upstream: ip.Address,
  )
}

pub fn factory(named: process.Name(factory.Message(Resolve, Nil))) {
  factory.worker_child(worker)
  |> factory.named(named)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.supervised
}

fn worker(resolve: Resolve) {
  let Resolve(peer:, query:, original:, upstream:) = resolve

  process.spawn(fn() {
    case query.questions {
      [question, ..] -> {
        use <- lookup_cache(peer, query, question)

        let assert Ok(socket) = udp.open(0, [udp.ActiveMode(udp.Passive)])
        let _ = udp.send(udp.Peer(socket:, ip: upstream, port: 53), original)

        case udp.recv(socket, 5000) {
          Ok(#(_peer, data)) -> {
            udp.close(socket)

            case dns.decode(data) {
              Ok(dns.DecodedResponse(response)) -> {
                list.each(response.answers, fn(record) {
                  case ip.from_bit_array(record.rdata) {
                    Ok(ip) ->
                      cache.set(record.name, record.rtype, ip, record.ttl)
                    Error(_) -> Nil
                  }
                })

                let _ =
                  dns.encode_response(response)
                  |> udp.send(peer, _)

                Nil
              }
              Ok(dns.DecodedQuery(_)) -> Nil
              Error(dns.NotEnough) -> Nil
              Error(dns.Malformed) -> Nil
            }
          }
          Error(_) -> Nil
        }
      }
      _ -> {
        let _ =
          encode_serv_fail(query)
          |> udp.send(peer, _)

        Nil
      }
    }
  })
  |> actor.Started(data: Nil)
  |> Ok
}

fn lookup_cache(
  peer: udp.Peer,
  query: dns.Query,
  question: dns.Question,
  next: fn() -> Nil,
) {
  case cache.get(question.qname, question.qtype) {
    Ok(cache.Record(ip:, remaining:)) -> {
      let _ =
        [resource_record(question.qname, ip, remaining)]
        |> encode_response(query, _)
        |> udp.send(peer, _)

      Nil
    }
    Error(_) -> next()
  }
}

pub fn encode_serv_fail(query: dns.Query) -> BitArray {
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

fn resource_record(name: String, ip: ip.Address, ttl: Int) {
  let rtype = case ip {
    ip.IpV4(..) -> dns.A
    ip.IpV6(..) -> dns.AAAA
  }

  dns.ResourceRecord(
    name:,
    rtype:,
    rclass: dns.IN,
    ttl:,
    rdata: ip.to_bit_array(ip),
  )
}
