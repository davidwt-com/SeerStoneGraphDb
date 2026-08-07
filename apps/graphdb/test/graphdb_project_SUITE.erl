%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-06-29
%% Description: Common Test integration suite for graphdb_project.
%%              Each test case gets its own isolated temp directory
%%              with a fresh Mnesia database and nref allocator.
%%              The full worker stack is started so graphdb_bootstrap
%%              loads the scaffold; graphdb_project (a plain module,
%%              not a gen_server) is then exercised directly.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-06-29 Author: David W. Thomas
%% Initial implementation: SP1 project registry tests.
%%---------------------------------------------------------------------
-module(graphdb_project_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb internal records — no shared hrl)
%%---------------------------------------------------------------------
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
	suite/0,
	init_per_suite/1,
	end_per_suite/1,
	init_per_group/2,
	end_per_group/2,
	init_per_testcase/2,
	end_per_testcase/2
]).

%%---------------------------------------------------------------------
%% Test cases
%%---------------------------------------------------------------------
-export([
	register_project_creates_child_of_projects/1,
	register_project_creates_tables/1,
	register_project_is_idempotent/1,
	is_project_false_for_non_child/1,
	open_returns_project_handle/1,
	open_rejects_non_project/1,
	open_rejects_project_without_store/1,
	open_rejects_project_with_partial_tables/1,
	require_project_accepts_valid_handle/1,
	require_project_rejects_malformed_term/1,
	next_nref_starts_at_one/1,
	next_nref_is_sequential/1,
	next_rel_id_pair_returns_two_consecutive_ids/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[register_project_creates_child_of_projects,
	 register_project_creates_tables,
	 register_project_is_idempotent,
	 is_project_false_for_non_child,
	 open_returns_project_handle,
	 open_rejects_non_project,
	 open_rejects_project_without_store,
	 open_rejects_project_with_partial_tables,
	 require_project_accepts_valid_handle,
	 require_project_rejects_malformed_term,
	 next_nref_starts_at_one,
	 next_nref_is_sequential,
	 next_rel_id_pair_returns_two_consecutive_ids].


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
%% init_per_group/2
%%-----------------------------------------------------------------------------
init_per_group(_Group, Config) ->
	Config.


%%-----------------------------------------------------------------------------
%% end_per_group/2
%%-----------------------------------------------------------------------------
end_per_group(_Group, _Config) ->
	ok.


%%-----------------------------------------------------------------------------
%% init_per_testcase/2
%%-----------------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
	Config1 = setup_isolated_env(Config),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	%% Start workers in dependency order (mirrors graphdb_instance_SUITE)
	{ok, _} = rel_id_server:start_link(),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	{ok, _} = graphdb_mgr:start_link(),
	{ok, _} = graphdb_attr:start_link(),
	{ok, _} = graphdb_class:start_link(),
	{ok, _} = graphdb_instance:start_link(),
	{ok, _} = graphdb_rules:start_link(),
	%% Mirror production graphdb:start/2: flip to runtime tier after all
	%% workers have seeded so that register_project allocates runtime nrefs.
	ok = graphdb_nref:set_runtime_phase(),
	Config1.


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%-----------------------------------------------------------------------------
end_per_testcase(TC, Config) ->
	verify_cache_invariant(TC),
	catch gen_server:stop(graphdb_rules),
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
%% Test Cases
%%=============================================================================

%%-----------------------------------------------------------------------------
%% register_project creates a child-of-Projects instance node.
%%-----------------------------------------------------------------------------
register_project_creates_child_of_projects(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	?assert(is_integer(P)),
	?assert(graphdb_project:is_project(P)),
	{ok, #node{kind = Kind, parents = Parents}} = graphdb_mgr:get_node(P),
	?assertEqual(instance, Kind),
	?assert(lists:member(?NREF_PROJECTS, Parents)).

%%-----------------------------------------------------------------------------
%% is_project returns false for a node that is NOT under Projects.
%%-----------------------------------------------------------------------------
is_project_false_for_non_child(_Config) ->
	?assertNot(graphdb_project:is_project(?NREF_CLASSES)).

%%-----------------------------------------------------------------------------
%% register_project creates the three physical tables, all initially empty.
%%-----------------------------------------------------------------------------
register_project_creates_tables(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	Tables = mnesia:system_info(tables),
	?assert(lists:member(list_to_atom("nodes_" ++ integer_to_list(P)), Tables)),
	?assert(lists:member(list_to_atom("relationships_" ++ integer_to_list(P)),
		Tables)),
	?assert(lists:member(list_to_atom("counters_" ++ integer_to_list(P)),
		Tables)).

%%-----------------------------------------------------------------------------
%% register_project/1 is create-if-absent: a retried call for the same
%% Name converges on the same anchor nref and the same table handle, and
%% does NOT leave a duplicate project node under Projects.
%%-----------------------------------------------------------------------------
register_project_is_idempotent(_Config) ->
	{ok, P1} = graphdb_project:register_project("Acme"),
	{ok, P2} = graphdb_project:register_project("Acme"),
	?assertEqual(P1, P2),
	{ok, Handle1} = graphdb_project:open(P1),
	{ok, Handle2} = graphdb_project:open(P2),
	?assertEqual(Handle1, Handle2),
	?assertEqual(1, count_projects_named("Acme")).

%%-----------------------------------------------------------------------------
%% open/1 returns a Project handle carrying the three table atoms.
%%-----------------------------------------------------------------------------
open_returns_project_handle(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(#{anchor => P,
	               nodes => list_to_atom("nodes_" ++ integer_to_list(P)),
	               rels => list_to_atom("relationships_" ++ integer_to_list(P)),
	               counters => list_to_atom("counters_" ++ integer_to_list(P))},
	             Project).

%%-----------------------------------------------------------------------------
%% open/1 rejects a non-project nref.
%%-----------------------------------------------------------------------------
open_rejects_non_project(_Config) ->
	?assertEqual({error, not_a_project}, graphdb_project:open(?NREF_CLASSES)).

%%-----------------------------------------------------------------------------
%% open/1 reports {error, no_store} for a registered anchor whose tables
%% were never created (the SP1-era state) -- simulated by writing an anchor
%% node directly under Projects without calling register_project/1.
%%-----------------------------------------------------------------------------
open_rejects_project_without_store(_Config) ->
	Nref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Node = #node{nref = Nref, kind = instance, parents = [?NREF_PROJECTS],
	             attribute_value_pairs = []},
	F = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id1, kind = composition,
			              source_nref = ?NREF_PROJECTS,
			              characterization = ?ARC_CAT_CHILD,
			              target_nref = Nref, reciprocal = ?ARC_CAT_PARENT,
			              avps = []}, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id2, kind = composition,
			              source_nref = Nref,
			              characterization = ?ARC_CAT_PARENT,
			              target_nref = ?NREF_PROJECTS,
			              reciprocal = ?ARC_CAT_CHILD, avps = []}, write)
	end,
	{ok, ok} = graphdb_mgr:transaction(F),
	?assert(graphdb_project:is_project(Nref)),
	?assertEqual({error, no_store}, graphdb_project:open(Nref)).

%%-----------------------------------------------------------------------------
%% open/1 reports {error, no_store} when only a subset of the three tables
%% exist -- e.g. ensure_tables/1 failed partway through, leaving nodes_<A>
%% created but relationships_<A>/counters_<A> absent. tables_exist/1 must
%% check all three, not just the nodes table.
%%-----------------------------------------------------------------------------
open_rejects_project_with_partial_tables(_Config) ->
	Nref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Node = #node{nref = Nref, kind = instance, parents = [?NREF_PROJECTS],
	             attribute_value_pairs = []},
	F = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id1, kind = composition,
			              source_nref = ?NREF_PROJECTS,
			              characterization = ?ARC_CAT_CHILD,
			              target_nref = Nref, reciprocal = ?ARC_CAT_PARENT,
			              avps = []}, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id2, kind = composition,
			              source_nref = Nref,
			              characterization = ?ARC_CAT_PARENT,
			              target_nref = ?NREF_PROJECTS,
			              reciprocal = ?ARC_CAT_CHILD, avps = []}, write)
	end,
	{ok, ok} = graphdb_mgr:transaction(F),
	NodesTable = list_to_atom("nodes_" ++ integer_to_list(Nref)),
	{atomic, ok} = mnesia:create_table(NodesTable, [
		{record_name, node},
		{attributes, record_info(fields, node)},
		{disc_copies, [node()]}
	]),
	?assert(graphdb_project:is_project(Nref)),
	?assertEqual({error, no_store}, graphdb_project:open(Nref)).

%%-----------------------------------------------------------------------------
%% require_project accepts a well-formed handle, rejects everything else.
%%-----------------------------------------------------------------------------
require_project_accepts_valid_handle(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(ok, graphdb_project:require_project(Project)).

require_project_rejects_malformed_term(_Config) ->
	?assertEqual({error, invalid_project}, graphdb_project:require_project(undefined)),
	?assertEqual({error, invalid_project}, graphdb_project:require_project(#{})).

%%-----------------------------------------------------------------------------
%% next_nref/1: first allocation yields 1; no seeding needed.
%%-----------------------------------------------------------------------------
next_nref_starts_at_one(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(1, graphdb_project:next_nref(Project)).

next_nref_is_sequential(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(1, graphdb_project:next_nref(Project)),
	?assertEqual(2, graphdb_project:next_nref(Project)),
	?assertEqual(3, graphdb_project:next_nref(Project)).

%%-----------------------------------------------------------------------------
%% next_rel_id_pair/1: two consecutive ids, independent of the nref counter.
%%-----------------------------------------------------------------------------
next_rel_id_pair_returns_two_consecutive_ids(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual({1, 2}, graphdb_project:next_rel_id_pair(Project)),
	?assertEqual({3, 4}, graphdb_project:next_rel_id_pair(Project)),
	?assertEqual(1, graphdb_project:next_nref(Project)).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% ensure_loaded(App) -> ok
%%-----------------------------------------------------------------------------
ensure_loaded(App) ->
	case application:load(App) of
		ok                             -> ok;
		{error, {already_loaded, App}} -> ok
	end.


%%-----------------------------------------------------------------------------
%% setup_isolated_env(Config) -> Config1
%%-----------------------------------------------------------------------------
setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"project_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	ok = file:set_cwd(TmpDir),
	application:set_env(mnesia, dir, MnesiaDir),
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% count_projects_named(Name) -> non_neg_integer()
%%
%% Counts the direct children of Projects (nref 5) whose instance-name AVP
%% equals Name. Used to assert register_project/1's create-if-absent
%% behaviour never leaves a duplicate anchor for a retried call.
%%-----------------------------------------------------------------------------
count_projects_named(Name) ->
	{ok, Arcs} = graphdb_mgr:get_relationships(?NREF_PROJECTS, outgoing),
	ChildNrefs = [T || #relationship{characterization = C, target_nref = T}
		<- Arcs, C =:= ?ARC_CAT_CHILD],
	length([N || N <- ChildNrefs, node_named(N, Name)]).

node_named(Nref, Name) ->
	case graphdb_mgr:get_node(Nref) of
		{ok, #node{attribute_value_pairs = AVPs}} ->
			lists:any(fun
				(#{attribute := ?NAME_ATTR_INSTANCE, value := V}) -> V =:= Name;
				(_) -> false
			end, AVPs);
		_ ->
			false
	end.


%%-----------------------------------------------------------------------------
%% verify_cache_invariant(TC) -> ok
%%-----------------------------------------------------------------------------
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


-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "project_").


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
