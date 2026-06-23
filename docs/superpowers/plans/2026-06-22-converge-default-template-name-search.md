<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Converge Default-Template Name Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the verbatim-duplicated template name-search walk in
`graphdb_class` by extracting one exported tier-1 in-transaction primitive
(`find_template_by_name_in_txn/2`) and funnelling both existing functions
through it, behaviour-preserving.

**Architecture:** `graphdb_class` carries the same
`downward_children_by_arc/3` + `lists:search` (kind=template + name match)
walk in two places: `do_find_template_by_name/2` (gen-server, owns one txn,
generic name, swallows read errors) and `default_template_in_txn/1` (tier-1
in-txn, hardcodes the default name). Extract the shared body into a new
exported tier-1 primitive `find_template_by_name_in_txn/2`; have
`default_template_in_txn/1` delegate with `?DEFAULT_TEMPLATE_NAME` and
`do_find_template_by_name/2` wrap one `graphdb_mgr:transaction/1` around it.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (invoked as repo-local
`./rebar3`), Common Test, Mnesia.

## Global Constraints

- Module file uses **hard tabs** for indentation (`graphdb_class.erl` and
  `graphdb_class_SUITE.erl`) — match existing indentation exactly.
- Behaviour-preserving: no externally observable change. The full existing
  `graphdb_class_SUITE` must pass unchanged.
- `find_template_by_name_in_txn/2` is a **tier-1 in-transaction primitive**:
  bare mnesia ops, never opens its own transaction, assumes it runs inside an
  active mnesia activity. It must be exported in the tier-1 primitive group.
- `do_find_template_by_name/2` keeps its own single transaction and its
  `{error, _} -> not_found` swallow.
- `graphdb_mgr:transaction/1` maps `{atomic, R} -> {ok, R}` and
  `{aborted, R} -> {error, R}`. A fun returning `{ok, Nref}` surfaces as
  `{ok, {ok, Nref}}`; a fun returning `not_found` surfaces as
  `{ok, not_found}`.
- Reference: `docs/designs/converge-default-template-name-search-design.md`.
- Run the class suite with:
  `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`.
- The suite's `end_per_testcase/2` runs `graphdb_mgr:verify_caches/0` as a
  fatal assertion — every test must leave node `parents`/`classes` caches
  consistent with the authoritative arcs (so all setup goes through the
  public `graphdb_class` API, which maintains caches).

---

## Reference: current source (for the implementer)

`apps/graphdb/src/graphdb_class.erl` currently holds these three functions.
You will replace the bodies of the latter two and add the new primitive
between them.

```erlang
%% lines ~701-714 — the gen-server form (opens its own txn)
do_find_template_by_name(ClassNref, Name) ->
	F = fun() ->
		Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD,
			composition),
		lists:search(fun
			(#node{kind = template} = N) -> template_has_name(N, Name);
			(_)                           -> false
		end, Children)
	end,
	case graphdb_mgr:transaction(F) of
		{ok, {value, #node{nref = Nref}}} -> {ok, Nref};
		{ok, false}                       -> not_found;
		{error, _}                        -> not_found
	end.

%% lines ~716-720 — shared name-match helper (UNCHANGED by this plan)
template_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
	lists:any(fun
		(#{attribute := ?NAME_ATTR_CLASS, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).

%% lines ~730-740 — the tier-1 in-txn form (hardcodes default name)
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

Macros already in scope in `graphdb_class.erl`: `?ARC_CLS_CHILD`,
`?DEFAULT_TEMPLATE_NAME`, `?NAME_ATTR_CLASS`. The export list groups the
tier-1 primitives near line 122-131 (`get_template_in_txn/1`,
`class_in_ancestry_in_txn/2`, `default_template_in_txn/1`).

---

## Task 1: Extract and converge `find_template_by_name_in_txn/2`

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (export list ~line 125; the
  three functions at ~701-740)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl` (add 3 cases + register
  them in the test group)

This is a single behaviour-preserving refactor: the new primitive plus the
two delegations land together because `default_template_in_txn/1`'s and
`do_find_template_by_name/2`'s new bodies *reference* the new primitive — they
cannot compile or be reviewed independently. The three new CT cases exercise
the newly exported primitive directly.

**Interfaces:**
- Produces: `graphdb_class:find_template_by_name_in_txn(ClassNref, Name) ->
  {ok, Nref} | not_found` — tier-1 in-transaction primitive (must run inside
  an mnesia activity). Exported.
- Unchanged public contract: `default_template_in_txn/1 -> {ok, Nref} |
  not_found`; `do_find_template_by_name/2 -> {ok, Nref} | not_found`
  (internal); `default_template/1`, `add_template/2` callers unaffected.

- [ ] **Step 1: Write the three failing tests**

In `apps/graphdb/test/graphdb_class_SUITE.erl`, add these three test
functions (place them just after `default_template_in_txn_not_found_after_delete/1`,
near line 637). Use **hard tabs** to match the file.

```erlang
%%-----------------------------------------------------------------------------
%% find_template_by_name_in_txn resolves a named (non-default) template child
%% and returns it distinct from the auto-created default template.
%%-----------------------------------------------------------------------------
find_template_by_name_in_txn_found(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, Default}   = graphdb_class:default_template(ClassNref),
	{ok, Bio}       = graphdb_class:add_template(ClassNref, "biological"),
	?assertNotEqual(Default, Bio),
	?assertEqual({ok, {ok, Bio}}, graphdb_mgr:transaction(fun() ->
		graphdb_class:find_template_by_name_in_txn(ClassNref, "biological")
	end)).

%%-----------------------------------------------------------------------------
%% find_template_by_name_in_txn selects by name: searching the same class for
%% "default" returns the default template, not the named one (proves the name
%% selects rather than first-match).
%%-----------------------------------------------------------------------------
find_template_by_name_in_txn_discriminates(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	{ok, Default}   = graphdb_class:default_template(ClassNref),
	{ok, Bio}       = graphdb_class:add_template(ClassNref, "biological"),
	?assertNotEqual(Default, Bio),
	?assertEqual({ok, {ok, Default}}, graphdb_mgr:transaction(fun() ->
		graphdb_class:find_template_by_name_in_txn(ClassNref, "default")
	end)).

%%-----------------------------------------------------------------------------
%% find_template_by_name_in_txn returns not_found for a name no template
%% carries.
%%-----------------------------------------------------------------------------
find_template_by_name_in_txn_not_found(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Animal", 3),
	?assertEqual({ok, not_found}, graphdb_mgr:transaction(fun() ->
		graphdb_class:find_template_by_name_in_txn(ClassNref, "nonexistent")
	end)).
```

Register the three cases. Add them to the exported test-function list
(near line 84-86, beside the `default_template_in_txn_*` entries):

```erlang
	find_template_by_name_in_txn_found/1,
	find_template_by_name_in_txn_discriminates/1,
	find_template_by_name_in_txn_not_found/1,
```

…and to the test group list (near line 174-176, beside the
`default_template_in_txn_*` entries):

```erlang
			find_template_by_name_in_txn_found,
			find_template_by_name_in_txn_discriminates,
			find_template_by_name_in_txn_not_found,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE \
  --case find_template_by_name_in_txn_found \
  --case find_template_by_name_in_txn_discriminates \
  --case find_template_by_name_in_txn_not_found
```
Expected: FAIL — compilation error or `undef` for
`graphdb_class:find_template_by_name_in_txn/2` (the function does not exist
and is not exported yet).

- [ ] **Step 3: Add the new primitive and converge the two callers**

In `apps/graphdb/src/graphdb_class.erl`:

(a) Add the export. In the tier-1 primitive group (the line currently reading
`default_template_in_txn/1,` at ~line 125), add a line after it:

```erlang
		default_template_in_txn/1,
		find_template_by_name_in_txn/2,
```

(b) Replace the body of `do_find_template_by_name/2` (~lines 701-714) with the
one-txn wrapper that delegates to the new primitive. Keep the doc comment
above it; the swallow is preserved:

```erlang
do_find_template_by_name(ClassNref, Name) ->
	case graphdb_mgr:transaction(fun() ->
			find_template_by_name_in_txn(ClassNref, Name)
		end) of
		{ok, {ok, Nref}} -> {ok, Nref};
		{ok, not_found}  -> not_found;
		{error, _}       -> not_found
	end.
```

(c) Replace the body of `default_template_in_txn/1` (~lines 730-740) so it
delegates to the new primitive. Update its doc comment to point at the
primitive:

```erlang
%%-----------------------------------------------------------------------------
%% default_template_in_txn(ClassNref) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction twin of default_template/1.  Delegates to
%% find_template_by_name_in_txn/2 with ?DEFAULT_TEMPLATE_NAME.  Returns
%% not_found when ClassNref has no default template (e.g. an abstract class).
%%-----------------------------------------------------------------------------
default_template_in_txn(ClassNref) ->
	find_template_by_name_in_txn(ClassNref, ?DEFAULT_TEMPLATE_NAME).
```

(d) Add the new primitive between them (after `template_has_name/2`, before
`default_template_in_txn/1`):

```erlang
%%-----------------------------------------------------------------------------
%% find_template_by_name_in_txn(ClassNref, Name) -> {ok, Nref} | not_found
%%
%% Tier-1 in-transaction primitive.  Assumes it runs inside an active mnesia
%% activity; reuses the bare-mnesia downward_children_by_arc/3 and
%% template_has_name/2.  Returns the kind=template child of ClassNref whose
%% class NameAttrNref (19) value equals Name, or not_found.
%%-----------------------------------------------------------------------------
find_template_by_name_in_txn(ClassNref, Name) ->
	Children = downward_children_by_arc(ClassNref, ?ARC_CLS_CHILD, composition),
	case lists:search(fun
			(#node{kind = template} = N) -> template_has_name(N, Name);
			(_)                           -> false
		end, Children) of
		{value, #node{nref = Nref}} -> {ok, Nref};
		false                       -> not_found
	end.
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE \
  --case find_template_by_name_in_txn_found \
  --case find_template_by_name_in_txn_discriminates \
  --case find_template_by_name_in_txn_not_found
```
Expected: PASS — 3 cases, 0 failures.

- [ ] **Step 5: Run the full class suite (behaviour-preservation proof)**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE
```
Expected: PASS — all cases (the prior count plus 3) green, 0 failures.
In particular the three `default_template_in_txn_*` cases and the
`add_template_*` / `default_template` cases pass unchanged.

- [ ] **Step 6: Compile clean (zero warnings)**

Run:
```bash
./rebar3 compile
```
Expected: no warnings, no errors. (A common slip is forgetting the export,
which surfaces as an "unused function" warning — fix by completing step 3a.)

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "$(cat <<'EOF'
refactor(graphdb_class): converge template name-search into one primitive

Extract the duplicated downward_children_by_arc + name-match walk shared by
do_find_template_by_name/2 and default_template_in_txn/1 into an exported
tier-1 primitive find_template_by_name_in_txn/2. default_template_in_txn/1
delegates with ?DEFAULT_TEMPLATE_NAME; do_find_template_by_name/2 wraps one
graphdb_mgr:transaction/1 and preserves its {error,_}->not_found swallow.
Behaviour-preserving; +3 direct CT cases for the new primitive.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF
EOF
)"
```

---

## Task 2: Docs

**Files:**
- Modify: `apps/graphdb/CLAUDE.md` (tier-1 primitive bullet for `graphdb_class`)
- Modify: `TASKS.md` (the "Converge default-template name search" bullet)

- [ ] **Step 1: Update `apps/graphdb/CLAUDE.md`**

Find the tier-1 primitive bullet under `### graphdb_class` (it currently
reads `get_template_in_txn/1`, `class_in_ancestry_in_txn/2`,
`default_template_in_txn/1` — tier-1 in-transaction read primitives …) and
add `find_template_by_name_in_txn/2` to the list, noting it is the generic
by-name search that `default_template_in_txn/1` delegates to. Match the
file's existing bullet wording/style.

- [ ] **Step 2: Flip the TASKS.md bullet to IMPLEMENTED**

In `TASKS.md`, locate the "**Converge default-template name search**" bullet
(it currently describes the duplication as deferred future cleanup). Rewrite
it to record completion: the shared walk is now
`graphdb_class:find_template_by_name_in_txn/2` (exported tier-1 primitive);
`default_template_in_txn/1` and `do_find_template_by_name/2` delegate to it;
behaviour-preserving with +3 CT cases. Reference the design
(`docs/designs/converge-default-template-name-search-design.md`) and this
plan. Match the surrounding bullet style.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/CLAUDE.md TASKS.md
git commit -m "$(cat <<'EOF'
docs(graphdb_class): record converged template name-search primitive

CLAUDE.md tier-1 primitive bullet lists find_template_by_name_in_txn/2;
TASKS.md "Converge default-template name search" flipped to IMPLEMENTED.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF
EOF
)"
```

---

## Notes for the executor

- `docs/Architecture.md` is intentionally **not** updated: this is an internal
  refactor with no public-contract or schema change.
- Do not touch `do_templates_for_class/1` (all-templates, no name match) or
  `do_default_template/1` (a thin identity wrapper) — both are out of scope.
- The `kind = template` guard's reject branch is unreachable through the
  public API and is intentionally not covered by an injected-state test; the
  guard stays in the code for behaviour preservation. See the design doc's
  Testing section.
