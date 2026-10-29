import armadillo/server/dns/protocol as dns
import armadillo/shared/records
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

pub type CacheError {
  NotFound
  Expired
}

@external(erlang, "cache_ffi", "new")
pub fn init() -> Nil

@external(erlang, "cache_ffi", "replace_local")
pub fn replace_local(records: List(records.Record)) -> Nil

@external(erlang, "cache_ffi", "replace_domain")
pub fn replace_domain(name: String, records: List(records.Record)) -> Nil

type Cleanup {
  Cleanup
}

pub fn worker() -> supervision.ChildSpecification(Nil) {
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

pub fn store_response(response: dns.Response) -> Nil {
  case response.rcode == dns.NoError && !response.truncated {
    True ->
      response.answers
      |> list.filter_map(dns.resource_record_to_record)
      |> replace_upstream
    False -> Nil
  }
}

@external(erlang, "cache_ffi", "replace_upstream")
fn replace_upstream(records: List(records.Record)) -> Nil

@external(erlang, "cache_ffi", "lookup")
pub fn get(
  name: String,
  type_: dns.Type,
) -> Result(List(records.Record), CacheError)

@external(erlang, "cache_ffi", "cleanup_expired")
fn cleanup_expired() -> Nil
