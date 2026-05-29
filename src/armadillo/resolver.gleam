import armadillo/cache
import armadillo/dns
import armadillo/ip
import armadillo/udp
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/pair

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

        case cache.get(question.qname, question.qtype) {
          Ok(cache.Record(ips:)) -> {
            let records =
              list.map(ips, with: fn(ip) {
                let #(ip, ttl) = ip
                #(index, resource_record(question.qname, ip, ttl))
              })

            #(questions, list.append(records, answers))
          }
          Error(_) -> #([#(index, question), ..questions], answers)
        }
      },
    )

  case list.map(keyed_questions, with: fn(entry) { entry.1 }) {
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
      let index_map =
        list.fold(keyed_questions, dict.new(), fn(acc, entry) {
          let #(index, question) = entry
          dict.insert(acc, #(question.qname, question.qtype), index)
        })

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
                case ip.from_bit_array(record.rdata) {
                  Ok(ip) -> cache.set(record.name, record.rtype, ip, record.ttl)
                  Error(_) -> Nil
                }
              })

              let upstream_answers =
                list.filter_map(response.answers, fn(record) {
                  case dict.get(index_map, #(record.name, record.rtype)) {
                    Ok(index) -> Ok(#(index, record))
                    Error(_) -> Error(Nil)
                  }
                })

              let answers =
                list.append(keyed_answers, upstream_answers)
                |> list.sort(fn(a, b) {
                  int.compare(pair.first(a), pair.first(b))
                })
                |> list.map(pair.second)

              let _ =
                dns.Response(
                  ..response,
                  id: query.id,
                  questions: query.questions,
                  answers:,
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
