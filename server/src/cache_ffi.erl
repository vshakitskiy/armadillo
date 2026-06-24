-module(cache_ffi).

-export([new/0, insert/2, insert_with_ttl/2, lookup/2, delete/2, delete_domain/1,
         cleanup_expired/0, system_time_seconds/0]).

new() ->
    ets:new(dns,
            [set, public, named_table, {read_concurrency, true}, {write_concurrency, auto}]),
    nil.

insert({a_record, Name, Ttl, Ip}, Expiry) ->
    ets:insert(dns, {{Name, a, Ip}, {Expiry, Ttl}}),
    nil;
insert({aaaa_record, Name, Ttl, Ip}, Expiry) ->
    ets:insert(dns, {{Name, aaaa, Ip}, {Expiry, Ttl}}),
    nil;
insert({cname_record, Name, Ttl, Target}, Expiry) ->
    ets:insert(dns, {{Name, cname, Target}, {Expiry, Ttl}}),
    nil.

insert_with_ttl(Record, Ttl) ->
    insert(Record, system_time_seconds() + Ttl).

lookup(Name, Type) ->
    Now = system_time_seconds(),
    Matches = ets:match_object(dns, {{Name, Type, '_'}, '_'}),
    Valid =
        [make_record(Name, Type, Value, Expiry, Ttl, Now)
         || {{_, _, Value}, {Expiry, Ttl}} <- Matches, Expiry =:= -1 orelse Expiry - Now > 0],
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

make_record(Name, a, Ip, Expiry, Ttl, Now) ->
    {a_record, Name, remaining(Expiry, Ttl, Now), Ip};
make_record(Name, aaaa, Ip, Expiry, Ttl, Now) ->
    {aaaa_record, Name, remaining(Expiry, Ttl, Now), Ip};
make_record(Name, cname, Target, Expiry, Ttl, Now) ->
    {cname_record, Name, remaining(Expiry, Ttl, Now), Target}.

remaining(-1, Ttl, _Now) ->
    Ttl;
remaining(Expiry, _Ttl, Now) ->
    Expiry - Now.

delete(Name, Type) ->
    ets:match_delete(dns, {{Name, Type, '_'}, '_'}),
    nil.

delete_domain(Name) ->
    ets:match_delete(dns, {{Name, '_', '_'}, '_'}),
    nil.

cleanup_expired() ->
    Now = system_time_seconds(),
    ets:select_delete(dns,
                      [{{{'_', '_', '_'}, {'$1', '_'}},
                        [{'=/=', '$1', -1}, {'<', '$1', Now}],
                        [true]}]),
    nil.

system_time_seconds() ->
    erlang:system_time(second).
