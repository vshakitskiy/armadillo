# Armadillo

A DNS server for my local network, powered by Gleam.

## The Vision

The plan is to build a recursive resolver with local overrides. It will use SQLite for persistent record storage and ETS for in-memory caching. Management will happen via a simple HTTP API.

## Binding to default DNS port without sudo

To bind to port 53 without sudo, I run setcap on the beam binary.
```sh
# To find the beam binary:
$(which erl) -noshell -eval 'io:format("~s~n",[os:find_executable("beam.smp")]),halt().'
# > /path/to/beam.smp

# And then:
sudo setcap cap_net_bind_service=+ep /path/to/beam.smp
```