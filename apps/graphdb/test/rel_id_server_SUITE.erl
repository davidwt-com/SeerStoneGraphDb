%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-19
%% Description: Common Test integration suite for rel_id_server.
%%              Each test case gets its own isolated temp directory;
%%              rel_id_server is started fresh per testcase with its
%%              own DETS file.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-05-19 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026-05-19 Author: David W. Thomas
%%
%%---------------------------------------------------------------------
-module(rel_id_server_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "rel_id_").

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
    get_id_returns_integer/1,
    get_id_returns_distinct_values/1,
    get_id_is_monotonic/1,
    persists_counter_across_restart/1,
    get_id_pair_returns_integers/1,
    get_id_pair_are_consecutive/1,
    get_id_pair_no_overlap_with_get_id/1
]).

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [{group, counter}].

groups() ->
    [{counter, [sequence], [
        get_id_returns_integer,
        get_id_returns_distinct_values,
        get_id_is_monotonic,
        persists_counter_across_restart,
        get_id_pair_returns_integers,
        get_id_pair_are_consecutive,
        get_id_pair_no_overlap_with_get_id
    ]}].


%%---------------------------------------------------------------------
%% Suite setup
%%---------------------------------------------------------------------
init_per_suite(Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    [{orig_cwd, OrigCwd} | Config].

end_per_suite(_Config) ->
    ok.


%%---------------------------------------------------------------------
%% Per-testcase setup/teardown
%%---------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique  = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir  = filename:join([OrigCwd, "_build", "test", "ct_scratch",
                             ?DIR_PREFIX ++ Unique]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    ok = file:set_cwd(TmpDir),
    {ok, _} = rel_id_server:start_link(),
    [{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_server:stop(rel_id_server),
    catch dets:close(rel_id_server),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    ok.


delete_dir_recursive(Dir) ->
    IsAbsolute = filename:pathtype(Dir) =:= absolute,
    HasScratch = string:find(Dir, ?SCRATCH_SENTINEL) =/= nomatch,
    HasPrefix  = string:find(filename:basename(Dir), ?DIR_PREFIX)
                     =:= filename:basename(Dir),
    case IsAbsolute andalso HasScratch andalso HasPrefix of
        true  -> os:cmd("rm -rf \"" ++ Dir ++ "\""), ok;
        false -> ct:fail({unsafe_delete, Dir})
    end.


%%=====================================================================
%% Counter Tests
%%=====================================================================

get_id_returns_integer(_Config) ->
    Id = rel_id_server:get_id(),
    ?assert(is_integer(Id)),
    ?assert(Id > 0).

get_id_returns_distinct_values(_Config) ->
    Id1 = rel_id_server:get_id(),
    Id2 = rel_id_server:get_id(),
    Id3 = rel_id_server:get_id(),
    ?assertNotEqual(Id1, Id2),
    ?assertNotEqual(Id2, Id3),
    ?assertNotEqual(Id1, Id3).

get_id_is_monotonic(_Config) ->
    Id1 = rel_id_server:get_id(),
    Id2 = rel_id_server:get_id(),
    Id3 = rel_id_server:get_id(),
    ?assert(Id2 > Id1),
    ?assert(Id3 > Id2).

persists_counter_across_restart(_Config) ->
    Id1 = rel_id_server:get_id(),
    Id2 = rel_id_server:get_id(),
    Id3 = rel_id_server:get_id(),
    %% Stop the gen_server (terminate/2 closes DETS)
    ok = gen_server:stop(rel_id_server),
    %% Belt-and-suspenders: close DETS in case stop didn't flush
    catch dets:close(rel_id_server),
    %% Restart from same DETS file (cwd unchanged)
    {ok, _} = rel_id_server:start_link(),
    Id4 = rel_id_server:get_id(),
    ?assert(Id4 > Id1),
    ?assert(Id4 > Id2),
    ?assert(Id4 > Id3).

get_id_pair_returns_integers(_Config) ->
    {A, B} = rel_id_server:get_id_pair(),
    ?assert(is_integer(A)),
    ?assert(is_integer(B)),
    ?assert(A > 0),
    ?assert(B > 0).

get_id_pair_are_consecutive(_Config) ->
    {A, B} = rel_id_server:get_id_pair(),
    ?assertEqual(A + 1, B).

get_id_pair_no_overlap_with_get_id(_Config) ->
    {_A, B} = rel_id_server:get_id_pair(),
    Next = rel_id_server:get_id(),
    ?assertEqual(B + 1, Next).
