-module(graphdb_ns_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-define(PROJECT, #{anchor => 42, nodes => nodes_42, rels => relationships_42, counters => counters_42}).

namespace_of_environment_roles_test() ->
	[ ?assertEqual(environment, graphdb_ns:namespace_of(Home, R))
	  || Home <- [environment, ?PROJECT],
	     R    <- [characterization, reciprocal, avp_attribute,
	              node_classes, taxonomy_parent] ].

namespace_of_home_relative_roles_test() ->
	[ ?assertEqual(Home, graphdb_ns:namespace_of(Home, R))
	  || Home <- [environment, ?PROJECT],
	     R    <- [compositional_parent, node_nref] ].

target_namespace_instance_is_home_test() ->
	[ ?assertEqual(Home, graphdb_ns:target_namespace(Home, instance))
	  || Home <- [environment, ?PROJECT] ].

target_namespace_others_are_environment_test() ->
	[ ?assertEqual(environment, graphdb_ns:target_namespace(Home, K))
	  || Home <- [environment, ?PROJECT],
	     K    <- [category, attribute, class] ].

namespace_of_unknown_role_crashes_test() ->
	?assertError(function_clause, graphdb_ns:namespace_of(environment, bogus_role)).

target_namespace_unknown_kind_crashes_test() ->
	?assertError(function_clause, graphdb_ns:target_namespace(environment, bogus_kind)).

node_table_environment_is_literal_test() ->
	?assertEqual(nodes, graphdb_ns:node_table(environment)).

node_table_project_is_its_own_table_test() ->
	?assertEqual(nodes_42, graphdb_ns:node_table(?PROJECT)).

rel_table_environment_is_literal_test() ->
	?assertEqual(relationships, graphdb_ns:rel_table(environment)).

rel_table_project_is_its_own_table_test() ->
	?assertEqual(relationships_42, graphdb_ns:rel_table(?PROJECT)).

%%---------------------------------------------------------------------
%% arc_target_namespace/3 -- the arc-row analogue of namespace_of/2.
%% Home is the store the arc row was READ from.
%%---------------------------------------------------------------------
arc_target_namespace_taxonomy_is_always_environment_test() ->
	%% Taxonomy is class/attribute refinement; projects hold only
	%% instances, so a taxonomy arc never targets a project node.
	[ ?assertEqual(environment,
	               graphdb_ns:arc_target_namespace(Home, taxonomy, C))
	  || Home <- [environment, ?PROJECT],
	     C    <- [?ARC_ATTR_PARENT, ?ARC_ATTR_CHILD, 9999] ].

arc_target_namespace_composition_is_home_relative_test() ->
	[ ?assertEqual(Home,
	               graphdb_ns:arc_target_namespace(Home, composition, C))
	  || Home <- [environment, ?PROJECT],
	     C    <- [?ARC_INST_PARENT, ?ARC_INST_CHILD, 9999] ].

arc_target_namespace_connection_is_home_relative_test() ->
	[ ?assertEqual(Home,
	               graphdb_ns:arc_target_namespace(Home, connection, 9999))
	  || Home <- [environment, ?PROJECT] ].

arc_target_namespace_membership_splits_on_characterization_test() ->
	%% The 29/30 pair is the one arc shape whose two directions
	%% deliberately live in different Homes: both rows sit in the
	%% PROJECT's table, but 29 targets an environment class and 30
	%% targets a project instance.
	?assertEqual(environment,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation,
	                                             ?ARC_INST_TO_CLASS)),
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation,
	                                             ?ARC_CLASS_TO_INST)).

arc_target_namespace_unknown_kind_defaults_to_home_test() ->
	%% Deliberately NOT a function_clause: this is reached from inside
	%% the graphdb_query singleton, where a crash would take the query
	%% server down for every session over one malformed row.
	?assertEqual(environment,
	             graphdb_ns:arc_target_namespace(environment, bogus_kind, 1)),
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, bogus_kind, 1)).

arc_target_namespace_unknown_instantiation_char_defaults_to_home_test() ->
	%% instantiation with a characterization outside the 29/30 pair is
	%% not a shape this codebase writes; fall through to the catch-all
	%% rather than crash.
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation, 9999)).
