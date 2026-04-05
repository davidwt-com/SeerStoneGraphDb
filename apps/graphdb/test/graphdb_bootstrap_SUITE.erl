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
%% Description: Common Test integration suite for graphdb_bootstrap.
%%				Each test case gets an isolated Mnesia database and
%%				fresh nref allocator state in a private temp directory.
%%				Tests verify the full load/0 flow including Mnesia
%%				schema creation, bootstrap data loading, and error
%%				handling.
%%---------------------------------------------------------------------
-module(graphdb_bootstrap_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb_bootstrap internal records)
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
	load_creates_tables/1,
	load_writes_all_nodes/1,
	load_writes_all_relationships/1,
	load_root_node_correct/1,
	load_attribute_node_correct/1,
	load_category_children/1,
	load_relationship_structure/1,
	load_relationship_ids_above_floor/1,
	load_relationship_reciprocal_pairs/1,
	load_nref_floor_set/1,
	load_idempotent/1,
	load_missing_config/1,
	load_nonexistent_file/1,
	load_invalid_terms/1,
	load_missing_nref_start/1,
	load_nref_above_floor/1
]).


%%=============================================================================
%% Common Test Callbacks
%%=============================================================================

suite() ->
	[{timetrap, {seconds, 30}}].

all() ->
	[{group, success}, {group, errors}].

groups() ->
	[
		{success, [sequence], [
			load_creates_tables,
			load_writes_all_nodes,
			load_writes_all_relationships,
			load_root_node_correct,
			load_attribute_node_correct,
			load_category_children,
			load_relationship_structure,
			load_relationship_ids_above_floor,
			load_relationship_reciprocal_pairs,
			load_nref_floor_set,
			load_idempotent
		]},
		{errors, [], [
			load_missing_config,
			load_nonexistent_file,
			load_invalid_terms,
			load_missing_nref_start,
			load_nref_above_floor
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
%% env, and starts the nref application fresh.
%%-----------------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
	%% Build a unique temp directory
	OrigCwd = proplists:get_value(orig_cwd, Config),
	Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
	TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
		"bootstrap_" ++ Unique]),
	MnesiaDir = filename:join(TmpDir, "mnesia"),
	ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),

	%% Change cwd so nref DETS files are created in the temp dir
	ok = file:set_cwd(TmpDir),

	%% Configure Mnesia to use the private directory
	application:set_env(mnesia, dir, MnesiaDir),

	%% Configure bootstrap_file (absolute path — cwd-independent)
	BootstrapFile = proplists:get_value(bootstrap_file, Config),
	application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),

	%% Start nref fresh (DETS files created in TmpDir)
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%
%% Stops nref, stops Mnesia, restores cwd, and deletes the temp dir.
%%-----------------------------------------------------------------------------
end_per_testcase(_TC, Config) ->
	%% Stop applications (ignore errors — they may not be running)
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
%% Success Test Cases
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Verify that load/0 creates the Mnesia tables.
%%-----------------------------------------------------------------------------
load_creates_tables(_Config) ->
	ok = graphdb_bootstrap:load(),
	%% Tables should exist and be accessible
	?assert(lists:member(nodes, mnesia:system_info(tables))),
	?assert(lists:member(relationships, mnesia:system_info(tables))).

%%-----------------------------------------------------------------------------
%% Verify exactly 30 nodes are loaded.
%%-----------------------------------------------------------------------------
load_writes_all_nodes(_Config) ->
	ok = graphdb_bootstrap:load(),
	?assertEqual(30, mnesia:table_info(nodes, size)).

%%-----------------------------------------------------------------------------
%% Verify exactly 58 relationship rows (29 pairs x 2 directions).
%%-----------------------------------------------------------------------------
load_writes_all_relationships(_Config) ->
	ok = graphdb_bootstrap:load(),
	?assertEqual(58, mnesia:table_info(relationships, size)).

%%-----------------------------------------------------------------------------
%% Verify the root node (nref 1) has correct structure.
%%-----------------------------------------------------------------------------
load_root_node_correct(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, [Root]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, 1)
	end),
	?assertEqual(1, Root#node.nref),
	?assertEqual(category, Root#node.kind),
	?assertEqual(undefined, Root#node.parent),
	?assertEqual([#{attribute => 17, value => "Root"}],
		Root#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Verify a specific attribute node (nref 18 — Name, self-referential).
%%-----------------------------------------------------------------------------
load_attribute_node_correct(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, [Node]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, 18)
	end),
	?assertEqual(18, Node#node.nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual(10, Node#node.parent),    %% parent: Attribute Name Attributes
	?assertEqual([#{attribute => 18, value => "Name"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Verify Root's children via the parent index.
%%-----------------------------------------------------------------------------
load_category_children(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, Children} = mnesia:transaction(fun() ->
		mnesia:index_read(nodes, 1, #node.parent)
	end),
	ChildNrefs = lists:sort([N#node.nref || N <- Children]),
	%% Root's children: Attributes(2), Classes(3), Languages(4), Projects(5)
	?assertEqual([2, 3, 4, 5], ChildNrefs),
	%% All are category nodes
	?assert(lists:all(fun(N) -> N#node.kind =:= category end, Children)).

%%-----------------------------------------------------------------------------
%% Verify relationship row structure for Root -> Attributes arc.
%%-----------------------------------------------------------------------------
load_relationship_structure(_Config) ->
	ok = graphdb_bootstrap:load(),
	%% Find forward arc: Root(1) -> Attributes(2) with characterization=22 (Child/CatRel)
	{atomic, Fwd} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 1, #relationship.source_nref)
	end),
	ChildArcs = [R || R <- Fwd,
		R#relationship.characterization =:= 22,
		R#relationship.target_nref =:= 2],
	?assertEqual(1, length(ChildArcs)),
	[Arc] = ChildArcs,
	?assertEqual(21, Arc#relationship.reciprocal),
	?assertEqual([], Arc#relationship.avps).

%%-----------------------------------------------------------------------------
%% Verify all relationship IDs are >= 10000 (nref_start floor).
%%-----------------------------------------------------------------------------
load_relationship_ids_above_floor(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, AllRels} = mnesia:transaction(fun() ->
		mnesia:foldl(fun(Rec, Acc) -> [Rec | Acc] end, [], relationships)
	end),
	?assertEqual(58, length(AllRels)),
	BelowFloor = [R || R <- AllRels, R#relationship.id < 10000],
	?assertEqual([], BelowFloor).

%%-----------------------------------------------------------------------------
%% Verify every forward arc has a matching reverse arc (reciprocal pair).
%%-----------------------------------------------------------------------------
load_relationship_reciprocal_pairs(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, AllRels} = mnesia:transaction(fun() ->
		mnesia:foldl(fun(Rec, Acc) -> [Rec | Acc] end, [], relationships)
	end),
	%% For each row, there must be a row going the other direction
	lists:foreach(fun(R) ->
		Reverse = [Rev || Rev <- AllRels,
			Rev#relationship.source_nref =:= R#relationship.target_nref,
			Rev#relationship.target_nref =:= R#relationship.source_nref,
			Rev#relationship.characterization =:= R#relationship.reciprocal,
			Rev#relationship.reciprocal =:= R#relationship.characterization],
		?assertNotEqual([], Reverse,
			{missing_reciprocal,
				R#relationship.source_nref,
				R#relationship.characterization,
				R#relationship.target_nref})
	end, AllRels).

%%-----------------------------------------------------------------------------
%% Verify the nref floor was set: next nref from nref_server is >= 10000.
%%-----------------------------------------------------------------------------
load_nref_floor_set(_Config) ->
	ok = graphdb_bootstrap:load(),
	%% 29 relationship pairs = 58 IDs consumed, starting at 10000
	%% Next nref should be >= 10058
	NextNref = nref_server:get_nref(),
	?assert(NextNref >= 10058).

%%-----------------------------------------------------------------------------
%% Verify load/0 is idempotent: calling it again does not duplicate data.
%%-----------------------------------------------------------------------------
load_idempotent(_Config) ->
	ok = graphdb_bootstrap:load(),
	NodesBefore = mnesia:table_info(nodes, size),
	RelsBefore = mnesia:table_info(relationships, size),

	%% Second call should be a no-op (table already populated)
	ok = graphdb_bootstrap:load(),
	NodesAfter = mnesia:table_info(nodes, size),
	RelsAfter = mnesia:table_info(relationships, size),

	?assertEqual(NodesBefore, NodesAfter),
	?assertEqual(RelsBefore, RelsAfter).


%%=============================================================================
%% Error Test Cases
%%=============================================================================

%%-----------------------------------------------------------------------------
%% load/0 with no bootstrap_file in app env returns an error.
%%-----------------------------------------------------------------------------
load_missing_config(_Config) ->
	application:unset_env(seerstone_graph_db, bootstrap_file),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {missing_config, bootstrap_file}}, Result).

%%-----------------------------------------------------------------------------
%% load/0 with a nonexistent file returns an error.
%%-----------------------------------------------------------------------------
load_nonexistent_file(Config) ->
	TmpDir = proplists:get_value(tmp_dir, Config),
	BadPath = filename:join(TmpDir, "does_not_exist.terms"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadPath),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {consult_failed, _, _}}, Result).

%%-----------------------------------------------------------------------------
%% load/0 with a file containing invalid terms returns an error.
%%-----------------------------------------------------------------------------
load_invalid_terms(Config) ->
	TmpDir = proplists:get_value(tmp_dir, Config),
	BadFile = filename:join(TmpDir, "bad.terms"),
	ok = file:write_file(BadFile,
		"{nref_start, 100}.\n{bogus, stuff}.\n"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadFile),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {unknown_term, {bogus, stuff}}}, Result).

%%-----------------------------------------------------------------------------
%% load/0 with a file missing the nref_start directive.
%%-----------------------------------------------------------------------------
load_missing_nref_start(Config) ->
	TmpDir = proplists:get_value(tmp_dir, Config),
	BadFile = filename:join(TmpDir, "no_floor.terms"),
	ok = file:write_file(BadFile,
		"{node, 1, category, undefined, {17, \"Root\"}, []}.\n"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadFile),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, missing_nref_start}, Result).

%%-----------------------------------------------------------------------------
%% load/0 with a node whose nref >= nref_start.
%%-----------------------------------------------------------------------------
load_nref_above_floor(Config) ->
	TmpDir = proplists:get_value(tmp_dir, Config),
	BadFile = filename:join(TmpDir, "above_floor.terms"),
	ok = file:write_file(BadFile,
		"{nref_start, 10}.\n"
		"{node, 10, category, undefined, {17, \"Root\"}, []}.\n"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadFile),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {nref_not_below_floor, 10, 10}}, Result).


%%=============================================================================
%% Internal Helpers
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Safe scratch directory for test isolation.  All temp dirs are created
%% under this path by init_per_testcase/2.
%%-----------------------------------------------------------------------------
-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "bootstrap_").


%%-----------------------------------------------------------------------------
%% delete_dir_recursive(Dir) -> ok | error({unsafe_delete, Dir})
%%
%% Recursively deletes a directory and all its contents.
%%
%% Safety: refuses to operate unless ALL of the following hold:
%%   1. Dir is an absolute path
%%   2. Dir contains the path segment "_build/test/ct_scratch/"
%%   3. The leaf directory name starts with "bootstrap_"
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
