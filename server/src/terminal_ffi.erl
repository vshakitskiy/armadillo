-module(terminal_ffi).

-export([clear/0]).

clear() ->
    io:format("\e[2J\e[H"),
    nil.
