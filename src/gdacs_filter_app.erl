%%%-------------------------------------------------------------------
%%% @doc GDACS disaster alert agent.
%%%
%%% As an agent this module:
%%%   - Announces capabilities to em_disco on startup via `agent_hello'.
%%%   - Maintains a memory of event URLs already returned, so
%%%     duplicate alerts across successive queries are filtered out.
%%%
%%% Handler contract: `handle/2' (Body, Memory) -> {RawList, NewMemory}.
%%% Returns a raw Erlang list — em_filter_server encodes it.
%%% Memory schema: `#{seen => #{binary_url => true}}'.
%%% @end
%%%-------------------------------------------------------------------
-module(gdacs_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1, handle/2]).

-define(SEARCH_URL,
    "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH").

-define(CAPABILITIES, [
    <<"gdacs">>,
    <<"disasters">>,
    <<"alerts">>,
    <<"realtime">>,
    <<"geopolitics">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(gdacs_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_filter(gdacs_filter).

%%====================================================================
%% Agent handler — with memory (primary path)
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Plain filter handler — backward compatibility
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing (unchanged)
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    SearchUrl        = build_search_url(),
    SslOpts          = [{ssl, [{verify, verify_none},
                               {cacerts, public_key:cacerts_get()}]}],
    case httpc:request(get, {SearchUrl, [{"User-Agent", "Mozilla/5.0"}]},
                       SslOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_events(Body, Value, Timeout);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

build_search_url() ->
    {{Year, Month, Day}, _} = calendar:local_time(),
    Today    = fmt("~4..0w-~2..0w-~2..0w", [Year, Month, Day]),
    {SY, SM, SD} = calendar:gregorian_days_to_date(
        calendar:date_to_gregorian_days({Year, Month, Day}) - 7),
    SevenAgo = fmt("~4..0w-~2..0w-~2..0w", [SY, SM, SD]),
    lists:concat([?SEARCH_URL,
                  "?fromDate=", SevenAgo,
                  "&toDate=",   Today,
                  "&alertlevel=orange%3Bred&eventlist=&country="]).

parse_events(JsonData, SearchValue, TimeoutSecs) ->
    try json:decode(JsonData) of
        #{<<"features">> := Features} when is_list(Features) ->
            StartTime = erlang:system_time(second),
            process_features(Features, SearchValue, StartTime, TimeoutSecs, []);
        _ ->
            []
    catch
        _:_ -> []
    end.

process_features([], _Value, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
process_features([Feature | Rest], Value, Start, Timeout, Acc) ->
    case erlang:system_time(second) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = case process_feature(Feature, Value) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_features(Rest, Value, Start, Timeout, NewAcc)
    end.

process_feature(Feature, SearchValue) ->
    Props    = maps:get(<<"properties">>, Feature, #{}),
    Name     = binary_to_list(maps:get(<<"name">>,     Props, <<"">>)),
    Country  = binary_to_list(maps:get(<<"country">>,  Props, <<"">>)),
    FromDate = binary_to_list(maps:get(<<"fromdate">>, Props, <<"">>)),
    UrlMap   = maps:get(<<"url">>, Props, #{}),
    Url      = maps:get(<<"report">>, UrlMap, <<"N/A">>),
    case contains_any(SearchValue, [Name, Country, FromDate]) of
        true ->
            Resume = list_to_binary(
                lists:concat([Name, " : ", Country, " - from ", FromDate])),
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => Url,
                    <<"resume">> => Resume
                }
            }};
        false ->
            skip
    end.

contains_any(SearchValue, Targets) ->
    Low = string:to_lower(SearchValue),
    lists:any(fun(T) ->
        LowT = string:to_lower(T),
        string:str(Low, LowT) > 0 orelse string:str(LowT, Low) > 0
    end, Targets).

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).

%%====================================================================
%% Internal helpers
%%====================================================================

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
