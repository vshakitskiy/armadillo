-module(cache_ffi).

-export([new/0, insert/4, lookup/2, delete/2, system_time_seconds/0]).

new() ->
    ets:new(dns,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]),
    nil.

insert(QName, QType, Ip, Expiry) ->
    ets:insert(dns, {{QName, QType, Ip}, Expiry}),
    nil.

lookup(QName, QType) ->
    Now = erlang:system_time(second),
    Matches = ets:match_object(dns, {{QName, QType, '_'}, '_'}),
    Valid = [{Ip, Expiry - Now} || {{_, _, Ip}, Expiry} <- Matches, Expiry - Now > 0],
    case Valid of
        [] ->
            case Matches of
                [] -> {error, not_found};
                _  -> {error, expired}
            end;
        _ ->
            {ok, {record, Valid}}
    end.

delete(QName, QType) ->
    ets:match_delete(dns, {{QName, QType, '_'}, '_'}),
    nil.

system_time_seconds() ->
    erlang:system_time(second).
