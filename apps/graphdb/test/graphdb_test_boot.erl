%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-11-13
%% Description: Test-only helper that makes Common Test suites boot the
%%				graphdb workers the way graphdb:start/2 does in
%%				production: workers start in the permanent nref phase
%%				(seeding in their init/1), then the runtime phase is
%%				set and the seed cache is loaded.  Also provides the
%%				teardown reset, the seeds-unchanged check and checks/2,
%%				which turns teardown checks into an end_per_testcase
%%				verdict.  Common Test ignores a raise from
%%				end_per_testcase but fails the case when it returns
%%				{fail, Reason}, so the checks return a verdict and
%%				never raise.
%%---------------------------------------------------------------------
-module(graphdb_test_boot).

-include_lib("common_test/include/ct.hrl").

-export([
	flip/0,
	reset/0,
	assert_seeds_unchanged/1,
	checks/2
]).

-record(node, {nref, kind, parents = [], classes = [],
	attribute_value_pairs = []}).

%% Call once, after the last seeding worker has started.
flip() ->
	ok = graphdb_nref:set_runtime_phase(),
	ok = graphdb_seeds:load(),
	ok.

reset() ->
	ok = graphdb_seeds:erase(),
	catch persistent_term:erase({graphdb_nref, phase}),
	ok.

%% assert_seeds_unchanged(TC) -> ok | {fail, {seeds_changed, TC, Nrefs}}
%%
%% Every cached seed must equal its stored row; a runtime path that
%% rewrites a seed makes the cache stale.
assert_seeds_unchanged(TC) ->
	case mnesia:system_info(is_running) of
		yes ->
			Bad = [{N#node.nref, N, Stored}
				|| N <- graphdb_seeds:all(),
				   Stored <- [mnesia:dirty_read(nodes, N#node.nref)],
				   Stored =/= [N]],
			case Bad of
				[] -> ok;
				_ ->
					ct:pal("Seeds changed in ~p:~n~p", [TC, Bad]),
					{fail, {seeds_changed, TC, [E || {E, _, _} <- Bad]}}
			end;
		_ -> ok
	end.

%% checks(TC, [fun(() -> ok | {fail, Reason})]) -> ok | {fail, Reason}
%%
%% Runs every check (each needs Mnesia, so call this before teardown
%% stops anything) and returns the first failure, or ok.  A check that
%% raises becomes {fail, {check_crashed, TC, Class, Reason}}, so the
%% rest of teardown still runs.  end_per_testcase returns the verdict
%% after its teardown.
checks(TC, Checks) ->
	Verdicts = [check(TC, C) || C <- Checks],
	case [V || {fail, _} = V <- Verdicts] of
		[]          -> ok;
		[First | _] -> First
	end.

check(TC, Check) ->
	try Check() of
		ok               -> ok;
		{fail, _} = Fail -> Fail
	catch
		Class:Reason ->
			ct:pal("Teardown check crashed in ~p: ~p:~p", [TC, Class, Reason]),
			{fail, {check_crashed, TC, Class, Reason}}
	end.
