%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-11-13
%% Description: Common Test suite for graphdb_seeds, the persistent_term
%%				cache of every environment seed node.  Each test case
%%				gets an isolated temp directory with a fresh Mnesia
%%				database; workers are started manually and flipped to
%%				the runtime phase.  Cases call graphdb_seeds:load/0
%%				themselves.
%%---------------------------------------------------------------------
-module(graphdb_seeds_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-export([
	all/0,
	groups/0,
	suite/0,
	init_per_suite/1,
	end_per_suite/1,
	init_per_testcase/2,
	end_per_testcase/2
]).

-export([
	load_caches_every_permanent_tier_node/1,
	runtime_node_is_not_seed/1,
	lookup_by_label/1,
	non_nref_map_values_are_not_labels/1,
	unknown_label_is_not_seed/1,
	label_sources_are_disjoint/1,
	before_load_nothing_is_seed/1,
	load_skips_absent_workers/1,
	lookups_run_inside_a_transaction/1,
	load_rejects_worker_started_after_flip/1
]).

suite() ->
	[{timetrap, {seconds, 60}}].

all() ->
	[{group, cache}].

groups() ->
	[
		{cache, [], [
			load_caches_every_permanent_tier_node,
			runtime_node_is_not_seed,
			lookup_by_label,
			non_nref_map_values_are_not_labels,
			unknown_label_is_not_seed,
			label_sources_are_disjoint,
			before_load_nothing_is_seed,
			load_skips_absent_workers,
			lookups_run_inside_a_transaction,
			load_rejects_worker_started_after_flip
		]}
	].


%%-----------------------------------------------------------------------------
%% init_per_suite/1
%%-----------------------------------------------------------------------------
init_per_suite(Config) ->
	{ok, OrigCwd} = file:get_cwd(),
	ok = ensure_loaded(graphdb),
	PrivDir = code:priv_dir(graphdb),
	BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
	true = filelib:is_file(BootstrapFile),
	[{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) ->
	ok.


%%-----------------------------------------------------------------------------
%% init_per_testcase/2
%%-----------------------------------------------------------------------------
init_per_testcase(load_rejects_worker_started_after_flip, Config) ->
	Config1 = setup_isolated_env(Config),
	start_workers(Config1, false),
	ok = graphdb_nref:set_runtime_phase(),
	Config1;
init_per_testcase(_TC, Config) ->
	Config1 = setup_isolated_env(Config),
	start_workers(Config1, true),
	ok = graphdb_nref:set_runtime_phase(),
	Config1.

start_workers(Config, WithRules) ->
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	{ok, _} = rel_id_server:start_link(),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	{ok, _} = graphdb_mgr:start_link(),
	{ok, _} = graphdb_attr:start_link(),
	{ok, _} = graphdb_class:start_link(),
	{ok, _} = graphdb_instance:start_link(),
	{ok, _} = graphdb_language:start_link(),
	case WithRules of
		true  -> {ok, _} = graphdb_rules:start_link();
		false -> ok
	end,
	ok.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"seeds_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	ok = file:set_cwd(TmpDir),
	application:set_env(mnesia, dir, MnesiaDir),
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%-----------------------------------------------------------------------------
end_per_testcase(_TC, Config) ->
	catch graphdb_seeds:erase(),
	catch gen_server:stop(graphdb_rules),
	catch gen_server:stop(graphdb_language),
	catch gen_server:stop(graphdb_instance),
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	catch gen_server:stop(graphdb_nref),
	catch persistent_term:erase({graphdb_nref, phase}),
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


%%=============================================================================
%% Test cases
%%=============================================================================

load_caches_every_permanent_tier_node(_Config) ->
	ok = graphdb_seeds:load(),
	Keys = [N || N <- mnesia:dirty_all_keys(nodes), N < ?NREF_START],
	?assert(length(Keys) > 36),
	?assertEqual(length(Keys), length(graphdb_seeds:all())),
	lists:foreach(fun(N) ->
		[Row] = mnesia:dirty_read(nodes, N),
		?assert(graphdb_seeds:is_seed(N)),
		?assertEqual({ok, Row}, graphdb_seeds:node(N))
	end, Keys).

runtime_node_is_not_seed(_Config) ->
	ok = graphdb_seeds:load(),
	{ok, C} = graphdb_class:create_class("Runtime", ?NREF_CLASSES),
	?assert(C >= ?NREF_START),
	?assertNot(graphdb_seeds:is_seed(C)),
	?assertEqual(not_seed, graphdb_seeds:node(C)).

lookup_by_label(_Config) ->
	ok = graphdb_seeds:load(),
	{ok, #{retired := Ret}}      = graphdb_attr:seeded_nrefs(),
	{ok, #{applies_to := App}}   = graphdb_rules:seeded_nrefs(),
	{ok, #{lang_human := LH}}    = graphdb_language:seeded_nrefs(),
	RR = graphdb_instance:remote_reference_class(),
	?assertEqual({ok, ?ARC_INST_PARENT}, graphdb_seeds:nref(arc_inst_parent)),
	?assertEqual({ok, ?NREF_ENGLISH},    graphdb_seeds:nref(nref_english)),
	?assertEqual({ok, Ret}, graphdb_seeds:nref(retired)),
	?assertEqual({ok, App}, graphdb_seeds:nref(applies_to)),
	?assertEqual({ok, LH},  graphdb_seeds:nref(lang_human)),
	?assertEqual({ok, RR},  graphdb_seeds:nref(remote_reference_class)),
	?assertEqual(graphdb_seeds:node(Ret), graphdb_seeds:node(retired)).

non_nref_map_values_are_not_labels(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(env_language_code)).

unknown_label_is_not_seed(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(no_such_seed)),
	?assertEqual(not_seed, graphdb_seeds:node(no_such_seed)).

label_sources_are_disjoint(_Config) ->
	%% Two sources claiming one label would silently overwrite each other.
	ok = graphdb_seeds:load(),
	Ints = fun(M) -> [K || {K, V} <- maps:to_list(M), is_integer(V)] end,
	{ok, A} = graphdb_attr:seeded_nrefs(),
	{ok, L} = graphdb_language:seeded_nrefs(),
	{ok, R} = graphdb_rules:seeded_nrefs(),
	All = [K || {K, _, _, _} <- graphdb_nrefs:scaffold_spec()]
		++ Ints(A) ++ Ints(L) ++ Ints(R) ++ [remote_reference_class],
	?assertEqual(length(All), length(lists:usort(All))).

before_load_nothing_is_seed(_Config) ->
	ok = graphdb_seeds:load(),
	ok = graphdb_seeds:erase(),
	?assertNot(graphdb_seeds:is_seed(?NREF_ROOT)),
	?assertEqual(not_seed, graphdb_seeds:node(?NREF_ROOT)),
	?assertEqual(not_seed, graphdb_seeds:nref(nref_root)),
	?assertEqual([], graphdb_seeds:all()),
	?assertEqual(ok, graphdb_seeds:erase()).

load_skips_absent_workers(_Config) ->
	{ok, #{applies_to := App}} = graphdb_rules:seeded_nrefs(),
	ok = gen_server:stop(graphdb_rules),
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(applies_to)),
	?assert(graphdb_seeds:is_seed(App)).

lookups_run_inside_a_transaction(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual({atomic, true},
		mnesia:transaction(fun() -> graphdb_seeds:is_seed(?NREF_ROOT) end)).

load_rejects_worker_started_after_flip(_Config) ->
	{ok, _} = graphdb_rules:start_link(),
	{ok, #{rule := Rule}} = graphdb_rules:seeded_nrefs(),
	?assert(Rule >= ?NREF_START),
	?assertMatch({error, {label_not_seed, _, N}} when N >= ?NREF_START,
		graphdb_seeds:load()),
	?assertNot(graphdb_seeds:is_seed(?NREF_ROOT)).


%%=============================================================================
%% Helpers
%%=============================================================================

ensure_loaded(App) ->
	case application:load(App) of
		ok                             -> ok;
		{error, {already_loaded, App}} -> ok
	end.

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "seeds_").

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
	case filelib:is_dir(Dir) of
		true ->
			{ok, Entries} = file:list_dir(Dir),
			lists:foreach(fun(E) ->
				Path = filename:join(Dir, E),
				case filelib:is_dir(Path) of
					true  -> do_delete_dir(Path);
					false -> file:delete(Path)
				end
			end, Entries),
			file:del_dir(Dir);
		false ->
			ok
	end.
