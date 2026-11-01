-module(cache_ffi).

-export([new/0, replace_local/1, replace_domain/2, replace_upstream/1, lookup/2,
         cleanup_expired/0, system_time_seconds/0]).

new() ->
    Options = [
        public,
        named_table,
        {read_concurrency, true},
        {write_concurrency, auto}
    ],
    ets:new(dns, [set | Options]),
    ets:new(dns_local, [ordered_set | Options]),
    nil.

replace_local(Records) ->
    Groups = maps:groups_from_list(fun record_name/1, Records),
    PreviousNames = [
        record_name(Record) || {_Key, [Record | _Rest]} <- ets:tab2list(dns_local)
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
            ets:delete(dns_local, local_key(Name));
        _Records -> ets:insert(dns_local, {local_key(Name), Records})
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
    case local_records(name_labels(Name)) of
        {ok, Records} ->
            Matching = [
                with_name(Record, Name) || Record <- Records,
                Type =:= any_type orelse record_type(Record) =:= Type
            ],

            case Matching of
                [] -> {error, no_data};
                Matching -> {ok, Matching}
            end;
        {error, not_found} -> lookup_upstream(Name, Type)
    end.

local_key(Name) ->
    lists:reverse(name_labels(Name)).

name_labels(<<".">>) -> [];
name_labels(Name) -> binary:split(Name, <<".">>, [global]).

local_records(Labels) ->
    case records_at(lists:reverse(Labels)) of
        {ok, Records} -> {ok, Records};
        {error, not_found} ->
            case Labels of
                [_Label | Parent] -> wildcard_records(Parent);
                [] -> {error, not_found}
            end
    end.

records_at(Key) ->
    case ets:lookup(dns_local, Key) of
        [{_Key, Records}] -> {ok, Records};
        [] ->
            case has_descendants(Key) of
                true -> {ok, []};
                false -> {error, not_found}
            end
    end.

has_descendants(Key) ->
    case ets:next(dns_local, Key) of
        '$end_of_table' -> false;
        NextKey -> lists:prefix(Key, NextKey)
    end.

wildcard_records(Labels) ->
    Key = lists:reverse(Labels),

    case ets:member(dns_local, Key) orelse has_descendants(Key) of
        true -> records_at(Key ++ [<<"*">>]);
        false ->
            case Labels of
                [_Label | Parent] -> wildcard_records(Parent);
                [] -> {error, not_found}
            end
    end.

with_name({a_record, _Name, Ttl, Ip}, Name) ->
    {a_record, Name, Ttl, Ip};
with_name({aaaa_record, _Name, Ttl, Ip}, Name) ->
    {aaaa_record, Name, Ttl, Ip};
with_name({cname_record, _Name, Ttl, Target}, Name) ->
    {cname_record, Name, Ttl, Target}.

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
