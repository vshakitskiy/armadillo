-module(cache_ffi).

-export([new/0, insert/4, lookup/2, delete/2]).

new() ->
    ets:new(dns,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]),
    nil.

insert(QName, QType, Ip, Expiry) ->
    ets:insert(dns, {{QName, QType}, Ip, Expiry}),
    nil.

lookup(QName, QType) ->
    case ets:lookup(dns, {QName, QType}) of
        [{_, Ip, Expiry}] ->
            Remaining = Expiry - erlang:system_time(second),
            case Remaining > 0 of
                true ->
                    {ok, {record, Ip, Remaining}};
                false ->
                    {error, expired}
            end;
        [] ->
            {error, not_found}
    end.

delete(QName, QType) ->
    ets:delete(dns, {QName, QType}),
    nil.
