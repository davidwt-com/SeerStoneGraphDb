%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: EUnit tests for graphdb_instance pure internal functions.
%%				Tests find_avp_value/2 — the AVP lookup helper used by
%%				the inheritance resolution engine.
%%---------------------------------------------------------------------
-module(graphdb_instance_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%=============================================================================
%% find_avp_value/2 tests
%%=============================================================================

find_avp_value_empty_list_test() ->
	?assertEqual(not_found, graphdb_instance:find_avp_value([], 42)).

find_avp_value_no_match_test() ->
	AVPs = [#{attribute => 10, value => "hello"}],
	?assertEqual(not_found, graphdb_instance:find_avp_value(AVPs, 42)).

find_avp_value_single_match_test() ->
	AVPs = [#{attribute => 42, value => "found_it"}],
	?assertEqual({ok, "found_it"}, graphdb_instance:find_avp_value(AVPs, 42)).

find_avp_value_first_match_wins_test() ->
	AVPs = [#{attribute => 42, value => "first"},
			#{attribute => 42, value => "second"}],
	?assertEqual({ok, "first"}, graphdb_instance:find_avp_value(AVPs, 42)).

find_avp_value_among_many_test() ->
	AVPs = [#{attribute => 10, value => "a"},
			#{attribute => ?NAME_ATTR_INSTANCE, value => "b"},
			#{attribute => ?ARC_CLASS_TO_INST, value => "c"}],
	?assertEqual({ok, "b"}, graphdb_instance:find_avp_value(AVPs, ?NAME_ATTR_INSTANCE)).

find_avp_value_integer_value_test() ->
	AVPs = [#{attribute => 5, value => 999}],
	?assertEqual({ok, 999}, graphdb_instance:find_avp_value(AVPs, 5)).

find_avp_value_atom_value_test() ->
	AVPs = [#{attribute => 7, value => active}],
	?assertEqual({ok, active}, graphdb_instance:find_avp_value(AVPs, 7)).

find_avp_value_undefined_is_not_found_test() ->
	%% value => undefined is a QC declaration, not a resolved value.
	AVPs = [#{attribute => 42, value => undefined}],
	?assertEqual(not_found, graphdb_instance:find_avp_value(AVPs, 42)).

find_avp_value_undefined_does_not_shadow_bound_in_suffix_test() ->
	%% undefined in first position should return not_found (no fallthrough).
	AVPs = [#{attribute => 42, value => undefined},
			#{attribute => 42, value => "should_not_reach"}],
	?assertEqual(not_found, graphdb_instance:find_avp_value(AVPs, 42)).
