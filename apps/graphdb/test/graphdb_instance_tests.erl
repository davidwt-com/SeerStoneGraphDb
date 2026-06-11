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


%%=============================================================================
%% Firing report helpers (B2-D6) tests
%%=============================================================================

mk_rule(N) -> {node, N, instance, [], [c], [#{attribute => 1, value => "r"}]}.

add_outcome_creates_then_appends_test() ->
	R0 = [],
	Rule = mk_rule(100),
	Dep = #{mode => mandatory, multiplicity => {2, 2}, template => 31},
	R1 = graphdb_instance:add_outcome(R0, Rule, Dep,
			#{owner => 5, index => 1, status => fired, child => 200}),
	?assertMatch([#{rule := _, deployment := Dep, outcomes := [_]}], R1),
	R2 = graphdb_instance:add_outcome(R1, Rule, Dep,
			#{owner => 5, index => 2, status => fired, child => 201}),
	[#{outcomes := Outs}] = R2,
	?assertEqual(2, length(Outs)).            %% same rule -> one rule_report

merge_reports_unions_by_rule_test() ->
	Rule = mk_rule(100),
	Dep = #{mode => auto, multiplicity => {1, 1}, template => 31},
	A = graphdb_instance:add_outcome([], Rule, Dep,
			#{owner => 5, index => 1, status => fired, child => 200}),
	B = graphdb_instance:add_outcome([], Rule, Dep,
			#{owner => 6, index => 1, status => fired, child => 300}),
	Merged = graphdb_instance:merge_reports(A, B),
	?assertEqual(1, length(Merged)),          %% one rule_report
	[#{outcomes := Outs}] = Merged,
	?assertEqual(2, length(Outs)).

report_not_attempted_marks_planned_and_culprit_test() ->
	Bolt = #{class => 10, name => "Bolt", rule => mk_rule(100),
			 mandatory_children => [], auto_rules => []},
	PlanSoFar = #{class => 9, name => undefined, rule => root,
				  mandatory_children => [Bolt], auto_rules => []},
	Culprit = mk_rule(101),
	Failure = #{plan_so_far => PlanSoFar, culprit => Culprit},
	R = graphdb_instance:report_not_attempted(some_reason, Failure),
	Status = fun(N) ->
		[#{outcomes := [#{status := S}]}] =
			[RR || RR = #{rule := {node, X, _,_,_,_}} <- R, X =:= N],
		S
	end,
	?assertEqual(not_attempted, Status(100)),
	?assertEqual(failed, Status(101)).

summarize_counts_test() ->
	Rule = mk_rule(100),
	Dep = #{mode => mandatory, multiplicity => {1, 1}, template => 31},
	R0 = graphdb_instance:add_outcome([], Rule, Dep,
			#{owner => 5, index => 1, status => fired, child => 200}),
	R1 = graphdb_instance:add_outcome(R0, Rule, Dep,
			#{owner => 5, index => 1, status => failed, reason => x}),
	R2 = graphdb_instance:add_outcome(R1, Rule, Dep,
			#{owner => 5, index => 1, status => proposed, proposed_class => 9,
			  name => "P"}),
	?assertEqual(#{fired => 1, failed => 1, not_attempted => 0, proposed => 1,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(R2)).
