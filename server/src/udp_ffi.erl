-module(udp_ffi).

-export([open_udp/2, recv_udp/2, close_udp/1, coerce_socket_message/1, set_active/1,
         parse_address/1, send_udp/4, sockname/1]).

open_udp(Port, Options) when is_integer(Port), Port >= 0, Port =< 65535 ->
    try gen_udp:open(Port, [binary | to_erl_options(Options)])
    catch
        error:badarg -> {error, bad_argument}
    end;
open_udp(_Port, _Options) -> {error, bad_argument}.

recv_udp(Socket, Timeout) ->
    case gen_udp:recv(Socket, 0, Timeout) of
        {ok, {{A, B, C, D}, Port, Data}} ->
            {ok, {{peer, Socket, {v4, {ipv4, A, B, C, D}}, Port}, Data}};
        {ok, {{A, B, C, D, E, F, G, H}, Port, Data}} ->
            {ok, {{peer, Socket, {v6, {ipv6, A, B, C, D, E, F, G, H}}, Port}, Data}};
        {error, Reason} ->
            {error, Reason}
    end.

close_udp(Socket) ->
    gen_udp:close(Socket),
    nil.

coerce_socket_message({udp, Socket, {A, B, C, D}, Port, Data}) ->
    {packet, {peer, Socket, {v4, {ipv4, A, B, C, D}}, Port}, Data};
coerce_socket_message({udp, Socket, {A, B, C, D, E, F, G, H}, Port, Data}) ->
    {packet, {peer, Socket, {v6, {ipv6, A, B, C, D, E, F, G, H}}, Port}, Data}.

to_erl_options(Options) ->
    lists:map(fun to_erl_option/1, Options).

to_erl_option({active_mode, once}) ->
    {active, once};
to_erl_option({active_mode, passive}) ->
    {active, false};
to_erl_option({active_mode, active}) ->
    {active, true};
to_erl_option({active_mode, {count, Count}}) ->
    {active, Count};
to_erl_option({ip, {address, {v4, {ipv4, A, B, C, D}}}}) ->
    {ip, {A, B, C, D}};
to_erl_option({ip, {address, {v6, {ipv6, A, B, C, D, E, F, G, H}}}}) ->
    {ip, {A, B, C, D, E, F, G, H}};
to_erl_option(ipv6) ->
    inet6;
to_erl_option({ipv6_only, Enabled}) ->
    {ipv6_v6only, Enabled};
to_erl_option({receive_buffer, Size}) ->
    {recbuf, Size};
to_erl_option({send_buffer, Size}) ->
    {sndbuf, Size};
to_erl_option(reuse_address) ->
    {reuseaddr, true};
to_erl_option(Other) ->
    Other.

parse_address(Address) ->
    case inet:parse_address(Address) of
        {ok, {A, B, C, D}} ->
            {ok, {v4, {ipv4, A, B, C, D}}};
        {ok, {A, B, C, D, E, F, G, H}} ->
            {ok, {v6, {ipv6, A, B, C, D, E, F, G, H}}};
        {error, _Reason} ->
            {error, nil}
    end.

send_udp(Socket, {v4, {ipv4, A, B, C, D}}, Port, Data) ->
    send_to(Socket, {A, B, C, D}, Port, Data);
send_udp(Socket, {v6, {ipv6, A, B, C, D, E, F, G, H}}, Port, Data) ->
    send_to(Socket, {A, B, C, D, E, F, G, H}, Port, Data).

send_to(Socket, Address, Port, Data) when is_integer(Port), Port >= 0, Port =< 65535 ->
    try socket_result(gen_udp:send(Socket, Address, Port, Data))
    catch
        error:badarg -> {error, bad_argument}
    end;
send_to(_Socket, _Address, _Port, _Data) -> {error, bad_argument}.

set_active(Socket) ->
    socket_result(inet:setopts(Socket, [{active, once}])).

socket_result(ok) -> {ok, nil};
socket_result({error, Reason}) -> {error, Reason}.

sockname(Socket) ->
    case inet:sockname(Socket) of
        {ok, {{A, B, C, D}, Port}} ->
            {ok, {{v4, {ipv4, A, B, C, D}}, Port}};
        {ok, {{A, B, C, D, E, F, G, H}, Port}} ->
            {ok, {{v6, {ipv6, A, B, C, D, E, F, G, H}}, Port}};
        {error, Reason} ->
            {error, Reason}
    end.
