%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(graphdb_language_tests).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% overlay_table_name/2
%%--------------------------------------------------------------------

overlay_table_name_env_test() ->
    ?assertEqual(language_en,    graphdb_language:overlay_table_name(en, environment)),
    ?assertEqual(language_de,    graphdb_language:overlay_table_name(de, environment)),
    ?assertEqual(language_en_gb, graphdb_language:overlay_table_name(en_gb, environment)).

overlay_table_name_project_test() ->
    ?assertEqual(language_en_42,    graphdb_language:overlay_table_name(en, {project, 42})),
    ?assertEqual(language_de_1000,  graphdb_language:overlay_table_name(de, {project, 1000})),
    ?assertEqual(language_en_gb_7,  graphdb_language:overlay_table_name(en_gb, {project, 7})).

%%--------------------------------------------------------------------
%% do_make_chain/3
%%   DialectMap :: #{Code :: atom() => Base :: atom()}
%%   (absent key = not a dialect)
%%--------------------------------------------------------------------

make_chain_empty_test() ->
    ?assertEqual([], graphdb_language:do_make_chain([], [], #{})).

make_chain_no_dialects_test() ->
    %% No dialects registered — output = input
    ?assertEqual([de, fr], graphdb_language:do_make_chain([de, fr], [], #{})).

make_chain_dialect_base_absent_test() ->
    %% [de, en_gb, fr] → [de, en_gb, en, fr]  (en absent from full chain)
    DMap = #{en_gb => en},
    ?assertEqual([de, en_gb, en, fr],
        graphdb_language:do_make_chain([de, en_gb, fr], [], DMap)).

make_chain_dialect_base_in_remaining_test() ->
    %% [en_gb, en, fr] → [en_gb, en, fr]  (en already in remaining)
    DMap = #{en_gb => en},
    ?assertEqual([en_gb, en, fr],
        graphdb_language:do_make_chain([en_gb, en, fr], [], DMap)).

make_chain_multiple_dialects_single_base_test() ->
    %% [en_gb, en_us] → [en_gb, en, en_us]
    %% After en_gb: en not in [en_gb, en_us] → insert. Now full chain = [en_gb, en, en_us].
    %% After en_us: en in [en_gb, en, en_us] → skip.
    DMap = #{en_gb => en, en_us => en},
    ?assertEqual([en_gb, en, en_us],
        graphdb_language:do_make_chain([en_gb, en_us], [], DMap)).

make_chain_base_already_present_test() ->
    %% [pt_br, pt, de] → [pt_br, pt, de]  (pt already present in remaining)
    DMap = #{pt_br => pt},
    ?assertEqual([pt_br, pt, de],
        graphdb_language:do_make_chain([pt_br, pt, de], [], DMap)).

make_chain_base_inserted_test() ->
    %% [pt_br, de] → [pt_br, pt, de]  (pt absent from full chain)
    DMap = #{pt_br => pt},
    ?assertEqual([pt_br, pt, de],
        graphdb_language:do_make_chain([pt_br, de], [], DMap)).

-endif.
