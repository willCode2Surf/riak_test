-module(st).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

-import(rt, [deploy_nodes/1,
             owners_according_to/1,
             join/2,
             wait_until_nodes_ready/1,
             wait_until_no_pending_changes/1,
             owners_according_to/1,
             leave/1,
             wait_until_unpingable/1,
             status_of_according_to/2,
             remove/2,
             wait_until_unpingable/1,
             claimant_according_to/1,
             stop/1,
             start/1,
             down/2,
             wait_until_ring_converged/1,
             wait_until_all_members/2
            ]).

build_cluster(NumNodes) ->
    %% Deploy a set of new nodes
    Nodes = deploy_nodes(NumNodes),

    %% Ensure each node owns 100% of it's own ring
    [?assertEqual([Node], owners_according_to(Node)) || Node <- Nodes],

    %% Join nodes
    [Node1|OtherNodes] = Nodes,
    [join(Node, Node1) || Node <- OtherNodes],

    ?assertEqual(ok, wait_until_nodes_ready(Nodes)),
    ?assertEqual(ok, wait_until_no_pending_changes(Nodes)),

    %% Ensure each node owns a portion of the ring
    [?assertEqual(Nodes, owners_according_to(Node)) || Node <- Nodes],
    Nodes.

verify_leave() ->
    %% Bring up a 3-node cluster for the test
    Nodes = build_cluster(3),
    [Node1, Node2, Node3] = Nodes,

    %% Have node2 leave
    lager:info("Have ~p leave", [Node2]),
    leave(Node2),
    ?assertEqual(ok, wait_until_unpingable(Node2)),

    %% Verify node2 no longer owns partitions, all node believe it invalid
    lager:info("Verify ~p no longer owns partitions and all nodes believe "
               "it is invalid", [Node2]),
    Remaining1 = Nodes -- [Node2],
    [?assertEqual(Remaining1, owners_according_to(Node)) || Node <- Remaining1],
    [?assertEqual(invalid, status_of_according_to(Node2, Node)) || Node <- Remaining1],

    %% Have node1 remove node3
    lager:info("Have ~p remove ~p", [Node1, Node3]),
    remove(Node1, Node3),
    ?assertEqual(ok, wait_until_unpingable(Node3)),

    %% Verify node3 no longer owns partitions, all node believe it invalid
    lager:info("Verify ~p no longer owns partitions, and all nodes believe "
               "it is invalid", [Node3]),
    Remaining2 = Remaining1 -- [Node3],
    [?assertEqual(Remaining2, owners_according_to(Node)) || Node <- Remaining2],
    [?assertEqual(invalid, status_of_according_to(Node3, Node)) || Node <- Remaining2],
    ok.

verify_claimant() ->
    Nodes = build_cluster(3),
    [Node1, Node2, _Node3] = Nodes,

    %% Ensure all nodes believe node1 is the claimant
    lager:info("Ensure all nodes believe ~p is the claimant", [Node1]),
    [?assertEqual(Node1, claimant_according_to(Node)) || Node <- Nodes],

    %% Stop node1
    lager:info("Stop ~p", [Node1]),
    stop(Node1),
    ?assertEqual(ok, wait_until_unpingable(Node1)),

    %% Ensure all nodes still believe node1 is the claimant
    lager:info("Ensure all nodes still believe ~p is the claimant", [Node1]),
    Remaining = Nodes -- [Node1],
    [?assertEqual(Node1, claimant_according_to(Node)) || Node <- Remaining],

    %% Mark node1 as down and wait for ring convergence
    lager:info("Mark ~p as down", [Node1]),
    down(Node2, Node1),
    ?assertEqual(ok, wait_until_ring_converged(Remaining)),
    [?assertEqual(down, status_of_according_to(Node1, Node)) || Node <- Remaining],

    %% Ensure all nodes now believe node2 to be the claimant
    lager:info("Ensure all nodes now believe ~p is the claimant", [Node2]),
    [?assertEqual(Node2, claimant_according_to(Node)) || Node <- Remaining],

    %% Restart node1 and wait for ring convergence
    lager:info("Restart ~p and wait for ring convergence", [Node1]),
    start(Node1),
    ?assertEqual(ok, wait_until_nodes_ready([Node1])),
    ?assertEqual(ok, wait_until_ring_converged(Nodes)),

    %% Ensure node has rejoined and is no longer down
    lager:info("Ensure ~p has rejoined and is no longer down", [Node1]),
    [?assertEqual(valid, status_of_according_to(Node1, Node)) || Node <- Nodes],

    %% Ensure all nodes still believe node2 is the claimant
    lager:info("Ensure all nodes still believe ~p is the claimant", [Node2]),
    [?assertEqual(Node2, claimant_according_to(Node)) || Node <- Nodes],
    ok.

verify_down() ->
    Nodes = deploy_nodes(3),
    [Node1, Node2, Node3] = Nodes,

    %% Join node2 to node1 and wait for cluster convergence
    lager:info("Join ~p to ~p", [Node2, Node1]),
    join(Node2, Node1),
    ?assertEqual(ok, wait_until_nodes_ready([Node1, Node2])),
    ?assertEqual(ok, wait_until_no_pending_changes([Node1, Node2])),

    %% Shutdown node2
    lager:info("Stopping ~p", [Node2]),
    stop(Node2),
    ?assertEqual(ok, wait_until_unpingable(Node2)),
    Remaining = Nodes -- [Node2],

    %% Join node3 to node1
    lager:info("Join ~p to ~p", [Node3, Node1]),
    join(Node3, Node1),
    ?assertEqual(ok, wait_until_all_members(Remaining, [Node3])),

    %% Ensure node3 remains in the joining state
    lager:info("Ensure ~p remains in the joining state", [Node3]),
    [?assertEqual(joining, status_of_according_to(Node3, Node)) || Node <- Remaining],

    %% Mark node2 as down and wait for ring convergence
    lager:info("Mark ~p as down", [Node2]),
    down(Node1, Node2),
    ?assertEqual(ok, wait_until_ring_converged(Remaining)),
    [?assertEqual(down, status_of_according_to(Node2, Node)) || Node <- Remaining],

    %% Ensure node3 is now valid
    [?assertEqual(valid, status_of_according_to(Node3, Node)) || Node <- Remaining],

    %% Restart node2 and wait for ring convergence
    lager:info("Restart ~p and wait for ring convergence", [Node2]),
    start(Node2),
    ?assertEqual(ok, wait_until_nodes_ready([Node2])),
    ?assertEqual(ok, wait_until_ring_converged(Nodes)),

    %% Verify that all three nodes are ready
    lager:info("Ensure all nodes are ready"),
    ?assertEqual(ok, wait_until_nodes_ready(Nodes)),
    ok.
