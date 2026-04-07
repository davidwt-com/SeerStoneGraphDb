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
%% Description: EUnit tests for graphdb_class pure functions.
%%				Tests is_valid_parent_kind/1 and collect_qc_nrefs/2.
%%---------------------------------------------------------------------
-module(graphdb_class_tests).

-include_lib("eunit/include/eunit.hrl").


%%=============================================================================
%% is_valid_parent_kind/1 tests
%%=============================================================================

valid_parent_kind_category_test() ->
	?assert(graphdb_class:is_valid_parent_kind(category)).

valid_parent_kind_class_test() ->
	?assert(graphdb_class:is_valid_parent_kind(class)).

valid_parent_kind_attribute_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(attribute)).

valid_parent_kind_instance_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(instance)).

valid_parent_kind_atom_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(bogus)).

valid_parent_kind_integer_test() ->
	?assertNot(graphdb_class:is_valid_parent_kind(42)).


%%=============================================================================
%% collect_qc_nrefs/2 tests
%%=============================================================================

collect_qc_nrefs_empty_test() ->
	?assertEqual([], graphdb_class:collect_qc_nrefs([], 100)).

collect_qc_nrefs_no_match_test() ->
	AVPs = [
		#{attribute => 19, value => "Car"},
		#{attribute => 200, value => somevalue}
	],
	?assertEqual([], graphdb_class:collect_qc_nrefs(AVPs, 100)).

collect_qc_nrefs_single_match_test() ->
	AVPs = [
		#{attribute => 19, value => "Car"},
		#{attribute => 100, value => 42}
	],
	?assertEqual([42], graphdb_class:collect_qc_nrefs(AVPs, 100)).

collect_qc_nrefs_multiple_matches_test() ->
	AVPs = [
		#{attribute => 19, value => "Car"},
		#{attribute => 100, value => 42},
		#{attribute => 100, value => 43},
		#{attribute => 200, value => ignored}
	],
	?assertEqual([42, 43], graphdb_class:collect_qc_nrefs(AVPs, 100)).

collect_qc_nrefs_preserves_order_test() ->
	AVPs = [
		#{attribute => 100, value => 99},
		#{attribute => 100, value => 1},
		#{attribute => 100, value => 50}
	],
	?assertEqual([99, 1, 50], graphdb_class:collect_qc_nrefs(AVPs, 100)).
