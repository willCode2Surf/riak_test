-module(verify_aae).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

verify_aae() ->
    Nodes = rt:build_cluster(2),
    [Node1, Node2] = Nodes,

    lager:info("Disable handoff to ensure no hinted handoff occurs"),
    NewConfig = [{riak_core, [{handoff_concurrency, 0}]}],
    [rt:update_app_config(Node, NewConfig) || Node <- Nodes],

    lager:info("Write data while ~p is offline", [Node2]),
    rt:stop(Node2),
    ?assertEqual([], rt:systest_write(Node1, 1000, 3)),

    lager:info("Verify that ~p is missing data", [Node2]),
    rt:start(Node2),
    rt:stop(Node1),
    ?assertMatch([{_,{error,notfound}}|_],
                 rt:systest_read(Node2, 1000, 3)),

    lager:info("Trigger anti-entropy"),
    rt:start(Node1),
    timer:sleep(20000),
    %% rpc:call(Node1, riak_kv_vnode, do_exchange, [0]),
    {ok, Ring} = rpc:call(Node1, riak_core_ring_manager, get_my_ring, []),
    {Indices, _} = lists:unzip(riak_core_ring:all_owners(Ring)),
    [rpc:call(Node1, riak_kv_vnode, do_exchange, [Index]) || Index <- Indices],
    timer:sleep(30000),

    lager:info("Verify that no data is missing"),
    rt:stop(Node1),
    ?assertMatch([], rt:systest_read(Node2, 1000, 3)),

    lager:info("Add additional data to test incremental tree"),
    rt:start(Node1),
    rt:stop(Node2),
    ?assertEqual([], rt:systest_write(Node1, 2000, 3)),

    lager:info("Trigger another round of anti-entropy"),
    rt:start(Node2),
    timer:sleep(40000),
    [rpc:call(Node1, riak_kv_vnode, do_exchange, [Index]) || Index <- Indices],
    timer:sleep(90000),

    lager:info("Verify that no data is missing"),
    rt:stop(Node1),
    R = rt:systest_read(Node2, 2000, 3),
    io:format("~w~n", [R]),
    ?assertMatch([], R),

    ok.
