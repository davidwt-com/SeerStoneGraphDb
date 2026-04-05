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
%% Description: Common Test integration suite for graphdb_attr.
%%				Each test case gets its own isolated temp directory
%%				with a fresh Mnesia database and nref allocator.
%%				graphdb_mgr is started first to load the bootstrap
%%				scaffold; graphdb_attr is then started and its create
%%				and lookup API are exercised against live Mnesia.
%%---------------------------------------------------------------------
-module(graphdb_attr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb_attr internal records)
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
	seeds_created_on_first_start/1,
	seeds_idempotent_on_restart/1,
	seeded_nrefs_are_above_floor/1,
	%% Creators
	create_name_attribute_basic/1,
	create_literal_attribute_stores_type/1,
	create_relationship_attribute_pair/1,
	create_relationship_attribute_rejects_bad_kind/1,
	create_relationship_type_basic/1,
	new_attribute_writes_compositional_arcs/1,
	%% Lookups
	get_attribute_returns_node/1,
	get_attribute_not_found/1,
	get_attribute_rejects_non_attribute/1,
	list_attributes_includes_bootstrap_and_runtime/1,
	list_relationship_types_includes_buckets/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, seeding}, {group, creators}, {group, lookups}].

groups() ->
	[
		{seeding, [], [
			seeds_created_on_first_start,
			seeds_idempotent_on_restart,
			seeded_nrefs_are_above_floor
		]},
		{creators, [], [
			create_name_attribute_basic,
			create_literal_attribute_stores_type,
			create_relationship_attribute_pair,
			create_relationship_attribute_rejects_bad_kind,
			create_relationship_type_basic,
			new_attribute_writes_compositional_arcs
		]},
		{lookups, [], [
			get_attribute_returns_node,
			get_attribute_not_found,
			get_attribute_rejects_non_attribute,
			list_attributes_includes_bootstrap_and_runtime,
			list_relationship_types_includes_buckets
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
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"attr_" ++ Unique]),
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
%% On first startup, graphdb_attr seeds literal_type, target_kind, and
%% relationship_avp under the Literals subtree (nref 7).
%%-----------------------------------------------------------------------------
seeds_created_on_first_start(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{literal_type := Lt, target_kind := Tk, relationship_avp := Ra}} =
		graphdb_attr:seeded_nrefs(),
	?assert(is_integer(Lt)),
	?assert(is_integer(Tk)),
	?assert(is_integer(Ra)),
	%% All three are distinct
	?assertNotEqual(Lt, Tk),
	?assertNotEqual(Lt, Ra),
	?assertNotEqual(Tk, Ra),
	%% Each is an attribute node whose parent is the Literals subtree (7)
	lists:foreach(fun(N) ->
		{ok, Node} = graphdb_attr:get_attribute(N),
		?assertEqual(attribute, Node#node.kind),
		?assertEqual(7, Node#node.parent)
	end, [Lt, Tk, Ra]).

%%-----------------------------------------------------------------------------
%% Restarting graphdb_attr must detect existing seeds and NOT create
%% duplicates.  Seeded nrefs should be identical across restarts.
%%-----------------------------------------------------------------------------
seeds_idempotent_on_restart(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, Seeds1} = graphdb_attr:seeded_nrefs(),
	NodesBefore = mnesia:table_info(nodes, size),

	ok = gen_server:stop(graphdb_attr),
	{ok, _} = graphdb_attr:start_link(),
	{ok, Seeds2} = graphdb_attr:seeded_nrefs(),
	NodesAfter = mnesia:table_info(nodes, size),

	?assertEqual(Seeds1, Seeds2),
	?assertEqual(NodesBefore, NodesAfter).

%%-----------------------------------------------------------------------------
%% Seeded nrefs are runtime-allocated and must be >= the nref_start
%% floor (10000 from bootstrap.terms).
%%-----------------------------------------------------------------------------
seeded_nrefs_are_above_floor(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{literal_type := Lt, target_kind := Tk, relationship_avp := Ra}} =
		graphdb_attr:seeded_nrefs(),
	?assert(Lt >= 10000),
	?assert(Tk >= 10000),
	?assert(Ra >= 10000).


%%=============================================================================
%% Creator Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% create_name_attribute writes an attribute node under parent=6.
%%-----------------------------------------------------------------------------
create_name_attribute_basic(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, Nref} = graphdb_attr:create_name_attribute("TestName"),
	{ok, Node} = graphdb_attr:get_attribute(Nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual(6, Node#node.parent),
	?assertEqual([#{attribute => 18, value => "TestName"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% create_literal_attribute stores the Type argument as an AVP keyed
%% by the seeded literal_type attribute.
%%-----------------------------------------------------------------------------
create_literal_attribute_stores_type(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{literal_type := Lt}} = graphdb_attr:seeded_nrefs(),
	{ok, Nref} = graphdb_attr:create_literal_attribute("Weight", kilogram),
	{ok, Node} = graphdb_attr:get_attribute(Nref),
	?assertEqual(7, Node#node.parent),
	AVPs = Node#node.attribute_value_pairs,
	?assert(lists:member(#{attribute => 18, value => "Weight"}, AVPs)),
	?assert(lists:member(#{attribute => Lt, value => kilogram}, AVPs)).

%%-----------------------------------------------------------------------------
%% create_relationship_attribute writes two arc label nodes, each
%% with a target_kind AVP; they share the same parent and have
%% distinct nrefs.
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{target_kind := Tk}} = graphdb_attr:seeded_nrefs(),
	{ok, {FwdNref, RevNref}} =
		graphdb_attr:create_relationship_attribute("Makes", "MadeBy", class),
	?assertNotEqual(FwdNref, RevNref),

	{ok, Fwd} = graphdb_attr:get_attribute(FwdNref),
	{ok, Rev} = graphdb_attr:get_attribute(RevNref),
	?assertEqual(8, Fwd#node.parent),
	?assertEqual(8, Rev#node.parent),
	?assert(lists:member(#{attribute => 18, value => "Makes"},
		Fwd#node.attribute_value_pairs)),
	?assert(lists:member(#{attribute => 18, value => "MadeBy"},
		Rev#node.attribute_value_pairs)),
	?assert(lists:member(#{attribute => Tk, value => class},
		Fwd#node.attribute_value_pairs)),
	?assert(lists:member(#{attribute => Tk, value => class},
		Rev#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% create_relationship_attribute rejects invalid target_kind atoms
%% before touching Mnesia.
%%-----------------------------------------------------------------------------
create_relationship_attribute_rejects_bad_kind(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	?assertEqual({error, {invalid_target_kind, bogus}},
		graphdb_attr:create_relationship_attribute("X", "Y", bogus)).

%%-----------------------------------------------------------------------------
%% create_relationship_type writes a grouping node under parent=8.
%%-----------------------------------------------------------------------------
create_relationship_type_basic(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, Nref} = graphdb_attr:create_relationship_type("Ownership"),
	{ok, Node} = graphdb_attr:get_attribute(Nref),
	?assertEqual(8, Node#node.parent),
	?assertEqual([#{attribute => 18, value => "Ownership"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Creating a new attribute must write the compositional parent/child
%% arc pair into the relationships table so the new node is reachable
%% by traversal from its parent.
%%-----------------------------------------------------------------------------
new_attribute_writes_compositional_arcs(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	RelsBefore = mnesia:table_info(relationships, size),
	{ok, Nref} = graphdb_attr:create_name_attribute("ArcTest"),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 2, RelsAfter),

	%% Parent (6) -> Child (Nref) with char=24 should exist
	{atomic, ParentOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 6, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Nref andalso
		R#relationship.characterization =:= 24 andalso
		R#relationship.reciprocal =:= 23
	end, ParentOut)),

	%% Child (Nref) -> Parent (6) with char=23 should exist
	{atomic, ChildOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= 6 andalso
		R#relationship.characterization =:= 23 andalso
		R#relationship.reciprocal =:= 24
	end, ChildOut)).


%%=============================================================================
%% Lookup Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_attribute returns a bootstrap attribute node correctly.
%%-----------------------------------------------------------------------------
get_attribute_returns_node(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	%% Nref 6 (Names) is a bootstrap attribute
	{ok, Node} = graphdb_attr:get_attribute(6),
	?assertEqual(6, Node#node.nref),
	?assertEqual(attribute, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_attribute returns {error, not_found} for an unknown nref.
%%-----------------------------------------------------------------------------
get_attribute_not_found(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	?assertEqual({error, not_found}, graphdb_attr:get_attribute(99999)).

%%-----------------------------------------------------------------------------
%% get_attribute rejects non-attribute nodes (category, class, etc.).
%%-----------------------------------------------------------------------------
get_attribute_rejects_non_attribute(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	%% Nref 1 (Root) is a category, not attribute
	?assertEqual({error, not_an_attribute}, graphdb_attr:get_attribute(1)).

%%-----------------------------------------------------------------------------
%% list_attributes returns every attribute-kind node including
%% bootstrap (25 of them: nrefs 6-30) plus the three seeds plus any
%% runtime creates in this test.
%%-----------------------------------------------------------------------------
list_attributes_includes_bootstrap_and_runtime(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, Before} = graphdb_attr:list_attributes(),
	%% Bootstrap has 25 attribute nodes (nrefs 6-30); seeding adds 3
	?assertEqual(25 + 3, length(Before)),

	{ok, _} = graphdb_attr:create_name_attribute("One"),
	{ok, _} = graphdb_attr:create_name_attribute("Two"),
	{ok, After} = graphdb_attr:list_attributes(),
	?assertEqual(length(Before) + 2, length(After)).

%%-----------------------------------------------------------------------------
%% list_relationship_types returns the four bootstrap buckets
%% (nrefs 13-16) plus any runtime additions.
%%-----------------------------------------------------------------------------
list_relationship_types_includes_buckets(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, Before} = graphdb_attr:list_relationship_types(),
	Nrefs = lists:sort([N#node.nref || N <- Before]),
	?assertEqual([13, 14, 15, 16], Nrefs),

	{ok, NewType} = graphdb_attr:create_relationship_type("Custom"),
	{ok, After} = graphdb_attr:list_relationship_types(),
	AfterNrefs = lists:sort([N#node.nref || N <- After]),
	?assertEqual([13, 14, 15, 16, NewType], AfterNrefs).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% ensure_loaded(App) -> ok
%%
%% Tolerant of already_loaded so multiple CT suites in the same run
%% can each call it without tearing down application state.
%%-----------------------------------------------------------------------------
ensure_loaded(App) ->
	case application:load(App) of
		ok                                -> ok;
		{error, {already_loaded, App}}    -> ok
	end.

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "attr_").


%%-----------------------------------------------------------------------------
%% delete_dir_recursive(Dir) -> ok | error({unsafe_delete, Dir})
%%
%% Safety: refuses to operate unless Dir is an absolute path containing
%% the sentinel "_build/test/ct_scratch/" and whose leaf starts with
%% "attr_".  Prevents misuse from deleting project source or user
%% directories.
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
