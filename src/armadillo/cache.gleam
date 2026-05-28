import armadillo/dns
import armadillo/udp
import gleam/erlang/atom
import gleam/erlang/process

pub opaque type Cache {
  Cache(name: atom.Atom)
}

pub type CacheError {
  NotFound
  Expired
}

@external(erlang, "cache_ffi", "new")
fn ffi_new(name: atom.Atom) -> Nil

@external(erlang, "cache_ffi", "insert")
fn ffi_insert(
  table: atom.Atom,
  qname: String,
  qtype: dns.Type,
  ip: udp.IpAddress,
  expiry: Int,
) -> Nil

@external(erlang, "cache_ffi", "lookup")
fn ffi_lookup(
  table: atom.Atom,
  qname: String,
  qtype: dns.Type,
) -> Result(udp.IpAddress, CacheError)

@external(erlang, "cache_ffi", "delete")
fn ffi_delete(table: atom.Atom, qname: String, qtype: dns.Type) -> Nil

pub fn new(name: process.Name(a)) -> Cache {
  let atom = to_atom(name)

  ffi_new(atom)
  Cache(atom)
}

@external(erlang, "gleam@function", "identity")
fn to_atom(name: process.Name(a)) -> atom.Atom

pub fn set(
  cache: Cache,
  qname: String,
  qtype: dns.Type,
  ip: udp.IpAddress,
  ttl_seconds: Int,
) {
  let expiry_time = system_time_seconds() + ttl_seconds
  ffi_insert(cache.name, qname, qtype, ip, expiry_time)
}

pub fn get(
  cache: Cache,
  qname: String,
  qtype: dns.Type,
) -> Result(udp.IpAddress, CacheError) {
  ffi_lookup(cache.name, qname, qtype)
}

pub fn delete(cache: Cache, qname: String, qtype: dns.Type) -> Nil {
  ffi_delete(cache.name, qname, qtype)
}

@external(erlang, "os", "system_time")
fn system_time_seconds() -> Int
