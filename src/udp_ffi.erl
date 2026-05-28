-module(udp_ffi).

-export([open_udp/2, coerce_socket_message/1, set_active/1, parse_address/1, send_udp/4]).

open_udp(Port, Options) ->
    gen_udp:open(Port, [binary | to_erl_options(Options)]).

coerce_socket_message({udp, Socket, {A, B, C, D}, Port, Data}) ->
    {packet, {peer, Socket, {ip_v4, A, B, C, D}, Port}, Data};
coerce_socket_message({udp, Socket, {A, B, C, D, E, F, G, H}, Port, Data}) ->
    {packet, {peer, Socket, {ip_v6, A, B, C, D, E, F, G, H}, Port}, Data}.

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
to_erl_option({ip, {address, {ip_v4, A, B, C, D}}}) ->
    {ip, {A, B, C, D}};
to_erl_option({ip, {address, {ip_v6, A, B, C, D, E, F, G, H}}}) ->
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
            {ok, {ip_v4, A, B, C, D}};
        {ok, {A, B, C, D, E, F, G, H}} ->
            {ok, {ip_v6, A, B, C, D, E, F, G, H}};
        {error, _Reason} ->
            {error, nil}
    end.

send_udp(Socket, {ip_v4, A, B, C, D}, Port, Data) ->
    gen_udp:send(Socket, {A, B, C, D}, Port, Data);
send_udp(Socket, {ip_v6, A, B, C, D, E, F, G, H}, Port, Data) ->
    gen_udp:send(Socket, {A, B, C, D, E, F, G, H}, Port, Data).

set_active(Socket) ->
    case inet:setopts(Socket, [{active, once}]) of
        ok ->
            {ok, nil};
        {error, Reason} ->
            {error, Reason}
    end.
