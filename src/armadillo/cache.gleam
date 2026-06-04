import armadillo/dns/protocol as dns
import armadillo/ip
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

pub type CacheError {
  NotFound
  Expired
}

pub type Record {
  Record(ips: List(Entry))
}

pub type Entry {
  Entry(ip: ip.Address, remaining: Int)
}

pub fn init(records: List(#(String, ip.Address))) {
  new()
  list.each(records, fn(record) {
    let #(domain, ip) = record
    set_permanent(domain, dns.A, ip)
  })
}

type Cleanup {
  Cleanup
}

pub fn worker() {
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(self) {
      process.send_after(self, 60_000, Cleanup)

      actor.initialised(self)
      |> actor.returning(Nil)
      |> Ok
    })
    |> actor.on_message(fn(self, _message) {
      cleanup_expired()
      process.send_after(self, 60_000, Cleanup)
      actor.continue(self)
    })
    |> actor.start()
  })
}

@external(erlang, "cache_ffi", "new")
fn new() -> Nil

@external(erlang, "cache_ffi", "lookup")
pub fn get(qname: String, qtype: dns.Type) -> Result(Record, CacheError)

pub fn set_permanent(qname: String, qtype: dns.Type, ip: ip.Address) {
  do_set(qname, qtype, ip, -1)
}

pub fn set(qname: String, qtype: dns.Type, ip: ip.Address, ttl_seconds: Int) {
  do_set(qname, qtype, ip, system_time_seconds() + ttl_seconds)
}

@external(erlang, "cache_ffi", "insert")
fn do_set(qname: String, qtype: dns.Type, ip: ip.Address, expiry: Int) -> Nil

@external(erlang, "cache_ffi", "delete")
pub fn delete(qname: String, qtype: dns.Type) -> Nil

pub fn set_cname(qname: String, target: String, ttl_seconds: Int) -> Nil {
  do_set_cname(qname, target, system_time_seconds() + ttl_seconds)
}

@external(erlang, "cache_ffi", "insert_cname")
fn do_set_cname(qname: String, target: String, expiry: Int) -> Nil

@external(erlang, "cache_ffi", "lookup_cname")
pub fn get_cname(qname: String) -> Result(List(#(String, Int)), CacheError)

@external(erlang, "cache_ffi", "delete_cname")
pub fn delete_cname(qname: String) -> Nil

@external(erlang, "cache_ffi", "cleanup_expired")
fn cleanup_expired() -> Nil

@external(erlang, "cache_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
