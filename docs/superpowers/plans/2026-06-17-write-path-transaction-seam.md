<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Write-Path Transaction-Layering Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `graphdb_mgr:transaction/1`, a shared Mnesia
transaction-runner that normalises results, and document the three-tier
primitive/wrapper/batch convention it anchors.

**Architecture:** A single new exported function on `graphdb_mgr`. It
wraps `mnesia:transaction/1` and maps `{atomic, R}` → `{ok, R}` and
`{aborted, Reason}` → `{error, Reason}`. It is a plain function (not a
`gen_server:call`) because `mnesia:transaction/1` runs in the calling
process. Tier-1 primitives (functions that assume a surrounding
transaction and signal failure via `mnesia:abort/1`) compose under it.
No existing write op is changed in this slice.

**Tech Stack:** Erlang/OTP 28, Mnesia, Common Test, rebar3 3.27.

**Design:** `docs/designs/write-path-transaction-seam-design.md`

## Global Constraints

- **OTP 28 / rebar3 3.27.** Build with `./rebar3 compile` from the repo
  root (kerl PATH is preset — no `source ~/.bashrc` prefix).
- **Zero compiler warnings.** The tree compiles clean; keep it clean.
- **Module header + macro conventions.** `graphdb_mgr.erl` already has its
  copyright block, `-export` lists, and NYI/UEM macros; do not duplicate
  or disturb them. Add the new export to the existing public-API
  `-export` block, not a new one.
- **CT suite uses explicit per-group `-export` lists** (no
  `-compile(export_all)`). Every new test function MUST be added to the
  test-case `-export` block AND registered in `groups/0` AND reachable
  from `all/0`, or Common Test fails with `undef` at runtime.
- **Commit message footer.** End commit messages with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

| File                                       | Responsibility                                         |
| ------------------------------------------ | ------------------------------------------------------ |
| `apps/graphdb/src/graphdb_mgr.erl`         | Add exported `transaction/1` + its header comment      |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`  | New `transaction_seam` group: 3 CT cases proving the contract |

No supervision-tree, schema, `docs/Architecture.md`, or
`docs/diagrams/ontology-tree.md` change is required: the seam is an
internal convention plus one stateless helper.

---

## Task 1: `graphdb_mgr:transaction/1` runner + contract tests

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (export block at lines
  103–119; add the function implementation in the public-API section,
  immediately before the `verify_caches/0` public function)
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

**Interfaces:**
- Produces:
  `graphdb_mgr:transaction(fun(() -> Result)) -> {ok, Result} | {error, term()}`
  — runs `Fun` inside one Mnesia transaction; `{atomic, R}` → `{ok, R}`,
  `{aborted, Reason}` → `{error, Reason}`. `Fun` is a tier-1 primitive (or
  a composition of them): it does bare-Mnesia reads/writes and signals
  failure via `mnesia:abort/1`.

### Why these three tests

The runner's whole job is (a) result/error normalisation and (b)
inheriting Mnesia's atomicity. The three cases pin exactly that: success
passthrough, single-primitive rollback on abort, and multi-primitive
rollback (the property tier-3 batch composition relies on). The sample
primitives are throwaway funs that write bare `#node` rows at scratch
nrefs well above `?NREF_START`; each CT case already runs in an isolated
Mnesia database (`init_per_testcase` → `setup_isolated_env`), and the
temp DB is deleted in `end_per_testcase`, so no in-test cleanup is needed.
The rows written by the success case have empty `parents`/`classes` and no
arcs, so they satisfy the `verify_cache_invariant/1` audit that
`end_per_testcase` runs.

- [ ] **Step 1: Register the new group and test-case exports**

In `apps/graphdb/test/graphdb_mgr_SUITE.erl`, add the three case names to
the test-case `-export` block (the one ending at line 94, after
`rebuild_caches_restores_after_poison/1`). Add a trailing comma to the
current last entry:

```erlang
		rebuild_caches_restores_after_poison/1,
		%% Transaction seam
		transaction_commit_returns_ok/1,
		transaction_abort_rolls_back/1,
		transaction_composition_rolls_back/1
```

Add the group to `all/0` (currently lines 104–107):

```erlang
all() ->
	[{group, init_tests}, {group, read_ops},
	 {group, category_guard}, {group, write_delegation},
	 {group, cache_audit}, {group, transaction_seam}].
```

Add the group definition to `groups/0` (after the `cache_audit` group,
before the closing `]` at line 149 — add a comma after the `cache_audit`
group's closing brace):

```erlang
		{cache_audit, [], [
			verify_caches_clean_after_bootstrap,
			verify_caches_detects_poisoned_parents,
			verify_caches_detects_poisoned_classes,
			rebuild_caches_restores_after_poison
		]},
		{transaction_seam, [], [
			transaction_commit_returns_ok,
			transaction_abort_rolls_back,
			transaction_composition_rolls_back
		]}
```

These cases need no special `init_per_testcase` clause: the default
clause (line 216) starts `nref` + `rel_id_server`, and each test body
starts `graphdb_mgr` itself (creating the `nodes`/`relationships` tables),
exactly as the read-ops cases do.

- [ ] **Step 2: Write the three failing test cases**

Append these case functions to `apps/graphdb/test/graphdb_mgr_SUITE.erl`
(at the end of the file, after the last existing case). The `#node{}`
record and `?NREF_START` are already available (record defined at lines
24–30; `graphdb_nrefs.hrl` included at line 18).

```erlang
%%=============================================================================
%% Transaction Seam Tests
%%=============================================================================

%%-----------------------------------------------------------------------------
%% transaction/1 commits a primitive's writes and returns {ok, Result}.
%%-----------------------------------------------------------------------------
transaction_commit_returns_ok(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	Nref1 = ?NREF_START + 500001,
	Nref2 = ?NREF_START + 500002,
	Fun = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = Nref1, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		ok = mnesia:write(nodes,
			#node{nref = Nref2, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		{written, 2}
	end,
	?assertEqual({ok, {written, 2}}, graphdb_mgr:transaction(Fun)),
	?assertMatch([#node{nref = Nref1}], mnesia:dirty_read(nodes, Nref1)),
	?assertMatch([#node{nref = Nref2}], mnesia:dirty_read(nodes, Nref2)).

%%-----------------------------------------------------------------------------
%% transaction/1 maps mnesia:abort/1 to {error, Reason} and rolls back the
%% primitive's write (single-primitive atomicity).
%%-----------------------------------------------------------------------------
transaction_abort_rolls_back(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	NrefA = ?NREF_START + 500010,
	Fun = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = NrefA, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write),
		mnesia:abort(blocked)
	end,
	?assertEqual({error, blocked}, graphdb_mgr:transaction(Fun)),
	?assertEqual([], mnesia:dirty_read(nodes, NrefA)).

%%-----------------------------------------------------------------------------
%% transaction/1 over a composition of two primitives rolls back BOTH when
%% the second aborts -- the property tier-3 batch composition relies on.
%%-----------------------------------------------------------------------------
transaction_composition_rolls_back(_Config) ->
	{ok, _} = graphdb_mgr:start_link(),
	NrefP = ?NREF_START + 500020,
	First = fun() ->
		ok = mnesia:write(nodes,
			#node{nref = NrefP, kind = instance,
				parents = [], classes = [], attribute_value_pairs = []},
			write)
	end,
	Second = fun() -> mnesia:abort(second_failed) end,
	Fun = fun() -> First(), Second() end,
	?assertEqual({error, second_failed}, graphdb_mgr:transaction(Fun)),
	?assertEqual([], mnesia:dirty_read(nodes, NrefP)).
```

- [ ] **Step 3: Run the new group to verify it fails**

Run:

```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --group transaction_seam
```

Expected: FAIL. The cases compile but fail at runtime because
`graphdb_mgr:transaction/1` is undefined — an `undef` /
`{badrpc, ...}`-style error or a function-clause/`error:undef` on
`graphdb_mgr:transaction/1`. (If instead the suite fails to *compile*,
re-check the Step 1 export/group edits.)

- [ ] **Step 4: Add the `transaction/1` export**

In `apps/graphdb/src/graphdb_mgr.erl`, extend the public-API `-export`
block (lines 103–119). Add a `transaction/1` entry under a new comment
group, before the cache-audit exports:

```erlang
		add_relationship/4,
		delete_node/1,
		update_node_avps/2,
		%% Transaction helper (write-path seam)
		transaction/1,
		%% Cache invariant audit / repair
		verify_caches/0,
		rebuild_caches/0
		]).
```

- [ ] **Step 5: Implement `transaction/1`**

In `apps/graphdb/src/graphdb_mgr.erl`, add the function in the public-API
function section, immediately before the public `verify_caches/0`
definition. Match the module's existing banner-comment style:

```erlang
%%-----------------------------------------------------------------------------
%% transaction(Fun) -> {ok, Result} | {error, Reason}
%%
%% Runs Fun inside one Mnesia transaction and normalises the result:
%% {atomic, R} -> {ok, R}; {aborted, Reason} -> {error, Reason}.
%%
%% Fun is a tier-1 write-path primitive (or a composition of them): it
%% performs its reads/writes with bare mnesia ops, never opens its own
%% transaction, and signals a domain failure via mnesia:abort/1.  This is
%% the single transaction boundary the write-path seam standardises on;
%% see docs/designs/write-path-transaction-seam-design.md.
%%
%% This is a plain function, not a gen_server:call -- mnesia:transaction/1
%% runs in the calling process, so routing writes through the graphdb_mgr
%% server would needlessly serialise them.
%%-----------------------------------------------------------------------------
-spec transaction(fun(() -> Result)) -> {ok, Result} | {error, term()}.
transaction(Fun) ->
	case mnesia:transaction(Fun) of
		{atomic,  Result} -> {ok, Result};
		{aborted, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 6: Run the new group to verify it passes**

Run:

```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --group transaction_seam
```

Expected: PASS — 3 cases, 0 failures.

- [ ] **Step 7: Compile clean and run the full mgr suite**

Run:

```bash
./rebar3 compile
./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE
```

Expected: zero compiler warnings; the full `graphdb_mgr_SUITE` passes
(the pre-existing cases plus the 3 new ones).

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl \
        apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "feat: add graphdb_mgr:transaction/1 write-path transaction seam

Adds the shared Mnesia transaction-runner that normalises
{atomic,R}->{ok,R} / {aborted,R}->{error,R} and anchors the tier-1
primitive / tier-2 wrapper / tier-3 batch convention. First consumers
(delete_node, remove_relationship) land in later slices.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage.** The spec's three deliverables map to this plan:
(§1.2.1 the convention) — documented in the design doc and in the
`transaction/1` banner comment (Step 5); (§1.2.2 the helper) — Steps 4–5;
(§1.2.3 tests) — Steps 1–3 + 6. The spec's §5 three test properties
(success+passthrough, abort rollback, composition rollback) are the three
cases in Step 2. §4 error normalisation is exercised by the `{error,
blocked}` / `{error, second_failed}` assertions. Out-of-scope items (§1.3)
are correctly absent.

**2. Placeholder scan.** No TBD/TODO/"handle errors"/"similar to" — every
step shows exact code and exact commands.

**3. Type consistency.** `transaction/1` signature, the `{ok, Result}` /
`{error, Reason}` return shapes, and the `mnesia:abort/1` reasons
(`blocked`, `second_failed`) are consistent between the test assertions
(Step 2), the export (Step 4), and the implementation + spec (Step 5).
Scratch nrefs are distinct per case (`?NREF_START + 500001/500002`,
`+500010`, `+500020`).
