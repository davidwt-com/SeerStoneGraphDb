%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: EUnit tests for graphdb_mgr pure functions.
%%				These tests do NOT require Mnesia, nref_server, or
%%				the graphdb_mgr gen_server to be running -- they
%%				exercise only the direction validation and client-side
%%				argument checking.
%%---------------------------------------------------------------------
-module(graphdb_mgr_tests).

-include_lib("eunit/include/eunit.hrl").


%%=============================================================================
%% validate_direction/1 tests
%%=============================================================================

validate_direction_outgoing_test() ->
	?assertEqual(ok, graphdb_mgr:validate_direction(outgoing)).

validate_direction_incoming_test() ->
	?assertEqual(ok, graphdb_mgr:validate_direction(incoming)).

validate_direction_both_test() ->
	?assertEqual(ok, graphdb_mgr:validate_direction(both)).

validate_direction_invalid_atom_test() ->
	?assertEqual({error, {invalid_direction, sideways}},
		graphdb_mgr:validate_direction(sideways)).

validate_direction_invalid_string_test() ->
	?assertEqual({error, {invalid_direction, "outgoing"}},
		graphdb_mgr:validate_direction("outgoing")).

validate_direction_invalid_integer_test() ->
	?assertEqual({error, {invalid_direction, 42}},
		graphdb_mgr:validate_direction(42)).

validate_direction_undefined_test() ->
	?assertEqual({error, {invalid_direction, undefined}},
		graphdb_mgr:validate_direction(undefined)).


%%=============================================================================
%% Client-side validation tests
%%
%% These verify that API functions validate arguments before making a
%% gen_server call.  The gen_server is not running during EUnit tests,
%% so any call that reaches gen_server:call would crash.  The fact that
%% these return a proper error proves the validation short-circuits.
%%=============================================================================

get_relationships_invalid_direction_test() ->
	%% validate_direction rejects before gen_server:call -- no server needed
	?assertEqual({error, {invalid_direction, sideways}},
		graphdb_mgr:get_relationships(1, sideways)).

get_relationships_invalid_direction_string_test() ->
	?assertEqual({error, {invalid_direction, "both"}},
		graphdb_mgr:get_relationships(1, "both")).
