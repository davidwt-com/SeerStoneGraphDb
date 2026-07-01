-module(graphdb_ns_tests).
-include_lib("eunit/include/eunit.hrl").

namespace_of_environment_roles_test() ->
	[ ?assertEqual(environment, graphdb_ns:namespace_of(R))
	  || R <- [characterization, reciprocal, avp_attribute,
			   node_classes, taxonomy_parent] ].

namespace_of_project_roles_test() ->
	?assertEqual(project, graphdb_ns:namespace_of(compositional_parent)).

namespace_of_home_roles_test() ->
	[ ?assertEqual(home, graphdb_ns:namespace_of(R))
	  || R <- [node_nref, source_nref] ].

target_namespace_instance_is_project_test() ->
	?assertEqual(project, graphdb_ns:target_namespace(instance)).

target_namespace_others_are_environment_test() ->
	[ ?assertEqual(environment, graphdb_ns:target_namespace(K))
	  || K <- [category, attribute, class] ].

namespace_of_unknown_role_crashes_test() ->
	?assertError(function_clause, graphdb_ns:namespace_of(bogus_role)).
