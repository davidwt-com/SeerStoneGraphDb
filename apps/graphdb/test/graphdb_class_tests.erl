%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: EUnit tests for graphdb_class pure functions.
%%				Tests is_valid_parent_kind/1 and collect_qc_avps/1.
%%---------------------------------------------------------------------
-module(graphdb_class_tests).

-include_lib("eunit/include/eunit.hrl").


%%=============================================================================
%% is_valid_parent_kind/1 tests
%%=============================================================================

valid_parent_kind_category_test() ->
	?assert(graphdb_class:is_valid_parent_kind(category)).

valid_parent_kind_class_test() ->
	?assert(graphdb_class:is_valid_parent_kind(class)).

valid_parent_kind_attribute_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(attribute)).

valid_parent_kind_instance_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(instance)).

valid_parent_kind_atom_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(bogus)).

valid_parent_kind_integer_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(42)).


%%=============================================================================
%% collect_qc_avps/1 tests
%%=============================================================================

%% Fake #node{} records for testing — only attribute_value_pairs matters.
-record(node, {
	nref,
	kind,
	parents = [],
	classes = [],
	attribute_value_pairs
}).

collect_qc_avps_empty_nodes_test() ->
	?assertEqual([], graphdb_class:collect_qc_avps([])).

collect_qc_avps_single_node_no_avps_test() ->
	Node = #node{nref = 1, kind = class, attribute_value_pairs = []},
	?assertEqual([], graphdb_class:collect_qc_avps([Node])).

collect_qc_avps_single_node_one_avp_test() ->
	Node = #node{nref = 1, kind = class,
		attribute_value_pairs = [#{attribute => 18, value => undefined}]},
	?assertEqual([{18, undefined}], graphdb_class:collect_qc_avps([Node])).

collect_qc_avps_single_node_multiple_avps_test() ->
	%% Two QC attrs (17 and 18) — both appear; attr 19 would be filtered.
	Node = #node{nref = 1, kind = class,
		attribute_value_pairs = [
			#{attribute => 17, value => undefined},
			#{attribute => 18, value => undefined}
		]},
	?assertEqual([{17, undefined}, {18, undefined}],
		graphdb_class:collect_qc_avps([Node])).

collect_qc_avps_deduplication_first_wins_test() ->
	%% Two nodes: second has same AttrNref as first — first occurrence wins.
	Node1 = #node{nref = 1, kind = class,
		attribute_value_pairs = [#{attribute => 18, value => "bound"}]},
	Node2 = #node{nref = 2, kind = class,
		attribute_value_pairs = [#{attribute => 18, value => undefined}]},
	?assertEqual([{18, "bound"}],
		graphdb_class:collect_qc_avps([Node1, Node2])).

collect_qc_avps_multiple_nodes_no_overlap_test() ->
	Node1 = #node{nref = 1, kind = class,
		attribute_value_pairs = [#{attribute => 20, value => undefined}]},
	Node2 = #node{nref = 2, kind = class,
		attribute_value_pairs = [#{attribute => 17, value => undefined}]},
	?assertEqual([{20, undefined}, {17, undefined}],
		graphdb_class:collect_qc_avps([Node1, Node2])).

collect_qc_avps_filters_name_avp_test() ->
	%% Name AVP (attr=19) is filtered out; only QC attr 18 appears.
	Node = #node{nref = 1, kind = class,
		attribute_value_pairs = [
			#{attribute => 19, value => "Animal"},
			#{attribute => 18, value => undefined}
		]},
	?assertEqual([{18, undefined}],
		graphdb_class:collect_qc_avps([Node])).
