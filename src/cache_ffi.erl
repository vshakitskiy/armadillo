-module(cache_ffi).

-export([new/0, insert/4, lookup/2, delete/2, insert_cname/3, lookup_cname/1,
         delete_cname/1, system_time_seconds/0]).

new() ->
    ets:new(dns,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]),
    ets:new(dns_cname,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]),
    nil.

insert(QName, QType, Ip, Expiry) ->
    ets:insert(dns, {{QName, QType, Ip}, Expiry}),
    nil.

lookup(QName, QType) ->
    Now = erlang:system_time(second),
    Matches = ets:match_object(dns, {{QName, QType, '_'}, '_'}),
    Valid = [{entry, Ip, Expiry - Now} || {{_, _, Ip}, Expiry} <- Matches, Expiry - Now > 0],
    case Valid of
        [] ->
            case Matches of
                [] ->
                    {error, not_found};
                _ ->
                    {error, expired}
            end;
        _ ->
            {ok, {record, Valid}}
    end.

delete(QName, QType) ->
    ets:match_delete(dns, {{QName, QType, '_'}, '_'}),
    nil.

insert_cname(QName, Target, Expiry) ->
    ets:insert(dns_cname, {{QName, Target}, Expiry}),
    nil.

lookup_cname(QName) ->
    Now = erlang:system_time(second),
    Matches = ets:match_object(dns_cname, {{QName, '_'}, '_'}),
    Valid = [{Target, Expiry - Now} || {{_, Target}, Expiry} <- Matches, Expiry - Now > 0],
    case Valid of
        [] ->
            case Matches of
                [] ->
                    {error, not_found};
                _ ->
                    {error, expired}
            end;
        _ ->
            {ok, Valid}
    end.

delete_cname(QName) ->
    ets:match_delete(dns_cname, {{QName, '_'}, '_'}),
    nil.

system_time_seconds() ->
    erlang:system_time(second).
