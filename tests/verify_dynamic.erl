-module(verify_dynamic).
-export([verify_dynamic/0]).
-include_lib("eunit/include/eunit.hrl").

set_bucket(Node, Bucket, BucketProps) ->
    rpc:call(Node, riak_core_bucket, set_bucket, [Bucket, BucketProps]).

verify_dynamic() ->
    %% Nodes = rt:deploy_nodes(3),
    Nodes = rt:build_cluster(4),
    [Node1|_] = Nodes,

    %% Verify there there are no bad preflists
    lager:info("Verify there are no bad preflists"),
    ?assertEqual([], rpc:call(Node1, riak_core_ring_util, check_ring, [])),

    %% Setup buckets for dynamic riak_kv test
    lager:info("Setting up buckets for dynamic riak_kv test"),
    set_bucket(Node1, <<"n3allowmult322">>,
               [{allow_mult,true}, {n_val,3}]),
    set_bucket(Node1, <<"n3allowmult313">>,
               [{allow_mult,true}, {n_val,3}, {r,1}, {dw,3}]),
    set_bucket(Node1, <<"n1allowmult322">>,
               [{allow_mult,true}, {n_val,1}]),

    %% P = open_port({spawn, "$HOME/basho/basho_bench/basho_bench ./dynamic/kv2/populate-n1allowmult322.config"},
    %%               [exit_status]),
    %% wait_until_exit(P),
    %% catch port_close(P),
    Bench = "$HOME/basho/basho_bench/basho_bench",
    Runner = Bench ++ " ./dynamic/kv2/",
    %% lager:info("Populating n1/322 bucket"),
    %% ?assertEqual(0, cmd(Runner ++ "populate-n1allowmult322.config")),
    %% lager:info("Populating n3/322 bucket"),
    %% ?assertEqual(0, cmd(Runner ++ "populate-n3allowmult322.config")),
    lager:info("Populating n3/313 bucket"),
    ?assertEqual(0, cmd(Runner ++ "populate-n3allowmult313.config")),

    %% lager:info("Verifying n1/322 bucket"),
    %% ?assertEqual(0, cmd(Runner ++ "verify-n1allowmult322.config")),

    %% lager:info("Stopping 2 nodes and verify n1/322 fails"),
    %% [rt:stop(Node) || Node <- tl(Nodes)],
    lager:info("Stopping 1 node and verify n1/322 fails"),
    rt:stop(lists:nth(2,Nodes)),
    %% ?assertEqual(1, cmd(Runner ++ "verify-n1allowmult322.config")),

    %% lager:info("Verify n3/313 passes"),
    %% ?assertEqual(0, cmd(Runner ++ "verify-n3allowmult313.config")),
    ?assertEqual(ok, rt:wait_until(node(),
                  fun(_) ->
                          lager:info("Running basho_bench verify-n3allowmult313.config"),
                          case cmd(Runner ++ "verify-n3allowmult313.config") of
                              0 ->
                                  true;
                              1 ->
                                  cmd(Runner ++ "verify-n3allowmult313-nf.config"),
                                  false
                          end
                  end)),

    %% lager:info("Verify n3/322 fails"),
    %% ?assertEqual(1, cmd(Runner ++ "verify-n3allowmult322.config")),

    lager:info("verify_dynamic: PASS"),
    %% Status = cmd(" "
    %%              "./dynamic/kv2/populate-n1allowmult322.config"),
    %% ?assertEqual(0, Status),

    ok.

cmd(Cmd) ->
    Port = open_port({spawn, Cmd}, [exit_status]),
    rt:wait_until(node(),
                  fun(_) ->
                          receive
                              {Port, Msg={exit_status, _}} ->
                                  catch port_close(Port),
                                  self() ! {Port, Msg},
                                  true
                          after 0 ->
                                  false
                          end
                  end),
    receive
        {Port, {exit_status, Status}} ->
            Status
    after 0 ->
            timeout
    end.

%% cmd(Cmd) ->
%%     Port = open_port({spawn, Cmd}, [exit_status]),
%%     receive
%%         {Port, {exit_status, Status}} ->
%%             catch port_close(Port),
%%             Status
%%     after 10000 ->
%%             throw(timeout)
%%     end.

%% wait_until_exit(Port) ->
%%     receive
%%         {Port, Msg} ->
%%             io:format("~p~n", [Msg]),
%%             case Msg of
%%                 {exit_status, _} ->
%%                     ok;
%%                 _ ->
%%                     wait_until_exit(Port)
%%             end
%%     after 5000 ->
%%             ok
%%     end.
