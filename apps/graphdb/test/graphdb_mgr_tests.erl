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


%%=============================================================================
%% validate_avp_updates/1 tests (pure)
%%=============================================================================

validate_avp_updates_accepts_upsert_test() ->
	?assertEqual(ok,
		graphdb_mgr:validate_avp_updates([#{attribute => 42, value => "x"}])).

validate_avp_updates_accepts_delete_test() ->
	?assertEqual(ok,
		graphdb_mgr:validate_avp_updates([#{attribute => 42}])).

validate_avp_updates_accepts_empty_test() ->
	?assertEqual(ok, graphdb_mgr:validate_avp_updates([])).

validate_avp_updates_accepts_undefined_value_test() ->
	?assertEqual(ok,
		graphdb_mgr:validate_avp_updates([#{attribute => 42, value => undefined}])).

validate_avp_updates_rejects_non_list_test() ->
	?assertEqual({error, {invalid_avp, not_a_list}},
		graphdb_mgr:validate_avp_updates(not_a_list)).

validate_avp_updates_rejects_non_map_element_test() ->
	?assertEqual({error, {invalid_avp, "nope"}},
		graphdb_mgr:validate_avp_updates(["nope"])).

validate_avp_updates_rejects_missing_attribute_test() ->
	?assertEqual({error, {invalid_avp, #{value => 1}}},
		graphdb_mgr:validate_avp_updates([#{value => 1}])).

validate_avp_updates_rejects_noninteger_attribute_test() ->
	Bad = #{attribute => "x", value => 1},
	?assertEqual({error, {invalid_avp, Bad}},
		graphdb_mgr:validate_avp_updates([Bad])).

validate_avp_updates_rejects_extra_keys_test() ->
	Bad = #{attribute => 42, value => 1, foo => bar},
	?assertEqual({error, {invalid_avp, Bad}},
		graphdb_mgr:validate_avp_updates([Bad])).

%%=============================================================================
%% apply_avp_updates/2 tests (pure)
%%=============================================================================

apply_avp_updates_upsert_new_appends_to_tail_test() ->
	Existing = [#{attribute => 1, value => "a"}],
	Updates  = [#{attribute => 2, value => "b"}],
	?assertEqual([#{attribute => 1, value => "a"},
				  #{attribute => 2, value => "b"}],
		graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_upsert_overwrite_preserves_position_test() ->
	%% Re-binding attribute 1 keeps it at the head, not moved to the tail.
	Existing = [#{attribute => 1, value => "old"},
				#{attribute => 2, value => "b"}],
	Updates  = [#{attribute => 1, value => "new"}],
	?assertEqual([#{attribute => 1, value => "new"},
				  #{attribute => 2, value => "b"}],
		graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_delete_present_test() ->
	Existing = [#{attribute => 1, value => "a"},
				#{attribute => 2, value => "b"}],
	Updates  = [#{attribute => 1}],
	?assertEqual([#{attribute => 2, value => "b"}],
		graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_delete_absent_is_noop_test() ->
	Existing = [#{attribute => 1, value => "a"}],
	Updates  = [#{attribute => 99}],
	?assertEqual(Existing, graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_undefined_value_retained_test() ->
	%% value => undefined is an upsert (declared-but-unbound), NOT a delete.
	Existing = [],
	Updates  = [#{attribute => 1, value => undefined}],
	?assertEqual([#{attribute => 1, value => undefined}],
		graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_last_write_wins_test() ->
	Existing = [],
	Updates  = [#{attribute => 1, value => "first"},
				#{attribute => 1, value => "second"}],
	?assertEqual([#{attribute => 1, value => "second"}],
		graphdb_mgr:apply_avp_updates(Existing, Updates)).

apply_avp_updates_empty_updates_is_identity_test() ->
	Existing = [#{attribute => 1, value => "a"}],
	?assertEqual(Existing, graphdb_mgr:apply_avp_updates(Existing, [])).


%%=============================================================================
%% update_node_avps/2 client-side validation
%%=============================================================================

%% Malformed AVPs are rejected before any gen_server:call -- the server is
%% not running under EUnit, so a proper error proves the short-circuit.
update_node_avps_malformed_short_circuits_test() ->
	?assertEqual({error, {invalid_avp, "bad"}},
		graphdb_mgr:update_node_avps(123, ["bad"])).


%%=============================================================================
%% check_instance_only/2 tests (pure)
%%=============================================================================

check_instance_only_rejects_value_bearing_test() ->
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42, value => "SN-1"}],
	?assertEqual({error, {instance_only_attribute, 42}},
		graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_rejects_undefined_value_test() ->
	%% value => undefined still carries a `value` key -> still a bind attempt.
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42, value => undefined}],
	?assertEqual({error, {instance_only_attribute, 42}},
		graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_allows_delete_test() ->
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42}],
	?assertEqual(ok, graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_allows_non_marked_test() ->
	Stored = [#{attribute => 42, value => undefined}],
	Updates = [#{attribute => 42, value => "red"}],
	?assertEqual(ok, graphdb_mgr:check_instance_only(Stored, Updates)).
