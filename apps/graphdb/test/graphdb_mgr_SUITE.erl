%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: Common Test integration suite for graphdb_mgr.
%%				Each test case gets an isolated Mnesia database and
%%				fresh nref allocator state in a private temp directory.
%%				Tests verify init/1 bootstrap wiring, read operations,
%%				category immutability guard, and write operation API
%%				skeleton.
%%---------------------------------------------------------------------
-module(graphdb_mgr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb_mgr/bootstrap internal records)
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
	%% Bootstrap/init
	init_runs_bootstrap/1,
	init_idempotent_restart/1,
	init_fails_on_bad_config/1,
	%% get_node
	get_node_root/1,
	get_node_attribute/1,
	get_node_not_found/1,
	%% get_relationships
	get_relationships_outgoing/1,
	get_relationships_incoming/1,
	get_relationships_both/1,
	get_relationships_empty/1,
	%% Category guard
	category_guard_delete/1,
	category_guard_update/1,
	category_guard_allows_noncategory_delete/1,
	category_guard_allows_noncategory_update/1,
	category_guard_delete_nonexistent/1,
	%% Write delegation
	create_name_attribute_delegates/1,
	create_literal_attribute_delegates/1,
	create_relationship_attribute_delegates/1,
	create_relationship_type_delegates/1,
	create_relationship_attribute_missing_avps/1,
	create_attribute_unknown_parent/1,
	create_class_delegates/1,
	create_instance_delegates/1,
	add_relationship_delegates/1,
	%% Cache audit / repair
	verify_caches_clean_after_bootstrap/1,
	verify_caches_detects_poisoned_parents/1,
	verify_caches_detects_poisoned_classes/1,
	rebuild_caches_restores_after_poison/1,
	%% Transaction seam
	transaction_commit_returns_ok/1,
	transaction_abort_rolls_back/1,
	transaction_composition_rolls_back/1,
	transaction_crash_passes_through/1,
	%% Soft-retire
	retire_node_sets_and_clears_marker/1,
	retire_node_is_idempotent/1,
	retire_node_refuses_permanent_tier/1,
	retire_node_not_found/1,
	get_node_hides_retired/1,
	%% Batch mutate
	mutate_empty_batch/1,
	mutate_single_add_relationship/1,
	mutate_single_retire_and_unretire/1,
	mutate_mixed_all_succeed/1,
	mutate_atomic_rollback/1,
	mutate_read_your_writes_rollback/1,
	mutate_malformed_term/1,
	mutate_permanent_tier_guard/1,
	mutate_add_relationship_explicit_template/1,
	mutate_add_relationship_with_avps/1,
	%% update_node_avps (solo / tier-2 path)
	update_node_avps_upsert_roundtrip/1,
	update_node_avps_overwrite_preserves_head/1,
	update_node_avps_delete/1,
	update_node_avps_delete_absent_noop/1,
	update_node_avps_undefined_retained/1,
	update_node_avps_unknown_attribute/1,
	update_node_avps_retired_marker_rejected/1,
	update_node_avps_not_found/1,
	update_node_avps_permanent_tier/1,
	update_node_avps_atomic_rollback/1,
	mutate_single_update_node_avps/1,
	mutate_mixed_add_rel_and_update_avps/1,
	mutate_update_avps_rollback/1,
	mutate_update_avps_malformed/1,
	mutate_update_avps_not_found/1,
	%% instance-only QC enforcement
	update_node_avps_rejects_instance_only/1,
	update_node_avps_delete_instance_only_ok/1,
	mutate_rejects_instance_only/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, init_tests}, {group, read_ops},
	 {group, category_guard}, {group, write_delegation},
	 {group, cache_audit}, {group, transaction_seam},
	 {group, soft_retire}, {group, mutate}, {group, update_avps}].

groups() ->
	[
		{init_tests, [], [
			init_runs_bootstrap,
			init_idempotent_restart,
			init_fails_on_bad_config
		]},
		{read_ops, [], [
			get_node_root,
			get_node_attribute,
			get_node_not_found,
			get_relationships_outgoing,
			get_relationships_incoming,
			get_relationships_both,
			get_relationships_empty
		]},
		{category_guard, [], [
			category_guard_delete,
			category_guard_update,
			category_guard_allows_noncategory_delete,
			category_guard_allows_noncategory_update,
			category_guard_delete_nonexistent
		]},
		{write_delegation, [], [
			create_name_attribute_delegates,
			create_literal_attribute_delegates,
			create_relationship_attribute_delegates,
			create_relationship_type_delegates,
			create_relationship_attribute_missing_avps,
			create_attribute_unknown_parent,
			create_class_delegates,
			create_instance_delegates,
			add_relationship_delegates
		]},
		{cache_audit, [], [
			verify_caches_clean_after_bootstrap,
			verify_caches_detects_poisoned_parents,
			verify_caches_detects_poisoned_classes,
			rebuild_caches_restores_after_poison
		]},
		{transaction_seam, [], [
			transaction_commit_returns_ok,
			transaction_abort_rolls_back,
			transaction_composition_rolls_back,
			transaction_crash_passes_through
		]},
		{soft_retire, [], [
			retire_node_sets_and_clears_marker,
			retire_node_is_idempotent,
			retire_node_refuses_permanent_tier,
			retire_node_not_found,
			get_node_hides_retired
		]},
		{mutate, [], [
			mutate_empty_batch,
			mutate_single_add_relationship,
			mutate_single_retire_and_unretire,
			mutate_mixed_all_succeed,
			mutate_atomic_rollback,
			mutate_read_your_writes_rollback,
			mutate_malformed_term,
			mutate_permanent_tier_guard,
			mutate_add_relationship_explicit_template,
			mutate_add_relationship_with_avps,
			mutate_single_update_node_avps,
			mutate_mixed_add_rel_and_update_avps,
			mutate_update_avps_rollback,
			mutate_update_avps_malformed,
			mutate_update_avps_not_found,
			mutate_rejects_instance_only
		]},
		{update_avps, [], [
			update_node_avps_upsert_roundtrip,
			update_node_avps_overwrite_preserves_head,
			update_node_avps_delete,
			update_node_avps_delete_absent_noop,
			update_node_avps_undefined_retained,
			update_node_avps_unknown_attribute,
			update_node_avps_retired_marker_rejected,
			update_node_avps_not_found,
			update_node_avps_permanent_tier,
			update_node_avps_atomic_rollback,
			update_node_avps_rejects_instance_only,
			update_node_avps_delete_instance_only_ok
		]}
	].


%%-----------------------------------------------------------------------------
%% init_per_suite/1
%%
%% Saves the original working directory and computes the absolute path
%% to bootstrap.terms via code:priv_dir (works regardless of cwd).
%%-----------------------------------------------------------------------------
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

end_per_suite(_Config) ->
	ok.


%%-----------------------------------------------------------------------------
%% init_per_testcase/2
%%
%% Creates an isolated temp directory, changes cwd so nref DETS files
%% go there, configures a private Mnesia dir, sets the bootstrap_file
%% env, starts nref, and (for most tests) starts graphdb_mgr.
%%
%% write_delegation tests also start graphdb_attr, graphdb_class, and
%% graphdb_instance so that delegated calls can reach the workers.
%%-----------------------------------------------------------------------------
init_per_testcase(init_fails_on_bad_config, Config) ->
	%% Special setup for error test -- bad bootstrap path
	Config1 = setup_isolated_env(Config),
	BadPath = filename:join(proplists:get_value(tmp_dir, Config1),
		"does_not_exist.terms"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadPath),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	Config1;
init_per_testcase(TC, Config) when
		TC =:= create_name_attribute_delegates;
		TC =:= create_literal_attribute_delegates;
		TC =:= create_relationship_attribute_delegates;
		TC =:= create_relationship_type_delegates;
		TC =:= create_relationship_attribute_missing_avps;
		TC =:= create_attribute_unknown_parent;
		TC =:= create_class_delegates;
		TC =:= create_instance_delegates;
		TC =:= add_relationship_delegates;
		TC =:= retire_node_sets_and_clears_marker;
		TC =:= retire_node_is_idempotent;
		TC =:= retire_node_refuses_permanent_tier;
		TC =:= retire_node_not_found;
		TC =:= get_node_hides_retired;
		TC =:= mutate_empty_batch;
		TC =:= mutate_single_add_relationship;
		TC =:= mutate_single_retire_and_unretire;
		TC =:= mutate_mixed_all_succeed;
		TC =:= mutate_atomic_rollback;
		TC =:= mutate_read_your_writes_rollback;
		TC =:= mutate_malformed_term;
		TC =:= mutate_permanent_tier_guard;
		TC =:= mutate_add_relationship_explicit_template;
		TC =:= mutate_add_relationship_with_avps;
		TC =:= update_node_avps_upsert_roundtrip;
		TC =:= update_node_avps_overwrite_preserves_head;
		TC =:= update_node_avps_delete;
		TC =:= update_node_avps_delete_absent_noop;
		TC =:= update_node_avps_undefined_retained;
		TC =:= update_node_avps_unknown_attribute;
		TC =:= update_node_avps_retired_marker_rejected;
		TC =:= update_node_avps_not_found;
		TC =:= update_node_avps_permanent_tier;
		TC =:= update_node_avps_atomic_rollback;
		TC =:= mutate_single_update_node_avps;
		TC =:= mutate_mixed_add_rel_and_update_avps;
		TC =:= mutate_update_avps_rollback;
		TC =:= mutate_update_avps_malformed;
		TC =:= mutate_update_avps_not_found;
		TC =:= update_node_avps_rejects_instance_only;
		TC =:= update_node_avps_delete_instance_only_ok;
		TC =:= mutate_rejects_instance_only ->
	Config1 = setup_isolated_env(Config),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	%% Start rel_id_server first (needed for relationship ID allocation)
	{ok, _} = rel_id_server:start_link(),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	%% Start mgr first (runs bootstrap, sets up tables), then workers
	{ok, _} = graphdb_mgr:start_link(),
	{ok, _} = graphdb_attr:start_link(),
	{ok, _} = graphdb_class:start_link(),
	{ok, _} = graphdb_instance:start_link(),
	{ok, _} = graphdb_rules:start_link(),
	%% Mirror production graphdb:start/2: flip to runtime tier after all
	%% workers have seeded so that user-level create_* calls allocate runtime nrefs.
	ok = graphdb_nref:set_runtime_phase(),
	Config1;
init_per_testcase(_TC, Config) ->
	Config1 = setup_isolated_env(Config),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	%% Start rel_id_server first (needed for relationship ID allocation)
	{ok, _} = rel_id_server:start_link(),
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"mgr_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	%% Change cwd so nref DETS files are created in the temp dir
	ok = file:set_cwd(TmpDir),

	%% Configure Mnesia to use the private directory
	application:set_env(mnesia, dir, MnesiaDir),

	%% Start nref fresh (DETS files created in TmpDir)
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%
%% Stops workers, graphdb_mgr, nref, Mnesia, restores cwd, and deletes
%% temp dir.
%%-----------------------------------------------------------------------------
end_per_testcase(TC, Config) ->
	verify_cache_invariant(TC),
	%% Stop workers if running (write_delegation tests start these)
	catch gen_server:stop(graphdb_rules),
	catch gen_server:stop(graphdb_instance),
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	%% Stop graphdb_mgr if running
	catch gen_server:stop(graphdb_mgr),
	catch gen_server:stop(graphdb_nref),
	catch persistent_term:erase({graphdb_nref, phase}),
	catch gen_server:stop(rel_id_server),

	%% Stop applications (ignore errors -- they may not be running)
	catch application:stop(nref),
	catch mnesia:stop(),

	%% Close any lingering DETS tables
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
	catch dets:close(rel_id_server),

	%% Restore original cwd
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),

	%% Delete the temp directory recursively
	TmpDir = proplists:get_value(tmp_dir, Config),
	delete_dir_recursive(TmpDir),

	%% Unset app env to avoid leaking between test cases
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
%% Init/Bootstrap Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Verify that starting graphdb_mgr triggers bootstrap load.
%%-----------------------------------------------------------------------------
init_runs_bootstrap(_Config) ->
	{ok, _Pid} = graphdb_mgr:start_link(),
	%% Tables should exist
	?assert(lists:member(nodes, mnesia:system_info(tables))),
	?assert(lists:member(relationships, mnesia:system_info(tables))),
	%% 38 nodes and 76 relationship rows should be loaded
	?assertEqual(38, mnesia:table_info(nodes, size)),
	?assertEqual(76, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% Verify that stopping and restarting graphdb_mgr is idempotent --
%% bootstrap does not reload or duplicate data.
%%-----------------------------------------------------------------------------
init_idempotent_restart(_Config) ->
	{ok, _Pid1} = graphdb_mgr:start_link(),
	NodesBefore = mnesia:table_info(nodes, size),
	RelsBefore = mnesia:table_info(relationships, size),

	%% Stop and restart
	ok = gen_server:stop(graphdb_mgr),
	{ok, _Pid2} = graphdb_mgr:start_link(),

	?assertEqual(NodesBefore, mnesia:table_info(nodes, size)),
	?assertEqual(RelsBefore, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% Verify that init fails if bootstrap fails (bad file path).
%% Must trap exits because start_link propagates the gen_server exit.
%%-----------------------------------------------------------------------------
init_fails_on_bad_config(_Config) ->
	process_flag(trap_exit, true),
	Result = graphdb_mgr:start_link(),
	?assertMatch({error, {bootstrap_failed, _}}, Result),
	%% Flush the EXIT message from the linked gen_server
	receive {'EXIT', _, _} -> ok after 1000 -> ok end.


%%=============================================================================
%% Read Operation Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_node returns Root (nref 1) correctly.
%%-----------------------------------------------------------------------------
get_node_root(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Root} = graphdb_mgr:get_node(1),
	?assertEqual(1, Root#node.nref),
	?assertEqual(category, Root#node.kind),
	?assertEqual([], Root#node.parents),
	?assertEqual([#{attribute => ?NAME_ATTR_CATEGORY, value => "Root"}],
		Root#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% get_node returns an attribute node (nref 18 -- Name, self-ref) correctly.
%%-----------------------------------------------------------------------------
get_node_attribute(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Node} = graphdb_mgr:get_node(?NAME_ATTR_ATTRIBUTE),
	?assertEqual(?NAME_ATTR_ATTRIBUTE, Node#node.nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual([10], Node#node.parents),    %% parent: Attribute Name Attributes
	?assertEqual([#{attribute => ?NAME_ATTR_ATTRIBUTE, value => "Name"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% get_node returns {error, not_found} for nonexistent nref.
%%-----------------------------------------------------------------------------
get_node_not_found(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_found}, graphdb_mgr:get_node(99999)).

%%-----------------------------------------------------------------------------
%% get_relationships returns outgoing arcs for Root.
%% Root has outgoing child arcs to 2, 3, 4, 5 (characterization=22).
%%-----------------------------------------------------------------------------
get_relationships_outgoing(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(1),
	Targets = lists:sort([R#relationship.target_nref || R <- Rels]),
	?assertEqual([2, 3, 4, 5], Targets),
	%% All should have characterization=22 (Child/CatRel)
	?assert(lists:all(fun(R) ->
		R#relationship.characterization =:= ?ARC_CAT_CHILD
	end, Rels)).

%%-----------------------------------------------------------------------------
%% get_relationships with incoming direction.
%% Attributes(2) has incoming arcs from:
%%   Root(1)  -- child arc (char=22)
%%   Names(6), Literals(7), Relationships(8) -- parent arcs (char=23)
%%-----------------------------------------------------------------------------
get_relationships_incoming(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(2, incoming),
	Sources = lists:sort([R#relationship.source_nref || R <- Rels]),
	?assertEqual([1, 6, 7, 8], Sources).

%%-----------------------------------------------------------------------------
%% get_relationships with both directions -- should be union of out + in.
%%-----------------------------------------------------------------------------
get_relationships_both(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, OutRels} = graphdb_mgr:get_relationships(2, outgoing),
	{ok, InRels} = graphdb_mgr:get_relationships(2, incoming),
	{ok, BothRels} = graphdb_mgr:get_relationships(2, both),
	?assertEqual(length(OutRels) + length(InRels), length(BothRels)).

%%-----------------------------------------------------------------------------
%% get_relationships returns empty list for nonexistent node.
%%-----------------------------------------------------------------------------
get_relationships_empty(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(99999, outgoing),
	?assertEqual([], Rels).


%%=============================================================================
%% Category Guard Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% delete_node rejects category nodes (Root=1, Attributes=2).
%%-----------------------------------------------------------------------------
category_guard_delete(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:delete_node(1)),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:delete_node(2)).

%%-----------------------------------------------------------------------------
%% update_node_avps rejects category nodes.
%%-----------------------------------------------------------------------------
category_guard_update(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:update_node_avps(1, [#{attribute => 99, value => "test"}])).

%%-----------------------------------------------------------------------------
%% delete_node passes guard for non-category nodes (returns not_implemented).
%%-----------------------------------------------------------------------------
category_guard_allows_noncategory_delete(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute node -- should pass guard
	?assertEqual({error, not_implemented},
		graphdb_mgr:delete_node(6)).

%%-----------------------------------------------------------------------------
%% update_node_avps passes the category guard for non-category nodes; nref 6
%% is permanent-tier, so it is then refused with permanent_node_immutable
%% (proving it cleared the category guard rather than being rejected as a
%% category node).
%%-----------------------------------------------------------------------------
category_guard_allows_noncategory_update(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute node -- clears the category guard
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:update_node_avps(6, [#{attribute => 99, value => "test"}])).

%%-----------------------------------------------------------------------------
%% delete_node returns not_found for nonexistent node.
%%-----------------------------------------------------------------------------
category_guard_delete_nonexistent(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_found},
		graphdb_mgr:delete_node(99999)).


%%=============================================================================
%% Write Delegation Tests
%%
%% Each test verifies that graphdb_mgr correctly routes a write call to
%% the appropriate worker and that the result is retrievable.  Workers
%% (graphdb_attr, graphdb_class, graphdb_instance) are pre-started in
%% init_per_testcase for this group.
%%=============================================================================

%%-----------------------------------------------------------------------------
%% create_attribute delegates to create_name_attribute for Names subtree.
%% ParentNref=6 (Names).
%%-----------------------------------------------------------------------------
create_name_attribute_delegates(_Config) ->
	{ok, Nref} = graphdb_mgr:create_attribute("TestNameAttr", 6, #{}),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(attribute, Node#node.kind).

%%-----------------------------------------------------------------------------
%% create_attribute delegates to create_literal_attribute for Literals subtree.
%% ParentNref=7 (Literals), AVPs=#{type => string}.
%%-----------------------------------------------------------------------------
create_literal_attribute_delegates(_Config) ->
	{ok, Nref} = graphdb_mgr:create_attribute("TestLiteralAttr", 7, #{type => string}),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(attribute, Node#node.kind).

%%-----------------------------------------------------------------------------
%% create_attribute delegates to create_relationship_attribute for the
%% Relationships subtree when reciprocal_name and target_kind are both present.
%% Returns {ok, FwdNref} (forward nref of the pair).
%%-----------------------------------------------------------------------------
create_relationship_attribute_delegates(_Config) ->
	{ok, Nref} = graphdb_mgr:create_attribute(
		"Has", 8, #{reciprocal_name => "BelongsTo", target_kind => instance}),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(attribute, Node#node.kind).

%%-----------------------------------------------------------------------------
%% create_attribute delegates to create_relationship_type when no reciprocal
%% keys are present (bare Relationships parent, no AVPs).
%%-----------------------------------------------------------------------------
create_relationship_type_delegates(_Config) ->
	{ok, Nref} = graphdb_mgr:create_attribute("MyRelType", 8, #{}),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(attribute, Node#node.kind).

%%-----------------------------------------------------------------------------
%% create_attribute returns an error when exactly one of reciprocal_name /
%% target_kind is present (partial AVPs).  Both-or-neither is required for
%% the Relationships subtree; one-of-two is the missing_avps error path.
%%-----------------------------------------------------------------------------
create_relationship_attribute_missing_avps(_Config) ->
	?assertMatch({error, _},
		graphdb_mgr:create_attribute("Has", 8, #{reciprocal_name => "BelongsTo"})).

%%-----------------------------------------------------------------------------
%% create_attribute returns {error, {unknown_attribute_parent, _}} for a
%% ParentNref that does not belong to any recognised attribute subtree.
%%-----------------------------------------------------------------------------
create_attribute_unknown_parent(_Config) ->
	?assertEqual({error, {unknown_attribute_parent, 99}},
		graphdb_mgr:create_attribute("Bad", 99, #{})).

%%-----------------------------------------------------------------------------
%% create_class delegates to graphdb_class; the new node is readable.
%%-----------------------------------------------------------------------------
create_class_delegates(_Config) ->
	{ok, Nref} = graphdb_mgr:create_class("TestClass", 3),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(class, Node#node.kind).

%%-----------------------------------------------------------------------------
%% create_instance delegates to graphdb_instance.  A class must exist first;
%% we use graphdb_class:create_class/2 directly to set up the prerequisite.
%%-----------------------------------------------------------------------------
create_instance_delegates(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("TestClass2", 3),
	{ok, Nref, _} = graphdb_mgr:create_instance("TestInst", ClassNref, 5),
	?assert(is_integer(Nref)),
	{ok, Node} = graphdb_mgr:get_node(Nref),
	?assertEqual(instance, Node#node.kind).

%%-----------------------------------------------------------------------------
%% add_relationship delegates to graphdb_instance.  Two instances and a
%% relationship attribute pair are created as prerequisites.
%%-----------------------------------------------------------------------------
add_relationship_delegates(_Config) ->
	%% Create a class and two instances
	{ok, ClassNref} = graphdb_class:create_class("RelClass", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	%% Create a reciprocal relationship attribute pair (char/reciprocal nrefs)
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	%% Delegate through mgr
	?assertEqual(ok,
		graphdb_mgr:add_relationship(InstA, CharNref, InstB, RecipNref)),
	%% Verify the arc is readable
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([InstB], Targets).


%%=============================================================================
%% Cache Audit / Repair Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% A freshly bootstrapped database satisfies the cache invariant: every
%% node's parents/classes lists agree with the relationships table.
%%-----------------------------------------------------------------------------
verify_caches_clean_after_bootstrap(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual(ok, graphdb_mgr:verify_caches()).

%%-----------------------------------------------------------------------------
%% Poisoning a node's parents cache makes verify_caches return an error
%% tuple naming the offending node, the field, the expected value (from
%% the arcs), and the actual cached value.
%%-----------------------------------------------------------------------------
verify_caches_detects_poisoned_parents(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute child of nref 2 (Attributes); the
	%% bootstrap arc 2 -> 6 makes parents=[2] the truth.
	{atomic, ok} = mnesia:transaction(fun() ->
		[Node] = mnesia:read(nodes, 6),
		Poisoned = Node#node{parents = [9999]},
		mnesia:write(nodes, Poisoned, write)
	end),
	{error, Mismatches} = graphdb_mgr:verify_caches(),
	?assertEqual([{6, parents, [2], [9999]}], Mismatches),
	%% Restore so end_per_testcase verify_cache_invariant doesn't trip.
	ok = graphdb_mgr:rebuild_caches().

%%-----------------------------------------------------------------------------
%% Poisoning a non-instance node's classes cache (which should be []) is
%% also detected.  Bootstrap nodes are all non-instance, so any non-empty
%% classes list is a mismatch.
%%-----------------------------------------------------------------------------
verify_caches_detects_poisoned_classes(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{atomic, ok} = mnesia:transaction(fun() ->
		[Node] = mnesia:read(nodes, 7),
		Poisoned = Node#node{classes = [42]},
		mnesia:write(nodes, Poisoned, write)
	end),
	{error, Mismatches} = graphdb_mgr:verify_caches(),
	?assertEqual([{7, classes, [], [42]}], Mismatches),
	%% Restore so end_per_testcase verify_cache_invariant doesn't trip.
	ok = graphdb_mgr:rebuild_caches().

%%-----------------------------------------------------------------------------
%% rebuild_caches/0 rewrites every node's cache from the arcs.  After a
%% rebuild, verify_caches/0 must return ok even if multiple caches were
%% poisoned.
%%-----------------------------------------------------------------------------
rebuild_caches_restores_after_poison(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{atomic, ok} = mnesia:transaction(fun() ->
		[N6]  = mnesia:read(nodes, 6),
		[N7]  = mnesia:read(nodes, 7),
		[N18] = mnesia:read(nodes, ?NAME_ATTR_ATTRIBUTE),
		mnesia:write(nodes, N6#node{parents = [9999]}, write),
		mnesia:write(nodes, N7#node{classes = [42]}, write),
		mnesia:write(nodes, N18#node{parents = []}, write)
	end),
	{error, Mismatches} = graphdb_mgr:verify_caches(),
	?assertEqual(3, length(Mismatches)),
	ok = graphdb_mgr:rebuild_caches(),
	?assertEqual(ok, graphdb_mgr:verify_caches()),
	{atomic, [Restored18]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, ?NAME_ATTR_ATTRIBUTE)
	end),
	?assertEqual([10], Restored18#node.parents).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Safe scratch directory for test isolation.  All temp dirs are created
%% under this path by init_per_testcase/2.
%%-----------------------------------------------------------------------------
-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "mgr_").


%%-----------------------------------------------------------------------------
%% delete_dir_recursive(Dir) -> ok | error({unsafe_delete, Dir})
%%
%% Recursively deletes a directory and all its contents.
%%
%% Safety: refuses to operate unless ALL of the following hold:
%%   1. Dir is an absolute path
%%   2. Dir contains the path segment "_build/test/ct_scratch/"
%%   3. The leaf directory name starts with "mgr_"
%%
%% These guards ensure this function can never be misused to delete
%% project source, home directories, or anything outside the test
%% scratch area, even if called with a wrong argument.
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


%%=============================================================================
%% Transaction Seam Tests
%%
%% Sample throwaway primitives write bare #node rows at scratch nrefs in the
%% ?NREF_START + 500_000 band (well clear of bootstrap and other suites'
%% runtime allocations); each case runs in its own isolated Mnesia DB.
%%=============================================================================

%%-----------------------------------------------------------------------------
%% transaction/1 commits a primitive's writes and returns {ok, Result}.
%%-----------------------------------------------------------------------------
transaction_commit_returns_ok(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	Nref1 = ?NREF_START + 500001,
	Nref2 = ?NREF_START + 500002,
	Fun = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = Nref1, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		ok = mnesia:write(nodes,
			#node{nref = Nref2, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		{written, 2}
	end,
	?assertEqual({ok, {written, 2}}, graphdb_mgr:transaction(Fun)),
	?assertMatch([#node{nref = Nref1}], mnesia:dirty_read(nodes, Nref1)),
	?assertMatch([#node{nref = Nref2}], mnesia:dirty_read(nodes, Nref2)).

%%-----------------------------------------------------------------------------
%% transaction/1 maps mnesia:abort/1 to {error, Reason} and rolls back the
%% primitive's write (single-primitive atomicity).
%%-----------------------------------------------------------------------------
transaction_abort_rolls_back(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	NrefA = ?NREF_START + 500010,
	Fun = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = NrefA, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		mnesia:abort(blocked)
	end,
	?assertEqual({error, blocked}, graphdb_mgr:transaction(Fun)),
	?assertEqual([], mnesia:dirty_read(nodes, NrefA)).

%%-----------------------------------------------------------------------------
%% transaction/1 over a composition of two primitives rolls back BOTH when
%% the second aborts -- the property tier-3 batch composition relies on.
%%-----------------------------------------------------------------------------
transaction_composition_rolls_back(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	NrefP = ?NREF_START + 500020,
	First = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = NrefP, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write)
	end,
	Second = fun() -> mnesia:abort(second_failed) end,
	Fun = fun() -> First(), Second() end,
	?assertEqual({error, second_failed}, graphdb_mgr:transaction(Fun)),
	?assertEqual([], mnesia:dirty_read(nodes, NrefP)).

%%-----------------------------------------------------------------------------
%% An uncaught crash inside the fun surfaces as Mnesia's standard
%% {aborted, {Reason, Stacktrace}} shape, passed through unreshaped as
%% {error, {Reason, Stacktrace}} (design doc section 4), and rolls back the
%% primitive's write.
%%-----------------------------------------------------------------------------
transaction_crash_passes_through(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	NrefC = ?NREF_START + 500030,
	Fun = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = NrefC, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		%% Uncaught crash -- not a deliberate mnesia:abort/1.
		erlang:error(crash_in_txn)
	end,
	?assertMatch({error, {crash_in_txn, _Stack}},
		graphdb_mgr:transaction(Fun)),
	?assertEqual([], mnesia:dirty_read(nodes, NrefC)).


%%=============================================================================
%% Soft-Retire Tests
%%
%% Workers (graphdb_attr, graphdb_class, graphdb_instance, graphdb_rules) are
%% pre-started by init_per_testcase (full-stack clause).  The `retired` nref
%% is resolved lazily on first use from graphdb_attr:seeded_nrefs/0.
%%=============================================================================

%%-----------------------------------------------------------------------------
%% retire_node stamps the `retired` boolean AVP; unretire_node removes it.
%%-----------------------------------------------------------------------------
retire_node_sets_and_clears_marker(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("RetireMe", 3),
	?assert(ClassNref >= ?NREF_START),
	ok = graphdb_mgr:retire_node(ClassNref),
	[#node{attribute_value_pairs = AVPs1}] =
		mnesia:dirty_read(nodes, ClassNref),
	%% Consideration (future hardening): this predicate matches ANY
	%% value=>true AVP, not the `retired` attribute specifically. A fresh
	%% class carries no other boolean-true AVP today, so it is not a false
	%% positive — but a stricter, attribute-specific check would be:
	%%   {ok, #{retired := RetiredNref}} = graphdb_attr:seeded_nrefs(),
	%%   ?assert(lists:any(
	%%       fun(#{attribute := A, value := true}) when A =:= RetiredNref -> true;
	%%          (_) -> false end, AVPs1)),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs1)),
	ok = graphdb_mgr:unretire_node(ClassNref),
	[#node{attribute_value_pairs = AVPs2}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs2)).

%%-----------------------------------------------------------------------------
%% retire_node and unretire_node are both idempotent.
%%-----------------------------------------------------------------------------
retire_node_is_idempotent(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("RetireIdem", 3),
	ok = graphdb_mgr:retire_node(ClassNref),
	ok = graphdb_mgr:retire_node(ClassNref),
	ok = graphdb_mgr:unretire_node(ClassNref),
	ok = graphdb_mgr:unretire_node(ClassNref).

%%-----------------------------------------------------------------------------
%% Both operations refuse permanent-tier nrefs (Nref < ?NREF_START).
%%-----------------------------------------------------------------------------
retire_node_refuses_permanent_tier(_Config) ->
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:retire_node(1)),
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:retire_node(27)),
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:unretire_node(27)).

%%-----------------------------------------------------------------------------
%% Both operations return {error, not_found} for a nonexistent runtime nref.
%%-----------------------------------------------------------------------------
retire_node_not_found(_Config) ->
	BadNref = ?NREF_START + 999999,
	?assertEqual({error, not_found}, graphdb_mgr:retire_node(BadNref)),
	?assertEqual({error, not_found}, graphdb_mgr:unretire_node(BadNref)).

%%-----------------------------------------------------------------------------
%% get_node/1 returns {error, retired} for a retired node; unretiring
%% restores the {ok, #node{}} response.
%%-----------------------------------------------------------------------------
get_node_hides_retired(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("HideMe", 3),
	{ok, _} = graphdb_mgr:get_node(ClassNref),
	ok = graphdb_mgr:retire_node(ClassNref),
	?assertEqual({error, retired}, graphdb_mgr:get_node(ClassNref)),
	ok = graphdb_mgr:unretire_node(ClassNref),
	{ok, #node{nref = ClassNref}} = graphdb_mgr:get_node(ClassNref).


%%=============================================================================
%% Batch mutate Tests
%%
%% mutate/1 applies an ordered list of mutations atomically in one
%% transaction. Workers are pre-started in init_per_testcase for this group.
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Empty batch is a no-op: {ok, []}, no transaction opened.
%%-----------------------------------------------------------------------------
mutate_empty_batch(_Config) ->
	?assertEqual({ok, []}, graphdb_mgr:mutate([])).

%%-----------------------------------------------------------------------------
%% A single add_relationship returns {ok, [ok]} and writes the arc.
%%-----------------------------------------------------------------------------
mutate_single_add_relationship(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MClassAR", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MKnows", "MKnownBy",
			instance),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate(
			[{add_relationship, InstA, CharNref, InstB, RecipNref}])),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([InstB], Targets).

%%-----------------------------------------------------------------------------
%% A single retire_node sets the marker; a single unretire_node clears it.
%%-----------------------------------------------------------------------------
mutate_single_retire_and_unretire(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRetire", 3),
	?assert(ClassNref >= ?NREF_START),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{retire_node, ClassNref}])),
	[#node{attribute_value_pairs = AVPs1}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs1)),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{unretire_node, ClassNref}])),
	[#node{attribute_value_pairs = AVPs2}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs2)).

%%-----------------------------------------------------------------------------
%% A mixed batch (two add_relationship + one retire) all succeeds: every
%% effect is present after commit.
%%-----------------------------------------------------------------------------
mutate_mixed_all_succeed(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MMixed", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MMA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MMB", ClassNref, 5),
	{ok, InstC, _} = graphdb_instance:create_instance("MMC", ClassNref, 5),
	{ok, {Ch1, Re1}} =
		graphdb_attr:create_relationship_attribute_pair("MM1", "MM1r", instance),
	{ok, {Ch2, Re2}} =
		graphdb_attr:create_relationship_attribute_pair("MM2", "MM2r", instance),
	Batch = [{add_relationship, InstA, Ch1, InstB, Re1},
			 {add_relationship, InstA, Ch2, InstC, Re2},
			 {retire_node, InstB}],
	?assertEqual({ok, [ok, ok, ok]}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Chars = lists:sort([R#relationship.characterization || R <- Rels,
		R#relationship.characterization =:= Ch1 orelse
		R#relationship.characterization =:= Ch2]),
	?assertEqual(lists:sort([Ch1, Ch2]), Chars),
	[#node{attribute_value_pairs = BAVPs}] = mnesia:dirty_read(nodes, InstB),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, BAVPs)).

%%-----------------------------------------------------------------------------
%% Atomic rollback: a valid add_relationship followed by a retire of a
%% nonexistent node aborts with {error, not_found}, and the relationship the
%% first mutation wrote is absent (the whole batch rolled back).
%%-----------------------------------------------------------------------------
mutate_atomic_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRollback", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MRA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MRB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MRKnows", "MRKnownBy",
			instance),
	BadNref = ?NREF_START + 999999,
	Batch = [{add_relationship, InstA, CharNref, InstB, RecipNref},
			 {retire_node, BadNref}],
	?assertEqual({error, not_found}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([], Targets).

%%-----------------------------------------------------------------------------
%% Read-your-writes rollback: retire X, then relate from X in the same batch.
%% The relationship's endpoint validation sees X's uncommitted retired marker
%% and aborts {endpoint_retired, X}; both mutations roll back, so X is NOT
%% retired afterward.
%%-----------------------------------------------------------------------------
mutate_read_your_writes_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRYW", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MRYWA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MRYWB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MRYWK", "MRYWKr",
			instance),
	Batch = [{retire_node, InstA},
			 {add_relationship, InstA, CharNref, InstB, RecipNref}],
	?assertEqual({error, {endpoint_retired, InstA}},
		graphdb_mgr:mutate(Batch)),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, InstA),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs)).

%%-----------------------------------------------------------------------------
%% A malformed mutation term is rejected in phase 1 with
%% {error, {bad_mutation, M}}; the well-formed mutation preceding it in the
%% batch writes nothing (phase 1 rejects the whole batch before phase 2/3).
%%-----------------------------------------------------------------------------
mutate_malformed_term(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MBad", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MBadA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MBadB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MBadK", "MBadKr",
			instance),
	Bad = {frobnicate, 1, 2},
	Batch = [{add_relationship, InstA, CharNref, InstB, RecipNref}, Bad],
	?assertEqual({error, {bad_mutation, Bad}}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([], Targets).

%%-----------------------------------------------------------------------------
%% The permanent-tier guard rejects retire/unretire of a node below
%% ?NREF_START with {error, permanent_node_immutable}, before any write.
%% Asserts the bootstrap node carries no retired marker afterward
%% (attribute-specific check -- node 27 may carry other AVPs).
%%-----------------------------------------------------------------------------
mutate_permanent_tier_guard(_Config) ->
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:mutate([{retire_node, 27}])),
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, 27),
	?assertEqual(false, lists:any(
		fun(#{attribute := A, value := true}) when A =:= RetAttr -> true;
		   (_) -> false end, AVPs)).

%%-----------------------------------------------------------------------------
%% mutate accepts the 6-element add_relationship form with an explicit
%% template nref; the Template AVP on the written arc is that template.
%%-----------------------------------------------------------------------------
mutate_add_relationship_explicit_template(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MTmplClass", 3),
	{ok, AltTmpl} = graphdb_class:add_template(ClassNref, "msocial"),
	{ok, A, _} = graphdb_instance:create_instance("MTA", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("MTB", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("MTKnows", "MTKnownBy",
			instance),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate(
			[{add_relationship, A, Char, B, Recip, AltTmpl}])),
	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => AltTmpl},
		Fwd#relationship.avps)).

%%-----------------------------------------------------------------------------
%% mutate accepts the 7-element add_relationship form with per-direction
%% AVPs; the forward AVP lands on the forward arc only and the reverse AVP
%% on the reverse arc only.
%%-----------------------------------------------------------------------------
mutate_add_relationship_with_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MAvpClass", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("MAvA", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("MAvB", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("MAvKnows", "MAvKnownBy",
			instance),
	{ok, Source}     = graphdb_attr:create_literal_attribute("msource", string),
	{ok, Confidence} = graphdb_attr:create_literal_attribute("mconf",   float),
	FwdOnly = #{attribute => Source,     value => "research-paper"},
	RevOnly = #{attribute => Confidence, value => 0.42},
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate(
			[{add_relationship, A, Char, B, Recip, DefaultTmpl,
				{[FwdOnly], [RevOnly]}}])),
	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assert(lists:member(FwdOnly,    Fwd#relationship.avps)),
	?assertNot(lists:member(RevOnly, Fwd#relationship.avps)),
	{atomic, BRels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, B, #relationship.source_nref)
	end),
	[Rev] = [R || R <- BRels,
		R#relationship.characterization =:= Recip,
		R#relationship.target_nref =:= A],
	?assert(lists:member(RevOnly,    Rev#relationship.avps)),
	?assertNot(lists:member(FwdOnly, Rev#relationship.avps)).


%%-----------------------------------------------------------------------------
%% A single update_node_avps mutation returns {ok, [ok]} and writes the AVP.
%%-----------------------------------------------------------------------------
mutate_single_update_node_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MUAClass", 3),
	{ok, Inst, _} = graphdb_instance:create_instance("MUAInst", ClassNref, 5),
	{ok, Attr} = graphdb_attr:create_literal_attribute("MUAAttr", string),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{update_node_avps, Inst,
			[#{attribute => Attr, value => "blue"}]}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, Inst),
	?assert(lists:member(#{attribute => Attr, value => "blue"}, AVPs)).

%%-----------------------------------------------------------------------------
%% A mixed batch (add_relationship + update_node_avps) all succeeds.
%%-----------------------------------------------------------------------------
mutate_mixed_add_rel_and_update_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MMUAClass", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MMUAA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MMUAB", ClassNref, 5),
	{ok, {Ch, Re}} =
		graphdb_attr:create_relationship_attribute_pair("MMUAk", "MMUAkb",
			instance),
	{ok, Attr} = graphdb_attr:create_literal_attribute("MMUAAttr", string),
	Batch = [{add_relationship, InstA, Ch, InstB, Re},
			 {update_node_avps, InstA, [#{attribute => Attr, value => "green"}]}],
	?assertEqual({ok, [ok, ok]}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	?assertEqual([InstB],
		[R#relationship.target_nref || R <- Rels,
			R#relationship.characterization =:= Ch]),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, InstA),
	?assert(lists:member(#{attribute => Attr, value => "green"}, AVPs)).

%%-----------------------------------------------------------------------------
%% Atomic rollback: a valid add_relationship followed by an update_node_avps
%% with an unknown attribute aborts the whole batch -- the relationship the
%% first mutation wrote is absent.
%%-----------------------------------------------------------------------------
mutate_update_avps_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MUARbClass", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MUARbA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MUARbB", ClassNref, 5),
	{ok, {Ch, Re}} =
		graphdb_attr:create_relationship_attribute_pair("MUARbk", "MUARbkb",
			instance),
	BadAttr = ?NREF_START + 888888,
	Batch = [{add_relationship, InstA, Ch, InstB, Re},
			 {update_node_avps, InstA, [#{attribute => BadAttr, value => 1}]}],
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	?assertEqual([],
		[R#relationship.target_nref || R <- Rels,
			R#relationship.characterization =:= Ch]).

%%-----------------------------------------------------------------------------
%% A malformed update_node_avps mutation is rejected in static validation
%% ({error, {invalid_avp, _}}), before any transaction is opened.
%%-----------------------------------------------------------------------------
mutate_update_avps_malformed(_Config) ->
	?assertEqual({error, {invalid_avp, "bad"}},
		graphdb_mgr:mutate([{update_node_avps, 123, ["bad"]}])).

%%-----------------------------------------------------------------------------
%% A batch update_node_avps targeting a nonexistent node aborts {error,
%% not_found} via the tier-1 primitive (mutate has no pre-txn category guard,
%% so this is the path that exercises the tier-1 mnesia:abort(not_found)).
%%-----------------------------------------------------------------------------
mutate_update_avps_not_found(_Config) ->
	{ok, Attr} = graphdb_attr:create_literal_attribute("MUANFAttr", string),
	BadNref = ?NREF_START + 999999,
	?assertEqual({error, not_found},
		graphdb_mgr:mutate([{update_node_avps, BadNref,
			[#{attribute => Attr, value => "x"}]}])).


%%=============================================================================
%% update_node_avps Tests (solo / tier-2 path)
%%
%% Full worker stack started in init_per_testcase. A runtime instance is the
%% subject; a runtime literal attribute supplies a valid attribute nref.
%%=============================================================================

%% Helper: create a runtime class + instance + one literal attribute.
%% Returns {InstNref, AttrNref}.
ua_setup(Name) ->
	{ok, ClassNref} = graphdb_class:create_class("UAClass" ++ Name, 3),
	{ok, InstNref, _} =
		graphdb_instance:create_instance("UAInst" ++ Name, ClassNref, 5),
	{ok, AttrNref} =
		graphdb_attr:create_literal_attribute("UAAttr" ++ Name, string),
	{InstNref, AttrNref}.

ua_avps(Nref) ->
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, Nref),
	AVPs.

ua_value(Nref, AttrNref) ->
	AVPs = ua_avps(Nref),
	case [V || #{attribute := A, value := V} <- AVPs, A =:= AttrNref] of
		[V] -> V;
		[]  -> not_found
	end.

%%-----------------------------------------------------------------------------
%% Upsert a new attribute -> dirty_read reflects it.
%%-----------------------------------------------------------------------------
update_node_avps_upsert_roundtrip(_Config) ->
	{Inst, Attr} = ua_setup("RT"),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr, value => "red"}])),
	?assertEqual("red", ua_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Overwriting the name attribute keeps it at the head of the AVP list.
%%-----------------------------------------------------------------------------
update_node_avps_overwrite_preserves_head(_Config) ->
	{Inst, _Attr} = ua_setup("Head"),
	[#{attribute := NameAttr} | _] = ua_avps(Inst),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => NameAttr, value => "Renamed"}])),
	[#{attribute := NameAttr, value := "Renamed"} | _] = ua_avps(Inst).

%%-----------------------------------------------------------------------------
%% A value-less map deletes the attribute.
%%-----------------------------------------------------------------------------
update_node_avps_delete(_Config) ->
	{Inst, Attr} = ua_setup("Del"),
	ok = graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr, value => "x"}]),
	?assertEqual("x", ua_value(Inst, Attr)),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr}])),
	?assertEqual(not_found, ua_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Deleting an attribute the node does not carry is a no-op (still ok).
%%-----------------------------------------------------------------------------
update_node_avps_delete_absent_noop(_Config) ->
	{Inst, Attr} = ua_setup("DelAbsent"),
	Before = ua_avps(Inst),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr}])),
	?assertEqual(Before, ua_avps(Inst)).

%%-----------------------------------------------------------------------------
%% value => undefined upserts a real (declared-but-unbound) entry, not a delete.
%%-----------------------------------------------------------------------------
update_node_avps_undefined_retained(_Config) ->
	{Inst, Attr} = ua_setup("Undef"),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => Attr, value => undefined}])),
	AVPs = ua_avps(Inst),
	?assert(lists:member(#{attribute => Attr, value => undefined}, AVPs)).

%%-----------------------------------------------------------------------------
%% An upsert referencing a nonexistent attribute aborts {unknown_attribute, _}.
%%-----------------------------------------------------------------------------
update_node_avps_unknown_attribute(_Config) ->
	{Inst, _Attr} = ua_setup("Unknown"),
	BadAttr = ?NREF_START + 888888,
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:update_node_avps(Inst, [#{attribute => BadAttr, value => 1}])).

%%-----------------------------------------------------------------------------
%% Targeting the seeded `retired` attribute is rejected -> use_retire_api.
%%-----------------------------------------------------------------------------
update_node_avps_retired_marker_rejected(_Config) ->
	{Inst, _Attr} = ua_setup("Ret"),
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	?assertEqual({error, use_retire_api},
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => RetAttr, value => true}])).

%%-----------------------------------------------------------------------------
%% A nonexistent runtime node -> {error, not_found}.
%%-----------------------------------------------------------------------------
update_node_avps_not_found(_Config) ->
	{_Inst, Attr} = ua_setup("NF"),
	BadNref = ?NREF_START + 999999,
	?assertEqual({error, not_found},
		graphdb_mgr:update_node_avps(BadNref, [#{attribute => Attr, value => 1}])).

%%-----------------------------------------------------------------------------
%% A permanent-tier node -> {error, permanent_node_immutable}.
%%-----------------------------------------------------------------------------
update_node_avps_permanent_tier(_Config) ->
	%% Nref 6 (Names) is a permanent-tier attribute node.
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:update_node_avps(6, [#{attribute => 6, value => 1}])).

%%-----------------------------------------------------------------------------
%% Atomicity: a multi-AVP call where a later AVP aborts leaves the node
%% unchanged (the earlier AVP in the same call is rolled back).
%%-----------------------------------------------------------------------------
update_node_avps_atomic_rollback(_Config) ->
	{Inst, Attr} = ua_setup("Atomic"),
	BadAttr = ?NREF_START + 888888,
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => Attr, value => "red"},
			 #{attribute => BadAttr, value => "boom"}])),
	?assertEqual(not_found, ua_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% update_node_avps/2 rejects a value-bearing update to a class node's
%% instance-only QC, and rolls the write back.
%%-----------------------------------------------------------------------------
update_node_avps_rejects_instance_only(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IOClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual({error, {instance_only_attribute, Attr}},
		graphdb_mgr:update_node_avps(ClassNref,
			[#{attribute => Attr, value => "SN-1"}])),
	%% Rollback: the QC stays declared-unbound, marker intact.
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:member(
		#{attribute => Attr, value => undefined, instance_only => true}, AVPs)).

%%-----------------------------------------------------------------------------
%% update_node_avps/2 permits DELETING an instance-only QC (no `value` key).
%%-----------------------------------------------------------------------------
update_node_avps_delete_instance_only_ok(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IODelClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(ClassNref, [#{attribute => Attr}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assertNot(lists:any(fun(#{attribute := A}) -> A =:= Attr;
				(_) -> false end, AVPs)).

%%-----------------------------------------------------------------------------
%% mutate/1 inherits the instance-only guard via update_node_avps_in_txn.
%%-----------------------------------------------------------------------------
mutate_rejects_instance_only(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IOMutClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual({error, {instance_only_attribute, Attr}},
		graphdb_mgr:mutate([{update_node_avps, ClassNref,
			[#{attribute => Attr, value => "SN-1"}]}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:member(
		#{attribute => Attr, value => undefined, instance_only => true}, AVPs)).
