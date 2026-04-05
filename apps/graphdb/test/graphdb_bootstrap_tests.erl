%%---------------------------------------------------------------------
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of
%% SeerStone, Inc.
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
		{node, 1, category, undefined, {17, "Root"}, []},
		{node, 6, attribute, 2, {18, "Names"}, []},
		{relationship, 1, 22, [], 21, 2, []}
	],
	{NrefStart, Nodes, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(100, NrefStart),
	?assertEqual(2, length(Nodes)),
	?assertEqual(1, length(Rels)).

classify_terms_sorts_by_kind_test() ->
	Terms = [
		{nref_start, 100},
		{node, 6, attribute, 2, {18, "Names"}, []},
		{node, 1, category, undefined, {17, "Root"}, []}
	],
	{_, Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	%% category should come before attribute regardless of file order
	[{node, 1, category, _, _, _}, {node, 6, attribute, _, _, _}] = Nodes.

classify_terms_preserves_relationship_order_test() ->
	Terms = [
		{nref_start, 100},
		{relationship, 1, 22, [], 21, 2, []},
		{relationship, 1, 22, [], 21, 3, []},
		{relationship, 2, 24, [], 23, 6, []}
	],
	{_, _, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(3, length(Rels)),
	%% File order preserved
	{relationship, 1, 22, [], 21, 2, []} = lists:nth(1, Rels),
	{relationship, 1, 22, [], 21, 3, []} = lists:nth(2, Rels),
	{relationship, 2, 24, [], 23, 6, []} = lists:nth(3, Rels).

classify_terms_missing_nref_start_test() ->
	Terms = [{node, 1, category, undefined, {17, "Root"}, []}],
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
		{node, 1, category, undefined, {17, "Root"}, []},
		{node, 6, attribute, 2, {18, "Attr"}, []},
		{node, 50, class, 3, {19, "Cls"}, []},
		{node, 60, instance, 50, {20, "Inst"}, []}
	],
	{_, Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	Kinds = [Kind || {node, _, Kind, _, _, _} <- Nodes],
	?assertEqual([category, attribute, class, instance], Kinds).


%%=============================================================================
%% sort_nodes_by_kind/1 tests
%%=============================================================================

sort_nodes_by_kind_mixed_test() ->
	Nodes = [
		{node, 60, instance, 50, {20, "I"}, []},
		{node, 50, class, 3, {19, "C"}, []},
		{node, 1, category, undefined, {17, "R"}, []},
		{node, 6, attribute, 2, {18, "A"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	[category, attribute, class, instance] =
		[Kind || {node, _, Kind, _, _, _} <- Sorted].

sort_nodes_by_kind_already_sorted_test() ->
	Nodes = [
		{node, 1, category, undefined, {17, "R"}, []},
		{node, 6, attribute, 2, {18, "A"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	[category, attribute] =
		[Kind || {node, _, Kind, _, _, _} <- Sorted].

sort_nodes_by_kind_empty_test() ->
	?assertEqual([], graphdb_bootstrap:sort_nodes_by_kind([])).

sort_nodes_by_kind_preserves_order_within_kind_test() ->
	Nodes = [
		{node, 8, attribute, 2, {18, "Relationships"}, []},
		{node, 6, attribute, 2, {18, "Names"}, []},
		{node, 7, attribute, 2, {18, "Literals"}, []}
	],
	Sorted = graphdb_bootstrap:sort_nodes_by_kind(Nodes),
	%% Stable sort: same-kind nodes stay in file order
	[8, 6, 7] = [Nref || {node, Nref, _, _, _, _} <- Sorted].


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

kind_order_values_test() ->
	?assertEqual(1, graphdb_bootstrap:kind_order(category)),
	?assertEqual(2, graphdb_bootstrap:kind_order(attribute)),
	?assertEqual(3, graphdb_bootstrap:kind_order(class)),
	?assertEqual(4, graphdb_bootstrap:kind_order(instance)).


%%=============================================================================
%% validate/2 tests
%%=============================================================================

validate_all_valid_test() ->
	Nodes = [
		{node, 1, category, undefined, {17, "Root"}, []},
		{node, 2, category, 1, {17, "Attributes"}, []},
		{node, 6, attribute, 2, {18, "Names"}, []},
		{node, 99, instance, 6, {20, "Inst"}, []}
	],
	?assertEqual(ok, graphdb_bootstrap:validate(100, Nodes)).

validate_empty_nodes_test() ->
	?assertEqual(ok, graphdb_bootstrap:validate(100, [])).

validate_nref_at_floor_test() ->
	%% Nref equal to NrefStart is invalid (must be strictly less than)
	Nodes = [{node, 100, category, undefined, {17, "Root"}, []}],
	?assertThrow({error, {nref_not_below_floor, 100, 100}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_nref_above_floor_test() ->
	Nodes = [{node, 150, category, undefined, {17, "Root"}, []}],
	?assertThrow({error, {nref_not_below_floor, 150, 100}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_invalid_kind_test() ->
	Nodes = [{node, 1, bogus, undefined, {17, "Root"}, []}],
	?assertThrow({error, {invalid_kind, 1, bogus}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_negative_nref_test() ->
	Nodes = [{node, -1, category, undefined, {17, "Root"}, []}],
	?assertThrow({error, {invalid_nref, -1}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_zero_nref_test() ->
	Nodes = [{node, 0, category, undefined, {17, "Root"}, []}],
	?assertThrow({error, {invalid_nref, 0}},
		graphdb_bootstrap:validate(100, Nodes)).

validate_stops_at_first_error_test() ->
	%% Second node has invalid kind; first is fine
	Nodes = [
		{node, 1, category, undefined, {17, "Root"}, []},
		{node, 2, bogus, 1, {17, "Bad"}, []}
	],
	?assertThrow({error, {invalid_kind, 2, bogus}},
		graphdb_bootstrap:validate(100, Nodes)).


%%=============================================================================
%% term_to_node/1 tests
%%=============================================================================

term_to_node_category_test() ->
	Term = {node, 1, category, undefined, {17, "Root"}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual(1, element(2, Rec)),			%% nref
	?assertEqual(category, element(3, Rec)),	%% kind
	?assertEqual(undefined, element(4, Rec)),	%% parent
	?assertEqual([#{attribute => 17, value => "Root"}], element(5, Rec)).

term_to_node_attribute_test() ->
	Term = {node, 6, attribute, 2, {18, "Names"}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual(6, element(2, Rec)),
	?assertEqual(attribute, element(3, Rec)),
	?assertEqual(2, element(4, Rec)),
	?assertEqual([#{attribute => 18, value => "Names"}], element(5, Rec)).

term_to_node_with_extra_avps_test() ->
	Term = {node, 1, category, undefined, {17, "Root"}, [{99, "extra"}, {100, 42}]},
	Rec = graphdb_bootstrap:term_to_node(Term),
	Expected = [
		#{attribute => 17, value => "Root"},
		#{attribute => 99, value => "extra"},
		#{attribute => 100, value => 42}
	],
	?assertEqual(Expected, element(5, Rec)).

term_to_node_empty_name_test() ->
	Term = {node, 1, category, undefined, {17, ""}, []},
	Rec = graphdb_bootstrap:term_to_node(Term),
	?assertEqual([#{attribute => 17, value => ""}], element(5, Rec)).


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
