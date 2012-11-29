%% walk the rabbit supervision tree looking for blockages on shutdown

-module(suptree_inspect).
-export([main/1, inspect/1]).
-mode(compile).

main([Node, Sup]) ->
    Dest = list_to_atom(Node),
    {ok, _} = net_kernel:start([?MODULE, shortnames]),
    case net_kernel:hidden_connect_node(Dest) of
        true ->
            {Mod, Bin, Fn} = code:get_object_code(?MODULE),
            {module, Mod} = rpc:call(Dest, code, load_binary, [Mod, Fn, Bin]),
            print(rpc:call(Dest, Mod, inspect, [list_to_atom(Sup)]));
        false ->
            io:format("ERROR: unable to contact ~s~n", [Node]),
            erlang:halt(1)
    end.

print({badrpc, _}) ->
    io:format("rpc to node failed.~n");
print([]) ->
    io:format("no process information available.~n");
print([{Pid, Reg, CF, BTrace, Desc}|T]) ->
    io:format("~n"),
    io:format("pid: ~p~n", [Pid]),
    io:format("registered name: ~p~n", [strip(Reg)]),
    io:format("stacktrace: ~p~n", [strip(CF)]),
    io:format("-------------------------~n"),
    io:format("~s", [BTrace]),
    io:format("-------------------------~n"),
    case Desc of
        [] -> ok;
        _  -> print(Desc)
    end,
    print(T).

strip({registered_name, N})    -> N;
strip({current_stacktrace, T}) -> T;
strip([])                      -> none;
strip(T)                       -> T.

inspect(Name) ->
   io:format(user, "inspecting ~s supervision tree~n", [Name]),
   {Acc, _} = gather(whereis(Name)),
   lists:reverse(Acc).

gather(undefined) ->
    {[], nil};
gather(Pid) when is_pid(Pid) ->
    gather(Pid, {[], gb_trees:empty()}).

gather(undefined, Acc) ->
    Acc;
gather(Pid, {Acc, Seen}=S) when is_pid(Pid) ->
    case gb_trees:is_defined(Pid, Seen) of
        false ->
            Reg = erlang:process_info(Pid, registered_name),
            CF = erlang:process_info(Pid, current_stacktrace),
            {_, BTrace} = erlang:process_info(Pid, backtrace),
            {ShuttingDown, MorePids} =
                case erlang:process_info(Pid, monitors) of
                    {monitors, Monitors} when is_list(Monitors) ->
                        combine([P || {process, P} <- Monitors, is_pid(P)],
                                track(Pid, Seen));
                    _What ->
                        {[], Seen}
                end,
            {Links, MorePids2} =
                case erlang:process_info(Pid, links) of
                    {links, Linked} ->
                        combine([P || P <- Linked, is_pid(P)], MorePids);
                    _ ->
                        {[], MorePids}
                end,
            Descendants = ShuttingDown ++ Links,
            {[{Pid, Reg, CF, BTrace, Descendants}|Acc],
             track(Pid, MorePids2)};
        true ->
            S
    end.

track(Pid, Seen) ->
    gb_trees:enter(Pid, true, Seen).

combine(Infos, Seen) ->
   lists:foldl(fun(Pid, {Acc, SeenPids}) ->
                       {Acc2, MoreSeen} = gather(Pid, {[], SeenPids}),
                       {Acc ++ Acc2, MoreSeen}
               end, {[], Seen}, Infos).
