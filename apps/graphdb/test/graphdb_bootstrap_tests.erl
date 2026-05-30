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
		{node, 1, category, {17, "Root"}, []},
		{node, 6, attribute, {18, "Names"}, []},
		{relationship, 1, 22, [], 21, 2, [], composition}
	],
	{Nodes, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(2, length(Nodes)),
	?assertEqual(1, length(Rels)).

classify_terms_sorts_by_kind_test() ->
	Terms = [
		{node, 6, attribute, {18, "Names"}, []},
		{node, 1, category, {17, "Root"}, []}
	],
	{Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	%% category should come before attribute regardless of file order
	[{node, 1, category, _, _}, {node, 6, attribute, _, _}] = Nodes.

classify_terms_preserves_relationship_order_test() ->
	Terms = [
		{relationship, 1, 22, [], 21, 2, [], composition},
		{relationship, 1, 22, [], 21, 3, [], composition},
		{relationship, 2, 24, [], 23, 6, [], taxonomy}
	],
	{_, Rels} = graphdb_bootstrap:classify_terms(Terms),
	?assertEqual(3, length(Rels)),
	%% File order preserved
	{relationship, 1, 22, [], 21, 2, [], composition} = lists:nth(1, Rels),
	{relationship, 1, 22, [], 21, 3, [], composition} = lists:nth(2, Rels),
	{relationship, 2, 24, [], 23, 6, [], taxonomy} = lists:nth(3, Rels).

classify_terms_empty_returns_empty_test() ->
	?assertEqual({[], []}, graphdb_bootstrap:classify_terms([])).

classify_terms_unknown_term_test() ->
	?assertThrow({error, {unknown_term, {bogus, stuff}}},
		graphdb_bootstrap:classify_terms([{bogus, stuff}])).

classify_terms_all_four_kinds_test() ->
	Terms = [
		{node, 1, category, {17, "Root"}, []},
		{node, 6, attribute, {18, "Attr"}, []},
		{node, 50, class, {19, "Cls"}, []},
		{node, 60, instance, {20, "Inst"}, []}
	],
	{Nodes, _} = graphdb_bootstrap:classify_terms(Terms),
	Kinds = [Kind || {node, _, Kind, _, _} <- Nodes],
	?assertEqual([category, attribute, class, instance], Kinds).


%%=============================================================================
%% build_symbol_table/4 tests
%%=============================================================================

build_symbol_table_assigns_sequential_test() ->
	%% Two labels assigned 10001, 10002 in usort order
	Nodes = [{node, lang_human, class,     {19, "Human Language"}, []},
	         {node, lang_code,  attribute, {18, "lang_code"},      []}],
	Map = graphdb_bootstrap:build_symbol_table(Nodes, [], 10001, 1000000),
	?assertEqual(10001, maps:get(lang_code,  Map)),
	?assertEqual(10002, maps:get(lang_human, Map)).

build_symbol_table_empty_test() ->
	?assertEqual(#{},
		graphdb_bootstrap:build_symbol_table([], [], 10001, 1000000)).

build_symbol_table_throws_when_would_cross_nref_start_test() ->
	%% NrefStart of 10002 only leaves room for one label
	Nodes = [{node, foo, attribute, {18, "F"}, []},
	         {node, bar, attribute, {18, "B"}, []}],
	?assertThrow({error, {labels_exceeded_nref_start, _, _, _}},
		graphdb_bootstrap:build_symbol_table(Nodes, [], 10001, 10002)).


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


%%=============================================================================
%% validate/2 — atom label extension
%%=============================================================================

validate_atom_label_allowed_test() ->
	%% Atom labels are valid pre-resolution nrefs; must not throw
	Nodes = [{node, my_label, attribute, {18, "Foo"}, []}],
	?assertEqual(ok, graphdb_bootstrap:validate(100, Nodes)).


%%=============================================================================
%% collect_labels/2 tests
%%=============================================================================

collect_labels_empty_test() ->
	?assertEqual([], graphdb_bootstrap:collect_labels([], [])).

collect_labels_node_nref_label_test() ->
	Nodes = [{node, foo, attribute, {18, "Foo"}, []}],
	?assertEqual([foo], graphdb_bootstrap:collect_labels(Nodes, [])).

collect_labels_avp_key_label_test() ->
	Nodes = [{node, 1, instance, {20, "Inst"}, [{my_attr, some_value}]}],
	?assertEqual([my_attr], graphdb_bootstrap:collect_labels(Nodes, [])).

collect_labels_rel_endpoint_labels_test() ->
	Rels = [{relationship, foo, 29, [], 30, bar, [], instantiation}],
	?assertEqual([bar, foo], graphdb_bootstrap:collect_labels([], Rels)).

collect_labels_deduplicates_test() ->
	%% lang_code appears as node nref AND as avp key — should appear once
	Nodes = [{node, foo, attribute, {18, "Foo"}, [{foo, 42}]}],
	?assertEqual([foo], graphdb_bootstrap:collect_labels(Nodes, [])).

collect_labels_ignores_integer_nrefs_test() ->
	Nodes = [{node, 1, category, {17, "Root"}, []}],
	Rels = [{relationship, 1, 22, [], 21, 2, [], composition}],
	?assertEqual([], graphdb_bootstrap:collect_labels(Nodes, Rels)).

collect_labels_sorted_test() ->
	%% Result is always sorted regardless of input order
	Nodes = [{node, zzz, attribute, {18, "Z"}, []},
	         {node, aaa, attribute, {18, "A"}, []}],
	?assertEqual([aaa, zzz], graphdb_bootstrap:collect_labels(Nodes, [])).


%%=============================================================================
%% resolve_nref/2 tests
%%=============================================================================

resolve_nref_integer_passthrough_test() ->
	?assertEqual(42, graphdb_bootstrap:resolve_nref(42, #{})).

resolve_nref_label_found_test() ->
	SymTable = #{foo => 99},
	?assertEqual(99, graphdb_bootstrap:resolve_nref(foo, SymTable)).

resolve_nref_label_not_found_test() ->
	?assertThrow({error, {undefined_label, bar}},
		graphdb_bootstrap:resolve_nref(bar, #{})).


%%=============================================================================
%% resolve_node/2 tests
%%=============================================================================

resolve_node_integer_nref_unchanged_test() ->
	Node = {node, 5, category, {17, "Root"}, []},
	?assertEqual({node, 5, category, {17, "Root"}, []},
		graphdb_bootstrap:resolve_node(Node, #{})).

resolve_node_label_nref_resolved_test() ->
	Node = {node, foo, attribute, {18, "Foo"}, []},
	SymTable = #{foo => 100},
	?assertEqual({node, 100, attribute, {18, "Foo"}, []},
		graphdb_bootstrap:resolve_node(Node, SymTable)).

resolve_node_avp_key_label_resolved_test() ->
	Node = {node, 1, instance, {20, "Inst"}, [{my_attr, hello}]},
	SymTable = #{my_attr => 200},
	?assertEqual({node, 1, instance, {20, "Inst"}, [{200, hello}]},
		graphdb_bootstrap:resolve_node(Node, SymTable)).

resolve_node_both_nref_and_avp_label_test() ->
	Node = {node, x, attribute, {18, "X"}, [{x, val}]},
	SymTable = #{x => 300},
	?assertEqual({node, 300, attribute, {18, "X"}, [{300, val}]},
		graphdb_bootstrap:resolve_node(Node, SymTable)).


%%=============================================================================
%% resolve_rel/2 tests
%%=============================================================================

resolve_rel_no_labels_test() ->
	Rel = {relationship, 1, 22, [], 21, 2, [], composition},
	?assertEqual({relationship, 1, 22, [], 21, 2, [], composition},
		graphdb_bootstrap:resolve_rel(Rel, #{})).

resolve_rel_endpoint_labels_resolved_test() ->
	Rel = {relationship, foo, 29, [], 30, bar, [], instantiation},
	SymTable = #{foo => 100, bar => 200},
	?assertEqual({relationship, 100, 29, [], 30, 200, [], instantiation},
		graphdb_bootstrap:resolve_rel(Rel, SymTable)).

resolve_rel_avp_key_resolved_test() ->
	Rel = {relationship, 1, 22, [{my_key, 1}], 21, 2, [{other_key, 2}], composition},
	SymTable = #{my_key => 50, other_key => 60},
	?assertEqual({relationship, 1, 22, [{50, 1}], 21, 2, [{60, 2}], composition},
		graphdb_bootstrap:resolve_rel(Rel, SymTable)).


%%=============================================================================
%% apply_symbol_table/3 tests
%%=============================================================================

apply_symbol_table_resolves_all_test() ->
	Nodes = [{node, foo, attribute, {18, "Foo"}, []}],
	Rels = [{relationship, 1, 24, [], 23, foo, [], taxonomy}],
	SymTable = #{foo => 300},
	{ResNodes, ResRels} = graphdb_bootstrap:apply_symbol_table(Nodes, Rels, SymTable),
	?assertEqual([{node, 300, attribute, {18, "Foo"}, []}], ResNodes),
	?assertEqual([{relationship, 1, 24, [], 23, 300, [], taxonomy}], ResRels).

apply_symbol_table_empty_test() ->
	{[], []} = graphdb_bootstrap:apply_symbol_table([], [], #{}).


%%=============================================================================
%% validate_no_unresolved_labels/2 tests
%%=============================================================================

validate_no_unresolved_labels_all_integers_test() ->
	Nodes = [{node, 1, category, {17, "Root"}, []}],
	Rels = [{relationship, 1, 22, [], 21, 2, [], composition}],
	?assertEqual(ok,
		graphdb_bootstrap:validate_no_unresolved_labels(Nodes, Rels)).

validate_no_unresolved_labels_empty_test() ->
	?assertEqual(ok, graphdb_bootstrap:validate_no_unresolved_labels([], [])).

validate_no_unresolved_labels_unresolved_node_nref_test() ->
	Nodes = [{node, unresolved, category, {17, "Root"}, []}],
	?assertThrow({error, {unresolved_label, unresolved}},
		graphdb_bootstrap:validate_no_unresolved_labels(Nodes, [])).

validate_no_unresolved_labels_unresolved_avp_key_test() ->
	Nodes = [{node, 1, instance, {20, "I"}, [{dangling_attr, val}]}],
	?assertThrow({error, {unresolved_label, dangling_attr}},
		graphdb_bootstrap:validate_no_unresolved_labels(Nodes, [])).

validate_no_unresolved_labels_unresolved_rel_source_test() ->
	Rels = [{relationship, dangling, 22, [], 21, 2, [], composition}],
	?assertThrow({error, {unresolved_label, dangling}},
		graphdb_bootstrap:validate_no_unresolved_labels([], Rels)).

validate_no_unresolved_labels_unresolved_rel_target_test() ->
	Rels = [{relationship, 1, 22, [], 21, dangling, [], composition}],
	?assertThrow({error, {unresolved_label, dangling}},
		graphdb_bootstrap:validate_no_unresolved_labels([], Rels)).
