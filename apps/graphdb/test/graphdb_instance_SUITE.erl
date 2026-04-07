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
%% Description: Common Test integration suite for graphdb_instance.
%%				Each test case gets its own isolated temp directory
%%				with a fresh Mnesia database and nref allocator.
%%				graphdb_mgr is started first to load the bootstrap
%%				scaffold; graphdb_attr, graphdb_class, and
%%				graphdb_instance are then started and exercised.
%%---------------------------------------------------------------------
-module(graphdb_instance_SUITE).

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
	%% Creation
	create_instance_basic/1,
	create_instance_rejects_bad_class/1,
	create_instance_rejects_missing_class/1,
	create_instance_rejects_missing_parent/1,
	create_instance_writes_membership_arcs/1,
	create_instance_writes_compositional_arcs/1,
	%% Relationships
	add_relationship_basic/1,
	add_relationship_both_directions/1,
	%% Lookups
	get_instance_returns_node/1,
	get_instance_not_found/1,
	get_instance_rejects_non_instance/1,
	%% Hierarchy
	children_returns_instance_children/1,
	children_empty_for_leaf/1,
	ancestors_returns_chain/1,
	ancestors_empty_for_top_level/1,
	%% Inheritance
	resolve_value_local/1,
	resolve_value_from_class/1,
	resolve_value_from_ancestor/1,
	resolve_value_from_connected/1,
	resolve_value_not_found/1,
	resolve_value_priority_local_over_class/1,
	resolve_value_priority_class_over_ancestor/1,
	resolve_value_priority_ancestor_over_connected/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, creation}, {group, relationships}, {group, lookups},
	 {group, hierarchy}, {group, inheritance}].

groups() ->
	[
		{creation, [], [
			create_instance_basic,
			create_instance_rejects_bad_class,
			create_instance_rejects_missing_class,
			create_instance_rejects_missing_parent,
			create_instance_writes_membership_arcs,
			create_instance_writes_compositional_arcs
		]},
		{relationships, [], [
			add_relationship_basic,
			add_relationship_both_directions
		]},
		{lookups, [], [
			get_instance_returns_node,
			get_instance_not_found,
			get_instance_rejects_non_instance
		]},
		{hierarchy, [], [
			children_returns_instance_children,
			children_empty_for_leaf,
			ancestors_returns_chain,
			ancestors_empty_for_top_level
		]},
		{inheritance, [], [
			resolve_value_local,
			resolve_value_from_class,
			resolve_value_from_ancestor,
			resolve_value_from_connected,
			resolve_value_not_found,
			resolve_value_priority_local_over_class,
			resolve_value_priority_class_over_ancestor,
			resolve_value_priority_ancestor_over_connected
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
	%% Start workers in dependency order
	{ok, _} = graphdb_mgr:start_link(),
	{ok, _} = graphdb_attr:start_link(),
	{ok, _} = graphdb_class:start_link(),
	{ok, _} = graphdb_instance:start_link(),
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"instance_" ++ Unique]),
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
	catch gen_server:stop(graphdb_instance),
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
%% Creation Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Create an instance with a class and parent.  Uses the Projects
%% category (nref 5) as the compositional parent anchor.
%%-----------------------------------------------------------------------------
create_instance_basic(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Vehicle", 3),
	{ok, InstNref} = graphdb_instance:create_instance("Car1", ClassNref, 5),
	{ok, Node} = graphdb_instance:get_instance(InstNref),
	?assertEqual(instance, Node#node.kind),
	?assertEqual(5, Node#node.parent),
	?assertEqual([#{attribute => 20, value => "Car1"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-class nref.
%%-----------------------------------------------------------------------------
create_instance_rejects_bad_class(_Config) ->
	%% Nref 6 (Names) is an attribute node
	?assertMatch({error, {not_a_class, attribute}},
		graphdb_instance:create_instance("Bad", 6, 5)).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-existent class.
%%-----------------------------------------------------------------------------
create_instance_rejects_missing_class(_Config) ->
	?assertEqual({error, class_not_found},
		graphdb_instance:create_instance("Bad", 99999, 5)).

%%-----------------------------------------------------------------------------
%% Reject creation with a non-existent parent.
%%-----------------------------------------------------------------------------
create_instance_rejects_missing_parent(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	?assertEqual({error, parent_not_found},
		graphdb_instance:create_instance("Bad", ClassNref, 99999)).

%%-----------------------------------------------------------------------------
%% Creating an instance must write membership arcs (char=29/30).
%%-----------------------------------------------------------------------------
create_instance_writes_membership_arcs(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, InstNref} = graphdb_instance:create_instance("Dog1", ClassNref, 5),

	%% Instance -> Class (char=29, reciprocal=30)
	{atomic, InstOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, InstNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= ClassNref andalso
		R#relationship.characterization =:= 29 andalso
		R#relationship.reciprocal =:= 30
	end, InstOut)),

	%% Class -> Instance (char=30, reciprocal=29)
	{atomic, ClassOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, ClassNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= InstNref andalso
		R#relationship.characterization =:= 30 andalso
		R#relationship.reciprocal =:= 29
	end, ClassOut)).

%%-----------------------------------------------------------------------------
%% Creating an instance must write compositional arcs (char=28/27).
%%-----------------------------------------------------------------------------
create_instance_writes_compositional_arcs(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, InstNref} = graphdb_instance:create_instance("Bolt1", ClassNref, 5),

	%% Parent (5) -> Child (InstNref) with char=28
	{atomic, ParentOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 5, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= InstNref andalso
		R#relationship.characterization =:= 28 andalso
		R#relationship.reciprocal =:= 27
	end, ParentOut)),

	%% Child (InstNref) -> Parent (5) with char=27
	{atomic, ChildOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, InstNref,
			#relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= 5 andalso
		R#relationship.characterization =:= 27 andalso
		R#relationship.reciprocal =:= 28
	end, ChildOut)).


%%=============================================================================
%% Relationship Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% add_relationship writes two directed rows.
%%-----------------------------------------------------------------------------
add_relationship_basic(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B} = graphdb_instance:create_instance("B", ClassNref, 5),
	%% Create a relationship attribute pair for testing
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute("Makes", "MadeBy", instance),
	RelsBefore = mnesia:table_info(relationships, size),
	ok = graphdb_instance:add_relationship(A, MakesNref, B, MadeByNref),
	RelsAfter = mnesia:table_info(relationships, size),
	?assertEqual(RelsBefore + 2, RelsAfter).

%%-----------------------------------------------------------------------------
%% add_relationship creates both forward and reverse arcs.
%%-----------------------------------------------------------------------------
add_relationship_both_directions(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, Ford} = graphdb_instance:create_instance("Ford", ClassNref, 5),
	{ok, Taurus} = graphdb_instance:create_instance("Taurus", ClassNref, 5),
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute("Makes", "MadeBy", instance),
	ok = graphdb_instance:add_relationship(Ford, MakesNref, Taurus, MadeByNref),

	%% Ford -> Taurus (char=Makes, reciprocal=MadeBy)
	{atomic, FordOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Ford, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Taurus andalso
		R#relationship.characterization =:= MakesNref andalso
		R#relationship.reciprocal =:= MadeByNref
	end, FordOut)),

	%% Taurus -> Ford (char=MadeBy, reciprocal=Makes)
	{atomic, TaurusOut} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Taurus, #relationship.source_nref)
	end),
	?assert(lists:any(fun(R) ->
		R#relationship.target_nref =:= Ford andalso
		R#relationship.characterization =:= MadeByNref andalso
		R#relationship.reciprocal =:= MakesNref
	end, TaurusOut)).


%%=============================================================================
%% Lookup Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_instance returns an instance node.
%%-----------------------------------------------------------------------------
get_instance_returns_node(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Widget", 3),
	{ok, InstNref} = graphdb_instance:create_instance("W1", ClassNref, 5),
	{ok, Node} = graphdb_instance:get_instance(InstNref),
	?assertEqual(InstNref, Node#node.nref),
	?assertEqual(instance, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_instance returns {error, not_found} for unknown nref.
%%-----------------------------------------------------------------------------
get_instance_not_found(_Config) ->
	?assertEqual({error, not_found}, graphdb_instance:get_instance(99999)).

%%-----------------------------------------------------------------------------
%% get_instance rejects non-instance nodes.
%%-----------------------------------------------------------------------------
get_instance_rejects_non_instance(_Config) ->
	%% Nref 1 (Root) is a category
	?assertEqual({error, not_an_instance}, graphdb_instance:get_instance(1)).


%%=============================================================================
%% Hierarchy Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% children returns direct instance-kind children.
%%-----------------------------------------------------------------------------
children_returns_instance_children(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Car", 3),
	{ok, Car} = graphdb_instance:create_instance("MyCar", ClassNref, 5),
	{ok, Engine} = graphdb_instance:create_instance("Engine1", ClassNref, Car),
	{ok, Wheel} = graphdb_instance:create_instance("Wheel1", ClassNref, Car),
	{ok, Kids} = graphdb_instance:children(Car),
	KidNrefs = lists:sort([N#node.nref || N <- Kids]),
	?assertEqual(lists:sort([Engine, Wheel]), KidNrefs).

%%-----------------------------------------------------------------------------
%% children returns empty list for a leaf instance.
%%-----------------------------------------------------------------------------
children_empty_for_leaf(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Leaf", 3),
	{ok, Leaf} = graphdb_instance:create_instance("Leaf1", ClassNref, 5),
	?assertEqual({ok, []}, graphdb_instance:children(Leaf)).

%%-----------------------------------------------------------------------------
%% compositional_ancestors returns the chain in nearest-first order.
%%-----------------------------------------------------------------------------
ancestors_returns_chain(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, Car} = graphdb_instance:create_instance("Car", ClassNref, 5),
	{ok, Engine} = graphdb_instance:create_instance("Engine", ClassNref, Car),
	{ok, Block} = graphdb_instance:create_instance("Block", ClassNref, Engine),
	{ok, Ancestors} = graphdb_instance:compositional_ancestors(Block),
	AncNrefs = [N#node.nref || N <- Ancestors],
	%% Nearest-first: Engine, then Car
	?assertEqual([Engine, Car], AncNrefs).

%%-----------------------------------------------------------------------------
%% compositional_ancestors returns empty for top-level instance (parent
%% is a non-instance node like a category).
%%-----------------------------------------------------------------------------
ancestors_empty_for_top_level(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Top", 3),
	{ok, Top} = graphdb_instance:create_instance("Top1", ClassNref, 5),
	?assertEqual({ok, []}, graphdb_instance:compositional_ancestors(Top)).


%%=============================================================================
%% Inheritance Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% resolve_value finds a value in the instance's own AVPs.
%%-----------------------------------------------------------------------------
resolve_value_local(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, InstNref} = graphdb_instance:create_instance("T1", ClassNref, 5),
	%% The name attribute (20) was set by create_instance
	?assertEqual({ok, "T1"}, graphdb_instance:resolve_value(InstNref, 20)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from the class node's AVPs.
%%-----------------------------------------------------------------------------
resolve_value_from_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	%% Add a custom AVP directly to the class node
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("shade", string),
	set_avp(ClassNref, TestAttr, "blue"),
	{ok, InstNref} = graphdb_instance:create_instance("C1", ClassNref, 5),
	%% Instance doesn't have shade — resolved from class
	?assertEqual({ok, "blue"},
		graphdb_instance:resolve_value(InstNref, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from a compositional ancestor.
%%-----------------------------------------------------------------------------
resolve_value_from_ancestor(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("location", string),
	{ok, Car} = graphdb_instance:create_instance("Car", ClassNref, 5),
	set_avp(Car, TestAttr, "garage"),
	{ok, Engine} = graphdb_instance:create_instance("Engine", ClassNref, Car),
	{ok, Block} = graphdb_instance:create_instance("Block", ClassNref, Engine),
	%% Block doesn't have location, Engine doesn't — resolved from Car
	?assertEqual({ok, "garage"},
		graphdb_instance:resolve_value(Block, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value finds a value from a directly connected node.
%%-----------------------------------------------------------------------------
resolve_value_from_connected(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("country", string),
	{ok, Ford} = graphdb_instance:create_instance("Ford", ClassNref, 5),
	set_avp(Ford, TestAttr, "USA"),
	{ok, Taurus} = graphdb_instance:create_instance("Taurus", ClassNref, 5),
	{ok, {MakesNref, MadeByNref}} =
		graphdb_attr:create_relationship_attribute("Makes", "MadeBy", instance),
	ok = graphdb_instance:add_relationship(Taurus, MadeByNref, Ford, MakesNref),
	%% Taurus doesn't have country, its class doesn't, no ancestors have it
	%% — resolved from connected Ford
	?assertEqual({ok, "USA"},
		graphdb_instance:resolve_value(Taurus, TestAttr)).

%%-----------------------------------------------------------------------------
%% resolve_value returns not_found when attribute is nowhere.
%%-----------------------------------------------------------------------------
resolve_value_not_found(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Empty", 3),
	{ok, InstNref} = graphdb_instance:create_instance("E1", ClassNref, 5),
	?assertEqual(not_found,
		graphdb_instance:resolve_value(InstNref, 99999)).

%%-----------------------------------------------------------------------------
%% Priority: local value overrides class-level value.
%%-----------------------------------------------------------------------------
resolve_value_priority_local_over_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Color", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("hue", string),
	set_avp(ClassNref, TestAttr, "class_hue"),
	{ok, InstNref} = graphdb_instance:create_instance("C1", ClassNref, 5),
	set_avp(InstNref, TestAttr, "local_hue"),
	?assertEqual({ok, "local_hue"},
		graphdb_instance:resolve_value(InstNref, TestAttr)).

%%-----------------------------------------------------------------------------
%% Priority: class-level value overrides compositional ancestor value.
%%-----------------------------------------------------------------------------
resolve_value_priority_class_over_ancestor(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Part", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("weight", string),
	set_avp(ClassNref, TestAttr, "class_weight"),
	{ok, Parent} = graphdb_instance:create_instance("P1", ClassNref, 5),
	set_avp(Parent, TestAttr, "parent_weight"),
	{ok, Child} = graphdb_instance:create_instance("C1", ClassNref, Parent),
	%% Child has no local value; class has weight; parent has weight
	%% Class (priority 2) should win over parent (priority 3)
	?assertEqual({ok, "class_weight"},
		graphdb_instance:resolve_value(Child, TestAttr)).

%%-----------------------------------------------------------------------------
%% Priority: ancestor value overrides directly-connected-node value.
%%-----------------------------------------------------------------------------
resolve_value_priority_ancestor_over_connected(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Org", 3),
	{ok, TestAttr} = graphdb_attr:create_literal_attribute("region", string),
	{ok, Parent} = graphdb_instance:create_instance("Parent", ClassNref, 5),
	set_avp(Parent, TestAttr, "ancestor_region"),
	{ok, Child} = graphdb_instance:create_instance("Child", ClassNref, Parent),
	{ok, Peer} = graphdb_instance:create_instance("Peer", ClassNref, 5),
	set_avp(Peer, TestAttr, "peer_region"),
	{ok, {LinksNref, LinkedByNref}} =
		graphdb_attr:create_relationship_attribute("Links", "LinkedBy", instance),
	ok = graphdb_instance:add_relationship(Child, LinksNref, Peer, LinkedByNref),
	%% Child has no local value, class has no value
	%% Ancestor Parent (priority 3) should win over connected Peer (priority 4)
	?assertEqual({ok, "ancestor_region"},
		graphdb_instance:resolve_value(Child, TestAttr)).


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


%%-----------------------------------------------------------------------------
%% set_avp(Nref, AttrNref, Value) -> ok
%%
%% Appends an AVP to the node's existing attribute_value_pairs.
%% Used by tests to inject values for inheritance testing.
%%-----------------------------------------------------------------------------
set_avp(Nref, AttrNref, Value) ->
	{atomic, ok} = mnesia:transaction(fun() ->
		[Node] = mnesia:read(nodes, Nref),
		AVPs = Node#node.attribute_value_pairs,
		NewAVP = #{attribute => AttrNref, value => Value},
		Updated = Node#node{attribute_value_pairs = AVPs ++ [NewAVP]},
		ok = mnesia:write(nodes, Updated, write)
	end),
	ok.


-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "instance_").


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
