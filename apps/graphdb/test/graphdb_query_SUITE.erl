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
%%              query).  This is the F3 Task 2 smoke suite that asserts
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
    %% Q1 — get_node
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
    %% Q2 — describe_attribute
    q2_describes_name_attribute/1,
    q2_includes_parent_and_taxonomy/1,
    q2_includes_labels_default_english/1,
    q2_not_found_returns_error/1,
    q2_rejects_non_attribute_nref/1,
    %% Q3 — describe_class
    q3_describes_class_with_superclasses/1,
    q3_lists_subclasses/1,
    q3_includes_qcs_flat_list/1,
    q3_class_not_found/1,
    %% Q4 — describe_instance
    q4_describes_instance_with_class/1,
    q4_resolves_inherited_attributes/1,
    q4_outgoing_and_incoming_connections/1,
    q4_compositional_ancestors/1,
    q4_instance_not_found/1,
    %% Q5 — list_instances_of
    q5_lists_direct_instances/1,
    q5_recursive_includes_subclass_instances/1,
    q5_non_recursive_excludes_subclasses/1,
    q5_class_with_no_instances/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, skeleton}, {group, q1_get_node}, {group, q1b_get_arcs},
     {group, q2_describe_attribute}, {group, q3_describe_class},
     {group, q4_describe_instance}, {group, q5_list_instances_of}].

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
        q2_rejects_non_attribute_nref
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
    {ok, _} = graphdb_mgr:start_link(),
    {ok, _} = graphdb_attr:start_link(),
    {ok, _} = graphdb_class:start_link(),
    {ok, _} = graphdb_instance:start_link(),
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
    catch gen_server:stop(graphdb_instance),
    catch gen_server:stop(graphdb_class),
    catch gen_server:stop(graphdb_attr),
    catch gen_server:stop(graphdb_mgr),
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
    %% catch-all {error, not_implemented} path, durable across F3 tasks.
    ?assertEqual({error, not_implemented},
                 graphdb_query:execute_query({unknown_query_shape, foo})).


%%=====================================================================
%% Q1 — get_node tests
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
%% Q2 — describe_attribute tests
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
    %% NREF_ROOT is a category — Q2 path is for attributes only.
    %% Categories take the category branch (no describe yet).
    {error, {unsupported_kind, category}} =
        graphdb_query:execute_query(
            #q_describe{nref = ?NREF_ROOT, labels = default}).

%%---------------------------------------------------------------------
%% Q3 — describe_class
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
%% Q4 — describe_instance
%%---------------------------------------------------------------------
q4_describes_instance_with_class(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Taurus}  = graphdb_instance:create_instance(
                       "Taurus", Vehicle, ?NREF_PROJECTS),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}),
    ?assertEqual(instance,  maps:get(kind, R)),
    ?assertEqual([Vehicle], maps:get(classes, R)),
    ?assert(lists:member(Vehicle, maps:get(class_ancestors, R))).

q4_resolves_inherited_attributes(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, WeightA} = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Vehicle, WeightA),
    %% Bind a class-level value (Task 0 adds bind_qc_value/3)
    ok = graphdb_class:bind_qc_value(Vehicle, WeightA, 3500),
    {ok, Taurus} = graphdb_instance:create_instance(
                      "Taurus", Vehicle, ?NREF_PROJECTS),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}),
    Resolved = maps:get(resolved_attributes, R),
    Weight = maps:get(WeightA, Resolved),
    ?assertEqual(3500,             maps:get(value,  Weight)),
    ?assertEqual({class, Vehicle}, maps:get(source, Weight)).

q4_outgoing_and_incoming_connections(_Config) ->
    {ok, Mfr}    = graphdb_class:create_class("Manufacturer", ?NREF_CLASSES),
    {ok, Veh}    = graphdb_class:create_class("Vehicle",      ?NREF_CLASSES),
    {ok, Ford}   = graphdb_instance:create_instance(
                       "Ford",   Mfr, ?NREF_PROJECTS),
    {ok, Tau}    = graphdb_instance:create_instance(
                       "Taurus", Veh, ?NREF_PROJECTS),
    %% create_relationship_attribute/3 atomically creates BOTH directions
    %% in one call and returns {ok, {FwdNref, RevNref}}.
    {ok, {MakesA, MadeByA}} = graphdb_attr:create_relationship_attribute(
                                  "makes", "made_by", instance),
    ok = graphdb_instance:add_relationship(Ford, MakesA, Tau, MadeByA),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Tau, labels = default}),
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
    {ok, Car}    = graphdb_instance:create_instance(
                       "Car",    Veh, ?NREF_PROJECTS),
    {ok, Engine} = graphdb_instance:create_instance(
                       "Engine", Veh, Car),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Engine, labels = default}),
    ?assertEqual(Car, maps:get(compositional_parent, R)),
    ?assert(lists:member(Car, maps:get(compositional_ancestors, R))).

q4_instance_not_found(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).

%%---------------------------------------------------------------------
%% Q5 — list_instances_of
%%---------------------------------------------------------------------
q5_lists_direct_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Veh, ?NREF_PROJECTS),
    {ok, Acc} = graphdb_instance:create_instance(
                    "Accord", Veh, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}),
    ?assert(lists:member(Tau, Insts)),
    ?assert(lists:member(Acc, Insts)).

q5_recursive_includes_subclass_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Car, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = true}),
    ?assert(lists:member(Tau, Insts)).

q5_non_recursive_excludes_subclasses(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Car, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}),
    ?assertNot(lists:member(Tau, Insts)).

q5_class_with_no_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    ?assertMatch({ok, []},
                 graphdb_query:execute_query(
                     #q_instances_of{class = Veh, recursive = true})).
