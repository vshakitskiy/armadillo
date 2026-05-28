-module(cache_ffi).

-export([new/1, insert/5, lookup/3, delete/3]).

new(TableName) ->
    ets:new(TableName,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]).

insert(Table, QName, QType, Ip, ExpiryTime) ->
    ets:insert(Table, {{QName, QType}, Ip, ExpiryTime}),
    nil.

lookup(Table, QName, QType) ->
    case ets:lookup(Table, {QName, QType}) of
        [{{QName, QType}, Ip, ExpiryTime}] ->
            CurrentTime = os:system_time(second),
            if CurrentTime < ExpiryTime ->
                   {ok, Ip};
               true ->
                   ets:delete(Table, {QName, QType}),
                   {error, expired}
            end;
        [] ->
            {error, not_found}
    end.

delete(Table, QName, QType) ->
    ets:delete(Table, {QName, QType}),
    ok.
