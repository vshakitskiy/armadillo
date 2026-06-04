import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/pair
import server/cache
import server/dns/protocol as dns
import server/dns/udp
import server/ip

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

  let #(keyed_questions, keyed_answers) =
    list.index_fold(
      over: query.questions,
      from: #([], []),
      with: fn(acc, question, index) {
        let #(questions, answers) = acc

        case lookup_chain(question.qname, question.qtype) {
          Ok([]) | Error(Nil) -> #([#(index, question), ..questions], answers)
          Ok(records) -> {
            let keyed = list.map(records, pair.new(index, _))
            #(questions, list.append(keyed, answers))
          }
        }
      },
    )

  case list.map(keyed_questions, with: pair.second) {
    [] -> {
      let answers =
        list.sort(keyed_answers, fn(a, b) {
          int.compare(pair.first(a), pair.first(b))
        })
        |> list.map(pair.second)

      let _ =
        encode_response(query, answers)
        |> udp.send(peer, _)

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
                case record.rtype {
                  dns.CNAME ->
                    case dns.decode_cname_target(record.rdata) {
                      Ok(target) ->
                        cache.set_cname(record.name, target, record.ttl)
                      Error(_) -> Nil
                    }
                  _ ->
                    case ip.from_bit_array(record.rdata) {
                      Ok(ip) ->
                        cache.set(record.name, record.rtype, ip, record.ttl)
                      Error(_) -> Nil
                    }
                }
              })

              let cached =
                keyed_answers
                |> list.sort(fn(a, b) {
                  int.compare(pair.first(a), pair.first(b))
                })
                |> list.map(pair.second)

              let _ =
                dns.Response(
                  ..response,
                  id: query.id,
                  questions: query.questions,
                  answers: list.append(cached, response.answers),
                )
                |> dns.encode_response
                |> udp.send(peer, _)

              Nil
            }

            Ok(dns.DecodedQuery(_))
            | Error(dns.NotEnough)
            | Error(dns.Malformed) -> {
              let _ =
                encode_serv_fail(query)
                |> udp.send(peer, _)
              Nil
            }
          }
        }

        Error(_) -> {
          let _ =
            encode_serv_fail(query)
            |> udp.send(peer, _)
          Nil
        }
      }
    }
  }
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
                rtype: dns.CNAME,
                rclass: dns.IN,
                ttl: remaining,
                rdata: dns.encode_name(target),
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
  |> echo
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
