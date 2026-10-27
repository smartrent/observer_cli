-module(observer_cli_core_test).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include("observer_cli.hrl").

transform_seq_test() ->
    ?assertEqual(3, observer_cli:transform_seq(1, 2, 3)),
    ?assertEqual(1000, observer_cli:transform_seq(3, 2, 3)).

warning_color_test() ->
    ?assertEqual(?RED, observer_cli:warning_color(0.9)),
    ?assertEqual(?GREEN, observer_cli:warning_color(0.1)).

format_atom_info_test() ->
    {Color1, Atom1} = observer_cli:format_atom_info(100, 90),
    ?assertEqual(?RED, Color1),
    ?assertEqual("90/100", lists:flatten(Atom1)),
    {Color2, Atom2} = observer_cli:format_atom_info(100, 10),
    ?assertEqual(<<"">>, Color2),
    ?assertEqual("10/100", lists:flatten(Atom2)).

process_bar_format_style_test() ->
    Format2 = observer_cli:process_bar_format_style([0.1, 0.2], true),
    ?assert(is_binary(Format2)),
    ?assertMatch({0, _}, binary:match(Format2, ?UNDERLINE)),
    Format4 = observer_cli:process_bar_format_style([0.1, 0.2, 0.3, 0.4], false),
    ?assert(is_binary(Format4)),
    Format10 = observer_cli:process_bar_format_style(
        [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1],
        false
    ),
    ?assert(is_binary(Format10)).

get_refresh_prompt_test() ->
    Count = lists:flatten(observer_cli:get_refresh_prompt(proc_count, memory, 1500, 5)),
    Window = lists:flatten(observer_cli:get_refresh_prompt(proc_window, reductions, 1500, 5)),
    ?assert(lists:prefix("recon:proc_count", Count)),
    ?assert(lists:prefix("recon:proc_window", Window)).

collect_top_n_test() ->
    Count = observer_cli:collect_top_n(proc_count, memory, 1500, 1, true),
    WindowFirst = observer_cli:collect_top_n(proc_window, memory, 1, 1, true),
    WindowNext = observer_cli:collect_top_n(proc_window, memory, 1, 1, false),
    ?assert(is_list(Count)),
    ?assert(is_list(WindowFirst)),
    ?assert(is_list(WindowNext)).

collect_home_snapshot_test() ->
    Home = #home{
        interval = 1500,
        func = proc_count,
        type = memory,
        cur_page = 1,
        scheduler_usage = ?DISABLE
    },
    StableInfo = observer_cli:get_stable_system_info(),
    LastStats = observer_cli:get_incremental_stats(?DISABLE, undefined, true),
    {Snapshot, NewStats} =
        observer_cli:collect_home_snapshot(
            "printf 'header\\n 1 2\\n'", Home, StableInfo, LastStats, 15, true
        ),
    ?assertEqual(
        lists:sort([
            memory_summary,
            process_rows,
            refresh_prompt,
            scheduler_usage,
            system_summary,
            top_processes
        ]),
        lists:sort(maps:keys(Snapshot))
    ),
    ?assertMatch([[{_, _} | _] | _], maps:get(system_summary, Snapshot)),
    ?assertMatch([[{_, _} | _] | _], maps:get(memory_summary, Snapshot)),
    ?assertEqual(undefined, maps:get(scheduler_usage, Snapshot)),
    ?assertEqual(1, maps:get(process_rows, Snapshot)),
    ?assert(is_list(maps:get(top_processes, Snapshot))),
    ?assert(
        lists:prefix(
            "recon:proc_count(memory, 1)",
            lists:flatten(maps:get(refresh_prompt, Snapshot))
        )
    ),
    ?assertMatch({_, _, _, _, _, _}, NewStats).

get_current_initial_call_test() ->
    Call = [
        {current_function, {lists, map, 2}},
        {initial_call, {erlang, apply, 3}}
    ],
    {CurFun, InitialCall} = observer_cli:get_current_initial_call(Call),
    ?assertEqual("lists:map/2", lists:flatten(CurFun)),
    ?assertEqual({erlang, apply, 3}, InitialCall).

render_system_line_test() ->
    PsCmd = "printf 'header\\n 1 2\\n'",
    StableInfo = observer_cli:get_stable_system_info(),
    Line = observer_cli:render_system_line(PsCmd, StableInfo),
    ?assert(string:find(lists:flatten(Line), "System") =/= nomatch).

render_system_line_unsupported_atom_status_test() ->
    PsCmd = "printf 'header\\n 1 2\\n'",
    StableInfo = observer_cli:get_stable_system_info(),
    Line = observer_cli:render_system_line(PsCmd, StableInfo, {error, unsupported}),
    ?assert(string:find(lists:flatten(Line), "Ets Limit") =/= nomatch).

render_system_line_missing_output_test() ->
    PsCmd = "printf ''",
    StableInfo = observer_cli:get_stable_system_info(),
    Line = lists:flatten(observer_cli:render_system_line(PsCmd, StableInfo)),
    ?assert(string:find(Line, "cpu rate") =/= nomatch),
    ?assertEqual(nomatch, string:find(Line, "ps -o pcpu")),
    ?assert(string:find(Line, "/proc pmem") =/= nomatch),
    ?assertEqual(nomatch, string:find(Line, "ps -o pmem")).

render_system_line_proc_fallback_test() ->
    PsCmd = "printf ''",
    StableInfo = observer_cli:get_stable_system_info(),
    LineNoSample = lists:flatten(
        observer_cli:render_system_line(PsCmd, StableInfo, observer_cli:get_atom_status(), "--")
    ),
    ?assert(string:find(LineNoSample, "--%") =/= nomatch),
    LineWithPercent = lists:flatten(
        observer_cli:render_system_line(PsCmd, StableInfo, observer_cli:get_atom_status(), "42.0")
    ),
    ?assert(string:find(LineWithPercent, "42.0%") =/= nomatch),
    case os:type() of
        {unix, linux} ->
            ?assertNotEqual("--", observer_cli_lib:proc_mem_percent());
        _ ->
            ok
    end.

home_ps_cmd_probes_once_test() ->
    Marker = filename:join(
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Dir -> Dir
        end,
        "observer_cli_home_probe_test"
    ),
    file:delete(Marker),
    Cmd =
        "printf x >> " ++ Marker ++
            "; printf \"ps: invalid option -- 'o'\\n"
            "BusyBox v1.37.0 multi-call binary.\\n\"",
    ?assertEqual(no_ps, observer_cli:resolve_ps_cmd(Cmd)),
    ?assertEqual(1, marker_count(Marker)),
    Opts = #view_opts{ps_cmd = no_ps},
    lists:foreach(
        fun(_) -> ?assertEqual(no_ps, observer_cli:home_ps_cmd(Opts)) end,
        lists:seq(1, 10)
    ),
    ?assertEqual(1, marker_count(Marker)),
    file:delete(Marker).

marker_count(Marker) ->
    case file:read_file(Marker) of
        {ok, Bin} -> byte_size(Bin);
        {error, _} -> 0
    end.

resolve_ps_cmd_test() ->
    BusyBoxLike =
        "printf \"ps: invalid option -- 'o'\\n"
        "BusyBox v1.37.0 (Ubuntu 1:1.37.0) multi-call binary.\\n\"",
    ?assertEqual(no_ps, observer_cli:resolve_ps_cmd(BusyBoxLike)),
    ?assertEqual(no_ps, observer_cli:resolve_ps_cmd("printf ''")),
    Working = "printf 'header\\n 1.5 0.3\\n'",
    ?assertEqual(Working, observer_cli:resolve_ps_cmd(Working)).

resolve_ps_cmd_rejects_non_numeric_columns_test() ->
    TwoFieldBanners = [
        "printf \"ps: invalid option -- 'o'\\nBusyBox v1.37.0\\n\"",
        "printf 'ps: Unknown option\\nusage: ps\\n'",
        "printf 'ps: error\\nbad arg\\n'",
        "printf 'header\\n 1.5 huge\\n'",
        "printf 'header\\n -1 0.3\\n'"
    ],
    lists:foreach(
        fun(Cmd) -> ?assertEqual(no_ps, observer_cli:resolve_ps_cmd(Cmd)) end,
        TwoFieldBanners
    ),
    StableInfo = observer_cli:get_stable_system_info(),
    Line = lists:flatten(
        observer_cli:render_system_line(
            "printf \"ps: invalid option -- 'o'\\nBusyBox v1.37.0\\n\"",
            StableInfo,
            observer_cli:get_atom_status(),
            "42.0"
        )
    ),
    ?assertEqual(nomatch, string:find(Line, "BusyBox")),
    ?assertEqual(nomatch, string:find(Line, "v1.37.0")),
    ?assert(string:find(Line, "42.0%") =/= nomatch).

reclaim_cpu_gauge_carries_worker_gauge_test() ->
    Gauge = {{1000, 2000}, "12.3"},
    Worker = spawn(fun() -> gauge_responder(Gauge) end),
    Opts = #view_opts{ps_cmd = no_ps},
    ?assertEqual(
        Opts#view_opts{cpu_gauge = Gauge},
        observer_cli:reclaim_cpu_gauge(Opts, [Worker, self()])
    ).

reclaim_cpu_gauge_skips_working_ps_test() ->
    Worker = spawn(fun() -> gauge_responder({{1, 2}, "9.9"}) end),
    Opts = #view_opts{ps_cmd = "ps -o pcpu,pmem 1"},
    ?assertEqual(Opts, observer_cli:reclaim_cpu_gauge(Opts, [Worker, self()])),
    ?assert(erlang:is_process_alive(Worker)),
    erlang:exit(Worker, kill).

reclaim_cpu_gauge_tolerates_dead_worker_test() ->
    Worker = spawn(fun() -> ok end),
    Opts = #view_opts{ps_cmd = no_ps},
    ?assertEqual(Opts, observer_cli:reclaim_cpu_gauge(Opts, [Worker, self()])),
    ?assertEqual([], [M || {cpu_gauge, _, _} = M <- drain_messages()]).

gauge_responder(Gauge) ->
    receive
        {cpu_gauge, From, Ref} -> erlang:send(From, {cpu_gauge, Ref, Gauge})
    after 5000 -> ok
    end.

drain_messages() ->
    receive
        Msg -> [Msg | drain_messages()]
    after 0 -> []
    end.

carried_cpu_gauge_reports_percent_on_first_frame_test() ->
    case os:type() of
        {unix, linux} ->
            Fresh = observer_cli:get_incremental_stats(?DISABLE, undefined, true),
            ?assertEqual("--", observer_cli:cpu_percent_from_stats(Fresh)),
            {{Ticks, Ms}, Percent} = element(6, Fresh),
            Aged = {{Ticks, Ms - ?MIN_INTERVAL - 1}, Percent},
            Carried = observer_cli:get_incremental_stats(?DISABLE, Aged, true),
            ?assertNotEqual("--", observer_cli:cpu_percent_from_stats(Carried)),
            {_, _, Next} = observer_cli:node_stats(Carried, ?DISABLE, true),
            ?assertEqual(
                observer_cli:cpu_percent_from_stats(Carried),
                observer_cli:cpu_percent_from_stats(Next)
            );
        _ ->
            ok
    end.

render_system_line_no_ps_test() ->
    StableInfo = observer_cli:get_stable_system_info(),
    Line = lists:flatten(
        observer_cli:render_system_line(no_ps, StableInfo, observer_cli:get_atom_status(), "42.0")
    ),
    ?assert(string:find(Line, "42.0%") =/= nomatch),
    Working = "printf 'header\\n 1.5 0.3\\n'",
    WorkingLine = lists:flatten(
        observer_cli:render_system_line(Working, StableInfo, observer_cli:get_atom_status(), "42.0")
    ),
    ?assert(string:find(WorkingLine, "1.5%") =/= nomatch),
    ?assert(string:find(WorkingLine, "42.0%") =:= nomatch).

render_system_line_real_ps_test() ->
    RealPs = "printf '%%CPU %%MEM\\n 277  0.2\\n'",
    StableInfo = observer_cli:get_stable_system_info(),
    Line = lists:flatten(
        observer_cli:render_system_line(RealPs, StableInfo, observer_cli:get_atom_status(), "7.5")
    ),
    ?assert(string:find(Line, "277%") =/= nomatch),
    ?assert(string:find(Line, "0.2%") =/= nomatch),
    ?assertEqual(nomatch, string:find(Line, "7.5%")),
    ?assertEqual(RealPs, observer_cli:resolve_ps_cmd(RealPs)).

node_stats_skips_cpu_sample_when_ps_works_test() ->
    Unsampled = observer_cli:get_incremental_stats(?DISABLE, undefined, false),
    ?assertEqual(undefined, element(6, Unsampled)),
    ?assertEqual("--", observer_cli:cpu_percent_from_stats(Unsampled)),
    {_, _, Next} = observer_cli:node_stats(Unsampled, ?DISABLE, false),
    ?assertEqual(undefined, element(6, Next)),
    ?assertEqual("--", observer_cli:cpu_percent_from_stats(Next)),
    case os:type() of
        {unix, linux} ->
            Sampled = observer_cli:get_incremental_stats(?DISABLE, undefined, true),
            ?assertNotEqual(undefined, element(6, Sampled));
        _ ->
            ok
    end.

node_stats_cpu_gauge_rate_limited_test() ->
    case os:type() of
        {unix, linux} ->
            Stats0 = observer_cli:get_incremental_stats(?DISABLE, undefined, true),
            ?assertEqual("--", observer_cli:cpu_percent_from_stats(Stats0)),
            timer:sleep(?MIN_INTERVAL + 100),
            {_, _, Stats1} = observer_cli:node_stats(Stats0, ?DISABLE, true),
            Percent1 = observer_cli:cpu_percent_from_stats(Stats1),
            ?assertNotEqual("--", Percent1),
            ?assertMatch({_Float, []}, string:to_float(Percent1)),
            {_, _, Stats2} = observer_cli:node_stats(Stats1, ?DISABLE, true),
            ?assertEqual(Percent1, observer_cli:cpu_percent_from_stats(Stats2));
        _ ->
            ok
    end.

accept_net_ticktime_result_test() ->
    ?assertEqual(ok, observer_cli:accept_net_ticktime_result(change_initiated, 60)),
    ?assertEqual(ok, observer_cli:accept_net_ticktime_result({ongoing_change_to, 60}, 60)),
    ?assertEqual(
        {error, connection, connection_failed},
        observer_cli:accept_net_ticktime_result({ongoing_change_to, 30}, 60)
    ),
    ?assertEqual(ok, observer_cli:accept_net_ticktime_result(unchanged, 60)).

update_net_ticktime_from_disconnected_node_test() ->
    {ok, Host} = inet:gethostname(),
    MissingNode = list_to_atom("observer_cli_missing_ticktime@" ++ Host),
    ?assertEqual(
        {error, connection, connection_failed},
        observer_cli:update_net_ticktime_from(MissingNode)
    ).

render_memory_process_line_test() ->
    MemSum = {1, 2, 3, 4},
    Line = observer_cli:render_memory_process_line(MemSum, 1500),
    ?assert(string:find(lists:flatten(Line), "Total") =/= nomatch).

render_memory_process_line_error_logger_test() ->
    MemSum = {1, 2, 3, 4},
    Prev = whereis(error_logger),
    TempPid =
        case Prev of
            undefined ->
                Pid = spawn(fun() ->
                    receive
                        stop -> ok
                    end
                end),
                true = register(error_logger, Pid),
                Pid;
            _ ->
                Prev
        end,
    try
        Line = observer_cli:render_memory_process_line(MemSum, 1500),
        ?assert(string:find(lists:flatten(Line), "RunQueue") =/= nomatch)
    after
        case Prev of
            undefined ->
                unregister(error_logger),
                TempPid ! stop;
            _ ->
                ok
        end
    end.

render_home_summary_wide_layout_test() ->
    observer_cli_test_io:with_geometry(
        24,
        160,
        [],
        fun() ->
            StableInfo = observer_cli:get_stable_system_info(),
            SystemLines = observer_cli:render_system_line(
                "printf 'header\n 1 2\n'", StableInfo
            ),
            MemLines = observer_cli:render_memory_process_line({1, 2, 3, 4}, 1500),
            [SystemTitle | _] = SystemLines,
            [MemTitle | _] = MemLines,
            ?assertEqual(
                observer_cli_lib:layout_width(), hd(home_summary_line_lengths(SystemTitle))
            ),
            ?assertEqual(
                nomatch,
                binary:match(unicode:characters_to_binary(MemTitle), <<"\e[0m |">>)
            ),
            ?assertEqual([15, 26, 30, 25, 25, 31], home_summary_widths(SystemTitle)),
            ?assertEqual([15, 26, 30, 25, 25, 31], home_summary_widths(MemTitle)),
            ?assert(
                lists:all(
                    fun(Len) -> Len =< observer_cli_lib:layout_width() end,
                    home_summary_line_lengths(SystemTitle)
                )
            ),
            ?assert(
                lists:all(
                    fun(Len) -> Len =< observer_cli_lib:layout_width() end,
                    home_summary_line_lengths(MemTitle)
                )
            ),
            ?assert(
                lists:all(
                    fun(Len) -> Len =< observer_cli_lib:layout_width() end,
                    rendered_line_lengths(SystemLines)
                )
            ),
            ?assert(
                lists:all(
                    fun(Len) -> Len =< observer_cli_lib:layout_width() end,
                    rendered_line_lengths(MemLines)
                )
            )
        end
    ).

render_scheduler_usage_test() ->
    ?assertEqual({0, []}, observer_cli:render_scheduler_usage(undefined)),
    ?assertEqual({0, []}, observer_cli:render_scheduler_usage([])),
    {2, _} = observer_cli:render_scheduler_usage([{1, 0.1}, {2, 0.2}, {3, 0.3}, {4, 0.4}]),
    {3, _} = observer_cli:render_scheduler_usage([{1, 0.1}, {2, 0.2}, {3, 0.3}, {4, 0.4}, {5, 0.5}]),
    {2, _} = observer_cli:render_scheduler_usage(
        [{1, 0.1}, {2, 0.2}, {3, 0.3}, {4, 0.4}, {5, 0.5}, {6, 0.6}, {7, 0.7}, {8, 0.8}]
    ),
    {3, _} = observer_cli:render_scheduler_usage(
        lists:map(fun(N) -> {N, 0.1} end, lists:seq(1, 9))
    ),
    {11, _} = observer_cli:render_scheduler_usage(
        lists:map(fun(N) -> {N, 0.1} end, lists:seq(1, 101))
    ),
    {11, _} = observer_cli:render_scheduler_usage(
        lists:map(fun(N) -> {N, 0.1} end, lists:seq(1, 110))
    ).

render_scheduler_usage_wide_layout_test() ->
    FullSchedulers = lists:map(fun(N) -> {N, 1.0} end, lists:seq(1, 8)),
    ?assert(scheduler_bar_count(160, FullSchedulers) > scheduler_bar_count(139, FullSchedulers)),
    observer_cli_test_io:with_geometry(
        24,
        160,
        [],
        fun() ->
            Samples = [
                [{1, 0.1}, {2, 0.2}, {3, 0.3}, {4, 0.4}],
                lists:map(fun(N) -> {N, 0.1} end, lists:seq(1, 8)),
                lists:map(fun(N) -> {N, 0.1} end, lists:seq(1, 101))
            ],
            ?assert(
                lists:all(
                    fun(SchedulerUsage) ->
                        {_Rows, Lines} = observer_cli:render_scheduler_usage(SchedulerUsage),
                        lists:all(
                            fun(Line) ->
                                observer_cli_lib:visible_length(Line) =:=
                                    observer_cli_lib:layout_width()
                            end,
                            Lines
                        )
                    end,
                    Samples
                )
            )
        end
    ).

scheduler_bar_count(Columns, SchedulerUsage) ->
    observer_cli_test_io:with_geometry(
        24,
        Columns,
        [],
        fun() ->
            {_Rows, [Line | _]} = observer_cli:render_scheduler_usage(SchedulerUsage),
            erlang:length([Char || Char <- observer_cli_test_io:plain(Line), Char =:= $|])
        end
    ).

render_top_n_view_test() ->
    Pid1 = self(),
    Pid2 = spawn(fun() -> receive
        after infinity -> ok
        end end),
    Call1 = [test_name, {current_function, {lists, map, 2}}, {initial_call, {erlang, apply, 3}}],
    Call2 = [
        {registered_name, undefined},
        {current_function, {lists, map, 2}},
        {initial_call, {erlang, apply, 3}}
    ],
    Items = [
        {Pid1, 1000, Call1},
        {Pid2, 2000, Call2}
    ],
    Pages = [{1, 1}],
    {PidList1, Rows1} = observer_cli:render_top_n_view(memory, Items, 2, Pages, 1),
    {PidList2, Rows2} = observer_cli:render_top_n_view(binary_memory, Items, 2, Pages, 1),
    {PidList3, Rows3} = observer_cli:render_top_n_view(reductions, Items, 2, Pages, 1),
    {PidList4, Rows4} = observer_cli:render_top_n_view(total_heap_size, Items, 2, Pages, 1),
    {PidList5, Rows5} = observer_cli:render_top_n_view(message_queue_len, Items, 2, Pages, 1),
    ?assertEqual(2, length(PidList1)),
    ?assertEqual(3, length(Rows1)),
    ?assertEqual(2, length(PidList2)),
    ?assertEqual(3, length(Rows2)),
    ?assertEqual(2, length(PidList3)),
    ?assertEqual(3, length(Rows3)),
    ?assertEqual(2, length(PidList4)),
    ?assertEqual(3, length(Rows4)),
    ExpectedHeap = observer_cli_lib:to_byte(1000 * erlang:system_info(wordsize)),
    ?assertNotEqual(nomatch, string:find(observer_cli_test_io:plain(Rows4), ExpectedHeap)),
    ?assertEqual(2, length(PidList5)),
    ?assertEqual(3, length(Rows5)),
    erlang:exit(Pid2, kill),
    {PidList1, Rows1, Rows2, Rows3, Rows4, Rows5}.

render_top_n_view_type_columns_test() ->
    Pid = self(),
    Call = [
        {registered_name, undefined},
        {current_function, {lists, map, 2}},
        {initial_call, {erlang, apply, 3}}
    ],
    Items = [{Pid, 1000, Call}],
    LayoutWidth = observer_cli_lib:layout_base_width(),
    Cases = [
        {memory, LayoutWidth, ["Memory", "Reductions", "MsgQueue"]},
        {binary_memory, LayoutWidth, ["BinMemory", "Reductions", "MsgQueue"]},
        {reductions, LayoutWidth + 1, ["Reductions", "Memory", "MsgQueue"]},
        {total_heap_size, LayoutWidth, ["TotalHeapSize", "Reductions", "MsgQueue"]},
        {message_queue_len, LayoutWidth, ["MsgQueue", "Memory", "Reductions"]}
    ],
    lists:foreach(
        fun({Type, TitleWidth, Fragments}) ->
            {_, [Title, Row]} = observer_cli:render_top_n_view(
                Type, Items, 1, [{1, 1}], 1, LayoutWidth
            ),
            observer_cli_test_io:assert_stable_fragments(
                [Title],
                ["No | Pid", "Name|>Label|>Initial Call", "Current Function" | Fragments]
            ),
            RowBin = unicode:characters_to_binary(Row),
            ?assertNotEqual(nomatch, binary:match(RowBin, ?ANSI_INVERSE)),
            ?assertEqual(nomatch, binary:match(RowBin, ?ANSI_GREEN_BG)),
            ?assertEqual(TitleWidth, observer_cli_lib:visible_length(Title)),
            ?assertEqual(LayoutWidth, observer_cli_lib:visible_length(Row))
        end,
        Cases
    ).

select_home_process_test() ->
    StorePid = observer_cli_store:start(),
    Pid1 = spawn(fun wait_forever/0),
    Pid2 = spawn(fun wait_forever/0),
    try
        observer_cli_store:update(StorePid, 2, [{2, Pid1}, {3, Pid2}]),
        ExactOpts = #view_opts{home = #home{cur_page = 1, pages = [{1, 2}]}},
        FallbackOpts = #view_opts{home = #home{cur_page = 1, pages = [{1, 1}]}},
        ?assertEqual({ok, Pid1}, observer_cli:select_home_process(StorePid, ExactOpts, false)),
        ?assertEqual(error, observer_cli:select_home_process(StorePid, FallbackOpts, false)),
        ?assertEqual({ok, Pid2}, observer_cli:select_home_process(StorePid, FallbackOpts, true))
    after
        observer_cli_lib:exit_processes([StorePid, Pid1, Pid2])
    end.

render_top_n_view_wide_layout_test() ->
    Pid = self(),
    Call = [
        {registered_name, undefined},
        {current_function,
            {very_long_current_module_for_layout, very_long_current_function_for_layout, 2}},
        {initial_call,
            {very_long_initial_module_for_layout, very_long_initial_function_for_layout, 1}}
    ],
    {_, [Title, Row]} = observer_cli:render_top_n_view(
        memory, [{Pid, 1000, Call}], 1, [{1, 1}], 1, 160
    ),
    ?assertEqual(160, observer_cli_lib:visible_length(Title)),
    ?assertEqual(160, observer_cli_lib:visible_length(Row)).

get_top_n_info_translated_call_test() ->
    Pid = spawn(fun() -> receive
        after infinity -> ok
        end end),
    Call = [
        {registered_name, undefined},
        {current_function, {lists, map, 2}},
        {initial_call, {proc_lib, init_p, 5}}
    ],
    {Pid, _Val, _CurFun, Flag} = observer_cli:get_top_n_info({Pid, 1, Call}),
    ?assert(is_list(Flag)),
    erlang:exit(Pid, kill).

atom_status_test() ->
    case observer_cli:get_atom_status() of
        {ok, Limit, Count} ->
            ?assert(is_integer(Limit)),
            ?assert(is_integer(Count));
        {error, unsupported} ->
            ok
    end.

get_pid_info_test() ->
    {Val1, Val2} = observer_cli:get_pid_info(self(), [reductions, message_queue_len]),
    ?assert(Val1 =/= "dead"),
    ?assert(Val2 =/= "dead").

get_pid_info_dead_test() ->
    Pid = spawn(fun() -> receive
        after infinity -> ok
        end end),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 ->
        ok
    end,
    ?assertEqual({"dead", "dead"}, observer_cli:get_pid_info(Pid, [reductions, message_queue_len])).

port_proc_info_test() ->
    {PortWarning, ProcWarning, PortCountStr, ProcCountStr} =
        observer_cli:get_port_proc_info(999999, 999999),
    ?assert(is_binary(PortWarning)),
    ?assert(is_binary(ProcWarning)),
    ?assert(string:find(lists:flatten(PortCountStr), "/") =/= nomatch),
    ?assert(string:find(lists:flatten(ProcCountStr), "/") =/= nomatch).

port_proc_info_warning_test() ->
    {PortWarning, ProcWarning, _PortCountStr, _ProcCountStr} =
        observer_cli:get_port_proc_info(1, 1),
    ?assertEqual(?RED, PortWarning),
    ?assertEqual(?RED, ProcWarning).

display_unique_flag_label_false_test() ->
    case erlang:function_exported(proc_lib, get_label, 1) of
        true ->
            Prev = proc_lib:get_label(self()),
            proc_lib:set_label(false),
            try
                Flag = observer_cli:display_unique_flag(123, {erlang, apply, 3}, self()),
                ?assert(string:find(lists:flatten(Flag), "erlang:apply/3") =/= nomatch)
            after
                proc_lib:set_label(Prev)
            end;
        false ->
            ok
    end.

display_unique_flag_label_value_test() ->
    case erlang:function_exported(proc_lib, get_label, 1) of
        true ->
            Prev = proc_lib:get_label(self()),
            proc_lib:set_label(my_label),
            try
                Flag = observer_cli:display_unique_flag(123, {erlang, apply, 3}, self()),
                ?assert(string:find(lists:flatten(Flag), "my_label") =/= nomatch)
            after
                proc_lib:set_label(Prev)
            end;
        false ->
            ok
    end.

node_stats_test() ->
    Stats = observer_cli:get_incremental_stats(?DISABLE, undefined, true),
    {Diffs, _Sched, _New} = observer_cli:node_stats(Stats, ?DISABLE, true),
    {InDiff, OutDiff, _GcDiff, _WordsDiff} = Diffs,
    ?assert(string:find(lists:flatten(InDiff), "/") =/= nomatch),
    ?assert(string:find(lists:flatten(OutDiff), "/") =/= nomatch).

check_auto_row_test() ->
    ?assert(is_boolean(observer_cli:check_auto_row())).

private_home_layout_contract_test() ->
    ?assertEqual([], observer_cli:join_home_summary_rows([])),
    ?assertNotEqual(
        [],
        observer_cli:join_home_summary_rows([
            {normal, [{"one", 10}]}
        ])
    ),
    ?assertNotEqual(
        [],
        observer_cli:join_home_summary_rows([
            {normal, [{"one", 10}]}, {normal, [{"two", 10}]}
        ])
    ),
    ?assertEqual(0, observer_cli:scheduler_usage_rows(undefined)),
    ?assertEqual(2, observer_cli:scheduler_usage_rows([a, b, c])),
    ?assertEqual(3, observer_cli:scheduler_usage_rows(lists:seq(1, 12))),
    ?assertEqual(11, observer_cli:scheduler_usage_rows(lists:seq(1, 101))).

home_summary_widths(IoData) ->
    Header =
        case non_empty_lines(IoData) of
            [_First, Second | _] -> Second;
            [Only] -> Only
        end,
    Parts = string:split(Header, "|", all),
    Inner = lists:sublist(Parts, 2, length(Parts) - 2),
    [length(P) || P <- Inner].

non_empty_lines(IoData) ->
    [Line || Line <- string:split(plain(IoData), "\n", all), Line =/= ""].

home_summary_line_lengths(IoData) ->
    [length(Line) || Line <- non_empty_lines(IoData)].

rendered_line_lengths(IoDatas) ->
    lists:flatmap(fun home_summary_line_lengths/1, IoDatas).

plain(IoData) ->
    binary_to_list(
        re:replace(
            unicode:characters_to_binary(IoData),
            <<"\e\\[[0-9;]*[A-Za-z]">>,
            <<>>,
            [global, {return, binary}]
        )
    ).

wait_forever() ->
    receive
    after infinity ->
        ok
    end.

-endif.
