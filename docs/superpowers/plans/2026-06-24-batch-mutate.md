<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Batch `mutate/1` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tier-3 batch write entry point `graphdb_mgr:mutate/1` that
applies an ordered list of `add_relationship` / `retire_node` /
`unretire_node` mutations atomically in one Mnesia transaction.

**Architecture:** `mutate/1` is a plain exported function (not a
`gen_server:call`), mirroring `graphdb_mgr:transaction/1`. It runs three
phases: (1) static validation (no DB, no allocation), (2) a resource
pre-pass that resolves the seeded attr nrefs once and allocates one rel-id
pair per `add_relationship` — all **outside** the transaction, and (3) one
`graphdb_mgr:transaction/1` that folds the prepared mutations in order,
dispatching each to a tier-1 in-transaction primitive. To make
`add_relationship` composable inside that fold, its existing in-transaction
body is extracted verbatim into a new exported tier-1 primitive
`graphdb_instance:add_relationship_in_txn/9` (the "add, don't rewrap"
pattern from PRs #44/#45).

**Tech Stack:** Erlang/OTP 28.5, Mnesia, rebar3 3.27 (invoke as repo-local
`./rebar3` — PATH/kerl are preset; do **not** prefix with `source ~/.bashrc`).
Common Test for integration tests.

**Design:** `docs/designs/batch-mutate-design.md` (approved). Read it first.

## Global Constraints

- Source files use **hard tabs** for indentation (match the surrounding
  file exactly — never expand tabs to spaces).
- Every module keeps its existing header (copyright block, author, revision
  history, `-module`, attributes, NYI/UEM macros, explicit `-export`).
- `mutate/1` is a **plain exported function**, never a `gen_server:call` /
  `handle_call`. Within `graphdb_mgr` it calls the transaction runner
  fully-qualified as `graphdb_mgr:transaction(...)` (matching the existing
  `set_retired/3` style).
- **The central invariant (load-bearing):** `rel_id_server:get_id_pair/0`
  and `graphdb_attr:seeded_nrefs/0` are gen_server calls and run **only** in
  phase 2, **outside** the transaction. Phase 3's fold calls the `_in_txn`
  primitives **directly** — never `transaction/1`, never `get_id_pair/0`,
  never `seeded_nrefs/0` inside the transaction fun.
- Return contract is **opaque, bare-reason**: `{ok, [Result]}` on success
  (every op returns `ok`, so `{ok, [ok, ...]}`), `{error, Reason}` with the
  **bare** domain reason of the first aborting mutation, whole batch rolled
  back. `mutate([]) -> {ok, []}` with no transaction opened. No index in the
  error.
- Behaviour preservation: the §4 extraction must leave the existing
  `add_relationship` behaviour byte-identical — the existing
  `graphdb_instance` and `graphdb_mgr` add_relationship tests must pass
  unchanged.
- Build/test from the project root. Compile: `./rebar3 compile` (must be
  warning-free). CT for one suite:
  `./rebar3 ct --suite apps/graphdb/test/<suite>` (see each task for the
  exact command).

---

### Task 1: Extract `add_relationship_in_txn/9` (behaviour-preserving)

Lift the in-transaction body of `do_add_relationship/7` into a new exported
tier-1 primitive on `graphdb_instance`, and make `do_add_relationship/7` a
thin wrapper that allocates the rel-id pair, reads its two seeded nrefs from
`State`, and runs the primitive through `graphdb_mgr:transaction/1`. No
behaviour changes — the proof is that the existing add_relationship tests
pass unchanged.

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` — export list at
  `apps/graphdb/src/graphdb_instance.erl:119-137`; `do_add_relationship/7`
  at `apps/graphdb/src/graphdb_instance.erl:1189-1214`.

**Interfaces:**
- Consumes: existing private helpers `validate_arc_endpoints_in_txn/6`,
  `resolve_arc_classes_in_txn/2`, `resolve_template_in_txn/2`,
  `build_connection_rows/7`, and `graphdb_class:validate_template_scope_in_txn/3`
  (all unchanged).
- Produces: exported
  `graphdb_instance:add_relationship_in_txn(IdPair, SourceNref, CharNref,
  TargetNref, ReciprocalNref, TemplateSpec, AVPSpec, TkAttr, RetAttr) -> ok`
  where `IdPair :: {integer(), integer()}`, `TemplateSpec :: default |
  integer()`, `AVPSpec :: {[map()], [map()]}`, `TkAttr`/`RetAttr ::
  integer()`. Must run inside an active Mnesia transaction; aborts via
  `mnesia:abort/1` on any domain failure. Consumed by Task 2's `mutate/1`.

- [ ] **Step 1: Add `add_relationship_in_txn/9` to the export list**

In the public `-export([...])` block (`graphdb_instance.erl:119-137`), add
the primitive right after `add_class_membership/2`, under a new comment line:

```erlang
		add_class_membership/2,
		%% Tier-1 in-transaction primitive (write-path seam)
		add_relationship_in_txn/9,
```

- [ ] **Step 2: Extract the primitive and rewrite `do_add_relationship/7`**

Replace the whole of `do_add_relationship/7`
(`apps/graphdb/src/graphdb_instance.erl:1189-1214`) — keep its existing
doc-comment header (lines 1178-1188) above it — with the thin wrapper below,
**followed immediately** by the new primitive (note the body of the
primitive is the verbatim lift of the old `Txn` fun):

```erlang
do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateSpec, AVPSpec, State) ->
	TkAttr  = State#state.target_kind_avp_nref,
	RetAttr = State#state.retired_nref,
	%% Allocate the rel-id pair up-front, OUTSIDE the transaction: get_id_pair
	%% is a gen_server call and must never run inside an mnesia fun.  A
	%% validation abort inside the primitive orphans this pair -- harmless
	%% (allocate-outside-transaction doctrine).
	IdPair = rel_id_server:get_id_pair(),
	case graphdb_mgr:transaction(fun() ->
			add_relationship_in_txn(IdPair, SourceNref, CharNref, TargetNref,
				ReciprocalNref, TemplateSpec, AVPSpec, TkAttr, RetAttr)
		end) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.


%%-----------------------------------------------------------------------------
%% add_relationship_in_txn(IdPair, Source, Char, Target, Reciprocal,
%%     TemplateSpec, AVPSpec, TkAttr, RetAttr) -> ok
%%
%% Tier-1 write-path primitive.  Must run inside an active mnesia transaction;
%% never opens its own.  Validates endpoints, resolves source/target class and
%% template scope, then writes the two directed connection rows -- all with
%% bare mnesia ops, signalling any domain failure via mnesia:abort/1.  The
%% rel-id pair must be allocated by the caller (get_id_pair is a gen_server
%% call and must never run inside an mnesia fun).  Composes into a caller's
%% single transaction (the write-path seam's tier-1 contract); used by both
%% do_add_relationship/7 (tier-2) and graphdb_mgr:mutate/1 (tier-3).
%% Phase order: validate endpoints -> resolve classes -> resolve template ->
%% validate scope -> write.
%%-----------------------------------------------------------------------------
add_relationship_in_txn({_Id1, _Id2} = IdPair, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateSpec, AVPSpec, TkAttr, RetAttr) ->
	ok = validate_arc_endpoints_in_txn(SourceNref, CharNref, TargetNref,
		ReciprocalNref, TkAttr, RetAttr),
	{SourceClass, TargetClass} =
		resolve_arc_classes_in_txn(SourceNref, TargetNref),
	TemplateNref = resolve_template_in_txn(TemplateSpec, SourceClass),
	ok = graphdb_class:validate_template_scope_in_txn(TemplateNref,
		SourceClass, TargetClass),
	Rows = build_connection_rows(IdPair, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, AVPSpec),
	lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
		Rows).
```

- [ ] **Step 3: Compile**

Run: `./rebar3 compile`
Expected: compiles with **zero warnings** (no unused-function or
unbound-variable warnings).

- [ ] **Step 4: Prove behaviour is preserved — run the add_relationship tests**

The extraction is byte-identical, so the existing tests must pass unchanged.

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE`
Expected: PASS (all cases green — these exercise every
`add_relationship/4,5,6` branch through `do_add_relationship/7`).

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --group write_delegation`
Expected: PASS (includes `add_relationship_delegates`).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "Extract add_relationship_in_txn/9 tier-1 primitive"
```

---

### Task 2: Implement `graphdb_mgr:mutate/1` + test group

Add the tier-3 batch entry point and its three-phase helpers to
`graphdb_mgr`, export it, and add an 8-case CT group to `graphdb_mgr_SUITE`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` — export list at
  `apps/graphdb/src/graphdb_mgr.erl:107-127`; add the new functions after
  `transaction/1` (`apps/graphdb/src/graphdb_mgr.erl:296`). `?NREF_START` is
  already in scope via the include at
  `apps/graphdb/src/graphdb_mgr.erl:51`; `set_retired_/3` already exists at
  `apps/graphdb/src/graphdb_mgr.erl:575`.
- Modify/Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl` — `all/0` at
  `apps/graphdb/test/graphdb_mgr_SUITE.erl:115-119`; `groups/0` at
  `:121-174`; the test-case `-export` block at `:59-105`;
  `init_per_testcase/2` worker-startup guard at `:217-248`; new test bodies
  appended to the file.

**Interfaces:**
- Consumes: `graphdb_instance:add_relationship_in_txn/9` (Task 1);
  `graphdb_mgr:transaction/1`; module-local `set_retired_/3`;
  `graphdb_attr:seeded_nrefs/0` returning
  `{ok, #{target_kind := integer(), retired := integer(), ...}}`;
  `rel_id_server:get_id_pair/0` returning `{integer(), integer()}`.
- Produces: exported `graphdb_mgr:mutate([mutation()]) -> {ok, [term()]} |
  {error, term()}`.

- [ ] **Step 1: Add the test-case names to the suite `-export` block**

In `apps/graphdb/test/graphdb_mgr_SUITE.erl`, inside the test-case
`-export([...])` block (`:59-105`), add (place after
`get_node_hides_retired/1`, keeping the trailing entry comma-correct):

```erlang
	get_node_hides_retired/1,
	%% Batch mutate
	mutate_empty_batch/1,
	mutate_single_add_relationship/1,
	mutate_single_retire_and_unretire/1,
	mutate_mixed_all_succeed/1,
	mutate_atomic_rollback/1,
	mutate_read_your_writes_rollback/1,
	mutate_malformed_term/1,
	mutate_permanent_tier_guard/1
```

- [ ] **Step 2: Register the `mutate` group in `all/0` and `groups/0`**

In `all/0` (`:115-119`), append `{group, mutate}`:

```erlang
all() ->
	[{group, init_tests}, {group, read_ops},
	 {group, category_guard}, {group, write_delegation},
	 {group, cache_audit}, {group, transaction_seam},
	 {group, soft_retire}, {group, mutate}].
```

In `groups/0` (`:121-174`), add the new group after the `soft_retire`
group (add a comma after the `soft_retire` group's closing `}`):

```erlang
		{soft_retire, [], [
			retire_node_sets_and_clears_marker,
			retire_node_is_idempotent,
			retire_node_refuses_permanent_tier,
			retire_node_not_found,
			get_node_hides_retired
		]},
		{mutate, [], [
			mutate_empty_batch,
			mutate_single_add_relationship,
			mutate_single_retire_and_unretire,
			mutate_mixed_all_succeed,
			mutate_atomic_rollback,
			mutate_read_your_writes_rollback,
			mutate_malformed_term,
			mutate_permanent_tier_guard
		]}
```

- [ ] **Step 3: Give the `mutate` cases the full-worker environment**

These tests need the workers started and the runtime-tier flip (same as the
`write_delegation` / `soft_retire` groups). In `init_per_testcase/2`, extend
the guard clause that starts the full worker set (`:217-231`) by adding the
eight case names to the `when` list:

```erlang
		TC =:= retire_node_not_found;
		TC =:= get_node_hides_retired;
		TC =:= mutate_empty_batch;
		TC =:= mutate_single_add_relationship;
		TC =:= mutate_single_retire_and_unretire;
		TC =:= mutate_mixed_all_succeed;
		TC =:= mutate_atomic_rollback;
		TC =:= mutate_read_your_writes_rollback;
		TC =:= mutate_malformed_term;
		TC =:= mutate_permanent_tier_guard ->
```

- [ ] **Step 4: Write the failing tests**

Append the following section to the end of
`apps/graphdb/test/graphdb_mgr_SUITE.erl`, **before** the
`%% Internal Helpers` section (`:694`). (Indent with hard tabs to match the
file.)

```erlang
%%=============================================================================
%% Batch mutate Tests
%%
%% mutate/1 applies an ordered list of mutations atomically in one
%% transaction. Workers are pre-started in init_per_testcase for this group.
%%=============================================================================

%%-----------------------------------------------------------------------------
%% Empty batch is a no-op: {ok, []}, no transaction opened.
%%-----------------------------------------------------------------------------
mutate_empty_batch(_Config) ->
	?assertEqual({ok, []}, graphdb_mgr:mutate([])).

%%-----------------------------------------------------------------------------
%% A single add_relationship returns {ok, [ok]} and writes the arc.
%%-----------------------------------------------------------------------------
mutate_single_add_relationship(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MClassAR", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MKnows", "MKnownBy",
			instance),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate(
			[{add_relationship, InstA, CharNref, InstB, RecipNref}])),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([InstB], Targets).

%%-----------------------------------------------------------------------------
%% A single retire_node sets the marker; a single unretire_node clears it.
%%-----------------------------------------------------------------------------
mutate_single_retire_and_unretire(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRetire", 3),
	?assert(ClassNref >= ?NREF_START),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{retire_node, ClassNref}])),
	[#node{attribute_value_pairs = AVPs1}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs1)),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{unretire_node, ClassNref}])),
	[#node{attribute_value_pairs = AVPs2}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs2)).

%%-----------------------------------------------------------------------------
%% A mixed batch (two add_relationship + one retire) all succeeds: every
%% effect is present after commit.
%%-----------------------------------------------------------------------------
mutate_mixed_all_succeed(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MMixed", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MMA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MMB", ClassNref, 5),
	{ok, InstC, _} = graphdb_instance:create_instance("MMC", ClassNref, 5),
	{ok, {Ch1, Re1}} =
		graphdb_attr:create_relationship_attribute_pair("MM1", "MM1r", instance),
	{ok, {Ch2, Re2}} =
		graphdb_attr:create_relationship_attribute_pair("MM2", "MM2r", instance),
	Batch = [{add_relationship, InstA, Ch1, InstB, Re1},
			 {add_relationship, InstA, Ch2, InstC, Re2},
			 {retire_node, InstB}],
	?assertEqual({ok, [ok, ok, ok]}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Chars = lists:sort([R#relationship.characterization || R <- Rels,
		R#relationship.characterization =:= Ch1 orelse
		R#relationship.characterization =:= Ch2]),
	?assertEqual(lists:sort([Ch1, Ch2]), Chars),
	[#node{attribute_value_pairs = BAVPs}] = mnesia:dirty_read(nodes, InstB),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, BAVPs)).

%%-----------------------------------------------------------------------------
%% Atomic rollback: a valid add_relationship followed by a retire of a
%% nonexistent node aborts with {error, not_found}, and the relationship the
%% first mutation wrote is absent (the whole batch rolled back).
%%-----------------------------------------------------------------------------
mutate_atomic_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRollback", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MRA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MRB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MRKnows", "MRKnownBy",
			instance),
	BadNref = ?NREF_START + 999999,
	Batch = [{add_relationship, InstA, CharNref, InstB, RecipNref},
			 {retire_node, BadNref}],
	?assertEqual({error, not_found}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([], Targets).

%%-----------------------------------------------------------------------------
%% Read-your-writes rollback: retire X, then relate from X in the same batch.
%% The relationship's endpoint validation sees X's uncommitted retired marker
%% and aborts {endpoint_retired, X}; both mutations roll back, so X is NOT
%% retired afterward.
%%-----------------------------------------------------------------------------
mutate_read_your_writes_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MRYW", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MRYWA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MRYWB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MRYWK", "MRYWKr",
			instance),
	Batch = [{retire_node, InstA},
			 {add_relationship, InstA, CharNref, InstB, RecipNref}],
	?assertEqual({error, {endpoint_retired, InstA}},
		graphdb_mgr:mutate(Batch)),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, InstA),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs)).

%%-----------------------------------------------------------------------------
%% A malformed mutation term is rejected in phase 1 with
%% {error, {bad_mutation, M}}; the well-formed mutation preceding it in the
%% batch writes nothing (phase 1 rejects the whole batch before phase 2/3).
%%-----------------------------------------------------------------------------
mutate_malformed_term(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MBad", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MBadA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MBadB", ClassNref, 5),
	{ok, {CharNref, RecipNref}} =
		graphdb_attr:create_relationship_attribute_pair("MBadK", "MBadKr",
			instance),
	Bad = {frobnicate, 1, 2},
	Batch = [{add_relationship, InstA, CharNref, InstB, RecipNref}, Bad],
	?assertEqual({error, {bad_mutation, Bad}}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	Targets = [R#relationship.target_nref || R <- Rels,
		R#relationship.characterization =:= CharNref],
	?assertEqual([], Targets).

%%-----------------------------------------------------------------------------
%% The permanent-tier guard rejects retire/unretire of a node below
%% ?NREF_START with {error, permanent_node_immutable}, before any write.
%% Asserts the bootstrap node carries no retired marker afterward
%% (attribute-specific check -- node 27 may carry other AVPs).
%%-----------------------------------------------------------------------------
mutate_permanent_tier_guard(_Config) ->
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:mutate([{retire_node, 27}])),
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, 27),
	?assertEqual(false, lists:any(
		fun(#{attribute := A, value := true}) when A =:= RetAttr -> true;
		   (_) -> false end, AVPs)).
```

- [ ] **Step 5: Run the new group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --group mutate`
Expected: FAIL — `mutate_empty_batch` (and the rest) fail because
`graphdb_mgr:mutate/1` is undefined (`undef` / `function mutate/1
undefined`).

- [ ] **Step 6: Add `mutate/1` to the `graphdb_mgr` export list**

In the public `-export([...])` block (`apps/graphdb/src/graphdb_mgr.erl:107-127`),
add `mutate/1` to the write-operations group (after `update_node_avps/2`):

```erlang
		update_node_avps/2,
		%% Batch write (tier-3 entry point)
		mutate/1,
		%% Transaction helper (write-path seam)
		transaction/1,
```

- [ ] **Step 7: Implement `mutate/1` and its phase helpers**

Insert the following immediately after the `transaction/1` definition
(after `apps/graphdb/src/graphdb_mgr.erl:296`):

```erlang
%%-----------------------------------------------------------------------------
%% mutate([Mutation]) -> {ok, [Result]} | {error, Reason}
%%
%% Tier-3 batch write entry point: applies an ordered list of mutations
%% ATOMICALLY in one graphdb_mgr:transaction/1, composing the write-path
%% seam's tier-1 primitives directly. All commit or none do.
%%
%% Mutation grammar (tagged tuples mirroring the public arities):
%%   {add_relationship, S, C, T, R}                       default template, no AVPs
%%   {add_relationship, S, C, T, R, Template}             explicit template nref
%%   {add_relationship, S, C, T, R, Template, {Fwd, Rev}} + per-direction AVPs
%%   {retire_node,   Nref}
%%   {unretire_node, Nref}
%%
%% Returns {ok, [Result]} -- one native success value per mutation in list
%% order (every op returns `ok` today, so {ok, [ok, ok, ...]}) -- or the bare
%% {error, Reason} of the first aborting mutation with the whole batch rolled
%% back. mutate([]) -> {ok, []} (no transaction opened).
%%
%% Three phases: (1) static validation -- tuple shape + the permanent-tier
%% guard, no DB, no allocation; (2) a resource pre-pass OUTSIDE the
%% transaction -- resolve the seeded attr nrefs once and allocate one rel-id
%% pair per add_relationship (gen_server calls); (3) one transaction folding
%% the prepared list in order, dispatching each to a tier-1 in-txn primitive.
%%
%% Plain function, not a gen_server:call -- mnesia:transaction/1 runs in the
%% calling process and phase 2 calls OTHER gen_servers, so routing mutate
%% through graphdb_mgr would needlessly serialise batches.
%% See docs/designs/batch-mutate-design.md.
%%-----------------------------------------------------------------------------
-spec mutate([tuple()]) -> {ok, [term()]} | {error, term()}.
mutate(Mutations) ->
	case validate_mutations(Mutations) of
		ok               -> run_mutations(Mutations);
		{error, _} = Err -> Err
	end.

%% Phase 1: static validation. No DB access, no allocation. A malformed term
%% -> {error, {bad_mutation, M}}; a permanent-tier retire/unretire ->
%% {error, permanent_node_immutable} (the same static guard set_retired/3
%% applies in the solo path).
validate_mutations([]) ->
	ok;
validate_mutations([M | Rest]) ->
	case validate_mutation(M) of
		ok               -> validate_mutations(Rest);
		{error, _} = Err -> Err
	end.

validate_mutation({add_relationship, _S, _C, _T, _R}) ->
	ok;
validate_mutation({add_relationship, _S, _C, _T, _R, _Template}) ->
	ok;
validate_mutation({add_relationship, _S, _C, _T, _R, _Template, {_Fwd, _Rev}}) ->
	ok;
validate_mutation({retire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Nref);
validate_mutation({unretire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Nref);
validate_mutation(M) ->
	{error, {bad_mutation, M}}.

tier_guard(Nref) when Nref >= ?NREF_START -> ok;
tier_guard(_Nref)                         -> {error, permanent_node_immutable}.

%% Phases 2 + 3. Precondition: Mutations already passed validate_mutations/1.
%% Empty batch short-circuits with no transaction.
run_mutations([]) ->
	{ok, []};
run_mutations(Mutations) ->
	%% Phase 2 (outside the transaction): resolve the seeded attr nrefs once,
	%% and allocate one rel-id pair per add_relationship.
	{ok, #{target_kind := TkAttr, retired := RetAttr}} =
		graphdb_attr:seeded_nrefs(),
	Prepared = [prepare(M) || M <- Mutations],
	%% Phase 3: one transaction folding the prepared list in order.
	graphdb_mgr:transaction(fun() ->
		[dispatch(P, TkAttr, RetAttr) || P <- Prepared]
	end).

%% Phase 2 per-mutation prep. Allocates one rel-id pair per add_relationship
%% via rel_id_server (a gen_server call -- MUST stay outside the transaction)
%% and normalises each add_relationship to the explicit
%% (TemplateSpec, AVPSpec) form. retire/unretire need no resources.
%% Prepared add_relationship shape:
%%   {add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec}
prepare({add_relationship, S, C, T, R}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		default, {[], []}};
prepare({add_relationship, S, C, T, R, Template}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		Template, {[], []}};
prepare({add_relationship, S, C, T, R, Template, AVPSpec}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		Template, AVPSpec};
prepare({retire_node, _Nref} = M) ->
	M;
prepare({unretire_node, _Nref} = M) ->
	M.

%% Phase 3 dispatch. Runs INSIDE the transaction: no gen_server calls, no
%% transaction/1, no rel-id allocation here (all done in phase 2). Each
%% tier-1 primitive returns ok or calls mnesia:abort/1.
dispatch({add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec},
		TkAttr, RetAttr) ->
	graphdb_instance:add_relationship_in_txn(IdPair, S, C, T, R, TemplateSpec,
		AVPSpec, TkAttr, RetAttr);
dispatch({retire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Nref, true, RetAttr);
dispatch({unretire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Nref, false, RetAttr).
```

- [ ] **Step 8: Compile**

Run: `./rebar3 compile`
Expected: compiles with **zero warnings**.

- [ ] **Step 9: Run the new group to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --group mutate`
Expected: PASS — all 8 cases green.

- [ ] **Step 10: Run the whole `graphdb_mgr` suite (no regressions)**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS — every group green (init_tests, read_ops, category_guard,
write_delegation, cache_audit, transaction_seam, soft_retire, mutate).

- [ ] **Step 11: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "Add graphdb_mgr:mutate/1 tier-3 batch entry point"
```

---

### Task 3: Documentation

Record the new tier-3 entry point in the worker guide, the architecture
doc, and the task tracker. No code changes.

**Files:**
- Modify: `apps/graphdb/CLAUDE.md` — `graphdb_mgr` worker section and the
  `graphdb_instance` worker section.
- Modify: `docs/Architecture.md` — the write-path / transaction-seam area.
- Modify: `TASKS.md` — the "Batch `mutate([Mutation])`" bullet at
  `TASKS.md:149`.

**Interfaces:**
- Consumes: nothing (docs only).
- Produces: nothing.

- [ ] **Step 1: Flip the TASKS.md tracker entry to IMPLEMENTED**

In `TASKS.md`, replace the single-line bullet at `TASKS.md:149`:

```markdown
- **Batch `mutate([Mutation])`** — the tier-3 entry point.
```

with:

```markdown
- **Batch `mutate([Mutation])`** — IMPLEMENTED. Tier-3 batch entry point
  `graphdb_mgr:mutate/1`: applies an ordered list of `add_relationship` /
  `retire_node` / `unretire_node` mutations atomically in one
  `graphdb_mgr:transaction/1`, composing tier-1 primitives directly. Opaque
  bare-reason contract (`{ok, [ok, ...]}` | `{error, Reason}`, whole-batch
  rollback, `mutate([]) -> {ok, []}`). Phase 2 resolves the seeded attr
  nrefs once and allocates one rel-id pair per `add_relationship` outside
  the transaction; phase 3 folds the prepared list in order. Required one
  behaviour-preserving extraction —
  `graphdb_instance:add_relationship_in_txn/9`. Design
  `docs/designs/batch-mutate-design.md`; plan
  `docs/superpowers/plans/2026-06-24-batch-mutate.md`.
```

- [ ] **Step 2: Add the `mutate/1` blurb to the `graphdb_mgr` worker section**

In `apps/graphdb/CLAUDE.md`, in the `### graphdb_mgr — Primary Coordinator`
section, add a bullet to its API list:

```markdown
- `mutate/1` — tier-3 batch entry point. Applies an ordered list of
  `add_relationship` / `retire_node` / `unretire_node` mutations atomically
  in one `transaction/1` (all commit or none). Tagged-tuple grammar; opaque
  bare-reason contract `{ok, [ok, ...]}` | `{error, Reason}` with whole-batch
  rollback; `mutate([]) -> {ok, []}`. A **plain function**, not a
  `gen_server:call` — it owns the transaction in the caller's process. See
  `docs/designs/batch-mutate-design.md`.
```

- [ ] **Step 3: Add `add_relationship_in_txn/9` to the `graphdb_instance` tier-1 list**

In `apps/graphdb/CLAUDE.md`, in the `### graphdb_instance` section, append a
sentence to the `add_relationship/4,5,6` bullet (or add a dedicated bullet)
noting the extracted primitive:

```markdown
- `add_relationship_in_txn/9` (IdPair, S, C, T, R, TemplateSpec, AVPSpec,
  TkAttr, RetAttr) — tier-1 **in-transaction** primitive (bare-mnesia twin
  of `add_relationship`'s transaction body; aborts on failure, never opens
  its own txn). The caller allocates the rel-id pair up-front.
  `do_add_relationship/7` (tier-2) and `graphdb_mgr:mutate/1` (tier-3) both
  compose it into their single transaction.
```

- [ ] **Step 4: Note the tier-3 entry on the write path in Architecture.md**

In `docs/Architecture.md`, in the section describing the write-path
transaction seam / tiers, add one sentence noting the tier-3 batch entry
point now exists:

```markdown
The tier-3 batch entry point `graphdb_mgr:mutate/1` applies an ordered list
of `add_relationship` / `retire_node` / `unretire_node` mutations atomically
in one transaction, composing the tier-1 primitives directly.
```

(Place it adjacent to the existing transaction-seam / `transaction/1`
description. If no such section exists, add the sentence where the
`graphdb_mgr` write API is described — keep it at architectural altitude,
one sentence.)

- [ ] **Step 5: Verify the docs render and commit**

Confirm the three files read cleanly (tables aligned, fenced code blocks
tagged). No build step.

```bash
git add apps/graphdb/CLAUDE.md docs/Architecture.md TASKS.md
git commit -m "Docs: batch mutate/1 tier-3 entry point"
```

---

## Self-Review

**Spec coverage** (against `docs/designs/batch-mutate-design.md`):

- §1 scope (3 ops; creates/delete/update deferred) — Task 2 grammar + Task 1
  primitive cover exactly `add_relationship`, `retire_node`, `unretire_node`. ✓
- §2 tagged-tuple grammar (5 shapes) — `validate_mutation/1` + `prepare/1`
  clauses, Task 2 Step 7. ✓
- §3.1 opaque bare-reason contract; `mutate([]) -> {ok, []}` — `mutate/1` +
  `run_mutations/1`; tests 1, 5, 6, 8. ✓
- §3.3 no indexed error — the contract is bare `{error, Reason}`; test 5/6/7
  assert bare reasons. ✓
- §3.4 read-your-writes rollback (`{endpoint_retired, X}`) — test 6. ✓
- §4 extract `add_relationship_in_txn/9`, `do_add_relationship/7` delegates,
  behaviour-preserving — Task 1 (proof = existing suites Step 4). ✓
- §5 three phases; plain function; allocation/seeds outside txn, primitives
  inside — Task 2 Step 7 (`run_mutations`/`prepare`/`dispatch`). ✓
- §7 eight test cases + behaviour preservation — Task 2 Step 4 (8 cases),
  Task 1 Step 4 (preservation). ✓
- §8 files touched — Task 1 (graphdb_instance), Task 2 (graphdb_mgr +
  SUITE), Task 3 (CLAUDE.md, Architecture.md, TASKS.md). ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every
run step gives the exact command and expected result. ✓

**Type consistency:** `add_relationship_in_txn/9` signature is identical in
Task 1 (definition), Task 2 Step 7 (`dispatch/3` call site), and Task 3
(doc). Prepared add_relationship tuple
`{add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec}` is produced
by `prepare/1` and matched by `dispatch/3` — same 8-element shape. `mutate/1`
return `{ok, [term()]} | {error, term()}` matches the tests' assertions. ✓
