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
%% #relationship{} record is exercised by the composition group
%% (read_arc/3) and later F4 Phase A tasks.
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
	%% seeding
	seeds_rule_meta_ontology_idempotent/1,
	seeds_rule_literals_subgroup/1,
	seeds_literal_attributes_under_rule_literals/1,
	seeds_applies_to_pair/1,
	seeded_nrefs_returns_all_thirteen/1,
	name_pattern_is_seeded/1,
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
	%% validation
	class_not_found_rejected/1,
	not_a_class_rejected/1,
	abstract_owning_class_rejected/1,
	referenced_class_not_found_rejected/1,
	referenced_not_a_class_rejected/1,
	characterization_not_found_rejected/1,
	not_a_relationship_attribute_rejected/1,
	template_not_found_rejected/1,
	not_a_template_rejected/1,
	invalid_mode_rejected/1,
	invalid_multiplicity_rejected/1,
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
	%% effective (B1 taxonomy walk)
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
	 {group, complex_scenarios}, {group, effective}, {group, cache_audit}].

groups() ->
	[
		{seeding, [], [
			seeds_rule_meta_ontology_idempotent,
			seeds_rule_literals_subgroup,
			seeds_literal_attributes_under_rule_literals,
			seeds_applies_to_pair,
			seeded_nrefs_returns_all_thirteen,
			name_pattern_is_seeded
		]},
		{composition, [], [
			creates_composition_rule_minimal,
			creates_composition_rule_with_template,
			applies_to_arc_pair_written,
			instance_to_class_membership_written,
			avps_present_and_correct
		]},
		{connection, [], [
			creates_connection_rule_minimal,
			creates_connection_rule_with_template,
			instance_to_class_membership_to_connection_rule
		]},
		{validation, [], [
			class_not_found_rejected,
			not_a_class_rejected,
			abstract_owning_class_rejected,
			referenced_class_not_found_rejected,
			referenced_not_a_class_rejected,
			characterization_not_found_rejected,
			not_a_relationship_attribute_rejected,
			template_not_found_rejected,
			not_a_template_rejected,
			invalid_mode_rejected,
			invalid_multiplicity_rejected,
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
			non_class_nref_empty
		]},
		{cache_audit, [], [
			verify_caches_passes_after_rule_creation
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

seeded_nrefs_returns_all_thirteen(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Expected = [rule, composition_rule, connection_rule,
				applies_to, applied_by, rule_literals_group,
				child_class_nref_attr, target_class_nref_attr,
				template_nref_attr, characterization_nref_attr,
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


%%=============================================================================
%% Composition Tests
%%=============================================================================

creates_composition_rule_minimal(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, 1),
	?assert(is_integer(RuleNref)),
	{ok, #node{kind = instance, classes = Classes}} = node_read2(RuleNref),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	?assertEqual([maps:get(composition_rule, S)], Classes).

creates_composition_rule_with_template(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Wheel"),
	{ok, DT} = graphdb_class:default_template(Parent),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-wheel", Parent, Child, auto, 4, DT),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	TemplateAttr = maps:get(template_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

applies_to_arc_pair_written(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, 1),
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
	?assert(lists:member(#{attribute => MultAttr, value => 1}, FAVPs)).

instance_to_class_membership_written(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	{ok, RuleNref} = graphdb_rules:create_composition_rule(
		environment, "car-has-engine", Parent, Child, mandatory, 1),
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
		environment, "car-has-engine", Parent, Child, mandatory, 1),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	ChildAttr = maps:get(child_class_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => ?NAME_ATTR_INSTANCE,
						   value => "car-has-engine"}, AVPs)),
	?assert(lists:member(#{attribute => ChildAttr, value => Child}, AVPs)),
	%% no deployment AVPs leaked onto the node
	ModeAttr = maps:get(mode_attr, S),
	?assertNot(lists:any(fun(#{attribute := A}) -> A =:= ModeAttr end, AVPs)).


%%=============================================================================
%% Connection Tests
%%=============================================================================

creates_connection_rule_minimal(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Target,
		mandatory, 1),
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
	Char   = make_rel_char("placed_by", "placed"),
	{ok, DT} = graphdb_class:default_template(Source),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Target,
		propose, unbounded, DT),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	TemplateAttr = maps:get(template_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

instance_to_class_membership_to_connection_rule(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by-customer", Source, Char, Target,
		mandatory, 1),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Conn = maps:get(connection_rule, S),
	I2C = read_arc(RuleNref, ?ARC_INST_TO_CLASS, Conn),
	?assertEqual(instantiation, I2C#relationship.kind).


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
			environment, "x", 999999, Child, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

not_a_class_rejected(_Config) ->
	Child = make_class("Engine"),
	%% nref 6 (Names) is an attribute, not a class
	Before = table_size(nodes),
	?assertEqual({error, not_a_class},
		graphdb_rules:create_composition_rule(
			environment, "x", ?NREF_NAMES, Child, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

abstract_owning_class_rejected(_Config) ->
	Abstract = make_abstract_class("AbstractCar"),
	Child    = make_class("Engine"),
	Before   = table_size(nodes),
	?assertEqual({error, owning_class_has_no_default_template},
		graphdb_rules:create_composition_rule(
			environment, "x", Abstract, Child, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

referenced_class_not_found_rejected(_Config) ->
	Parent = make_class("Car"),
	Before = table_size(nodes),
	?assertEqual({error, referenced_class_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, 999999, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

referenced_not_a_class_rejected(_Config) ->
	Parent = make_class("Car"),
	Before = table_size(nodes),
	?assertEqual({error, referenced_not_a_class},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, ?NREF_NAMES, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

characterization_not_found_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Before = table_size(nodes),
	?assertEqual({error, characterization_not_found},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, 999999, Target, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

not_a_relationship_attribute_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	%% a literal attribute, not a relationship attribute
	{ok, Lit} = graphdb_attr:create_literal_attribute("weight", integer),
	Before = table_size(nodes),
	?assertEqual({error, not_a_relationship_attribute},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, Lit, Target, mandatory, 1)),
	?assertEqual(Before, table_size(nodes)).

template_not_found_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, template_not_found},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, 1, 999999)),
	?assertEqual(Before, table_size(nodes)).

not_a_template_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	%% Child is a class, not a template
	Before = table_size(nodes),
	?assertEqual({error, not_a_template},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, mandatory, 1, Child)),
	?assertEqual(Before, table_size(nodes)).

invalid_mode_rejected(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Before = table_size(nodes),
	?assertEqual({error, invalid_mode},
		graphdb_rules:create_composition_rule(
			environment, "x", Parent, Child, bogus, 1)),
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
			environment, "x", Parent, Child, mandatory, 1, 999999)),
	?assertEqual(Before, table_size(nodes)).


%%=============================================================================
%% Retrieval Tests
%%=============================================================================

rules_for_class_returns_all_kinds(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	Char  = make_rel_char("made_by", "makes"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
	{ok, R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Maker, mandatory, 1),
	{ok, Rules} = graphdb_rules:rules_for_class(environment, Car),
	Nrefs = [N#node.nref || N <- Rules],
	?assertEqual(lists:sort([R1, R2]), lists:sort(Nrefs)).

composition_rules_for_class_filters_by_kind(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	Char  = make_rel_char("made_by", "makes"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
	{ok, _R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Maker, mandatory, 1),
	{ok, Comp} = graphdb_rules:composition_rules_for_class(environment, Car),
	?assertEqual([R1], [N#node.nref || N <- Comp]).

connection_rules_for_class_filters_by_kind(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	Char  = make_rel_char("made_by", "makes"),
	{ok, _R1} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
	{ok, R2} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Maker, mandatory, 1),
	{ok, Conn} = graphdb_rules:connection_rules_for_class(environment, Car),
	?assertEqual([R2], [N#node.nref || N <- Conn]).

get_rule_returns_full_record(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
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
		environment, "car-engine", Car, Eng, mandatory, 1),
	{ok, R2} = graphdb_rules:create_composition_rule(
		environment, "bike-wheel", Bike, Whl, mandatory, 2),
	{ok, All} = graphdb_rules:list_rules(environment),
	Nrefs = [N#node.nref || N <- All],
	?assert(lists:member(R1, Nrefs)),
	?assert(lists:member(R2, Nrefs)).


%%=============================================================================
%% Scope Tests
%%=============================================================================
%% Phase A supports environment-scoped rules only.  The {project, _} branches
%% (added across Tasks 2-5) lock the contract: create is rejected, every
%% retrieval returns empty / not_found.

project_scope_rejected_on_create(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	?assertEqual({error, project_rules_not_yet_supported},
		graphdb_rules:create_composition_rule(
			{project, 1}, "x", Parent, Child, mandatory, 1)),
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	?assertEqual({error, project_rules_not_yet_supported},
		graphdb_rules:create_connection_rule(
			{project, 1}, "x", Source, Char, Target, mandatory, 1)).

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
%% exercise the create/retrieve paths in combination and document Phase A
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
	MadeBy = make_rel_char("made_by", "makes"),
	SoldBy = make_rel_char("sold_by", "sells"),
	{ok, DT} = graphdb_class:default_template(Car),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "engine", Car, Eng, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "wheels", Car, Whl, auto, 4, DT),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "sunroof", Car, Sun, propose, 1),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, MadeBy, Maker, mandatory, 1, DT),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "sold-by", Car, SoldBy, Deal, propose, unbounded),
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

%% Phase A retrieval is direct-attachment only: a rule on a superclass is NOT
%% returned for a subclass.  Documents that taxonomy-walking retrieval is
%% Phase B (effective_rules_for_class/2).
rule_isolation_across_class_taxonomy(_Config) ->
	Vehicle = make_class("Vehicle"),
	{ok, Car} = graphdb_class:create_class("Car", Vehicle),
	{ok, Sports} = graphdb_class:create_class("SportsCar", Car),
	Eng   = make_class("Engine"),
	Wheel = make_class("SteeringWheel"),
	Spoil = make_class("Spoiler"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "v-engine", Vehicle, Eng, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, 1),
	{ok, RV} = graphdb_rules:rules_for_class(environment, Vehicle),
	{ok, RC} = graphdb_rules:rules_for_class(environment, Car),
	{ok, RS} = graphdb_rules:rules_for_class(environment, Sports),
	?assertEqual(1, length(RV)),
	?assertEqual(1, length(RC)),
	?assertEqual(1, length(RS)).

%% Two composition rules with the same child class but different modes are
%% both accepted (distinct nrefs).  Documents that Phase A makes no
%% conflict-resolution commitment.
duplicate_child_class_with_different_modes(_Config) ->
	Cell = make_class("Cell"),
	Nuc  = make_class("Nucleus"),
	{ok, R1} = graphdb_rules:create_composition_rule(
		environment, "nuc-mandatory", Cell, Nuc, mandatory, 1),
	{ok, R2} = graphdb_rules:create_composition_rule(
		environment, "nuc-propose", Cell, Nuc, propose, 1),
	?assertNotEqual(R1, R2),
	{ok, Rules} = graphdb_rules:composition_rules_for_class(environment, Cell),
	?assertEqual(2, length(Rules)).


%%=============================================================================
%% Effective Rules Tests (B1 -- taxonomy walk)
%%=============================================================================
%% effective_rules_for_class/2 gathers rules from the class AND its taxonomy
%% ancestors, nearest-first, grouped by attaching class, each paired with that
%% attachment's deployment map.  It resolves nothing -- every level survives.

self_only_no_ancestors(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
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
		environment, "v-engine", Vehicle, Eng, mandatory, 1),
	{ok, RC} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, 1),
	{ok, RS} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, 1),
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
		environment, "comp-winding", Top, Wid, mandatory, 1),
	{ok, RB} = graphdb_rules:create_composition_rule(
		environment, "alt-casing", Bot, Cas, auto, 1),
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
	%% BOTH (F4 D12 reuse).  It must appear once per attaching ancestor, each
	%% occurrence carrying that ancestor's own deployment.
	A = make_class("Insurable"),
	B = make_class("Taxable"),
	{ok, Bot} = graphdb_class:create_class("Vehicle", A),
	ok = graphdb_class:add_superclass(Bot, B),
	Doc = make_class("Document"),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "needs-document", A, Doc, mandatory, 1),
	ok = attach_existing_rule(B, R, mandatory, 3),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Bot),
	?assertEqual([A, B], level_nrefs(Levels)),
	?assertMatch([{#node{nref = R}, #{multiplicity := 1}}], pairs_at(A, Levels)),
	?assertMatch([{#node{nref = R}, #{multiplicity := 3}}], pairs_at(B, Levels)).

deployment_avps_surfaced(_Config) ->
	Car = make_class("Car"),
	Whl = make_class("Wheel"),
	{ok, DT} = graphdb_class:default_template(Car),
	{ok, _R} = graphdb_rules:create_composition_rule(
		environment, "wheels", Car, Whl, auto, 4, DT),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	[{_RuleNode, Deploy}] = pairs_at(Car, Levels),
	?assertEqual(auto, maps:get(mode, Deploy)),
	?assertEqual(4, maps:get(multiplicity, Deploy)),
	?assertEqual(DT, maps:get(template, Deploy)).

additive_parent_and_child(_Config) ->
	%% Parent mandates a wheel-group (mult 1); subclass adds more (mult 4) for
	%% the SAME child class.  B1 drops nothing -- both survive, each with its
	%% own deployment.  The firing engine (B2/B5) decides additive-vs-shadow.
	Vehicle = make_class("Vehicle"),
	{ok, Car} = graphdb_class:create_class("Car", Vehicle),
	Wheel = make_class("Wheel"),
	{ok, RV} = graphdb_rules:create_composition_rule(
		environment, "v-wheel", Vehicle, Wheel, mandatory, 1),
	{ok, RC} = graphdb_rules:create_composition_rule(
		environment, "c-wheel", Car, Wheel, mandatory, 4),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	?assertEqual([Car, Vehicle], level_nrefs(Levels)),
	?assertEqual([RC], rule_nrefs_at(Car, Levels)),
	?assertEqual([RV], rule_nrefs_at(Vehicle, Levels)),
	[{_, DC}] = pairs_at(Car, Levels),
	[{_, DV}] = pairs_at(Vehicle, Levels),
	?assertEqual(4, maps:get(multiplicity, DC)),
	?assertEqual(1, maps:get(multiplicity, DV)).

empty_levels_skipped(_Config) ->
	Vehicle = make_class("Vehicle"),
	{ok, Car}    = graphdb_class:create_class("Car", Vehicle),
	{ok, Sports} = graphdb_class:create_class("SportsCar", Car),
	Spoil = make_class("Spoiler"),
	Eng   = make_class("Engine"),
	%% Rules on Sports and Vehicle only; the middle level (Car) has none.
	{ok, RS} = graphdb_rules:create_composition_rule(
		environment, "s-spoiler", Sports, Spoil, auto, 1),
	{ok, RV} = graphdb_rules:create_composition_rule(
		environment, "v-engine", Vehicle, Eng, mandatory, 1),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Sports),
	%% Car omitted entirely; nearest-first order preserved.
	?assertEqual([Sports, Vehicle], level_nrefs(Levels)),
	?assertEqual([RS], rule_nrefs_at(Sports, Levels)),
	?assertEqual([RV], rule_nrefs_at(Vehicle, Levels)).

mixed_kinds_returned(_Config) ->
	Car   = make_class("Car"),
	Eng   = make_class("Engine"),
	Maker = make_class("Manufacturer"),
	Char  = make_rel_char("made_by", "makes"),
	{ok, RComp} = graphdb_rules:create_composition_rule(
		environment, "has-engine", Car, Eng, mandatory, 1),
	{ok, RConn} = graphdb_rules:create_connection_rule(
		environment, "made-by", Car, Char, Maker, mandatory, 1),
	{ok, Levels} = graphdb_rules:effective_rules_for_class(environment, Car),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Comp = maps:get(composition_rule, S),
	Conn = maps:get(connection_rule, S),
	Pairs = pairs_at(Car, Levels),
	%% B1-D4 consumer pattern: inline kind filter over the gathered pairs.
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


%%=============================================================================
%% Cache Audit Tests
%%=============================================================================
%% Rule creation writes instantiation + applies_to arcs.  This asserts the
%% "arcs authoritative; lists cached" invariant holds after a rule write.

verify_caches_passes_after_rule_creation(_Config) ->
	Car = make_class("Car"),
	Eng = make_class("Engine"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "engine", Car, Eng, mandatory, 1),
	?assertEqual(ok, graphdb_mgr:verify_caches()).


%%=============================================================================
%% Local test helpers
%%=============================================================================

%% make_class(Name) -> Nref
%% Creates a (non-abstract) domain class under ?NREF_CLASSES.
make_class(Name) ->
	{ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES),
	Nref.

%% make_abstract_class(Name) -> Nref
%% Creates an abstract class (L9 instantiable=false marker) under
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
%% an already-existing rule node (F4 D12 reuse), stamped with OwnerClass's own
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
