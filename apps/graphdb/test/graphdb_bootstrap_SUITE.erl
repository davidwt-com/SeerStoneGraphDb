%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
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
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Record definitions (match graphdb_bootstrap internal records)
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
	load_creates_tables/1,
	load_writes_all_nodes/1,
	load_writes_all_relationships/1,
	load_root_node_correct/1,
	load_attribute_node_correct/1,
	load_template_avp_node_correct/1,
	load_language_subcategories/1,
	load_category_children/1,
	load_relationship_structure/1,
	load_relationship_ids_above_floor/1,
	load_relationship_reciprocal_pairs/1,
	load_idempotent/1,
	load_english_instance/1,
	load_labeled_nodes/1,
	load_english_class_membership/1,
	load_missing_config/1,
	load_nonexistent_file/1,
	load_invalid_terms/1,
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
			load_template_avp_node_correct,
			load_language_subcategories,
			load_category_children,
			load_relationship_structure,
			load_relationship_ids_above_floor,
			load_relationship_reciprocal_pairs,
			load_idempotent,
			load_english_instance,
			load_labeled_nodes,
			load_english_class_membership
		]},
		{errors, [], [
			load_missing_config,
			load_nonexistent_file,
			load_invalid_terms,
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

	%% Start rel_id_server (needed for relationship ID allocation in bootstrap)
	{ok, _} = rel_id_server:start_link(),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].


%%-----------------------------------------------------------------------------
%% end_per_testcase/2
%%
%% Stops nref, stops Mnesia, restores cwd, and deletes the temp dir.
%%-----------------------------------------------------------------------------
end_per_testcase(TC, Config) ->
	verify_cache_invariant(TC),

	%% Stop applications (ignore errors — they may not be running)
	catch gen_server:stop(rel_id_server),
	catch application:stop(nref),
	catch mnesia:stop(),

	%% Defensive: clear the graphdb_nref phase flag in case a prior suite
	%% in the same VM left it set (this suite never sets it itself).
	catch persistent_term:erase({graphdb_nref, phase}),

	%% Close any lingering DETS tables
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
	catch dets:close(rel_id_server),

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
%% Verify exactly 38 nodes are loaded:
%%   nrefs 1–35 (scaffold), nref 10000 (English permanent), plus
%%   2 labeled permanent nodes (lang_code, lang_human — nrefs assigned
%%   from the loader's local counter starting at label_start = 10001).
%%-----------------------------------------------------------------------------
load_writes_all_nodes(_Config) ->
	ok = graphdb_bootstrap:load(),
	?assertEqual(38, mnesia:table_info(nodes, size)).

%%-----------------------------------------------------------------------------
%% Verify exactly 76 relationship rows (38 pairs x 2 directions).
%%   34 original + 4 new (Literals->lang_code, Classes->lang_human,
%%                        English->lang_human, HumanLanguages->English)
%%-----------------------------------------------------------------------------
load_writes_all_relationships(_Config) ->
	ok = graphdb_bootstrap:load(),
	?assertEqual(76, mnesia:table_info(relationships, size)).

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
	?assertEqual([], Root#node.parents),
	?assertEqual([#{attribute => ?NAME_ATTR_CATEGORY, value => "Root"}],
		Root#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Verify a specific attribute node (nref 18 — Name, self-referential).
%%-----------------------------------------------------------------------------
load_attribute_node_correct(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, [Node]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, ?NAME_ATTR_ATTRIBUTE)
	end),
	?assertEqual(18, Node#node.nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual([10], Node#node.parents),    %% parent: Attribute Name Attributes
	?assertEqual([#{attribute => ?NAME_ATTR_ATTRIBUTE, value => "Name"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Verify the Template AVP marker node (nref 31) — added in C3a as the
%% Connection-arc scope marker.  Pre-graphdb_attr-init it has just the
%% name AVP; the relationship_avp marker is stamped by graphdb_attr.
%%-----------------------------------------------------------------------------
load_template_avp_node_correct(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, [Node]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, ?ARC_TEMPLATE)
	end),
	?assertEqual(?ARC_TEMPLATE, Node#node.nref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual([16], Node#node.parents),    %% Instance Relationships subtree
	?assertEqual([#{attribute => ?NAME_ATTR_ATTRIBUTE, value => "Template"}],
		Node#node.attribute_value_pairs).

%%-----------------------------------------------------------------------------
%% Verify the four Language subcategory nodes (nrefs 32-35) under Languages (4).
%%-----------------------------------------------------------------------------
load_language_subcategories(_Config) ->
	ok = graphdb_bootstrap:load(),
	Expected = [
		{?NREF_HUMAN_LANGS,  "Human Languages"},
		{?NREF_FORMAL_LANGS, "Formal Languages"},
		{?NREF_DIAGRAM_LANGS,"Diagram Languages"},
		{?NREF_RENDERERS,    "Renderers"}
	],
	lists:foreach(fun({Nref, Name}) ->
		{atomic, [Node]} = mnesia:transaction(fun() ->
			mnesia:read(nodes, Nref)
		end),
		?assertEqual(Nref,     Node#node.nref),
		?assertEqual(category, Node#node.kind),
		?assertEqual([4],      Node#node.parents),
		?assertEqual([#{attribute => ?NAME_ATTR_CATEGORY, value => Name}],
			Node#node.attribute_value_pairs)
	end, Expected),
	%% Languages (nref 4) has exactly these four children via char=22 (Child/CatRel)
	{atomic, ChildArcs} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 4, #relationship.source_nref)
	end),
	ChildNrefs = lists:sort([A#relationship.target_nref ||
		A <- ChildArcs,
		A#relationship.kind =:= composition,
		A#relationship.characterization =:= ?ARC_CAT_CHILD]),
	?assertEqual([?NREF_HUMAN_LANGS, ?NREF_FORMAL_LANGS, ?NREF_DIAGRAM_LANGS, ?NREF_RENDERERS], ChildNrefs).

%%-----------------------------------------------------------------------------
%% Verify Root's children via the compositional arcs (char=22, kind=composition).
%%-----------------------------------------------------------------------------
load_category_children(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, Arcs} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 1, #relationship.source_nref)
	end),
	ChildNrefs = lists:sort([A#relationship.target_nref ||
		A <- Arcs,
		A#relationship.kind =:= composition,
		A#relationship.characterization =:= ?ARC_CAT_CHILD]),
	%% Root's children: Attributes(2), Classes(3), Languages(4), Projects(5)
	?assertEqual([2, 3, 4, 5], ChildNrefs),
	%% Each child node is a category and lists Root in its parents cache
	{atomic, Children} = mnesia:transaction(fun() ->
		[hd(mnesia:read(nodes, N)) || N <- ChildNrefs]
	end),
	?assert(lists:all(fun(N) -> N#node.kind =:= category end, Children)),
	?assert(lists:all(fun(N) -> N#node.parents =:= [1] end, Children)).

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
		R#relationship.characterization =:= ?ARC_CAT_CHILD,
		R#relationship.target_nref =:= 2],
	?assertEqual(1, length(ChildArcs)),
	[Arc] = ChildArcs,
	?assertEqual(?ARC_CAT_PARENT, Arc#relationship.reciprocal),
	?assertEqual([], Arc#relationship.avps).

%%-----------------------------------------------------------------------------
%% Verify all relationship IDs are unique positive integers (from rel_id_server).
%% rel_id_server is a separate allocator, so IDs start at 1, not at nref_start.
%%-----------------------------------------------------------------------------
load_relationship_ids_above_floor(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, AllRels} = mnesia:transaction(fun() ->
		mnesia:foldl(fun(Rec, Acc) -> [Rec | Acc] end, [], relationships)
	end),
	?assertEqual(76, length(AllRels)),
	%% Verify all IDs are unique and positive
	IDs = [R#relationship.id || R <- AllRels],
	?assertEqual(length(IDs), sets:size(sets:from_list(IDs))),
	AllPositive = lists:all(fun(ID) -> ID > 0 end, IDs),
	?assertEqual(true, AllPositive).

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


%%-----------------------------------------------------------------------------
%% Verify the English permanent instance node (nref 10000).
%%-----------------------------------------------------------------------------
load_english_instance(_Config) ->
	ok = graphdb_bootstrap:load(),
	{atomic, [Eng]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, ?NREF_ENGLISH)
	end),
	?assertEqual(?NREF_ENGLISH, Eng#node.nref),
	?assertEqual(instance, Eng#node.kind),
	%% Find lang_code attribute nref by name (do not hardcode the assigned nref)
	LangCodeNref = find_attribute_nref_by_name("lang_code"),
	?assert(LangCodeNref > ?NREF_ENGLISH),
	?assert(LangCodeNref < ?NREF_START),
	?assert(lists:member(#{attribute => LangCodeNref, value => en},
		Eng#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% Verify that labeled nodes (lang_code, lang_human) exist with permanent-
%% tier nrefs immediately above English (10001+, below nref_start = 1000000).
%%-----------------------------------------------------------------------------
load_labeled_nodes(_Config) ->
	ok = graphdb_bootstrap:load(),
	LangCodeNref = find_attribute_nref_by_name("lang_code"),
	?assert(LangCodeNref > ?NREF_ENGLISH),
	?assert(LangCodeNref < ?NREF_START),
	LangHumanNref = find_class_nref_by_name("Human Language"),
	?assert(LangHumanNref > ?NREF_ENGLISH),
	?assert(LangHumanNref < ?NREF_START).

%%-----------------------------------------------------------------------------
%% Verify English's class membership arc and the classes cache.
%%-----------------------------------------------------------------------------
load_english_class_membership(_Config) ->
	ok = graphdb_bootstrap:load(),
	LangHumanNref = find_class_nref_by_name("Human Language"),
	%% English's classes cache must contain LangHuman nref
	{atomic, [Eng]} = mnesia:transaction(fun() ->
		mnesia:read(nodes, ?NREF_ENGLISH)
	end),
	?assert(lists:member(LangHumanNref, Eng#node.classes)),
	%% English's compositional parent is Human Languages (nref 32)
	?assertEqual([?NREF_HUMAN_LANGS], Eng#node.parents),
	%% Instantiation arc English -> Human Language exists
	{atomic, MemberArcs} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, ?NREF_ENGLISH, #relationship.source_nref)
	end),
	ClassArcs = [A || A <- MemberArcs,
		A#relationship.kind =:= instantiation,
		A#relationship.characterization =:= ?ARC_INST_TO_CLASS,
		A#relationship.target_nref =:= LangHumanNref],
	?assertEqual(1, length(ClassArcs)).


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
	ok = file:write_file(BadFile, "{bogus, stuff}.\n"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadFile),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {unknown_term, {bogus, stuff}}}, Result).

%%-----------------------------------------------------------------------------
%% load/0 with a node whose nref >= ?NREF_START.
%%-----------------------------------------------------------------------------
load_nref_above_floor(Config) ->
	TmpDir = proplists:get_value(tmp_dir, Config),
	BadFile = filename:join(TmpDir, "above_floor.terms"),
	ok = file:write_file(BadFile,
		"{node, 1000000, category, {17, \"X\"}, []}.\n"),
	application:set_env(seerstone_graph_db, bootstrap_file, BadFile),
	Result = graphdb_bootstrap:load(),
	?assertMatch({error, {nref_not_below_floor, ?NREF_START, ?NREF_START}}, Result).


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

%%-----------------------------------------------------------------------------
%% find_attribute_nref_by_name(Name) -> integer()
%%
%% Scans the nodes table for an attribute node whose name AVP has the
%% given string value.  Uses NameAttrNref=18 (attribute-node Name).
%%-----------------------------------------------------------------------------
find_attribute_nref_by_name(Name) ->
	{atomic, Matches} = mnesia:transaction(fun() ->
		mnesia:foldl(fun(N, Acc) ->
			case N#node.kind =:= attribute andalso
			     lists:member(#{attribute => ?NAME_ATTR_ATTRIBUTE, value => Name},
			                  N#node.attribute_value_pairs) of
				true  -> [N#node.nref | Acc];
				false -> Acc
			end
		end, [], nodes)
	end),
	case Matches of
		[Nref] -> Nref;
		[]     -> ct:fail({attribute_not_found, Name});
		_      -> ct:fail({duplicate_attribute, Name, Matches})
	end.

%%-----------------------------------------------------------------------------
%% find_class_nref_by_name(Name) -> integer()
%%
%% Scans the nodes table for a class node whose name AVP has the given
%% string value.  Uses NameAttrNref=19 (class-node Name).
%%-----------------------------------------------------------------------------
find_class_nref_by_name(Name) ->
	{atomic, Matches} = mnesia:transaction(fun() ->
		mnesia:foldl(fun(N, Acc) ->
			case N#node.kind =:= class andalso
			     lists:member(#{attribute => ?NAME_ATTR_CLASS, value => Name},
			                  N#node.attribute_value_pairs) of
				true  -> [N#node.nref | Acc];
				false -> Acc
			end
		end, [], nodes)
	end),
	case Matches of
		[Nref] -> Nref;
		[]     -> ct:fail({class_not_found, Name});
		_      -> ct:fail({duplicate_class, Name, Matches})
	end.
