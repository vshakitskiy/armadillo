-module(udp_ffi).

-export([open_udp/2, recv_udp/2, close_udp/1, coerce_socket_message/1, set_active/1,
         parse_address/1, send_udp/4, sockname/1]).

open_udp(Port, Options) ->
    gen_udp:open(Port, [binary | to_erl_options(Options)]).

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
    gen_udp:close(Socket).

coerce_socket_message({udp, Socket, {A, B, C, D}, Port, Data}) ->
    {packet, {peer, Socket, {v4, {ipv4, A, B, C, D}}, Port}, Data};
coerce_socket_message({udp, Socket, {A, B, C, D, E, F, G, H}, Port, Data}) ->
    {packet, {peer, Socket, {v6, {ipv6, A, B, C, D, E, F, G, H}}, Port}, Data}.

to_erl_options(Options) ->
    lists:map(fun(A) -> to_erl_option(A) end, Options).

to_erl_option({active_mode, once}) ->
    {active, once};
to_erl_option({active_mode, passive}) ->
    {active, false};
to_erl_option({active_mode, active}) ->
    {active, true};
to_erl_option({active_mode, {count, N}}) ->
    {active, N};
to_erl_option({ip, {address, {v4, {ipv4, A, B, C, D}}}}) ->
    {ip, {A, B, C, D}};
to_erl_option({ip, {address, {v6, {ipv6, A, B, C, D, E, F, G, H}}}}) ->
    {ip, {A, B, C, D, E, F, G, H}};
to_erl_option(ipv6) ->
    inet6;
to_erl_option({ipv6_only, V}) ->
    {ipv6_v6only, V};
to_erl_option({receive_buffer, N}) ->
    {recbuf, N};
to_erl_option({send_buffer, N}) ->
    {sndbuf, N};
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
    gen_udp:send(Socket, {A, B, C, D}, Port, Data);
send_udp(Socket, {v6, {ipv6, A, B, C, D, E, F, G, H}}, Port, Data) ->
    gen_udp:send(Socket, {A, B, C, D, E, F, G, H}, Port, Data).

set_active(Socket) ->
    case inet:setopts(Socket, [{active, once}]) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, Reason}
    end.

sockname(Socket) ->
    case inet:sockname(Socket) of
        {ok, {{A, B, C, D}, Port}} ->
            {ok, {{v4, {ipv4, A, B, C, D}}, Port}};
        {ok, {{A, B, C, D, E, F, G, H}, Port}} ->
            {ok, {{v6, {ipv6, A, B, C, D, E, F, G, H}}, Port}};
        {error, Reason} ->
            {error, Reason}
    end.
