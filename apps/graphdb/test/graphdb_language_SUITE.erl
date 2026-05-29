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
-include_lib("graphdb/include/graphdb_nrefs.hrl").

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
    seeds_language_literals_subgroup/1,
    language_literal_seeds_parented_under_subgroup/1,
    language_seeds_carry_attribute_type_literal/1,
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
                             language_en_table_created,
                             seeds_language_literals_subgroup,
                             language_literal_seeds_parented_under_subgroup,
                             language_seeds_carry_attribute_type_literal]},
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
    {ok, _}  = rel_id_server:start_link(),
    graphdb_nref:set_permanent_phase(),
    {ok, _}  = graphdb_nref:start_link(),
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
    {ok, #{lang_code               := LC,
           lang_human              := LH,
           language_literals_group := LL,
           base_language           := BL,
           project_language        := PL,
           env_language_code       := en}} = graphdb_language:seeded_nrefs(),
    ?assert(is_integer(LC)),
    ?assert(is_integer(LH)),
    ?assert(is_integer(LL)),
    ?assert(is_integer(BL)),
    ?assert(is_integer(PL)).

seeded_nrefs_above_floor(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{lang_code               := LC,
           lang_human              := LH,
           language_literals_group := LL,
           base_language           := BL,
           project_language        := PL}} = graphdb_language:seeded_nrefs(),
    %% lang_code and lang_human are bootstrap-labeled (loader-assigned),
    %% so they sit in the permanent tier above English and below nref_start.
    ?assert(LC > ?NREF_ENGLISH),
    ?assert(LC < 1000000),
    ?assert(LH > ?NREF_ENGLISH),
    ?assert(LH < 1000000),
    %% Language Literals sub-group, base_language and project_language are
    %% runtime-seeded by graphdb_language:init/1 AFTER bootstrap, so they
    %% come from nref_server with the runtime-tier floor in effect.
    ?assert(LL >= 1000000),
    ?assert(BL >= 1000000),
    ?assert(PL >= 1000000).

language_en_table_created(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Tables = mnesia:system_info(tables),
    ?assert(lists:member(language_en, Tables)).

seeds_language_literals_subgroup(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{language_literals_group := LangLitNref}} =
        graphdb_language:seeded_nrefs(),
    ?assert(is_integer(LangLitNref)),
    ?assert(LangLitNref >= 1000000),
    {ok, Node} = graphdb_attr:get_attribute(LangLitNref),
    ?assertEqual(attribute, Node#node.kind),
    ?assertEqual([?NREF_LITERALS], Node#node.parents).

language_literal_seeds_parented_under_subgroup(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{language_literals_group := LangLitNref,
           base_language           := BL,
           project_language        := PL}} =
        graphdb_language:seeded_nrefs(),
    {ok, BLNode} = graphdb_attr:get_attribute(BL),
    {ok, PLNode} = graphdb_attr:get_attribute(PL),
    ?assertEqual([LangLitNref], BLNode#node.parents),
    ?assertEqual([LangLitNref], PLNode#node.parents).

language_seeds_carry_attribute_type_literal(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{language_literals_group := LangLitNref,
           base_language           := BL,
           project_language        := PL}} =
        graphdb_language:seeded_nrefs(),
    %% All three nodes should have attribute_type=literal stamped.
    lists:foreach(
        fun(Nref) ->
            ?assertEqual({ok, literal}, graphdb_attr:attribute_type_of(Nref))
        end,
        [LangLitNref, BL, PL]).


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
%% Overlay Write Tests
%%=====================================================================

set_labels_writes_avp(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    %% Write a German label for English nref 10000
    DeAVP = #{attribute => LCAttr, value => "Englisch"},
    ok = graphdb_language:set_labels(?NREF_ENGLISH, de, [DeAVP]),
    %% Read it back directly from the Mnesia table
    [#language_node{avps = AVPs}] =
        mnesia:dirty_read(language_de, ?NREF_ENGLISH),
    {value, #{value := "Englisch"}} =
        lists:search(fun(#{attribute := A}) -> A =:= LCAttr end, AVPs).

set_labels_merges_avps(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, #{lang_code := LCAttr, base_language := BLAttr}} =
        graphdb_language:seeded_nrefs(),
    AVP1 = #{attribute => LCAttr, value => "Englisch"},
    AVP2 = #{attribute => BLAttr, value => test_sentinel},
    ok = graphdb_language:set_labels(?NREF_ENGLISH, de, [AVP1]),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, de, [AVP2]),
    %% Both AVPs present after two writes
    [#language_node{avps = AVPs}] =
        mnesia:dirty_read(language_de, ?NREF_ENGLISH),
    2 = length(AVPs).

set_labels_unregistered_code_error(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {error, unregistered_language} =
        graphdb_language:set_labels(?NREF_ENGLISH, xx, []).


%%=====================================================================
%% Label Resolution Tests
%%=====================================================================

%% Helper used by several tests below
avp(A, V) -> #{attribute => A, value => V}.

resolve_label_from_environment_fallback(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% Chain [en] → en sentinel → read terminal node directly
    %% English nref ?NREF_ENGLISH, instance name AVP attr = 20, value = "English"
    {ok, "English"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, ?NAME_ATTR_INSTANCE, [en], environment).

resolve_label_from_overlay(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, de, [avp(LCAttr, "Englisch")]),
    {ok, "Englisch"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, LCAttr, [de], environment).

resolve_label_chain_priority(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, de, [avp(LCAttr, "Englisch")]),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, fr, [avp(LCAttr, "Anglais")]),
    %% de appears first — de wins
    {ok, "Englisch"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, LCAttr, [de, fr], environment).

resolve_label_en_sentinel(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% Write a wrong value into language_en — sentinel must bypass it
    WrongRec = #language_node{nref = ?NREF_ENGLISH, avps = [avp(?NAME_ATTR_INSTANCE,"WRONG")]},
    ok = mnesia:dirty_write(language_en, WrongRec),
    %% en sentinel skips language_en and reads environment node directly
    {ok, "English"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, ?NAME_ATTR_INSTANCE, [en], environment).

resolve_label_dialect_hit(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% en is already bootstrapped at nref 10000; no need to register it
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, en_gb, [avp(?NAME_ATTR_INSTANCE,"English (UK)")]),
    {ok, "English (UK)"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, ?NAME_ATTR_INSTANCE, [en_gb, en], environment).

resolve_label_dialect_fallback(_Config) ->
    %% [en_gb, en, fr]: en_gb miss → en sentinel → environment (fr skipped)
    {ok, _} = graphdb_language:start_link(),
    %% en is already bootstrapped at nref 10000; no need to register it
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    ok = graphdb_language:set_labels(?NREF_ENGLISH, fr, [avp(?NAME_ATTR_INSTANCE,"Anglais")]),
    %% en_gb has no overlay for nref 10000 → fall through; en → sentinel → env node
    {ok, "English"} =
        graphdb_language:resolve_label(?NREF_ENGLISH, ?NAME_ATTR_INSTANCE, [en_gb, en, fr], environment).

resolve_label_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% AttrNref 99999 does not exist on nref 10000
    not_found =
        graphdb_language:resolve_label(?NREF_ENGLISH, 99999, [en], environment).


%%=====================================================================
%% make_chain Integration Tests
%%=====================================================================

make_chain_drops_unknown_codes(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    %% xx is not registered — dropped silently
    [de] = graphdb_language:make_chain([de, xx]).

make_chain_dialect_insertion(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    %% en_gb is registered; its base en is already in lang_code_map (bootstrap)
    %% de is not registered → dropped
    %% en_gb is a dialect of en; en absent from [en_gb, fr] → inserted
    [en_gb, en, fr] = graphdb_language:make_chain([de, en_gb, fr]).


%%=====================================================================
%% Project Language Tests
%%=====================================================================

project_language_avp_roundtrip(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, DeNref} = graphdb_language:lookup_language_nref(de),
    {ok, #{project_language := PLAttr}} = graphdb_language:seeded_nrefs(),
    %% Stamp the project_language AVP onto nref 10000 (reuse for simplicity)
    F = fun() ->
        [#node{attribute_value_pairs = AVPs} = N] =
            mnesia:read(nodes, ?NREF_ENGLISH),
        Updated = N#node{
            attribute_value_pairs =
                [#{attribute => PLAttr, value => DeNref} | AVPs]
        },
        mnesia:write(nodes, Updated, write)
    end,
    {atomic, ok} = mnesia:transaction(F),
    {ok, de} = graphdb_language:project_language(?NREF_ENGLISH).

project_language_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% Nref 10000 has no project_language AVP yet
    not_found = graphdb_language:project_language(?NREF_ENGLISH).


%%=====================================================================
%% Translation Hook Tests
%%=====================================================================

translation_hook_called_after_registration(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Self = self(),
    Hook = fun(Nref, AVPs) -> Self ! {hook_fired, Nref, AVPs} end,
    ok = graphdb_language:register_translation_hook(Hook),
    graphdb_language:fire_translation_hooks(99, [#{attribute => ?NAME_ATTR_INSTANCE, value => "Test"}]),
    receive
        {hook_fired, 99, _AVPs} -> ok
    after 1000 ->
        ct:fail(hook_not_fired)
    end.

translation_hook_crash_does_not_fail_caller(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    CrashHook = fun(_Nref, _AVPs) -> error(deliberate_crash) end,
    ok = graphdb_language:register_translation_hook(CrashHook),
    ok = graphdb_language:fire_translation_hooks(99, []).

translation_hook_unregister(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Self = self(),
    Hook = fun(Nref, _AVPs) -> Self ! {hook_fired, Nref} end,
    ok = graphdb_language:register_translation_hook(Hook),
    ok = graphdb_language:unregister_translation_hook(Hook),
    graphdb_language:fire_translation_hooks(99, []),
    receive
        {hook_fired, _} -> ct:fail(hook_should_be_unregistered)
    after 200 ->
        ok
    end.
