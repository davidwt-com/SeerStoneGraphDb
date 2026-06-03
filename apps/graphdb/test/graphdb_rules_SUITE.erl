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
	seeded_nrefs_returns_all_twelve/1,
	%% composition
	creates_composition_rule_minimal/1,
	creates_composition_rule_with_template/1,
	applies_to_arc_pair_written/1,
	instance_to_class_membership_written/1,
	avps_present_and_correct/1,
	%% connection
	creates_connection_rule_minimal/1,
	creates_connection_rule_with_template/1,
	instance_to_class_membership_to_connection_rule/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, seeding}, {group, composition}, {group, connection}].

groups() ->
	[
		{seeding, [], [
			seeds_rule_meta_ontology_idempotent,
			seeds_rule_literals_subgroup,
			seeds_literal_attributes_under_rule_literals,
			seeds_applies_to_pair,
			seeded_nrefs_returns_all_twelve
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
%% Local test helpers
%%=============================================================================

%% make_class(Name) -> Nref
%% Creates a (non-abstract) domain class under ?NREF_CLASSES.
make_class(Name) ->
	{ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES),
	Nref.

%% make_rel_char(Name, Recip) -> CharNref
%% Creates a reciprocal relationship-attribute pair and returns the forward
%% characterization nref (a valid, non-abstract connection-arc label).
make_rel_char(Name, Recip) ->
	{ok, {Fwd, _Rev}} =
		graphdb_attr:create_relationship_attribute_pair(Name, Recip, class),
	Fwd.

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
