%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: May 2026
%% Description: Common Test integration suite for graphdb_language.
%%              Each test case gets its own isolated temp directory
%%              with a fresh Mnesia database and nref allocator.
%%              graphdb_mgr is started first to load the bootstrap
%%              scaffold; graphdb_attr and graphdb_class are started
%%              next; graphdb_language is then exercised.
%%---------------------------------------------------------------------
-module(graphdb_language_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-record(node, {
    nref,
    kind,
    parents       = [],
    classes       = [],
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

-record(language_node, {
    nref,
    avps
}).

-compile({nowarn_unused_record, [node, relationship, language_node]}).

-define(DIR_PREFIX, "lang_").

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
    seeded_nrefs_present/1,
    seeded_nrefs_above_floor/1,
    language_en_table_created/1,
    %% Registration
    register_language_creates_concept_node/1,
    register_language_idempotent/1,
    register_dialect_creates_concept_node/1,
    register_dialect_base_not_found/1,
    %% Overlay write
    set_labels_writes_avp/1,
    set_labels_merges_avps/1,
    set_labels_unregistered_code_error/1,
    %% Label resolution
    resolve_label_from_environment_fallback/1,
    resolve_label_from_overlay/1,
    resolve_label_chain_priority/1,
    resolve_label_en_sentinel/1,
    resolve_label_dialect_hit/1,
    resolve_label_dialect_fallback/1,
    resolve_label_not_found/1,
    %% make_chain integration
    make_chain_drops_unknown_codes/1,
    make_chain_dialect_insertion/1,
    %% Project language
    project_language_avp_roundtrip/1,
    project_language_not_found/1,
    %% Translation hooks
    translation_hook_called_after_registration/1,
    translation_hook_crash_does_not_fail_caller/1,
    translation_hook_unregister/1
]).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [{group, seeding},
     {group, registration},
     {group, overlay_write},
     {group, label_resolution},
     {group, make_chain},
     {group, project_language},
     {group, translation_hooks}].

groups() ->
    [{seeding,          [], [seeded_nrefs_present, seeded_nrefs_above_floor,
                             language_en_table_created]},
     {registration,     [], [register_language_creates_concept_node,
                             register_language_idempotent,
                             register_dialect_creates_concept_node,
                             register_dialect_base_not_found]},
     {overlay_write,    [], [set_labels_writes_avp, set_labels_merges_avps,
                             set_labels_unregistered_code_error]},
     {label_resolution, [], [resolve_label_from_environment_fallback,
                             resolve_label_from_overlay,
                             resolve_label_chain_priority,
                             resolve_label_en_sentinel,
                             resolve_label_dialect_hit,
                             resolve_label_dialect_fallback,
                             resolve_label_not_found]},
     {make_chain,       [], [make_chain_drops_unknown_codes,
                             make_chain_dialect_insertion]},
     {project_language, [], [project_language_avp_roundtrip,
                             project_language_not_found]},
     {translation_hooks,[], [translation_hook_called_after_registration,
                             translation_hook_crash_does_not_fail_caller,
                             translation_hook_unregister]}].


%%---------------------------------------------------------------------
%% Suite setup
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

ensure_loaded(App) ->
    case application:load(App) of
        ok                            -> ok;
        {error, {already_loaded, _}}  -> ok
    end.


%%---------------------------------------------------------------------
%% Per-testcase setup/teardown
%%---------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
    Config1  = setup_isolated_env(Config),
    BootFile = proplists:get_value(bootstrap_file, Config),
    application:set_env(seerstone_graph_db, bootstrap_file, BootFile),
    {ok, _}  = graphdb_mgr:start_link(),
    {ok, _}  = graphdb_attr:start_link(),
    {ok, _}  = graphdb_class:start_link(),
    Config1.

end_per_testcase(TC, Config) ->
    verify_cache_invariant(TC),
    catch gen_server:stop(graphdb_language),
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

setup_isolated_env(Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique  = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir  = filename:join([OrigCwd, "_build", "test", "ct_scratch",
                             ?DIR_PREFIX ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    [{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].

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
%% Seeding Tests
%%=====================================================================

seeded_nrefs_present(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{lang_code         := LC,
           base_language     := BL,
           project_language  := PL,
           env_language_code := en}} = graphdb_language:seeded_nrefs(),
    ?assert(is_integer(LC)),
    ?assert(is_integer(BL)),
    ?assert(is_integer(PL)).

seeded_nrefs_above_floor(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{lang_code := LC, base_language := BL,
           project_language := PL}} = graphdb_language:seeded_nrefs(),
    ?assert(LC >= 100000),
    ?assert(BL >= 100000),
    ?assert(PL >= 100000).

language_en_table_created(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Tables = mnesia:system_info(tables),
    ?assert(lists:member(language_en, Tables)).


%%=====================================================================
%% Registration Tests
%%=====================================================================

register_language_creates_concept_node(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, DeNref} = graphdb_language:register_language(de, "German"),
    %% Concept node exists in nodes table
    [#node{kind = instance, attribute_value_pairs = AVPs}] =
        mnesia:dirty_read(nodes, DeNref),
    %% lang_code AVP = de
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    {value, #{value := de}} =
        lists:search(fun(#{attribute := A}) -> A =:= LCAttr end, AVPs),
    %% Overlay table created
    ?assert(lists:member(language_de, mnesia:system_info(tables))).

register_language_idempotent(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _Nref1} = graphdb_language:register_language(de, "German"),
    %% Second call returns already_registered
    {error, already_registered} = graphdb_language:register_language(de, "German").

register_dialect_creates_concept_node(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% English is already bootstrapped at nref 10000; look it up rather than registering
    {ok, EnNref}  = graphdb_language:lookup_language_nref(en),
    {ok, GbNref}  = graphdb_language:register_dialect(en_gb, "British English", en),
    %% Concept node exists
    [#node{kind = instance, attribute_value_pairs = AVPs}] =
        mnesia:dirty_read(nodes, GbNref),
    %% base_language AVP references en concept nref
    {ok, #{base_language := BLAttr}} = graphdb_language:seeded_nrefs(),
    {value, #{value := EnNref}} =
        lists:search(fun(#{attribute := A}) -> A =:= BLAttr end, AVPs),
    %% Overlay table created
    ?assert(lists:member(language_en_gb, mnesia:system_info(tables))).

register_dialect_base_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {error, base_not_found} =
        graphdb_language:register_dialect(en_gb, "British English", nonexistent_lang).


%%=====================================================================
%% Overlay Write Tests (stubs — implemented in Task 5)
%%=====================================================================

set_labels_writes_avp(_Config)           -> {skip, not_yet_implemented}.
set_labels_merges_avps(_Config)          -> {skip, not_yet_implemented}.
set_labels_unregistered_code_error(_Config) -> {skip, not_yet_implemented}.


%%=====================================================================
%% Label Resolution Tests (stubs — implemented in Task 6)
%%=====================================================================

resolve_label_from_environment_fallback(_Config) -> {skip, not_yet_implemented}.
resolve_label_from_overlay(_Config)              -> {skip, not_yet_implemented}.
resolve_label_chain_priority(_Config)            -> {skip, not_yet_implemented}.
resolve_label_en_sentinel(_Config)               -> {skip, not_yet_implemented}.
resolve_label_dialect_hit(_Config)               -> {skip, not_yet_implemented}.
resolve_label_dialect_fallback(_Config)          -> {skip, not_yet_implemented}.
resolve_label_not_found(_Config)                 -> {skip, not_yet_implemented}.


%%=====================================================================
%% make_chain Tests (stubs — implemented in Task 7)
%%=====================================================================

make_chain_drops_unknown_codes(_Config) -> {skip, not_yet_implemented}.
make_chain_dialect_insertion(_Config)   -> {skip, not_yet_implemented}.


%%=====================================================================
%% Project Language Tests (stubs — implemented in Task 8)
%%=====================================================================

project_language_avp_roundtrip(_Config) -> {skip, not_yet_implemented}.
project_language_not_found(_Config)     -> {skip, not_yet_implemented}.


%%=====================================================================
%% Translation Hook Tests (stubs — implemented in Task 9)
%%=====================================================================

translation_hook_called_after_registration(_Config) -> {skip, not_yet_implemented}.
translation_hook_crash_does_not_fail_caller(_Config) -> {skip, not_yet_implemented}.
translation_hook_unregister(_Config)                 -> {skip, not_yet_implemented}.
