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
    get_id_pair_no_overlap_with_get_id/1,
    first_boot_seeds_at_one/1,
    seed_is_deferred_until_first_use/1,
    seeds_above_existing_relationship_ids/1,
    refuses_to_seed_when_max_id_undeterminable/1
]).

suite() -> [{timetrap, {seconds, 30}}].

all() ->
    [{group, counter}, {group, seeding}].

groups() ->
    [{counter, [sequence], [
        get_id_returns_integer,
        get_id_returns_distinct_values,
        get_id_is_monotonic,
        persists_counter_across_restart,
        get_id_pair_returns_integers,
        get_id_pair_are_consecutive,
        get_id_pair_no_overlap_with_get_id
    ]},
     {seeding, [sequence], [
        first_boot_seeds_at_one,
        seed_is_deferred_until_first_use,
        seeds_above_existing_relationship_ids,
        refuses_to_seed_when_max_id_undeterminable
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
%% Mnesia is started (schema-less, so ram-only) before rel_id_server for
%% every case.  The real deployment always has mnesia up -- it is an
%% application dependency of graphdb -- and seed_from_mnesia/0 now treats
%% an unreachable mnesia as fatal rather than defaulting the counter to 1.
%% Starting the server with no mnesia at all, as this suite used to, is
%% not a state the system can actually be in.
init_per_testcase(_TC, Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique  = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir  = filename:join([OrigCwd, "_build", "test", "ct_scratch",
                             ?DIR_PREFIX ++ Unique]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    ok = file:set_cwd(TmpDir),
    ok = mnesia:start(),
    {ok, _} = rel_id_server:start_link(),
    [{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_server:stop(rel_id_server),
    catch dets:close(rel_id_server),
    stop_mnesia(),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    ok.


%%---------------------------------------------------------------------
%% Helpers
%%---------------------------------------------------------------------

%% mnesia:stop/0 is asynchronous; wait for it so the next case starts
%% from a known state and the temp dir can be removed safely.
stop_mnesia() ->
    mnesia:stop(),
    wait_until(fun() -> mnesia:system_info(is_running) =:= no end, 50).

wait_until(_Pred, 0) ->
    ct:fail(timeout_waiting_for_condition);
wait_until(Pred, N) ->
    case Pred() of
        true  -> ok;
        false -> timer:sleep(20), wait_until(Pred, N - 1)
    end.

%% Stop the server and delete its DETS file, so the next start_link/0 has
%% no counter key and must re-run seed_from_mnesia/0.
wipe_counter(Config) ->
    catch gen_server:stop(rel_id_server),
    catch dets:close(rel_id_server),
    TmpDir = proplists:get_value(tmp_dir, Config),
    ok = file:delete(filename:join(TmpDir, "rel_id_server.dets")).

%% The subset of the real relationships table this suite needs: same
%% record name and attribute order, ram_copies so nothing touches disk.
create_relationships_table() ->
    {atomic, ok} = mnesia:create_table(relationships,
        [{record_name, relationship},
         {attributes, [id, kind, source_nref, characterization,
                       target_nref, reciprocal, avps]}]),
    ok.

write_relationship(Id) ->
    ok = mnesia:dirty_write(relationships,
        {relationship, Id, connection, 1, 21, 2, 22, []}).


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


%%=====================================================================
%% Counter Seeding Tests
%%
%% seed_from_mnesia/0 runs only when the DETS counter key is absent.
%% These cases cover its three outcomes.
%%=====================================================================

%% Genuine first boot: rel_id_server starts before graphdb_mgr, so the
%% relationships table does not exist yet. No rows can exist, so 1 is the
%% correct seed.
first_boot_seeds_at_one(Config) ->
    %% Assert absence via system_info/1, not table_info(_, size): the
    %% latter returns 0 for a table that does not exist, which is
    %% indistinguishable from one that exists and is empty.
    ?assertNot(lists:member(relationships, mnesia:system_info(tables))),
    wipe_counter(Config),
    {ok, _} = rel_id_server:start_link(),
    ?assertEqual(1, rel_id_server:get_id()).

%% The counter is seeded on first use, not in init/1. It has to be: under
%% graphdb_sup, rel_id_server starts before graphdb_mgr, and it is
%% graphdb_mgr:init/1 that runs graphdb_bootstrap -- which starts mnesia
%% and creates the relationships table. At init/1 there is nothing to read.
seed_is_deferred_until_first_use(Config) ->
    wipe_counter(Config),
    {ok, _} = rel_id_server:start_link(),
    ?assertEqual([], dets:lookup(rel_id_server, counter)),
    _ = rel_id_server:get_id(),
    ?assertMatch([{counter, _}], dets:lookup(rel_id_server, counter)).

%% Regression: DETS lost while Mnesia survived (restore, data-dir move,
%% partial recovery). The counter MUST resume above the highest existing
%% id -- seeding at 1 would hand out ids that collide with live primary
%% keys, and mnesia:write would then silently overwrite those rows.
%%
%% Staged in the real startup order: the server starts while the
%% relationships table still does not exist, the table then appears
%% already populated, and only then is an id requested. That ordering is
%% the point -- it is why seeding cannot happen in init/1.
seeds_above_existing_relationship_ids(Config) ->
    wipe_counter(Config),
    {ok, _} = rel_id_server:start_link(),
    ok = create_relationships_table(),
    %% Written out of order; 4242 is the high-water mark, not the last write.
    lists:foreach(fun write_relationship/1, [7, 4242, 41]),
    FirstId = rel_id_server:get_id(),
    ?assertEqual(4243, FirstId),
    %% The point of the assertion above: no id collides with a live row.
    ?assertEqual([], [I || I <- [FirstId, rel_id_server:get_id()],
                           mnesia:dirty_read(relationships, I) =/= []]).

%% If the highest existing id cannot be determined, the server must fail
%% loudly rather than default the counter to 1 -- 1 is precisely the value
%% that corrupts, so a silent fallback is the worst available guess.
refuses_to_seed_when_max_id_undeterminable(Config) ->
    wipe_counter(Config),
    stop_mnesia(),
    {ok, _} = rel_id_server:start_link(),
    process_flag(trap_exit, true),
    ?assertExit({rel_id_server_seed, _}, rel_id_server:get_id()),
    receive {'EXIT', _Pid, rel_id_server_seed} -> ok after 100 -> ok end,
    process_flag(trap_exit, false),
    %% Restore mnesia so end_per_testcase tears down from a known state.
    ok = mnesia:start().
