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
    unimplemented_query_returns_error/1
]).

suite() ->
    [{timetrap, {seconds, 30}}].

all() ->
    [{group, skeleton}].

groups() ->
    [{skeleton, [], [
        starts_and_is_registered,
        parse_query_is_identity,
        new_session_has_snapshot,
        refresh_bumps_snapshot,
        unimplemented_query_returns_error
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
    %% Any unhandled query shape should yield {error, not_implemented}
    %% — Q5 is not landed yet (Task 8), use it as a placeholder.
    Q = #q_instances_of{class = ?NREF_CLASSES, recursive = false},
    ?assertEqual({error, not_implemented},
                 graphdb_query:execute_query(Q)).
