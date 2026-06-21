<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Tier-1 Class-Read Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three exported, in-transaction (bare-mnesia) read primitives to `graphdb_class` — `get_template_in_txn/1`, `class_in_ancestry_in_txn/2`, `default_template_in_txn/1` — each returning results identical to its existing gen_server twin, with new CT coverage.

**Architecture:** Purely additive. The primitives are new exported functions that assume they already run inside an Mnesia activity and use bare `mnesia:read` / `mnesia:index_read` (never `dirty_*`, never opening their own transaction). They reuse the module-private `downward_children_by_arc/3` and `template_has_name/2` where possible; the ancestry walk is duplicated with bare reads (the gen_server twins keep their load-bearing `dirty_read`s untouched). No existing code path changes.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (invoked as repo-local `./rebar3`), Mnesia, Common Test.

## Global Constraints

- **Design contract:** `docs/designs/atomic-add-relationship-primitives-design.md`. This is PR 1 of 2; the `add_relationship` collapse is PR 2 and is **out of scope**.
- **Purely additive:** touch no existing function body, no existing `handle_call` clause, no existing test. The existing 539 tests must stay byte-for-byte unchanged and green.
- **Add, don't rewrap:** do NOT make `do_default_template/1`, `do_get_template/1`, or `do_class_in_ancestry/2` delegate to the new primitives. The gen_server `dirty_read`s on `get_template`/`class_in_ancestry` are load-bearing for `graphdb_rules:default_conflict_resolver/0` deadlock-safety.
- **Naming convention:** the new functions carry the `_in_txn` suffix.
- **Indentation:** `graphdb_class.erl` and `graphdb_class_SUITE.erl` use **hard tabs**. Match exactly.
- **Module header pattern:** do not add a copyright/revision block to functions; just add the functions in the existing Lookups region and their names to the existing `-export` list.
- **Relevant macros (already included via `graphdb_nrefs.hrl`):** `?NREF_CLASSES` = 3, `?NAME_ATTR_CLASS` = 19, `?ARC_CLS_CHILD` = 26. Local macro in `graphdb_class.erl`: `?DEFAULT_TEMPLATE_NAME` = `"default"`. The `composition` / `taxonomy` arc kinds are bare atoms.
- **Test harness:** every CT case starts `graphdb_class:start_link()` in its body; `init_per_testcase` already starts `nref`, `rel_id_server`, `graphdb_nref`, `graphdb_mgr` (bootstrap), and `graphdb_attr`. So `graphdb_mgr:transaction/1` is available inside test cases.
- **`graphdb_mgr:transaction/1` return shape:** maps `{atomic, R}` → `{ok, R}`. So a primitive returning `{ok, Node}` surfaces as `{ok, {ok, Node}}`; one returning `true` surfaces as `{ok, true}`; one returning `not_found` surfaces as `{ok, not_found}`.
- **Single-suite test run (per step):** `scripts/test-ct-parallel.sh class` (runs only `graphdb_class_SUITE`, isolated). Full verification run: `make test-ct-parallel` and `./rebar3 eunit`.

---

### Task 1: `get_template_in_txn/1`

The simplest primitive: the in-transaction twin of `do_get_template/1` (which uses `dirty_read`). Establishes the export-list edit pattern for the later tasks.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (add to `-export` Lookups region near line 121; add function body near the existing `do_get_template/1` around line 718–726)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl` (new cases + register in `-export` and `all/0`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `graphdb_class:get_template_in_txn(Nref) -> {ok, #node{}} | {error, not_a_template | not_found}`. Must be called inside an Mnesia activity.

- [ ] **Step 1: Write the failing tests**

Add these three cases to `apps/graphdb/test/graphdb_class_SUITE.erl`, in the Template Tests section (after `get_template_rejects_non_template/1`, around line 494):

```erlang
%%-----------------------------------------------------------------------------
%% get_template_in_txn returns the template node (in-transaction twin).
%%-----------------------------------------------------------------------------
get_template_in_txn_returns_node(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref} = graphdb_class:default_template(ClassNref),
	{ok, {ok, Node}} = graphdb_mgr:transaction(fun() ->
		graphdb_class:get_template_in_txn(TmplNref)
	end),
	?assertEqual(TmplNref, Node#node.nref),
	?assertEqual(template, Node#node.kind).

%%-----------------------------------------------------------------------------
%% get_template_in_txn rejects a class nref (kind mismatch).
%%-----------------------------------------------------------------------------
get_template_in_txn_rejects_non_template(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assertEqual({ok, {error, not_a_template}}, graphdb_mgr:transaction(fun() ->
		graphdb_class:get_template_in_txn(ClassNref)
	end)).

%%-----------------------------------------------------------------------------
%% get_template_in_txn returns not_found for an unused nref.
%%-----------------------------------------------------------------------------
get_template_in_txn_not_found(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	?assertEqual({ok, {error, not_found}}, graphdb_mgr:transaction(fun() ->
		graphdb_class:get_template_in_txn(999999)
	end)).
```

Register them in the `-export` test-case block (near line 76) and in `all/0` (near line 150), each adjacent to `get_template_rejects_non_template`:

```erlang
		get_template_returns_node/1,
		get_template_rejects_non_template/1,
		get_template_in_txn_returns_node/1,
		get_template_in_txn_rejects_non_template/1,
		get_template_in_txn_not_found/1,
```

```erlang
			get_template_returns_node,
			get_template_rejects_non_template,
			get_template_in_txn_returns_node,
			get_template_in_txn_rejects_non_template,
			get_template_in_txn_not_found,
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-ct-parallel.sh class`
Expected: FAIL — `graphdb_class:get_template_in_txn/1` is undefined (the three new cases error).

- [ ] **Step 3: Add to the export list**

In `apps/graphdb/src/graphdb_class.erl`, in the Lookups region of the public `-export` list (the block ending around line 130), add `get_template_in_txn/1` after `get_template/1`:

```erlang
		get_template/1,
		get_template_in_txn/1,
```

- [ ] **Step 4: Implement the primitive**

Add this function immediately after `do_get_template/1` (after line 726). It is the in-transaction twin: `mnesia:read` instead of `mnesia:dirty_read`.

```erlang
%%-----------------------------------------------------------------------------
%% get_template_in_txn(Nref) ->
%%     {ok, #node{}} | {error, not_a_template | not_found}
%%
%% Tier-1 in-transaction twin of do_get_template/1.  Assumes it runs inside an
%% active mnesia activity; uses a bare mnesia:read.  See
%% docs/designs/atomic-add-relationship-primitives-design.md.
%%-----------------------------------------------------------------------------
get_template_in_txn(Nref) ->
	case mnesia:read(nodes, Nref) of
		[#node{kind = template} = Node] -> {ok, Node};
		[_Other]                        -> {error, not_a_template};
		[]                              -> {error, not_found}
	end.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/test-ct-parallel.sh class`
Expected: PASS — all `graphdb_class_SUITE` cases green (existing + 3 new).

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "feat(graphdb_class): add get_template_in_txn/1 tier-1 read primitive"
```

---

### Task 2: `class_in_ancestry_in_txn/2`

The in-transaction twin of `do_class_in_ancestry/2`. Needs a bare-read ancestry walk (`ancestors_in_txn/1` + `walk_ancestors_in_txn/3`) duplicating `do_ancestors/1` + `do_walk_ancestors/3` with `mnesia:read` in place of `dirty_read`. This duplication is intentional (the design's "add, don't rewrap").

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (add to `-export`; add three functions near `do_class_in_ancestry/2` ~line 758 and `do_ancestors/1` ~line 922)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

**Interfaces:**
- Consumes: nothing.
- Produces: `graphdb_class:class_in_ancestry_in_txn(CandidateNref, ClassNref) -> boolean()`. Must be called inside an Mnesia activity. `class_in_ancestry_in_txn(C, C)` is `true`; any lookup error yields `false`.

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_class_SUITE.erl` after `class_in_ancestry_unrelated/1` (around line 561):

```erlang
%%-----------------------------------------------------------------------------
%% class_in_ancestry_in_txn: self is in its own ancestry (in-transaction twin).
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn_self(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assertEqual({ok, true}, graphdb_mgr:transaction(fun() ->
		graphdb_class:class_in_ancestry_in_txn(ClassNref, ClassNref)
	end)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry_in_txn: true for direct and transitive ancestors.
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn_ancestor(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AnimalNref} = graphdb_class:create_class("Animal", 3),
	{ok, MammalNref} = graphdb_class:create_class("Mammal", AnimalNref),
	{ok, WhaleNref}  = graphdb_class:create_class("Whale", MammalNref),
	?assertEqual({ok, true}, graphdb_mgr:transaction(fun() ->
		graphdb_class:class_in_ancestry_in_txn(AnimalNref, WhaleNref)
	end)),
	?assertEqual({ok, true}, graphdb_mgr:transaction(fun() ->
		graphdb_class:class_in_ancestry_in_txn(MammalNref, WhaleNref)
	end)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry_in_txn: false for unrelated classes.
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn_unrelated(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AnimalNref}  = graphdb_class:create_class("Animal", 3),
	{ok, VehicleNref} = graphdb_class:create_class("Vehicle", 3),
	?assertEqual({ok, false}, graphdb_mgr:transaction(fun() ->
		graphdb_class:class_in_ancestry_in_txn(VehicleNref, AnimalNref)
	end)).

%%-----------------------------------------------------------------------------
%% class_in_ancestry_in_txn: true for a diamond ancestor reached via two paths.
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn_diamond(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, A} = graphdb_class:create_class("A", 3),
	{ok, B} = graphdb_class:create_class("B", A),
	{ok, C} = graphdb_class:create_class("C", A),
	{ok, D} = graphdb_class:create_class("D", B),
	ok = graphdb_class:add_superclass(D, C),
	?assertEqual({ok, true}, graphdb_mgr:transaction(fun() ->
		graphdb_class:class_in_ancestry_in_txn(A, D)
	end)).
```

Register in the `-export` test-case block (after `class_in_ancestry_unrelated/1`, near line 83) and in `all/0` (after `class_in_ancestry_unrelated`, near line 157):

```erlang
		class_in_ancestry_self/1,
		class_in_ancestry_ancestor/1,
		class_in_ancestry_unrelated/1,
		class_in_ancestry_in_txn_self/1,
		class_in_ancestry_in_txn_ancestor/1,
		class_in_ancestry_in_txn_unrelated/1,
		class_in_ancestry_in_txn_diamond/1,
```

```erlang
			class_in_ancestry_self,
			class_in_ancestry_ancestor,
			class_in_ancestry_unrelated,
			class_in_ancestry_in_txn_self,
			class_in_ancestry_in_txn_ancestor,
			class_in_ancestry_in_txn_unrelated,
			class_in_ancestry_in_txn_diamond
```

NOTE: `class_in_ancestry_unrelated` is the last entry in its `all/0` group (followed by `]` or a group boundary) — preserve the existing trailing-comma/terminator layout when inserting; do not introduce a stray comma before a closing bracket.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-ct-parallel.sh class`
Expected: FAIL — `graphdb_class:class_in_ancestry_in_txn/2` is undefined.

- [ ] **Step 3: Add to the export list**

In `apps/graphdb/src/graphdb_class.erl`, add `class_in_ancestry_in_txn/2` after `class_in_ancestry/2` in the public `-export` list (near line 127):

```erlang
		class_in_ancestry/2,
		class_in_ancestry_in_txn/2,
```

- [ ] **Step 4: Implement the primitive and its bare-read walk**

Add `class_in_ancestry_in_txn/2` immediately after `do_class_in_ancestry/2` (after line 766):

```erlang
%%-----------------------------------------------------------------------------
%% class_in_ancestry_in_txn(CandidateNref, ClassNref) -> boolean()
%%
%% Tier-1 in-transaction twin of do_class_in_ancestry/2.  Assumes it runs
%% inside an active mnesia activity; walks the taxonomic ancestry with bare
%% mnesia:read.  Returns false on any lookup error.
%%-----------------------------------------------------------------------------
class_in_ancestry_in_txn(CandidateNref, CandidateNref) ->
	true;
class_in_ancestry_in_txn(CandidateNref, ClassNref) ->
	case ancestors_in_txn(ClassNref) of
		{ok, Ancestors} ->
			lists:any(fun(#node{nref = N}) -> N =:= CandidateNref end, Ancestors);
		_ ->
			false
	end.

%%-----------------------------------------------------------------------------
%% ancestors_in_txn(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Tier-1 in-transaction twin of do_ancestors/1: BFS over the multi-parent
%% taxonomic DAG with bare mnesia:read, nearest-first, each ancestor once,
%% the Classes category (nref 3) filtered out.
%%-----------------------------------------------------------------------------
ancestors_in_txn(ClassNref) ->
	case mnesia:read(nodes, ClassNref) of
		[#node{kind = class, parents = Parents}] ->
			Initial = [P || P <- Parents, P =/= ?NREF_CLASSES],
			walk_ancestors_in_txn(Initial, sets:from_list(Initial), []);
		[_] ->
			{error, not_a_class};
		[] ->
			{error, not_found}
	end.

walk_ancestors_in_txn([], _Visited, Acc) ->
	{ok, lists:reverse(Acc)};
walk_ancestors_in_txn([Nref | Rest], Visited, Acc) ->
	case mnesia:read(nodes, Nref) of
		[#node{kind = class, parents = Parents} = Node] ->
			New = [P || P <- Parents,
				P =/= ?NREF_CLASSES,
				not sets:is_element(P, Visited)],
			NewVisited = lists:foldl(fun sets:add_element/2, Visited, New),
			walk_ancestors_in_txn(Rest ++ New, NewVisited, [Node | Acc]);
		_ ->
			walk_ancestors_in_txn(Rest, Visited, Acc)
	end.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/test-ct-parallel.sh class`
Expected: PASS — all `graphdb_class_SUITE` cases green.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "feat(graphdb_class): add class_in_ancestry_in_txn/2 tier-1 read primitive"
```

---

### Task 3: `default_template_in_txn/1`

The in-transaction twin of `default_template/1`. Reuses the module-private `downward_children_by_arc/3` (already bare-mnesia, "must run inside a transaction") and `template_has_name/2`, so only the search/return logic is added.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (add to `-export`; add function near `do_default_template/1` ~line 745 / `do_find_template_by_name/1` ~line 695)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

**Interfaces:**
- Consumes: nothing.
- Produces: `graphdb_class:default_template_in_txn(ClassNref) -> {ok, Nref} | not_found`. Must be called inside an Mnesia activity.

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_class_SUITE.erl` after `default_template_not_found_after_delete/1` (around line 533):

```erlang
%%-----------------------------------------------------------------------------
%% default_template_in_txn returns the default template nref (in-tx twin).
%%-----------------------------------------------------------------------------
default_template_in_txn_returns_default(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, Expected}  = graphdb_class:default_template(ClassNref),
	?assertEqual({ok, {ok, Expected}}, graphdb_mgr:transaction(fun() ->
		graphdb_class:default_template_in_txn(ClassNref)
	end)).

%%-----------------------------------------------------------------------------
%% default_template_in_txn returns not_found for an abstract class (born
%% without a default template).
%%-----------------------------------------------------------------------------
default_template_in_txn_abstract_not_found(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	Marker = #{attribute => Inst, value => false},
	{ok, ClassNref} = graphdb_class:create_class("Abstract", 3, [Marker]),
	?assertEqual({ok, not_found}, graphdb_mgr:transaction(fun() ->
		graphdb_class:default_template_in_txn(ClassNref)
	end)).

%%-----------------------------------------------------------------------------
%% default_template_in_txn returns not_found after the default template node
%% is deleted.
%%-----------------------------------------------------------------------------
default_template_in_txn_not_found_after_delete(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, TmplNref}  = graphdb_class:default_template(ClassNref),
	{atomic, ok} = mnesia:transaction(fun() ->
		mnesia:delete({nodes, TmplNref})
	end),
	?assertEqual({ok, not_found}, graphdb_mgr:transaction(fun() ->
		graphdb_class:default_template_in_txn(ClassNref)
	end)).
```

Register in the `-export` test-case block (after `default_template_not_found_after_delete/1`, near line 80) and in `all/0` (after `default_template_not_found_after_delete`, near line 154):

```erlang
		default_template_returns_default/1,
		default_template_not_found_after_delete/1,
		default_template_in_txn_returns_default/1,
		default_template_in_txn_abstract_not_found/1,
		default_template_in_txn_not_found_after_delete/1,
```

```erlang
			default_template_returns_default,
			default_template_not_found_after_delete,
			default_template_in_txn_returns_default,
			default_template_in_txn_abstract_not_found,
			default_template_in_txn_not_found_after_delete,
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-ct-parallel.sh class`
Expected: FAIL — `graphdb_class:default_template_in_txn/1` is undefined.

- [ ] **Step 3: Add to the export list**

In `apps/graphdb/src/graphdb_class.erl`, add `default_template_in_txn/1` after `default_template/1` (near line 123):

```erlang
		default_template/1,
		default_template_in_txn/1,
```

- [ ] **Step 4: Implement the primitive**

Add this function immediately after `do_find_template_by_name/2` (after `template_has_name/2`, around line 714). It mirrors `do_find_template_by_name/2`'s search but assumes it is already inside a transaction (no `graphdb_mgr:transaction/1` wrapper) and returns the default-template result shape directly:

```erlang
%%-----------------------------------------------------------------------------
%% default_template_in_txn(ClassNref) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction twin of default_template/1.  Assumes it runs inside an
%% active mnesia activity; reuses the bare-mnesia downward_children_by_arc/3 and
%% template_has_name/2.  Returns not_found when ClassNref has no template named
%% ?DEFAULT_TEMPLATE_NAME (e.g. an abstract class).
%%-----------------------------------------------------------------------------
default_template_in_txn(ClassNref) ->
	Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD, composition),
	case lists:search(fun
			(#node{kind = template} = N) ->
				template_has_name(N, ?DEFAULT_TEMPLATE_NAME);
			(_) ->
				false
		end, Children) of
		{value, #node{nref = Nref}} -> {ok, Nref};
		false                       -> not_found
	end.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/test-ct-parallel.sh class`
Expected: PASS — all `graphdb_class_SUITE` cases green.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "feat(graphdb_class): add default_template_in_txn/1 tier-1 read primitive"
```

---

### Task 4: Documentation and full-suite verification

Record the new primitives in the worker API docs and the tracked follow-up, and run the full test suite to confirm nothing regressed.

**Files:**
- Modify: `apps/graphdb/CLAUDE.md` (graphdb_class API bullet)
- Modify: `TASKS.md` (Atomic `add_relationship` follow-up)

- [ ] **Step 1: Update the graphdb_class API bullet in `apps/graphdb/CLAUDE.md`**

In the `### graphdb_class — Taxonomic Hierarchy` section, add a line documenting the three new tier-1 primitives after the `get_class/1, subclasses/1, ancestors/1, inherited_qcs/1` bullet:

```markdown
- `get_template_in_txn/1`, `class_in_ancestry_in_txn/2`,
  `default_template_in_txn/1` — tier-1 **in-transaction** read primitives
  (bare-mnesia twins of `get_template`/`class_in_ancestry`/`default_template`);
  must be called inside an Mnesia activity. They compose into a caller's single
  transaction (the seam's tier-1 contract) and are the prerequisite for atomic
  `add_relationship` / `mutate/1`. See
  `docs/designs/atomic-add-relationship-primitives-design.md`.
```

- [ ] **Step 2: Update the Atomic `add_relationship` follow-up in `TASKS.md`**

In the "Tracked follow-ups" list under "Transaction-layering seam", replace the **Atomic `add_relationship`** bullet's "Blocked on …" sentence to record that the prerequisite primitives have landed. Change the bullet to read:

```markdown
- **Atomic `add_relationship`** — collapse its four separate transactions
  (validate → resolve classes → resolve template → write) into one. The
  prerequisite tier-1 `graphdb_class` read primitives
  (`get_template_in_txn/1`, `class_in_ancestry_in_txn/2`,
  `default_template_in_txn/1`) have landed (PR 1,
  `docs/designs/atomic-add-relationship-primitives-design.md`). PR 2 swaps
  `add_relationship` onto them, converts the `source_has_no_class` /
  `target_has_no_class` arms to `mnesia:abort/1`, and allocates the rel-id pair
  up-front. Sequence with / before `mutate/1`, which wants those primitives too.
```

- [ ] **Step 3: Run the full Common Test suite**

Run: `make test-ct-parallel`
Expected: PASS — all suites green; `graphdb_class_SUITE` reports +10 cases vs the prior run. See the count note below.

NOTE on counts: this plan adds **10 new CT cases** to `graphdb_class_SUITE` (3 + 4 + 3). The prior project total is 434 CT (post-PR-43). After this plan: **444 CT**. Confirm the runner reports the higher total with zero failures; the exact per-suite number matters less than "all green, +10 in graphdb_class_SUITE".

- [ ] **Step 4: Run the full EUnit suite**

Run: `./rebar3 eunit`
Expected: PASS — 105 EUnit tests, all green (unchanged; this plan adds no EUnit).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/CLAUDE.md TASKS.md
git commit -m "docs(graphdb_class): record tier-1 read primitives + add_relationship follow-up"
```

---

## Self-Review

**Spec coverage:**
- Three primitives (design §"The three primitives") → Tasks 1, 2, 3. ✓
- `_in_txn` naming convention → Global Constraints + every task. ✓
- Add-don't-rewrap, gen_server reads untouched (design §"Add, don't rewrap") → Global Constraints; no task modifies an existing function body. ✓
- Purely additive, 539 existing tests untouched → Global Constraints; tasks only append. ✓
- Tests: CT in `graphdb_class_SUITE`, invoked via `graphdb_mgr:transaction/1`, mirroring gen_server-twin assertions, with the exact scenarios listed (design §"Testing") → Tasks 1–3 cover default(with/without/abstract), get_template(template/non-template/missing), ancestry(self/ancestor/unrelated/diamond). ✓
- Non-goals (add_relationship collapse, abort conversions, up-front alloc) excluded → Global Constraints; not in any task. ✓
- Docs updates (worker API contract addition) → Task 4. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every command shows expected output. ✓

**Type consistency:** `get_template_in_txn/1` → `{ok,#node{}}|{error,not_a_template|not_found}`; `class_in_ancestry_in_txn/2` → `boolean()`; `default_template_in_txn/1` → `{ok,Nref}|not_found`. Test expectations account for the `graphdb_mgr:transaction/1` `{ok, _}` wrap consistently (`{ok,{ok,Node}}`, `{ok,true}`, `{ok,not_found}`). ✓
