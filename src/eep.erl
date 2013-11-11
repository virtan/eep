-module(eep).
-export([
         start_tracing/1,
         start_tracing/2,
         stop_tracing/0,
         convert_tracing/1,
         callgrind_convertor/1,
         convertor_child/1,
         save_kcachegrind_format/2,
         test_unwind/0
        ]).

start_tracing(FileName) ->
    start_tracing(FileName, '_').

start_tracing(FileName, Module) ->
    TraceFun = dbg:trace_port(file, tracefile(FileName)),
    {ok, _Tracer} = dbg:tracer(port, TraceFun),
    dbg:p(all, [call, timestamp, return_to, arity]),
    dbg:tpl(Module, []).

stop_tracing() ->
    dbg:stop_clear().

convert_tracing(FileName) ->
    Saver = spawn_link(?MODULE, save_kcachegrind_format, [FileName, self()]),
    dbg:trace_client(file, tracefile(FileName), {fun callgrind_convertor/2, callgrind_convertor({default_state, Saver})}),
    working.

tracefile(FileName) ->
    FileName ++ ".trace".

kcgfile(FileName) ->
    "callgrind.out." ++ FileName.

-record(cvn_state, {processes = ets:new(unnamed, [public, {write_concurrency, true}, {read_concurrency, true}]),
                    saver}).
-record(cvn_child_state, {pid, min_time = undefined, max_time = undefined, saver, stack = undefined}).
-record(cvn_item, {mfa, self = 0, ts, calls = 1, returns = 0, subcalls = orddict:new()}).

callgrind_convertor({default_state, Saver}) ->
    #cvn_state{saver = Saver}.

callgrind_convertor({trace_ts, Pid, _, _, _} = Msg, #cvn_state{processes = Processes, saver = Saver} = State) ->
    case ets:lookup(Processes, Pid) of
        [] ->
            Child = spawn_link(?MODULE, convertor_child, [#cvn_child_state{pid = Pid, saver = Saver}]),
            Child ! Msg,
            ets:insert(Processes, {Pid, Child}),
            State;
        [{Pid, Child}] ->
            Child ! Msg,
            State
    end;
callgrind_convertor(end_of_trace, #cvn_state{processes = Processes, saver = Saver}) ->
    Saver ! {wait, Processes},
    ets:foldl(fun({_, Child}, _) -> Child ! finalize end, nothing, Processes),
    end_of_cycle;
callgrind_convertor(UnknownMessage, #cvn_state{}) ->
    io:format("Unknown message: ~p~n", [UnknownMessage]).

convertor_child(#cvn_child_state{pid = Pid, min_time = MinTime, max_time = MaxTime,
                                 saver = Saver, stack = Stack} = State) ->
    receive
        {trace_ts, Pid, call, MFA, TS} ->
            NewStack = case Stack of
                           undefined ->
                               queue:in(#cvn_item{mfa = MFA, ts = ts(TS)}, queue:new());
                           _ ->
                               {{value, Last}, Dropped} = queue:out_r(Stack),
                               case Last of
                                   #cvn_item{mfa = MFA, calls = Calls} ->
                                       queue:in(Last#cvn_item{calls = Calls + 1}, Dropped);
                                   #cvn_item{self = Self, ts = PTS} ->
                                       queue:in(#cvn_item{mfa = MFA, ts = ts(TS)},
                                                queue:in(Last#cvn_item{self = Self + td(PTS, TS)}, Dropped))
                               end
                       end,
            convertor_child(State#cvn_child_state{
                              stack = NewStack,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        {trace_ts, Pid, return_to, MFA, TS} ->
            NewStack = case Stack of
                           undefined ->
                               io:format("Incomplete data~n", []),
                               undefined;
                           _ ->
                               NewStack1 = convertor_unwind(MFA, TS, nosub, queue:out_r(Stack), {Pid, Saver}),
                               case queue:is_empty(NewStack1) of
                                   true -> undefined;
                                   _ -> NewStack1
                               end
                       end,
            convertor_child(State#cvn_child_state{
                              stack = NewStack,
                              min_time = min_ts(MinTime, TS),
                              max_time = max_ts(MaxTime, TS)});
        finalize ->
            convertor_unwind({nonexistent, nonexistent, 999}, MaxTime, nosub, queue:out_r(Stack), {Pid, Saver}),
            Saver ! {finalize, Pid, MinTime, MaxTime},
            get_out
    end.
            
convertor_unwind(MFA, _TS, nosub, {{value, #cvn_item{mfa = MFA, calls = Calls, returns = Returns} = Last},
                                         Dropped}, _) when Calls > Returns + 1 ->
    queue:in(Last#cvn_item{returns = Returns + 1}, Dropped);
convertor_unwind(MFA, TS, nosub, {{value, #cvn_item{mfa = MFA, ts = TS}} = Last, Dropped}, _) ->
    % unexpected frame
    queue:in(Last#cvn_item{ts = ts(TS)}, Dropped);
convertor_unwind(MFA, TS, nosub, {{value, #cvn_item{mfa = CMFA, self = Self, calls = CCalls, ts = CTS} = Last},
                                         Dropped}, {Pid, Saver}) ->
    TD = Self + td(CTS, TS),
    Saver ! {Pid, Last#cvn_item{self = TD div CCalls}},
    convertor_unwind(MFA, TS, {CMFA, CCalls, TD}, queue:out_r(Dropped), {Pid, Saver});
convertor_unwind(MFA, TS, Sub, {{value, #cvn_item{mfa = MFA, subcalls = SubCalls} = Last}, Dropped}, _) ->
    queue:in(Last#cvn_item{ts = ts(TS), subcalls = subcall_update(Sub, SubCalls)}, Dropped);
convertor_unwind(MFA, TS, Sub, {{value, #cvn_item{mfa = CMFA, calls = CCalls, ts = CTS,
                                                            subcalls = CSubCalls} = Last}, Dropped}, {Pid, Saver}) ->
    Saver ! {Pid, Last#cvn_item{subcalls = subcall_update(Sub, CSubCalls)}},
    convertor_unwind(MFA, TS, {CMFA, CCalls, td(CTS, TS)}, queue:out_r(Dropped), {Pid, Saver});
convertor_unwind(MFA, TS, Sub, {empty, EmptyQueue}, _) ->
    % recreating top level
    queue:in(#cvn_item{mfa = MFA, ts = ts(TS), subcalls = subcall_update(Sub, orddict:new())}, EmptyQueue);
convertor_unwind(A1, A2, A3, A4, A5) ->
    io:format("Shouldn't happen ~p ~p ~p ~p ~p~n", [A1, A2, A3, A4, A5]).

subcall_update({SMFA, SCalls, STD}, SubCalls) ->
    orddict:update(SMFA, fun({SCalls2, STD2}) -> {SCalls2 + SCalls, STD2 + STD} end, {SCalls, STD}, SubCalls).

save_kcachegrind_format(FileName, Parent) ->
    RealFileName = kcgfile(FileName),
    case file:open(RealFileName, [read, write, binary, delayed_write, read_ahead, raw]) of
        {ok, IOD} ->
            file:delete(RealFileName),
            {ok, Timer} = timer:send_interval(1000, status),
            {GTD} = save_receive_cycle(IOD, 1, ts(os:timestamp()), 0, ts(os:timestamp()), undefined),
            timer:cancel(Timer),
            {ok, IOD2} = file:open(RealFileName, [write, binary, delayed_write, raw]),
            save_header(IOD2, GTD),
            file:position(IOD, {bof, 0}),
            save_copy(IOD, IOD2),
            file:close(IOD),
            file:close(IOD2),
            io:format("done~n", []),
            Parent ! done;
        {error, Reason} ->
            io:format("Error: can't create file ~p: ~p~n", [RealFileName, Reason]),
            error(problem)
    end.

save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting) ->
    receive
        status ->
            working_stat(P, MinTime, max(MinTime, MaxTime), StartTime),
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting);
        {Pid, #cvn_item{mfa = {M, F, A}, self = Self, ts = TS, subcalls = SubCalls}} ->
            Block1 = io_lib:format("ob=~s~n"
                                   "fl=~w~n"
                                   "fn=~w:~w/~b~n"
                                   "1 ~b~n",
                                   [pid_to_list(Pid), M, M, F, A, Self]),
            Block3 = orddict:fold(fun({CM, CF, CA}, {CCalls, Cumulative}, Acc) ->
                                          Block2 = io_lib:format("cfl=~w~n"
                                                                 "cfn=~w:~w/~b~n"
                                                                 "calls=~b 1~n"
                                                                 "1 ~b~n",
                                                                 [CM, CM, CF, CA, CCalls, Cumulative]),
                                          [Block2 | Acc]
                                  end, [], SubCalls),
            file:write(IOD, iolist_to_binary([Block1, lists:reverse(Block3), $\n])),
            save_receive_cycle(IOD, P + 1, min_ts(MinTime, TS), max_ts(MaxTime, TS), StartTime, Waiting);
        {wait, Processes} ->
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Processes);
        {finalize, Pid, MinTime1, MaxTime1} ->
            ets:delete(Waiting, Pid),
            Minimum = min(MinTime, MinTime1),
            Maximum = max(MaxTime, MaxTime1),
            case ets:info(Waiting, size) of
                0 ->
                    working_stat(P, Minimum, Maximum, StartTime),
                    ets:delete(Waiting),
                    {td(Minimum, Maximum)};
                _ ->
                    save_receive_cycle(IOD, P, Minimum, Maximum, StartTime, Waiting)
            end;
        _ ->
            save_receive_cycle(IOD, P, MinTime, MaxTime, StartTime, Waiting)
    end.

working_stat(Msgs, MinTime, MaxTime, StartTime) ->
    io:format("~b msgs (~b msgs/sec), ~f secs (~bx slowdown)~n",
              [Msgs, round(Msgs / (td(StartTime, os:timestamp()) / 1000000)),
               td(MinTime, MaxTime) / 1000000, round(td(StartTime, os:timestamp()) / td(MinTime, MaxTime))]).

save_header(IOD, GTD) ->
    Block4 = io_lib:format("events: Time~n"
                           "creator: Erlang Easy Profiling http://github.com/virtan/eep~n"
                           "summary: ~b~n~n",
                           [GTD]),
    file:write(IOD, iolist_to_binary(Block4)).

save_copy(From, To) ->
    case file:read(From, 64*1024) of
        {ok, Data} ->
            case file:write(To, Data) of
                ok -> save_copy(From, To);
                {error, Reason} ->
                    io:format("Error: can't save results: ~p~n", [Reason]),
                    error(problem)
            end;
        eof -> done;
        {error, Reason} ->
            io:format("Error: can't save results: ~p~n", [Reason]),
            error(problem)
    end.

ts({Mega, Secs, Micro}) -> (Mega * 1000000000000) + (Secs * 1000000) + Micro;
ts(Number) -> Number.

td(From, To) -> ts(To) - ts(From).

min_ts(undefined, undefined) -> undefined;
min_ts(undefined, Two) -> Two;
min_ts(One, undefined) -> One;
min_ts(One, Two) ->
    case {ts(One), ts(Two)} of
        {X, Y} when X < Y -> X;
        {_, Y} -> Y
    end.

max_ts(undefined, undefined) -> undefined;
max_ts(undefined, Two) -> Two;
max_ts(One, undefined) -> One;
max_ts(One, Two) ->
    case {ts(One), ts(Two)} of
        {X, Y} when X > Y -> X;
        {_, Y} -> Y
    end.

receive_all(Prev) ->
    receive
        M -> receive_all([M | Prev])
    after 0 -> lists:reverse(Prev)
    end.

test_unwind() ->
    test_unwind_1(),
    test_unwind_2().

test_unwind_1() ->
    TestSet = [
     {trace_ts, 1, call, abc, 1},
     {trace_ts, 1, call, abc, 3},
     {trace_ts, 1, call, abc, 7},
     {trace_ts, 1, return_to, toplevel, 10}
    ],
    lists:foldl(fun(El, St) -> callgrind_convertor(El, St) end, callgrind_convertor({default_state, self()}), TestSet),
    [{_, #cvn_item{mfa = abc, self = 3, calls = 3, subcalls = []}}] = receive_all([]).

test_unwind_2() ->
    TestSet = [
     {trace_ts, 1, call, a, 1},
     {trace_ts, 1, call, ab, 3},
     {trace_ts, 1, call, abc, 7},
     {trace_ts, 1, return_to, a, 10}
    ],
    lists:foldl(fun(El, St) -> callgrind_convertor(El, St) end, callgrind_convertor({default_state, self()}), TestSet),
    [{_, #cvn_item{mfa = abc, self = 3, calls = 1, subcalls = []}},
     {_, #cvn_item{mfa = ab, self = 4, calls = 1, subcalls = [{abc, 1, 3}]}}] = receive_all([]).
