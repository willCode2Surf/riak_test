-module(verify_dynamic_eqc).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

-record(state,{nodes,
               cluster,
               buckets,
               verify,
               verify_mr,
               stopped}).

-define(BUCKETS, [{<<"n3r2w2">>, [{n_val,3}]},
                  {<<"n3r1w3">>, [{n_val,3}, {r,1}, {dw,3}, {w,3}]},
                  {<<"n1r1w1">>, [{n_val,1}]},
                  {<<"n3r2w2nf">>, [{n_val,3},{notfound_ok,false}]}]).

%% -define(BUCKETS, [{<<"n3r2w2">>, [{n_val,3}]}]).

initial_state() ->
    Buckets = ?BUCKETS,
    #state{nodes=[], cluster=[], stopped=[], buckets=Buckets, verify=[], verify_mr=[]}.

expand_props(Props) ->
    N = proplists:get_value(n_val, Props),
    Quorum = erlang:trunc((N/2)+1),
    Defaults = [{r, Quorum}, {w, Quorum}, {dw, Quorum}, {notfound_ok, true}],
    Props2 = lists:ukeysort(1, Props ++ Defaults),
    Props2.

verify_should_pass(Bucket,
                   #state{nodes=Nodes, cluster=Cluster, stopped=Stopped, buckets=Buckets}) ->
    Props0 = proplists:get_value(Bucket, Buckets),
    Props = expand_props(Props0),
    %% io:format("Bucket: ~p~nProps: ~p~n", [Bucket, Props]),
    N = proplists:get_value(n_val, Props),
    R = proplists:get_value(r, Props),
    FailN = case proplists:get_value(notfound_ok, Props) of
                true ->
                    0;
                false ->
                    N - R
            end,
    FailRepairN = N - R,
    Down = Stopped -- (Nodes -- Cluster),
    DownN = length(Down),
    case {DownN > FailN, DownN > FailRepairN} of
        {false, _} ->
            true;
        {true, false} ->
            repair;
        {true, true} ->
            false
    end.

command(State) ->
    case mochiglobal:get(countercmds) of
        undefined ->
            real_command(State);
        [] ->
            real_command(State);
        [CmdSym|Cs] ->
            {set,_,Cmd} = CmdSym,
            mochiglobal:put(countercmds, Cs),
            %% io:format("C: ~p~n", [Cmd]),
            Cmd
    end.

real_command(#state{nodes=[]}) ->
    {call,?MODULE,build_cluster,[3]};
real_command(#state{nodes=Nodes, cluster=Cluster, stopped=Stopped,
               buckets=Buckets, verify=Verify, verify_mr=VerifyMR}) ->
    {BucketNames, _} = lists:unzip(Buckets),
    Others = Nodes -- Cluster,
    _ = Stopped,
    _ = Verify,
    _ = BucketNames,
    _ = Others,
    frequency(
%% [{3,{call,?MODULE,join,[elements(Others), elements(Cluster)]}} || Others /= []] ++
%% [{3,{call,?MODULE,leave,[elements(Cluster)]}} || length(Cluster) > 1] ++
%% [{3,{call,?MODULE,start,[elements(Stopped)]}} || Stopped /= []] ++
%% [{3,{call,?MODULE,stop,[elements(Cluster)]}} || Cluster /= []] ++
%% [{8,{call,?MODULE,verify,[elements(BucketNames)]}}] ++
%% [{1,{call,?MODULE,check_verify,[elements(Verify)]}} || Verify /= []] ++ []).
[{8,{call,?MODULE,verify_mapred,[]}}] ++
[{1,{call,?MODULE,check_verify_mapred,[elements(VerifyMR)]}} || VerifyMR /= []]).

nodes(Nodes, _Length) when is_list(Nodes) ->
    Nodes;
nodes(Nodes, Length) ->
    %% Symbolic nodes
    [{call,lists,nth,[N, Nodes]} || N <- lists:seq(1,Length)].

next_state(S,V,{call,_,build_cluster,[N]}) ->
    rt:reset_harness(),
    Nodes = nodes(V,N),
    %% Cluster = [hd(Nodes)],
    Cluster = Nodes,
    %% io:format("Cluster: ~p~n", [Cluster]),
    S#state{nodes=Nodes, cluster=Cluster};

next_state(S,_V,{call,_,join,[Node, _]}) ->
    Cluster = [Node | S#state.cluster],
    S#state{cluster=Cluster};

next_state(S,_V,{call,_,leave,[Node]}) ->
    %% Nodes = lists:delete(Node, S#state.nodes),
    Cluster = lists:delete(Node, S#state.cluster),
    Stopped = [Node | S#state.stopped],
    %% S#state{nodes=Nodes, cluster=Cluster, stopped=Stopped};
    S#state{cluster=Cluster, stopped=Stopped};

next_state(S,_V,{call,_,start,[Node]}) ->
    %% Nodes = lists:sort([Node | S#state.nodes]),
    Stopped = lists:delete(Node, S#state.stopped),
    %% S#state{nodes=Nodes, stopped=Stopped};
    S#state{stopped=Stopped};

next_state(S,_V,{call,_,stop,[Node]}) ->
    %% Nodes = lists:delete(Node, S#state.nodes),
    Stopped = [Node | S#state.stopped],
    %% S#state{nodes=Nodes, stopped=Stopped};
    S2 = S#state{stopped=Stopped},

    Verify =
        [case verify_should_pass(Bucket, S2) of
             repair ->
                 Opts2 = ordsets:add_element(repair, Opts),
                 {Bucket, Pid, Opts2};
             _ ->
                 NoChange
         end || NoChange={Bucket,Pid,Opts} <- S2#state.verify],
    S2#state{verify=Verify};

next_state(S,V,{call,_,verify,[Bucket]}) ->
    case verify_should_pass(Bucket, S) of
        repair ->
            Opts = [repair];
        _ ->
            Opts = []
    end,
    Verify = [{Bucket, V, Opts} | S#state.verify],
    S#state{verify=Verify};

next_state(S,_V,{call,_,check_verify,[{Bucket, _, _}]}) ->
    Verify = lists:keydelete(Bucket, 1, S#state.verify),
    S#state{verify=Verify};

next_state(S,V,{call,_,verify_mapred,[]}) ->
    VerifyMR = [V | S#state.verify_mr],
    S#state{verify_mr=VerifyMR};

next_state(S,_V,{call,_,check_verify_mapred,[Pid]}) ->
    VerifyMR = lists:delete(Pid, S#state.verify_mr),
    S#state{verify_mr=VerifyMR};

next_state(S,_V,{call,_,_,_}) ->
    S.

precondition(#state{nodes=[]},{call,_,build_cluster,_}) ->
    true;
precondition(#state{nodes=[]},_) ->
    false;

precondition(S,{call,_,join,[Node, NodeTo]}) ->
    Others = S#state.nodes -- S#state.cluster,
    not lists:member(Node, S#state.stopped) andalso
    %% Don't join while nodes are stopped (or change things to mark them as down)
    (S#state.stopped =:= []) andalso
    lists:member(Node, Others) andalso
    lists:member(NodeTo, S#state.cluster);

precondition(S,{call,_,leave,[Node]}) ->
    T1 = length(S#state.cluster) > 1,
    T2 = lists:member(Node, S#state.cluster),

    %% %% Ensure we don't do transistions that will cause verify failures
    %% NS = next_state(S,ok,{call,?MODULE,leave,[Node]}),
    %% SP = [verify_should_pass(Bucket, NS) || {Bucket, _} <- NS#state.buckets],
    %% %% Allow changes that will require read-repair to occur
    %% T3 = lists:all(fun(V) -> (V == true) or (V == repair) end, SP),
    %% %% Allow changes will only pass without read-repair
    %% %% T3 = lists:all(fun(V) -> V == true end, SP),

    T3 = true,
    %% io:format("S: ~p~n", [S]),
    T4 = (Node /= hd(S#state.nodes)),
    %% T5 = not lists:member(Node, S#state.stopped),
    %% Don't leave while nodes are stopped (or change things to mark them as down)
    T5 = (S#state.stopped =:= []),
    T1 and T2 and T3 and T4 and T5;

precondition(S,{call,_,start,[Node]}) ->
    lists:member(Node, S#state.stopped);

precondition(S,{call,_,stop,[Node]}) ->
    T1 = not lists:member(Node, S#state.stopped),
    T2 = lists:member(Node, S#state.cluster),

    %% Ensure we don't do transistions that will cause verify failures
    NS = next_state(S,ok,{call,?MODULE,stop,[Node]}),
    SP = [verify_should_pass(Bucket, NS) || {Bucket, _} <- NS#state.buckets],
    %% Allow changes that will require read-repair to occur
    T3 = lists:all(fun(V) -> (V == true) or (V == repair) end, SP),
    %% Allow changes will only pass without read-repair
    %% T3 = lists:all(fun(V) -> V == true end, SP),
    %% T3 = lists:all(fun(V) -> V == repair end, SP),

    %% T3 = true,
    T4 = (Node /= hd(S#state.nodes)),
    T1 and T2 and T3 and T4;

precondition(S,{call,_,verify,[Bucket]}) ->
    Verify = verify_should_pass(Bucket, S),
    Pass = ((Verify == true) or (Verify == repair)),
    %% Pass = (Verify == true),
    %% Pass = (Verify == repair),
    Pass andalso
    not lists:keymember(Bucket, 1, S#state.verify);

precondition(S,{call,_,check_verify,[{Bucket, _, _}]}) ->
    lists:keymember(Bucket, 1, S#state.verify);

precondition(S,{call,_,verify_mapred,[]}) ->
    %% S#state.nodes /= [];
    %% S#state.verify_mr =:= [];
    length(S#state.verify_mr) < 80;

precondition(S,{call,_,check_verify,[Pid]}) ->
    (length(S#state.verify_mr) > 50) andalso
    lists:keymember(Pid, 1, S#state.verify_mr);

precondition(_S,{call,_,_,_}) ->
    true.

postcondition(_S,{call,_,check_verify,[{_, _, _}]},Res) ->
    Res =:= ok;

postcondition(_S,{call,_,check_verify_mapred,_},Res) ->
    Res =:= ok;

postcondition(#state{cluster=Cluster},{call,_,join,[Node, _]},_Res) ->
    Nodes = lists:sort([Node|Cluster]),
    [begin
         Members = rt:members_according_to(N),
         ?assertEqual(Nodes, Members)
     end || N <- Nodes],
    %% [true = lists:member(Node, rt:members_according_to(N)) || N <- Deployed],
    true;

postcondition(#state{cluster=Cluster},{call,_,leave,[Node]},_Res) ->
    Nodes = lists:sort(Cluster -- [Node]),
    %% It make take some time for the leave to propagate around the cluster
    TestFn = fun(N, Acc) ->
                     Members = rt:members_according_to(N),
                     Acc and (Members == Nodes)
             end,
    MemberTest =
        rt:wait_until(node(),
                      fun(_) -> lists:foldl(TestFn, true, Nodes) end),
    ?assertEqual(ok, MemberTest),
    %% [true = lists:member(Node, rt:members_according_to(N)) || N <- Deployed],
    true;

postcondition(_S,{call,_,_,_},_Res) ->
    true.

already_deployed_state() ->
    {_,S0,_} =
        run_commands(?MODULE, [{set,{var,1},{call,?MODULE,deploy_nodes,[3]}}]),
    S0.
    
prop_riak() ->
    %% ?LET(S0, already_deployed_state(),
    %%      ?FORALL(Cmds,commands(?MODULE,S0),
    ?LET(_S0, ok,
         ?FORALL(Cmds,noshrink(?SUCHTHAT(C,more_commands(100,commands(?MODULE)),length(C)>100)),
         ?ALWAYS(1,
         %% ?FORALL(Cmds,more_commands(100,commands(?MODULE)),
                 begin
                     io:format("Cmds: ~p~n", [Cmds]),
                     {H,S,Res} = run_commands(?MODULE,Cmds),
                     ?WHENFAIL(
                        io:format("History: ~p\nState: ~p\nRes: ~p\n",[H,S,Res]),
                        Res == ok)
                 end))).

verify_dynamic_eqc() ->
    %% Config = "bb-verify-mapred.config",
    %% lager:info("Verifying map-reduce"),
    %% Id = rt:spawn_cmd("$BASHO_BENCH2/basho_bench " ++ Config),
    %% R = check_verify_mapred(Id),
    %% io:format("R: ~p~n", [R]).

    %% sample(?SUCHTHAT(C,more_commands(100,commands(?MODULE)),length(C)>50)),
    %% ok.
    %% Buckets = ?BUCKETS,
    %% [populate(Bucket) || {Bucket, _} <- Buckets],
    %% ok.
    %% build_cluster(1).
    %% test_rr().
    eqc:quickcheck(prop_riak()).
    %% Idx1 = rt:spawn_cmd("false"),
    %% R1 = rt:wait_for_cmd(Idx1),
    %% Idx2 = rt:spawn_cmd("false"),
    %% lager:info("Idx1: ~p", [Idx1]),
    %% lager:info("Idx2: ~p", [Idx2]),
    %% R2 = rt:wait_for_cmd(Idx2),
    %% lager:info("C2: ~p", [R2]),
    %% lager:info("C1: ~p", [R1]),

build_cluster(N) ->
    Nodes = rt:build_cluster(N),
    lager:info("Modifying app.config"),
    NewConfig = [{riak_core, [{forced_ownership_handoff, 8},
                              {handoff_concurrency, 8},
                              {vnode_inactivity_timeout, 1000},
                              {gossip_limit, {10000000, 60000}}]}],
    [rt:update_app_config(Node, NewConfig) || Node <- Nodes],

    [Node1|_] = Nodes,

    Buckets = ?BUCKETS,
    generate_scripts(Buckets),
    rt:rsync(Node1, "*.config", "."),

    lager:info("Setting up bucket properties"),
    [set_bucket(Node1, Bucket, Props) || {Bucket, Props} <- Buckets],
    [populate(Bucket) || {Bucket, _} <- Buckets],
    populate_mapred(),
    %% Ports = [spawn_verify(Bucket) || {Bucket, _} <- Buckets],
    %% [?assertEqual(0, rt:wait_for_cmd(Port)) || Port <- Ports],
    Nodes.

generate_scripts(Buckets) ->
    [begin
         Bucket = binary_to_list(BucketBin),
         populate_script(Bucket),
         spawn_verify_script(Bucket),
         spawn_repair_script(Bucket)
     end || {BucketBin, _} <- Buckets],
    populate_mapred_script(),
    spawn_verify_mapred_script(),
    ok.

populate_script(Bucket) ->
    Host = "127.0.0.1",
    Port = 8098,
    Out = io_lib:format("
{mode, max}.
{duration, infinity}.
{concurrent, 16}.
{driver, basho_bench_driver_http_raw}.
{key_generator, {partitioned_sequential_int, 0, 8000}}.
{value_generator, {uniform_bin,100,1000}}.
{operations, [{update, 1}]}.
{http_raw_ips, [\"~s\"]}.
{http_raw_port, ~b}.
{http_raw_path, \"/riak/~s\"}.", [Host, Port, Bucket]),
    Config = "bb-populate-" ++ Bucket ++ ".config",
    file:write_file(Config, Out),
    ok.

populate(Bucket) when is_binary(Bucket) ->
    populate(binary_to_list(Bucket));
populate(Bucket) ->
    Config = "bb-populate-" ++ Bucket ++ ".config",
    lager:info("Populating bucket ~s", [Bucket]),
    ?assertEqual(0, cmd("$BASHO_BENCH/basho_bench " ++ Config)),
    ok.

spawn_verify_script(Bucket) ->
        Host = "127.0.0.1",
    Port = 8098,
    Out = io_lib:format("
{mode, {rate, 50}}.
%{duration, infinity}.
{duration, 1}.
{concurrent, 10}.
{driver, basho_bench_driver_http_raw}.
{key_generator, {uniform_int, 7999}}.
{value_generator, {uniform_bin,100,1000}}.
{operations, [{update, 1},{get_existing, 1}]}.
{http_raw_ips, [\"~s\"]}.
{http_raw_port, ~b}.
{http_raw_path, \"/riak/~s\"}.
{shutdown_on_error, true}.", [Host, Port, Bucket]),
    Config = "bb-verify-" ++ Bucket ++ ".config",
    file:write_file(Config, Out),
    ok.

spawn_verify(Bucket) when is_binary(Bucket) ->
    spawn_verify(binary_to_list(Bucket));
spawn_verify(Bucket) ->
    Config = "bb-verify-" ++ Bucket ++ ".config",
    lager:info("Verifying bucket ~s", [Bucket]),
    %% ?assertEqual(0, cmd("$BASHO_BENCH/basho_bench " ++ Config)),
    %% ok.
    rt:spawn_cmd("$BASHO_BENCH/basho_bench " ++ Config).

spawn_repair_script(Bucket) ->
        Host = "127.0.0.1",
    Port = 8098,
    Out = io_lib:format("
{mode, {rate, 50}}.
{duration, infinity}.
%{duration, 1}.
{concurrent, 10}.
{driver, basho_bench_driver_http_raw}.
%{key_generator, {uniform_int, 8000}}.
{key_generator, {partitioned_sequential_int, 0, 8000}}.
{value_generator, {uniform_bin,100,1000}}.
{operations, [{get, 1}]}.
{http_raw_ips, [\"~s\"]}.
{http_raw_port, ~b}.
{http_raw_path, \"/riak/~s\"}.", [Host, Port, Bucket]),
    Config = "bb-repair-" ++ Bucket ++ ".config",
    file:write_file(Config, Out),
    ok.

spawn_repair(Bucket) when is_binary(Bucket) ->
    spawn_repair(binary_to_list(Bucket));
spawn_repair(Bucket) ->
    Config = "bb-repair-" ++ Bucket ++ ".config",
    lager:info("Read-repairing bucket ~s", [Bucket]),
    %% ?assertEqual(0, cmd("$BASHO_BENCH/basho_bench " ++ Config)),
    %% ok.
    rt:spawn_cmd("$BASHO_BENCH/basho_bench " ++ Config).

populate_mapred_script() ->
    %% Host = "127.0.0.1",
    %% Port = 8087,
    Host = {127,0,0,1},
    Port = 8087,
    Out = io_lib:format("
{driver, basho_bench_driver_riakc_pb}.

%{code_paths, [\"deps/stats\",
%              \"deps/riakc\",
%              \"deps/protobuffs\"]}.

{riakc_pb_ips, [{~p, ~b}]}.

{riakc_pb_replies, 1}.

{riakc_pb_bucket, <<\"bryanitbs\">>}.

%% load
{mode, max}.
{duration, 10000}.
{concurrent, 1}.
{operations, [{put, 1}]}.
{key_generator, {int_to_str, {sequential_int, 10000}}}.
{value_generator,
 {function, basho_bench_driver_riakc_pb, mapred_ordered_valgen, []}}.",
    [Host, Port]),
    Config = "bb-populate-mapred.config",
    file:write_file(Config, Out),
    ok.

populate_mapred() ->
    Config = "bb-populate-mapred.config",
    lager:info("Populating map-reduce bucket"),
    ?assertEqual(0, cmd("$BASHO_BENCH2/basho_bench " ++ Config)),
    ok.

spawn_verify_mapred_script() ->
    Host = {127,0,0,1},
    Port = 8087,
    Out = io_lib:format("
{driver, basho_bench_driver_riakc_pb}.

%{code_paths, [\"deps/stats\",
%              \"deps/riakc\",
%              \"deps/protobuffs\"]}.

{riakc_pb_ips, [{~p, ~b}]}.

{riakc_pb_replies, 1}.

{riakc_pb_bucket, <<\"bryanitbs\">>}.

%% test

%% for computing expected bucket sum
{riakc_pb_preloaded_keys, 10000}.

{mode, max}.
{duration, 1}.
{concurrent, 1}.
{operations, [{mr_bucket_erlang, 1}]}.
{key_generator, {int_to_str, {uniform_int, 9999}}}.
{value_generator, {fixed_bin, 1}}.
{riakc_pb_keylist_length, 1000}.
{shutdown_on_error, true}.", [Host, Port]),

    Config = "bb-verify-mapred.config",
    file:write_file(Config, Out),
    ok.

spawn_verify_mapred() ->
    Config = "bb-verify-mapred.config",
    lager:info("Verifying map-reduce"),
    rt:spawn_cmd("$BASHO_BENCH2/basho_bench " ++ Config).

cmd(Cmd) ->
    Port = rt:spawn_cmd(Cmd),
    rt:wait_for_cmd(Port).

%% cmd(Cmd) ->
%%     Port = open_port({spawn, Cmd}, [exit_status]),
%%     rt:wait_until(node(),
%%                   fun(_) ->
%%                           receive
%%                               {Port, Msg={exit_status, _}} ->
%%                                   catch port_close(Port),
%%                                   self() ! {Port, Msg},
%%                                   true
%%                           after 0 ->
%%                                   false
%%                           end
%%                   end),
%%     receive
%%         {Port, {exit_status, Status}} ->
%%             Status
%%     after 0 ->
%%             timeout
%%     end.

%% spawn_cmd(Cmd) ->
%%     Port = open_port({spawn, Cmd}, [exit_status]),
%%     Port.

%% wait_for_cmd(Port) ->
%%     rt:wait_until(node(),
%%                   fun(_) ->
%%                           receive
%%                               {Port, Msg={exit_status, _}} ->
%%                                   catch port_close(Port),
%%                                   self() ! {Port, Msg},
%%                                   true
%%                           after 0 ->
%%                                   false
%%                           end
%%                   end),
%%     receive
%%         {Port, {exit_status, Status}} ->
%%             Status
%%     after 0 ->
%%             timeout
%%     end.

check_verify_repair(Bucket) ->
    rt:wait_until(node(),
                  fun(_) ->
                          P1 = spawn_repair(Bucket),
                          rt:wait_for_cmd(P1),
                          P2 = spawn_verify(Bucket),
                          case rt:wait_for_cmd(P2) of
                              0 ->
                                  true;
                              1 ->
                                  false
                          end
                  end).

%% deploy_nodes(N) ->
%%     rt:deploy_nodes(N).

join(Node, ToNode) ->
    rt:join(Node, ToNode),
    Nodes = [Node, ToNode],
    ?assertEqual(ok, rt:wait_until_nodes_ready(Nodes)),
    ?assertEqual(ok, rt:wait_until_no_pending_changes(Nodes)),
    ok.

leave(Node) ->
    ?assertEqual(ok, rt:leave(Node)),
    %% ?assertEqual(ok, rt:wait_until_unpingable(Node)),
    %% Sometimes leave will stall. Restarting node usually fixes things
    case rt:wait_until_unpingable(Node) of
        ok ->
            ok;
        _ ->
            rt:stop(Node),
            rt:start(Node),
            ?assertEqual(ok, rt:wait_until_unpingable(Node)),
            ok
    end.

start(Node) ->
    ?assertEqual(ok, rt:start(Node)),
    ok.

stop(Node) ->
    ?assertEqual(ok, rt:stop(Node)),
    ok.

verify(Bucket) ->
    spawn_verify(Bucket).

check_verify({Bucket, Port, Opts}) ->
    lager:info("Checking verify ~p:~p", [Bucket, Opts]),
    Result = rt:wait_for_cmd(Port),
    Repair = ordsets:is_element(repair, Opts),
    case {Repair, Result} of
        {true, 1} ->
            check_verify_repair(Bucket);
        {_, 0} ->
            ok;
        {_, 1} ->
            fail
    end.
    %% ?assertEqual(0, rt:wait_for_cmd(Port)),
    %% ok.

verify_mapred() ->
    spawn_verify_mapred().

check_verify_mapred(Port) ->
    lager:info("Checking verify map-reduce"),
    case rt:wait_for_cmd(Port) of
        0 ->
            ok;
        1 ->
            fail
    end.

set_bucket(Node, Bucket, BucketProps) ->
    rpc:call(Node, riak_core_bucket, set_bucket, [Bucket, BucketProps]).

test_rr() ->
    C1 = [{set,{var,1},{call,verify_dynamic_eqc,build_cluster,[3]}},
          {set,{var,2},{call,verify_dynamic_eqc,stop,[{call,lists,nth,[2,{var,1}]}]}},
          {set,{var,3},{call,verify_dynamic_eqc,verify,[<<"n3r2w2">>]}},
          {set,{var,4},{call,verify_dynamic_eqc,check_verify,[{<<"n3r2w2">>,{var,3},[repair]}]}}],
    %% riak_test:main(["../my-rtdev2.config", ""]),
    eqc:check(verify_dynamic_eqc:prop_riak(), [C1]).

mr_fail() ->
    [{set,{var,1},{call,verify_dynamic_eqc,build_cluster,[3]}},
     {set,{var,2},{call,verify_dynamic_eqc,verify_mapred,[]}},
     {set,{var,3},{call,verify_dynamic_eqc,check_verify_mapred,[{var,2}]}},
     {set,{var,4},{call,verify_dynamic_eqc,verify_mapred,[]}},
     {set,{var,5},{call,verify_dynamic_eqc,check_verify_mapred,[{var,4}]}},
     {set,{var,10},{call,verify_dynamic_eqc,leave,[{call,lists,nth,[3,{var,1}]}]}},
     {set,{var,11},{call,verify_dynamic_eqc,verify_mapred,[]}}].

mr_fail2() ->
    [{set,{var,1},{call,verify_dynamic_eqc,build_cluster,[3]}},
     {set,{var,5},{call,verify_dynamic_eqc,check_verify_mapred,[{var,4}]}},
     {set,{var,10},{call,verify_dynamic_eqc,leave,[{call,lists,nth,[3,{var,1}]}]}},
     {set,{var,11},{call,verify_dynamic_eqc,verify_mapred,[]}}].

%% wait_until_unpingable fails after leave
leave_fail() ->
    [{set,{var,1},{call,verify_dynamic_eqc,build_cluster,[3]}},
     {set,{var,2},{call,verify_dynamic_eqc,verify_mapred,[]}},
     {set,{var,6},{call,verify_dynamic_eqc,leave,[{call,lists,nth,[3,{var,1}]}]}}].

prop_recheck(_File) ->
    %% [Counter] = binary_to_term(element(2, file:read_file(File))),
    %% Counter = mr_fail(),
    Counter = leave_fail(),
    catch riak_test:main(["my-rtdev2.config", ""]),
    mochiglobal:put(countercmds, Counter),
    %% eqc:quickcheck(prop_riak()).
    eqc:quickcheck(gen_prop_recheck(Counter)).

gen_prop_recheck(Counter) ->
    ?FORALL(Cmds,
      ?SUCHTHAT(C,more_commands(100,commands(?MODULE)),
        begin
            io:format("HERE~n"),
            mochiglobal:put(countercmds, Counter),
            %% length(C)>50
            %% C=Counter
            _ = C,
            true
        end),
         ?ALWAYS(10,
                 begin
                     io:format("Cmds: ~p~n", [Cmds]),
                     {H,S,Res} = run_commands(?MODULE,Cmds),
                     ?WHENFAIL(
                        io:format("History: ~p\nState: ~p\nRes: ~p\n",[H,S,Res]),
                        Res == ok)
                 end)).
