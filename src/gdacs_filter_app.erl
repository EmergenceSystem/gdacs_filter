-module(gdacs_filter_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% Cowboy handler callbacks
-export([init/2, terminate/3]).

-define(SEARCH_URL, "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(gdacs_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% Cowboy handler behavior
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),

    %% Print the full JSON response right here
    io:format("Response JSON: ~s~n", [EncodedResponse]),

    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

generate_embryo_list(JsonBinary) ->
    CurrentDate = calendar:local_time(),
    {{Year, Month, Day}, _} = CurrentDate,
    CurrentDateFormatted = lists:flatten(io_lib:format("~4..0w-~2..0w-~2..0w", [Year, Month, Day])),
    
    SevenDaysAgo = calendar:gregorian_days_to_date(
        calendar:date_to_gregorian_days({Year, Month, Day}) - 7
    ),
    {SevenYear, SevenMonth, SevenDay} = SevenDaysAgo,
    SevenDaysAgoFormatted = lists:flatten(io_lib:format("~4..0w-~2..0w-~2..0w", [SevenYear, SevenMonth, SevenDay])),
    
    SearchUrl = lists:concat([?SEARCH_URL, "?fromDate=", SevenDaysAgoFormatted, 
                             "&toDate=", CurrentDateFormatted, 
                             "&alertlevel=orange;red&eventlist=&country="]),
    
    io:format("Search URL: ~s~n", [SearchUrl]),
    
    case httpc:request(get, {SearchUrl, []}, [{ssl, [{verify, verify_none}, {cacerts, public_key:cacerts_get()}]}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_links_from_results(Body, JsonBinary);
        {error, Reason} ->
            io:format("Error fetching search results: ~p~n", [Reason]),
            []
    end.

extract_links_from_results(JsonData, JsonSearch) ->
    Search = case jsone:decode(JsonSearch, [{keys, atom}]) of
        SearchMap when is_map(SearchMap) ->
            Value = binary_to_list(maps:get(value, SearchMap, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, SearchMap, <<"10">>))),
            {Value, Timeout};
        _ ->
            {"", 10}
    end,
    
    {SearchValue, TimeoutSecs} = Search,
    io:format("Search value: ~p~n", [SearchValue]),
    
    try jsone:decode(JsonData) of
        ParsedJson ->
            Features = case maps:get(<<"features">>, ParsedJson, []) of
                FeaturesList when is_list(FeaturesList) -> FeaturesList;
                _ -> []
            end,
            
            StartTime = erlang:system_time(second),
            process_features(Features, SearchValue, StartTime, TimeoutSecs, [])
    catch
        _:Error ->
            io:format("Error parsing JSON: ~p~n", [Error]),
            []
    end.

process_features([], _SearchValue, _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
process_features([Feature | Rest], SearchValue, StartTime, Timeout, Acc) ->
    CurrentTime = erlang:system_time(second),
    case CurrentTime - StartTime >= Timeout of
        true ->
            lists:reverse(Acc);
        false ->
            Properties = maps:get(<<"properties">>, Feature, #{}),
            Name = binary_to_list(maps:get(<<"name">>, Properties, <<"">>)),
            Country = binary_to_list(maps:get(<<"country">>, Properties, <<"">>)),
            FromDate = binary_to_list(maps:get(<<"fromdate">>, Properties, <<"">>)),
            
            UrlMap = maps:get(<<"url">>, Properties, #{}),
            Url = binary_to_list(maps:get(<<"report">>, UrlMap, <<"N/A">>)),
            
            case contains_any(SearchValue, [Name, Country, FromDate]) of
                true ->
                    Resume = lists:concat([Name, " : ", Country, " - from ", FromDate]),
                    Embryo = #{
                        properties => #{
                            <<"url">> => list_to_binary(Url),
                            <<"resume">> => list_to_binary(Resume)
                        }
                    },
                    process_features(Rest, SearchValue, StartTime, Timeout, [Embryo | Acc]);
                false ->
                    process_features(Rest, SearchValue, StartTime, Timeout, Acc)
            end
    end.

contains_any(SearchValue, Targets) ->
    lists:any(fun(Target) ->
        string:str(string:to_lower(SearchValue), string:to_lower(Target)) > 0 orelse
        string:str(string:to_lower(Target), string:to_lower(SearchValue)) > 0
    end, Targets).
