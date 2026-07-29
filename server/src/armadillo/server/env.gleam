import envoy
import logging

pub fn get_or(
  key: String,
  parse parse: fn(String) -> Result(a, Nil),
  or default: a,
  log default_string: String,
) {
  case envoy.get(key) {
    Ok(value) -> {
      case parse(value) {
        Ok(value) -> value
        Error(Nil) -> {
          logging.log(
            logging.Warning,
            "Invalid "
              <> key
              <> " provided, using default value: "
              <> default_string,
          )

          default
        }
      }
    }
    Error(Nil) -> {
      logging.log(
        logging.Warning,
        "No " <> key <> " provided, using default value: " <> default_string,
      )

      default
    }
  }
}
