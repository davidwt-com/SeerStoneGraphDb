%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(term_server_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0,
		 init_per_suite/1, end_per_suite/1,
		 init_per_testcase/2, end_per_testcase/2]).

-export([create_returns_true/1,
		 read_existing_key/1,
		 read_missing_key/1,
		 update_existing_key/1,
		 delete_existing_key/1,
		 all_returns_pairs/1,
		 size_returns_count/1]).

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "term_").

all() -> [{group, crud}].

groups() ->
	[{crud, [sequence], [
		create_returns_true,
		read_existing_key,
		read_missing_key,
		update_existing_key,
		delete_existing_key,
		all_returns_pairs,
		size_returns_count
	]}].

init_per_suite(Config) ->
	{ok, OrigCwd} = file:get_cwd(),
	[{orig_cwd, OrigCwd} | Config].

end_per_suite(_Config) -> ok.

init_per_testcase(_TC, Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		?DIR_PREFIX ++ Unique]),
	ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
	application:set_env(seerstone_graph_db, data_path, TmpDir),
	{ok, _} = term_server:start_link(),
	[{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
	catch gen_server:stop(term_server),
	application:unset_env(seerstone_graph_db, data_path),
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),
	TmpDir = proplists:get_value(tmp_dir, Config),
	delete_dir_recursive(TmpDir),
	ok.

%%=============================================================================
%% Test Cases
%%=============================================================================

create_returns_true(_Config) ->
	?assertEqual(true, term_server:create("hello")).

read_existing_key(_Config) ->
	true = term_server:create("greet"),
	true = term_server:update("greet", "hi"),
	Result = term_server:read("greet"),
	?assertMatch([{_, "hi"}], Result).

read_missing_key(_Config) ->
	?assertEqual([], term_server:read("no_such_key")).

update_existing_key(_Config) ->
	true = term_server:create("color"),
	true = term_server:update("color", "blue"),
	true = term_server:update("color", "red"),
	[{_, Val}] = term_server:read("color"),
	?assertEqual("red", Val).

delete_existing_key(_Config) ->
	true = term_server:create("temp"),
	true = term_server:delete("temp"),
	?assertEqual([], term_server:read("temp")).

all_returns_pairs(_Config) ->
	true = term_server:create("k1"),
	true = term_server:create("k2"),
	true = term_server:update("k1", "v1"),
	true = term_server:update("k2", "v2"),
	Pairs = term_server:all(),
	?assert(length(Pairs) >= 2).

size_returns_count(_Config) ->
	?assert(is_integer(term_server:size())),
	true = term_server:create("x"),
	N = term_server:size(),
	?assert(N >= 1).

%%=============================================================================
%% Helpers
%%=============================================================================

delete_dir_recursive(Dir) ->
	case is_safe_scratch_dir(Dir) of
		true  -> do_delete_dir(Dir);
		false -> error({unsafe_delete, Dir})
	end.

is_safe_scratch_dir(Dir) ->
	Abs = filename:absname(Dir),
	IsAbsolute = (Abs =:= Dir),
	ContainsSentinel = (string:find(Dir, ?SCRATCH_SENTINEL) =/= nomatch),
	Leaf = filename:basename(Dir),
	HasPrefix = lists:prefix(?DIR_PREFIX, Leaf),
	IsAbsolute andalso ContainsSentinel andalso HasPrefix.

do_delete_dir(Dir) ->
	{ok, Entries} = file:list_dir(Dir),
	lists:foreach(fun(E) ->
		Path = filename:join(Dir, E),
		case filelib:is_dir(Path) of
			false -> file:delete(Path);
			true  -> do_delete_dir(Path)
		end
	end, Entries),
	file:del_dir(Dir).
