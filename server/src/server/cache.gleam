import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import server/dns/protocol as dns
import shared/records

pub type CacheError {
  NotFound
  Expired
}

pub fn init(records: List(records.Record)) -> Nil {
  new()
  list.each(records, set)
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

pub fn set(record: records.Record) -> Nil {
  do_insert(record, -1)
}

pub fn set_with_ttl(record: records.Record, ttl: Int) -> Nil {
  do_insert_with_ttl(record, ttl)
}

@external(erlang, "cache_ffi", "insert")
fn do_insert(record: records.Record, expiry: Int) -> Nil

@external(erlang, "cache_ffi", "insert_with_ttl")
fn do_insert_with_ttl(record: records.Record, ttl: Int) -> Nil

@external(erlang, "cache_ffi", "lookup")
pub fn get(
  name: String,
  type_: dns.Type,
) -> Result(List(records.Record), CacheError)

@external(erlang, "cache_ffi", "delete")
pub fn delete(name: String, type_: dns.Type) -> Nil

@external(erlang, "cache_ffi", "delete_domain")
pub fn delete_domain(name: String) -> Nil

@external(erlang, "cache_ffi", "cleanup_expired")
fn cleanup_expired() -> Nil
