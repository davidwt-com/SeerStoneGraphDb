# Slice B — `update_node_avps/2` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `graphdb_mgr:update_node_avps/2` (currently a `not_implemented` stub) as a merge/upsert over a node's `attribute_value_pairs`, through the three-tier write-path seam, and expose it as a fourth `mutate/1` batch mutation kind.

**Architecture:** A pure merge helper (`apply_avp_updates/2`) and a pure well-formedness validator (`validate_avp_updates/1`); a tier-1 in-txn primitive (`update_node_avps_in_txn/3`) that reads the node under a write lock, runs the in-txn guards, applies the merge, and writes back; a tier-2 public wrapper that runs the client-side + pre-txn guards and owns one `transaction/1`; and a `{update_node_avps, Nref, AVPs}` grammar entry composing the tier-1 primitive into `mutate/1`'s batch transaction. This mirrors the existing `set_retired` / `set_retired_` / `ensure_retired_nref` pattern exactly.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (repo-local `./rebar3`), Mnesia, EUnit, Common Test.

**Design doc:** `docs/designs/slice-b-update-node-avps-design.md`

## Global Constraints

- All edits to files under `apps/graphdb/` use **hard tabs** for indentation (match the surrounding file exactly).
- Invoke rebar3 as plain `./rebar3 ...` from the project root — **no** `source ~/.bashrc &&` prefix.
- **LOAD-BEARING INVARIANT:** no `gen_server` call (`graphdb_attr:seeded_nrefs/0`, `ensure_retired_nref/1`, etc.) may run inside an Mnesia transaction fun. The seeded `retired` nref (`RetAttr`) is resolved *outside* the txn and passed into the tier-1 primitive as a parameter.
- **Three-tier seam:** tier-1 (`*_in_txn`) is bare-mnesia, never opens its own txn, calls `mnesia:abort/1` on failure, and is exported for composition. Tier-2 owns exactly one `graphdb_mgr:transaction/1` and maps `{ok, ok} -> ok`, `{error, R} -> {error, R}`. Tier-3 (`mutate/1`) composes tier-1 directly — never tier-2 (no nested txns).
- **Error contract:** bare reasons via `mnesia:abort/1` — `not_found`, `{unknown_attribute, A}`, `use_retire_api`. Pre-txn/client-side failures: `{error, permanent_node_immutable}`, `{error, {invalid_avp, Bad}}`, `{error, category_nodes_are_immutable}`.
- **Delete signal:** an update map *lacking* the `value` key deletes that attribute. `value => undefined` is a real upsert (declared-but-unbound), never a delete.
- **Order-preserving upsert:** overwriting an existing attribute keeps its list position; a new attribute appends to the tail.
- After every state-mutating CT testcase, `end_per_testcase` asserts `graphdb_mgr:verify_caches/0` returns `ok`. `update_node_avps` touches only `attribute_value_pairs` (never `parents`/`classes`), so caches are unaffected — but the assertion must stay green.
- Module conventions: copyright/header block, NYI/UEM macros, explicit `-export` lists (never `export_all`). Match the existing `graphdb_mgr.erl` style.
- End commit messages with the trailers:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF
  ```

---

### Task 1: Pure AVP helpers + well-formedness validator

The merge algorithm and the input validator are pure functions (no Mnesia, no gen_server). They are built and unit-tested first so the tier-1 primitive (Task 2) and `mutate/1` validation (Task 3) can compose them.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (add internal functions in the Internal Functions section, after `set_marker/3`'s neighbours near line 713; add TEST-only exports near line 147)
- Test: `apps/graphdb/test/graphdb_mgr_tests.erl` (append new EUnit tests)

**Interfaces:**
- Produces:
  - `validate_avp_updates(AVPs) -> ok | {error, {invalid_avp, term()}}` — pure; `AVPs` must be a list whose every element is a map with key set exactly `[attribute]` (delete) or `[attribute, value]` (upsert), `attribute` an `integer()`.
  - `apply_avp_updates(Existing :: [map()], Updates :: [map()]) -> [map()]` — pure; left-to-right fold applying upsert (in-place-or-append) / delete (by value-key absence).

- [ ] **Step 1: Add TEST-only exports**

In the `-ifdef(TEST).` export block (currently lines 146-151), add the two helpers:

```erlang
-ifdef(TEST).
-export([
		validate_direction/1,
		check_category_guard/1,
		validate_avp_updates/1,
		apply_avp_updates/2
		]).
-endif.
```

- [ ] **Step 2: Write the failing EUnit tests**

Append to `apps/graphdb/test/graphdb_mgr_tests.erl` (before EOF). These use only exported pure functions, so no server is needed.

```erlang

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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./rebar3 eunit --module=graphdb_mgr_tests`
Expected: FAIL — `validate_avp_updates/1` and `apply_avp_updates/2` are undefined.

- [ ] **Step 4: Implement the pure helpers**

In `apps/graphdb/src/graphdb_mgr.erl`, in the Internal Functions section (after the `is_retired_avp_present/2` helper near line 736), add:

```erlang
%%-----------------------------------------------------------------------------
%% validate_avp_updates(AVPs) -> ok | {error, {invalid_avp, term()}}
%% Pure, client-side. AVPs must be a list whose every element is a map whose
%% key set is exactly [attribute] (delete) or [attribute, value] (upsert),
%% with an integer attribute. Anything else is {invalid_avp, Offender}.
%%-----------------------------------------------------------------------------
validate_avp_updates(AVPs) when is_list(AVPs) ->
	validate_avp_updates_(AVPs);
validate_avp_updates(Other) ->
	{error, {invalid_avp, Other}}.

validate_avp_updates_([]) ->
	ok;
validate_avp_updates_([M | Rest]) ->
	case valid_avp_update(M) of
		true  -> validate_avp_updates_(Rest);
		false -> {error, {invalid_avp, M}}
	end.

valid_avp_update(#{attribute := A} = M) when is_integer(A) ->
	case lists:sort(maps:keys(M)) of
		[attribute]        -> true;   %% delete
		[attribute, value] -> true;   %% upsert
		_                  -> false
	end;
valid_avp_update(_) ->
	false.

%%-----------------------------------------------------------------------------
%% apply_avp_updates(Existing, Updates) -> NewAVPs
%% Pure. Folds each update over the AVP list, left-to-right:
%%   - update map WITH a `value` key  -> upsert: replace the matching entry
%%     in place if present, else append the new entry to the tail
%%   - update map WITHOUT a `value` key -> delete that attribute (no-op if
%%     absent)
%% Precondition: Updates already passed validate_avp_updates/1.
%%-----------------------------------------------------------------------------
apply_avp_updates(Existing, Updates) ->
	lists:foldl(fun apply_one_avp_update/2, Existing, Updates).

apply_one_avp_update(#{attribute := A} = Update, AVPs) ->
	case maps:is_key(value, Update) of
		true  -> upsert_avp(AVPs, A, maps:get(value, Update));
		false -> delete_avp(AVPs, A)
	end.

%% Replace the entry for A in place if present, else append to the tail.
upsert_avp(AVPs, A, V) ->
	New = #{attribute => A, value => V},
	case lists:any(fun(P) -> is_avp_for(P, A) end, AVPs) of
		true ->
			[case is_avp_for(P, A) of true -> New; false -> P end
				|| P <- AVPs];
		false ->
			AVPs ++ [New]
	end.

delete_avp(AVPs, A) ->
	[P || P <- AVPs, not is_avp_for(P, A)].

is_avp_for(#{attribute := A}, A) -> true;
is_avp_for(_, _)                 -> false.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./rebar3 eunit --module=graphdb_mgr_tests`
Expected: PASS — all `validate_avp_updates_*` and `apply_avp_updates_*` tests green, plus the pre-existing `validate_direction`/client-side tests.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_tests.erl
git commit -m "Slice B: pure AVP merge + well-formedness helpers

apply_avp_updates/2 (order-preserving upsert + value-less-map delete) and
validate_avp_updates/1, with EUnit coverage. Pure functions only; no
Mnesia. Foundation for the tier-1 primitive and mutate/1 grammar entry.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

### Task 2: Tier-1 primitive + tier-2 wrapper (solo path)

Replace the `not_implemented` stub with the real implementation: a tier-1 in-txn primitive and the tier-2 public wrapper. Mirrors `set_retired` / `set_retired_` / `ensure_retired_nref`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl`
  - external API export block (lines 107-129): export the tier-1 primitive
  - public function `update_node_avps/2` (lines 273-274): add client-side validation
  - `handle_call({update_node_avps, ...})` (lines 549-558): replace stub body
  - Internal Functions: add `do_update_node_avps/3` and `update_node_avps_in_txn/3`
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl`
  - fix the pre-existing `category_guard_allows_noncategory_update/1` assertion
  - add a new `update_avps` group with full-stack testcases
  - add the new testcases to `-export`, `all/0`, `groups/0`, and the `init_per_testcase` worker-start guard clause
- Test: `apps/graphdb/test/graphdb_mgr_tests.erl` (one client-side short-circuit test)

**Interfaces:**
- Consumes: `validate_avp_updates/1`, `apply_avp_updates/2` (Task 1); `ensure_retired_nref/1`, `check_category_guard/1`, `graphdb_mgr:transaction/1` (existing); `?NREF_START` (`graphdb_nrefs.hrl`).
- Produces:
  - `update_node_avps_in_txn(Nref, AVPs, RetAttr) -> ok` — tier-1; runs inside a caller's txn; `mnesia:abort/1` on `not_found` | `{unknown_attribute, A}` | `use_retire_api`. Used by `mutate/1` (Task 3).
  - `update_node_avps(Nref, AVPs) -> ok | {error, term()}` — tier-2 public API.

- [ ] **Step 1: Export the tier-1 primitive**

In the external API `-export` block, add it under the write operations (after `mutate/1`'s neighbours), with a clarifying comment:

```erlang
			update_node_avps/2,
			%% Batch write (tier-3 entry point)
			mutate/1,
			%% Tier-1 in-txn write primitive (composed by mutate/1)
			update_node_avps_in_txn/3,
```

- [ ] **Step 2: Write the failing CT testcases (new `update_avps` group)**

First register the group. In `all/0` (line 126-130) add `{group, update_avps}`:

```erlang
all() ->
	[{group, init_tests}, {group, read_ops},
	 {group, category_guard}, {group, write_delegation},
	 {group, cache_audit}, {group, transaction_seam},
	 {group, soft_retire}, {group, mutate}, {group, update_avps}].
```

In `groups/0` (after the `mutate` group, line 196) add:

```erlang
		,
		{update_avps, [], [
			update_node_avps_upsert_roundtrip,
			update_node_avps_overwrite_preserves_head,
			update_node_avps_delete,
			update_node_avps_delete_absent_noop,
			update_node_avps_undefined_retained,
			update_node_avps_unknown_attribute,
			update_node_avps_retired_marker_rejected,
			update_node_avps_not_found,
			update_node_avps_permanent_tier,
			update_node_avps_atomic_rollback
		]}
```

In the testcase `-export` block (the second `-export` listing testcases, starting line 59), add the ten names:

```erlang
	update_node_avps_upsert_roundtrip/1,
	update_node_avps_overwrite_preserves_head/1,
	update_node_avps_delete/1,
	update_node_avps_delete_absent_noop/1,
	update_node_avps_undefined_retained/1,
	update_node_avps_unknown_attribute/1,
	update_node_avps_retired_marker_rejected/1,
	update_node_avps_not_found/1,
	update_node_avps_permanent_tier/1,
	update_node_avps_atomic_rollback/1,
```

In the `init_per_testcase(TC, Config) when ...` guard clause (lines 240-264) — the one that starts all workers — append the ten testcases to the `TC =:= ...` disjunction (so the full worker stack is started for them):

```erlang
		TC =:= mutate_add_relationship_with_avps;
		TC =:= update_node_avps_upsert_roundtrip;
		TC =:= update_node_avps_overwrite_preserves_head;
		TC =:= update_node_avps_delete;
		TC =:= update_node_avps_delete_absent_noop;
		TC =:= update_node_avps_undefined_retained;
		TC =:= update_node_avps_unknown_attribute;
		TC =:= update_node_avps_retired_marker_rejected;
		TC =:= update_node_avps_not_found;
		TC =:= update_node_avps_permanent_tier;
		TC =:= update_node_avps_atomic_rollback ->
```

Then append the testcase bodies (after the `mutate` tests, near EOF). A shared helper creates a runtime instance and a literal attribute:

```erlang

%%=============================================================================
%% update_node_avps Tests (solo / tier-2 path)
%%
%% Full worker stack started in init_per_testcase. A runtime instance is the
%% subject; a runtime literal attribute supplies a valid attribute nref.
%%=============================================================================

%% Helper: create a runtime class + instance + one literal attribute.
%% Returns {InstNref, AttrNref}.
ua_setup(Name) ->
	{ok, ClassNref} = graphdb_class:create_class("UAClass" ++ Name, 3),
	{ok, InstNref, _} =
		graphdb_instance:create_instance("UAInst" ++ Name, ClassNref, 5),
	{ok, AttrNref} =
		graphdb_attr:create_literal_attribute("UAAttr" ++ Name, string),
	{InstNref, AttrNref}.

ua_avps(Nref) ->
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, Nref),
	AVPs.

ua_value(Nref, AttrNref) ->
	AVPs = ua_avps(Nref),
	case [V || #{attribute := A, value := V} <- AVPs, A =:= AttrNref] of
		[V] -> V;
		[]  -> not_found
	end.

%%-----------------------------------------------------------------------------
%% Upsert a new attribute -> get_node / dirty_read reflect it.
%%-----------------------------------------------------------------------------
update_node_avps_upsert_roundtrip(_Config) ->
	{Inst, Attr} = ua_setup("RT"),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr, value => "red"}])),
	?assertEqual("red", ua_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Overwriting the name attribute keeps it at the head of the AVP list.
%%-----------------------------------------------------------------------------
update_node_avps_overwrite_preserves_head(_Config) ->
	{Inst, _Attr} = ua_setup("Head"),
	[#{attribute := NameAttr} | _] = ua_avps(Inst),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => NameAttr, value => "Renamed"}])),
	[#{attribute := NameAttr, value := "Renamed"} | _] = ua_avps(Inst).

%%-----------------------------------------------------------------------------
%% A value-less map deletes the attribute.
%%-----------------------------------------------------------------------------
update_node_avps_delete(_Config) ->
	{Inst, Attr} = ua_setup("Del"),
	ok = graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr, value => "x"}]),
	?assertEqual("x", ua_value(Inst, Attr)),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr}])),
	?assertEqual(not_found, ua_value(Inst, Attr)).

%%-----------------------------------------------------------------------------
%% Deleting an attribute the node does not carry is a no-op (still ok).
%%-----------------------------------------------------------------------------
update_node_avps_delete_absent_noop(_Config) ->
	{Inst, Attr} = ua_setup("DelAbsent"),
	Before = ua_avps(Inst),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst, [#{attribute => Attr}])),
	?assertEqual(Before, ua_avps(Inst)).

%%-----------------------------------------------------------------------------
%% value => undefined upserts a real (declared-but-unbound) entry, not a delete.
%%-----------------------------------------------------------------------------
update_node_avps_undefined_retained(_Config) ->
	{Inst, Attr} = ua_setup("Undef"),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => Attr, value => undefined}])),
	AVPs = ua_avps(Inst),
	?assert(lists:member(#{attribute => Attr, value => undefined}, AVPs)).

%%-----------------------------------------------------------------------------
%% An upsert referencing a nonexistent attribute aborts {unknown_attribute, _}.
%%-----------------------------------------------------------------------------
update_node_avps_unknown_attribute(_Config) ->
	{Inst, _Attr} = ua_setup("Unknown"),
	BadAttr = ?NREF_START + 888888,
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:update_node_avps(Inst, [#{attribute => BadAttr, value => 1}])).

%%-----------------------------------------------------------------------------
%% Targeting the seeded `retired` attribute is rejected -> use_retire_api.
%%-----------------------------------------------------------------------------
update_node_avps_retired_marker_rejected(_Config) ->
	{Inst, _Attr} = ua_setup("Ret"),
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	?assertEqual({error, use_retire_api},
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => RetAttr, value => true}])).

%%-----------------------------------------------------------------------------
%% A nonexistent runtime node -> {error, not_found}.
%%-----------------------------------------------------------------------------
update_node_avps_not_found(_Config) ->
	{_Inst, Attr} = ua_setup("NF"),
	BadNref = ?NREF_START + 999999,
	?assertEqual({error, not_found},
		graphdb_mgr:update_node_avps(BadNref, [#{attribute => Attr, value => 1}])).

%%-----------------------------------------------------------------------------
%% A permanent-tier node -> {error, permanent_node_immutable}.
%%-----------------------------------------------------------------------------
update_node_avps_permanent_tier(_Config) ->
	%% Nref 6 (Names) is a permanent-tier attribute node.
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:update_node_avps(6, [#{attribute => 6, value => 1}])).

%%-----------------------------------------------------------------------------
%% Atomicity: a multi-AVP call where a later AVP aborts leaves the node
%% unchanged (the earlier AVP in the same call is rolled back).
%%-----------------------------------------------------------------------------
update_node_avps_atomic_rollback(_Config) ->
	{Inst, Attr} = ua_setup("Atomic"),
	BadAttr = ?NREF_START + 888888,
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:update_node_avps(Inst,
			[#{attribute => Attr, value => "red"},
			 #{attribute => BadAttr, value => "boom"}])),
	?assertEqual(not_found, ua_value(Inst, Attr)).
```

- [ ] **Step 3: Fix the pre-existing `category_guard_allows_noncategory_update` assertion**

This test (line 529) currently asserts `not_implemented`. After implementation, nref 6 passes the category guard but is permanent-tier, so the result becomes `permanent_node_immutable`. Update it:

```erlang
%%-----------------------------------------------------------------------------
%% update_node_avps passes the category guard for non-category nodes; nref 6
%% is permanent-tier, so it is then refused with permanent_node_immutable
%% (proving it cleared the category guard rather than being rejected as a
%% category node).
%%-----------------------------------------------------------------------------
category_guard_allows_noncategory_update(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	%% Nref 6 (Names) is an attribute node -- clears the category guard
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:update_node_avps(6, [#{attribute => 99, value => "test"}])).
```

- [ ] **Step 4: Add the client-side short-circuit EUnit test**

Append to `apps/graphdb/test/graphdb_mgr_tests.erl`:

```erlang

%%=============================================================================
%% update_node_avps/2 client-side validation
%%=============================================================================

%% Malformed AVPs are rejected before any gen_server:call -- the server is
%% not running under EUnit, so a proper error proves the short-circuit.
update_node_avps_malformed_short_circuits_test() ->
	?assertEqual({error, {invalid_avp, "bad"}},
		graphdb_mgr:update_node_avps(123, ["bad"])).
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --group=update_avps`
Expected: FAIL — `update_node_avps` still returns `{error, not_implemented}`; the new group's testcases fail their assertions.

Run: `./rebar3 eunit --module=graphdb_mgr_tests`
Expected: FAIL — `update_node_avps_malformed_short_circuits_test` (no client-side validation yet; reaches `gen_server:call` and crashes).

- [ ] **Step 6: Add client-side validation to the public function**

Replace `update_node_avps/2` (lines 273-274). Update its header comment to drop "Actual update not yet implemented":

```erlang
%%-----------------------------------------------------------------------------
%% update_node_avps(Nref, AVPs) -> ok | {error, term()}
%%
%% Merges a list of attribute-value-pair updates into a node's AVP list,
%% atomically. Each update map upserts (replace-in-place-or-append) when it
%% carries a `value` key, or deletes that attribute when it does not.
%% Well-formedness is validated client-side before the gen_server:call.
%% Rejects category nodes ({error, category_nodes_are_immutable}) and the
%% permanent tier ({error, permanent_node_immutable}).
%%-----------------------------------------------------------------------------
-spec update_node_avps(integer(), [map()]) -> ok | {error, term()}.
update_node_avps(Nref, AVPs) ->
	case validate_avp_updates(AVPs) of
		ok ->
			gen_server:call(?MODULE, {update_node_avps, Nref, AVPs});
		{error, _} = Err ->
			Err
	end.
```

- [ ] **Step 7: Replace the handle_call stub body**

Replace the `handle_call({update_node_avps, Nref, _AVPs}, _From, State)` clause (lines 549-558) with one that, after the category guard, delegates to a tier-2 helper that owns the transaction:

```erlang
handle_call({update_node_avps, Nref, AVPs}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			{Reply, State1} = do_update_node_avps(Nref, AVPs, State),
			{reply, Reply, State1}
	end;
```

- [ ] **Step 8: Add the tier-2 helper and tier-1 primitive**

In the Internal Functions section, near `set_retired`/`set_retired_` (after line 698), add:

```erlang
%%-----------------------------------------------------------------------------
%% do_update_node_avps(Nref, AVPs, State) -> {ok | {error, Reason}, State'}
%%
%% Tier-2 body. Static permanent-tier guard refuses the whole permanent tier
%% (Nref < ?NREF_START); otherwise lazily resolves the seeded `retired` nref
%% (caching it in State) and runs the tier-1 primitive through the
%% transaction seam. Returns the possibly-updated State so the cache sticks.
%% Precondition: AVPs already passed validate_avp_updates/1 (client-side) and
%% Nref passed check_category_guard/1.
%%-----------------------------------------------------------------------------
do_update_node_avps(Nref, _AVPs, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
do_update_node_avps(Nref, AVPs, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> update_node_avps_in_txn(Nref, AVPs, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.

%%-----------------------------------------------------------------------------
%% update_node_avps_in_txn(Nref, AVPs, RetAttr) -> ok
%% Tier-1 primitive. Must run inside an active mnesia transaction. Reads the
%% node under a write lock; aborts not_found if absent. Aborts use_retire_api
%% if any update targets the seeded `retired` attribute. Aborts
%% {unknown_attribute, A} if any UPSERT references a non-attribute node.
%% Applies the merge and writes the node back. RetAttr is resolved by the
%% caller OUTSIDE the transaction (load-bearing: no gen_server call in-txn).
%%-----------------------------------------------------------------------------
update_node_avps_in_txn(Nref, AVPs, RetAttr) ->
	case mnesia:read(nodes, Nref, write) of
		[] ->
			mnesia:abort(not_found);
		[Node] ->
			ok = guard_retired_marker(AVPs, RetAttr),
			ok = guard_attribute_existence(AVPs),
			New = apply_avp_updates(Node#node.attribute_value_pairs, AVPs),
			mnesia:write(nodes, Node#node{attribute_value_pairs = New}, write)
	end.

%% Abort if any update (upsert or delete) targets the seeded `retired` attr.
guard_retired_marker(AVPs, RetAttr) ->
	case lists:any(fun(#{attribute := A}) -> A =:= RetAttr end, AVPs) of
		true  -> mnesia:abort(use_retire_api);
		false -> ok
	end.

%% Abort if any UPSERT references a node that is not an existing attribute
%% node. Deletes (no `value` key) are skipped -- removing a reference does
%% not require the attribute to still exist.
guard_attribute_existence(AVPs) ->
	Upserts = [A || #{attribute := A} = M <- AVPs, maps:is_key(value, M)],
	lists:foreach(fun(A) ->
		case mnesia:read(nodes, A, read) of
			[#node{kind = attribute}] -> ok;
			_                         -> mnesia:abort({unknown_attribute, A})
		end
	end, Upserts),
	ok.
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --group=update_avps`
Expected: PASS — all ten testcases green.

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --group=category_guard`
Expected: PASS — including the updated `category_guard_allows_noncategory_update`.

Run: `./rebar3 eunit --module=graphdb_mgr_tests`
Expected: PASS — including `update_node_avps_malformed_short_circuits_test`.

- [ ] **Step 10: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl apps/graphdb/test/graphdb_mgr_tests.erl
git commit -m "Slice B: implement update_node_avps/2 (tier-1 + tier-2)

Replace the not_implemented stub with the merge/upsert write op: tier-1
update_node_avps_in_txn/3 (node-existence, attribute-existence on upserts,
retired-marker guards; order-preserving merge) and the tier-2 wrapper
owning one transaction/1, mirroring set_retired. Client-side
well-formedness short-circuits before the gen_server call. Updates the
pre-existing category-guard test (nref 6 now hits the permanent-tier
guard). New update_avps CT group covers round-trip, delete, undefined-
retained, every guard, and single-call atomicity.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

### Task 3: `mutate/1` grammar entry (batch path)

Add `{update_node_avps, Nref, AVPs}` as a fourth batch mutation kind composing the tier-1 primitive from Task 2.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl`
  - `mutate/1` grammar doc comment (lines 308-313)
  - `validate_mutation/1` (after line 359)
  - `prepare/1` (after line 399)
  - `dispatch/3` (after line 411)
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl` (add to the `mutate` group)

**Interfaces:**
- Consumes: `update_node_avps_in_txn/3`, `validate_avp_updates/1`, `tier_guard/1` (existing), `RetAttr` resolved in `run_mutations/1` (existing).
- Produces: a new grammar clause; no new exported function.

- [ ] **Step 1: Write the failing CT testcases**

In `groups/0`, append to the `mutate` group's list (after `mutate_add_relationship_with_avps`, line 195):

```erlang
			mutate_add_relationship_with_avps,
			mutate_single_update_node_avps,
			mutate_mixed_add_rel_and_update_avps,
			mutate_update_avps_rollback,
			mutate_update_avps_malformed
```

In the testcase `-export` block add:

```erlang
	mutate_single_update_node_avps/1,
	mutate_mixed_add_rel_and_update_avps/1,
	mutate_update_avps_rollback/1,
	mutate_update_avps_malformed/1,
```

In the `init_per_testcase` worker-start guard clause, append (after the Task 2 additions). **Task 2 left the disjunction ending `... update_node_avps_atomic_rollback ->`; change that trailing `->` to `;` before appending these, and end the new last line with `->`:**

```erlang
		TC =:= update_node_avps_atomic_rollback;
		TC =:= mutate_single_update_node_avps;
		TC =:= mutate_mixed_add_rel_and_update_avps;
		TC =:= mutate_update_avps_rollback;
		TC =:= mutate_update_avps_malformed ->
```

Append the testcase bodies after the existing `mutate_*` tests:

```erlang

%%-----------------------------------------------------------------------------
%% A single update_node_avps mutation returns {ok, [ok]} and writes the AVP.
%%-----------------------------------------------------------------------------
mutate_single_update_node_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MUAClass", 3),
	{ok, Inst, _} = graphdb_instance:create_instance("MUAInst", ClassNref, 5),
	{ok, Attr} = graphdb_attr:create_literal_attribute("MUAAttr", string),
	?assertEqual({ok, [ok]},
		graphdb_mgr:mutate([{update_node_avps, Inst,
			[#{attribute => Attr, value => "blue"}]}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, Inst),
	?assert(lists:member(#{attribute => Attr, value => "blue"}, AVPs)).

%%-----------------------------------------------------------------------------
%% A mixed batch (add_relationship + update_node_avps) all succeeds.
%%-----------------------------------------------------------------------------
mutate_mixed_add_rel_and_update_avps(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MMUAClass", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MMUAA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MMUAB", ClassNref, 5),
	{ok, {Ch, Re}} =
		graphdb_attr:create_relationship_attribute_pair("MMUAk", "MMUAkb",
			instance),
	{ok, Attr} = graphdb_attr:create_literal_attribute("MMUAAttr", string),
	Batch = [{add_relationship, InstA, Ch, InstB, Re},
			 {update_node_avps, InstA, [#{attribute => Attr, value => "green"}]}],
	?assertEqual({ok, [ok, ok]}, graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	?assertEqual([InstB],
		[R#relationship.target_nref || R <- Rels,
			R#relationship.characterization =:= Ch]),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, InstA),
	?assert(lists:member(#{attribute => Attr, value => "green"}, AVPs)).

%%-----------------------------------------------------------------------------
%% Atomic rollback: a valid add_relationship followed by an update_node_avps
%% with an unknown attribute aborts the whole batch -- the relationship the
%% first mutation wrote is absent.
%%-----------------------------------------------------------------------------
mutate_update_avps_rollback(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("MUARbClass", 3),
	{ok, InstA, _} = graphdb_instance:create_instance("MUARbA", ClassNref, 5),
	{ok, InstB, _} = graphdb_instance:create_instance("MUARbB", ClassNref, 5),
	{ok, {Ch, Re}} =
		graphdb_attr:create_relationship_attribute_pair("MUARbk", "MUARbkb",
			instance),
	BadAttr = ?NREF_START + 888888,
	Batch = [{add_relationship, InstA, Ch, InstB, Re},
			 {update_node_avps, InstA, [#{attribute => BadAttr, value => 1}]}],
	?assertEqual({error, {unknown_attribute, BadAttr}},
		graphdb_mgr:mutate(Batch)),
	{ok, Rels} = graphdb_mgr:get_relationships(InstA),
	?assertEqual([],
		[R#relationship.target_nref || R <- Rels,
			R#relationship.characterization =:= Ch]).

%%-----------------------------------------------------------------------------
%% A malformed update_node_avps mutation is rejected in static validation
%% ({error, {invalid_avp, _}}), before any transaction is opened.
%%-----------------------------------------------------------------------------
mutate_update_avps_malformed(_Config) ->
	?assertEqual({error, {invalid_avp, "bad"}},
		graphdb_mgr:mutate([{update_node_avps, 123, ["bad"]}])).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --group=mutate`
Expected: FAIL — `{update_node_avps, ...}` falls through to `validate_mutation(M) -> {error, {bad_mutation, M}}`, so the new testcases fail.

- [ ] **Step 3: Add the grammar clauses**

In `validate_mutation/1`, after the `unretire_node` clause (line 359), before the catch-all:

```erlang
validate_mutation({update_node_avps, Nref, AVPs}) when is_integer(Nref) ->
	case validate_avp_updates(AVPs) of
		ok               -> tier_guard(Nref);
		{error, _} = Err -> Err
	end;
```

In `prepare/1`, after the `unretire_node` clause (line 399) — update_node_avps needs no allocated resource. **`prepare/1`'s last clause `prepare({unretire_node, _Nref} = M) -> M.` ends in `.`; change that `.` to `;` and end the new clause with `.`:**

```erlang
prepare({unretire_node, _Nref} = M) ->
	M;
prepare({update_node_avps, _Nref, _AVPs} = M) ->
	M.
```

In `dispatch/3`, after the `unretire_node` clause (line 411):

```erlang
dispatch({update_node_avps, Nref, AVPs}, _TkAttr, RetAttr) ->
	update_node_avps_in_txn(Nref, AVPs, RetAttr).
```

(Note: `dispatch/3`'s last clause ends with `.` — when adding a clause, change the previous clause's terminating `.` to `;` and end the new clause with `.`.)

- [ ] **Step 4: Update the `mutate/1` grammar doc comment**

In the `mutate/1` header comment (lines 308-313), add the fourth kind:

```erlang
%% Mutation grammar (tagged tuples mirroring the public arities):
%%   {add_relationship, S, C, T, R}                       default template, no AVPs
%%   {add_relationship, S, C, T, R, Template}             explicit template nref
%%   {add_relationship, S, C, T, R, Template, {Fwd, Rev}} + per-direction AVPs
%%   {retire_node,      Nref}
%%   {unretire_node,    Nref}
%%   {update_node_avps, Nref, AVPs}                        merge/upsert AVP list
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --group=mutate`
Expected: PASS — all `mutate_*` testcases green, including the four new ones.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "Slice B: wire update_node_avps into mutate/1 grammar

Add {update_node_avps, Nref, AVPs} as a fourth batch mutation kind:
validate_mutation runs the pure well-formedness + permanent-tier guards in
phase 1; dispatch composes update_node_avps_in_txn/3 with the RetAttr
already resolved by run_mutations. CT covers single, mixed-with-add_rel,
whole-batch rollback, and static malformed rejection.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

### Task 4: Documentation + full-suite verification

Update the docs that record `update_node_avps` as unimplemented, mark slice B done in `TASKS.md`, and run the full suite.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (header comment, lines 31-34)
- Modify: `CLAUDE.md` (root, line 279 — Known Incomplete Areas)
- Modify: `apps/graphdb/CLAUDE.md` (graphdb_mgr API bullets + mutate grammar)
- Modify: `TASKS.md` (mark slice B implemented; trim the `mutate/1` deferred-extensions list)
- Modify: `docs/Architecture.md` (only if it asserts `update_node_avps` is unimplemented — verify first)

- [ ] **Step 1: Fix the module header comment**

In `apps/graphdb/src/graphdb_mgr.erl` (lines 31-34), the header says `delete_node and update_node_avps remain not_implemented`. Narrow it to `delete_node`:

```erlang
%% delegate directly to graphdb_class and graphdb_instance respectively;
%% add_relationship delegates to graphdb_instance.  update_node_avps merges
%% an AVP list onto a node atomically (tier-2 wrapper + update_node_avps_in_txn
%% tier-1 primitive).  delete_node remains not_implemented (no worker deletion
%% API exists yet).
```

- [ ] **Step 2: Update root `CLAUDE.md` Known Incomplete Areas**

Line 279 currently lists `delete_node/1` and `update_node_avps/2` as both returning `not_implemented`. Edit to:

```markdown
- **`graphdb_mgr` write operations** — `create_attribute/3`, `create_class/2`, `create_instance/3`, `add_relationship/4`, `update_node_avps/2` delegate to the workers / merge node AVPs; `delete_node/1` still returns `{error, not_implemented}` pending a worker that implements it
```

- [ ] **Step 3: Update `apps/graphdb/CLAUDE.md`**

In the `graphdb_mgr — Primary Coordinator` section, add a bullet for `update_node_avps/2` and extend the `mutate/1` grammar note with the fourth kind. Add after the `mutate/1` bullet:

```markdown
- `update_node_avps/2` — merges a list of AVP updates onto a node atomically
  through the transaction seam (tier-2 wrapper owning one `transaction/1`;
  tier-1 `update_node_avps_in_txn/3` does the in-txn work). Each update map
  upserts in place (or appends) when it carries a `value` key, or deletes
  that attribute when it does not (`value => undefined` is a real
  declared-but-unbound upsert, never a delete). Guards: category-immutable,
  permanent-tier, well-formedness (client-side), attribute-existence
  (upserts), and retired-marker (use `retire_node`/`unretire_node` instead).
  See `docs/designs/slice-b-update-node-avps-design.md`.
```

In the `mutate/1` bullet's grammar list, add `{update_node_avps, Nref, AVPs}` as the fourth kind.

- [ ] **Step 4: Mark slice B implemented in `TASKS.md`**

In the `### Node AVP update (slice B)` section (line 266), prefix the heading with the IMPLEMENTED marker matching the file's convention and add a short note (mirror the style of the other IMPLEMENTED entries). In the `mutate/1` IMPLEMENTED bullet's "Deferred extensions" paragraph (around line 166), remove `update_node_avps` from the future-grammar-extension list (it is now wired). Leave the slice C / slice E references intact.

- [ ] **Step 5: Verify `docs/Architecture.md`**

Run: `grep -n "update_node_avps\|not_implemented" docs/Architecture.md`
If it states `update_node_avps` is unimplemented, update that line to reflect it is implemented (tier-2 + tier-1, in the `mutate/1` grammar). If there is no such statement, make no change (an internal implementation landing inside an already-described coordinator is below architectural altitude).

- [ ] **Step 6: Run the full suite**

Run: `make test-ct-parallel`
Expected: all CT suites pass (the prior baseline plus the new `update_avps` group and four new `mutate` testcases).

Run: `./rebar3 eunit`
Expected: all EUnit pass (prior baseline plus the new pure + client-side tests).

Run: `./rebar3 compile`
Expected: clean compile, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl CLAUDE.md apps/graphdb/CLAUDE.md TASKS.md docs/Architecture.md
git commit -m "Slice B: docs + TASKS status for update_node_avps

Narrow the not_implemented note to delete_node, document update_node_avps
in the graphdb_mgr guides, add the fourth mutate/1 grammar kind, and mark
slice B IMPLEMENTED in TASKS.md (trimming it from the mutate/1 deferred
grammar-extension list).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

## Self-Review

**Spec coverage:**

| Spec section                          | Task                          |
|---------------------------------------|-------------------------------|
| §3 AVP semantics (upsert/delete)      | Task 1 (`apply_avp_updates`)  |
| §3 order-preserving upsert            | Task 1 (`upsert_avp` + test)  |
| §4 three-tier layering                | Tasks 2 (tier-1/2) + 3 (tier-3)|
| §5 well-formedness guard              | Task 1 + Task 2 (client-side) |
| §5 permanent-tier guard               | Task 2 (`do_update_node_avps`)|
| §5 node-existence guard               | Task 2 (tier-1)               |
| §5 attribute-existence (upserts only) | Task 2 (`guard_attribute_existence`) |
| §5 retired-marker protection          | Task 2 (`guard_retired_marker`)|
| §5 category guard (unchanged)         | Task 2 (handle_call)          |
| §6 return contract & atomicity        | Tasks 2 + 3 (tests)           |
| §7 mutate/1 integration               | Task 3                        |
| §8 testing (EUnit + CT)               | Tasks 1, 2, 3                 |

**Type consistency:** `update_node_avps_in_txn/3` defined in Task 2 and consumed by `dispatch/3` in Task 3 — same arity, same `(Nref, AVPs, RetAttr)` order. `validate_avp_updates/1` and `apply_avp_updates/2` defined in Task 1, consumed in Tasks 2 (public fn, tier-1) and 3 (`validate_mutation`). `RetAttr` is the seeded `retired` nref throughout.

**Placeholder scan:** none — every code step shows complete code; every run step shows the exact command and expected outcome.
