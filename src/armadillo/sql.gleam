import gleam/dynamic/decode
import gleam/result
import sqlight

pub type Record {
  Record(domain: String, ip: String)
}

fn record_decoder() -> decode.Decoder(Record) {
  use domain <- decode.field(0, decode.string)
  use ip <- decode.field(1, decode.string)
  decode.success(Record(domain:, ip:))
}

pub fn open() -> sqlight.Connection {
  let assert Ok(conn) = sqlight.open("file:./data/records.sqlite3")

  let query =
    "create table if not exists records (
      id integer primary key autoincrement,
      domain text not null unique,
      ip text not null
    );"

  let assert Ok(Nil) = sqlight.exec(query, conn)

  conn
}

pub fn get_records(
  conn: sqlight.Connection,
) -> Result(List(Record), sqlight.Error) {
  let query = "select domain, ip from records;"
  sqlight.query(query, on: conn, with: [], expecting: record_decoder())
}

pub fn insert_record(
  conn: sqlight.Connection,
  domain: String,
  ip: String,
) -> Result(Nil, sqlight.Error) {
  let query = "insert into records (domain, ip) values (?, ?);"
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(domain), sqlight.text(ip)],
    expecting: decode.dynamic,
  )
  |> result.replace(Nil)
}

pub fn update_record(
  conn: sqlight.Connection,
  domain: String,
  ip: String,
) -> Result(Nil, sqlight.Error) {
  let query = "update records set ip = ? where domain = ?;"
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(ip), sqlight.text(domain)],
    expecting: decode.dynamic,
  )
  |> result.replace(Nil)
}

pub fn delete_record(
  conn: sqlight.Connection,
  domain: String,
) -> Result(Nil, sqlight.Error) {
  let query = "delete from records where domain = ?;"
  sqlight.query(
    query,
    on: conn,
    with: [sqlight.text(domain)],
    expecting: decode.dynamic,
  )
  |> result.replace(Nil)
}
