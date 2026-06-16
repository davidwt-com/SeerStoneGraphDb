%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: June 2026
%% Description: Common Test integration suite for graphdb_rules.
%%				Each test case gets its own isolated temp
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
%% #relationship{} record is exercised by the composition group
%% (read_arc/3) and later tasks.
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
%% Effective connection-rule test case exports
%%---------------------------------------------------------------------
-export([
	effective_connection_rules_returns_specs/1,
	effective_connection_rules_excludes_composition/1,
	effective_connection_rules_project_scope_empty/1
]).

%%---------------------------------------------------------------------
%% Plan firing test case exports
%%---------------------------------------------------------------------
-export([
	plan_single_mandatory/1,
	plan_name_pattern/1,
	plan_mult_one_singular_name/1,
	plan_auto_annotated_not_expanded/1,
	plan_propose_accumulated/1,
	plan_mixed_modes/1,
	plan_propose_at_mandatory_child/1,
	plan_unbounded_mandatory_mints_min/1,
	plan_abstract_mandatory_child_fails/1,
	plan_cascade/1,
	plan_cycle_self_nest_zero_children/1,
	plan_cycle_a_b_a/1,
	plan_project_scope_is_leaf/1
]).

%%---------------------------------------------------------------------
%% Conflict resolution test case exports (F4 B5)
%%---------------------------------------------------------------------
-export([
	b5_comp_cross_level_shadow/1,
	b5_comp_descendant_shadow/1,
	b5_comp_additive_unrelated/1,
	b5_comp_max_merge_unbounded/1,
	b5_comp_same_level_mode_priority/1
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
	seeded_nrefs_returns_all_thirteen/1,
	name_pattern_is_seeded/1,
	seeds_reciprocal_literal/1,
	%% composition
	creates_composition_rule_minimal/1,
	creates_composition_rule_with_template/1,
	applies_to_arc_pair_written/1,
	instance_to_class_membership_written/1,
	avps_present_and_correct/1,
	%% connection
	creates_connection_rule_minimal/1,
	creates_connection_rule_with_template/1,
	instance_to_class_membership_to_connection_rule/1,
	connection_rule_stores_reciprocal/1,
	%% validation
	class_not_found_rejected/1,
	not_a_class_rejected/1,
	abstract_owning_class_rejected/1,
	referenced_class_not_found_rejected/1,
	referenced_not_a_class_rejected/1,
	characterization_not_found_rejected/1,
	reciprocal_not_found_rejected/1,
	not_a_relationship_attribute_rejected/1,
	reciprocal_not_a_relationship_attribute_rejected/1,
	template_not_found_rejected/1,
	not_a_template_rejected/1,
	invalid_mode_rejected/1,
	invalid_multiplicity_rejected/1,
	multiplicity_range_validation/1,
	failed_validation_consumes_no_nref/1,
	%% retrieval
	rules_for_class_returns_all_kinds/1,
	composition_rules_for_class_filters_by_kind/1,
	connection_rules_for_class_filters_by_kind/1,
	get_rule_returns_full_record/1,
	get_rule_not_found/1,
	list_rules_returns_all/1,
	%% scope
	project_scope_rejected_on_create/1,
	project_scope_returns_empty_on_retrieve/1,
	%% complex scenarios
	mixed_rules_on_one_class/1,
	rule_isolation_across_class_taxonomy/1,
	duplicate_child_class_with_different_modes/1,
	%% name_pattern
	composition_rule_carries_name_pattern/1,
	%% effective
	self_only_no_ancestors/1,
	linear_chain_nearest_first/1,
	diamond_dag_dedup/1,
	shared_rule_node_across_ancestors/1,
	deployment_avps_surfaced/1,
	additive_parent_and_child/1,
	empty_levels_skipped/1,
	mixed_kinds_returned/1,
	project_scope_empty/1,
	unknown_class_empty/1,
	non_class_nref_empty/1,
	%% cache audit
	verify_caches_passes_after_rule_creation/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, seeding}, {group, composition}, {group, connection},
	 {group, validation}, {group, retrieval}, {group, scope},
	 {group, complex_scenarios}, {group, effective}, {group, cache_audit},
	 {group, plan_firing}, {group, conflict_resolution}].

groups() ->
	[
		{seeding, [], [
			seeds_rule_meta_ontology_idempotent,
			seeds_rule_literals_subgroup,
			seeds_literal_attributes_under_rule_literals,
			seeds_applies_to_pair,
			seeded_nrefs_returns_all_thirteen,
			name_pattern_is_seeded,
			seeds_reciprocal_literal
		]},
		{composition, [], [
			creates_composition_rule_minimal,
			creates_composition_rule_with_template,
			applies_to_arc_pair_written,
			instance_to_class_membership_written,
			avps_present_and_correct,
			composition_rule_carries_name_pattern
		]},
		{connection, [], [
			creates_connection_rule_minimal,
			creates_connection_rule_with_template,
			instance_to_class_membership_to_connection_rule,
			connection_rule_stores_reciprocal
		]},
		{validation, [], [
			class_not_found_rejected,
			not_a_class_rejected,
			abstract_owning_class_rejected,
			referenced_class_not_found_rejected,
			referenced_not_a_class_rejected,
			characterization_not_found_rejected,
			reciprocal_not_found_rejected,
			not_a_relationship_attribute_rejected,
			reciprocal_not_a_relationship_attribute_rejected,
			template_not_found_rejected,
			not_a_template_rejected,
			invalid_mode_rejected,
			invalid_multiplicity_rejected,
			multiplicity_range_validation,
			failed_validation_consumes_no_nref
		]},
		{retrieval, [], [
			rules_for_class_returns_all_kinds,
			composition_rules_for_class_filters_by_kind,
			connection_rules_for_class_filters_by_kind,
			get_rule_returns_full_record,
			get_rule_not_found,
			list_rules_returns_all
		]},
		{scope, [], [
			project_scope_rejected_on_create,
			project_scope_returns_empty_on_retrieve
		]},
		{complex_scenarios, [], [
			mixed_rules_on_one_class,
			rule_isolation_across_class_taxonomy,
			duplicate_child_class_with_different_modes
		]},
		{effective, [], [
			self_only_no_ancestors,
			linear_chain_nearest_first,
			diamond_dag_dedup,
			shared_rule_node_across_ancestors,
			deployment_avps_surfaced,
			additive_parent_and_child,
			empty_levels_skipped,
			mixed_kinds_returned,
			project_scope_empty,
			unknown_class_empty,
			non_class_nref_empty,
			effective_connection_rules_returns_specs,
			effective_connection_rules_excludes_composition,
			effective_connection_rules_project_scope_empty
		]},
		{cache_audit, [], [
			verify_caches_passes_after_rule_creation
		]},
		{plan_firing, [], [
			plan_single_mandatory,
			plan_name_pattern,
			plan_mult_one_singular_name,
			plan_auto_annotated_not_expanded,
			plan_unbounded_mandatory_mints_min,
			plan_abstract_mandatory_child_fails,
			plan_cascade,
			plan_cycle_self_nest_zero_children,
			plan_cycle_a_b_a,
			plan_project_scope_is_leaf,
			plan_propose_accumulated,
			plan_mixed_modes,
			plan_propose_at_mandatory_child
		]},
		{conflict_resolution, [], [
			b5_comp_cross_level_shadow,
			b5_comp_descendant_shadow,
			b5_comp_additive_unrelated,
			b5_comp_max_merge_unbounded,
			b5_comp_same_level_mode_priority
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
	{ok, _} = graphdb_language:start_link(),
	{ok, _} = graphdb_query:start_link(),
	{ok, _} = graphdb_rules:start_link(),
	plan_firing_fixtures(TC, Config1).

%% plan_firing_fixtures/2  — gate: only runs for plan_firing test cases.
%% Creates shared class fixtures and stashes them in Config.
plan_firing_fixtures(TC, Config) ->
	PlanFiringCases = [
		plan_single_mandatory, plan_name_pattern, plan_mult_one_singular_name,
		plan_auto_annotated_not_expanded, plan_unbounded_mandatory_mints_min,
		plan_abstract_mandatory_child_fails, plan_cascade,
		plan_cycle_self_nest_zero_children, plan_cycle_a_b_a,
		plan_project_scope_is_leaf,
		plan_propose_accumulated, plan_mixed_modes,
		plan_propose_at_mandatory_child
	],
	case lists:member(TC, PlanFiringCases) of
		false ->
			Config;
		true ->
			Owner    = make_class("Owner"),
			Bolt     = make_class("Bolt"),
			Widget   = make_class("Widget"),
			Abstract = make_abstract_class("Abstract"),
			Folder   = make_class("Folder"),
			A        = make_class("A"),
			B        = make_class("B"),
			[{ob, {Owner, Bolt}}, {oa, {Owner, Abstract}},
			 {obw, {Owner, Bolt, Widget}}, {folder, Folder}, {ab, {A, B}}
			 | Config]
	end.

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
	%% Rule is abstract: is_instantiable/1 = false
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

seeded_nrefs_returns_all_thirteen(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Expected = [rule, composition_rule, connection_rule,
				applies_to, applied_by, rule_literals_group,
				child_class_nref_attr, target_class_nref_attr,
				template_nref_attr, characterization_nref_attr,
				reciprocal_nref_attr,
				mode_attr, multiplicity_attr, name_pattern],
	lists:foreach(fun(K) -> ?assert(maps:is_key(K, S)) end, Expected),
	?assertEqual(length(Expected), maps:size(S)).

name_pattern_is_seeded(_Config) ->
	{ok, Seeds} = graphdb_rules:seeded_nrefs(),
	?assert(maps:is_key(name_pattern, Seeds)),
	NP = maps:get(name_pattern, Seeds),
	?assert(is_integer(NP)),
	%% it lives under the Rule Literals group
	RuleLit = maps:get(rule_literals_group, Seeds),
	{ok, NP} = graphdb_attr:find_attribute_by_name(RuleLit, "name_pattern").

seeds_reciprocal_literal(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Recip = maps:get(reciprocal_nref_attr, S),
	?assert(is_integer(Recip)),
	%% distinct from the characterization literal it sits beside
	?assertNotEqual(maps:get(characterization_nref_attr, S), Recip),
	%% it is a child of the Rule Literals sub-group
	RuleLit = maps:get(rule_literals_group, S),
	{ok, Recip2} = graphdb_attr:find_attribute_by_name(RuleLit, "reciprocal_nref"),
	?assertEqual(Recip, Recip2).


%%=============================================================================
%% Composition Tests
%%=============================================================================

creates_composition_rule_minimal(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, {1, 1}),
	?assert(is_integer(RuleNref)),
	{ok, #node{kind = instance, classes = Classes}} = node_read2(RuleNref),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	?assertEqual([maps:get(composition_rule, S)], Classes).

creates_composition_rule_with_template(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Wheel"),
	{ok, DT} = graphdb_class:default_template(Parent),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-wheel", Parent, Child, auto, {4, 4}, DT),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	TemplateAttr = maps:get(template_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

applies_to_arc_pair_written(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	AppliesTo = maps:get(applies_to, S),
	AppliedBy = maps:get(applied_by, S),
	ModeAttr  = maps:get(mode_attr, S),
	MultAttr  = maps:get(multiplicity_attr, S),
	{ok, DT}  = graphdb_class:default_template(Parent),
	Fwd = read_arc(Parent, AppliesTo, RuleNref),
	Rev = read_arc(RuleNref, AppliedBy, Parent),
	?assertEqual(connection, Fwd#relationship.kind),
	?assertEqual(connection, Rev#relationship.kind),
	FAVPs = Fwd#relationship.avps,
	?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => DT}, FAVPs)),
	?assert(lists:member(#{attribute => ModeAttr, value => mandatory}, FAVPs)),
	?assert(lists:member(#{attribute => MultAttr, value => {1, 1}}, FAVPs)).

instance_to_class_membership_written(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Comp = maps:get(composition_rule, S),
	I2C = read_arc(RuleNref, ?ARC_INST_TO_CLASS, Comp),
	C2I = read_arc(Comp, ?ARC_CLASS_TO_INST, RuleNref),
	?assertEqual(instantiation, I2C#relationship.kind),
	?assertEqual(instantiation, C2I#relationship.kind).

avps_present_and_correct(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	ChildAttr = maps:get(child_class_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => ?NAME_ATTR_INSTANCE,
						   value => "car-has-engine"}, AVPs)),
	?assert(lists:member(#{attribute => ChildAttr, value => Child}, AVPs)),
	%% no deployment AVPs leaked onto the node
	ModeAttr = maps:get(mode_attr, S),
	?assertNot(lists:any(fun(#{attribute := A}) -> A =:= ModeAttr end, AVPs)).

composition_rule_carries_name_pattern(_Config) ->
	Owner = make_class("Car"),
	Child = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "PatRule", Owner, Child, mandatory, {2, 2}, undefined,
		#{name_pattern => "Bolt {i}"}),
	{ok, #node{attribute_value_pairs = AVPs}} =
		graphdb_rules:get_rule(environment, RuleNref),
	{ok, Seeds} = graphdb_rules:seeded_nrefs(),
	NP = maps:get(name_pattern, Seeds),
	?assertEqual({ok, "Bolt {i}"}, find_avp(AVPs, NP)).

%%-----------------------------------------------------------------------------
%% a propose-mode rule lands in propose_rules (NOT auto_rules /
%% mandatory_children), unexpanded — exactly one {RuleNode, Deploy} entry
%% regardless of multiplicity.
%%-----------------------------------------------------------------------------
plan_propose_accumulated(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {3, 3}),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{class := Owner, mandatory_children := [], auto_rules := [],
	  propose_rules := [{_RuleNode, Dep}]} = Plan,
	?assertEqual(propose, maps:get(mode, Dep)),
	?assertEqual({3, 3}, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% one rule of each mode on the same owner populates all three
%% accumulators independently.
%%-----------------------------------------------------------------------------
plan_mixed_modes(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	Gizmo = make_class("Gizmo"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "man", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "aut", Owner, Widget, auto, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "pro", Owner, Gizmo, propose, {1, 1}),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{mandatory_children := Mand, auto_rules := Auto,
	  propose_rules := Prop} = Plan,
	?assertEqual(1, length(Mand)),
	?assertEqual(1, length(Auto)),
	?assertEqual(1, length(Prop)),
	%% the mandatory child is the Bolt class, not Widget/Gizmo
	[#{class := Bolt}] = Mand.

%%-----------------------------------------------------------------------------
%% a propose rule attached to a MANDATORY child's class appears in that
%% child's plan node (propose rides the mandatory-cascade recursion).
%%-----------------------------------------------------------------------------
plan_propose_at_mandatory_child(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BWpropose", Bolt, Widget, propose, {1, 1}),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{mandatory_children := [BoltPlan]} = Plan,
	#{class := Bolt, propose_rules := [{_R, Dep}]} = BoltPlan,
	?assertEqual(propose, maps:get(mode, Dep)).


%%=============================================================================
%% Connection Tests
%%=============================================================================

creates_connection_rule_minimal(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	CharAttr   = maps:get(characterization_nref_attr, S),
	TargetAttr = maps:get(target_class_nref_attr, S),
	{ok, #node{kind = instance, classes = Classes,
			   attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assertEqual([maps:get(connection_rule, S)], Classes),
	?assert(lists:member(#{attribute => CharAttr, value => Char}, AVPs)),
	?assert(lists:member(#{attribute => TargetAttr, value => Target}, AVPs)).

creates_connection_rule_with_template(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	{ok, DT} = graphdb_class:default_template(Source),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Recip, Target,
		propose, {1, unbounded}, DT),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	TemplateAttr = maps:get(template_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

instance_to_class_membership_to_connection_rule(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Conn = maps:get(connection_rule, S),
	I2C = read_arc(RuleNref, ?ARC_INST_TO_CLASS, Conn),
	?assertEqual(instantiation, I2C#relationship.kind).

connection_rule_stores_reciprocal(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	RecipAttr = maps:get(reciprocal_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => RecipAttr, value => Recip}, AVPs)).


%%=============================================================================
%% Validation Tests
%%=============================================================================
%% Validation runs entirely BEFORE do_create_rule allocates any nref, so a
%% rejected create writes nothing.  Each case asserts the specific error atom
%% AND that the nodes table is unchanged (compare table_size/1 before/after).

class_not_found_rejected(_Config) ->
	Child = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, class_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", 999999, Child, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

not_a_class_rejected(_Config) ->
	Child = make_class("Engine"),
	%% nref 6 (Names) is an attribute, not a class
	Before = table_size(nodes),
	?assertEqual({error, not_a_class},
		graphdb_rules:create_composition_rule(
			environment, "x", ?NREF_NAMES, Child, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

abstract_owning_class_rejected(_Config) ->
	Abstract = make_abstract_class("AbstractCar"),
	Child    = make_class("Engine"),
	Before   = table_size(nodes),
	?assertEqual({error, owning_class_has_no_default_template},
		graphdb_rules:create_composition_rule(
			environment, "x", Abstract, Child, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

referenced_class_not_found_rejected(_Config) ->
	Parent = make_class("Car"),
	Before = table_size(nodes),
	?assertEqual({error, referenced_class_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, 999999, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

referenced_not_a_class_rejected(_Config) ->
	Parent = make_class("Car"),
	Before = table_size(nodes),
	?assertEqual({error, referenced_not_a_class},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, ?NREF_NAMES, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

characterization_not_found_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Recip  = make_rel_char("placed", "placed_by"),
	Before = table_size(nodes),
	?assertEqual({error, characterization_not_found},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, 999999, Recip, Target, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

reciprocal_not_found_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	Before = table_size(nodes),
	?assertEqual({error, reciprocal_not_found},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, Char, 999999, Target, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

not_a_relationship_attribute_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	%% a literal attribute, not a relationship attribute
	{ok, Lit} = graphdb_attr:create_literal_attribute("weight", integer),
	Recip  = make_rel_char("placed", "placed_by"),
	Before = table_size(nodes),
	?assertEqual({error, not_a_relationship_attribute},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, Lit, Recip, Target, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

reciprocal_not_a_relationship_attribute_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	{ok, Lit} = graphdb_attr:create_literal_attribute("weight2", integer),
	Before = table_size(nodes),
	?assertEqual({error, reciprocal_not_a_relationship_attribute},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, Char, Lit, Target, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

template_not_found_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, template_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, {1, 1}, 999999)),
	?assertEqual(Before, table_size(nodes)).

not_a_template_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	%% Child is a class, not a template
	Before = table_size(nodes),
	?assertEqual({error, not_a_template},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, {1, 1}, Child)),
	?assertEqual(Before, table_size(nodes)).

invalid_mode_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, invalid_mode},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, bogus, {1, 1})),
	?assertEqual(Before, table_size(nodes)).

invalid_multiplicity_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, invalid_multiplicity},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, 0)),
	?assertEqual({error, invalid_multiplicity},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, "lots")),
	?assertEqual(Before, table_size(nodes)).

%% the {Min, Max} validation catalogue.
multiplicity_range_validation(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Ok = fun(Mult) ->
		{ok, _} = graphdb_rules:create_composition_rule(
			environment, "ok", Parent, Child, auto, Mult)
	end,
	Bad = fun(Mult) ->
		?assertEqual({error, invalid_multiplicity},
			graphdb_rules:create_composition_rule(
				environment, "bad", Parent, Child, auto, Mult))
	end,
	%% accepted
	Ok({1, 1}),
	Ok({0, 3}),
	Ok({2, unbounded}),
	%% rejected
	Bad({3, 1}),        %% Max < Min
	Bad({1, 0}),        %% Max < 1
	Bad({0, 0}),        %% Max < 1
	Bad(5),             %% bare integer
	Bad(unbounded),     %% bare unbounded
	Bad({a, b}).        %% non-integers

failed_validation_consumes_no_nref(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	%% graphdb_nref has no peek API (only get_next/0); assert no node was
	%% written, which proves the write path never ran and consumed no nref.
	%% Use a LATE-validator rejection (template_not_found, after the pure
	%% mode/multiplicity and the owning/referenced-class checks) so the
	%% no-write invariant is exercised deeper in the chain than the
	%% earliest validator covers.
	Before = table_size(nodes),
	?assertEqual({error, template_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, {1, 1}, 999999)),
	?assertEqual(Before, table_size(nodes)).


%%=============================================================================
%% Retrieval Tests
%%=============================================================================

rules_for_class_returns_all_kinds(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "makes"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Recip, Maker, mandatory, {1, 1}),
	{ok, Rules} = graphdb_rules:rules_for_class(environment, Car),
	Nrefs = [N#node.nref || N <- Rules],
	?assertEqual(lists:sort([R1, R2]), lists:sort(Nrefs)).

composition_rules_for_class_filters_by_kind(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "makes"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, _R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Recip, Maker, mandatory, {1, 1}),
	{ok, Comp} = graphdb_rules:composition_rules_for_class(environment, Car),
	?assertEqual([R1], [N#node.nref || N <- Comp]).

connection_rules_for_class_filters_by_kind(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "makes"),
	{ok, _R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Recip, Maker, mandatory, {1, 1}),
	{ok, Conn} = graphdb_rules:connection_rules_for_class(environment, Car),
	?assertEqual([R2], [N#node.nref || N <- Conn]).

get_rule_returns_full_record(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, #node{nref = R, kind = instance}} =
		graphdb_rules:get_rule(environment, R).

get_rule_not_found(_Config) ->
	%% Missing nref.
	?assertEqual(not_found, graphdb_rules:get_rule(environment, 999999)),
	%% Existing node that is NOT a rule instance (a plain class) must also
	%% be rejected -- exercises the kind/is_rule_instance discrimination,
	%% not just the missing-nref fall-through.
	Car = make_class("Car"),
	?assertEqual(not_found, graphdb_rules:get_rule(environment, Car)).

list_rules_returns_all(_Config) ->
	Car  = make_class("Car"),
	Eng  = make_class("Engine"),
	Bike = make_class("Bike"),
	Whl  = make_class("Wheel"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "car-engine", Car, Eng, mandatory, {1, 1}),
	{ok, R2} = graphdb_rules:create_composition_rule(
		environment, "bike-wheel", Bike, Whl, mandatory, {2, 2}),
	{ok, All} = graphdb_rules:list_rules(environment),
	Nrefs = [N#node.nref || N <- All],
	?assert(lists:member(R1, Nrefs)),
	?assert(lists:member(R2, Nrefs)).


%%=============================================================================
%% Scope Tests
%%=============================================================================
%% The rules data model supports environment-scoped rules only.  The {project, _} branches
%% (added across Tasks 2-5) lock the contract: create is rejected, every
%% retrieval returns empty / not_found.

project_scope_rejected_on_create(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	?assertEqual({error, project_rules_not_yet_supported},
		graphdb_rules:create_composition_rule(
			{project, 1}, "x", Parent, Child, mandatory, {1, 1})),
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	?assertEqual({error, project_rules_not_yet_supported},
		graphdb_rules:create_connection_rule(
			{project, 1}, "x", Source, Char, Recip, Target, mandatory, {1, 1})).

project_scope_returns_empty_on_retrieve(_Config) ->
	Car = make_class("Car"),
	?assertEqual({ok, []},
		graphdb_rules:rules_for_class({project, 1}, Car)),
	?assertEqual({ok, []},
		graphdb_rules:composition_rules_for_class({project, 1}, Car)),
	?assertEqual({ok, []}, graphdb_rules:list_rules({project, 1})),
	?assertEqual(not_found, graphdb_rules:get_rule({project, 1}, 999999)).


%%=============================================================================
%% Complex Scenario Tests
%%=============================================================================
%% Integration tests over the Task 2-5 API.  No new production code; these
%% exercise the create/retrieve paths in combination and document the data-model
%% semantics (direct-attachment retrieval, no conflict resolution).

%% Five distinct rules of both kinds attached to one owning class.  Asserts
%% the kind-partitioned retrieval counts, the exact applies_to arc count out
%% of the class, and the cache invariant.
mixed_rules_on_one_class(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Whl   = make_class("Wheel"),
	Sun   = make_class("Sunroof"),
	Maker = make_class("Manufacturer"),
	Deal  = make_class("Dealer"),
	{MadeBy, MadeByRev} = make_rel_pair("made_by", "makes"),
	{SoldBy, SoldByRev} = make_rel_pair("sold_by", "sells"),
	{ok, DT} = graphdb_class:default_template(Car),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "engine", Car, Eng, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "wheels", Car, Whl, auto, {4, 4}, DT),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "sunroof", Car, Sun, propose, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, MadeBy, MadeByRev, Maker, mandatory, {1, 1}, DT),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "sold-by", Car, SoldBy, SoldByRev, Deal, propose, {1, unbounded}),
	{ok, All}  = graphdb_rules:rules_for_class(environment, Car),
	{ok, Comp} = graphdb_rules:composition_rules_for_class(environment, Car),
	{ok, Conn} = graphdb_rules:connection_rules_for_class(environment, Car),
	?assertEqual(5, length(All)),
	?assertEqual(3, length(Comp)),
	?assertEqual(2, length(Conn)),
	%% five applies_to arcs out of Car
	{ok, S} = graphdb_rules:seeded_nrefs(),
	AppliesTo = maps:get(applies_to, S),
	Arcs = mnesia:dirty_index_read(relationships, Car,
								   #relationship.source_nref),
	Applies = [A || A <- Arcs, A#relationship.kind == connection,
			   A#relationship.characterization == AppliesTo],
	?assertEqual(5, length(Applies)),
	?assertEqual(ok, graphdb_mgr:verify_caches()).

%% Direct-attachment retrieval only: a rule on a superclass is NOT
%% returned for a subclass.  Documents that taxonomy-walking retrieval is
%% the taxonomy-walk read (effective_rules_for_class/2).
rule_isolation_across_class_taxonomy(_Config) ->
	Vehicle = make_class("Vehicle"),
	{ok, Car} = graphdb_class:create_class("Car", Vehicle),
	{ok, Sports} = graphdb_class:create_class("SportsCar", Car),
	Eng   = make_class("Engine"),
	Wheel = make_class("SteeringWheel"),
	Spoil = make_class("Spoiler"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "v-engine", Vehicle, Eng, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, {1, 1}),
	{ok, RV} = graphdb_rules:rules_for_class(environment, Vehicle),
	{ok, RC} = graphdb_rules:rules_for_class(environment, Car),
	{ok, RS} = graphdb_rules:rules_for_class(environment, Sports),
	?assertEqual(1, length(RV)),
	?assertEqual(1, length(RC)),
	?assertEqual(1, length(RS)).

%% Two composition rules with the same child class but different modes are
%% both accepted (distinct nrefs).  Documents that the data model makes no
%% conflict-resolution commitment.
duplicate_child_class_with_different_modes(_Config) ->
	Cell = make_class("Cell"),
	Nuc  = make_class("Nucleus"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "nuc-mandatory", Cell, Nuc, mandatory, {1, 1}),
	{ok, R2} = graphdb_rules:create_composition_rule(
		environment, "nuc-propose", Cell, Nuc, propose, {1, 1}),
	?assertNotEqual(R1, R2),
	{ok, Rules} = graphdb_rules:composition_rules_for_class(environment, Cell),
	?assertEqual(2, length(Rules)).


%%=============================================================================
%% Effective Rules Tests
%%=============================================================================
%% effective_rules_for_class/2 gathers rules from the class AND its taxonomy
%% ancestors, nearest-first, grouped by attaching class, each paired with that
%% attachment's deployment map.  It resolves nothing -- every level survives.

self_only_no_ancestors(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	?assertEqual([Car], level_nrefs(Levels)),
	?assertEqual([R], rule_nrefs_at(Car, Levels)).

linear_chain_nearest_first(_Config) ->
	Vehicle = make_class("Vehicle"),
	{ok, Car}    = graphdb_class:create_class("Car", Vehicle),
	{ok, Sports} = graphdb_class:create_class("SportsCar", Car),
	Eng   = make_class("Engine"),
	Wheel = make_class("SteeringWheel"),
	Spoil = make_class("Spoiler"),
	{ok, RV} = graphdb_rules:create_composition_rule(
		environment, "v-engine", Vehicle, Eng, mandatory, {1, 1}),
	{ok, RC} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, {1, 1}),
	{ok, RS} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, {1, 1}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Sports),
	%% nearest-first: SportsCar, then Car, then Vehicle
	?assertEqual([Sports, Car, Vehicle], level_nrefs(Levels)),
	?assertEqual([RS], rule_nrefs_at(Sports, Levels)),
	?assertEqual([RC], rule_nrefs_at(Car, Levels)),
	?assertEqual([RV], rule_nrefs_at(Vehicle, Levels)).

diamond_dag_dedup(_Config) ->
	Top  = make_class("Component"),
	{ok, Mid1} = graphdb_class:create_class("Electrical", Top),
	{ok, Mid2} = graphdb_class:create_class("Mechanical", Top),
	{ok, Bot}  = graphdb_class:create_class("Alternator", Mid1),
	ok = graphdb_class:add_superclass(Bot, Mid2),
	Wid = make_class("Winding"),
	Cas = make_class("Casing"),
	{ok, RT} = graphdb_rules:create_composition_rule(
		environment, "comp-winding", Top, Wid, mandatory, {1, 1}),
	{ok, RB} = graphdb_rules:create_composition_rule(
		environment, "alt-casing", Bot, Cas, auto, {1, 1}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Bot),
	Names = level_nrefs(Levels),
	%% Top appears exactly once despite being reachable via two parents.
	%% Mid1/Mid2 carry no rules and are omitted (empty levels).
	?assertEqual(1, length([L || L <- Names, L =:= Top])),
	?assertEqual([Bot, Top], Names),
	?assertEqual([RB], rule_nrefs_at(Bot, Levels)),
	?assertEqual([RT], rule_nrefs_at(Top, Levels)).

shared_rule_node_across_ancestors(_Config) ->
	%% A and B are two superclasses of Bot.  ONE rule node is attached to
	%% BOTH (rule reuse).  It must appear once per attaching ancestor, each
	%% occurrence carrying that ancestor's own deployment.
	A = make_class("Insurable"),
	B = make_class("Taxable"),
	{ok, Bot} = graphdb_class:create_class("Vehicle", A),
	ok = graphdb_class:add_superclass(Bot, B),
	Doc = make_class("Document"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "needs-document", A, Doc, mandatory, {1, 1}),
	ok = attach_existing_rule(B, R, mandatory, {3, 3}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Bot),
	?assertEqual([A, B], level_nrefs(Levels)),
	?assertMatch([{#node{nref = R}, #{multiplicity := {1, 1}}}], pairs_at(A, Levels)),
	?assertMatch([{#node{nref = R}, #{multiplicity := {3, 3}}}], pairs_at(B, Levels)).

deployment_avps_surfaced(_Config) ->
	Car = make_class("Car"),
	Whl = make_class("Wheel"),
	{ok, DT} = graphdb_class:default_template(Car),
	{ok, _R} = graphdb_rules:create_composition_rule(
		environment, "wheels", Car, Whl, auto, {4, 4}, DT),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	[{_RuleNode, Deploy}] = pairs_at(Car, Levels),
	?assertEqual(auto, maps:get(mode, Deploy)),
	?assertEqual({4, 4}, maps:get(multiplicity, Deploy)),
	?assertEqual(DT, maps:get(template, Deploy)).

additive_parent_and_child(_Config) ->
	%% Parent mandates a wheel-group (mult 1); subclass adds more (mult 4) for
	%% the SAME child class.  the gather drops nothing -- both survive, each with its
	%% own deployment.  The firing engine decides additive-vs-shadow.
	Vehicle = make_class("Vehicle"),
	{ok, Car} = graphdb_class:create_class("Car", Vehicle),
	Wheel = make_class("Wheel"),
	{ok, RV} = graphdb_rules:create_composition_rule(
		environment, "v-wheel", Vehicle, Wheel, mandatory, {1, 1}),
	{ok, RC} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, {4, 4}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	?assertEqual([Car, Vehicle], level_nrefs(Levels)),
	?assertEqual([RC], rule_nrefs_at(Car, Levels)),
	?assertEqual([RV], rule_nrefs_at(Vehicle, Levels)),
	[{_, DC}] = pairs_at(Car, Levels),
	[{_, DV}] = pairs_at(Vehicle, Levels),
	?assertEqual({4, 4}, maps:get(multiplicity, DC)),
	?assertEqual({1, 1}, maps:get(multiplicity, DV)).

empty_levels_skipped(_Config) ->
	Vehicle = make_class("Vehicle"),
	{ok, Car}    = graphdb_class:create_class("Car", Vehicle),
	{ok, Sports} = graphdb_class:create_class("SportsCar", Car),
	Spoil = make_class("Spoiler"),
	Eng   = make_class("Engine"),
	%% Rules on Sports and Vehicle only; the middle level (Car) has none.
	{ok, RS} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, {1, 1}),
	{ok, RV} = graphdb_rules:create_composition_rule(
		environment, "v-engine", Vehicle, Eng, mandatory, {1, 1}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Sports),
	%% Car omitted entirely; nearest-first order preserved.
	?assertEqual([Sports, Vehicle], level_nrefs(Levels)),
	?assertEqual([RS], rule_nrefs_at(Sports, Levels)),
	?assertEqual([RV], rule_nrefs_at(Vehicle, Levels)).

mixed_kinds_returned(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "makes"),
	{ok, RComp} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, {1, 1}),
	{ok, RConn} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Recip, Maker, mandatory, {1, 1}),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Comp = maps:get(composition_rule, S),
	Conn = maps:get(connection_rule, S),
	Pairs = pairs_at(Car, Levels),
	%% consumer pattern: inline kind filter over the gathered pairs.
	CompNrefs = [N#node.nref || {N, _D} <- Pairs,
				 lists:member(Comp, N#node.classes)],
	ConnNrefs = [N#node.nref || {N, _D} <- Pairs,
				 lists:member(Conn, N#node.classes)],
	?assertEqual([RComp], CompNrefs),
	?assertEqual([RConn], ConnNrefs).

project_scope_empty(_Config) ->
	Car = make_class("Car"),
	?assertEqual({ok, []},
		graphdb_rules:effective_rules_for_class({project, 1}, Car)).

unknown_class_empty(_Config) ->
	%% Non-existent nref: ancestors/1 -> {error, not_found}, mapped to [].
	?assertEqual({ok, []},
		graphdb_rules:effective_rules_for_class(environment, 999999)).

non_class_nref_empty(_Config) ->
	%% nref 6 (Names) is an attribute node, not a class:
	%% ancestors/1 -> {error, not_a_class}, mapped to [].
	?assertEqual({ok, []},
		graphdb_rules:effective_rules_for_class(environment, ?NREF_NAMES)).

effective_connection_rules_returns_specs(_Config) ->
	Source = make_class("Car"),
	Target = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "manufactures"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, Triples} = graphdb_rules:effective_connection_rules(environment, Source),
	[{RuleNode, Deploy, Spec}] = Triples,
	?assertEqual(RuleNref, RuleNode#node.nref),
	?assertEqual(mandatory, maps:get(mode, Deploy)),
	?assertEqual({1, 1}, maps:get(multiplicity, Deploy)),
	?assertEqual(Char,   maps:get(characterization, Spec)),
	?assertEqual(Recip,  maps:get(reciprocal, Spec)),
	?assertEqual(Target, maps:get(target_class, Spec)).

effective_connection_rules_excludes_composition(_Config) ->
	Parent = make_class("Engine"),
	Child  = make_class("Cylinder"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "EC", Parent, Child, mandatory, {1, 1}),
	%% a composition rule must NOT appear among connection rules
	?assertEqual({ok, []},
		graphdb_rules:effective_connection_rules(environment, Parent)).

effective_connection_rules_project_scope_empty(_Config) ->
	Source = make_class("Car"),
	?assertEqual({ok, []},
		graphdb_rules:effective_connection_rules({project, p1}, Source)).


%%=============================================================================
%% Plan Firing Tests
%%=============================================================================

%% plan_single_mandatory/1 — one mandatory rule, mult=2, two Bolt children.
%% Verifies the top-level plan shape: rule=root, deploy=undefined, name=undefined,
%% no auto_rules, and both expanded children have class=Bolt with fallback names.
plan_single_mandatory(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _R} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {2, 2}),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{class := Owner, mandatory_children := Kids, auto_rules := []} = Plan,
	?assertEqual(2, length(Kids)),
	[#{class := Bolt, name := N1}, #{class := Bolt, name := N2}] = Kids,
	?assertEqual("Bolt 1", N1),                      %% fallback, mult>1
	?assertEqual("Bolt 2", N2).

%% plan_name_pattern/1 — name_pattern AVP is threaded into child plan name.
%% Creates with mult=2 and name_pattern "Pin {i}"; expects two children named
%% "Pin 1" and "Pin 2".
plan_name_pattern(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {2, 2}, undefined,
		#{name_pattern => "Pin {i}"}),
	{ok, #{mandatory_children := [#{name := "Pin 1"}, #{name := "Pin 2"}]}} =
		graphdb_rules:plan_composition_firing(environment, Owner).

%% plan_mult_one_singular_name/1 — mult=1 with no name_pattern falls back to
%% class name (no index suffix).
plan_mult_one_singular_name(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, #{mandatory_children := [#{name := "Bolt"}]}} =       %% no index suffix
		graphdb_rules:plan_composition_firing(environment, Owner).

%% plan_auto_annotated_not_expanded/1 — auto rule appears in auto_rules, not
%% mandatory_children; no recursive expansion.
plan_auto_annotated_not_expanded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, auto, {1, 1}),
	{ok, #{mandatory_children := [], auto_rules := [{_RuleNode, Dep}]}} =
		graphdb_rules:plan_composition_firing(environment, Owner),
	?assertEqual(auto, maps:get(mode, Dep)).

%% {Min, unbounded} mandatory mints Min (here 1) — the old
%% unbounded_multiplicity_not_fireable error is retired.
plan_unbounded_mandatory_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _R} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, unbounded}),
	{ok, #{mandatory_children := Kids}} =
		graphdb_rules:plan_composition_firing(environment, Owner),
	?assertEqual(1, length(Kids)),
	[#{class := Bolt}] = Kids.

%% plan_abstract_mandatory_child_fails/1 — mandatory rule whose child_class is
%% abstract must fail planning.
plan_abstract_mandatory_child_fails(Config) ->
	{Owner, Abstract} = ?config(oa, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OA", Owner, Abstract, mandatory, {1, 1}),
	{error, {class_not_instantiable, Abstract}, #{culprit := _}} =
		graphdb_rules:plan_composition_firing(environment, Owner).

%% plan_cascade/1 — Owner→Bolt (mandatory/1), Bolt→Widget (mandatory/1).
%% Verifies the plan tree recurses: Owner's child is Bolt, Bolt's child is
%% Widget.
plan_cascade(Config) ->
	%% Owner mandates Bolt; Bolt mandates Widget
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BW", Bolt, Widget, mandatory, {1, 1}),
	{ok, #{mandatory_children :=
	        [#{class := Bolt, mandatory_children := [#{class := Widget}]}]}} =
		graphdb_rules:plan_composition_firing(environment, Owner).

%% plan_cycle_self_nest_zero_children/1 — a class with a rule pointing back to
%% itself (Folder→Folder) must produce zero mandatory_children for the root node
%% (on-path cycle cut at plan_mandatory level), not loop.
plan_cycle_self_nest_zero_children(Config) ->
	%% Folder mandates Folder
	Folder = ?config(folder, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "FF", Folder, Folder, mandatory, {1, 1}),
	{ok, #{mandatory_children := []}} =       %% zero-level cut
		graphdb_rules:plan_composition_firing(environment, Folder).

%% plan_cycle_a_b_a/1 — two-class cycle: A→B (mandatory/1), B→A (mandatory/1).
%% Root is A.  OnPath at B's plan_mandatory call is [B, A], so A is on-path →
%% cut returns {ok, Acc} (A absent from B's mandatory_children).
plan_cycle_a_b_a(Config) ->
	%% A mandates B; B mandates A  -> {A,B}, the closing A cut
	{A, B} = ?config(ab, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "AB", A, B, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BA", B, A, mandatory, {1, 1}),
	{ok, #{class := A, mandatory_children :=
	        [#{class := B, mandatory_children := []}]}} =
		graphdb_rules:plan_composition_firing(environment, A).

%% plan_project_scope_is_leaf/1 — project scope is always a leaf plan (no
%% rule lookup attempted).
plan_project_scope_is_leaf(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, #{class := Owner, mandatory_children := [], auto_rules := []}} =
		graphdb_rules:plan_composition_firing({project, p1}, Owner).


%%=============================================================================
%% Cache Audit Tests
%%=============================================================================
%% Rule creation writes instantiation + applies_to arcs.  This asserts the
%% "arcs authoritative; lists cached" invariant holds after a rule write.

verify_caches_passes_after_rule_creation(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "engine", Car, Eng, mandatory, {1, 1}),
	?assertEqual(ok, graphdb_mgr:verify_caches()).


%%-----------------------------------------------------------------------------
%% Group: conflict_resolution (F4 B5 default composition resolver)
%%-----------------------------------------------------------------------------

%%-----------------------------------------------------------------------------
%% Cross-level shadow: Car (nearest) and Vehicle (ancestor) both mandate Engine.
%% Resolved to ONE pair: nearest mode + nearest Min, greatest Max.
%%-----------------------------------------------------------------------------
b5_comp_cross_level_shadow(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
    {ok, Car}     = graphdb_class:create_class("Car", Vehicle),
    {ok, Engine}  = graphdb_class:create_class("Engine", 3),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CE", Car, Engine, mandatory, {1, 1}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "VE", Vehicle, Engine, mandatory, {1, 3}),
    {ok, [{_R, Dep}]} = resolve_comp(Car),
    ?assertEqual(mandatory, maps:get(mode, Dep)),
    ?assertEqual({1, 3}, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% Descendant shadow (B5-D1): Car mandates ElectricMotor (is-a Engine);
%% Vehicle mandates Engine.  ElectricMotor wins; Vehicle's Engine rule shadowed.
%%-----------------------------------------------------------------------------
b5_comp_descendant_shadow(_Config) ->
    {ok, Vehicle}  = graphdb_class:create_class("Vehicle", 3),
    {ok, Car}      = graphdb_class:create_class("Car", Vehicle),
    {ok, Engine}   = graphdb_class:create_class("Engine", 3),
    {ok, EMotor}   = graphdb_class:create_class("ElectricMotor", Engine),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CEM", Car, EMotor, mandatory, {1, 1}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
    {ok, [{R, _Dep}]} = resolve_comp(Car),
    ?assertEqual(EMotor, graphdb_rules:rule_child_class(R)).

%%-----------------------------------------------------------------------------
%% Additive: unrelated child classes both survive (two pairs).
%%-----------------------------------------------------------------------------
b5_comp_additive_unrelated(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
    {ok, Car}     = graphdb_class:create_class("Car", Vehicle),
    {ok, Engine}  = graphdb_class:create_class("Engine", 3),
    {ok, Radio}   = graphdb_class:create_class("Radio", 3),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CE", Car, Engine, mandatory, {1, 1}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "VR", Vehicle, Radio, mandatory, {1, 1}),
    {ok, Pairs} = resolve_comp(Car),
    ?assertEqual(2, length(Pairs)).

%%-----------------------------------------------------------------------------
%% Greatest-Max merge across 3 levels including unbounded -> unbounded dominates.
%%-----------------------------------------------------------------------------
b5_comp_max_merge_unbounded(_Config) ->
    {ok, A}   = graphdb_class:create_class("A", 3),
    {ok, B}   = graphdb_class:create_class("B", A),
    {ok, C}   = graphdb_class:create_class("C", B),
    {ok, Eng} = graphdb_class:create_class("Engine", 3),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CE", C, Eng, mandatory, {1, 1}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "BE", B, Eng, mandatory, {1, 2}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "AE", A, Eng, mandatory, {1, unbounded}),
    {ok, [{_R, Dep}]} = resolve_comp(C),
    ?assertEqual({1, unbounded}, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% Same-level mode-priority tie (B5-D2): two rules on Cell, both child=Nucleus,
%% one mandatory one propose.  mandatory wins; one pair survives.
%%-----------------------------------------------------------------------------
b5_comp_same_level_mode_priority(_Config) ->
    {ok, Cell}    = graphdb_class:create_class("Cell", 3),
    {ok, Nucleus} = graphdb_class:create_class("Nucleus", 3),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CN-prop", Cell, Nucleus, propose, {1, 1}),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "CN-mand", Cell, Nucleus, mandatory, {1, 1}),
    {ok, [{_R, Dep}]} = resolve_comp(Cell),
    ?assertEqual(mandatory, maps:get(mode, Dep)).


%%=============================================================================
%% Local test helpers
%%=============================================================================

%% resolve_comp(ClassNref) -> {ok, [{#node{}, Deploy}]}
%% Drives the default conflict resolver over the composition rules effective for
%% ClassNref, exactly as plan_node would.
resolve_comp(ClassNref) ->
    {ok, Effective} = graphdb_rules:effective_rules_for_class(environment,
                                                              ClassNref),
    Pairs = [P || {_Level, LvlPairs} <- Effective, P <- LvlPairs,
                  is_composition_pair(P)],
    Resolver = graphdb_rules:default_conflict_resolver(),
    {ok, Resolver(#{kind => composition, rules => Pairs, class_nref => ClassNref})}.

%% is_composition_pair({RuleNode, _Deploy}) -> boolean()
%% A pair is composition iff its rule node is a CompositionRule instance.
is_composition_pair({#node{classes = Classes}, _Deploy}) ->
    {ok, S} = graphdb_rules:seeded_nrefs(),
    lists:member(maps:get(composition_rule, S), Classes).

%% find_avp(AVPs, AttrNref) -> {ok, Value} | not_found
%% Searches an AVP list for an entry whose attribute key equals AttrNref;
%% returns {ok, Value} on the first match, not_found if absent.
find_avp(AVPs, A) ->
	case lists:search(fun(#{attribute := X}) -> X =:= A end, AVPs) of
		{value, #{value := V}} -> {ok, V};
		false                  -> not_found
	end.

%% make_class(Name) -> Nref
%% Creates a (non-abstract) domain class under ?NREF_CLASSES.
make_class(Name) ->
	{ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES),
	Nref.

%% make_abstract_class(Name) -> Nref
%% Creates an abstract class (instantiable=false marker) under
%% ?NREF_CLASSES.  An abstract class is born without a default template,
%% so it must be rejected as a rule owning class.
make_abstract_class(Name) ->
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	Marker = #{attribute => InstAttr, value => false},
	{ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES, [Marker]),
	Nref.

%% table_size(Tab) -> integer()
table_size(Tab) ->
	mnesia:table_info(Tab, size).

%% make_rel_char(Name, Recip) -> CharNref
%% Creates a reciprocal relationship-attribute pair and returns the forward
%% characterization nref (a valid, non-abstract connection-arc label).
make_rel_char(Name, Recip) ->
	{ok, {Fwd, _Rev}} =
		graphdb_attr:create_relationship_attribute_pair(Name, Recip, class),
	Fwd.

%% make_rel_pair(Name, Recip) -> {FwdNref, RevNref}
%% target_kind=instance: connection rules fire against instance arcs.  Both
%% the forward (characterization) and reverse (reciprocal) labels are returned.
make_rel_pair(Name, Recip) ->
	{ok, {Fwd, Rev}} =
		graphdb_attr:create_relationship_attribute_pair(Name, Recip, instance),
	{Fwd, Rev}.

%% level_nrefs(Levels) -> [integer()]
%% The ordered list of attaching-class nrefs in an effective_rules result.
level_nrefs(Levels) ->
	[L || {L, _Pairs} <- Levels].

%% pairs_at(LevelNref, Levels) -> [{#node{}, map()}]
%% The {RuleNode, Deployment} pairs grouped under LevelNref.
pairs_at(Level, Levels) ->
	{Level, Pairs} = lists:keyfind(Level, 1, Levels),
	Pairs.

%% rule_nrefs_at(LevelNref, Levels) -> [integer()]
%% The rule nrefs grouped under LevelNref.
rule_nrefs_at(Level, Levels) ->
	[N#node.nref || {N, _D} <- pairs_at(Level, Levels)].

%% attach_existing_rule(OwnerClass, RuleNref, Mode, Mult) -> ok
%% Writes a SECOND applies_to/applied_by connection arc pair from OwnerClass to
%% an already-existing rule node (rule reuse), stamped with OwnerClass's own
%% deployment.  Connection arcs are not part of the parents/classes caches, so
%% this does not disturb verify_caches/0.  Used by
%% shared_rule_node_across_ancestors to make one rule node reachable from two
%% ancestors.
attach_existing_rule(OwnerClass, RuleNref, Mode, Mult) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	AppliesTo = maps:get(applies_to, S),
	AppliedBy = maps:get(applied_by, S),
	ModeAttr  = maps:get(mode_attr, S),
	MultAttr  = maps:get(multiplicity_attr, S),
	{ok, DT}  = graphdb_class:default_template(OwnerClass),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Deploy = [#{attribute => ?ARC_TEMPLATE, value => DT},
			  #{attribute => ModeAttr, value => Mode},
			  #{attribute => MultAttr, value => Mult}],
	Fwd = #relationship{id = Id1, kind = connection, source_nref = OwnerClass,
		characterization = AppliesTo, target_nref = RuleNref,
		reciprocal = AppliedBy, avps = Deploy},
	Rev = #relationship{id = Id2, kind = connection, source_nref = RuleNref,
		characterization = AppliedBy, target_nref = OwnerClass,
		reciprocal = AppliesTo, avps = []},
	{atomic, ok} = mnesia:transaction(fun() ->
		ok = mnesia:write(relationships, Fwd, write),
		ok = mnesia:write(relationships, Rev, write)
	end),
	ok.

%% node_read2(Nref) -> {ok, #node{}} | not_found
node_read2(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[N] -> {ok, N};
		[]  -> not_found
	end.

%% read_arc(Source, Char, Target) -> #relationship{}
%% Returns the single arc from Source to Target with characterization Char.
read_arc(Source, Char, Target) ->
	Arcs = mnesia:dirty_index_read(relationships, Source,
								   #relationship.source_nref),
	[Arc] = [A || A <- Arcs,
			 A#relationship.characterization =:= Char,
			 A#relationship.target_nref =:= Target],
	Arc.

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
