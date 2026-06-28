%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: Common Test integration suite for graphdb_instance.
%%				Each test case gets its own isolated temp directory
%%				with a fresh Mnesia database and nref allocator.
%%				graphdb_mgr is started first to load the bootstrap
%%				scaffold; graphdb_attr, graphdb_class, and
%%				graphdb_instance are then started and exercised.
%%---------------------------------------------------------------------
-module(graphdb_instance_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb internal records)
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
	init_per_group/2,
	end_per_group/2,
	init_per_testcase/2,
	end_per_testcase/2
]).

%%---------------------------------------------------------------------
%% Test cases
%%---------------------------------------------------------------------
-export([
	%% Creation
	create_instance_basic/1,
	create_instance_rejects_bad_class/1,
	create_instance_rejects_missing_class/1,
	create_instance_rejects_missing_parent/1,
	create_instance_writes_membership_arcs/1,
	create_instance_writes_compositional_arcs/1,
	create_instance_refused_for_abstract_class/1,
	create_instance_allowed_for_unmarked_class/1,
	create_instance_refuses_retired_class/1,
	create_instance_refuses_retired_parent/1,
	%% Relationships
	add_relationship_basic/1,
	add_relationship_both_directions/1,
	add_relationship_stamps_template_avp/1,
	add_relationship_explicit_template/1,
	add_relationship_rejects_non_template_nref/1,
	add_relationship_rejects_template_out_of_ancestry/1,
	add_relationship_no_default_after_delete/1,
	add_relationship_rejects_missing_source/1,
	add_relationship_rejects_missing_target/1,
	add_relationship_rejects_missing_characterization/1,
	add_relationship_rejects_missing_reciprocal/1,
	add_relationship_rejects_non_attribute_char/1,
	add_relationship_rejects_non_attribute_reciprocal/1,
	add_relationship_rejects_target_kind_mismatch/1,
	add_relationship_rejects_source_has_no_class/1,
	add_relationship_rejects_target_has_no_class/1,
	add_relationship_stamps_user_avps/1,
	add_relationship_avps_are_per_direction/1,
	add_relationship_default_avps_empty/1,
	add_relationship_refuses_retired_endpoint/1,
	class_of_returns_class/1,
	%% Remove relationships
	remove_relationship_basic/1,
	remove_relationship_not_found/1,
	remove_relationship_ambiguous/1,
	remove_relationship_disambiguate_by_template/1,
	remove_relationship_dangling_half_edge/1,
	%% Update relationships
	update_relationship_single_direction/1,
	update_relationship_reverse_direction/1,
	update_relationship_protects_template/1,
	update_relationship_not_found/1,
	update_relationship_both_directions/1,
	%% Lookups
	get_instance_returns_node/1,
	get_instance_not_found/1,
	get_instance_rejects_non_instance/1,
	%% Hierarchy
	children_returns_instance_children/1,
	children_empty_for_leaf/1,
	ancestors_returns_chain/1,
	ancestors_empty_for_top_level/1,
	%% Inheritance
	resolve_value_local/1,
	resolve_value_from_class/1,
	resolve_value_from_ancestor/1,
	resolve_value_from_connected/1,
	resolve_value_not_found/1,
	resolve_value_priority_local_over_class/1,
	resolve_value_priority_class_over_ancestor/1,
	resolve_value_priority_ancestor_over_connected/1,
	resolve_value_walks_class_taxonomy/1,
	resolve_value_local_class_overrides_taxonomy_ancestor/1,
	resolve_value_p4_ignores_compositional_arc/1,
	resolve_value_source_local/1,
	resolve_value_source_class/1,
	resolve_value_source_ancestor/1,
	resolve_value_source_connected/1,
	%% Multi-membership
	add_class_membership_basic/1,
	add_class_membership_writes_arcs/1,
	add_class_membership_idempotent/1,
	add_class_membership_rejects_missing_instance/1,
	add_class_membership_rejects_non_instance/1,
	add_class_membership_rejects_missing_class/1,
	add_class_membership_rejects_non_class_target/1,
	add_class_membership_refuses_abstract_class/1,
	add_class_membership_refuses_retired_class/1,
	class_memberships_initial/1,
	%% Multi-membership resolver
	resolve_value_unique_across_two_classes/1,
	resolve_value_same_value_two_classes/1,
	resolve_value_ambiguous_two_classes/1,
	resolve_value_local_overrides_ambiguity/1,
	resolve_value_ambiguity_via_taxonomy/1,
	%% Firing
	firing_no_rules_baseline/1,
	firing_single_mandatory/1,
	firing_mandatory_mult/1,
	firing_mandatory_cascade_atomic/1,
	firing_mandatory_failure_rolls_back/1,
	firing_auto_best_effort/1,
	firing_auto_failure_survives/1,
	firing_auto_cascade_merges/1,
	firing_propose_outcome_in_report/1,
	firing_propose_not_materialised/1,
	firing_propose_multiplicity_bounded/1,
	firing_propose_multiplicity_unbounded/1,
	firing_propose_on_path_cut/1,
	firing_propose_summarize/1,
	firing_propose_with_mandatory_and_auto/1,
	firing_propose_owner_is_materialised_child/1,
	firing_propose_carries_max/1,
	firing_propose_min_zero_surfaces_none/1,
	%% mint-Min
	firing_mandatory_mints_min/1,
	firing_mandatory_min_zero_mints_none/1,
	firing_mandatory_min_unbounded_mints_min/1,
	firing_auto_mints_min/1,
	firing_auto_min_zero_unbounded/1,
	%% connection firing
	firing_conn_report_only_mandatory/1,
	firing_conn_report_only_auto/1,
	firing_conn_report_only_propose/1,
	firing_conn_explicit_defer/1,
	firing_conn_summarize/1,
	%% mandatory commit path
	firing_conn_mandatory_connected/1,
	firing_conn_mandatory_shortfall_fails/1,
	firing_conn_mandatory_invalid_target_fails/1,
	firing_conn_mandatory_caps_at_max/1,
	firing_conn_rollback_discriminable_composition/1,
	firing_conn_rollback_discriminable_connection/1,
	firing_conn_descendant_in_root_txn/1,
	%% auto connection post-commit
	firing_conn_auto_connected/1,
	firing_conn_auto_invalid_survives/1,
	%% target validation
	firing_conn_subclass_target_accepted/1,
	firing_conn_missing_target_fails/1,
	firing_conn_non_instance_target_fails/1,
	firing_conn_resolver_avps_stamped/1,
	%% B5 plumbing
	b5_create_instance_5_accepts_resolvers/1,
	b5_default_resolver_single_rule_unchanged/1,
	%% B5 end-to-end firing
	b5_firing_same_level_mode_priority/1,
	b5_firing_cross_level_shadow/1,
	b5_custom_resolver_pure_additive/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, creation}, {group, relationships}, {group, lookups},
	 {group, hierarchy}, {group, inheritance}, {group, multi_membership},
	 {group, firing}].

groups() ->
	[
		{creation, [], [
			create_instance_basic,
			create_instance_rejects_bad_class,
			create_instance_rejects_missing_class,
			create_instance_rejects_missing_parent,
			create_instance_writes_membership_arcs,
			create_instance_writes_compositional_arcs,
			create_instance_refused_for_abstract_class,
			create_instance_allowed_for_unmarked_class,
			create_instance_refuses_retired_class,
			create_instance_refuses_retired_parent
		]},
		{relationships, [], [
			add_relationship_basic,
			add_relationship_both_directions,
			add_relationship_stamps_template_avp,
			add_relationship_explicit_template,
			add_relationship_rejects_non_template_nref,
			add_relationship_rejects_template_out_of_ancestry,
			add_relationship_no_default_after_delete,
			add_relationship_rejects_missing_source,
			add_relationship_rejects_missing_target,
			add_relationship_rejects_missing_characterization,
			add_relationship_rejects_missing_reciprocal,
			add_relationship_rejects_non_attribute_char,
			add_relationship_rejects_non_attribute_reciprocal,
			add_relationship_rejects_target_kind_mismatch,
			add_relationship_rejects_source_has_no_class,
			add_relationship_rejects_target_has_no_class,
			add_relationship_stamps_user_avps,
			add_relationship_avps_are_per_direction,
			add_relationship_default_avps_empty,
			add_relationship_refuses_retired_endpoint,
			class_of_returns_class,
			remove_relationship_basic,
			remove_relationship_not_found,
			remove_relationship_ambiguous,
			remove_relationship_disambiguate_by_template,
			remove_relationship_dangling_half_edge,
			update_relationship_single_direction,
			update_relationship_reverse_direction,
			update_relationship_protects_template,
			update_relationship_not_found,
			update_relationship_both_directions
		]},
		{lookups, [], [
			get_instance_returns_node,
			get_instance_not_found,
			get_instance_rejects_non_instance
		]},
		{hierarchy, [], [
			children_returns_instance_children,
			children_empty_for_leaf,
			ancestors_returns_chain,
			ancestors_empty_for_top_level
		]},
		{inheritance, [], [
			resolve_value_local,
			resolve_value_from_class,
			resolve_value_from_ancestor,
			resolve_value_from_connected,
			resolve_value_not_found,
			resolve_value_priority_local_over_class,
			resolve_value_priority_class_over_ancestor,
			resolve_value_priority_ancestor_over_connected,
			resolve_value_walks_class_taxonomy,
			resolve_value_local_class_overrides_taxonomy_ancestor,
			resolve_value_p4_ignores_compositional_arc,
			resolve_value_source_local,
			resolve_value_source_class,
			resolve_value_source_ancestor,
			resolve_value_source_connected
		]},
		{multi_membership, [], [
			add_class_membership_basic,
			add_class_membership_writes_arcs,
			add_class_membership_idempotent,
			add_class_membership_rejects_missing_instance,
			add_class_membership_rejects_non_instance,
			add_class_membership_rejects_missing_class,
			add_class_membership_rejects_non_class_target,
			add_class_membership_refuses_abstract_class,
			add_class_membership_refuses_retired_class,
			class_memberships_initial,
			resolve_value_unique_across_two_classes,
			resolve_value_same_value_two_classes,
			resolve_value_ambiguous_two_classes,
			resolve_value_local_overrides_ambiguity,
			resolve_value_ambiguity_via_taxonomy
		]},
		{firing, [], [
			firing_no_rules_baseline,
			firing_single_mandatory,
			firing_mandatory_mult,
			firing_mandatory_cascade_atomic,
			firing_mandatory_failure_rolls_back,
			firing_mandatory_mints_min,
			firing_mandatory_min_zero_mints_none,
			firing_mandatory_min_unbounded_mints_min,
			firing_auto_best_effort,
			firing_auto_failure_survives,
			firing_auto_cascade_merges,
			firing_auto_mints_min,
			firing_auto_min_zero_unbounded,
			firing_propose_outcome_in_report,
			firing_propose_not_materialised,
			firing_propose_multiplicity_bounded,
			firing_propose_multiplicity_unbounded,
			firing_propose_on_path_cut,
			firing_propose_summarize,
			firing_propose_with_mandatory_and_auto,
			firing_propose_owner_is_materialised_child,
			firing_propose_carries_max,
			firing_propose_min_zero_surfaces_none,
			firing_conn_report_only_mandatory,
			firing_conn_report_only_auto,
			firing_conn_report_only_propose,
			firing_conn_explicit_defer,
			firing_conn_summarize,
			firing_conn_mandatory_connected,
			firing_conn_mandatory_shortfall_fails,
			firing_conn_mandatory_invalid_target_fails,
			firing_conn_mandatory_caps_at_max,
			firing_conn_rollback_discriminable_composition,
			firing_conn_rollback_discriminable_connection,
			firing_conn_descendant_in_root_txn,
			firing_conn_auto_connected,
			firing_conn_auto_invalid_survives,
			firing_conn_subclass_target_accepted,
			firing_conn_missing_target_fails,
			firing_conn_non_instance_target_fails,
			firing_conn_resolver_avps_stamped,
			b5_create_instance_5_accepts_resolvers,
			b5_default_resolver_single_rule_unchanged,
			b5_firing_same_level_mode_priority,
			b5_firing_cross_level_shadow,
			b5_custom_resolver_pure_additive
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
init_per_testcase(TC, Config) ->
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
	{ok, _} = graphdb_rules:start_link(),
	%% Retire-guard tests need runtime nrefs so retire_node/1 accepts them.
	%% Mirror production graphdb:start/2: flip to runtime tier after all workers
	%% have seeded so that user-level create_* calls allocate runtime nrefs.
	maybe_set_runtime_phase(TC),
	setup_firing_fixtures(TC, Config1).

%% Test cases that call graphdb_mgr:retire_node/1 require runtime nrefs.
%% Flip to the runtime tier (nref >= ?NREF_START) after seeding is complete.
%% NOTE: add any future retire-guard test case to this guard list — without
%% it the test runs in permanent phase and retire_node/1 rejects its
%% runtime-tier target with {error, permanent_node_immutable}.
maybe_set_runtime_phase(TC) when
		TC =:= create_instance_refuses_retired_class;
		TC =:= create_instance_refuses_retired_parent;
		TC =:= add_class_membership_refuses_retired_class;
		TC =:= add_relationship_refuses_retired_endpoint ->
	ok = graphdb_nref:set_runtime_phase();
maybe_set_runtime_phase(_TC) ->
	ok.

%% For firing-group test cases, create the shared class fixtures and add
%% them to Config.  Other test cases pass through unchanged.
setup_firing_fixtures(TC, Config) ->
	FiringTests = [firing_no_rules_baseline, firing_single_mandatory,
				   firing_mandatory_mult, firing_mandatory_cascade_atomic,
				   firing_mandatory_failure_rolls_back,
				   firing_auto_best_effort, firing_auto_failure_survives,
				   firing_auto_cascade_merges,
				   firing_propose_outcome_in_report,
				   firing_propose_not_materialised,
				   firing_propose_multiplicity_bounded,
				   firing_propose_multiplicity_unbounded,
				   firing_propose_on_path_cut,
				   firing_propose_summarize,
				   firing_propose_with_mandatory_and_auto,
				   firing_propose_owner_is_materialised_child,
				   firing_propose_carries_max,
				   firing_propose_min_zero_surfaces_none,
				   firing_mandatory_mints_min,
				   firing_mandatory_min_zero_mints_none,
				   firing_mandatory_min_unbounded_mints_min,
				   firing_auto_mints_min,
				   firing_auto_min_zero_unbounded],
	case lists:member(TC, FiringTests) of
		true ->
			{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
			{ok, Owner}    = graphdb_class:create_class("Owner",    3),
			{ok, Bolt}     = graphdb_class:create_class("Bolt",     3),
			{ok, Widget}   = graphdb_class:create_class("Widget",   3),
			{ok, Abstract} = graphdb_class:create_class("Abstract", 3,
				[#{attribute => InstAttr, value => false}]),
			[{ob,  {Owner, Bolt}},
			 {obw, {Owner, Bolt, Widget}},
			 {oa,  {Owner, Abstract}}
			 | Config];
		false ->
			Config
	end.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"instance_" ++ Unique]),
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
%% Creation Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Create an instance with a class and parent.  Uses the Projects
%% category (nref 5) as the compositional parent anchor.
%%-----------------------------------------------------------------------------
create_instance_basic(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Vehicle", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("Car1", ClassNref, 5),
	{ok, Node} = graphdb_instance:get_instance(InstNref),
	?assertEqual(instance, Node#node.kind),
	?assertEqual([5], Node#node.parents),
	?assertEqual([#{attribute => ?NAME_ATTR_INSTANCE, value => "Car1"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-class nref.
%%-----------------------------------------------------------------------------
create_instance_rejects_bad_class(_Config) ->
	%% Nref 6 (Names) is an attribute node
	?assertMatch({error, {not_a_class, attribute}},
		graphdb_instance:create_instance("Bad", 6, 5)).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-existent class.
%%-----------------------------------------------------------------------------
create_instance_rejects_missing_class(_Config) ->
	?assertEqual({error, class_not_found},
		graphdb_instance:create_instance("Bad", 99999, 5)).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-existent parent.
%%-----------------------------------------------------------------------------
create_instance_rejects_missing_parent(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	?assertEqual({error, parent_not_found},
		graphdb_instance:create_instance("Bad", ClassNref, 99999)).

%%-----------------------------------------------------------------------------
%% Creating an instance must write membership arcs (char=29/30).
%%-----------------------------------------------------------------------------
create_instance_writes_membership_arcs(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("Dog1", ClassNref, 5),

	%% Instance -> Class (char=29, reciprocal=30)
	{atomic, InstOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, InstNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= ClassNref andalso
		R#relationship.characterization =:= ?ARC_INST_TO_CLASS andalso
		R#relationship.reciprocal =:= ?ARC_CLASS_TO_INST
	end, InstOut)),

	%% Class -> Instance (char=30, reciprocal=29)
	{atomic, ClassOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, ClassNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= InstNref andalso
		R#relationship.characterization =:= ?ARC_CLASS_TO_INST andalso
		R#relationship.reciprocal =:= ?ARC_INST_TO_CLASS
	end, ClassOut)).

%%-----------------------------------------------------------------------------
%% Creating an instance must write compositional arcs (char=28/27).
%%-----------------------------------------------------------------------------
create_instance_writes_compositional_arcs(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("Bolt1", ClassNref, 5),

	%% Parent (5) -> Child (InstNref) with char=28
	{atomic, ParentOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 5, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= InstNref andalso
		R#relationship.characterization =:= ?ARC_INST_CHILD andalso
		R#relationship.reciprocal =:= ?ARC_INST_PARENT
	end, ParentOut)),

	%% Child (InstNref) -> Parent (5) with char=27
	{atomic, ChildOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, InstNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= 5 andalso
		R#relationship.characterization =:= ?ARC_INST_PARENT andalso
		R#relationship.reciprocal =:= ?ARC_INST_CHILD
	end, ChildOut)).


%%-----------------------------------------------------------------------------
%% Instantiating a class marked instantiable=>false is refused, and no
%% rows are written.
%%-----------------------------------------------------------------------------
create_instance_refused_for_abstract_class(_Config) ->
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	{ok, ClassNref} = graphdb_class:create_class("Meta", 3,
		[#{attribute => Inst, value => false}]),
	Before = mnesia:table_info(nodes, size),
	?assertEqual({error, {class_not_instantiable, ClassNref}},
		graphdb_instance:create_instance("Nope", ClassNref, 5)),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%%-----------------------------------------------------------------------------
%% Ordinary classes still instantiate normally.
%%-----------------------------------------------------------------------------
create_instance_allowed_for_unmarked_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Plain", 3),
	?assertMatch({ok, _, _},
		graphdb_instance:create_instance("Inst1", ClassNref, 5)).

%%-----------------------------------------------------------------------------
%% create_instance rejects a retired class node.
%%-----------------------------------------------------------------------------
create_instance_refuses_retired_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("RetClass", 3),
	ok = graphdb_mgr:retire_node(ClassNref),
	?assertEqual({error, {class_retired, ClassNref}},
		graphdb_instance:create_instance("i", ClassNref, 3)).

%%-----------------------------------------------------------------------------
%% create_instance rejects a retired compositional parent.
%%-----------------------------------------------------------------------------
create_instance_refuses_retired_parent(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("PClass", 3),
	{ok, Parent, _} = graphdb_instance:create_instance("p", ClassNref, 3),
	ok = graphdb_mgr:retire_node(Parent),
	?assertEqual({error, {parent_retired, Parent}},
		graphdb_instance:create_instance("child", ClassNref, Parent)).


%%=============================================================================
%% Relationship Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_relationship writes two directed rows.
%%-----------------------------------------------------------------------------
add_relationship_basic(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	%% Create a relationship attribute pair for testing
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute_pair("Makes", "MadeBy", instance),
	RelsBefore = mnesia:table_info(relationships, size),
	ok = graphdb_instance:add_relationship(A, MakesNref, B, MadeByNref),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 2, RelsAfter).

%%-----------------------------------------------------------------------------
%% add_relationship creates both forward and reverse arcs.
%%-----------------------------------------------------------------------------
add_relationship_both_directions(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, Ford, _} = graphdb_instance:create_instance("Ford", ClassNref, 5),
	{ok, Taurus, _} = graphdb_instance:create_instance("Taurus", ClassNref, 5),
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute_pair("Makes", "MadeBy", instance),
	ok = graphdb_instance:add_relationship(Ford, MakesNref, Taurus, MadeByNref),

	%% Ford -> Taurus (char=Makes, reciprocal=MadeBy)
	{atomic, FordOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Ford, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Taurus andalso
		R#relationship.characterization =:= MakesNref andalso
		R#relationship.reciprocal =:= MadeByNref
	end, FordOut)),

	%% Taurus -> Ford (char=MadeBy, reciprocal=Makes)
	{atomic, TaurusOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Taurus, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Ford andalso
		R#relationship.characterization =:= MadeByNref andalso
		R#relationship.reciprocal =:= MakesNref
	end, TaurusOut)).

%%-----------------------------------------------------------------------------
%% add_relationship/4 stamps the Template AVP (nref 31) on both rows,
%% pointing at the source class's default template.
%%-----------------------------------------------------------------------------
add_relationship_stamps_template_avp(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),

	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assertEqual(connection, Fwd#relationship.kind),
	?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => DefaultTmpl},
		Fwd#relationship.avps)).

%%-----------------------------------------------------------------------------
%% add_relationship/5 accepts an explicit template nref.
%%-----------------------------------------------------------------------------
add_relationship_explicit_template(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Person", 3),
	{ok, AltTmpl} = graphdb_class:add_template(ClassNref, "social"),
	{ok, A, _} = graphdb_instance:create_instance("Alice", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("Bob", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, AltTmpl),

	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => AltTmpl},
		Fwd#relationship.avps)).

%%-----------------------------------------------------------------------------
%% add_relationship/5 rejects an nref that is not a template node.
%%-----------------------------------------------------------------------------
add_relationship_rejects_non_template_nref(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	%% ClassNref is a class, not a template
	?assertMatch({error, {invalid_template, _, not_a_template}},
		graphdb_instance:add_relationship(A, Char, B, Recip, ClassNref)).

%%-----------------------------------------------------------------------------
%% add_relationship/5 rejects a template whose parent class is unrelated
%% to both source and target classes.
%%-----------------------------------------------------------------------------
add_relationship_rejects_template_out_of_ancestry(_Config) ->
	{ok, AnimalCls}  = graphdb_class:create_class("Animal", 3),
	{ok, VehicleCls} = graphdb_class:create_class("Vehicle", 3),
	{ok, VehTmpl}    = graphdb_class:default_template(VehicleCls),
	{ok, A, _} = graphdb_instance:create_instance("Cat", AnimalCls, 5),
	{ok, B, _} = graphdb_instance:create_instance("Dog", AnimalCls, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertMatch({error, {template_class_not_in_ancestry, _, _, _, _}},
		graphdb_instance:add_relationship(A, Char, B, Recip, VehTmpl)).

%%-----------------------------------------------------------------------------
%% After deleting the default template, /4 returns no_default_template;
%% callers must use /5 with an explicit template.
%%-----------------------------------------------------------------------------
add_relationship_no_default_after_delete(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	{atomic, ok} = mnesia:transaction(fun() ->
		mnesia:delete({nodes, DefaultTmpl})
	end),
	?assertEqual({error, no_default_template},
		graphdb_instance:add_relationship(A, Char, B, Recip)).

%%-----------------------------------------------------------------------------
%% missing source nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_source(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {source_not_found, 99999}},
		graphdb_instance:add_relationship(99999, Char, B, Recip)).

%%-----------------------------------------------------------------------------
%% missing target nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_target(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {target_not_found, 99999}},
		graphdb_instance:add_relationship(A, Char, 99999, Recip)).

%%-----------------------------------------------------------------------------
%% missing characterization nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_characterization(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {_Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {characterization_not_found, 99999}},
		graphdb_instance:add_relationship(A, 99999, B, Recip)).

%%-----------------------------------------------------------------------------
%% missing reciprocal nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_reciprocal(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, _Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {reciprocal_not_found, 99999}},
		graphdb_instance:add_relationship(A, Char, B, 99999)).

%%-----------------------------------------------------------------------------
%% characterization that is not kind=attribute is rejected.  Uses
%% the bootstrap Projects category (nref 5) as a non-attribute node.
%%-----------------------------------------------------------------------------
add_relationship_rejects_non_attribute_char(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {_Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertMatch({error, {characterization_not_an_attribute, 5, category}},
		graphdb_instance:add_relationship(A, 5, B, Recip)).

%%-----------------------------------------------------------------------------
%% reciprocal that is not kind=attribute is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_non_attribute_reciprocal(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, _Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertMatch({error, {reciprocal_not_an_attribute, 5, category}},
		graphdb_instance:add_relationship(A, Char, B, 5)).

%%-----------------------------------------------------------------------------
%% target whose kind disagrees with the characterization's
%% target_kind AVP is rejected.  Char declares target_kind=class but the
%% target is an instance.
%%-----------------------------------------------------------------------------
add_relationship_rejects_target_kind_mismatch(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	%% target_kind=class, but B is an instance
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Has", "HeldBy", class),
	?assertEqual({error, {target_kind_mismatch, class, instance}},
		graphdb_instance:add_relationship(A, Char, B, Recip)).

%%-----------------------------------------------------------------------------
%% source that exists and passes endpoint validation but has no instance->class
%% membership arc is rejected.  A class node is such a node: validate_arc_endpoints
%% does not constrain the source's kind, and a class has no ?ARC_INST_TO_CLASS arc.
%%-----------------------------------------------------------------------------
add_relationship_rejects_source_has_no_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {source_has_no_class, ClassNref}},
		graphdb_instance:add_relationship(ClassNref, Char, B, Recip)).

%%-----------------------------------------------------------------------------
%% target that exists and passes endpoint validation but has no instance->class
%% membership arc is rejected.  Char's target_kind=class lets a class node pass
%% endpoint validation as the target; the class has no ?ARC_INST_TO_CLASS arc.
%%-----------------------------------------------------------------------------
add_relationship_rejects_target_has_no_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Has", "HeldBy", class),
	?assertEqual({error, {target_has_no_class, ClassNref}},
		graphdb_instance:add_relationship(A, Char, ClassNref, Recip)).


%%-----------------------------------------------------------------------------
%% /6 stamps user AVPs on both connection rows alongside the
%% Template AVP.  Same AVPs are seen in fwd and rev directions when
%% they're identical lists.
%%-----------------------------------------------------------------------------
add_relationship_stamps_user_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	{ok, Confidence} = graphdb_attr:create_literal_attribute("confidence", float),
	UserAVP = #{attribute => Confidence, value => 0.95},
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl,
		{[UserAVP], [UserAVP]}),

	%% Both directions should carry Template AVP and the user AVP.
	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => DefaultTmpl},
		Fwd#relationship.avps)),
	?assert(lists:member(UserAVP, Fwd#relationship.avps)).

%%-----------------------------------------------------------------------------
%% forward and reverse AVPs are per-direction independent.  An AVP
%% supplied only on the forward side must not leak into the reverse arc.
%%-----------------------------------------------------------------------------
add_relationship_avps_are_per_direction(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	{ok, Source}     = graphdb_attr:create_literal_attribute("source",  string),
	{ok, Confidence} = graphdb_attr:create_literal_attribute("conf",    float),
	FwdOnly = #{attribute => Source,     value => "research-paper"},
	RevOnly = #{attribute => Confidence, value => 0.42},
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl,
		{[FwdOnly], [RevOnly]}),

	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assert(lists:member(FwdOnly,     Fwd#relationship.avps)),
	?assertNot(lists:member(RevOnly,  Fwd#relationship.avps)),

	{atomic, BRels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, B, #relationship.source_nref)
	end),
	[Rev] = [R || R <- BRels,
		R#relationship.characterization =:= Recip,
		R#relationship.target_nref =:= A],
	?assert(lists:member(RevOnly,     Rev#relationship.avps)),
	?assertNot(lists:member(FwdOnly,  Rev#relationship.avps)).

%%-----------------------------------------------------------------------------
%% /4 and /5 default to {[],[]}, so connection rows carry only the
%% Template AVP.
%%-----------------------------------------------------------------------------
add_relationship_default_avps_empty(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),

	{atomic, ARels} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[Fwd] = [R || R <- ARels,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B],
	?assertEqual([#{attribute => ?ARC_TEMPLATE, value => DefaultTmpl}],
		Fwd#relationship.avps).

%%-----------------------------------------------------------------------------
%% add_relationship rejects a retired endpoint.
%%-----------------------------------------------------------------------------
add_relationship_refuses_retired_endpoint(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("ArcClass", 3),
	{ok, Src, _}  = graphdb_instance:create_instance("s", ClassNref, 3),
	{ok, Tgt, _}  = graphdb_instance:create_instance("t", ClassNref, 3),
	{ok, {Fwd, Rec}} =
		graphdb_attr:create_relationship_attribute_pair("Likes", "LikedBy", instance),
	ok = graphdb_instance:add_relationship(Src, Fwd, Tgt, Rec),
	ok = graphdb_mgr:retire_node(Tgt),
	{ok, Tgt2, _} = graphdb_instance:create_instance("t2", ClassNref, 3),
	ok = graphdb_mgr:retire_node(Tgt2),
	?assertEqual({error, {endpoint_retired, Tgt2}},
		graphdb_instance:add_relationship(Src, Fwd, Tgt2, Rec)).


%%-----------------------------------------------------------------------------
%% class_of returns the membership class via the instance->class arc.
%%-----------------------------------------------------------------------------
class_of_returns_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("Red", ClassNref, 5),
	?assertEqual({ok, ClassNref}, graphdb_instance:class_of(InstNref)).


%%=============================================================================
%% Lookup Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_instance returns an instance node.
%%-----------------------------------------------------------------------------
get_instance_returns_node(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Widget", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("W1", ClassNref, 5),
	{ok, Node} = graphdb_instance:get_instance(InstNref),
	?assertEqual(InstNref, Node#node.nref),
	?assertEqual(instance, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_instance returns {error, not_found} for unknown nref.
%%-----------------------------------------------------------------------------
get_instance_not_found(_Config) ->
	?assertEqual({error, not_found}, graphdb_instance:get_instance(99999)).

%%-----------------------------------------------------------------------------
%% get_instance rejects non-instance nodes.
%%-----------------------------------------------------------------------------
get_instance_rejects_non_instance(_Config) ->
	%% Nref 1 (Root) is a category
	?assertEqual({error, not_an_instance}, graphdb_instance:get_instance(1)).


%%=============================================================================
%% Hierarchy Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% children returns direct instance-kind children.
%%-----------------------------------------------------------------------------
children_returns_instance_children(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Car", 3),
	{ok, Car, _} = graphdb_instance:create_instance("MyCar", ClassNref, 5),
	{ok, Engine, _} = graphdb_instance:create_instance("Engine1", ClassNref, Car),
	{ok, Wheel, _} = graphdb_instance:create_instance("Wheel1", ClassNref, Car),
	{ok, Kids} = graphdb_instance:children(Car),
	KidNrefs = lists:sort([N#node.nref || N <- Kids]),
	?assertEqual(lists:sort([Engine, Wheel]), KidNrefs).

%%-----------------------------------------------------------------------------
%% children returns empty list for a leaf instance.
%%-----------------------------------------------------------------------------
children_empty_for_leaf(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Leaf", 3),
	{ok, Leaf, _} = graphdb_instance:create_instance("Leaf1", ClassNref, 5),
	?assertEqual({ok, []}, graphdb_instance:children(Leaf)).

%%-----------------------------------------------------------------------------
%% compositional_ancestors returns the chain in nearest-first order.
%%-----------------------------------------------------------------------------
ancestors_returns_chain(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, Car, _} = graphdb_instance:create_instance("Car", ClassNref, 5),
	{ok, Engine, _} = graphdb_instance:create_instance("Engine", ClassNref, Car),
	{ok, Block, _} = graphdb_instance:create_instance("Block", ClassNref, Engine),
	{ok, Ancestors} = graphdb_instance:compositional_ancestors(Block),
	AncNrefs = [N#node.nref || N <- Ancestors],
	%% Nearest-first: Engine, then Car
	?assertEqual([Engine, Car], AncNrefs).

%%-----------------------------------------------------------------------------
%% compositional_ancestors returns empty for top-level instance (parent
%% is a non-instance node like a category).
%%-----------------------------------------------------------------------------
ancestors_empty_for_top_level(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Top", 3),
	{ok, Top, _} = graphdb_instance:create_instance("Top1", ClassNref, 5),
	?assertEqual({ok, []}, graphdb_instance:compositional_ancestors(Top)).


%%=============================================================================
%% Inheritance Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% resolve_value finds a value in the instance's own AVPs.
%%-----------------------------------------------------------------------------
resolve_value_local(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("T1", ClassNref, 5),
	%% The name attribute (20) was set by create_instance
	?assertMatch({ok, "T1", _},
		graphdb_instance:resolve_value(InstNref, ?NAME_ATTR_INSTANCE)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from the class node's AVPs.
%%-----------------------------------------------------------------------------
resolve_value_from_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	%% Add a custom AVP directly to the class node
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("shade", string),
	set_avp(ClassNref, TestAttr, "blue"),
	{ok, InstNref, _} = graphdb_instance:create_instance("C1", ClassNref, 5),
	%% Instance doesn't have shade — resolved from class
	?assertMatch({ok, "blue", _},
		graphdb_instance:resolve_value(InstNref, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from a compositional ancestor.
%%-----------------------------------------------------------------------------
resolve_value_from_ancestor(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("location", string),
	{ok, Car, _} = graphdb_instance:create_instance("Car", ClassNref, 5),
	set_avp(Car, TestAttr, "garage"),
	{ok, Engine, _} = graphdb_instance:create_instance("Engine", ClassNref, Car),
	{ok, Block, _} = graphdb_instance:create_instance("Block", ClassNref, Engine),
	%% Block doesn't have location, Engine doesn't — resolved from Car
	?assertMatch({ok, "garage", _},
		graphdb_instance:resolve_value(Block, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from a directly connected node.
%%-----------------------------------------------------------------------------
resolve_value_from_connected(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("country", string),
	{ok, Ford, _} = graphdb_instance:create_instance("Ford", ClassNref, 5),
	set_avp(Ford, TestAttr, "USA"),
	{ok, Taurus, _} = graphdb_instance:create_instance("Taurus", ClassNref, 5),
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute_pair("Makes", "MadeBy", instance),
	ok = graphdb_instance:add_relationship(Taurus, MadeByNref, Ford, MakesNref),
	%% Taurus doesn't have country, its class doesn't, no ancestors have it
	%% — resolved from connected Ford
	?assertMatch({ok, "USA", _},
		graphdb_instance:resolve_value(Taurus, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value returns not_found when attribute is nowhere.
%%-----------------------------------------------------------------------------
resolve_value_not_found(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Empty", 3),
	{ok, InstNref, _} = graphdb_instance:create_instance("E1", ClassNref, 5),
	?assertEqual(not_found,
		graphdb_instance:resolve_value(InstNref, 99999)).

%%-----------------------------------------------------------------------------
%% Priority: local value overrides class-level value.
%%-----------------------------------------------------------------------------
resolve_value_priority_local_over_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("hue", string),
	set_avp(ClassNref, TestAttr, "class_hue"),
	{ok, InstNref, _} = graphdb_instance:create_instance("C1", ClassNref, 5),
	set_avp(InstNref, TestAttr, "local_hue"),
	?assertMatch({ok, "local_hue", _},
		graphdb_instance:resolve_value(InstNref, TestAttr)).

%%-----------------------------------------------------------------------------
%% Priority: class-level value overrides compositional ancestor value.
%%-----------------------------------------------------------------------------
resolve_value_priority_class_over_ancestor(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("weight", string),
	set_avp(ClassNref, TestAttr, "class_weight"),
	{ok, Parent, _} = graphdb_instance:create_instance("P1", ClassNref, 5),
	set_avp(Parent, TestAttr, "parent_weight"),
	{ok, Child, _} = graphdb_instance:create_instance("C1", ClassNref, Parent),
	%% Child has no local value; class has weight; parent has weight
	%% Class (priority 2) should win over parent (priority 3)
	?assertMatch({ok, "class_weight", _},
		graphdb_instance:resolve_value(Child, TestAttr)).

%%-----------------------------------------------------------------------------
%% Priority: ancestor value overrides directly-connected-node value.
%%-----------------------------------------------------------------------------
resolve_value_priority_ancestor_over_connected(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("region", string),
	{ok, Parent, _} = graphdb_instance:create_instance("Parent", ClassNref, 5),
	set_avp(Parent, TestAttr, "ancestor_region"),
	{ok, Child, _} = graphdb_instance:create_instance("Child", ClassNref, Parent),
	{ok, Peer, _} = graphdb_instance:create_instance("Peer", ClassNref, 5),
	set_avp(Peer, TestAttr, "peer_region"),
	{ok, {LinksNref, LinkedByNref}} =
		graphdb_attr:create_relationship_attribute_pair("Links", "LinkedBy", instance),
	ok = graphdb_instance:add_relationship(Child, LinksNref, Peer, LinkedByNref),
	%% Child has no local value, class has no value
	%% Ancestor Parent (priority 3) should win over connected Peer (priority 4)
	?assertMatch({ok, "ancestor_region", _},
		graphdb_instance:resolve_value(Child, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_from_class must walk the class taxonomy.  Animal IS-A
%% Mammal IS-A Dog: an attribute bound on Animal must be visible to a
%% Dog instance even when neither Mammal nor Dog defines it.
%%-----------------------------------------------------------------------------
resolve_value_walks_class_taxonomy(_Config) ->
	{ok, AnimalNref} = graphdb_class:create_class("Animal", 3),
	{ok, MammalNref} = graphdb_class:create_class("Mammal", AnimalNref),
	{ok, DogNref}    = graphdb_class:create_class("Dog", MammalNref),
	{ok, TestAttr}   = graphdb_attr:create_literal_attribute("kingdom", string),
	%% Bind kingdom only on the topmost class
	set_avp(AnimalNref, TestAttr, "Animalia"),
	{ok, Rex, _} = graphdb_instance:create_instance("Rex", DogNref, 5),
	?assertMatch({ok, "Animalia", _},
		graphdb_instance:resolve_value(Rex, TestAttr)).

%%-----------------------------------------------------------------------------
%% when both the local class and a taxonomy ancestor bind the same
%% attribute, the nearest class wins (taxonomy walk is nearest-first).
%%-----------------------------------------------------------------------------
resolve_value_local_class_overrides_taxonomy_ancestor(_Config) ->
	{ok, AnimalNref} = graphdb_class:create_class("Animal", 3),
	{ok, DogNref}    = graphdb_class:create_class("Dog", AnimalNref),
	{ok, TestAttr}   = graphdb_attr:create_literal_attribute("class_color", string),
	set_avp(AnimalNref, TestAttr, "from_animal"),
	set_avp(DogNref,    TestAttr, "from_dog"),
	{ok, Rex, _} = graphdb_instance:create_instance("Rex", DogNref, 5),
	?assertMatch({ok, "from_dog", _},
		graphdb_instance:resolve_value(Rex, TestAttr)).

%%-----------------------------------------------------------------------------
%% Priority 4 ("directly connected nodes") must consider only
%% connection-kind arcs.  A value bound on the compositional parent's
%% category (reached only via the parent_arc) must not surface via P4.
%%-----------------------------------------------------------------------------
resolve_value_p4_ignores_compositional_arc(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Widget", 3),
	{ok, TestAttr}  = graphdb_attr:create_literal_attribute("color", string),
	%% Bind color directly on the Projects category (nref 5)
	set_avp(5, TestAttr, "category_color"),
	{ok, InstNref, _} = graphdb_instance:create_instance("W1", ClassNref, 5),
	%% Local: no.  Class: no.  Ancestors: P3 stops at category 5
	%% (non-instance).  P4 must not pick up category 5's AVP via the
	%% parent_arc — only true connection arcs count.
	?assertEqual(not_found,
		graphdb_instance:resolve_value(InstNref, TestAttr)).


%%-----------------------------------------------------------------------------
%% Task 0: Source tagging — Priority 1 hit returns `local`.
%%-----------------------------------------------------------------------------
resolve_value_source_local(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
	{ok, AttrNref}  = graphdb_attr:create_literal_attribute("weight", number),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, AttrNref),
	{ok, InstNref, _}  = graphdb_instance:create_instance(
						"Taurus", ClassNref, ?NREF_PROJECTS),
	set_avp(InstNref, AttrNref, 3500),
	?assertEqual({ok, 3500, local},
		graphdb_instance:resolve_value(InstNref, AttrNref)).

%%-----------------------------------------------------------------------------
%% Task 0: Source tagging — Priority 2 hit returns `{class, ClassNref}`.
%% Requires graphdb_class:bind_qc_value/3 to set the class-level value.
%%-----------------------------------------------------------------------------
resolve_value_source_class(_Config) ->
	{ok, Veh}    = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
	{ok, AttrN}  = graphdb_attr:create_literal_attribute("weight", number),
	ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN),
	ok = graphdb_class:bind_qc_value(Veh, AttrN, 3500),
	{ok, InstN, _}  = graphdb_instance:create_instance(
						"Taurus", Veh, ?NREF_PROJECTS),
	?assertEqual({ok, 3500, {class, Veh}},
		graphdb_instance:resolve_value(InstN, AttrN)).

%%-----------------------------------------------------------------------------
%% Task 0: Source tagging — Priority 3 hit returns `{compositional, AncNref}`
%% identifying the ancestor instance that held the value.
%%-----------------------------------------------------------------------------
resolve_value_source_ancestor(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", ?NREF_CLASSES),
	{ok, TestAttr}  = graphdb_attr:create_literal_attribute("location", string),
	{ok, Car, _}       = graphdb_instance:create_instance(
						"Car", ClassNref, ?NREF_PROJECTS),
	set_avp(Car, TestAttr, "garage"),
	{ok, Engine, _}    = graphdb_instance:create_instance(
						"Engine", ClassNref, Car),
	{ok, Block, _}     = graphdb_instance:create_instance(
						"Block", ClassNref, Engine),
	?assertEqual({ok, "garage", {compositional, Car}},
		graphdb_instance:resolve_value(Block, TestAttr)).

%%-----------------------------------------------------------------------------
%% Task 0: Source tagging — Priority 4 hit returns `{connected, NodeNref}`
%% identifying the directly-connected node that held the value.
%%-----------------------------------------------------------------------------
resolve_value_source_connected(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", ?NREF_CLASSES),
	{ok, TestAttr}  = graphdb_attr:create_literal_attribute("country", string),
	{ok, Ford, _}      = graphdb_instance:create_instance(
						"Ford", ClassNref, ?NREF_PROJECTS),
	set_avp(Ford, TestAttr, "USA"),
	{ok, Taurus, _}    = graphdb_instance:create_instance(
						"Taurus", ClassNref, ?NREF_PROJECTS),
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute_pair("Makes", "MadeBy", instance),
	ok = graphdb_instance:add_relationship(Taurus, MadeByNref, Ford, MakesNref),
	?assertEqual({ok, "USA", {connected, Ford}},
		graphdb_instance:resolve_value(Taurus, TestAttr)).


%%=============================================================================
%% Multi-Membership Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% After add_class_membership/2, class_memberships/1 returns both classes
%% in order added.
%%-----------------------------------------------------------------------------
add_class_membership_basic(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("Vehicle", 3),
	{ok, ClassB} = graphdb_class:create_class("Toy", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("ToyCar", ClassA, 5),
	?assertEqual({ok, [ClassA]}, graphdb_instance:class_memberships(Inst)),
	?assertEqual(ok, graphdb_instance:add_class_membership(Inst, ClassB)),
	?assertEqual({ok, [ClassA, ClassB]},
		graphdb_instance:class_memberships(Inst)).

%%-----------------------------------------------------------------------------
%% add_class_membership writes a 29/30 arc pair.
%%-----------------------------------------------------------------------------
add_class_membership_writes_arcs(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, ClassB} = graphdb_class:create_class("B", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),

	%% Instance -> ClassB (char=29, reciprocal=30)
	{atomic, InstOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Inst, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= ClassB andalso
		R#relationship.characterization =:= ?ARC_INST_TO_CLASS andalso
		R#relationship.reciprocal =:= ?ARC_CLASS_TO_INST
	end, InstOut)),

	%% ClassB -> Instance (char=30, reciprocal=29)
	{atomic, ClassOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, ClassB, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Inst andalso
		R#relationship.characterization =:= ?ARC_CLASS_TO_INST andalso
		R#relationship.reciprocal =:= ?ARC_INST_TO_CLASS
	end, ClassOut)).

%%-----------------------------------------------------------------------------
%% Re-adding the same class is a no-op.  Cache stays single-valued and
%% no extra arcs are written.
%%-----------------------------------------------------------------------------
add_class_membership_idempotent(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, ClassB} = graphdb_class:create_class("B", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	RelsBefore = mnesia:table_info(relationships, size),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore, RelsAfter),
	?assertEqual({ok, [ClassA, ClassB]},
		graphdb_instance:class_memberships(Inst)).

%%-----------------------------------------------------------------------------
%% Missing instance subject is rejected.
%%-----------------------------------------------------------------------------
add_class_membership_rejects_missing_instance(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	?assertEqual({error, not_found},
		graphdb_instance:add_class_membership(99999, ClassA)).

%%-----------------------------------------------------------------------------
%% Non-instance subject (e.g., a class node) is rejected.
%%-----------------------------------------------------------------------------
add_class_membership_rejects_non_instance(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	?assertEqual({error, not_an_instance},
		graphdb_instance:add_class_membership(ClassA, ClassA)).

%%-----------------------------------------------------------------------------
%% Missing class target is rejected.
%%-----------------------------------------------------------------------------
add_class_membership_rejects_missing_class(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	?assertEqual({error, class_not_found},
		graphdb_instance:add_class_membership(Inst, 99999)).

%%-----------------------------------------------------------------------------
%% Non-class target (e.g., an attribute node) is rejected.
%%-----------------------------------------------------------------------------
add_class_membership_rejects_non_class_target(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	%% Nref 6 (Names) is an attribute node
	?assertMatch({error, {not_a_class, attribute}},
		graphdb_instance:add_class_membership(Inst, 6)).

%%-----------------------------------------------------------------------------
%% A non-instantiable (abstract) class target is rejected — an instance
%% cannot become a member of an abstract class (that would make it an
%% instance of one).  Same guard as create_instance.
%%-----------------------------------------------------------------------------
add_class_membership_refuses_abstract_class(_Config) ->
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	{ok, ClassA}   = graphdb_class:create_class("A", 3),
	{ok, Instance, _} = graphdb_instance:create_instance("X", ClassA, 5),
	{ok, Abstract} = graphdb_class:create_class("Meta", 3,
		[#{attribute => Inst, value => false}]),
	RelsBefore = mnesia:table_info(relationships, size),
	?assertEqual({error, {class_not_instantiable, Abstract}},
		graphdb_instance:add_class_membership(Instance, Abstract)),
	?assertEqual(RelsBefore, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% add_class_membership rejects a retired class node.
%%-----------------------------------------------------------------------------
add_class_membership_refuses_retired_class(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("MemA", 3),
	{ok, ClassB} = graphdb_class:create_class("MemB", 3),
	{ok, Inst, _} = graphdb_instance:create_instance("m", ClassA, 3),
	ok = graphdb_mgr:retire_node(ClassB),
	?assertEqual({error, {class_retired, ClassB}},
		graphdb_instance:add_class_membership(Inst, ClassB)).

%%-----------------------------------------------------------------------------
%% After create_instance/3, class_memberships/1 returns the single class.
%%-----------------------------------------------------------------------------
class_memberships_initial(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	?assertEqual({ok, [ClassA]}, graphdb_instance:class_memberships(Inst)).


%%=============================================================================
%% Multi-Membership Resolver Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Two classes, only one binds the attribute.  resolve_value returns
%% that unique value.
%%-----------------------------------------------------------------------------
resolve_value_unique_across_two_classes(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("Mode", 3),
	{ok, ClassB} = graphdb_class:create_class("Tag", 3),
	{ok, Attr}   = graphdb_attr:create_literal_attribute("badge", string),
	set_avp(ClassA, Attr, "blue_badge"),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	?assertMatch({ok, "blue_badge", _},
		graphdb_instance:resolve_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Two classes both bind the attribute to the SAME value.  Not
%% ambiguous -- single distinct value wins.
%%-----------------------------------------------------------------------------
resolve_value_same_value_two_classes(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, ClassB} = graphdb_class:create_class("B", 3),
	{ok, Attr}   = graphdb_attr:create_literal_attribute("colour", string),
	set_avp(ClassA, Attr, "red"),
	set_avp(ClassB, Attr, "red"),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	?assertMatch({ok, "red", _},
		graphdb_instance:resolve_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Two classes bind the attribute to DIFFERENT values.  Resolver returns
%% an ambiguous_class_value error listing both class:value pairs.
%%-----------------------------------------------------------------------------
resolve_value_ambiguous_two_classes(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, ClassB} = graphdb_class:create_class("B", 3),
	{ok, Attr}   = graphdb_attr:create_literal_attribute("flavour", string),
	set_avp(ClassA, Attr, "sweet"),
	set_avp(ClassB, Attr, "salty"),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	Result = graphdb_instance:resolve_value(Inst, Attr),
	?assertMatch({error, {ambiguous_class_value, Attr, _}}, Result),
	{error, {ambiguous_class_value, _, Hits}} = Result,
	?assertEqual(lists:sort([{ClassA, "sweet"}, {ClassB, "salty"}]),
		lists:sort(Hits)).

%%-----------------------------------------------------------------------------
%% A local instance value still wins over an otherwise ambiguous pair
%% of class-level bindings (Priority 1 outranks Priority 2 -- ambiguity
%% is only checked when no local value exists).
%%-----------------------------------------------------------------------------
resolve_value_local_overrides_ambiguity(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("A", 3),
	{ok, ClassB} = graphdb_class:create_class("B", 3),
	{ok, Attr}   = graphdb_attr:create_literal_attribute("flavour", string),
	set_avp(ClassA, Attr, "sweet"),
	set_avp(ClassB, Attr, "salty"),
	{ok, Inst, _}   = graphdb_instance:create_instance("X", ClassA, 5),
	ok = graphdb_instance:add_class_membership(Inst, ClassB),
	set_avp(Inst, Attr, "umami"),
	?assertMatch({ok, "umami", _},
		graphdb_instance:resolve_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Per-membership taxonomy walk: ClassA's ancestor binds X, ClassB binds
%% Y locally.  Both branches contribute to ambiguity detection, and the
%% reported ClassNref is whichever class actually held the value (the
%% ancestor for ClassA's branch, ClassB itself for the other).
%%-----------------------------------------------------------------------------
resolve_value_ambiguity_via_taxonomy(_Config) ->
	{ok, AnimalCls} = graphdb_class:create_class("Animal", 3),
	{ok, MammalCls} = graphdb_class:create_class("Mammal", AnimalCls),
	{ok, ToyCls}    = graphdb_class:create_class("Toy", 3),
	{ok, Attr}      = graphdb_attr:create_literal_attribute("origin", string),
	set_avp(AnimalCls, Attr, "biological"),
	set_avp(ToyCls,    Attr, "manufactured"),
	{ok, Inst, _} = graphdb_instance:create_instance("Plushie", MammalCls, 5),
	ok = graphdb_instance:add_class_membership(Inst, ToyCls),
	Result = graphdb_instance:resolve_value(Inst, Attr),
	?assertMatch({error, {ambiguous_class_value, Attr, _}}, Result),
	{error, {ambiguous_class_value, _, Hits}} = Result,
	?assertEqual(
		lists:sort([{AnimalCls, "biological"}, {ToyCls, "manufactured"}]),
		lists:sort(Hits)).


%%=============================================================================
%% Firing Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% No rules attached — create_instance succeeds with an empty report.
%%-----------------------------------------------------------------------------
firing_no_rules_baseline(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Plain", 3),
	{ok, Nref, Report} = graphdb_instance:create_instance("p1", ClassNref, 5),
	?assert(is_integer(Nref)),
	?assertEqual([], Report).

%%-----------------------------------------------------------------------------
%% One mandatory rule (mult=1) fires a single child and reports it.
%%-----------------------------------------------------------------------------
firing_single_mandatory(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% one Bolt child created, reported fired under the rule
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),
	[#{rule := _, outcomes := [#{owner := Root, status := fired,
								 child := ChildNref}]}] = Report,
	?assert(lists:member(ChildNref,
		[N || {node, N, _, _, _, _} <- Kids])).

%%-----------------------------------------------------------------------------
%% Multiplicity=3 fires three children; report carries 3 outcomes indexed 1-3;
%% the deployment in the report reflects the real rule deployment.
%%-----------------------------------------------------------------------------
firing_mandatory_mult(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {3, 3}),
	{ok, _Root, [#{deployment := Dep, outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(3, length(Outs)),
	?assertEqual([1, 2, 3], [maps:get(index, O) || O <- Outs]),
	%% report carries the rule's real deployment map
	?assertEqual({3, 3}, maps:get(multiplicity, Dep)),
	?assertEqual(mandatory, maps:get(mode, Dep)).

%%-----------------------------------------------------------------------------
%% Two-level cascade: Owner->Bolt->Widget all written atomically.
%%-----------------------------------------------------------------------------
firing_mandatory_cascade_atomic(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BW", Bolt, Widget, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	{ok, [BoltInst]} = graphdb_instance:children(Root),
	BoltNref = element(2, BoltInst),
	{ok, [_Widget]} = graphdb_instance:children(BoltNref),
	%% both rules report a fired outcome
	?assertEqual(2, length(Report)).

%%-----------------------------------------------------------------------------
%% A mandatory rule targeting an abstract class fails; the transaction rolls
%% back (nothing written) and the report contains a failed outcome.
%%-----------------------------------------------------------------------------
firing_mandatory_failure_rolls_back(Config) ->
	{Owner, Abstract} = ?config(oa, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OA", Owner, Abstract, mandatory, {1, 1}),
	Before = mnesia:table_info(nodes, size),
	{error, {class_not_instantiable, Abstract}, Report} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(Before, mnesia:table_info(nodes, size)),   %% nothing written
	%% culprit rule has a failed outcome in the report
	?assert(lists:any(
		fun(#{outcomes := Os}) ->
			lists:any(fun(#{status := S}) -> S =:= failed end, Os)
		end, Report)).


%%-----------------------------------------------------------------------------
%% An auto rule fires best-effort post-commit; root is created and the auto
%% child appears in the compositional tree.
%%-----------------------------------------------------------------------------
firing_auto_best_effort(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto", Owner, Bolt, auto, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	{ok, [_]} = graphdb_instance:children(Root),       %% auto child created
	?assertEqual(#{fired => 1, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% An auto rule targeting an abstract class fails (best-effort); the root
%% instance survives and the report carries one failed outcome.
%%-----------------------------------------------------------------------------
firing_auto_failure_survives(Config) ->
	{Owner, Abstract} = ?config(oa, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OAauto", Owner, Abstract, auto, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assert(is_integer(Root)),                         %% root survived
	?assertEqual(#{fired => 0, failed => 1, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% Owner -auto-> Bolt; Bolt -mandatory-> Widget.  The auto Bolt and its
%% mandatory Widget both fire; the merged report carries two fired outcomes.
%%-----------------------------------------------------------------------------
firing_auto_cascade_merges(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto", Owner, Bolt, auto, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BW", Bolt, Widget, mandatory, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% the auto Bolt and its mandatory Widget both fired
	?assertEqual(#{fired => 2, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% a propose rule surfaces a `proposed` outcome carrying owner (the
%% materialised parent), proposed_class, index and name — and creates NOTHING.
%%-----------------------------------------------------------------------------
firing_propose_outcome_in_report(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% no child materialised
	?assertEqual({ok, []}, graphdb_instance:children(Root)),
	%% exactly one proposed outcome, owner=Root, proposed_class=Bolt, no child key
	[#{outcomes := [Outcome]}] = Report,
	?assertEqual(proposed, maps:get(status, Outcome)),
	?assertEqual(Root, maps:get(owner, Outcome)),
	?assertEqual(Bolt, maps:get(proposed_class, Outcome)),
	?assertEqual(1, maps:get(index, Outcome)),
	?assertNot(maps:is_key(child, Outcome)).      %% no created-instance key

%%-----------------------------------------------------------------------------
%% a propose rule materialises nothing — node table size is unchanged
%% beyond the single root instance.
%%-----------------------------------------------------------------------------
firing_propose_not_materialised(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {3, 3}),
	Before = mnesia:table_info(nodes, size),
	{ok, _Root, _Report} = graphdb_instance:create_instance("car", Owner, 5),
	After = mnesia:table_info(nodes, size),
	?assertEqual(Before + 1, After).      %% only the root, no proposed children

%%-----------------------------------------------------------------------------
%% multiplicity=3 propose yields three proposed outcomes, indices 1..3,
%% names per name_pattern.
%%-----------------------------------------------------------------------------
firing_propose_multiplicity_bounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {3, 3}, undefined,
		#{name_pattern => "Spare {i}"}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(3, length(Outs)),
	?assertEqual([1, 2, 3], [maps:get(index, O) || O <- Outs]),
	?assertEqual(["Spare 1", "Spare 2", "Spare 3"],
				 [maps:get(name, O) || O <- Outs]),
	?assert(lists:all(fun(O) -> maps:get(status, O) =:= proposed end, Outs)).

%%-----------------------------------------------------------------------------
%% {1, unbounded} propose yields one proposed outcome (index 1) carrying
%% max => unbounded.  The old index=unbounded sentinel is retired.
%%-----------------------------------------------------------------------------
firing_propose_multiplicity_unbounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {1, unbounded}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(1, length(Outs)),
	[#{index := Idx, status := proposed, max := Max}] = Outs,
	?assertEqual(1, Idx),
	?assertEqual(unbounded, Max).

%%-----------------------------------------------------------------------------
%% a propose rule whose child class is already on the
%% root->here path is cut — no proposed outcome.  Owner's class proposes
%% Owner (self), so nothing is surfaced.
%%-----------------------------------------------------------------------------
firing_propose_on_path_cut(Config) ->
	{Owner, _Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "selfpropose", Owner, Owner, propose, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual([], Report).

%%-----------------------------------------------------------------------------
%% summarize/1 counts proposed outcomes (and the map gains the key).
%%-----------------------------------------------------------------------------
firing_propose_summarize(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {2, 2}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(#{fired => 0, failed => 0, not_attempted => 0, proposed => 2,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% all three modes on one create — mandatory + auto materialise, propose
%% is surfaced but not materialised.
%%-----------------------------------------------------------------------------
firing_propose_with_mandatory_and_auto(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	%% graphdb_instance_SUITE has no make_class/1 helper — create the third
	%% class directly (parent nref 3 = Classes category).
	{ok, Gizmo} = graphdb_class:create_class("Gizmo", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "man", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "aut", Owner, Widget, auto, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "pro", Owner, Gizmo, propose, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% two children materialised (mandatory Bolt + auto Widget), Gizmo is not
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(2, length(Kids)),
	?assertEqual(#{fired => 2, failed => 0, not_attempted => 0, proposed => 1,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% a propose rule on a MANDATORY child's class surfaces a proposed outcome
%% whose owner is the materialised child (NOT the root) — proves owner rides
%% proposals at depth, not just at the requested-instance level.
%%-----------------------------------------------------------------------------
firing_propose_owner_is_materialised_child(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BWpropose", Bolt, Widget, propose, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% the materialised mandatory child
	{ok, [BoltInst]} = graphdb_instance:children(Root),
	BoltNref = element(2, BoltInst),
	%% find the proposed outcome across all rule reports
	Proposed = [O || #{outcomes := Os} <- Report, O <- Os,
					 maps:get(status, O) =:= proposed],
	?assertEqual(1, length(Proposed)),
	[PO] = Proposed,
	?assertEqual(Widget, maps:get(proposed_class, PO)),
	%% owner is the materialised Bolt child, NOT the root
	?assertEqual(BoltNref, maps:get(owner, PO)),
	?assertNotEqual(Root, maps:get(owner, PO)).


%%-----------------------------------------------------------------------------
%% propose {3, 5} surfaces 3 outcomes, each carrying max => 5.
%%-----------------------------------------------------------------------------
firing_propose_carries_max(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBp3-5", Owner, Bolt, propose, {3, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(3, length(Outs)),
	?assertEqual([1, 2, 3], [maps:get(index, O) || O <- Outs]),
	?assert(lists:all(fun(O) -> maps:get(max, O) =:= 5 end, Outs)),
	?assert(lists:all(fun(O) -> maps:get(status, O) =:= proposed end, Outs)),
	%% no index=unbounded sentinel survives
	?assertEqual([], [O || O <- Outs, maps:get(index, O) =:= unbounded]).

%%-----------------------------------------------------------------------------
%% {0, K} propose surfaces nothing by default (Min = 0); the ceiling K
%% is for the future interactive-creation session (BP-OI-1).
%%-----------------------------------------------------------------------------
firing_propose_min_zero_surfaces_none(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBp0-3", Owner, Bolt, propose, {0, 3}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(0, maps:get(proposed, graphdb_instance:summarize(Report))).

%%-----------------------------------------------------------------------------
%% mandatory composition mints Min children.
%%-----------------------------------------------------------------------------
firing_mandatory_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB2-5", Owner, Bolt, mandatory, {2, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(2, length(Fired)),
	?assertEqual([1, 2], [maps:get(index, O) || O <- Fired]).

%%-----------------------------------------------------------------------------
%% {0, K} mandatory mints nothing (vacuous) and does not fail.
%%-----------------------------------------------------------------------------
firing_mandatory_min_zero_mints_none(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB0-3", Owner, Bolt, mandatory, {0, 3}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(#{fired => 0, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% {1, unbounded} mandatory mints Min (1) — no
%% unbounded_multiplicity_not_fireable.
%%-----------------------------------------------------------------------------
firing_mandatory_min_unbounded_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB1-U", Owner, Bolt, mandatory, {1, unbounded}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(1, length(Fired)),
	?assert(lists:all(fun(O) ->
		maps:get(reason, O, none) =/= unbounded_multiplicity_not_fireable
	end, Outs)).

%%-----------------------------------------------------------------------------
%% auto composition mints Min children post-commit.
%%-----------------------------------------------------------------------------
firing_auto_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto2-5", Owner, Bolt, auto, {2, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(2, length(Fired)).

%%-----------------------------------------------------------------------------
%% {0, unbounded} auto mints nothing and does not fail.
%%-----------------------------------------------------------------------------
firing_auto_min_zero_unbounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto0-U", Owner, Bolt, auto, {0, unbounded}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	Outs = lists:append([maps:get(outcomes, RR) || RR <- Report]),
	?assertEqual([], [O || O <- Outs,
		maps:get(reason, O, none) =:= unbounded_multiplicity_not_fireable]),
	#{failed := 0} = graphdb_instance:summarize(Report).


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
%% set_avp(Nref, AttrNref, Value) -> ok
%%
%% Appends an AVP to the node's existing attribute_value_pairs.
%% Used by tests to inject values for inheritance testing.
%%-----------------------------------------------------------------------------
set_avp(Nref, AttrNref, Value) ->
	{atomic, ok} = mnesia:transaction(fun() ->
		[Node] = mnesia:read(nodes, Nref),
		AVPs = Node#node.attribute_value_pairs,
		NewAVP = #{attribute => AttrNref, value => Value},
		Updated = Node#node{attribute_value_pairs = AVPs ++ [NewAVP]},
		ok = mnesia:write(nodes, Updated, write)
	end),
	ok.


-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "instance_").


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


%%=============================================================================
%% Connection Firing Tests
%%=============================================================================
%% These cases build their own classes (NOT via setup_firing_fixtures) and
%% exercise the RESOLVE defer-path: report-only (/3) and explicit defer-all (/4)
%% resolvers surface effective connection rules as required/not_connected/
%% proposed outcomes; nothing is connected.

%% /3 report-only: a mandatory connection rule surfaces as `required`, nothing
%% connected, create succeeds (the /3 mandatory escape).
firing_conn_report_only_mandatory(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assert(is_integer(Root)),                          %% create succeeded
	?assertEqual([], b4_conn_targets(Root, Char)),      %% nothing connected
	O = b4_single_outcome(Report),
	?assertEqual(required, maps:get(status, O)),
	?assertEqual(Root, maps:get(source, O)),
	?assertEqual(Char, maps:get(characterization, O)),
	?assertEqual(Tgt,  maps:get(target_class, O)),
	?assertNot(maps:is_key(target, O)).                 %% no target on a non-connect

firing_conn_report_only_auto(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assertEqual(not_connected, maps:get(status, b4_single_outcome(Report))).

firing_conn_report_only_propose(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, propose, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(proposed, maps:get(status, b4_single_outcome(Report))).

%% /4 with an explicit defer-all resolver behaves exactly like /3 report-only.
firing_conn_explicit_defer(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> defer end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(required, maps:get(status, b4_single_outcome(Report))).

%% summarize counts the connection statuses alongside the composition ones.
firing_conn_summarize(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	S = graphdb_instance:summarize(Report),
	?assertEqual(1, maps:get(required, S)),
	?assertEqual(0, maps:get(connected, S)),
	?assertEqual(0, maps:get(not_connected, S)).


%%=============================================================================
%% Mandatory Commit Path Tests
%%=============================================================================

%% mandatory + committing resolver: arc pair written in the root txn; outcome
%% `connected`; reverse arc reaches the source.
firing_conn_mandatory_connected(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Target = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Target]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([Target], b4_conn_targets(Root, Char)),       %% forward arc
	?assertEqual([Root], b4_conn_targets(Target, Recip)),      %% reverse arc
	O = b4_single_outcome(Report),
	?assertEqual(connected, maps:get(status, O)),
	?assertEqual(Target, maps:get(target, O)),
	?assertEqual(Root,   maps:get(source, O)).

%% mandatory shortfall: resolver commits an empty list (< Min=1) -> create fails,
%% nothing written.
firing_conn_mandatory_shortfall_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, []} end,
	Before = mnesia:table_info(nodes, size),
	{error, {mandatory_connection_unsatisfied, RuleNref}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)),      %% nothing written
	?assert(lists:any(
		fun(#{outcomes := Os}) ->
			lists:any(fun(#{status := S}) -> S =:= failed end, Os)
		end, Report)).

%% mandatory + invalid target (wrong class) -> create fails, nothing written.
firing_conn_mandatory_invalid_target_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, Other} = graphdb_class:create_class("Other", 3),
	Wrong = b4_target_instance("wrong", Other),               %% not a Mfr
	R = fun(_Ctx) -> {connect, [Wrong]} end,
	Before = mnesia:table_info(nodes, size),
	{error, {invalid_connection_target, _}, _Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%% multiplicity {1,2}: resolver returns 3 valid -> exactly 2 written (cap=Max).
firing_conn_mandatory_caps_at_max(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 2}),
	T1 = b4_target_instance("m1", Tgt),
	T2 = b4_target_instance("m2", Tgt),
	T3 = b4_target_instance("m3", Tgt),
	R = fun(_Ctx) -> {connect, [T1, T2, T3]} end,
	{ok, Root, _Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(2, length(b4_conn_targets(Root, Char))).

%% rollback cause is discriminable: a class carrying BOTH a mandatory composition
%% rule (abstract child) and a mandatory connection rule.  The composition
%% shortfall aborts in PLAN, before RESOLVE -> culprit is a composition outcome
%% (has `child`/no `target`) and no connection outcome was produced.
firing_conn_rollback_discriminable_composition(_Config) ->
	{ok, InstAttr}  = b4_inst_attr(),
	{ok, Src}       = graphdb_class:create_class("Car", 3),
	{ok, Abstract}  = graphdb_class:create_class("Abs", 3,
		[#{attribute => InstAttr, value => false}]),
	{ok, Tgt}       = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by", "makes",
														instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CA", Src, Abstract, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CM", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Mfr = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Mfr]} end,
	{error, {class_not_instantiable, Abstract}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	%% the lone failed outcome is a COMPOSITION culprit: carries no connection keys
	Failed = [O || #{outcomes := Os} <- Report, #{status := failed} = O <- Os],
	?assertEqual(1, length(Failed)),
	[F] = Failed,
	?assertNot(maps:is_key(target, F)),
	?assertNot(maps:is_key(characterization, F)).

%% the mirror case: composition planned cleanly, connection shortfall aborts in
%% RESOLVE -> culprit is a CONNECTION outcome (carries characterization), and the
%% composition outcomes are all not_attempted.
firing_conn_rollback_discriminable_connection(_Config) ->
	{ok, Src}  = graphdb_class:create_class("Car", 3),
	{ok, Bolt} = graphdb_class:create_class("Bolt", 3),
	{ok, Tgt}  = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by", "makes",
														instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CB", Src, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CM", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, []} end,                  %% shortfall
	Before = mnesia:table_info(nodes, size),
	{error, {mandatory_connection_unsatisfied, _}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)),
	%% lone failed outcome is a CONNECTION culprit (has characterization);
	%% the composition Bolt rule is not_attempted.
	Failed = [O || #{outcomes := Os} <- Report, #{status := failed} = O <- Os],
	[F] = Failed,
	?assert(maps:is_key(characterization, F)),
	?assert(lists:any(
		fun(#{outcomes := Os}) ->
			lists:any(fun(#{status := S}) -> S =:= not_attempted end, Os)
		end, Report)).

%% a mandatory connection rule on a mandatory COMPOSITION descendant fires in the
%% same root txn; outcome source = the descendant nref.
firing_conn_descendant_in_root_txn(_Config) ->
	{ok, Owner} = graphdb_class:create_class("Owner", 3),
	{ok, Bolt}  = graphdb_class:create_class("Bolt", 3),
	{ok, Tgt}   = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by", "makes",
														instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "BM", Bolt, Char, Recip, Tgt, mandatory, {1, 1}),
	Mfr = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Mfr]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Owner, 5, R),
	{ok, [BoltInst]} = graphdb_instance:children(Root),
	BoltNref = element(2, BoltInst),
	?assertEqual([Mfr], b4_conn_targets(BoltNref, Char)),
	%% the connected outcome's source is the Bolt descendant, not the root
	Connected = [O || #{outcomes := Os} <- Report,
					  #{status := connected} = O <- Os],
	[C] = Connected,
	?assertEqual(BoltNref, maps:get(source, C)).


%%=============================================================================
%% Auto Connection Post-Commit Tests
%%=============================================================================

%% auto + committing resolver: target connected post-commit; root survives.
firing_conn_auto_connected(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	Target = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Target]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([Target], b4_conn_targets(Root, Char)),
	?assertEqual(connected, maps:get(status, b4_single_outcome(Report))).

%% auto + invalid target: survives as a failed outcome; root still created.
firing_conn_auto_invalid_survives(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	{ok, Other} = graphdb_class:create_class("Other", 3),
	Wrong = b4_target_instance("wrong", Other),
	R = fun(_Ctx) -> {connect, [Wrong]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assert(is_integer(Root)),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(failed, maps:get(status, b4_single_outcome(Report))).


%%=============================================================================
%% Target Validation Tests
%%=============================================================================

%% a target that is an instance of a SUBCLASS of target_class is accepted.
firing_conn_subclass_target_accepted(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, SubMfr} = graphdb_class:create_class("SubMfr", Tgt),   %% subclass of Mfr
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Target = b4_target_instance("acme", SubMfr),
	R = fun(_Ctx) -> {connect, [Target]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([Target], b4_conn_targets(Root, Char)),
	?assertEqual(connected, maps:get(status, b4_single_outcome(Report))).

%% a missing target nref on a mandatory rule fails the create; nothing written.
firing_conn_missing_target_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, [999999]} end,
	Before = mnesia:table_info(nodes, size),
	{error, {invalid_connection_target, {target_not_found, 999999}}, _Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%% a non-instance target (a class nref) on a mandatory rule fails the create.
firing_conn_non_instance_target_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, [Tgt]} end,             %% Tgt is a class, not an instance
	Before = mnesia:table_info(nodes, size),
	{error, {invalid_connection_target, {target_not_an_instance, Tgt}}, _R} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%% resolver-supplied per-direction AVPs are stamped on the written arc.
firing_conn_resolver_avps_stamped(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Target = b4_target_instance("acme", Tgt),
	FwdAVP = #{attribute => Char, value => "fwd-meta"},
	RevAVP = #{attribute => Recip, value => "rev-meta"},
	R = fun(_Ctx) -> {connect, [{Target, {[FwdAVP], [RevAVP]}}]} end,
	{ok, Root, _Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	Fwd = b4_conn_arc(Root, Char),
	Rev = b4_conn_arc(Target, Recip),
	?assert(lists:member(FwdAVP, Fwd#relationship.avps)),
	?assert(lists:member(RevAVP, Rev#relationship.avps)).


%%=============================================================================
%% Connection-firing helpers
%%=============================================================================

%% the single outgoing connection arc (#relationship{}) from Source with char.
b4_conn_arc(Source, Char) ->
	Arcs = mnesia:dirty_index_read(relationships, Source,
								   #relationship.source_nref),
	[Arc] = [A || A <- Arcs,
			 A#relationship.kind =:= connection,
			 A#relationship.characterization =:= Char],
	Arc.

%% the seeded instantiable marker nref (for building abstract classes).
b4_inst_attr() ->
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	{ok, InstAttr}.

%% make a pre-existing target instance of class Tgt, parented at Projects (5).
b4_target_instance(Name, Tgt) ->
	{ok, Nref, _} = graphdb_instance:create_instance(Name, Tgt, 5),
	Nref.

%% make a (Source, Target, Char, Recip) connection fixture; returns nrefs.
b4_conn_classes(SrcName, TgtName, Fwd, Rev) ->
	{ok, Src} = graphdb_class:create_class(SrcName, 3),
	{ok, Tgt} = graphdb_class:create_class(TgtName, 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair(Fwd, Rev, instance),
	{Src, Tgt, Char, Recip}.

%% the single connection outcome in a report (asserts exactly one rule, one out).
b4_single_outcome(Report) ->
	[#{outcomes := [Outcome]}] = Report,
	Outcome.

%% outgoing connection arc targets from Source with characterization Char.
b4_conn_targets(Source, Char) ->
	Arcs = mnesia:dirty_index_read(relationships, Source,
								   #relationship.source_nref),
	[A#relationship.target_nref || A <- Arcs,
	 A#relationship.kind =:= connection,
	 A#relationship.characterization =:= Char].


%%-----------------------------------------------------------------------------
%% B5 plumbing: create_instance/5 is accepted and, with the default resolver,
%% a single inherited mandatory rule still fires exactly as /3 (no regression).
%%-----------------------------------------------------------------------------
b5_create_instance_5_accepts_resolvers(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	Conn     = fun(_Ctx) -> defer end,
	Conflict = graphdb_rules:default_conflict_resolver(),
	{ok, Root, Report} =
		graphdb_instance:create_instance("car", Vehicle, 5, Conn, Conflict),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),
	?assertEqual(#{fired => 1, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% B5 plumbing: /3 (built-in default conflict resolver) is unchanged for a
%% plain single-rule fire.
%%-----------------------------------------------------------------------------
b5_default_resolver_single_rule_unchanged(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Vehicle, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),
	?assertEqual(1, length(Report)).

%%-----------------------------------------------------------------------------
%% Firing flip (B5-D2 at firing time): Cell mandates Nucleus (mandatory) and
%% proposes Nucleus.  Under B5 only ONE Nucleus is minted (mandatory wins).
%%-----------------------------------------------------------------------------
b5_firing_same_level_mode_priority(_Config) ->
	{ok, Cell}    = graphdb_class:create_class("Cell", 3),
	{ok, Nucleus} = graphdb_class:create_class("Nucleus", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-prop", Cell, Nucleus, propose, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-mand", Cell, Nucleus, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("c1", Cell, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),                 %% exactly one Nucleus minted
	#{fired := 1, proposed := 0} =
		maps:with([fired, proposed], graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% Cross-level shadow at firing time: Car + Vehicle both mandate Engine -> one
%% Engine minted (not two).
%%-----------------------------------------------------------------------------
b5_firing_cross_level_shadow(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	{ok, Root, _Report} = graphdb_instance:create_instance("car", Car, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)).

%%-----------------------------------------------------------------------------
%% Custom resolver overrides the seam: a pure-additive resolver makes Car +
%% Vehicle both fire (two Engines), proving the policy is caller-overridable.
%%-----------------------------------------------------------------------------
b5_custom_resolver_pure_additive(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	Additive = fun(#{rules := R}) -> R end,
	Conn     = fun(_Ctx) -> defer end,
	{ok, Root, _Report} =
		graphdb_instance:create_instance("car", Car, 5, Conn, Additive),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(2, length(Kids)).                 %% additive: both fire


%%=============================================================================
%% Remove-relationship helpers and test cases
%%=============================================================================

%% Setup helper: class, default template, two instances, a reciprocal
%% arc-label pair, and one connection edge A--Char-->B.  Returns the nrefs.
re_setup() ->
	{ok, ClassNref}   = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	#{class => ClassNref, tmpl => DefaultTmpl, a => A, b => B,
	  char => Char, recip => Recip}.

%% count forward connection rows A--Char-->B
re_count(A, Char, B) ->
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	length([R || R <- Rows,
		R#relationship.kind =:= connection,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B]).

remove_relationship_basic(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	?assertEqual(1, re_count(A, Char, B)),
	?assertEqual(1, re_count(B, Recip, A)),
	ok = graphdb_instance:remove_relationship(A, Char, B),
	?assertEqual(0, re_count(A, Char, B)),
	?assertEqual(0, re_count(B, Recip, A)).

remove_relationship_not_found(_Config) ->
	#{a := A, b := B, char := Char} = re_setup(),
	?assertEqual({error, relationship_not_found},
		graphdb_instance:remove_relationship(A, Char, B)).

remove_relationship_ambiguous(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip, class := Class} = re_setup(),
	{ok, DefaultTmpl} = graphdb_class:default_template(Class),
	{ok, AltTmpl}     = graphdb_class:add_template(Class, "social"),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, AltTmpl),
	?assertMatch({error, {ambiguous_relationship, [_, _]}},
		graphdb_instance:remove_relationship(A, Char, B)).

remove_relationship_disambiguate_by_template(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip, class := Class} = re_setup(),
	{ok, DefaultTmpl} = graphdb_class:default_template(Class),
	{ok, AltTmpl}     = graphdb_class:add_template(Class, "social"),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, AltTmpl),
	ok = graphdb_instance:remove_relationship(A, Char, B, DefaultTmpl),
	%% one edge (the AltTmpl one) remains in each direction
	?assertEqual(1, re_count(A, Char, B)),
	?assertEqual(1, re_count(B, Recip, A)).

remove_relationship_dangling_half_edge(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	%% manually delete the reverse row, leaving a half-edge
	{atomic, ok} = mnesia:transaction(fun() ->
		Rows = mnesia:index_read(relationships, B, #relationship.source_nref),
		[Rev] = [R || R <- Rows,
			R#relationship.characterization =:= Recip,
			R#relationship.target_nref =:= A],
		mnesia:delete_object(relationships, Rev, write)
	end),
	?assertMatch({error, {dangling_half_edge, _}},
		graphdb_instance:remove_relationship(A, Char, B)),
	%% the forward row is NOT deleted -- rollback left it intact
	?assertEqual(1, re_count(A, Char, B)).


%%=============================================================================
%% Update-relationship (single direction) helpers and test cases
%%=============================================================================

%% fetch the single forward row's avps
re_avps(A, Char, B) ->
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[R] = [X || X <- Rows,
		X#relationship.kind =:= connection,
		X#relationship.characterization =:= Char,
		X#relationship.target_nref =:= B],
	R#relationship.avps.

update_relationship_single_direction(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	ok = graphdb_instance:update_relationship(A, Char, B,
		[#{attribute => Note, value => "fwd"}]),
	?assert(lists:member(#{attribute => Note, value => "fwd"},
		re_avps(A, Char, B))),
	%% reverse row untouched (proves independence)
	?assertNot(lists:member(#{attribute => Note, value => "fwd"},
		re_avps(B, Recip, A))).

update_relationship_reverse_direction(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	%% name the reverse direction from the other endpoint: (T, R, S)
	ok = graphdb_instance:update_relationship(B, Recip, A,
		[#{attribute => Note, value => "rev"}]),
	?assert(lists:member(#{attribute => Note, value => "rev"},
		re_avps(B, Recip, A))),
	?assertNot(lists:member(#{attribute => Note, value => "rev"},
		re_avps(A, Char, B))).

update_relationship_protects_template(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	?assertEqual({error, {protected_relationship_avp, ?ARC_TEMPLATE}},
		graphdb_instance:update_relationship(A, Char, B,
			[#{attribute => ?ARC_TEMPLATE, value => 7}])).

update_relationship_not_found(_Config) ->
	#{a := A, b := B, char := Char} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	?assertEqual({error, relationship_not_found},
		graphdb_instance:update_relationship(A, Char, B,
			[#{attribute => Note, value => "x"}])).

update_relationship_both_directions(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, FAttr} = graphdb_attr:create_literal_attribute("fwd_meta", string),
	{ok, RAttr} = graphdb_attr:create_literal_attribute("rev_meta", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	ok = graphdb_instance:update_relationship_both(A, Char, B,
		{[#{attribute => FAttr, value => "F"}],
		 [#{attribute => RAttr, value => "R"}]}),
	FwdAVPs = re_avps(A, Char, B),
	RevAVPs = re_avps(B, Recip, A),
	?assert(lists:member(#{attribute => FAttr, value => "F"}, FwdAVPs)),
	?assertNot(lists:member(#{attribute => RAttr, value => "R"}, FwdAVPs)),
	?assert(lists:member(#{attribute => RAttr, value => "R"}, RevAVPs)),
	?assertNot(lists:member(#{attribute => FAttr, value => "F"}, RevAVPs)).
