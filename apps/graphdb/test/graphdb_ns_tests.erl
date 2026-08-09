-module(graphdb_ns_tests).
-include_lib("eunit/include/eunit.hrl").

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
