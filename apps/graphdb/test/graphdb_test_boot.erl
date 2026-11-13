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
%%				teardown reset and the seeds-unchanged assertion.
%%---------------------------------------------------------------------
-module(graphdb_test_boot).

-include_lib("common_test/include/ct.hrl").

-export([
	flip/0,
	reset/0,
	assert_seeds_unchanged/1
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
					ct:fail({seeds_changed, TC, [E || {E, _, _} <- Bad]})
			end;
		_ -> ok
	end.
