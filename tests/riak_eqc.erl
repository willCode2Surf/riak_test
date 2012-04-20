%(set-face-attribute 'default nil :family "Inconsolata" :height 120)
-module(riak_eqc).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

-record(state,{nodes,
               cluster,
               stopped}).

initial_state() ->
    #state{nodes=[]}.

command(#state{nodes=[]}) ->
    {call,?MODULE,deploy_nodes,[3]};
command(#state{nodes=Nodes, cluster=Cluster, stopped=Stopped}) ->
    Others = Nodes -- Cluster,
    oneof(
[{call,?MODULE,join,[elements(Others), elements(Cluster)]} || Others /= []] ++
[{call,?MODULE,leave,[elements(Cluster)]} || length(Cluster) > 1] ++
[{call,?MODULE,start,[elements(Stopped)]} || Stopped /= []] ++
[{call,?MODULE,dummy,[]}]).

nodes(Nodes, _Length) when is_list(Nodes) ->
    Nodes;
nodes(Nodes, Length) ->
    %% Symbolic nodes
    [{call,lists,nth,[N, Nodes]} || N <- lists:seq(1,Length)].

next_state(S,V,{call,_,deploy_nodes,[N]}) ->
    Nodes = nodes(V,N),
    Cluster = [hd(Nodes)],
    S#state{nodes=Nodes, cluster=Cluster, stopped=[]};

next_state(S,_V,{call,_,join,[Node, _]}) ->
    Cluster = [Node | S#state.cluster],
    S#state{cluster=Cluster};

next_state(S,_V,{call,_,leave,[Node]}) ->
    Nodes = lists:delete(Node, S#state.nodes),
    Cluster = lists:delete(Node, S#state.cluster),
    Stopped = [Node | S#state.stopped],
    S#state{nodes=Nodes, cluster=Cluster, stopped=Stopped};

next_state(S,_V,{call,_,start,[Node]}) ->
    Nodes = lists:sort([Node | S#state.nodes]),
    Stopped = lists:delete(Node, S#state.stopped),
    S#state{nodes=Nodes, stopped=Stopped};

next_state(S,_V,{call,_,_,_}) ->
    S.

precondition(S,{call,_,join,[Node, NodeTo]}) ->
    Others = S#state.nodes -- S#state.cluster,
    lists:member(Node, Others) andalso
    lists:member(NodeTo, S#state.cluster);

precondition(S,{call,_,leave,[Node]}) ->
    (length(S#state.cluster) > 1) andalso
    lists:member(Node, S#state.cluster);

precondition(_S,{call,_,dummy,_}) ->
    false;
precondition(_S,{call,_,_,_}) ->
    true.

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
    [begin
         Members = rt:members_according_to(N),
         ?assertEqual(Nodes, Members)
     end || N <- Nodes],
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
         ?FORALL(Cmds,commands(?MODULE),
                 begin
                     {H,S,Res} = run_commands(?MODULE,Cmds),
                     ?WHENFAIL(
                        io:format("History: ~p\nState: ~p\nRes: ~p\n",[H,S,Res]),
                        Res == ok)
                 end)).

riak_eqc() ->
    eqc:quickcheck(prop_riak()).

deploy_nodes(N) ->
    rt:deploy_nodes(N).

join(Node, ToNode) ->
    rt:join(Node, ToNode),
    Nodes = [Node, ToNode],
    ?assertEqual(ok, rt:wait_until_nodes_ready(Nodes)),
    ?assertEqual(ok, rt:wait_until_no_pending_changes(Nodes)),
    ok.

leave(Node) ->
    ?assertEqual(ok, rt:leave(Node)),
    ?assertEqual(ok, rt:wait_until_unpingable(Node)),
    ok.

start(Node) ->
    ?assertEqual(ok, rt:start(Node)),
    ok.

