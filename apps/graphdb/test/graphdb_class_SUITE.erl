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
	parent,
	attribute_value_pairs
}).

-record(relationship, {
	id,
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
	%% Seeding
	qc_seed_created_on_first_start/1,
	qc_seed_idempotent_on_restart/1,
	qc_seed_nref_above_floor/1,
	%% Creation
	create_class_top_level/1,
	create_class_subclass/1,
	create_class_rejects_bad_parent_kind/1,
	create_class_rejects_missing_parent/1,
	create_class_writes_compositional_arcs/1,
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
	%% Inheritance
	inherited_attributes_local_only/1,
	inherited_attributes_from_ancestors/1,
	inherited_attributes_deduplicates/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, seeding}, {group, creation}, {group, qualifying},
	 {group, lookups}, {group, hierarchy}, {group, inheritance}].

groups() ->
	[
		{seeding, [], [
			qc_seed_created_on_first_start,
			qc_seed_idempotent_on_restart,
			qc_seed_nref_above_floor
		]},
		{creation, [], [
			create_class_top_level,
			create_class_subclass,
			create_class_rejects_bad_parent_kind,
			create_class_rejects_missing_parent,
			create_class_writes_compositional_arcs
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
		{inheritance, [], [
			inherited_attributes_local_only,
			inherited_attributes_from_ancestors,
			inherited_attributes_deduplicates
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
end_per_testcase(_TC, Config) ->
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


%%=============================================================================
%% Seeding Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% On first startup, graphdb_class seeds the qualifying_characteristic
%% attribute under the Literals subtree (nref 7).
%%-----------------------------------------------------------------------------
qc_seed_created_on_first_start(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, QcNref} = graphdb_class:qc_attr_nref(),
	?assert(is_integer(QcNref)),
	%% Verify it's a real attribute node under Literals (parent=7)
	{ok, Node} = graphdb_attr:get_attribute(QcNref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual(7, Node#node.parent).

%%-----------------------------------------------------------------------------
%% Restarting graphdb_class must detect the existing seed and NOT
%% create duplicates.
%%-----------------------------------------------------------------------------
qc_seed_idempotent_on_restart(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Nref1} = graphdb_class:qc_attr_nref(),
	NodesBefore = mnesia:table_info(nodes, size),

	ok = gen_server:stop(graphdb_class),
	{ok, _} = graphdb_class:start_link(),
	{ok, Nref2} = graphdb_class:qc_attr_nref(),
	NodesAfter = mnesia:table_info(nodes, size),

	?assertEqual(Nref1, Nref2),
	?assertEqual(NodesBefore, NodesAfter).

%%-----------------------------------------------------------------------------
%% Seeded nref must be >= the nref_start floor (10000).
%%-----------------------------------------------------------------------------
qc_seed_nref_above_floor(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, QcNref} = graphdb_class:qc_attr_nref(),
	?assert(QcNref >= 10000).


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
	?assertEqual(3, Node#node.parent),
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
	?assertEqual(AnimalNref, Mammal#node.parent).

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
%% Creating a class must write the compositional parent/child arc pair.
%%-----------------------------------------------------------------------------
create_class_writes_compositional_arcs(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	RelsBefore = mnesia:table_info(relationships, size),
	{ok, Nref} = graphdb_class:create_class("Vehicle", 3),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 2, RelsAfter),

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


%%=============================================================================
%% Qualifying Characteristic Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic adds an attribute nref to the class's AVPs.
%%-----------------------------------------------------------------------------
add_qc_basic(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, QcAttr} = graphdb_class:qc_attr_nref(),
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	%% Use bootstrap attribute nref 18 (Name/attribute) as a QC for testing
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	{ok, Node} = graphdb_class:get_class(ClassNref),
	?assert(lists:member(#{attribute => QcAttr, value => 18},
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
	{ok, QcAttr} = graphdb_class:qc_attr_nref(),
	QcCount = length([1 || #{attribute := A, value := V} <-
		Node#node.attribute_value_pairs,
		A =:= QcAttr, V =:= 18]),
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
%% Inheritance Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% inherited_attributes returns only local QCs when no ancestors have any.
%%-----------------------------------------------------------------------------
inherited_attributes_local_only(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 18),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, 19),
	{ok, QcNrefs} = graphdb_class:inherited_attributes(ClassNref),
	?assertEqual([18, 19], QcNrefs).

%%-----------------------------------------------------------------------------
%% inherited_attributes includes QCs from ancestor classes.
%%-----------------------------------------------------------------------------
inherited_attributes_from_ancestors(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Animal} = graphdb_class:create_class("Animal", 3),
	ok = graphdb_class:add_qualifying_characteristic(Animal, 17),
	{ok, Mammal} = graphdb_class:create_class("Mammal", Animal),
	ok = graphdb_class:add_qualifying_characteristic(Mammal, 18),
	{ok, Whale} = graphdb_class:create_class("Whale", Mammal),
	ok = graphdb_class:add_qualifying_characteristic(Whale, 19),
	{ok, QcNrefs} = graphdb_class:inherited_attributes(Whale),
	%% Local first (19), then nearest ancestor (Mammal: 18), then Animal (17)
	?assertEqual([19, 18, 17], QcNrefs).

%%-----------------------------------------------------------------------------
%% inherited_attributes deduplicates: if a child has the same QC as an
%% ancestor, the local version takes priority and the ancestor's is
%% not repeated.
%%-----------------------------------------------------------------------------
inherited_attributes_deduplicates(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Parent} = graphdb_class:create_class("Parent", 3),
	ok = graphdb_class:add_qualifying_characteristic(Parent, 17),
	ok = graphdb_class:add_qualifying_characteristic(Parent, 18),
	{ok, Child} = graphdb_class:create_class("Child", Parent),
	ok = graphdb_class:add_qualifying_characteristic(Child, 18),
	ok = graphdb_class:add_qualifying_characteristic(Child, 19),
	{ok, QcNrefs} = graphdb_class:inherited_attributes(Child),
	%% Child's 18 and 19 first, then Parent's 17 (Parent's 18 is duplicate)
	?assertEqual([18, 19, 17], QcNrefs).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

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
