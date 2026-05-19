%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: Common Test integration suite for graphdb_class.
%%				Each test case gets its own isolated temp directory
%%				with a fresh Mnesia database and nref allocator.
%%				graphdb_mgr is started first to load the bootstrap
%%				scaffold; graphdb_attr is started for seeded attributes;
%%				graphdb_class is then started and its API exercised.
%%---------------------------------------------------------------------
-module(graphdb_class_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb internal records)
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
	%% Creation
	create_class_top_level/1,
	create_class_subclass/1,
	create_class_rejects_bad_parent_kind/1,
	create_class_rejects_missing_parent/1,
	create_class_writes_compositional_arcs/1,
	create_class_auto_creates_default_template/1,
	%% Templates
	add_template_basic/1,
	add_template_rejects_duplicate_name/1,
	add_template_rejects_non_class/1,
	get_template_returns_node/1,
	get_template_rejects_non_template/1,
	templates_for_class_lists_all/1,
	default_template_returns_default/1,
	default_template_not_found_after_delete/1,
	class_in_ancestry_self/1,
	class_in_ancestry_ancestor/1,
	class_in_ancestry_unrelated/1,
	%% Qualifying characteristics
	add_qc_basic/1,
	add_qc_idempotent/1,
	add_qc_rejects_non_class/1,
	add_qc_rejects_non_attribute/1,
	%% Lookups
	get_class_returns_node/1,
	get_class_not_found/1,
	get_class_rejects_non_class/1,
	%% Hierarchy
	subclasses_returns_children/1,
	subclasses_empty_for_leaf/1,
	ancestors_returns_chain/1,
	ancestors_empty_for_top_level/1,
	%% Multi-inheritance (H3)
	add_superclass_basic/1,
	add_superclass_writes_taxonomy_arcs/1,
	add_superclass_idempotent/1,
	add_superclass_rejects_self_reference/1,
	add_superclass_rejects_non_class_subject/1,
	add_superclass_rejects_non_class_target/1,
	ancestors_walks_multi_parent_dag/1,
	ancestors_dedupes_diamond_inheritance/1,
	inherited_qcs_multi_parent/1,
	class_in_ancestry_via_added_parent/1,
	%% Inheritance
	inherited_qcs_local_only/1,
	inherited_qcs_from_ancestors/1,
	inherited_qcs_deduplicates/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, creation}, {group, templates},
	 {group, qualifying}, {group, lookups}, {group, hierarchy},
	 {group, multi_inheritance}, {group, inheritance}].

groups() ->
	[
		{creation, [], [
			create_class_top_level,
			create_class_subclass,
			create_class_rejects_bad_parent_kind,
			create_class_rejects_missing_parent,
			create_class_writes_compositional_arcs,
			create_class_auto_creates_default_template
		]},
		{templates, [], [
			add_template_basic,
			add_template_rejects_duplicate_name,
			add_template_rejects_non_class,
			get_template_returns_node,
			get_template_rejects_non_template,
			templates_for_class_lists_all,
			default_template_returns_default,
			default_template_not_found_after_delete,
			class_in_ancestry_self,
			class_in_ancestry_ancestor,
			class_in_ancestry_unrelated
		]},
		{qualifying, [], [
			add_qc_basic,
			add_qc_idempotent,
			add_qc_rejects_non_class,
			add_qc_rejects_non_attribute
		]},
		{lookups, [], [
			get_class_returns_node,
			get_class_not_found,
			get_class_rejects_non_class
		]},
		{hierarchy, [], [
			subclasses_returns_children,
			subclasses_empty_for_leaf,
			ancestors_returns_chain,
			ancestors_empty_for_top_level
		]},
		{multi_inheritance, [], [
			add_superclass_basic,
			add_superclass_writes_taxonomy_arcs,
			add_superclass_idempotent,
			add_superclass_rejects_self_reference,
			add_superclass_rejects_non_class_subject,
			add_superclass_rejects_non_class_target,
			ancestors_walks_multi_parent_dag,
			ancestors_dedupes_diamond_inheritance,
			inherited_qcs_multi_parent,
			class_in_ancestry_via_added_parent
		]},
		{inheritance, [], [
			inherited_qcs_local_only,
			inherited_qcs_from_ancestors,
			inherited_qcs_deduplicates
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
	%% Start graphdb_mgr to trigger bootstrap load (populates Mnesia)
	{ok, _} = graphdb_mgr:start_link(),
	%% Start graphdb_attr (seeds literal_type, target_kind, relationship_avp)
	{ok, _} = graphdb_attr:start_link(),
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"class_" ++ Unique]),
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
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	catch application:stop(nref),
	catch mnesia:stop(),
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),

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
%% Creation Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Create a top-level class under the Classes category (nref 3).
%%-----------------------------------------------------------------------------
create_class_top_level(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Nref} = graphdb_class:create_class("Animal", 3),
	{ok, Node} = graphdb_class:get_class(Nref),
	?assertEqual(class, Node#node.kind),
	?assertEqual([3], Node#node.parents),
	?assertEqual([#{attribute => 19, value => "Animal"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Create a subclass under an existing class.
%%-----------------------------------------------------------------------------
create_class_subclass(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AnimalNref} = graphdb_class:create_class("Animal", 3),
	{ok, MammalNref} = graphdb_class:create_class("Mammal", AnimalNref),
	{ok, Mammal} = graphdb_class:get_class(MammalNref),
	?assertEqual([AnimalNref], Mammal#node.parents).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-class/non-category parent.
%%-----------------------------------------------------------------------------
create_class_rejects_bad_parent_kind(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	%% Nref 6 (Names) is an attribute node, not a class
	?assertMatch({error, {invalid_parent_kind, attribute}},
		graphdb_class:create_class("Bad", 6)).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-existent parent.
%%-----------------------------------------------------------------------------
create_class_rejects_missing_parent(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	?assertEqual({error, parent_not_found},
		graphdb_class:create_class("Bad", 99999)).

%%-----------------------------------------------------------------------------
%% Creating a class must write the taxonomic parent/child arc pair plus
%% the default template node and its compositional class -> template arc
%% pair (+2 nodes total: class + default template; +4 arcs total: 2
%% taxonomy + 2 composition).
%%-----------------------------------------------------------------------------
create_class_writes_compositional_arcs(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	RelsBefore = mnesia:table_info(relationships, size),
	{ok, Nref} = graphdb_class:create_class("Vehicle", 3),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 4, RelsAfter),

	%% Parent (3) -> Child (Nref) with char=26 should exist
	{atomic, ParentOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 3, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Nref andalso
		R#relationship.characterization =:= 26 andalso
		R#relationship.reciprocal =:= 25
	end, ParentOut)),

	%% Child (Nref) -> Parent (3) with char=25 should exist
	{atomic, ChildOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= 3 andalso
		R#relationship.characterization =:= 25 andalso
		R#relationship.reciprocal =:= 26
	end, ChildOut)).


%%-----------------------------------------------------------------------------
%% Creating a class must auto-create a "default" template as a
%% compositional child (kind=template, parent=ClassNref).
%%-----------------------------------------------------------------------------
create_class_auto_creates_default_template(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TemplateNref} = graphdb_class:default_template(ClassNref),
	{ok, TemplateNode} = graphdb_class:get_template(TemplateNref),
	?assertEqual(template, TemplateNode#node.kind),
	?assertEqual([ClassNref], TemplateNode#node.parents),
	?assert(lists:member(#{attribute => 19, value => "default"},
		TemplateNode#node.attribute_value_pairs)).


%%=============================================================================
%% Template Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_template/2 attaches a named template as a compositional child.
%%-----------------------------------------------------------------------------
add_template_basic(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref} = graphdb_class:add_template(ClassNref, "biological"),
	{ok, Node} = graphdb_class:get_template(TmplNref),
	?assertEqual(template, Node#node.kind),
	?assertEqual([ClassNref], Node#node.parents),
	?assert(lists:member(#{attribute => 19, value => "biological"},
		Node#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% add_template/2 rejects a name already taken by an existing template
%% (including the auto-created "default").
%%-----------------------------------------------------------------------------
add_template_rejects_duplicate_name(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assertMatch({error, {template_already_exists, "default"}},
		graphdb_class:add_template(ClassNref, "default")).

%%-----------------------------------------------------------------------------
%% add_template/2 rejects a non-class parent.
%%-----------------------------------------------------------------------------
add_template_rejects_non_class(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	%% nref 6 is an attribute (Names subtree), not a class
	?assertMatch({error, _},
		graphdb_class:add_template(6, "x")).

%%-----------------------------------------------------------------------------
%% get_template returns the template node.
%%-----------------------------------------------------------------------------
get_template_returns_node(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref} = graphdb_class:default_template(ClassNref),
	{ok, Node} = graphdb_class:get_template(TmplNref),
	?assertEqual(TmplNref, Node#node.nref),
	?assertEqual(template, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_template rejects a class nref (kind mismatch).
%%-----------------------------------------------------------------------------
get_template_rejects_non_template(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assertEqual({error, not_a_template},
		graphdb_class:get_template(ClassNref)).

%%-----------------------------------------------------------------------------
%% templates_for_class returns all templates (default plus any added).
%%-----------------------------------------------------------------------------
templates_for_class_lists_all(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, _} = graphdb_class:add_template(ClassNref, "biological"),
	{ok, _} = graphdb_class:add_template(ClassNref, "social"),
	{ok, Templates} = graphdb_class:templates_for_class(ClassNref),
	Names = [V || #node{attribute_value_pairs = AVPs} <- Templates,
		#{attribute := 19, value := V} <- AVPs],
	?assertEqual(lists:sort(["default", "biological", "social"]),
		lists:sort(Names)).

%%-----------------------------------------------------------------------------
%% default_template returns the auto-created default template's nref.
%%-----------------------------------------------------------------------------
default_template_returns_default(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref} = graphdb_class:default_template(ClassNref),
	{ok, Node} = graphdb_class:get_template(TmplNref),
	?assert(lists:member(#{attribute => 19, value => "default"},
		Node#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% Deleting the default template node makes default_template return
%% not_found — the class then forces explicit Template specification on
%% any subsequent Connection arc.
%%-----------------------------------------------------------------------------
default_template_not_found_after_delete(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref} = graphdb_class:default_template(ClassNref),
	{atomic, ok} = mnesia:transaction(fun() ->
		mnesia:delete({nodes, TmplNref})
	end),
	?assertEqual(not_found, graphdb_class:default_template(ClassNref)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry returns true when the candidate equals the class.
%%-----------------------------------------------------------------------------
class_in_ancestry_self(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assert(graphdb_class:class_in_ancestry(ClassNref, ClassNref)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry returns true when the candidate is an ancestor.
%%-----------------------------------------------------------------------------
class_in_ancestry_ancestor(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AnimalNref} = graphdb_class:create_class("Animal", 3),
	{ok, MammalNref} = graphdb_class:create_class("Mammal", AnimalNref),
	{ok, WhaleNref}  = graphdb_class:create_class("Whale", MammalNref),
	?assert(graphdb_class:class_in_ancestry(AnimalNref, WhaleNref)),
	?assert(graphdb_class:class_in_ancestry(MammalNref, WhaleNref)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry returns false for unrelated classes.
%%-----------------------------------------------------------------------------
class_in_ancestry_unrelated(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AnimalNref}  = graphdb_class:create_class("Animal", 3),
	{ok, VehicleNref} = graphdb_class:create_class("Vehicle", 3),
	?assertNot(graphdb_class:class_in_ancestry(VehicleNref, AnimalNref)).


%%=============================================================================
%% Qualifying Characteristic Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic adds an attribute nref to the class's AVPs
%% using the unified shape: #{attribute => AttrNref, value => undefined}.
%%-----------------------------------------------------------------------------
add_qc_basic(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	%% Use bootstrap attribute nref 18 (Name/attribute) as a QC for testing
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	{ok, Node} = graphdb_class:get_class(ClassNref),
	?assert(lists:member(#{attribute => 18, value => undefined},
		Node#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% Adding the same QC twice is idempotent.
%%-----------------------------------------------------------------------------
add_qc_idempotent(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Size", 3),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	{ok, Node} = graphdb_class:get_class(ClassNref),
	QcCount = length([1 || #{attribute := A} <-
		Node#node.attribute_value_pairs,
		A =:= 18]),
	?assertEqual(1, QcCount).

%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic rejects non-class nodes.
%%-----------------------------------------------------------------------------
add_qc_rejects_non_class(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	%% Nref 6 is an attribute node
	?assertMatch({error, {not_a_class, _}},
		graphdb_class:add_qualifying_characteristic(6, 18)).

%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic rejects non-attribute nrefs.
%%-----------------------------------------------------------------------------
add_qc_rejects_non_attribute(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Shape", 3),
	%% Nref 1 is a category node, not attribute
	?assertMatch({error, {not_an_attribute, 1}},
		graphdb_class:add_qualifying_characteristic(ClassNref, 1)).


%%=============================================================================
%% Lookup Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_class returns a class node.
%%-----------------------------------------------------------------------------
get_class_returns_node(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Nref} = graphdb_class:create_class("Material", 3),
	{ok, Node} = graphdb_class:get_class(Nref),
	?assertEqual(Nref, Node#node.nref),
	?assertEqual(class, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_class returns {error, not_found} for an unknown nref.
%%-----------------------------------------------------------------------------
get_class_not_found(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	?assertEqual({error, not_found}, graphdb_class:get_class(99999)).

%%-----------------------------------------------------------------------------
%% get_class rejects non-class nodes.
%%-----------------------------------------------------------------------------
get_class_rejects_non_class(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	%% Nref 1 (Root) is a category
	?assertEqual({error, not_a_class}, graphdb_class:get_class(1)).


%%=============================================================================
%% Hierarchy Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% subclasses returns direct class children.
%%-----------------------------------------------------------------------------
subclasses_returns_children(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Animal} = graphdb_class:create_class("Animal", 3),
	{ok, Mammal} = graphdb_class:create_class("Mammal", Animal),
	{ok, Bird} = graphdb_class:create_class("Bird", Animal),
	{ok, Subs} = graphdb_class:subclasses(Animal),
	SubNrefs = lists:sort([N#node.nref || N <- Subs]),
	?assertEqual(lists:sort([Mammal, Bird]), SubNrefs).

%%-----------------------------------------------------------------------------
%% subclasses returns empty list for a leaf class.
%%-----------------------------------------------------------------------------
subclasses_empty_for_leaf(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Leaf} = graphdb_class:create_class("Leaf", 3),
	?assertEqual({ok, []}, graphdb_class:subclasses(Leaf)).

%%-----------------------------------------------------------------------------
%% ancestors returns the full chain from immediate parent to top-level.
%%-----------------------------------------------------------------------------
ancestors_returns_chain(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Animal} = graphdb_class:create_class("Animal", 3),
	{ok, Mammal} = graphdb_class:create_class("Mammal", Animal),
	{ok, Whale} = graphdb_class:create_class("Whale", Mammal),
	{ok, Ancestors} = graphdb_class:ancestors(Whale),
	AncNrefs = [N#node.nref || N <- Ancestors],
	%% Nearest-first: Mammal, then Animal
	?assertEqual([Mammal, Animal], AncNrefs).

%%-----------------------------------------------------------------------------
%% ancestors returns empty list for a top-level class (parent = 3).
%%-----------------------------------------------------------------------------
ancestors_empty_for_top_level(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, TopLevel} = graphdb_class:create_class("TopLevel", 3),
	?assertEqual({ok, []}, graphdb_class:ancestors(TopLevel)).


%%=============================================================================
%% Multi-Inheritance Tests (H3)
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_superclass appends a second taxonomic parent and the parents
%% cache reflects both, in insertion order (creation parent first).
%%-----------------------------------------------------------------------------
add_superclass_basic(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", 3),
	{ok, Child} = graphdb_class:create_class("Child", A),
	ok = graphdb_class:add_superclass(Child, B),
	{ok, Node} = graphdb_class:get_class(Child),
	?assertEqual([A, B], Node#node.parents).

%%-----------------------------------------------------------------------------
%% add_superclass writes a taxonomy arc pair (kind=taxonomy, char 25/26)
%% between the child and the additional parent.
%%-----------------------------------------------------------------------------
add_superclass_writes_taxonomy_arcs(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", 3),
	{ok, Child} = graphdb_class:create_class("Child", A),
	RelsBefore = mnesia:table_info(relationships, size),
	ok = graphdb_class:add_superclass(Child, B),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 2, RelsAfter),

	%% Child -> B with char=25 (parent arc), kind=taxonomy
	{atomic, ChildOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Child, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= B andalso
		R#relationship.characterization =:= 25 andalso
		R#relationship.reciprocal =:= 26 andalso
		R#relationship.kind =:= taxonomy
	end, ChildOut)),

	%% B -> Child with char=26 (child arc), kind=taxonomy
	{atomic, BOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, B, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Child andalso
		R#relationship.characterization =:= 26 andalso
		R#relationship.reciprocal =:= 25 andalso
		R#relationship.kind =:= taxonomy
	end, BOut)).

%%-----------------------------------------------------------------------------
%% add_superclass with an already-present parent is a no-op (no new
%% arcs, no duplicate parents entry).
%%-----------------------------------------------------------------------------
add_superclass_idempotent(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", 3),
	{ok, Child} = graphdb_class:create_class("Child", A),
	ok = graphdb_class:add_superclass(Child, B),
	RelsBefore = mnesia:table_info(relationships, size),
	ok = graphdb_class:add_superclass(Child, B),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore, RelsAfter),
	{ok, Node} = graphdb_class:get_class(Child),
	?assertEqual([A, B], Node#node.parents).

%%-----------------------------------------------------------------------------
%% A class cannot be its own superclass.
%%-----------------------------------------------------------------------------
add_superclass_rejects_self_reference(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	?assertEqual({error, cyclic_self_reference},
		graphdb_class:add_superclass(A, A)).

%%-----------------------------------------------------------------------------
%% add_superclass rejects a non-class subject (e.g., an attribute).
%%-----------------------------------------------------------------------------
add_superclass_rejects_non_class_subject(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	%% nref 6 (Names) is an attribute node, not a class
	?assertMatch({error, _}, graphdb_class:add_superclass(6, A)).

%%-----------------------------------------------------------------------------
%% add_superclass rejects a non-class additional parent.
%%-----------------------------------------------------------------------------
add_superclass_rejects_non_class_target(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	%% nref 6 (Names) is an attribute node, not a class
	?assertMatch({error, {invalid_parent_kind, attribute}},
		graphdb_class:add_superclass(A, 6)).

%%-----------------------------------------------------------------------------
%% ancestors walks the full multi-parent DAG in BFS (nearest-first)
%% order.  Class C has parents A and B (no shared ancestors); ancestors
%% returns [A, B] -- both at depth 1.
%%-----------------------------------------------------------------------------
ancestors_walks_multi_parent_dag(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", 3),
	{ok, C} = graphdb_class:create_class("C", A),
	ok = graphdb_class:add_superclass(C, B),
	{ok, Ancestors} = graphdb_class:ancestors(C),
	AncNrefs = [N#node.nref || N <- Ancestors],
	?assertEqual([A, B], AncNrefs).

%%-----------------------------------------------------------------------------
%% Diamond inheritance: D inherits from B and C, both of which inherit
%% from A.  ancestors(D) returns each ancestor exactly once, BFS-ordered:
%% [B, C, A].
%%-----------------------------------------------------------------------------
ancestors_dedupes_diamond_inheritance(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", A),
	{ok, C} = graphdb_class:create_class("C", A),
	{ok, D} = graphdb_class:create_class("D", B),
	ok = graphdb_class:add_superclass(D, C),
	{ok, Ancestors} = graphdb_class:ancestors(D),
	AncNrefs = [N#node.nref || N <- Ancestors],
	%% Depth 1: B then C; Depth 2: A (visited once even though both
	%% B and C list it as a parent).
	?assertEqual([B, C, A], AncNrefs).

%%-----------------------------------------------------------------------------
%% inherited_qcs gathers QCs from all multi-parent ancestors in BFS order.
%% Uses attr 20 for C's local QC to avoid conflict with class name attr 19.
%%-----------------------------------------------------------------------------
inherited_qcs_multi_parent(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	ok = graphdb_class:add_qualifying_characteristic(A, 17),
	{ok, B} = graphdb_class:create_class("B", 3),
	ok = graphdb_class:add_qualifying_characteristic(B, 18),
	{ok, C} = graphdb_class:create_class("C", A),
	ok = graphdb_class:add_superclass(C, B),
	ok = graphdb_class:add_qualifying_characteristic(C, 20),
	{ok, QcPairs} = graphdb_class:inherited_qcs(C),
	%% Local (20), then nearest parents A (17), B (18) — all value=>undefined.
	?assert(lists:member({20, undefined}, QcPairs)),
	?assert(lists:member({17, undefined}, QcPairs)),
	?assert(lists:member({18, undefined}, QcPairs)),
	%% Order: C's local QC before ancestors.
	Attrs = [A2 || {A2, _} <- QcPairs],
	?assert(lists_index_of(20, Attrs) < lists_index_of(17, Attrs)),
	?assert(lists_index_of(20, Attrs) < lists_index_of(18, Attrs)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry finds a parent added via add_superclass.
%%-----------------------------------------------------------------------------
class_in_ancestry_via_added_parent(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", 3),
	{ok, C} = graphdb_class:create_class("C", A),
	ok = graphdb_class:add_superclass(C, B),
	?assert(graphdb_class:class_in_ancestry(B, C)),
	?assert(graphdb_class:class_in_ancestry(A, C)).


%%=============================================================================
%% Inheritance Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% inherited_qcs returns only local QCs when no ancestors have any.
%% Uses attrs 17 and 18 (not 19 — that is the class name attr and conflicts).
%%-----------------------------------------------------------------------------
inherited_qcs_local_only(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 17),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	{ok, QcPairs} = graphdb_class:inherited_qcs(ClassNref),
	%% Class has name AVP (attr=19, value="Color") plus two QC AVPs.
	%% inherited_qcs returns ALL AVPs; QC attrs 17 and 18 should be present.
	?assert(lists:member({17, undefined}, QcPairs)),
	?assert(lists:member({18, undefined}, QcPairs)).

%%-----------------------------------------------------------------------------
%% inherited_qcs includes QCs from ancestor classes.
%%-----------------------------------------------------------------------------
inherited_qcs_from_ancestors(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Animal} = graphdb_class:create_class("Animal", 3),
	ok = graphdb_class:add_qualifying_characteristic(Animal, 17),
	{ok, Mammal} = graphdb_class:create_class("Mammal", Animal),
	ok = graphdb_class:add_qualifying_characteristic(Mammal, 18),
	{ok, Whale} = graphdb_class:create_class("Whale", Mammal),
	ok = graphdb_class:add_qualifying_characteristic(Whale, 20),
	{ok, QcPairs} = graphdb_class:inherited_qcs(Whale),
	%% QC attrs 20 (local), 18 (from Mammal), 17 (from Animal) must appear.
	%% Dedup: each appears exactly once; local entry comes first.
	?assert(lists:member({20, undefined}, QcPairs)),
	?assert(lists:member({18, undefined}, QcPairs)),
	?assert(lists:member({17, undefined}, QcPairs)),
	%% 20 must appear before 18, and 18 must appear before 17.
	Attrs = [A || {A, _} <- QcPairs],
	?assert(lists_index_of(20, Attrs) < lists_index_of(18, Attrs)),
	?assert(lists_index_of(18, Attrs) < lists_index_of(17, Attrs)).

%%-----------------------------------------------------------------------------
%% inherited_qcs deduplicates: if a child has the same QC as an ancestor,
%% the local version takes priority and the ancestor's is not repeated.
%%-----------------------------------------------------------------------------
inherited_qcs_deduplicates(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Parent} = graphdb_class:create_class("Parent", 3),
	ok = graphdb_class:add_qualifying_characteristic(Parent, 17),
	ok = graphdb_class:add_qualifying_characteristic(Parent, 18),
	{ok, Child} = graphdb_class:create_class("Child", Parent),
	ok = graphdb_class:add_qualifying_characteristic(Child, 18),
	ok = graphdb_class:add_qualifying_characteristic(Child, 20),
	{ok, QcPairs} = graphdb_class:inherited_qcs(Child),
	%% 18 appears only once (from Child, not duplicated from Parent).
	Count18 = length([1 || {A, _} <- QcPairs, A =:= 18]),
	?assertEqual(1, Count18),
	%% 17 (from Parent only) and 20 (from Child only) also present.
	?assert(lists:member({17, undefined}, QcPairs)),
	?assert(lists:member({18, undefined}, QcPairs)),
	?assert(lists:member({20, undefined}, QcPairs)).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% lists_index_of(Elem, List) -> integer()
%%
%% Returns the 1-based position of Elem in List.  Used by ordering assertions.
%%-----------------------------------------------------------------------------
lists_index_of(Elem, List) ->
	lists_index_of(Elem, List, 1).

lists_index_of(Elem, [Elem | _], Idx) -> Idx;
lists_index_of(Elem, [_ | Rest], Idx) -> lists_index_of(Elem, Rest, Idx + 1).


%%-----------------------------------------------------------------------------
%% ensure_loaded(App) -> ok
%%-----------------------------------------------------------------------------
ensure_loaded(App) ->
	case application:load(App) of
		ok                             -> ok;
		{error, {already_loaded, App}} -> ok
	end.

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "class_").


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
