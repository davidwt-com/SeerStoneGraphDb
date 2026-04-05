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
%% Description: Common Test integration suite for graphdb_mgr.
%%				Each test case gets an isolated Mnesia database and
%%				fresh nref allocator state in a private temp directory.
%%				Tests verify init/1 bootstrap wiring, read operations,
%%				category immutability guard, and write operation API
%%				skeleton.
%%---------------------------------------------------------------------
-module(graphdb_mgr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb_mgr/bootstrap internal records)
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
	%% Bootstrap/init
	init_runs_bootstrap/1,
	init_idempotent_restart/1,
	init_fails_on_bad_config/1,
	%% get_node
	get_node_root/1,
	get_node_attribute/1,
	get_node_not_found/1,
	%% get_relationships
	get_relationships_outgoing/1,
	get_relationships_incoming/1,
	get_relationships_both/1,
	get_relationships_empty/1,
	%% Category guard
	category_guard_delete/1,
	category_guard_update/1,
	category_guard_allows_noncategory_delete/1,
	category_guard_allows_noncategory_update/1,
	category_guard_delete_nonexistent/1,
	%% Write stubs
	create_attribute_not_implemented/1,
	create_class_not_implemented/1,
	create_instance_not_implemented/1,
	add_relationship_not_implemented/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, init_tests}, {group, read_ops},
	 {group, category_guard}, {group, write_stubs}].

groups() ->
	[
		{init_tests, [], [
			init_runs_bootstrap,
			init_idempotent_restart,
			init_fails_on_bad_config
		]},
		{read_ops, [], [
			get_node_root,
			get_node_attribute,
			get_node_not_found,
			get_relationships_outgoing,
			get_relationships_incoming,
			get_relationships_both,
			get_relationships_empty
		]},
		{category_guard, [], [
			category_guard_delete,
			category_guard_update,
			category_guard_allows_noncategory_delete,
			category_guard_allows_noncategory_update,
			category_guard_delete_nonexistent
		]},
		{write_stubs, [], [
			create_attribute_not_implemented,
			create_class_not_implemented,
			create_instance_not_implemented,
			add_relationship_not_implemented
		]}
	].


%%-----------------------------------------------------------------------------
%% init_per_suite/1
%%
%% Saves the original working directory and computes the absolute path
%% to bootstrap.terms via code:priv_dir (works regardless of cwd).
%%-----------------------------------------------------------------------------
init_per_suite(Config) ->
	{ok, OrigCwd} = file:get_cwd(),
	ok = case application:load(graphdb) of
		ok -> ok;
		{error, {already_loaded, graphdb}} -> ok
	end,
	PrivDir = code:priv_dir(graphdb),
	BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
	true = filelib:is_file(BootstrapFile),
	[{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) ->
	ok.


%%-----------------------------------------------------------------------------
%% init_per_testcase/2
%%
%% Creates an isolated temp directory, changes cwd so nref DETS files
%% go there, configures a private Mnesia dir, sets the bootstrap_file
%% env, starts nref, and (for most tests) starts graphdb_mgr.
%%-----------------------------------------------------------------------------
init_per_testcase(init_fails_on_bad_config, Config) ->
	%% Special setup for error test -- bad bootstrap path
	Config1 = setup_isolated_env(Config),
	BadPath = filename:join(proplists:get_value(tmp_dir, Config1),
		"does_not_exist.terms"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadPath),
	Config1;
init_per_testcase(_TC, Config) ->
	Config1 = setup_isolated_env(Config),
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
	Config1.

setup_isolated_env(Config) ->
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"mgr_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	%% Change cwd so nref DETS files are created in the temp dir
	ok = file:set_cwd(TmpDir),

	%% Configure Mnesia to use the private directory
	application:set_env(mnesia, dir, MnesiaDir),

	%% Start nref fresh (DETS files created in TmpDir)
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%
%% Stops graphdb_mgr, nref, Mnesia, restores cwd, and deletes temp dir.
%%-----------------------------------------------------------------------------
end_per_testcase(_TC, Config) ->
	%% Stop graphdb_mgr if running
	catch gen_server:stop(graphdb_mgr),

	%% Stop applications (ignore errors -- they may not be running)
	catch application:stop(nref),
	catch mnesia:stop(),

	%% Close any lingering DETS tables
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),

	%% Restore original cwd
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),

	%% Delete the temp directory recursively
	TmpDir = proplists:get_value(tmp_dir, Config),
	delete_dir_recursive(TmpDir),

	%% Unset app env to avoid leaking between test cases
	application:unset_env(seerstone_graph_db, bootstrap_file),
	application:unset_env(mnesia, dir),

	ok.


%%=============================================================================
%% Init/Bootstrap Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Verify that starting graphdb_mgr triggers bootstrap load.
%%-----------------------------------------------------------------------------
init_runs_bootstrap(_Config) ->
	{ok, _Pid} = graphdb_mgr:start_link(),
	%% Tables should exist
	?assert(lists:member(nodes, mnesia:system_info(tables))),
	?assert(lists:member(relationships, mnesia:system_info(tables))),
	%% 30 nodes and 58 relationship rows should be loaded
	?assertEqual(30, mnesia:table_info(nodes, size)),
	?assertEqual(58, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% Verify that stopping and restarting graphdb_mgr is idempotent --
%% bootstrap does not reload or duplicate data.
%%-----------------------------------------------------------------------------
init_idempotent_restart(_Config) ->
	{ok, _Pid1} = graphdb_mgr:start_link(),
	NodesBefore = mnesia:table_info(nodes, size),
	RelsBefore = mnesia:table_info(relationships, size),

	%% Stop and restart
	ok = gen_server:stop(graphdb_mgr),
	{ok, _Pid2} = graphdb_mgr:start_link(),

	?assertEqual(NodesBefore, mnesia:table_info(nodes, size)),
	?assertEqual(RelsBefore, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% Verify that init fails if bootstrap fails (bad file path).
%% Must trap exits because start_link propagates the gen_server exit.
%%-----------------------------------------------------------------------------
init_fails_on_bad_config(_Config) ->
	process_flag(trap_exit, true),
	Result = graphdb_mgr:start_link(),
	?assertMatch({error, {bootstrap_failed, _}}, Result),
	%% Flush the EXIT message from the linked gen_server
	receive {'EXIT', _, _} -> ok after 1000 -> ok end.


%%=============================================================================
%% Read Operation Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% get_node returns Root (nref 1) correctly.
%%-----------------------------------------------------------------------------
get_node_root(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Root} = graphdb_mgr:get_node(1),
	?assertEqual(1, Root#node.nref),
	?assertEqual(category, Root#node.kind),
	?assertEqual(undefined, Root#node.parent),
	?assertEqual([#{attribute => 17, value => "Root"}],
		Root#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% get_node returns an attribute node (nref 18 -- Name, self-ref) correctly.
%%-----------------------------------------------------------------------------
get_node_attribute(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Node} = graphdb_mgr:get_node(18),
	?assertEqual(18, Node#node.nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual(10, Node#node.parent),    %% parent: Attribute Name Attributes
	?assertEqual([#{attribute => 18, value => "Name"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% get_node returns {error, not_found} for nonexistent nref.
%%-----------------------------------------------------------------------------
get_node_not_found(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_found}, graphdb_mgr:get_node(99999)).

%%-----------------------------------------------------------------------------
%% get_relationships returns outgoing arcs for Root.
%% Root has outgoing child arcs to 2, 3, 4, 5 (characterization=22).
%%-----------------------------------------------------------------------------
get_relationships_outgoing(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(1),
	Targets = lists:sort([R#relationship.target_nref || R <- Rels]),
	?assertEqual([2, 3, 4, 5], Targets),
	%% All should have characterization=22 (Child/CatRel)
	?assert(lists:all(fun(R) ->
		R#relationship.characterization =:= 22
	end, Rels)).

%%-----------------------------------------------------------------------------
%% get_relationships with incoming direction.
%% Attributes(2) has incoming arcs from:
%%   Root(1)  -- child arc (char=22)
%%   Names(6), Literals(7), Relationships(8) -- parent arcs (char=23)
%%-----------------------------------------------------------------------------
get_relationships_incoming(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(2, incoming),
	Sources = lists:sort([R#relationship.source_nref || R <- Rels]),
	?assertEqual([1, 6, 7, 8], Sources).

%%-----------------------------------------------------------------------------
%% get_relationships with both directions -- should be union of out + in.
%%-----------------------------------------------------------------------------
get_relationships_both(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, OutRels} = graphdb_mgr:get_relationships(2, outgoing),
	{ok, InRels} = graphdb_mgr:get_relationships(2, incoming),
	{ok, BothRels} = graphdb_mgr:get_relationships(2, both),
	?assertEqual(length(OutRels) + length(InRels), length(BothRels)).

%%-----------------------------------------------------------------------------
%% get_relationships returns empty list for nonexistent node.
%%-----------------------------------------------------------------------------
get_relationships_empty(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	{ok, Rels} = graphdb_mgr:get_relationships(99999, outgoing),
	?assertEqual([], Rels).


%%=============================================================================
%% Category Guard Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% delete_node rejects category nodes (Root=1, Attributes=2).
%%-----------------------------------------------------------------------------
category_guard_delete(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:delete_node(1)),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:delete_node(2)).

%%-----------------------------------------------------------------------------
%% update_node_avps rejects category nodes.
%%-----------------------------------------------------------------------------
category_guard_update(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, category_nodes_are_immutable},
		graphdb_mgr:update_node_avps(1, [#{attribute => 99, value => "test"}])).

%%-----------------------------------------------------------------------------
%% delete_node passes guard for non-category nodes (returns not_implemented).
%%-----------------------------------------------------------------------------
category_guard_allows_noncategory_delete(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute node -- should pass guard
	?assertEqual({error, not_implemented},
		graphdb_mgr:delete_node(6)).

%%-----------------------------------------------------------------------------
%% update_node_avps passes guard for non-category nodes.
%%-----------------------------------------------------------------------------
category_guard_allows_noncategory_update(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute node -- should pass guard
	?assertEqual({error, not_implemented},
		graphdb_mgr:update_node_avps(6, [#{attribute => 99, value => "test"}])).

%%-----------------------------------------------------------------------------
%% delete_node returns not_found for nonexistent node.
%%-----------------------------------------------------------------------------
category_guard_delete_nonexistent(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_found},
		graphdb_mgr:delete_node(99999)).


%%=============================================================================
%% Write Stub Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% create_attribute returns not_implemented.
%%-----------------------------------------------------------------------------
create_attribute_not_implemented(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_implemented},
		graphdb_mgr:create_attribute("TestAttr", 2, [])).

%%-----------------------------------------------------------------------------
%% create_class returns not_implemented.
%%-----------------------------------------------------------------------------
create_class_not_implemented(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_implemented},
		graphdb_mgr:create_class("TestClass", 3)).

%%-----------------------------------------------------------------------------
%% create_instance returns not_implemented.
%%-----------------------------------------------------------------------------
create_instance_not_implemented(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_implemented},
		graphdb_mgr:create_instance("TestInst", 100, 200)).

%%-----------------------------------------------------------------------------
%% add_relationship returns not_implemented.
%%-----------------------------------------------------------------------------
add_relationship_not_implemented(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	?assertEqual({error, not_implemented},
		graphdb_mgr:add_relationship(100, 22, 200, 21)).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Safe scratch directory for test isolation.  All temp dirs are created
%% under this path by init_per_testcase/2.
%%-----------------------------------------------------------------------------
-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "mgr_").


%%-----------------------------------------------------------------------------
%% delete_dir_recursive(Dir) -> ok | error({unsafe_delete, Dir})
%%
%% Recursively deletes a directory and all its contents.
%%
%% Safety: refuses to operate unless ALL of the following hold:
%%   1. Dir is an absolute path
%%   2. Dir contains the path segment "_build/test/ct_scratch/"
%%   3. The leaf directory name starts with "mgr_"
%%
%% These guards ensure this function can never be misused to delete
%% project source, home directories, or anything outside the test
%% scratch area, even if called with a wrong argument.
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
