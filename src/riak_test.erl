-module(riak_test).
-export([main/1]).

add_deps(Path) ->
    {ok, Deps} = file:list_dir(Path),
    [code:add_path(lists:append([Path, "/", Dep, "/ebin"])) || Dep <- Deps],
    ok.

main([Test]) ->
    Path = "/Users/jtuple/basho/CLEAN2/riak",
    add_deps(Path ++ "/deps"),
    ENode = 'eunit@127.0.0.1',
    Cookie = riak, 
    [] = os:cmd("epmd -daemon"),
    net_kernel:start([ENode]),
    erlang:set_cookie(node(), Cookie),

    application:start(lager),
    lager:set_loglevel(lager_console_backend, info),

    put(rt_path, Path),
    put(rt_max_wait_time, 180000),
    put(rt_retry_delay, 500),
    TestFn = list_to_atom(Test),
    st:TestFn(),
    ok.


