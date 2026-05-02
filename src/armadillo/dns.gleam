import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub type DecodeError {
  NotEnough
  Malformed
}

pub type Message {
  Query(
    id: Int,
    opcode: Opcode,
    truncated: Bool,
    recursion_desired: Bool,
    questions: List(Question),
    authority: List(ResourceRecord),
    additional: List(ResourceRecord),
    edns: option.Option(Edns),
  )
  Response(
    id: Int,
    opcode: Opcode,
    authoritative: Bool,
    truncated: Bool,
    recursion_desired: Bool,
    recursion_available: Bool,
    rcode: Rcode,
    answers: List(ResourceRecord),
    authority: List(ResourceRecord),
    additional: List(ResourceRecord),
    edns: option.Option(Edns),
  )
}

pub type Opcode {
  QUERY
  IQUERY
  STATUS
  NOTIFY
  UPDATE
}

pub type Rcode {
  NoError
  FormErr
  ServFail
  NXDomain
  NotImp
  Refused
}

pub type Type {
  A
  NS
  CNAME
  SOA
  PTR
  MX
  AAAA
  SRV
  ANYType
}

pub type Class {
  IN
  CH
  ANYClass
}

pub type Question {
  Question(qname: String, qtype: Type, qclass: Class)
}

pub type ResourceRecord {
  ResourceRecord(
    name: String,
    rtype: Type,
    rclass: Class,
    ttl: Int,
    rdata: BitArray,
  )
}

pub type Edns {
  Edns(
    udp_payload_size: Int,
    extended_rcode: Int,
    version: Int,
    dnssec_ok: Bool,
    options: List(EdnsOption),
  )
}

pub type EdnsOption {
  EdnsOption(code: Int, data: BitArray)
}

pub fn decode(data: BitArray) {
  case data {
    <<
      id:16,
      qr:1,
      opcode:4,
      aa:1,
      tc:1,
      rd:1,
      ra:1,
      _z:3,
      rcode:4,
      qdcount:unsigned-int-size(16),
      ancount:unsigned-int-size(16),
      nscount:unsigned-int-size(16),
      arcount:unsigned-int-size(16),
      remaining:bits,
    >> -> {
      use opcode <- result.try(case opcode {
        0 -> Ok(QUERY)
        1 -> Ok(IQUERY)
        2 -> Ok(STATUS)
        4 -> Ok(NOTIFY)
        5 -> Ok(UPDATE)
        _ -> Error(Malformed)
      })

      use rcode <- result.try(case rcode {
        0 -> Ok(NoError)
        1 -> Ok(FormErr)
        2 -> Ok(ServFail)
        3 -> Ok(NXDomain)
        4 -> Ok(NotImp)
        5 -> Ok(Refused)
        _ -> Error(Malformed)
      })

      use #(questions, remaining) <- result.try(decode_questions(
        remaining,
        data,
        qdcount,
      ))

      use #(answers, remaining) <- result.try(decode_records(
        remaining,
        data,
        ancount,
      ))

      use #(authority, remaining) <- result.try(decode_records(
        remaining,
        data,
        nscount,
      ))

      use #(edns, additional, _remaining) <- result.try(decode_additional(
        remaining,
        data,
        arcount,
      ))

      case qr {
        0 ->
          Ok(Query(
            id:,
            opcode:,
            truncated: tc == 1,
            recursion_desired: rd == 1,
            questions:,
            authority:,
            additional:,
            edns:,
          ))
        1 ->
          Ok(Response(
            id:,
            opcode:,
            authoritative: aa == 1,
            truncated: tc == 1,
            recursion_desired: rd == 1,
            recursion_available: ra == 1,
            rcode:,
            answers:,
            authority:,
            additional:,
            edns:,
          ))
        _ -> panic as "unreachable pattern!"
      }
    }
    _ -> Error(NotEnough)
  }
}

fn decode_questions(remaining: BitArray, packet: BitArray, count: Int) {
  do_decode_questions(remaining, packet, count, [])
}

fn do_decode_questions(
  remaining: BitArray,
  packet: BitArray,
  count: Int,
  acc: List(Question),
) {
  case count {
    0 -> Ok(#(list.reverse(acc), remaining))
    _ -> {
      use #(qname, remaining) <- result.try(decode_name(remaining, packet))
      case remaining {
        <<qtype:16, qclass:16, remaining:bits>> -> {
          use qtype <- result.try(decode_type(qtype))
          use qclass <- result.try(decode_class(qclass))
          do_decode_questions(remaining, packet, count - 1, [
            Question(qname:, qtype:, qclass:),
            ..acc
          ])
        }
        _ -> Error(NotEnough)
      }
    }
  }
}

fn decode_records(remaining: BitArray, packet: BitArray, count: Int) {
  do_decode_records(remaining, packet, count, [])
}

fn do_decode_records(
  remaining: BitArray,
  packet: BitArray,
  count: Int,
  acc: List(ResourceRecord),
) {
  case count {
    0 -> Ok(#(list.reverse(acc), remaining))
    _ -> {
      use #(name, remaining) <- result.try(decode_name(remaining, packet))
      use #(record, remaining) <- result.try(decode_record(name, remaining))
      do_decode_records(remaining, packet, count - 1, [record, ..acc])
    }
  }
}

fn decode_additional(
  remaining: BitArray,
  packet: BitArray,
  count: Int,
) -> Result(#(option.Option(Edns), List(ResourceRecord), BitArray), DecodeError) {
  do_decode_additional(remaining, packet, count, option.None, [])
}

fn do_decode_additional(
  remaining: BitArray,
  packet: BitArray,
  count: Int,
  edns: option.Option(Edns),
  acc: List(ResourceRecord),
) -> Result(#(option.Option(Edns), List(ResourceRecord), BitArray), DecodeError) {
  case count {
    0 -> Ok(#(edns, list.reverse(acc), remaining))
    _ -> {
      use #(name, remaining) <- result.try(decode_name(remaining, packet))
      case remaining {
        <<
          41:16,
          udp_payload_size:16,
          extended_rcode:8,
          version:8,
          dnssec_ok:1,
          _reserved:15,
          rdlength:16,
          rdata:bytes-size(rdlength),
          remaining:bits,
        >> -> {
          use options <- result.try(parse_edns_options(rdata, []))
          let edns =
            Edns(
              udp_payload_size:,
              extended_rcode:,
              version:,
              dnssec_ok: dnssec_ok == 1,
              options:,
            )

          do_decode_additional(
            remaining,
            packet,
            count - 1,
            option.Some(edns),
            acc,
          )
        }
        _ -> {
          use #(record, remaining) <- result.try(decode_record(name, remaining))
          do_decode_additional(remaining, packet, count - 1, edns, [
            record,
            ..acc
          ])
        }
      }
    }
  }
}

fn parse_edns_options(
  data: BitArray,
  acc: List(EdnsOption),
) -> Result(List(EdnsOption), DecodeError) {
  case data {
    <<>> -> Ok(list.reverse(acc))
    <<code:16, length:16, value:bytes-size(length), remaining:bits>> ->
      parse_edns_options(remaining, [EdnsOption(code:, data: value), ..acc])
    _ -> Error(Malformed)
  }
}

fn decode_record(name: String, remaining: BitArray) {
  case remaining {
    <<
      rtype:16,
      rclass:16,
      ttl:32,
      rdlength:16,
      rdata:bytes-size(rdlength),
      remaining:bits,
    >> -> {
      use rtype <- result.try(decode_type(rtype))
      use rclass <- result.try(decode_class(rclass))
      Ok(#(ResourceRecord(name:, rtype:, rclass:, ttl:, rdata:), remaining))
    }

    _ -> Error(NotEnough)
  }
}

fn decode_type(value: Int) -> Result(Type, DecodeError) {
  case value {
    1 -> Ok(A)
    2 -> Ok(NS)
    5 -> Ok(CNAME)
    6 -> Ok(SOA)
    12 -> Ok(PTR)
    15 -> Ok(MX)
    28 -> Ok(AAAA)
    33 -> Ok(SRV)
    255 -> Ok(ANYType)
    _ -> Error(Malformed)
  }
}

fn decode_class(value: Int) -> Result(Class, DecodeError) {
  case value {
    1 -> Ok(IN)
    3 -> Ok(CH)
    255 -> Ok(ANYClass)
    _ -> Error(Malformed)
  }
}

fn decode_name(
  data: BitArray,
  packet: BitArray,
) -> Result(#(String, BitArray), DecodeError) {
  do_decode_name(data, packet, [])
}

fn do_decode_name(
  data: BitArray,
  packet: BitArray,
  acc: List(String),
) -> Result(#(String, BitArray), DecodeError) {
  case data {
    <<0:8, remaining:bits>> ->
      Ok(#(string.join(list.reverse(acc), "."), remaining))
    <<length:8, next:8, remaining:bits>> if length >= 0xC0 -> {
      let offset =
        int.bitwise_and(length, 0x3F)
        |> int.bitwise_shift_left(8)
        |> int.bitwise_or(next)

      case packet {
        <<_:bytes-size(offset), jumped:bits>> -> {
          use #(name, _remaining) <- result.try(do_decode_name(
            jumped,
            packet,
            acc,
          ))

          Ok(#(name, remaining))
        }
        _ -> Error(Malformed)
      }
    }
    <<length:8, label:bytes-size(length), remaining:bits>> ->
      case bit_array.to_string(label) {
        Ok(label) -> do_decode_name(remaining, packet, [label, ..acc])
        Error(Nil) -> Error(Malformed)
      }
    _ -> Error(NotEnough)
  }
}
