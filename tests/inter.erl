-module(inter).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

-record(state,{}).

%% Initialize the state
initial_state() ->
    #state{}.

%% Node joins cluster:
%% 1. Node gets ring from cluster node
%% 2. Node adds itself to members list, and overwrites its ring
%% 3. Node gossips new_ring to cluster node
%% 4. Gossip eventually propagates around the cluster
%% 5. Claimant setups pending transfers
%% 6. Gossip again until convergance
%% 7. Old owners start handoff to new owner
%% 8. Vnode finishes handoff, moves to forwarding
%% 9. Ring converges, claimant updates ownership
%% 10. Ring converges, previous owner starts to shutdown
%% 11. Previous owner eventually shutsdown

%% Command generator, S is the state
command(_S) ->
    oneof([
           ]).

%% Next state transformation, S is the current state
next_state(S,_V,{call,_,_,_}) ->
    S.

%% Precondition, checked before command is added to the command sequence
precondition(_S,{call,_,_,_}) ->
    true.

%% Postcondition, checked after command has been evaluated
%% OBS: S is the state before next_state(S,_,<command>) 
postcondition(_S,{call,_,_,_},_Res) ->
    true.

inter() ->
    prop_test().

%% disable_handoff(Node) ->
%%     rpc:call(Node, application, set_env, [riak_core, forced_ownership_handoff, 0]),
%%     rpc:call(Node, application, set_env, [riak_core, vnode_inactivity_timeout, 99999999]),
%%     ok.

prop_test() ->
    Nodes = rt:deploy_nodes(2),

    %% Disable automatic handoff by modifying the app.config
    lager:info("Disabling automatic handoff by modifying app.config"),
    NewConfig = [{riak_core, [{forced_ownership_handoff, 0},
                              {vnode_inactivity_timeout, 99999999},
                              {gossip_limit, {1000000, 60000}}]}],
    %% NewConfig = [{riak_core, [{gossip_limit, {1000000, 60000}}]}],
    %% [rt:stop(Node) || Node <- Nodes],
    [rt:update_app_config(Node, NewConfig) || Node <- Nodes],
    %% [rt:start(Node) || Node <- Nodes],

    %% [disable_handoff(Node) || Node <- Nodes],
    [Node1, Node2] = Nodes,
    rt:join(Node1, Node2),
    ok.
    %% ?FORALL(Cmds,commands(?MODULE),
    %%         begin
    %%             {H,S,Res} = run_commands(?MODULE,Cmds),
    %%             ?WHENFAIL(
    %%                io:format("History: ~p\nState: ~p\nRes: ~p\n",[H,S,Res]),
    %%                Res == ok)
    %%         end).
