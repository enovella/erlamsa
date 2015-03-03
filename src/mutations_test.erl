-module(mutations_test).

-include_lib("eunit/include/eunit.hrl").
-include("erlamsa.hrl").

%%
%% Tests helper functions
%%

init_randr() -> random:seed(now()).

sprintf(Format, Vars) -> 
	lists:flatten(io_lib:format(Format, Vars)).

%% Test until N will be eq to Max
recursive_tester(_Run, _CheckBug, Max, Max) -> false;
recursive_tester(Run, CheckBug, Max, N) ->
	case CheckBug(Run()) of
		true -> true;
		false -> recursive_tester(Run, CheckBug, Max, N + 1)
	end.

%% Test until N will be eq to Max OR at least one fail
recursive_fail_tester(_Run, _CheckBug, Max, Max) -> true;
recursive_fail_tester(Run, CheckBug, Max, N) ->
	case CheckBug(Run()) of
		false -> false;
		true -> recursive_tester(Run, CheckBug, Max, N + 1)
	end.

recursive_regex_tester(InStr, Re, Muta, Iters) -> 
	init_randr(),
	TestString = sprintf(InStr, []),
	{ok, MP} = re:compile(Re),	
	recursive_tester(
				fun () -> {_F, _Rs, Ll, _Meta, _D} = Muta(1, [list_to_binary(TestString)], []),	binary_to_list(hd(Ll)) end, 								
				fun (X) -> re:run(X, MP) =/= nomatch end,
				Iters,
				0
			).

random_lex_string() -> init_randr(), random_lex_string(owllisp:rand(42), []).

random_lex_string(0, Out) -> Out;
random_lex_string(N, Out) -> 
	T = owllisp:rand(8),
	case T of 
		0 -> random_lex_string(N - 1, [92 | Out]); % \
		1 -> random_lex_string(N - 1, [34 | Out]); % "
		2 -> random_lex_string(N - 1, [39 | Out]); % '
		3 -> random_lex_string(N - 1, [0 | Out]);  % \0
		4 -> random_lex_string(N - 1, [owllisp:rand(256) | Out]);
		_Else -> random_lex_string(N - 1, [97 | Out]) % a
	end.

warn_false(true, _Fmt, _Lst) -> true;
warn_false(false, Fmt, Lst) ->
	?debugFmt(Fmt, Lst),
	false.

%% 
%% Number mutation test
%%

sed_num_test() ->
	?assert(recursive_regex_tester(
		" 100 + 100 + 100 ", "101", fun mutations:sed_num/3, 1500
		) =:= true). 

%% 
%% ASCII bad mutators test
%% 


string_lexer_test() -> ?assert(string_lexer_test(0, [233, 39, 39, 97, 97, 97, 0])).

string_lexer_test(10000, _Input) -> true;
string_lexer_test(N, Input) ->
	Chunks = mutations:string_lex(Input),
	Output = mutations:string_unlex(Chunks),
	case Output =:= Input of
		true -> string_lexer_test(N + 1, random_lex_string());
		false -> ?debugFmt("Lex/unlex fail onto: ~s =/= ~s from ~w~n", [Input, Output, {Input, Chunks, Output}]), false
	end.


ascii_bad_test() ->	
	?assert(recursive_regex_tester(
		"----------------------------------------\"\"--------------------------------------------------",
		"^-*\".*[%|a].*\"-*$", mutations:construct_ascii_bad_mutator(), 20
		) =:= true). 

ascii_delimeter_test() ->	
	?assert(recursive_regex_tester(
		"----------------------------------------\"\"--------------------------------------------------",
		"^-*\"-*$", mutations:construct_ascii_delimeter_mutator(), 20
		) =:= true). 
	
%%
%% Line mutations tests
%%

line_muta_tester(InStr, MutaFun, Check) ->
	init_randr(),
	TestString = sprintf(InStr, []),
	Muta = mutations:construct_line_muta(MutaFun, temp),
	{_F, _Rs, Ll, _Meta, _D} = Muta(1, [list_to_binary(TestString)], []),
	Check(TestString, binary_to_list(hd(Ll))).


line_del_test() -> 
	?assert(line_muta_tester("1~n 2~n  3~n  4~n    5~n", fun generic:list_del/2,
			fun (S, R) -> length(string:tokens(R,[10])) + 1 =:= length(string:tokens(S, [10])) end)).

line_del_seq_statistics_test() -> 
	init_randr(),
	Iters = 1000,
	TestString = sprintf("0~n1~n 2~n  3~n   4~n    5~n     6~n      7~n       8~n         9~n", []),
	Muta = mutations:construct_line_muta(fun generic:list_del_seq/2, line_del_seq),
	N = lists:foldl(
		fun (_, AccIn) -> 
			{_, _, Ll, _, _} = Muta(1, [list_to_binary(TestString)], []),
			AccIn + length(string:tokens(binary_to_list(hd(Ll)),[10])) end, 
			0, lists:seq(1, Iters)),		
	?assert((N*1.0)/Iters < (0.75 * length(string:tokens(TestString, [10])))). %% should be around 50% of original length

line_dup_test() -> 
	?assert(line_muta_tester("1~n", fun generic:list_dup/2,
			fun (S, R) -> R =:= S ++ S end)).

line_clone_test() -> 
	?assert(line_muta_tester("1~n2~n", fun generic:list_clone/2,
			fun (S, R) -> 
				(R =:= S) or
				(R =:= sprintf("1~n1~n", [])) or
				(R =:= sprintf("2~n2~n", []))
			 end)).

line_repeat_test() -> 
	?assert(line_muta_tester("1~n 2~n  3~n  4~n    5~n", fun generic:list_repeat/2,
			fun (S, R) -> 
				length(string:tokens(R, [10])) > length(string:tokens(S, [10]))
			 end)).

line_swap_length_test() -> 
	?assert(line_muta_tester("1~n 2~n  3~n  4~n    5~n", fun generic:list_swap/2,
			fun (S, R) -> 
				length(string:tokens(R, [10])) =:= length(string:tokens(S, [10]))
			 end)).

line_swap_correct_test() -> 
	?assert(line_muta_tester("A~n B~n", fun generic:list_swap/2,
			fun (_S, R) -> 
				R =:= sprintf(" B~nA~n", [])
			 end)).

line_perm_length_test() -> 
	?assert(line_muta_tester("1~n 2~n  3~n  4~n    5~n", fun generic:list_perm/2,
			fun (S, R) -> 
				length(string:tokens(R, [10])) =:= length(string:tokens(S, [10]))
			 end)).


%%
%% Byte-level mutations test
%%

bytes_sum(<<B:8>>, N) -> N + B;
bytes_sum(<<B:8, T/binary>>, N) -> bytes_sum(T, N + B).

sed_byte_muta_tester(InStr, MutaFun, Check, Tries) ->
	init_randr(),
	?assert(recursive_fail_tester(
		fun () ->			
			{_F, _Rs, Ll, _Meta, _D} = MutaFun(1, [InStr], []),
			warn_false(Check(InStr, hd(Ll)), "Failed string: ~w~n", [{InStr, hd(Ll)}])
		end, fun (X) -> X end, Tries, 0)).

sed_byte_drop_test() ->
	sed_byte_muta_tester(
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), %
		mutations:construct_sed_byte_drop(),
		fun (X, Y) -> size(X) - 1 =:= size(Y) end, 1000).

sed_byte_insert_test() ->
	sed_byte_muta_tester(		
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), 
		mutations:construct_sed_byte_insert(),
		fun (X, Y) -> size(X) + 1 =:= size(Y) end, 1000).

sed_byte_repeat_test() ->
	sed_byte_muta_tester(		
		<<1>>, 
		mutations:construct_sed_byte_repeat(),
		fun (_X, Y) -> Y =:= <<1,1>> end, 1000).

sed_byte_flip_length_test() ->
	sed_byte_muta_tester(		
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), 
		mutations:construct_sed_byte_flip(),
		fun (X, Y) -> size(X) =:= size(Y) end, 1000).

sed_byte_inc_test() ->
	sed_byte_muta_tester(		
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), 
		mutations:construct_sed_byte_inc(),
		fun (X, Y) -> 
			B1 = bytes_sum(X, 0), B2 = bytes_sum(Y, 0),
			(B1 + 1 =:= B2) or (B1 - 255 =:= B2) end, 1000).

sed_byte_dec_test() ->
	sed_byte_muta_tester(		
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), 
		mutations:construct_sed_byte_dec(),
		fun (X, Y) -> 
			B1 = bytes_sum(X, 0), B2 = bytes_sum(Y, 0),
			(B1 - 1 =:= B2) or (B1 + 255 =:= B2) end, 1000).

sed_byte_random_length_test() ->
	sed_byte_muta_tester(		
		owllisp:random_block(owllisp:erand(?MAX_BLOCK_SIZE)), 
		mutations:construct_sed_byte_random(),
		fun (X, Y) -> size(X) =:= size(Y) end, 1000).