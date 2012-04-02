-module(gh_riak_core_155).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

load_code(Module, Nodes) ->
    {Module, Bin, File} = code:get_object_code(Module),
    {_, []} = rpc:multicall(Nodes, code, load_binary, [Module, File, Bin]).

setup_mocks() ->
    application:start(lager),
    meck:new(riak_core_vnode_proxy_sup, [unstick, passthrough, no_link]),
    meck:expect(riak_core_vnode_proxy_sup, start_proxies,
                fun(Mod=riak_kv_vnode) ->
                        lager:info("Delaying start of riak_kv_vnode proxies"),
                        timer:sleep(3000),
                        meck:passthrough([Mod]);
                   (Mod) ->
                        meck:passthrough([Mod])
                end),
    lager:info("Installed mocks").

gh_riak_core_155() ->
    [Node] = rt:build_cluster(1),
    %% lager:info("NM: ~p", [rt:config(rt_nodes)]),
    %% Node = 'dev1@127.0.0.1',
    %% rt:set_config(rt_nodes, [{'dev1@127.0.0.1',1}]),
    %% rt:start(Node),
    %% rt:wait_until_pingable(Node),
  
    %% Generate a valid preflist for our get requests
    rpc:call(Node, riak_core, wait_for_service, [riak_kv]),
    %% io:format("~p~n", [rpc:call(Node, erlang, apply, [fun() -> io:format("Hi!~n") end, []])]),
    %% rpc:call(Node, io, format, ["Heyas"]),
    BKey = {<<"bucket">>, <<"value">>},
    DocIdx = riak_core_util:chash_std_keyfun(BKey),
    PL = rpc:call(Node, riak_core_apl, get_apl, [DocIdx, 3, riak_kv]),
    lager:info("PL: ~p", [PL]),

    lager:info("Adding delayed start to app.config"),
    NewConfig = [{riak_core, [{delayed_start, 1000}]}],
    rt:update_app_config(Node, NewConfig),

    rt:stop(Node),
    rt:async_start(Node),
    rt:wait_until_pingable(Node),

    load_code(?MODULE, [Node]),
    load_code(meck, [Node]),
    load_code(meck_mod, [Node]),
    rpc:call(Node, ?MODULE, setup_mocks, []),

    lager:info("Installed mocks to delay riak_kv proxy startup"),
    lager:info("Issuing 10000 gets against ~p", [Node]),
    perform_gets(10000, Node, PL, BKey),

    lager:info("Verifying ~p has not crashed", [Node]),
    [begin
         ?assertEqual(pong, net_adm:ping(Node)),
         timer:sleep(1000)
     end || _ <- lists:seq(1,10)],

    lager:info("Test passed"),
    %% %% rt:stop(Node),
    %% %% rt:wait_until_unpingable(Node),
    %% %% rt:start(Node),
    %% [begin
    %%      rpc:call(Node, application, stop, [riak_kv]),
    %%      rpc:call(Node, application, stop, [riak_core]),
    %%      rpc:call(Node, application, set_env, [riak_core, vnode_modules, []]),
    %%      %% Self = self(),
    %%      %% spawn(fun() ->
    %%      %%               perform_gets(10000, Node, PL, BKey),
    %%      %%               Self ! done
    %%      %%       end),
    %%      %% rpc:call(Node, application, start, [riak_core]),
    %%      %% rpc:call(Node, application, start, [riak_kv])
    %%      %% rpc:call(Node, application, start, [riak_kv]),
    %%      %% receive done -> ok end
    %%      spawn(fun() ->
    %%                    rpc:call(Node, application, start, [riak_core]),
    %%                    rpc:call(Node, application, start, [riak_kv])
    %%            end),
    %%      perform_gets(100000, Node, PL, BKey)
    %%  end || _ <- lists:seq(1,10)],
    %% [begin
    %%      lager:info("ping: ~p", [net_adm:ping(Node)]),
    %%      timer:sleep(1000)
    %%  end || _ <- lists:seq(1,10)],
    %% %% Self = self(),
    %% %% spawn(fun() ->
    %% %%               perform_gets(2000, Node, PL, BKey),
    %% %%               Self ! done
    %% %%       end),
    %% %% rt:start(Node),

    %% %% receive
    %% %%     A ->
    %% %%         lager:info("M: ~p", [A]),
    %% %%         ok
    %% %% end,
    ok.

perform_gets(Count, Node, PL, BKey) ->
    rpc:call(Node, riak_kv_vnode, get, [PL, BKey, make_ref()]),
    perform_gets2(Count, Node, PL, BKey).

perform_gets2(0, _, _, _) ->
    ok;
perform_gets2(Count, Node, PL, BKey) ->
    %% riak_kv_vnode:get(PL, BKey, make_ref()),
    rpc:call(Node, riak_kv_vnode, get, [PL, BKey, make_ref()], 1000),
    perform_gets(Count - 1, Node, PL, BKey).
