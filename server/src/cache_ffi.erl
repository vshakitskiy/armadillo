-module(cache_ffi).

-export([new/0, replace_local/1, replace_domain/2, replace_upstream/1, lookup/2,
         cleanup_expired/0, system_time_seconds/0]).

new() ->
    ets:new(dns, [
        set,
        public,
        named_table,
        {read_concurrency, true},
        {write_concurrency, auto}
    ]),
    nil.

replace_local(Records) ->
    Groups = maps:groups_from_list(fun record_name/1, Records),
    PreviousNames = [
        Name || {{local, Name}, _Records} <- ets:match_object(dns, {{local, '_'}, '_'})
    ],
    Names = lists:usort(PreviousNames ++ maps:keys(Groups)),

    lists:foreach(
        fun(Name) -> replace_domain(Name, maps:get(Name, Groups, [])) end,
        Names
    ),
    nil.

replace_domain(Name, Records) ->
    case Records of
        [] ->
            ets:match_delete(dns, {{upstream, Name, '_'}, '_'}),
            ets:delete(dns, {local, Name});
        _Records -> ets:insert(dns, {{local, Name}, Records})
    end,
    nil.

record_type({a_record, _Name, _Ttl, _Ip}) -> a;
record_type({aaaa_record, _Name, _Ttl, _Ip}) -> aaaa;
record_type({cname_record, _Name, _Ttl, _Target}) -> cname.

record_name({a_record, Name, _Ttl, _Ip}) -> Name;
record_name({aaaa_record, Name, _Ttl, _Ip}) -> Name;
record_name({cname_record, Name, _Ttl, _Target}) -> Name.

record_ttl({a_record, _Name, Ttl, _Ip}) -> Ttl;
record_ttl({aaaa_record, _Name, Ttl, _Ip}) -> Ttl;
record_ttl({cname_record, _Name, Ttl, _Target}) -> Ttl.

with_ttl({a_record, Name, _PreviousTtl, Ip}, Ttl) ->
    {a_record, Name, Ttl, Ip};
with_ttl({aaaa_record, Name, _PreviousTtl, Ip}, Ttl) ->
    {aaaa_record, Name, Ttl, Ip};
with_ttl({cname_record, Name, _PreviousTtl, Target}, Ttl) ->
    {cname_record, Name, Ttl, Target}.

replace_upstream(Records) ->
    Groups = maps:groups_from_list(
        fun(Record) -> {record_name(Record), record_type(Record)} end,
        Records
    ),
    Now = system_time_seconds(),
    Entries = maps:fold(
        fun({Name, Type}, Group, Acc) ->
            Ttl = lists:min([cache_ttl(Record) || Record <- Group]),
            [{{upstream, Name, Type}, {Now + Ttl, Group}} | Acc]
        end,
        [],
        Groups
    ),

    ets:insert(dns, Entries),
    nil.

cache_ttl(Record) ->
    case record_ttl(Record) of
        Ttl when Ttl >= 0, Ttl =< 2147483647 -> Ttl;
        _InvalidTtl -> 0
    end.

lookup(Name, Type) ->
    case ets:lookup(dns, {local, Name}) of
        [{_Key, Records}] ->
            case [Record || Record <- Records, record_type(Record) =:= Type] of
                [] -> {error, not_found};
                Matching -> {ok, Matching}
            end;
        [] -> lookup_upstream(Name, Type)
    end.

lookup_upstream(Name, Type) ->
    Now = system_time_seconds(),

    case ets:lookup(dns, {upstream, Name, Type}) of
        [{_Key, {Expiry, Records}}] when Expiry > Now ->
            {ok, [with_ttl(Record, Expiry - Now) || Record <- Records]};
        [{_Key, _Expired}] -> {error, expired};
        [] -> {error, not_found}
    end.

cleanup_expired() ->
    Now = system_time_seconds(),

    ets:select_delete(dns, [
        {{{upstream, '_', '_'}, {'$1', '_'}}, [{'=<', '$1', Now}], [true]}
    ]),
    nil.

system_time_seconds() ->
    erlang:system_time(second).
