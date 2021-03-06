% Copyright (c) 2011-2014 Aki Helin
% Copyright (c) 2014-2019 Alexander Bolshev aka dark_k3y
%
% Permission is hereby granted, free of charge, to any person obtaining a copy
% of this software and associated documentation files (the "Software"), to deal
% in the Software without restriction, including without limitation the rights
% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
% copies of the Software, and to permit persons to whom the Software is
% furnished to do so, subject to the following conditions:
%
% The above copyright notice and this permission notice shall be included in
% all copies or substantial portions of the Software.
%
% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
% SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
% DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
% OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
% THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%
%%%-------------------------------------------------------------------
%%% @author dark_k3y
%%% @doc
%%% Main fuzzer module.
%%% @end
%%%-------------------------------------------------------------------
-module(erlamsa_main).
-author("dark_k3y").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all]).
-endif.

-include("erlamsa.hrl").

%% API
-export([test/0, test/1, test_input/1, fuzzer/1]).

-spec make_verb_to_file(string()) -> fun().
make_verb_to_file(Path) ->
    {Res, Fd} = file:open(Path, [write]),
    case Res of
        ok ->
            OutputFun = erlamsa_utils:verb(Fd, 10),
            fun
                ({close, ok}) -> file:close(Fd);
                (X) -> OutputFun(X)
            end;
        _Else ->
            %% TODO: add printing filename, handling -r and other things...
            Err = lists:flatten(io_lib:format("Error opening file '~s'", [Path])),
            erlamsa_utils:error(Err),
            fun(X) -> X end
    end.

-spec maybe_meta_logger(string() | atom(), fun()) -> fun().
maybe_meta_logger(Path, _) ->
  Verb = case Path of
      nil -> fun (X) -> X end;
      stderr -> erlamsa_utils:verb(stderr, 10);
      stdout -> erlamsa_utils:verb(stdout, 10);
      _Else -> make_verb_to_file(Path)
  end,
  fun 
      F([X|T]) -> Verb(io_lib:format("~p~n", [X])), F(T);
      F([]) -> []; 
      F(X) -> Verb(io_lib:format("~p~n", [X])) 
  end.

-spec test() -> list().
test() -> fuzzer(maps:put(paths, ["test.1"], maps:put(verbose, 0,
                 maps:put(output, return, maps:new())))
                ).

test_input(Inp) -> fuzzer(
                    maps:put(paths, [direct],
                        maps:put(verbose, 0,
                            maps:put(output, return,
                                maps:put(input, Inp, maps:new()))))).

test(Seed) -> fuzzer(
                maps:put(paths, ["test.1"],
                    maps:put(verbose, 0,
                        maps:put(output, "-",
                            maps:put(seed, Seed, maps:new()))))).

-spec get_threading_mode(any(), integer(), integer()) -> integer() | list. 
get_threading_mode(_, N, Workers) when N =:= 1; Workers =:= 1 -> 1;
get_threading_mode("-", _N, _Workers) ->  1;
get_threading_mode(return, _N, _Workers) ->  1;
get_threading_mode(stdout, _N, _Workers) ->  1;
get_threading_mode(stderr, _N, _Workers) ->  1;
get_threading_mode(_Mode, N, Workers) ->  
    Div = N div Workers,
    Rem = N rem Workers,
    Tasks = [{A*Div, (A+1)*Div - 1, A} || A <- lists:seq(0, Workers-1)],
    [{{LastA, LastB, WNum}, LastRem}|T] = 
        (fun 
            MergeRem([H1|T1], [H2|T2], Acc) -> 
                MergeRem(T1, T2, [{H1, H2+Div*Workers}|Acc]); 
            MergeRem([H1|T1], [], Acc) -> 
                MergeRem(T1, [], [{H1, 0}|Acc]); 
            MergeRem([], [], Acc) -> Acc
        end)(Tasks, lists:seq(0, Rem), []),
    [{{0, FirstB, FirstW}, FirstRem}|FT] = lists:reverse([{{LastA, min(LastB, N), WNum}, LastRem}|T]),
    [{{1, FirstB, FirstW}, FirstRem}|FT].

-spec wait_for_finished(integer()) -> ok.
wait_for_finished(0) -> ok;
wait_for_finished(N) ->
    receive
        {finished, W, Pid, _ThreadSetting} -> 
            %io:format("Got from thread: ~p~n", [_ThreadSetting]),
            erlamsa_logger:log(info, "fuzzing worker process no. ~p <~p> finished", [W, Pid]),
            wait_for_finished(N-1)
    end.

-spec record_result(binary(), list()) -> list().
record_result(<<>>, Acc) -> Acc;
record_result(X, Acc) -> [X | Acc].

-spec fuzzer(#{}) -> [binary()].
fuzzer(Dict) ->
    %% Getting All Data from options
    SeedFun = maps:get(seed, Dict, fun() -> erlamsa_rnd:gen_urandom_seed() end),
    CustomMutas = erlamsa_utils:make_mutas(maps:get(external_mutations, Dict, nil)),
    Mutas = maps:get(mutations, Dict, erlamsa_mutations:default(CustomMutas)),
    Cnt = maps:get(n, Dict, 1), 
    MaxFails = maps:get(maxfails, Dict, ?TOO_MANY_FAILED_ATTEMPTS),
    Paths = maps:get(paths, Dict, ["-"]),
    Verbose = erlamsa_utils:verb(stderr, maps:get(verbose, Dict, 0)),
    Seed = SeedFun(),
    erlamsa_rnd:seed(Seed),
    file:write_file("./last_seed.txt", io_lib:format("~p", [Seed])),
    Verbose(io_lib:format("Random seed: ~p~n", [Seed])),
    erlamsa_logger:log(info, "starting fuzzer main (parent = ~p), random seed is: ~p",
                        [maps:get(parentpid, Dict, none), Seed]),
    Fail = fun(Why) -> io:write(Why), throw(Why) end,
    Muta = erlamsa_mutations:make_mutator(Mutas, CustomMutas),
    DirectInput = maps:get(input, Dict, nil),
    %%TODO: FIXME: should be maps:get(output, Dict, "-") instead 
    %% However now direct == return, so interexchanging with input should be ok
    RecordFun = case DirectInput of  
                    direct -> fun record_result/2;
                    _Else -> fun (_, _) -> [] end
                end,
    BlockScale = maps:get(blockscale, Dict, 1.0),
    Generator = erlamsa_gen:make_generator(maps:get(generators, Dict,
                                        erlamsa_gen:default()), Paths,
                                        DirectInput, BlockScale, Fail, Cnt),
    RecordMeta = maybe_meta_logger( maps:get(metadata, Dict, nil), Fail),
    RecordMeta({seed, Seed}),
    PatList = maps:get(patterns, Dict, erlamsa_patterns:default()),
    Pat = erlamsa_patterns:make_pattern(PatList),
    Out = erlamsa_out:string_outputs(Dict),
    Post = erlamsa_utils:make_post(maps:get(external_post, Dict, nil)),
    Sleep = maps:get(sleep, Dict, 0),
    FailDelay = maps:get(faildelay, Dict, 0),
    %% Creating the Fuzzing Loop function
    FuzzingLoop = 
        fun 
            FuzzingLoopFun(_, _, _, {0, _}, _N, _) -> [];
            FuzzingLoopFun(_, _, _, {I, _}, N, Acc) when is_integer(N) andalso N < I ->
                RecordMeta({close, ok}), lists:reverse(Acc);
            FuzzingLoopFun(_, _, _, {_, FailedI}, _N, Acc)
                                                    when FailedI > MaxFails ->
                io:format(standard_error, "Too many failed output attempts (~p), stopping.~n", [FailedI]),
                erlamsa_logger:log(error, "Too many failed output attempts (~p), stopping.~n", [FailedI]),
                RecordMeta({status, toomanyfailedoutputs}), RecordMeta({close, ok}),
                lists:reverse(Acc);
            FuzzingLoopFun(CurMuta, DataGen, CurOut, {I, Fails}, N, Acc) ->
                {Ll, GenMeta} = DataGen(),
                {NewOut, NewMuta, Data, NewFails} =
                    try
                        {CandidateOut, Fd, OutMeta} = CurOut(I, [{nth, I}, GenMeta]),
                        Tmp = Pat(Ll, CurMuta, OutMeta),
                        {CandidateMuta, Meta, Written, CandidateData} = erlamsa_out:output(Tmp, Fd, Post),
                        RecordMeta(lists:reverse(lists:flatten([{written, Written}| Meta]))),
                        Verbose(io_lib:format("output: ~p~n", [Written])),
                        erlamsa_logger:log(info, "fuzzing cycle ~p/~p finished, written ~p bytes", [I, N, Written]),
                        {CandidateOut, CandidateMuta, CandidateData, 0}
                    catch
                        {cantconnect, _Err} ->
                            timer:sleep(10*Fails + FailDelay),
                            {CurOut, CurMuta, <<>>, Fails + 1};
                        {fderror, _Err} ->
                            {CurOut, CurMuta, <<>>, Fails + 1}
                    end,
                timer:sleep(Sleep),
                FuzzingLoopFun(NewMuta, DataGen, NewOut, {I + 1, NewFails}, N, RecordFun(Data, Acc))
        end,
    %% Running in single- or multi- threaded mode
    Threads = get_threading_mode(maps:get(output, Dict, "-"), Cnt, maps:get(workers, Dict, 1)),
    run_fuzzing_loop(Threads, FuzzingLoop, Muta, Generator, Out, Cnt).

-spec run_fuzzing_loop(integer() | list(), fun(), fun(), {atom(), fun()}, fun(), non_neg_integer()) -> ok.
%% single- threaded mode
run_fuzzing_loop(1, FuzzingLoop, Muta, {_GenName, Gen}, Out, Cnt) ->
    FuzzingLoop(Muta, Gen, Out, {1, 0}, Cnt, []);
%% multi- threaded mode
run_fuzzing_loop(Threads, FuzzingLoop, Muta, {GenName, Gen}, Out, _Cnt) ->
    %% Selecting generator
    %% For stdio we need to pre-read the data;
    %% otherwise it could be some random that we should variate
    MultiGen = case GenName of
        stdin -> GenRes = Gen(), fun() -> GenRes end;
        _Else -> Gen
    end,
    MainProcessPid = erlang:self(),
    [spawn(fun() -> 
            erlamsa_logger:log(info, "fuzzing worker process ~p started, range {~p, ~p} + ~p additional", [W, A, B, R]),
            FuzzingLoop(Muta, MultiGen, Out, {A, 0}, B, []),
            FuzzingLoop(Muta, MultiGen, Out, {R, 0}, R, []),
            MainProcessPid ! {finished, W, erlang:self(), {{A, B, W}, R}}
        end)  || {{A, B, W}, R} <- Threads],
    wait_for_finished(length(Threads)).






