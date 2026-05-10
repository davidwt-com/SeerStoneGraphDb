%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: EUnit tests for graphdb_bootstrap pure internal
%%				functions.  These tests do NOT require Mnesia or
%%				nref_server — they exercise only the term parsing,
%%				validation, and record-conversion logic.
%%---------------------------------------------------------------------
-module(graphdb_bootstrap_tests).

-include_lib("eunit/include/eunit.hrl").


%%=============================================================================
%% classify_terms/1 tests
%%=============================================================================

classify_terms_valid_test() ->
	Terms = [
		{nref_start, 100},
		{node, 1, category, {17, "Root"}, []},
		{node, 6, attribute, {18, "Names"}, []},
		{relationship, 1, 22, [], 21, 2, [], composition}
	],
	{NrefStart, Nodes, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(100, NrefStart),
	?assertEqual(2, length(Nodes)),
	?assertEqual(1, length(Rels)).

classify_terms_sorts_by_kind_test() ->
	Terms = [
		{nref_start, 100},
		{node, 6, attribute, {18, "Names"}, []},
		{node, 1, category, {17, "Root"}, []}
	],
	{_, Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	%% category should come before attribute regardless of file order
	[{node, 1, category, _, _}, {node, 6, attribute, _, _}] = Nodes.

classify_terms_preserves_relationship_order_test() ->
	Terms = [
		{nref_start, 100},
		{relationship, 1, 22, [], 21, 2, [], composition},
		{relationship, 1, 22, [], 21, 3, [], composition},
		{relationship, 2, 24, [], 23, 6, [], taxonomy}
	],
	{_, _, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(3, length(Rels)),
	%% File order preserved
	{relationship, 1, 22, [], 21, 2, [], composition} = lists:nth(1, Rels),
	{relationship, 1, 22, [], 21, 3, [], composition} = lists:nth(2, Rels),
	{relationship, 2, 24, [], 23, 6, [], taxonomy} = lists:nth(3, Rels).

classify_terms_missing_nref_start_test() ->
	Terms = [{node, 1, category, {17, "Root"}, []}],
	?assertThrow({error, missing_nref_start},
		graphdb_bootstrap:classify_terms(Terms)).

classify_terms_duplicate_nref_start_test() ->
	Terms = [{nref_start, 100}, {nref_start, 200}],
	?assertThrow({error, duplicate_nref_start},
		graphdb_bootstrap:classify_terms(Terms)).

classify_terms_invalid_nref_start_test() ->
	%% nref_start must be a positive integer
	Terms = [{nref_start, -5}],
	?assertThrow({error, {invalid_nref_start, -5}},
		graphdb_bootstrap:classify_terms(Terms)).

classify_terms_zero_nref_start_test() ->
	Terms = [{nref_start, 0}],
	?assertThrow({error, {invalid_nref_start, 0}},
		graphdb_bootstrap:classify_terms(Terms)).

classify_terms_unknown_term_test() ->
	Terms = [{nref_start, 100}, {bogus, stuff}],
	?assertThrow({error, {unknown_term, {bogus, stuff}}},
		graphdb_bootstrap:classify_terms(Terms)).

classify_terms_empty_test() ->
	?assertThrow({error, missing_nref_start},
		graphdb_bootstrap:classify_terms([])).

classify_terms_nref_start_only_test() ->
	{100, [], []} = graphdb_bootstrap:classify_terms([{nref_start, 100}]).

classify_terms_all_four_kinds_test() ->
	Terms = [
		{nref_start, 100},
		{node, 1, category, {17, "Root"}, []},
		{node, 6, attribute, {18, "Attr"}, []},
		{node, 50, class, {19, "Cls"}, []},
		{node, 60, instance, {20, "Inst"}, []}
	],
	{_, Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	Kinds = [Kind || {node, _, Kind, _, _} <- Nodes],
	?assertEqual([category, attribute, class, instance], Kinds).


%%=============================================================================
%% sort_nodes_by_kind/1 tests
%%=============================================================================

sort_nodes_by_kind_mixed_test() ->
	Nodes = [
		{node, 60, instance,  {20, "I"}, []},
		{node, 50, class,     {19, "C"}, []},
		{node, 1,  category,  {17, "R"}, []},
		{node, 6,  attribute, {18, "A"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	[category, attribute, class, instance] =
		[Kind || {node, _, Kind, _, _} <- Sorted].

sort_nodes_by_kind_already_sorted_test() ->
	Nodes = [
		{node, 1, category,  {17, "R"}, []},
		{node, 6, attribute, {18, "A"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	[category, attribute] =
		[Kind || {node, _, Kind, _, _} <- Sorted].

sort_nodes_by_kind_empty_test() ->
	?assertEqual([], graphdb_bootstrap:sort_nodes_by_kind([])).

sort_nodes_by_kind_preserves_order_within_kind_test() ->
	Nodes = [
		{node, 8, attribute, {18, "Relationships"}, []},
		{node, 6, attribute, {18, "Names"}, []},
		{node, 7, attribute, {18, "Literals"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	%% Stable sort: same-kind nodes stay in file order
	[8, 6, 7] = [Nref || {node, Nref, _, _, _} <- Sorted].


%%=============================================================================
%% kind_order/1 tests
%%=============================================================================

kind_order_category_first_test() ->
	?assert(graphdb_bootstrap:kind_order(category) <
		graphdb_bootstrap:kind_order(attribute)).

kind_order_attribute_before_class_test() ->
	?assert(graphdb_bootstrap:kind_order(attribute) <
		graphdb_bootstrap:kind_order(class)).

kind_order_class_before_instance_test() ->
	?assert(graphdb_bootstrap:kind_order(class) <
		graphdb_bootstrap:kind_order(instance)).

kind_order_instance_before_template_test() ->
	?assert(graphdb_bootstrap:kind_order(instance) <
		graphdb_bootstrap:kind_order(template)).

kind_order_values_test() ->
	?assertEqual(1, graphdb_bootstrap:kind_order(category)),
	?assertEqual(2, graphdb_bootstrap:kind_order(attribute)),
	?assertEqual(3, graphdb_bootstrap:kind_order(class)),
	?assertEqual(4, graphdb_bootstrap:kind_order(instance)),
	?assertEqual(5, graphdb_bootstrap:kind_order(template)).


%%=============================================================================
%% validate/2 tests
%%=============================================================================

validate_all_valid_test() ->
	Nodes = [
		{node, 1,  category,  {17, "Root"}, []},
		{node, 2,  category,  {17, "Attributes"}, []},
		{node, 6,  attribute, {18, "Names"}, []},
		{node, 99, instance,  {20, "Inst"}, []}
	],
	?assertEqual(ok, graphdb_bootstrap:validate(100, Nodes)).

validate_template_kind_test() ->
	Nodes = [{node, 50, template, {19, "default"}, []}],
	?assertEqual(ok, graphdb_bootstrap:validate(100, Nodes)).

validate_empty_nodes_test() ->
	?assertEqual(ok, graphdb_bootstrap:validate(100, [])).

validate_nref_at_floor_test() ->
	%% Nref equal to NrefStart is invalid (must be strictly less than)
	Nodes = [{node, 100, category, {17, "Root"}, []}],
	?assertThrow({error, {nref_not_below_floor, 100, 100}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_nref_above_floor_test() ->
	Nodes = [{node, 150, category, {17, "Root"}, []}],
	?assertThrow({error, {nref_not_below_floor, 150, 100}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_invalid_kind_test() ->
	Nodes = [{node, 1, bogus, {17, "Root"}, []}],
	?assertThrow({error, {invalid_kind, 1, bogus}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_negative_nref_test() ->
	Nodes = [{node, -1, category, {17, "Root"}, []}],
	?assertThrow({error, {invalid_nref, -1}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_zero_nref_test() ->
	Nodes = [{node, 0, category, {17, "Root"}, []}],
	?assertThrow({error, {invalid_nref, 0}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_stops_at_first_error_test() ->
	%% Second node has invalid kind; first is fine
	Nodes = [
		{node, 1, category, {17, "Root"}, []},
		{node, 2, bogus,    {17, "Bad"}, []}
	],
	?assertThrow({error, {invalid_kind, 2, bogus}},
		graphdb_bootstrap:validate(100, Nodes)).


%%=============================================================================
%% term_to_node/1 tests
%%=============================================================================

%% Record positions: {node, Nref, Kind, Parents, Classes, AVPs}
%%   pos 2=nref, 3=kind, 4=parents, 5=classes, 6=attribute_value_pairs
%% Bootstrap loader writes parents=[], classes=[]; rebuild_caches/0
%% populates them from the arcs after all rows are written.
term_to_node_category_test() ->
	Term = {node, 1, category, {17, "Root"}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual(1, element(2, Rec)),			%% nref
	?assertEqual(category, element(3, Rec)),	%% kind
	?assertEqual([], element(4, Rec)),			%% parents (filled by rebuild)
	?assertEqual([], element(5, Rec)),			%% classes
	?assertEqual([#{attribute => 17, value => "Root"}], element(6, Rec)).

term_to_node_attribute_test() ->
	Term = {node, 6, attribute, {18, "Names"}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual(6, element(2, Rec)),
	?assertEqual(attribute, element(3, Rec)),
	?assertEqual([], element(4, Rec)),			%% parents (filled by rebuild)
	?assertEqual([], element(5, Rec)),			%% classes
	?assertEqual([#{attribute => 18, value => "Names"}], element(6, Rec)).

term_to_node_with_extra_avps_test() ->
	Term = {node, 1, category, {17, "Root"}, [{99, "extra"}, {100, 42}]},
	Rec = graphdb_bootstrap:term_to_node(Term),
	Expected = [
		#{attribute => 17, value => "Root"},
		#{attribute => 99, value => "extra"},
		#{attribute => 100, value => 42}
	],
	?assertEqual(Expected, element(6, Rec)).

term_to_node_empty_name_test() ->
	Term = {node, 1, category, {17, ""}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual([#{attribute => 17, value => ""}], element(6, Rec)).


%%=============================================================================
%% expand_avps/1 tests
%%=============================================================================

expand_avps_empty_test() ->
	?assertEqual([], graphdb_bootstrap:expand_avps([])).

expand_avps_single_test() ->
	?assertEqual([#{attribute => 1, value => "x"}],
		graphdb_bootstrap:expand_avps([{1, "x"}])).

expand_avps_multiple_test() ->
	?assertEqual(
		[#{attribute => 1, value => "x"}, #{attribute => 2, value => 42}],
		graphdb_bootstrap:expand_avps([{1, "x"}, {2, 42}])).

expand_avps_preserves_order_test() ->
	Input = [{3, c}, {1, a}, {2, b}],
	Result = graphdb_bootstrap:expand_avps(Input),
	[3, 1, 2] = [maps:get(attribute, M) || M <- Result].
