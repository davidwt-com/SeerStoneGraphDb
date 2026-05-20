%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-20
%% Description: Common Test suite for graphdb_nrefs congruency
%%              verification and bootstrap module lifecycle.
%%---------------------------------------------------------------------
-module(graphdb_nrefs_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "nrefs_").

%%---------------------------------------------------------------------
%% Common Test callbacks
%%---------------------------------------------------------------------
-export([all/0, groups/0, suite/0,
		 init_per_suite/1, end_per_suite/1,
		 init_per_testcase/2, end_per_testcase/2]).

%%---------------------------------------------------------------------
%% Test cases
%%---------------------------------------------------------------------
-export([verify_returns_ok/1,
		 bootstrap_module_unloaded/1]).

suite() -> [{timetrap, {seconds, 30}}].

all() -> [{group, congruency}].

groups() ->
	[{congruency, [sequence], [
		verify_returns_ok,
		bootstrap_module_unloaded
	]}].


%%---------------------------------------------------------------------
%% Suite setup
%%---------------------------------------------------------------------
init_per_suite(Config) ->
	{ok, OrigCwd} = file:get_cwd(),
	ok = case application:load(graphdb) of
		ok -> ok;
		{error, {already_loaded, graphdb}} -> ok
	end,
	PrivDir = code:priv_dir(graphdb),
	BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
	true = filelib:is_file(BootstrapFile),
	[{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) -> ok.


%%---------------------------------------------------------------------
%% Per-testcase setup/teardown
%%---------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		?DIR_PREFIX ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
	ok = file:set_cwd(TmpDir),
	application:set_env(mnesia, dir, MnesiaDir),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	{ok, _} = application:ensure_all_started(nref),
	{ok, _} = rel_id_server:start_link(),
	{ok, _} = graphdb_mgr:start_link(),
	[{tmp_dir, TmpDir} | Config].

end_per_testcase(TC, Config) ->
	verify_cache_invariant(TC),
	catch gen_server:stop(graphdb_mgr),
	catch gen_server:stop(rel_id_server),
	catch application:stop(nref),
	catch mnesia:stop(),
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
	catch dets:close(rel_id_server),
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),
	TmpDir = proplists:get_value(tmp_dir, Config),
	delete_dir_recursive(TmpDir),
	application:unset_env(seerstone_graph_db, bootstrap_file),
	application:unset_env(mnesia, dir),
	ok.


%%=====================================================================
%% Test Cases
%%=====================================================================

%%---------------------------------------------------------------------
%% After a successful bootstrap, every macro value must match its
%% corresponding Mnesia node (kind + name AVP).
%%---------------------------------------------------------------------
verify_returns_ok(_Config) ->
	?assertEqual(ok, graphdb_nrefs:verify()).

%%---------------------------------------------------------------------
%% graphdb_mgr:init/1 unloads graphdb_bootstrap from the code server
%% after a successful load.  code:is_loaded/1 returns false when a
%% module is absent from the code server.
%%---------------------------------------------------------------------
bootstrap_module_unloaded(_Config) ->
	?assertEqual(false, code:is_loaded(graphdb_bootstrap)).


%%=====================================================================
%% Helpers
%%=====================================================================

verify_cache_invariant(TC) ->
	case mnesia:system_info(is_running) of
		yes ->
			case graphdb_mgr:verify_caches() of
				ok -> ok;
				{error, Mismatches} ->
					ct:pal("Cache invariant failed in ~p:~n~p", [TC, Mismatches]),
					ct:fail({cache_invariant_failed, TC, Mismatches})
			end;
		_ -> ok
	end.

delete_dir_recursive(Dir) ->
	IsAbsolute = filename:pathtype(Dir) =:= absolute,
	HasSentinel = string:find(Dir, ?SCRATCH_SENTINEL) =/= nomatch,
	HasPrefix = lists:prefix(?DIR_PREFIX, filename:basename(Dir)),
	case IsAbsolute andalso HasSentinel andalso HasPrefix of
		true  -> os:cmd("rm -rf \"" ++ Dir ++ "\""), ok;
		false -> ct:fail({unsafe_delete, Dir})
	end.
