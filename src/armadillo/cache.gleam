import armadillo/dns
import armadillo/ip

pub type CacheError {
  NotFound
  Expired
}

pub type Record {
  Record(ips: List(#(ip.Address, Int)))
}

@external(erlang, "cache_ffi", "new")
pub fn new() -> Nil

@external(erlang, "cache_ffi", "lookup")
pub fn get(qname: String, qtype: dns.Type) -> Result(Record, CacheError)

pub fn set(qname: String, qtype: dns.Type, ip: ip.Address, ttl_seconds: Int) {
  do_set(qname, qtype, ip, system_time_seconds() + ttl_seconds)
}

@external(erlang, "cache_ffi", "insert")
fn do_set(qname: String, qtype: dns.Type, ip: ip.Address, expiry: Int) -> Nil

@external(erlang, "cache_ffi", "delete")
pub fn delete(qname: String, qtype: dns.Type) -> Nil

@external(erlang, "cache_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
