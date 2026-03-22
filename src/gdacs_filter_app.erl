%%%-------------------------------------------------------------------
%%% @doc GDACS disaster alert agent.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(gdacs_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL,
    "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"gdacs">>, <<"disasters">>,
                                      <<"alerts">>, <<"realtime">>,
                                      <<"geopolitics">>].

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(gdacs_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(gdacs_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    SearchUrl = build_search_url(),
    SslOpts = [{ssl, [{verify, verify_none},
                      {cacerts, public_key:cacerts_get()}]}],
    case httpc:request(get, {SearchUrl, [{"User-Agent", "Mozilla/5.0"}]},
                       SslOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_events(Body, Value, Timeout);
        {ok, {{_, Status, Reason}, _, _}} ->
            io:format("[gdacs] HTTP error: ~p ~p~n", [Status, Reason]),
            [];
        {error, Reason} ->
            io:format("[gdacs] request failed: ~p~n", [Reason]),
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
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
    Props       = maps:get(<<"properties">>, Feature, #{}),
    Name        = binary_to_list(maps:get(<<"name">>,        Props, <<"">>)),
    Country     = binary_to_list(maps:get(<<"country">>,     Props, <<"">>)),
    FromDate    = binary_to_list(maps:get(<<"fromdate">>,     Props, <<"">>)),
    EventType   = binary_to_list(maps:get(<<"eventtype">>,   Props, <<"">>)),
    AlertLevel  = binary_to_list(maps:get(<<"alertlevel">>,  Props, <<"">>)),
    Description = binary_to_list(maps:get(<<"description">>, Props, <<"">>)),
    UrlMap      = maps:get(<<"url">>, Props, #{}),
    Url         = maps:get(<<"report">>, UrlMap, <<"N/A">>),
    Targets     = [Name, Country, FromDate, EventType, AlertLevel, Description],
    case contains_any(SearchValue, Targets) of
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

contains_any("", _Targets) -> true;
contains_any(SearchValue, Targets) ->
    Low = string:to_lower(SearchValue),
    lists:any(fun(T) ->
        string:str(string:to_lower(T), Low) > 0
    end, Targets).

fmt(F, A) -> lists:flatten(io_lib:format(F, A)).
