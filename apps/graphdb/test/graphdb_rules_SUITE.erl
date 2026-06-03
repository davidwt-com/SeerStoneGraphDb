%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: June 2026
%% Description: Common Test integration suite for graphdb_rules (F4
%%				Phase A).  Each test case gets its own isolated temp
%%				directory with a fresh Mnesia database and nref
%%				allocator.  Workers are started manually in dependency
%%				order; graphdb_rules is started last so its init/1
%%				seeding can rely on graphdb_attr and graphdb_class.
%%---------------------------------------------------------------------
-module(graphdb_rules_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb internal records -- no shared
%% header; copied verbatim from graphdb_instance_SUITE.erl).  The
%% #relationship{} record is exercised by the create/retrieve groups
%% added in later F4 Phase A tasks; suppress the not-yet-used warning.
%%---------------------------------------------------------------------
-compile({nowarn_unused_record, [relationship]}).

-record(node, {
	nref,
	kind,
	parents = [],
	classes = [],
	attribute_value_pairs
}).

-record(relationship, {
	id,
	kind,
	source_nref,
	characterization,
	target_nref,
	reciprocal,
	avps
}).


%%---------------------------------------------------------------------
%% Common Test callbacks
%%---------------------------------------------------------------------
-export([
	all/0,
	groups/0,
	suite/0,
	init_per_suite/1,
	end_per_suite/1,
	init_per_testcase/2,
	end_per_testcase/2
]).

%%---------------------------------------------------------------------
%% Test cases
%%---------------------------------------------------------------------
-export([
	%% seeding
	seeds_rule_meta_ontology_idempotent/1,
	seeds_rule_literals_subgroup/1,
	seeds_literal_attributes_under_rule_literals/1,
	seeds_applies_to_pair/1,
	seeded_nrefs_returns_all_twelve/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, seeding}].

groups() ->
	[
		{seeding, [], [
			seeds_rule_meta_ontology_idempotent,
			seeds_rule_literals_subgroup,
			seeds_literal_attributes_under_rule_literals,
			seeds_applies_to_pair,
			seeded_nrefs_returns_all_twelve
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
init_per_testcase(_TC, Config) ->
	Config1 = setup_isolated_env(Config),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	%% Start workers in dependency order
	{ok, _} = rel_id_server:start_link(),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	{ok, _} = graphdb_mgr:start_link(),
	{ok, _} = graphdb_attr:start_link(),
	{ok, _} = graphdb_class:start_link(),
	{ok, _} = graphdb_instance:start_link(),
	{ok, _} = graphdb_language:start_link(),
	{ok, _} = graphdb_query:start_link(),
	{ok, _} = graphdb_rules:start_link(),
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"rules_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	ok = file:set_cwd(TmpDir),
	application:set_env(mnesia, dir, MnesiaDir),
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%-----------------------------------------------------------------------------
end_per_testcase(TC, Config) ->
	verify_cache_invariant(TC),
	catch gen_server:stop(graphdb_rules),
	catch gen_server:stop(graphdb_query),
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

%% Asserts the "arcs authoritative; lists cached" invariant after each
%% testcase.  A failed verify is a fatal CT failure -- it indicates a
%% write path bug, not correctable drift.
verify_cache_invariant(TC) ->
	case mnesia:system_info(is_running) of
		yes ->
			case graphdb_mgr:verify_caches() of
				ok -> ok;
				{error, Mismatches} ->
					ct:pal("Cache invariant failed in ~p:~n~p",
						[TC, Mismatches]),
					ct:fail({cache_invariant_failed, TC, Mismatches})
			end;
		_ -> ok
	end.


%%=============================================================================
%% Seeding Tests
%%=============================================================================

seeds_rule_meta_ontology_idempotent(_Config) ->
	{ok, S1} = graphdb_rules:seeded_nrefs(),
	Rule  = maps:get(rule, S1),
	Comp  = maps:get(composition_rule, S1),
	Conn  = maps:get(connection_rule, S1),
	?assert(is_integer(Rule)),
	%% Rule is abstract (L9): is_instantiable/1 = false
	?assertEqual(false, graphdb_class:is_instantiable(Rule)),
	%% Comp/Conn are instantiable subclasses of Rule
	?assertEqual(true, graphdb_class:is_instantiable(Comp)),
	?assertEqual(true, graphdb_class:is_instantiable(Conn)),
	%% subclasses/1 returns {ok, [#node{}]} (node records, not nrefs).
	{ok, Subs} = graphdb_class:subclasses(Rule),
	SubNrefs = [N#node.nref || N <- Subs],
	?assert(lists:member(Comp, SubNrefs)),
	?assert(lists:member(Conn, SubNrefs)),
	%% Re-running init is a no-op: restart the worker, nrefs unchanged
	ok = gen_server:stop(graphdb_rules),
	{ok, _} = graphdb_rules:start_link(),
	{ok, S2} = graphdb_rules:seeded_nrefs(),
	?assertEqual(S1, S2).

seeds_rule_literals_subgroup(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Grp = maps:get(rule_literals_group, S),
	{ok, #node{parents = Parents, kind = attribute}} =
		node_read(Grp),
	?assert(lists:member(?NREF_LITERALS, Parents)).

seeds_literal_attributes_under_rule_literals(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Grp = maps:get(rule_literals_group, S),
	Keys = [child_class_nref_attr, target_class_nref_attr, template_nref_attr,
			characterization_nref_attr, mode_attr, multiplicity_attr],
	lists:foreach(fun(K) ->
		Nref = maps:get(K, S),
		{ok, #node{parents = Parents, kind = attribute}} = node_read(Nref),
		?assert(lists:member(Grp, Parents))
	end, Keys).

seeds_applies_to_pair(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	AppliesTo = maps:get(applies_to, S),
	AppliedBy = maps:get(applied_by, S),
	{ok, #node{parents = P1, kind = attribute}} = node_read(AppliesTo),
	{ok, #node{parents = P2, kind = attribute}} = node_read(AppliedBy),
	?assert(lists:member(?NREF_INST_REL_ATTRS, P1)),
	?assert(lists:member(?NREF_INST_REL_ATTRS, P2)).

seeded_nrefs_returns_all_twelve(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Expected = [rule, composition_rule, connection_rule,
				applies_to, applied_by, rule_literals_group,
				child_class_nref_attr, target_class_nref_attr,
				template_nref_attr, characterization_nref_attr,
				mode_attr, multiplicity_attr],
	lists:foreach(fun(K) -> ?assert(maps:is_key(K, S)) end, Expected),
	?assertEqual(length(Expected), maps:size(S)).


%%=============================================================================
%% Local test helpers
%%=============================================================================

%% node_read(Nref) -> {ok, #node{}} | not_found
node_read(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[N] -> {ok, N};
		[]  -> not_found
	end.

%%-----------------------------------------------------------------------------
%% ensure_loaded(App) -> ok
%%-----------------------------------------------------------------------------
ensure_loaded(App) ->
	case application:load(App) of
		ok                             -> ok;
		{error, {already_loaded, App}} -> ok
	end.


-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "rules_").


%%-----------------------------------------------------------------------------
%% delete_dir_recursive(Dir) -> ok | error({unsafe_delete, Dir})
%%-----------------------------------------------------------------------------
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
