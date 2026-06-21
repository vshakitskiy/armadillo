import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import shared/ip

pub type DecodeError {
  NotEnough
  Malformed
}

pub type Decoded {
  DecodedQuery(Query)
  DecodedResponse(Response)
}

pub type Query {
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
}

pub type Response {
  Response(
    id: Int,
    opcode: Opcode,
    truncated: Bool,
    recursion_desired: Bool,
    recursion_available: Bool,
    authoritative: Bool,
    rcode: Rcode,
    questions: List(Question),
    answers: List(ResourceRecord),
    authority: List(ResourceRecord),
    additional: List(ResourceRecord),
    edns: option.Option(Edns),
  )
}

pub type Opcode {
  QueryOpcode
  Iquery
  Status
  Notify
  Update
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
  Ns
  Cname
  Soa
  Ptr
  Mx
  Aaaa
  Srv
  AnyType
  Unknown(Int)
}

pub fn type_to_string(t: Type) -> String {
  case t {
    A -> "A"
    Aaaa -> "AAAA"
    Cname -> "CNAME"
    Ns -> "NS"
    Mx -> "MX"
    Ptr -> "PTR"
    Soa -> "SOA"
    Srv -> "SRV"
    AnyType -> "ANY"
    Unknown(n) -> "?" <> string.inspect(n)
  }
}

pub type Class {
  In
  Ch
  AnyClass
}

pub type Question {
  Question(qname: String, type_: Type, class: Class)
}

pub type ResourceRecord {
  ResourceRecord(name: String, class: Class, ttl: Int, rdata: Rdata)
}

pub type Rdata {
  AData(ip.Ipv4)
  AaaaData(ip.Ipv6)
  CnameData(String)
  RawData(type_: Type, data: BitArray)
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
        0 -> Ok(QueryOpcode)
        1 -> Ok(Iquery)
        2 -> Ok(Status)
        4 -> Ok(Notify)
        5 -> Ok(Update)
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
          Ok(
            DecodedQuery(Query(
              id:,
              opcode:,
              truncated: tc == 1,
              recursion_desired: rd == 1,
              questions:,
              authority:,
              additional:,
              edns:,
            )),
          )
        1 ->
          Ok(
            DecodedResponse(Response(
              id:,
              opcode:,
              truncated: tc == 1,
              recursion_desired: rd == 1,
              recursion_available: ra == 1,
              authoritative: aa == 1,
              rcode:,
              questions:,
              answers:,
              authority:,
              additional:,
              edns:,
            )),
          )
        _ -> Error(Malformed)
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
        <<type_:16, class:16, remaining:bits>> -> {
          use class <- result.try(decode_class(class))
          do_decode_questions(remaining, packet, count - 1, [
            Question(qname:, type_: decode_type(type_), class:),
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
      use #(record, remaining) <- result.try(decode_record(
        name,
        remaining,
        packet,
      ))
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
          use #(record, remaining) <- result.try(decode_record(
            name,
            remaining,
            packet,
          ))
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

fn decode_record(name: String, remaining: BitArray, packet: BitArray) {
  case remaining {
    <<
      rtype:16,
      class:16,
      ttl:32,
      rdlength:16,
      rdata:bytes-size(rdlength),
      remaining:bits,
    >> -> {
      use class <- result.try(decode_class(class))
      use rdata <- result.try(decode_rdata(rtype, rdata, packet))
      Ok(#(ResourceRecord(name:, class:, ttl:, rdata:), remaining))
    }

    _ -> Error(NotEnough)
  }
}

fn decode_rdata(
  rtype: Int,
  rdata: BitArray,
  packet: BitArray,
) -> Result(Rdata, DecodeError) {
  case decode_type(rtype) {
    A ->
      case ip.ipv4_from_bit_array(rdata) {
        Ok(address) -> Ok(AData(address))
        _ -> Error(Malformed)
      }
    Aaaa ->
      case ip.ipv6_from_bit_array(rdata) {
        Ok(address) -> Ok(AaaaData(address))
        _ -> Error(Malformed)
      }
    Cname ->
      case decode_name(rdata, packet) {
        Ok(#(target, _)) -> Ok(CnameData(target))
        Error(e) -> Error(e)
      }
    type_ -> Ok(RawData(type_, rdata))
  }
}

fn decode_type(value: Int) -> Type {
  case value {
    1 -> A
    2 -> Ns
    5 -> Cname
    6 -> Soa
    12 -> Ptr
    15 -> Mx
    28 -> Aaaa
    33 -> Srv
    255 -> AnyType
    n -> Unknown(n)
  }
}

fn decode_class(value: Int) -> Result(Class, DecodeError) {
  case value {
    1 -> Ok(In)
    3 -> Ok(Ch)
    255 -> Ok(AnyClass)
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

pub fn encode_query(query: Query) {
  let qdcount = list.length(query.questions)
  let nscount = list.length(query.authority)
  let arcount =
    list.length(query.additional)
    + case query.edns {
      option.Some(_) -> 1
      option.None -> 0
    }

  let questions =
    list.fold(over: query.questions, from: <<>>, with: fn(acc, question) {
      <<acc:bits, encode_question(question):bits>>
    })

  let authority =
    list.fold(over: query.authority, from: <<>>, with: fn(acc, record) {
      <<acc:bits, encode_record(record):bits>>
    })

  let additional =
    list.fold(over: query.additional, from: <<>>, with: fn(acc, record) {
      <<acc:bits, encode_record(record):bits>>
    })

  let edns = option.map(query.edns, encode_edns) |> option.unwrap(<<>>)

  <<
    query.id:16,
    0:1,
    encode_opcode(query.opcode):4,
    0:1,
    bool_to_int(query.truncated):1,
    bool_to_int(query.recursion_desired):1,
    0:1,
    0:3,
    0:4,
    qdcount:16,
    0:16,
    nscount:16,
    arcount:16,
    questions:bits,
    authority:bits,
    additional:bits,
    edns:bits,
  >>
}

pub fn encode_response(response: Response) {
  let qdcount = list.length(response.questions)
  let ancount = list.length(response.answers)
  let nscount = list.length(response.authority)
  let arcount =
    list.length(response.additional)
    + case response.edns {
      option.Some(_) -> 1
      option.None -> 0
    }

  let questions =
    list.fold(over: response.questions, from: <<>>, with: fn(acc, question) {
      <<acc:bits, encode_question(question):bits>>
    })

  let answers =
    list.fold(over: response.answers, from: <<>>, with: fn(acc, record) {
      <<acc:bits, encode_record(record):bits>>
    })

  let authority =
    list.fold(over: response.authority, from: <<>>, with: fn(acc, record) {
      <<acc:bits, encode_record(record):bits>>
    })

  let additional =
    list.fold(over: response.additional, from: <<>>, with: fn(acc, record) {
      <<acc:bits, encode_record(record):bits>>
    })

  let edns = option.map(response.edns, encode_edns) |> option.unwrap(<<>>)

  <<
    response.id:16,
    1:1,
    encode_opcode(response.opcode):4,
    bool_to_int(response.authoritative):1,
    bool_to_int(response.truncated):1,
    bool_to_int(response.recursion_desired):1,
    bool_to_int(response.recursion_available):1,
    0:3,
    encode_rcode(response.rcode):4,
    qdcount:16,
    ancount:16,
    nscount:16,
    arcount:16,
    questions:bits,
    answers:bits,
    authority:bits,
    additional:bits,
    edns:bits,
  >>
}

fn bool_to_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn encode_opcode(opcode: Opcode) -> Int {
  case opcode {
    QueryOpcode -> 0
    Iquery -> 1
    Status -> 2
    Notify -> 4
    Update -> 5
  }
}

fn encode_rcode(rcode: Rcode) -> Int {
  case rcode {
    NoError -> 0
    FormErr -> 1
    ServFail -> 2
    NXDomain -> 3
    NotImp -> 4
    Refused -> 5
  }
}

fn encode_type(type_: Type) -> Int {
  case type_ {
    A -> 1
    Ns -> 2
    Cname -> 5
    Soa -> 6
    Ptr -> 12
    Mx -> 15
    Aaaa -> 28
    Srv -> 33
    AnyType -> 255
    Unknown(n) -> n
  }
}

fn encode_class(class: Class) -> Int {
  case class {
    In -> 1
    Ch -> 3
    AnyClass -> 255
  }
}

pub fn encode_name(name: String) -> BitArray {
  case name {
    "" -> <<0>>
    _ ->
      string.split(name, ".")
      |> list.fold(from: <<>>, with: fn(acc, label) {
        <<acc:bits, string.byte_size(label):8, label:utf8>>
      })
      |> bit_array.append(<<0>>)
  }
}

fn encode_question(question: Question) -> BitArray {
  <<
    encode_name(question.qname):bits,
    encode_type(question.type_):16,
    encode_class(question.class):16,
  >>
}

fn encode_record(record: ResourceRecord) -> BitArray {
  let #(rtype, rdata) = encode_rdata(record.rdata)
  let rtype = encode_type(rtype)

  <<
    encode_name(record.name):bits,
    rtype:16,
    encode_class(record.class):16,
    record.ttl:32,
    bit_array.byte_size(rdata):16,
    rdata:bits,
  >>
}

fn encode_rdata(rdata: Rdata) -> #(Type, BitArray) {
  case rdata {
    AData(address) -> #(A, ip.ipv4_to_bit_array(address))
    AaaaData(address) -> #(Aaaa, ip.ipv6_to_bit_array(address))
    CnameData(name) -> #(Cname, encode_name(name))
    RawData(type_, data) -> #(type_, data)
  }
}

fn encode_edns(edns: Edns) -> BitArray {
  let options =
    list.fold(over: edns.options, from: <<>>, with: fn(acc, option) {
      <<
        acc:bits,
        option.code:16,
        bit_array.byte_size(option.data):16,
        option.data:bits,
      >>
    })

  <<
    0:8,
    41:16,
    edns.udp_payload_size:16,
    edns.extended_rcode:8,
    edns.version:8,
    bool_to_int(edns.dnssec_ok):1,
    0:15,
    bit_array.byte_size(options):16,
    options:bits,
  >>
}
