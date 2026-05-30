%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: May 2026
%% Description: Common Test integration suite for graphdb_nref.
%%              Tests switchable allocation facade (permanent vs. runtime
%%              phases) and persistent_term durability across restarts.
%%---------------------------------------------------------------------
-module(graphdb_nref_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    compute_from_empty_returns_label_start/1,
    compute_from_populated_resumes/1,
    sequential_unique_and_monotonic/1,
    spillover_raises_runtime_floor/1,
    runtime_phase_delegates_to_nref_server/1,
    restart_in_runtime_phase_stays_safe/1
]).

all() ->
    [compute_from_empty_returns_label_start,
     compute_from_populated_resumes,
     sequential_unique_and_monotonic,
     spillover_raises_runtime_floor,
     runtime_phase_delegates_to_nref_server,
     restart_in_runtime_phase_stays_safe].

init_per_testcase(_TC, Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
        "nref_" ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    %% Isolate per-testcase: fresh cwd so nref DETS files (created in cwd)
    %% do not carry the allocator counter across testcases.
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(nodes,
        [{record_name, node}, {attributes, [nref, kind, parents, classes, attribute_value_pairs]}]),
    graphdb_nref:set_permanent_phase(),
    {ok, _} = graphdb_nref:start_link(),
    [{orig_cwd, OrigCwd} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_server:stop(graphdb_nref),
    catch persistent_term:erase({graphdb_nref, phase}),
    catch mnesia:stop(),
    catch mnesia:delete_schema([node()]),
    catch application:stop(nref),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    file:set_cwd(proplists:get_value(orig_cwd, Config)),
    ok.

%% Helper: write a node row with a given nref (only nref matters here).
put_node(Nref) ->
    Rec = {node, Nref, attribute, [], [], []},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(nodes, Rec, write) end),
    ok.

compute_from_empty_returns_label_start(_Config) ->
    ?assertEqual(?LABEL_START, graphdb_nref:get_next()).

compute_from_populated_resumes(_Config) ->
    ok = put_node(10000),   %% English (permanent, below ?NREF_START)
    ok = put_node(10050),
    ok = put_node(2000000), %% a runtime node — must be ignored by the scan
    ?assertEqual(10051, graphdb_nref:get_next()),
    ?assertEqual(10052, graphdb_nref:get_next()).

sequential_unique_and_monotonic(_Config) ->
    A = graphdb_nref:get_next(),
    B = graphdb_nref:get_next(),
    C = graphdb_nref:get_next(),
    ?assertEqual([?LABEL_START, ?LABEL_START + 1, ?LABEL_START + 2], [A, B, C]).

spillover_raises_runtime_floor(_Config) ->
    ok = put_node(?NREF_START - 1),   %% permanent tier is now "full"
    N = graphdb_nref:get_next(),      %% hands out ?NREF_START (spillover)
    ?assertEqual(?NREF_START, N),
    %% runtime floor must have been raised above the spilled nref
    ?assert(nref_server:get_nref() >= ?NREF_START + 1).

runtime_phase_delegates_to_nref_server(_Config) ->
    ok = graphdb_nref:set_runtime_phase(),
    ?assert(graphdb_nref:get_next() >= ?NREF_START).

restart_in_runtime_phase_stays_safe(_Config) ->
    ok = graphdb_nref:set_runtime_phase(),
    ok = gen_server:stop(graphdb_nref),
    {ok, _} = graphdb_nref:start_link(),
    %% durable phase flag survived the restart: still runtime tier
    ?assert(graphdb_nref:get_next() >= ?NREF_START).
