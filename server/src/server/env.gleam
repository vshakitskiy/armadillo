import envoy
import gleam/int
import gleam/result
import wisp

pub fn get_int_or(key: String, or or: Int) {
  use <- result.lazy_unwrap(envoy.get(key) |> result.try(int.parse))

  wisp.log_warning(
    "No " <> key <> " provided, using default value: " <> int.to_string(or),
  )
  or
}

pub fn get_string_or(key: String, or or: String) {
  use <- result.lazy_unwrap(envoy.get(key))

  wisp.log_warning("No " <> key <> " provided, using default value: " <> or)
  or
}
