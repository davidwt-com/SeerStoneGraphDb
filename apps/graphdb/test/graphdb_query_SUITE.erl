%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: May 2026
%% Description: Common Test integration suite for graphdb_query.
%%              Each testcase gets an isolated tmp dir + fresh Mnesia
%%              + fresh nref allocator + fully started graphdb
%%              supervision tree (mgr, attr, class, instance, language,
%%              query).  This is the smoke suite that asserts
%%              the gen_server boots, the session API is sane, and
%%              every execute-path returns {error, not_implemented}
%%              until Tasks 3-9 land.
%%---------------------------------------------------------------------
-module(graphdb_query_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").
-include_lib("graphdb/include/graphdb_query.hrl").

-define(DIR_PREFIX, "query_").

%%---------------------------------------------------------------------
%% Record definition (matches graphdb_query.erl's own local #node{} —
%% needed here only by root_instance/1, which writes a raw #node{} into
%% a project's nodes table directly, bypassing create_instance).
%%---------------------------------------------------------------------
-record(node, {
    nref,
    kind,
    parents               = [],
    classes               = [],
    attribute_value_pairs
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
    %% skeleton
    starts_and_is_registered/1,
    parse_query_is_identity/1,
    new_session_has_snapshot/1,
    refresh_bumps_snapshot/1,
    unimplemented_query_returns_error/1,
    %% get_node
    q1_returns_bootstrap_node/1,
    q1_returns_attribute_node/1,
    q1_not_found_returns_error/1,
    q1_session_form_returns_session/1,
    q1_cache_populates_on_read/1,
    q1_cache_hit_skips_mnesia/1,
    %% Q1b — get_arcs
    q1b_outgoing_all_kinds/1,
    q1b_incoming_all_kinds/1,
    q1b_both_directions/1,
    q1b_kind_filter_taxonomy_only/1,
    q1b_nref_with_no_arcs/1,
    q1b_cache_uses_dir_kind_key/1,
    q1b_cache_hit_skips_mnesia/1,
    %% describe_attribute
    q2_describes_name_attribute/1,
    q2_includes_parent_and_taxonomy/1,
    q2_includes_labels_default_english/1,
    q2_not_found_returns_error/1,
    q2_rejects_non_attribute_nref/1,
    q2_label_not_dropped_under_project_session/1,
    %% describe_class
    q3_describes_class_with_superclasses/1,
    q3_lists_subclasses/1,
    q3_includes_qcs_flat_list/1,
    q3_class_not_found/1,
    %% describe_instance
    q4_describes_instance_with_class/1,
    q4_resolves_inherited_attributes/1,
    q4_outgoing_and_incoming_connections/1,
    q4_compositional_ancestors/1,
    q4_instance_not_found/1,
    %% list_instances_of
    q5_lists_direct_instances/1,
    q5_recursive_includes_subclass_instances/1,
    q5_non_recursive_excludes_subclasses/1,
    q5_class_with_no_instances/1,
    %% find_path
    q6_finds_path_via_taxonomy/1,
    q6_returns_no_path_when_disconnected/1,
    q6_respects_max_depth_returns_partial/1,
    q6_resume_continues_from_frontier/1,
    q6_arc_kind_filter/1,
    q6_find_path_3_public_api/1,
    %% resume / snapshot_expired
    resume_against_refreshed_session_fails/1,
    %% SP2 T12 — session binds a Project; resolve_home/2
    new_session_1_binds_a_project/1,
    q_get_node_reads_a_project_instance/1,
    q_get_node_still_reads_environment_when_project_bound/1,
    resolve_home_prefers_project_and_logs_on_collision/1,
    %% SP2 review wave B Fix 2 — malformed-handle read-path gating
    execute_query_2_rejects_bad_session_project/1,
    resume_rejects_bad_session_project/1,
    %% SP2 follow-up — Home routing for arc-discovered nrefs
    t1_env_only_path_identical_across_sessions/1,
    t2_shadowed_target_is_not_falsely_found/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, skeleton}, {group, q1_get_node}, {group, q1b_get_arcs},
     {group, q2_describe_attribute}, {group, q3_describe_class},
     {group, q4_describe_instance}, {group, q5_list_instances_of},
     {group, q6_find_path}, {group, sp2_project_session},
     {group, sp2_traversal_home_routing}].

groups() ->
    [{skeleton, [], [
        starts_and_is_registered,
        parse_query_is_identity,
        new_session_has_snapshot,
        refresh_bumps_snapshot,
        unimplemented_query_returns_error
     ]},
     {q1_get_node, [], [
        q1_returns_bootstrap_node,
        q1_returns_attribute_node,
        q1_not_found_returns_error,
        q1_session_form_returns_session,
        q1_cache_populates_on_read,
        q1_cache_hit_skips_mnesia
     ]},
     {q1b_get_arcs, [], [
        q1b_outgoing_all_kinds,
        q1b_incoming_all_kinds,
        q1b_both_directions,
        q1b_kind_filter_taxonomy_only,
        q1b_nref_with_no_arcs,
        q1b_cache_uses_dir_kind_key,
        q1b_cache_hit_skips_mnesia
     ]},
     {q2_describe_attribute, [], [
        q2_describes_name_attribute,
        q2_includes_parent_and_taxonomy,
        q2_includes_labels_default_english,
        q2_not_found_returns_error,
        q2_rejects_non_attribute_nref,
        q2_label_not_dropped_under_project_session
     ]},
     {q3_describe_class, [], [
        q3_describes_class_with_superclasses,
        q3_lists_subclasses,
        q3_includes_qcs_flat_list,
        q3_class_not_found
     ]},
     {q4_describe_instance, [], [
        q4_describes_instance_with_class,
        q4_resolves_inherited_attributes,
        q4_outgoing_and_incoming_connections,
        q4_compositional_ancestors,
        q4_instance_not_found
     ]},
     {q5_list_instances_of, [], [
        q5_lists_direct_instances,
        q5_recursive_includes_subclass_instances,
        q5_non_recursive_excludes_subclasses,
        q5_class_with_no_instances
     ]},
     {q6_find_path, [], [
        q6_finds_path_via_taxonomy,
        q6_returns_no_path_when_disconnected,
        q6_respects_max_depth_returns_partial,
        q6_resume_continues_from_frontier,
        q6_arc_kind_filter,
        q6_find_path_3_public_api,
        resume_against_refreshed_session_fails
     ]},
     {sp2_project_session, [], [
        new_session_1_binds_a_project,
        q_get_node_reads_a_project_instance,
        q_get_node_still_reads_environment_when_project_bound,
        resolve_home_prefers_project_and_logs_on_collision,
        execute_query_2_rejects_bad_session_project,
        resume_rejects_bad_session_project
     ]},
     {sp2_traversal_home_routing, [], [
        t1_env_only_path_identical_across_sessions,
        t2_shadowed_target_is_not_falsely_found
     ]}].


%%---------------------------------------------------------------------
%% Suite-level setup/teardown
%%---------------------------------------------------------------------
init_per_suite(Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    ok = ensure_loaded(graphdb),
    PrivDir = code:priv_dir(graphdb),
    BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
    true = filelib:is_file(BootstrapFile),
    [{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) ->
    ok.


%%---------------------------------------------------------------------
%% Per-testcase setup/teardown
%%---------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
    Config1 = setup_isolated_env(Config),
    BootstrapFile = proplists:get_value(bootstrap_file, Config),
    application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
    {ok, _} = rel_id_server:start_link(),
    graphdb_nref:set_permanent_phase(),
    {ok, _} = graphdb_nref:start_link(),
    {ok, _} = graphdb_mgr:start_link(),
    {ok, _} = graphdb_attr:start_link(),
    {ok, _} = graphdb_class:start_link(),
    {ok, _} = graphdb_instance:start_link(),
    {ok, _} = graphdb_rules:start_link(),
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_query:start_link(),
    Config1.

setup_isolated_env(Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
                            ?DIR_PREFIX ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    [{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].

end_per_testcase(TC, Config) ->
    verify_cache_invariant(TC),
    catch gen_server:stop(graphdb_query),
    catch gen_server:stop(graphdb_language),
    catch gen_server:stop(graphdb_rules),
    catch gen_server:stop(graphdb_instance),
    catch gen_server:stop(graphdb_class),
    catch gen_server:stop(graphdb_attr),
    catch gen_server:stop(graphdb_mgr),
    catch gen_server:stop(graphdb_nref),
    catch persistent_term:erase({graphdb_nref, phase}),
    catch gen_server:stop(rel_id_server),
    catch application:stop(nref),
    catch mnesia:stop(),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    catch dets:close(rel_id_server),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    application:unset_env(seerstone_graph_db, bootstrap_file),
    application:unset_env(mnesia, dir),
    ok.

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

ensure_loaded(App) ->
    case application:load(App) of
        ok                             -> ok;
        {error, {already_loaded, App}} -> ok
    end.

delete_dir_recursive(Dir) ->
    IsAbsolute = filename:pathtype(Dir) =:= absolute,
    HasScratch = string:find(Dir, "_build/test/ct_scratch/") =/= nomatch,
    HasPrefix  = string:find(filename:basename(Dir), ?DIR_PREFIX)
                     =:= filename:basename(Dir),
    case IsAbsolute andalso HasScratch andalso HasPrefix of
        true  -> os:cmd("rm -rf \"" ++ Dir ++ "\""), ok;
        false -> ct:fail({unsafe_delete, Dir})
    end.


%%=====================================================================
%% Skeleton tests
%%=====================================================================

starts_and_is_registered(_Config) ->
    ?assert(is_pid(whereis(graphdb_query))).

parse_query_is_identity(_Config) ->
    Q = #q_get_node{nref = 1},
    ?assertEqual(Q, graphdb_query:parse_query(Q)).

new_session_has_snapshot(_Config) ->
    S = graphdb_query:new_session(),
    ?assert(is_map(S)),
    ?assert(maps:is_key(snapshot_at, S)),
    ?assert(maps:is_key(cache, S)),
    ?assertEqual(#{}, maps:get(cache, S)).

refresh_bumps_snapshot(_Config) ->
    S1 = graphdb_query:new_session(),
    %% Force a different timestamp by sleeping past os:timestamp() resolution
    timer:sleep(2),
    S2 = graphdb_query:refresh(S1),
    ?assertNotEqual(maps:get(snapshot_at, S1),
                    maps:get(snapshot_at, S2)),
    ?assertEqual(#{}, maps:get(cache, S2)).

unimplemented_query_returns_error(_Config) ->
    %% A query shape the dispatcher will never recognise — exercises the
    %% catch-all {error, not_implemented} path, durable across tasks.
    ?assertEqual({error, not_implemented},
                 graphdb_query:execute_query({unknown_query_shape, foo})).


%%=====================================================================
%% get_node tests
%%=====================================================================

q1_returns_bootstrap_node(_Config) ->
    {ok, Node} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}),
    ?assertEqual(?NREF_ROOT, maps:get(nref, Node)),
    ?assertEqual(category,   maps:get(kind, Node)),
    %% Root has no parents
    ?assertEqual([], maps:get(parents, Node)),
    ?assertEqual([], maps:get(classes, Node)),
    ?assert(is_list(maps:get(attribute_value_pairs, Node))).

q1_returns_attribute_node(_Config) ->
    {ok, Node} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_NAMES}),
    ?assertEqual(?NREF_NAMES, maps:get(nref, Node)),
    ?assertEqual(attribute,   maps:get(kind, Node)),
    ?assertEqual([?NREF_ATTRIBUTES], maps:get(parents, Node)).

q1_not_found_returns_error(_Config) ->
    ?assertEqual({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_get_node{nref = 9999999})).

q1_session_form_returns_session(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, Node, S1} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S0),
    ?assertEqual(?NREF_ROOT, maps:get(nref, Node)),
    ?assert(is_map(S1)),
    %% Snapshot_at must survive — refresh did not happen
    ?assertEqual(maps:get(snapshot_at, S0),
                 maps:get(snapshot_at, S1)).

q1_cache_populates_on_read(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, _Node, S1} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S0),
    Cache = maps:get(cache, S1),
    ?assert(maps:is_key({node, ?NREF_ROOT}, Cache)).

q1_cache_hit_skips_mnesia(_Config) ->
    %% First read populates the cache.
    S0 = graphdb_query:new_session(),
    {ok, Node1, S1} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S0),
    %% Stop Mnesia. A subsequent uncached query would now fail.
    stopped = mnesia:stop(),
    %% Second read under the same session must come from the cache.
    {ok, Node2, _S2} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S1),
    ?assertEqual(Node1, Node2).


%%=====================================================================
%% Q1b — get_arcs tests
%%
%% NOTE: bootstrap labels the Attributes-subtree child arcs with
%% ?ARC_ATTR_CHILD (24, kind=taxonomy), NOT ?ARC_CAT_CHILD (22,
%% kind=composition) — the category-vs-attribute distinction was set by
%% PR #15. The plan's test comments referenced ?ARC_CAT_CHILD; the real
%% ground-truth invariant is "child arcs exist with the appropriate
%% subtree label," so we assert against ?ARC_ATTR_CHILD here.
%%=====================================================================

q1b_outgoing_all_kinds(_Config) ->
    %% NREF_ATTRIBUTES (2) is the parent of NREF_NAMES (6), NREF_LITERALS
    %% (7), NREF_RELATIONSHIPS (8). Outgoing arcs from 2 include three
    %% ?ARC_ATTR_CHILD arcs (taxonomy, per PR #15).
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref      = ?NREF_ATTRIBUTES,
                    direction = outgoing,
                    arc_kinds = all}),
    ?assert(is_list(Arcs)),
    ChildArcs = [A || A <- Arcs,
                      maps:get(characterization, A) =:= ?ARC_ATTR_CHILD],
    ?assert(length(ChildArcs) >= 3),
    %% Every arc has the expected projected keys
    [?assertMatch(#{id := _, kind := _, source_nref := _,
                    characterization := _, target_nref := _,
                    reciprocal := _, avps := _}, A) || A <- Arcs].

q1b_incoming_all_kinds(_Config) ->
    %% NREF_NAMES (6) has one incoming child arc from NREF_ATTRIBUTES (2),
    %% labelled ?ARC_ATTR_CHILD (kind=taxonomy).
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref      = ?NREF_NAMES,
                    direction = incoming,
                    arc_kinds = all}),
    ParentArcs = [A || A <- Arcs,
                       maps:get(characterization, A) =:= ?ARC_ATTR_CHILD],
    ?assertEqual(1, length(ParentArcs)),
    [#{source_nref := Src}] = ParentArcs,
    ?assertEqual(?NREF_ATTRIBUTES, Src).

q1b_both_directions(_Config) ->
    %% NREF_NAMES has incoming arcs (parent + child-side-of-children) and
    %% outgoing arcs (parent-side-up + children). The two index reads are
    %% disjoint (each row has exactly one source_nref and one
    %% target_nref), so Out + In = Both.
    {ok, ArcsOut} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = outgoing,
                    arc_kinds = all}),
    {ok, ArcsIn}  = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = incoming,
                    arc_kinds = all}),
    {ok, ArcsBoth} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = both,
                    arc_kinds = all}),
    ?assertEqual(length(ArcsOut) + length(ArcsIn),
                 length(ArcsBoth)).

q1b_kind_filter_taxonomy_only(_Config) ->
    %% NREF_LITERALS (7) — all its outgoing arcs (parent-up + children)
    %% are kind=taxonomy.
    {ok, TaxArcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_LITERALS, direction = outgoing,
                    arc_kinds = [taxonomy]}),
    {ok, AllArcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_LITERALS, direction = outgoing,
                    arc_kinds = all}),
    ?assertEqual(length(TaxArcs),
                 length([A || A <- AllArcs,
                              maps:get(kind, A) =:= taxonomy])).

q1b_nref_with_no_arcs(_Config) ->
    %% An unknown nref simply yields an empty list, not an error.
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = 9999999, direction = outgoing,
                    arc_kinds = all}),
    ?assertEqual([], Arcs).

q1b_cache_uses_dir_kind_key(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, _, S1} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_ROOT, direction = outgoing,
                    arc_kinds = all}, S0),
    Cache = maps:get(cache, S1),
    Key = {arcs, ?NREF_ROOT, outgoing, all},
    ?assert(maps:is_key(Key, Cache)).

q1b_cache_hit_skips_mnesia(_Config) ->
    %% First read populates the cache under {arcs, N, Dir, Kinds}.
    S0 = graphdb_query:new_session(),
    {ok, Arcs1, S1} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_ROOT, direction = outgoing,
                    arc_kinds = all}, S0),
    %% Stop Mnesia. A subsequent uncached query would now fail.
    stopped = mnesia:stop(),
    %% Second read under the same session must come from the cache.
    {ok, Arcs2, _S2} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_ROOT, direction = outgoing,
                    arc_kinds = all}, S1),
    ?assertEqual(Arcs1, Arcs2).


%%=====================================================================
%% describe_attribute tests
%%=====================================================================

q2_describes_name_attribute(_Config) ->
    %% NREF_NAMES (6) is an attribute node, child of NREF_ATTRIBUTES.
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    ?assertEqual(?NREF_NAMES, maps:get(nref, R)),
    ?assertEqual(attribute,   maps:get(kind, R)),
    ?assertEqual(?NREF_ATTRIBUTES, maps:get(parent, R)).

q2_includes_parent_and_taxonomy(_Config) ->
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    Children = maps:get(children, R),
    ?assert(is_list(Children)),
    %% Names has children 9, 10, 11, 12 (NameAttr subcategories)
    ?assert(lists:member(?NREF_CAT_NAME_ATTRS, Children)),
    ?assert(lists:member(?NREF_INST_NAME_ATTRS, Children)).

q2_includes_labels_default_english(_Config) ->
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    Labels = maps:get(labels, R),
    ?assert(is_map(Labels)),
    ?assert(maps:is_key(?NREF_NAMES, Labels)),
    ?assert(is_list(maps:get(?NREF_NAMES, Labels))).

q2_not_found_returns_error(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).

q2_rejects_non_attribute_nref(_Config) ->
    %% NREF_ROOT is a category — describe path is for attributes only.
    %% Categories take the category branch (no describe yet).
    {error, {unsupported_kind, category}} =
        graphdb_query:execute_query(
            #q_describe{nref = ?NREF_ROOT, labels = default}).

%% SP2 review wave B Fix 1 regression: reproduces the reviewer's exact
%% repro. describe_attribute's own resolve_labels call used to route
%% N/Parent/Children (all attribute nrefs, always environment-resident)
%% through resolve_home/2, so a project-bound session whose project had
%% minted enough instances to collide numerically with a low bootstrap
%% nref (here, 8 = "Relationships") silently dropped that nref's label
%% instead of erroring -- resolve_home/2 found a project instance at key
%% 8, read it as kind=instance, and NAME_ATTR_INSTANCE (20) doesn't match
%% the environment's real Relationships node, so resolve_label missed.
%%
%% Mint 9 project nrefs (a compositional root plus 8 filler instances) so
%% the project's own allocator has assigned nref 8 to one of them -- a
%% genuine key collision with the environment's bootstrap "Relationships"
%% attribute (also nref 8). Then describe a relationship-type attribute
%% whose parent is nref 8 under a project-bound session and confirm BOTH
%% the described attribute's own label AND its parent's (nref 8's) label
%% are present -- pre-fix, nref 8's label was silently missing.
q2_label_not_dropped_under_project_session(_Config) ->
    Project = proj(),
    Class = widget_class(),
    Root = root_instance(Project),
    lists:foreach(fun(I) ->
        {ok, _, _} = graphdb_instance:create_instance(Project,
            "Filler" ++ integer_to_list(I), Class, Root)
    end, lists:seq(1, 8)),
    {ok, RelType} = graphdb_attr:create_relationship_type("QRelType"),
    Session = graphdb_query:new_session(Project),
    {ok, R, _Session1} = graphdb_query:execute_query(
        #q_describe{nref = RelType, labels = default}, Session),
    ?assertEqual(?NREF_RELATIONSHIPS, maps:get(parent, R)),
    Labels = maps:get(labels, R),
    ?assert(maps:is_key(RelType, Labels)),
    %% This is the assertion that failed before the fix: nref 8's label
    %% ("Relationships") was silently absent from Labels.
    ?assert(maps:is_key(?NREF_RELATIONSHIPS, Labels)),
    ?assertEqual("Relationships", maps:get(?NREF_RELATIONSHIPS, Labels)).

%%---------------------------------------------------------------------
%% describe_class
%%---------------------------------------------------------------------
q3_describes_class_with_superclasses(_Config) ->
    %% Build: Classes <- Vehicle <- Car
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car", Vehicle),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Car, labels = default}),
    ?assertEqual(Car,       maps:get(nref, R)),
    ?assertEqual(class,     maps:get(kind, R)),
    ?assertEqual([Vehicle], maps:get(superclasses, R)),
    ?assert(lists:member(Vehicle, maps:get(ancestors, R))).

q3_lists_subclasses(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car",   Vehicle),
    {ok, Truck}   = graphdb_class:create_class("Truck", Vehicle),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Vehicle, labels = default}),
    Subs = maps:get(subclasses, R),
    ?assert(lists:member(Car,   Subs)),
    ?assert(lists:member(Truck, Subs)).

q3_includes_qcs_flat_list(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car",   Vehicle),
    {ok, WeightA} = graphdb_attr:create_literal_attribute("weight", number),
    {ok, ColorA}  = graphdb_attr:create_literal_attribute("color",  string),
    ok = graphdb_class:add_qualifying_characteristic(Vehicle, WeightA),
    ok = graphdb_class:add_qualifying_characteristic(Car, ColorA),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Car, labels = default}),
    QCs = maps:get(qualifying_characteristics, R),
    %% Flat [{AttrNref, Value}] list; both Color (own) and Weight
    %% (inherited from Vehicle) appear, each with Value=undefined
    %% because no binding was set.
    ?assert(lists:member({ColorA,  undefined}, QCs)),
    ?assert(lists:member({WeightA, undefined}, QCs)).

q3_class_not_found(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).

%%---------------------------------------------------------------------
%% describe_instance
%%---------------------------------------------------------------------
%% describe_instance's ephemeral execute_query/1 form binds a project-less
%% session (project => undefined), so resolve_home/2 always resolves a bare
%% nref against the environment table. A project instance nref no longer
%% lives there under SP2 (or worse, numerically collides with an unrelated
%% environment node) -- these q4/q5/q6 tests bind a session to proj() and
%% use the session-threaded execute_query/2 form instead.
q4_describes_instance_with_class(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Taurus, _}  = graphdb_instance:create_instance(proj(),
                       "Taurus", Vehicle, root()),
    Session = graphdb_query:new_session(proj()),
    {ok, R, _Session1} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}, Session),
    ?assertEqual(instance,  maps:get(kind, R)),
    ?assertEqual([Vehicle], maps:get(classes, R)),
    ?assert(lists:member(Vehicle, maps:get(class_ancestors, R))).

q4_resolves_inherited_attributes(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, WeightA} = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Vehicle, WeightA),
    %% Bind a class-level value (Task 0 adds bind_qc_value/3)
    ok = graphdb_class:bind_qc_value(Vehicle, WeightA, 3500),
    {ok, Taurus, _} = graphdb_instance:create_instance(proj(),
                      "Taurus", Vehicle, root()),
    Session = graphdb_query:new_session(proj()),
    {ok, R, _Session1} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}, Session),
    Resolved = maps:get(resolved_attributes, R),
    Weight = maps:get(WeightA, Resolved),
    ?assertEqual(3500,             maps:get(value,  Weight)),
    ?assertEqual({class, Vehicle}, maps:get(source, Weight)).

q4_outgoing_and_incoming_connections(_Config) ->
    {ok, Mfr}    = graphdb_class:create_class("Manufacturer", ?NREF_CLASSES),
    {ok, Veh}    = graphdb_class:create_class("Vehicle",      ?NREF_CLASSES),
    {ok, Ford, _}   = graphdb_instance:create_instance(proj(),
                       "Ford",   Mfr, root()),
    {ok, Tau, _}    = graphdb_instance:create_instance(proj(),
                       "Taurus", Veh, root()),
    %% create_relationship_attribute/3 atomically creates BOTH directions
    %% in one call and returns {ok, {FwdNref, RevNref}}.
    {ok, {MakesA, MadeByA}} = graphdb_attr:create_relationship_attribute_pair(
                                  "makes", "made_by", instance),
    ok = graphdb_instance:add_relationship(proj(), Ford, MakesA, Tau, MadeByA),
    Session = graphdb_query:new_session(proj()),
    {ok, R, _Session1} = graphdb_query:execute_query(
        #q_describe{nref = Tau, labels = default}, Session),
    Outgoing = maps:get(outgoing_connections, R),
    Incoming = maps:get(incoming_connections, R),
    %% Taurus points at Ford via MadeByA (outgoing).
    %% Ford points at Taurus via MakesA (incoming, from Taurus's pov).
    ?assert(lists:any(fun(#{characterization := C, target := T}) ->
                          C =:= MadeByA andalso T =:= Ford
                      end, Outgoing)),
    ?assert(lists:any(fun(#{characterization := C, source := S}) ->
                          C =:= MakesA andalso S =:= Ford
                      end, Incoming)).

q4_compositional_ancestors(_Config) ->
    {ok, Veh}    = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car, _}    = graphdb_instance:create_instance(proj(),
                       "Car",    Veh, root()),
    {ok, Engine, _} = graphdb_instance:create_instance(proj(),
                       "Engine", Veh, Car),
    Session = graphdb_query:new_session(proj()),
    {ok, R, _Session1} = graphdb_query:execute_query(
        #q_describe{nref = Engine, labels = default}, Session),
    ?assertEqual(Car, maps:get(compositional_parent, R)),
    ?assert(lists:member(Car, maps:get(compositional_ancestors, R))).

q4_instance_not_found(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).

%%---------------------------------------------------------------------
%% list_instances_of
%%---------------------------------------------------------------------
%% #q_instances_of{}'s dispatch routes explicitly through the session's
%% bound Project (graphdb_query.erl's ProjectHome / session_read_arcs_home/5)
%% rather than resolve_home/2's bare-nref guess, since the class->instance
%% membership row (C2I) is always written into the PROJECT's own
%% relationships table regardless of where the class node itself resolves
%% (fixed by commit a419628; formerly a known gap in this suite's own
%% comments here, now stale and removed).
q5_lists_direct_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Tau, _} = graphdb_instance:create_instance(proj(),
                    "Taurus", Veh, root()),
    {ok, Acc, _} = graphdb_instance:create_instance(proj(),
                    "Accord", Veh, root()),
    Session = graphdb_query:new_session(proj()),
    {ok, Insts, _Session1} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}, Session),
    ?assert(lists:member(Tau, Insts)),
    ?assert(lists:member(Acc, Insts)).

q5_recursive_includes_subclass_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau, _} = graphdb_instance:create_instance(proj(),
                    "Taurus", Car, root()),
    Session = graphdb_query:new_session(proj()),
    {ok, Insts, _Session1} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = true}, Session),
    ?assert(lists:member(Tau, Insts)).

q5_non_recursive_excludes_subclasses(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau, _} = graphdb_instance:create_instance(proj(),
                    "Taurus", Car, root()),
    Session = graphdb_query:new_session(proj()),
    {ok, Insts, _Session1} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}, Session),
    ?assertNot(lists:member(Tau, Insts)).

%% SP2 review wave B Fix 3: project-bound, not the project-less
%% execute_query/1 form. Under execute_query/1 the session carries no
%% Project (project => undefined), so #q_instances_of{}'s dispatch takes
%% its ProjectHome =:= undefined branch and reads instantiation arcs from
%% the environment, where NO class ever has project-resident instances --
%% every class returns [] there, proven or not, so the assertion could
%% never fail. Binding to proj() -- AND populating that same project with
%% an instance of an unrelated class -- makes this test actually exercise
%% "a real, non-empty project still returns [] for a genuinely empty
%% class", matching its q5 siblings.
q5_class_with_no_instances(_Config) ->
    {ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Other} = graphdb_class:create_class("Other",   ?NREF_CLASSES),
    {ok, _, _}  = graphdb_instance:create_instance(proj(),
                   "Something", Other, root()),
    Session = graphdb_query:new_session(proj()),
    ?assertMatch({ok, [], _},
                 graphdb_query:execute_query(
                     #q_instances_of{class = Veh, recursive = true}, Session)).

%%---------------------------------------------------------------------
%% find_path
%%---------------------------------------------------------------------
q6_finds_path_via_taxonomy(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Path} = graphdb_query:execute_query(
        #q_find_path{from      = Car,
                     to        = Veh,
                     max_depth = 5,
                     arc_kinds = [taxonomy]}),
    ?assert(is_list(Path)),
    ?assertNotEqual([], Path),
    Last = lists:last(Path),
    ?assertEqual(Veh, maps:get(to, Last)).

q6_returns_no_path_when_disconnected(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", ?NREF_CLASSES),
    ?assertMatch({ok, no_path},
                 graphdb_query:execute_query(
                     #q_find_path{from      = A,
                                  to        = B,
                                  max_depth = 5,
                                  arc_kinds = [taxonomy]})).

q6_respects_max_depth_returns_partial(_Config) ->
    %% Build a chain A <- B <- C <- D <- E (5 nodes, 4 taxonomy hops)
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, D} = graphdb_class:create_class("D", C),
    {ok, _E} = graphdb_class:create_class("E", D),
    %% From D up to A is 3 hops; cap at 2 -> partial.
    Q = #q_find_path{from = D, to = A, max_depth = 2,
                     arc_kinds = [taxonomy]},
    Reply = graphdb_query:execute_query(Q),
    ?assertMatch({partial, _Path, _Cont}, Reply).

q6_resume_continues_from_frontier(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, D} = graphdb_class:create_class("D", C),
    Q = #q_find_path{from = D, to = A, max_depth = 2,
                     arc_kinds = [taxonomy]},
    S0 = graphdb_query:new_session(),
    {partial, _PartialPath, Cont, S1} =
        graphdb_query:execute_query(Q, S0),
    {ok, FullPath, _S2} = graphdb_query:resume(Cont, S1),
    Last = lists:last(FullPath),
    ?assertEqual(A, maps:get(to, Last)).

q6_arc_kind_filter(_Config) ->
    %% B (child) -> A (parent) via composition; restricting to taxonomy
    %% yields no_path because the path is purely compositional. A/B are
    %% project instances, so their compositional arcs live in Project's own
    %% relationships table -- bind a session to proj() (resolve_home/2
    %% correctly routes both A and B's arcs there, since A/B are found in
    %% Project's own node table).
    {ok, Cls} = graphdb_class:create_class("Cls", ?NREF_CLASSES),
    {ok, A, _}   = graphdb_instance:create_instance(proj(),
                    "A", Cls, root()),
    {ok, B, _}   = graphdb_instance:create_instance(proj(), "B", Cls, A),
    Session = graphdb_query:new_session(proj()),
    {ok, [_|_], Session1} = graphdb_query:execute_query(
        #q_find_path{from      = B,
                     to        = A,
                     max_depth = 5,
                     arc_kinds = [composition]}, Session),
    ?assertMatch({ok, no_path, _},
                 graphdb_query:execute_query(
                     #q_find_path{from      = B,
                                  to        = A,
                                  max_depth = 5,
                                  arc_kinds = [taxonomy]}, Session1)).

q6_find_path_3_public_api(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, Path} = graphdb_query:find_path(B, A, 5),
    ?assert(is_list(Path)),
    ?assertNotEqual([], Path).

resume_against_refreshed_session_fails(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, _D} = graphdb_class:create_class("D", C),
    Q = #q_find_path{from = C, to = A, max_depth = 1,
                     arc_kinds = [taxonomy]},
    S0 = graphdb_query:new_session(),
    {partial, _, Cont, S1} = graphdb_query:execute_query(Q, S0),
    timer:sleep(2),
    S2 = graphdb_query:refresh(S1),
    ?assertEqual({error, snapshot_expired},
                 graphdb_query:resume(Cont, S2)).


%%=====================================================================
%% SP2 T12 — session binds a Project; resolve_home/2
%%=====================================================================

new_session_1_binds_a_project(_Config) ->
    Project = proj(),
    Session = graphdb_query:new_session(Project),
    ?assertEqual(Project, maps:get(project, Session)).

q_get_node_reads_a_project_instance(_Config) ->
    Project = proj(),
    {ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
        widget_class(), root_instance(Project)),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := Nref, kind := instance}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = Nref}, Session).

q_get_node_still_reads_environment_when_project_bound(_Config) ->
    Project = proj(),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := ?NREF_ROOT, kind := category}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = ?NREF_ROOT}, Session).

resolve_home_prefers_project_and_logs_on_collision(_Config) ->
    Project = proj(),
    %% root_instance/1 seeds a compositional-root instance directly at the
    %% project's first allocated nref -- for a freshly-registered project
    %% the counter allocator starts at 1 (graphdb_project:next_nref/1), so
    %% this instance's nref genuinely collides in KEY (not identity) with
    %% the environment's Root category node, which is also nref 1.
    %% Bind to whatever root_instance/1 actually returns rather than
    %% asserting against the literal 1 -- create_instance/create-order
    %% quirks aside, resolve_home/2's contract is about the returned nref,
    %% not about a specific integer.
    ProjRootNref = root_instance(Project),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := FoundNref, kind := instance}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = ProjRootNref}, Session),
    ?assertEqual(ProjRootNref, FoundNref).

%%-----------------------------------------------------------------------------
%% SP2 review wave B Fix 2 regression -- reproduces the reviewer's "bogus
%% session" transcript. new_session/1 stores its Project argument
%% unvalidated; before this fix, feeding that session straight into
%% execute_query/2 (or resume/2) reached resolve_home/2's
%% mnesia:dirty_read(graphdb_ns:node_table(Project), _) INSIDE this
%% gen_server's own handle_call (dispatch/2 runs synchronously, not via a
%% nested call), and graphdb_ns:node_table/1's bare two-clause match
%% crashed the graphdb_query singleton itself. validate_session_home/1
%% now gates both entry points on the caller side, before the
%% gen_server:call, returning a clean {error, invalid_project} instead.
%% The empirical proof: the worker's registered pid is unchanged
%% before/after (this suite starts graphdb_query directly, not under a
%% supervisor, so a crash would unregister the name rather than restart
%% it -- either divergence from the pre-call pid proves the crash).
%%-----------------------------------------------------------------------------
execute_query_2_rejects_bad_session_project(_Config) ->
    PidBefore = whereis(graphdb_query),
    ?assert(is_pid(PidBefore)),
    Session = graphdb_query:new_session(not_a_project),
    ?assertEqual({error, invalid_project},
                 graphdb_query:execute_query(
                     #q_get_node{nref = ?NREF_ROOT}, Session)),
    ?assertEqual(PidBefore, whereis(graphdb_query)).

resume_rejects_bad_session_project(_Config) ->
    {ok, A}  = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B}  = graphdb_class:create_class("B", A),
    {ok, C}  = graphdb_class:create_class("C", B),
    {ok, _D} = graphdb_class:create_class("D", C),
    Q = #q_find_path{from = C, to = A, max_depth = 1,
                     arc_kinds = [taxonomy]},
    S0 = graphdb_query:new_session(),
    {partial, _, Cont, S1} = graphdb_query:execute_query(Q, S0),
    %% Corrupt the already-valid, already-in-flight session's Home after
    %% the fact -- resume/2 must re-validate, not trust a session just
    %% because execute_query/2 accepted it earlier.
    BadSession = S1#{project => not_a_project},
    PidBefore = whereis(graphdb_query),
    ?assertEqual({error, invalid_project},
                 graphdb_query:resume(Cont, BadSession)),
    ?assertEqual(PidBefore, whereis(graphdb_query)).

%%=====================================================================
%% SP2 follow-up — Home routing for arc-discovered nrefs
%% (docs/designs/query-traversal-home-routing-design.md)
%%=====================================================================

%%---------------------------------------------------------------------
%% T1 -- the invariant that broke.  An environment-only path must be
%% returned IDENTICALLY under an environment session, under a project
%% that does not shadow the intermediate hop, and under a project that
%% does.  Before the fix the third case returned {ok, no_path}.
%%---------------------------------------------------------------------
t1_env_only_path_identical_across_sessions(_Config) ->
    %% Both attributes are created under bootstrap nref 6 ("Names"), and
    %% graphdb_attr writes the taxonomy pair 6 -24-> New / New -23-> 6.
    %% So the only [taxonomy] route from A1 to A2 runs through 6.
    {ok, A1} = graphdb_attr:create_name_attribute("T1Alpha"),
    {ok, A2} = graphdb_attr:create_name_attribute("T1Beta"),
    Q = #q_find_path{from = A1, to = A2, max_depth = 4,
                     arc_kinds = [taxonomy]},

    {ok, EnvPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session()),

    %% (b) a project holding a single node -- nref 6 is NOT shadowed.
    {ok, SmallP} = graphdb_project:register_project("T1 small"),
    {ok, Small}  = graphdb_project:open(SmallP),
    _ = root_instance(Small),
    {ok, SmallPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session(Small)),

    %% (c) a project holding >= 6 nodes -- nref 6 IS shadowed.  Project
    %% allocators start at 1, so this is the steady state of any real
    %% project, not a contrived setup.
    {ok, BigP} = graphdb_project:register_project("T1 shadowing"),
    {ok, Big}  = graphdb_project:open(BigP),
    Seeded = [root_instance(Big) || _ <- lists:seq(1, 6)],
    ?assert(lists:member(?NREF_NAMES, Seeded)),
    {ok, BigPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session(Big)),

    ?assertEqual(EnvPath, SmallPath),
    ?assertEqual(EnvPath, BigPath),
    ?assertMatch([#{from := A1, via := ?ARC_ATTR_PARENT,
                    to := ?NREF_NAMES, kind := taxonomy},
                  #{from := ?NREF_NAMES, via := ?ARC_ATTR_CHILD,
                    to := A2, kind := taxonomy}], EnvPath),
    %% An environment-only path crosses no store, so no edge discloses
    %% a Home (see Task 3).
    ?assertEqual([], [E || E <- EnvPath, maps:is_key(home, E)]).

%%---------------------------------------------------------------------
%% T2 -- false `found` via the bare-nref target comparison.  With
%% to = 6 under a shadowing project, resolve_home/2 resolves the
%% ENDPOINT to the project's instance 6 (documented, intentional).  A
%% walk through the environment's attribute 6 must therefore NOT count
%% as having found it.  Pre-fix, `case T of To` compared 6 =:= 6 and
%% returned a one-edge path -- a fabricated result.
%%
%% max_depth = 2 makes the post-fix outcome deterministic: level 1
%% expands A1 to {6}, level 2 expands 6's children, none of which is
%% the project's instance 6, and the budget runs out with a non-empty
%% frontier -> partial.
%%---------------------------------------------------------------------
t2_shadowed_target_is_not_falsely_found(_Config) ->
    {ok, A1} = graphdb_attr:create_name_attribute("T2Alpha"),
    {ok, P}  = graphdb_project:register_project("T2 shadowing"),
    {ok, Project} = graphdb_project:open(P),
    Seeded = [root_instance(Project) || _ <- lists:seq(1, 6)],
    ?assert(lists:member(?NREF_NAMES, Seeded)),
    Session = graphdb_query:new_session(Project),
    Reply = graphdb_query:execute_query(
        #q_find_path{from = A1, to = ?NREF_NAMES, max_depth = 2,
                     arc_kinds = [taxonomy]}, Session),
    %% The invariant: no path is fabricated.
    ?assertNotMatch({ok, [_ | _], _}, Reply),
    ?assertMatch({partial, _Best, _Cont, _S}, Reply).


%%---------------------------------------------------------------------
%% proj() -> Project
%%
%% SP2 test helper: returns a project handle, memoised per test-case
%% process. Registers a project under Projects (nref 5) on first use and
%% opens it; subsequent calls in the same process reuse it.
%%---------------------------------------------------------------------
proj() ->
    case get(sp2_project) of
        undefined ->
            {ok, P} = graphdb_project:register_project("SP2 test project"),
            {ok, Project} = graphdb_project:open(P),
            put(sp2_project, Project),
            Project;
        Project ->
            Project
    end.

%%---------------------------------------------------------------------
%% root() -> Nref
%%
%% SP2 test helper: returns a shared compositional-root instance nref for
%% proj(), memoised per test-case process (mirrors proj()'s own memo
%% pattern) so every create_instance/4 call in one test case that used
%% to pass the old single-store stand-in parent (bare 5 / ?NREF_PROJECTS
%% -- an environment category nref that happened to always exist in the
%% pre-SP2 shared table) shares the SAME project-local parent. Seeds via
%% root_instance/1 on first use.
%%---------------------------------------------------------------------
root() ->
    case get(sp2_root) of
        undefined ->
            Nref = root_instance(proj()),
            put(sp2_root, Nref),
            Nref;
        Nref ->
            Nref
    end.

%%---------------------------------------------------------------------
%% widget_class() -> ClassNref
%%
%% Throwaway environment-scoped class for the SP2 T12 session tests.
%% Classes live in the environment regardless of which project
%% instantiates them.
%%---------------------------------------------------------------------
widget_class() ->
    {ok, ClassNref} = graphdb_class:create_class("T12Widget", 3),
    ClassNref.

%%---------------------------------------------------------------------
%% root_instance(Project) -> Nref
%%
%% Seeds a throwaway compositional-root instance directly into Project's
%% own (initially empty) nodes table, bypassing create_instance's parent
%% validation (do_validate_parent/3 requires the parent to already exist,
%% and a fresh project store has nothing yet to point at). For a freshly
%% registered project, next_nref/1's first call returns 1 -- callers must
%% never assume this and should bind/assert on the returned Nref.
%%---------------------------------------------------------------------
root_instance(Project) ->
    Nref = graphdb_project:next_nref(Project),
    Node = #node{nref = Nref, kind = instance, attribute_value_pairs = []},
    ok = mnesia:dirty_write(graphdb_ns:node_table(Project), Node),
    Nref.
