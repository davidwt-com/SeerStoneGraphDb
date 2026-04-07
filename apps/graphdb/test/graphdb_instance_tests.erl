%%---------------------------------------------------------------------
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of
%% SeerStone, Inc.
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: April 2026
%% Description: EUnit tests for graphdb_instance pure internal functions.
%%				Tests find_avp_value/2 — the AVP lookup helper used by
%%				the inheritance resolution engine.
%%---------------------------------------------------------------------
-module(graphdb_instance_tests).

-include_lib("eunit/include/eunit.hrl").


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
			#{attribute => 20, value => "b"},
			#{attribute => 30, value => "c"}],
	?assertEqual({ok, "b"}, graphdb_instance:find_avp_value(AVPs, 20)).

find_avp_value_integer_value_test() ->
	AVPs = [#{attribute => 5, value => 999}],
	?assertEqual({ok, 999}, graphdb_instance:find_avp_value(AVPs, 5)).

find_avp_value_atom_value_test() ->
	AVPs = [#{attribute => 7, value => active}],
	?assertEqual({ok, active}, graphdb_instance:find_avp_value(AVPs, 7)).
