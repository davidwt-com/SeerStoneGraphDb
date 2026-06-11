<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 B-prep — Multiplicity Range Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape a rule's `multiplicity` from a single `pos_integer() | unbounded`
into an explicit `{Min, Max}` cardinality range, uniformly across composition and
connection rules, so the connection-firing division (B4) can express both a floor
and a ceiling.

**Architecture:** A pervasive data-shape cutover. `multiplicity` becomes `{Min, Max}`
(`Min :: non_neg_integer()`, `Max :: pos_integer() | unbounded`; `unbounded` legal
only as `Max`). Creation firing materialises `Min` (mandatory mints `Min` in the root
txn; auto mints `Min` post-commit); propose surfaces `Min` `proposed` outcomes, each
carrying a `max => Max` key. The `unbounded`-driven dead-ends
(`unbounded_multiplicity_not_fireable`, propose `index => unbounded` sentinel) are
retired because `Min` is always finite. Greenfield — no data migration; only test
call-site churn.

**Tech Stack:** Erlang/OTP 28.5 (kerl), rebar3 3.27 (`./rebar3`), Common Test + EUnit.
TAB indentation, zero-warning bar.

**Design doc:** `docs/designs/f4-bprep-multiplicity-range-design.md` (BP-D1…BP-D6,
BP-OI-1…BP-OI-3). Read it before starting.

**Test baseline (current `develop`, post-PR-35):** 476 tests = 105 EUnit + 371 CT.
`graphdb_rules_SUITE` = 63 CT, `graphdb_instance_SUITE` = 76 CT. Every task ends with
the **full suite green** and **zero compiler warnings**.

**Commands:**

```sh
./rebar3 compile                                          # zero warnings required
./rebar3 eunit                                            # 105 EUnit
make test-ct-parallel                                     # all 13 CT suites (~20s)
make test-ct-parallel FILTER=rules                        # just graphdb_rules_SUITE
make test-ct-parallel FILTER=instance                     # just graphdb_instance_SUITE
```

---

## On TDD shape (read before Task 1)

This is a **pervasive type cutover**, not a green-field feature, so the usual
red-first/green-second rhythm does not fit Task 1 cleanly. The circularity is
unavoidable: `validate_multiplicity/1` rejects bare scalars **and** every
`fire_one_*`/`plan_mandatory` consumer destructures `{Min, Max}` — so any
un-migrated scalar call site produces a badmatch (or an `I > {K,K}` loop-bound
that never terminates the loop correctly). Production code and **all** call-site
migration therefore must land in one commit (Task 1). The **existing suite is
Task 1's regression net** — `{K, K}` preserves every observable behaviour.

Tasks 2–4 are **characterization / coverage** tests written *after* the Task 1
behaviour exists (test-after, by necessity). They are split into
validation / creation-firing / propose chunks so the two-stage review stays
focused. This is the honest structure for a type cutover; do not invent fake
red steps.

---

## File Structure

| File                                           | Responsibility in this refactor                                                                                 |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`           | `validate_multiplicity/1` rewrite; `plan_mandatory` drives `Min`, drops `unbounded`; `decode_deployment` doc    |
| `apps/graphdb/src/graphdb_instance.erl`        | `fire_one_auto` drives `Min`, drops `unbounded`; `fire_one_propose`/`propose_children` drive `Min`, carry `Max` |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`    | authoring args + decoded-deployment assertions → `{Min, Max}`; rewrite mandatory-unbounded case; new validation |
| `apps/graphdb/test/graphdb_instance_SUITE.erl` | firing authoring args + assertions → `{Min, Max}`; rewrite propose-unbounded case; new Min≠Max + carry-Max      |
| `apps/graphdb/test/graphdb_instance_tests.erl` | EUnit `Dep` fixture maps `multiplicity => K` → `{K, K}` (cosmetic fixture accuracy)                             |
| `apps/graphdb/CLAUDE.md`                       | `create_*_rule` multiplicity param type; deployment value note                                                  |
| `docs/designs/f4-graphdb-rules-design.md`      | record `{Min, Max}` (D5 deployment AVPs) + retirements                                                          |
| `README.md`                                    | test-count table (CT count shift)                                                                               |

No change to `apps/graphdb/priv/bootstrap.terms`, `docs/diagrams/ontology-tree.md`,
or any seed (BP-D5). No arity change to `create_composition_rule/6,7,8` or
`create_connection_rule/7,8` (BP-D5) — only the `Mult` param **type** changes.

---

## Task 1: Atomic data-shape cutover (production + behaviour-preserving migration)

The irreducible cutover. Production edits to both source files + migrate **every**
existing call site so the suite stays green. `{K, K}` reproduces every current
behaviour; the two `unbounded` special-case tests are rewritten to the new
behaviour.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Test: `apps/graphdb/test/graphdb_instance_tests.erl`

### Production edits

- [ ] **Step 1: Rewrite `validate_multiplicity/1` (graphdb_rules.erl).**

Replace the current three clauses (around line 641):

```erlang
validate_multiplicity(unbounded) ->
	ok;
validate_multiplicity(N) when is_integer(N), N >= 1 ->
	ok;
validate_multiplicity(_) ->
	{error, invalid_multiplicity}.
```

with (BP-D4):

```erlang
validate_multiplicity({Min, Max})
		when is_integer(Min), Min >= 0,
			 is_integer(Max), Max >= 1, Max >= Min ->
	ok;
validate_multiplicity({Min, unbounded})
		when is_integer(Min), Min >= 0 ->
	ok;
validate_multiplicity(_) ->
	{error, invalid_multiplicity}.
```

A bare integer, a bare `unbounded`, `Max < Min`, `Max < 1`, `{0, 0}`, and any
non-tuple all fall to the catch-all ⇒ `{error, invalid_multiplicity}` (same atom).

- [ ] **Step 2: `plan_mandatory/5` drives `Min`, drop the `unbounded` clause (graphdb_rules.erl).**

Replace the `false ->` branch body of `plan_mandatory/5` (around lines 950-967):

```erlang
		false ->
			case maps:get(multiplicity, Deploy, 1) of
				unbounded ->
					fail({unbounded_multiplicity_not_fireable,
						  RuleNode#node.nref}, RuleNode, Acc);
				Mult ->
					case graphdb_class:is_instantiable(ChildClass) of
						true ->
							expand_children(RuleNode, Deploy, ChildClass, Mult, 1,
											OnPath1, State, Acc);
						false ->
							fail({class_not_instantiable, ChildClass},
								 RuleNode, Acc);
						{error, Reason} ->
							fail({child_class_invalid, ChildClass, Reason},
								 RuleNode, Acc)
					end
			end
	end.
```

with (BP-D3 — `unbounded` clause deleted, `Min` drives the cascade):

```erlang
		false ->
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case graphdb_class:is_instantiable(ChildClass) of
				true ->
					expand_children(RuleNode, Deploy, ChildClass, Min, 1,
									OnPath1, State, Acc);
				false ->
					fail({class_not_instantiable, ChildClass},
						 RuleNode, Acc);
				{error, Reason} ->
					fail({child_class_invalid, ChildClass, Reason},
						 RuleNode, Acc)
			end
	end.
```

`expand_children/8`'s formal param keeps its name; it now receives `Min` as the
loop bound (the count actually being created — BP-D2/§3.7). `fallback_name/3`'s
`(ChildClass, _I, 1)` clause still matches when `Min = 1`, so naming is unchanged.

- [ ] **Step 3: Update the `plan_composition_firing` error-reasons doc comment (graphdb_rules.erl).**

In the comment block around lines 297-301, delete the two lines documenting the
retired error:

```erlang
%%   {unbounded_multiplicity_not_fireable, RuleNref} --
%%       a mandatory rule has multiplicity=unbounded
```

Leave the `{class_not_instantiable, ChildClassNref}` line.

- [ ] **Step 4: Update the `decode_deployment/2` doc comment (graphdb_rules.erl).**

In the comment above `decode_deployment/2` (around lines 839-844), note the value
type. Change:

```erlang
%% Decodes an applies_to arc's deployment AVPs into the symbolic Deployment map
%% #{mode, multiplicity, template}.  A key whose AVP is absent is omitted
```

to:

```erlang
%% Decodes an applies_to arc's deployment AVPs into the symbolic Deployment map
%% #{mode, multiplicity, template}.  `multiplicity' is a {Min, Max} range
%% (B-prep); the fold copies it verbatim.  A key whose AVP is absent is omitted
```

No code change to `decode_deployment/2` itself — it already copies the value
verbatim (BP-D5/§3.3).

- [ ] **Step 5: `fire_one_auto/5` drives `Min`, drop the `unbounded` clause (graphdb_instance.erl).**

Replace the `_ ->` branch body of `fire_one_auto/5` (around lines 631-643):

```erlang
		_ ->        %% true (or {error,_} -> treated as fireable; create reports)
			case maps:get(multiplicity, Deploy, 1) of
				unbounded ->
					add_outcome(Acc, RuleNode, Deploy,
						#{owner => OwnerNref, index => 1, status => failed,
						  reason => unbounded_multiplicity_not_fireable});
				Mult ->
					case lists:member(ChildClass, OnPath1) of
						true  -> Acc;       %% vertical cycle cut (B2-D5)
						false -> fire_auto_children(RuleNode, Deploy, ChildClass,
											Mult, 1, OwnerNref, OnPath1, Acc)
					end
			end
	end.
```

with (BP-D3 — `unbounded` outcome deleted; `Min` drives minting):

```erlang
		_ ->        %% true (or {error,_} -> treated as fireable; create reports)
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case lists:member(ChildClass, OnPath1) of
				true  -> Acc;       %% vertical cycle cut (B2-D5)
				false -> fire_auto_children(RuleNode, Deploy, ChildClass,
									Min, 1, OwnerNref, OnPath1, Acc)
			end
	end.
```

- [ ] **Step 6: Update the `fire_one_auto/5` doc comment (graphdb_instance.erl).**

The comment above `fire_one_auto/5` (around lines 619-623) says
"instantiable, then unbounded, then the vertical-cycle cut". Change to:

```erlang
%% Check order: instantiable, then the vertical-cycle cut, then expansion.
%% mints Min children post-commit (B-prep).
```

- [ ] **Step 7: `fire_one_propose/5` drives `Min`, carries `Max`, drop the `index=unbounded` clause (graphdb_instance.erl).**

Replace the `false ->` branch body of `fire_one_propose/5` (around lines 715-732):

```erlang
		false ->
			case maps:get(multiplicity, Deploy, 1) of
				unbounded ->
					%% B3 OI-B3-1: unbounded propose => a single proposal with
					%% index=unbounded; the caller decides cardinality.  Name is
					%% a representative resolved at index 1.  Supersedable by
					%% propose-with-options.
					Name = graphdb_rules:rule_child_name(RuleNode, ChildClass,
														 1, 1),
					add_outcome(Acc, RuleNode, Deploy,
						#{owner => OwnerNref, index => unbounded,
						  status => proposed, proposed_class => ChildClass,
						  name => Name});
				Mult ->
					propose_children(RuleNode, Deploy, ChildClass, Mult, 1,
									 OwnerNref, Acc)
			end
	end.
```

with (BP-D2 choice (b) — `Min` outcomes, each carrying `max => Max`):

```erlang
		false ->
			%% B-prep: propose surfaces Min proposed outcomes, each carrying
			%% max => Max so the report keeps the open-ended ceiling (Max may
			%% be `unbounded').  Generalises the old index=unbounded sentinel.
			{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
			propose_children(RuleNode, Deploy, ChildClass, Min, Max, 1,
							 OwnerNref, Acc)
	end.
```

- [ ] **Step 8: Extend `propose_children` to thread `Max` and stamp `max` on each outcome (graphdb_instance.erl).**

Replace the whole `propose_children/7` (around lines 739-747):

```erlang
propose_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _OwnerNref, Acc)
		when I > Mult ->
	Acc;
propose_children(RuleNode, Deploy, ChildClass, Mult, I, OwnerNref, Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Mult),
	Acc1 = add_outcome(Acc, RuleNode, Deploy,
		#{owner => OwnerNref, index => I, status => proposed,
		  proposed_class => ChildClass, name => Name}),
	propose_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OwnerNref, Acc1).
```

with `propose_children/8` (adds `Max` param; `Count` = `Min` is the loop bound):

```erlang
propose_children(_RuleNode, _Deploy, _ChildClass, Count, _Max, I, _OwnerNref, Acc)
		when I > Count ->
	Acc;
propose_children(RuleNode, Deploy, ChildClass, Count, Max, I, OwnerNref, Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Count),
	Acc1 = add_outcome(Acc, RuleNode, Deploy,
		#{owner => OwnerNref, index => I, status => proposed,
		  proposed_class => ChildClass, name => Name, max => Max}),
	propose_children(RuleNode, Deploy, ChildClass, Count, Max, I + 1, OwnerNref,
					 Acc1).
```

Also update the `propose_children` doc comment (around lines 735-738) to mention
`max`:

```erlang
%% propose_children(RuleNode, Deploy, ChildClass, Count, Max, I, OwnerNref, Acc)
%%   -> report()
%% Emits one `proposed' outcome per index 1..Count (Count = Min), each carrying
%% max => Max (Max may be `unbounded').
```

- [ ] **Step 9: Compile, expect zero warnings.**

Run: `./rebar3 compile`
Expected: `===> Compiling graphdb` with **no warnings**. (The suites are still
scalar at this point, so do NOT run tests yet — they will fail until migrated.)

### Test migration (behaviour-preserving sweep)

- [ ] **Step 10: Migrate every `create_*_rule` authoring arg in `graphdb_rules_SUITE.erl` (`K → {K, K}`).**

Find them: `grep -n "create_composition_rule\|create_connection_rule" apps/graphdb/test/graphdb_rules_SUITE.erl`

For each call, change the scalar multiplicity argument to `{K, K}`. The
multiplicity arg is the 6th positional arg of `create_composition_rule`
(`scope, name, parent, child, mode, MULT [, template] [, opts]`) and the 6th of
`create_connection_rule` (`scope, name, source, char, target, mode, MULT
[, template]`). Examples:

```erlang
%% before
graphdb_rules:create_composition_rule(environment, "OB", Owner, Bolt, mandatory, 1)
%% after
graphdb_rules:create_composition_rule(environment, "OB", Owner, Bolt, mandatory, {1, 1})
```

```erlang
%% before
graphdb_rules:create_composition_rule(environment, "x", Parent, Child, mandatory, 3, undefined, #{name_pattern => "P {i}"})
%% after
graphdb_rules:create_composition_rule(environment, "x", Parent, Child, mandatory, {3, 3}, undefined, #{name_pattern => "P {i}"})
```

**Do NOT touch** `invalid_multiplicity_rejected/1` (it passes bare `0` and `"lots"`
to prove non-tuples are rejected — keep them bare). **Do NOT touch**
`plan_unbounded_mandatory_fails/1` (rewritten in Step 12).

- [ ] **Step 11: Migrate decoded-deployment assertions in `graphdb_rules_SUITE.erl` (`multiplicity := K → {K, K}`).**

Find them: `grep -n "multiplicity := \|maps:get(multiplicity" apps/graphdb/test/graphdb_rules_SUITE.erl`

Update each assertion on a decoded deployment map. Examples (around lines 542,
1011-1012, 1023, 1043-1044):

```erlang
%% before
?assertEqual(3, maps:get(multiplicity, Dep)).
%% after
?assertEqual({3, 3}, maps:get(multiplicity, Dep)).
```

```erlang
%% before
?assertMatch([{#node{nref = R}, #{multiplicity := 3}}], pairs_at(B, Levels)).
%% after
?assertMatch([{#node{nref = R}, #{multiplicity := {3, 3}}}], pairs_at(B, Levels)).
```

```erlang
%% before
?assertEqual(4, maps:get(multiplicity, Deploy)),
%% after
?assertEqual({4, 4}, maps:get(multiplicity, Deploy)),
```

- [ ] **Step 12: Rewrite `plan_unbounded_mandatory_fails/1` → mints `Min` (graphdb_rules.erl `_SUITE`).**

This is a **behaviour change**: a `{1, unbounded}` mandatory rule now mints one
child instead of failing. Rename the test and rewrite the body. Replace
(around lines 700-707):

```erlang
plan_unbounded_mandatory_fails(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, R} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, unbounded),
	{error, {unbounded_multiplicity_not_fireable, R},
	 #{plan_so_far := #{class := Owner}, culprit := #node{nref = R}}} =
		graphdb_rules:plan_composition_firing(environment, Owner).
```

with:

```erlang
%% B-prep: {Min, unbounded} mandatory mints Min (here 1) — the old
%% unbounded_multiplicity_not_fireable error is retired.
plan_unbounded_mandatory_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _R} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, unbounded}),
	{ok, #{mandatory_children := Kids}} =
		graphdb_rules:plan_composition_firing(environment, Owner),
	?assertEqual(1, length(Kids)),
	[#{class := Bolt}] = Kids.
```

Then update the **export list** (around line 70) and the **group/sequence lists**
(around lines 233 and 286): rename `plan_unbounded_mandatory_fails` to
`plan_unbounded_mandatory_mints_min` in all three places.
`grep -n "plan_unbounded_mandatory_fails" apps/graphdb/test/graphdb_rules_SUITE.erl`
must return nothing afterwards.

- [ ] **Step 13: Migrate `graphdb_instance_SUITE.erl` authoring args + assertions (`K → {K, K}`).**

Find them: `grep -n "create_composition_rule\|create_connection_rule\|maps:get(multiplicity\|multiplicity :=" apps/graphdb/test/graphdb_instance_SUITE.erl`

- Change every `create_*_rule` scalar multiplicity arg to `{K, K}` (same as
  Step 10). Includes `firing_propose_multiplicity_bounded/1` (arg `3 → {3, 3}`;
  its assertions use per-key `maps:get(index/name/status, O)` extraction, so the
  new `max` key does NOT break them).
- Change the line-1368-area assertion `?assertEqual(3, maps:get(multiplicity, Dep))`
  to `?assertEqual({3, 3}, maps:get(multiplicity, Dep))`.
- **Do NOT touch** `firing_propose_multiplicity_unbounded/1` (rewritten in Step 14).

- [ ] **Step 14: Rewrite `firing_propose_multiplicity_unbounded/1` → one outcome carrying `max => unbounded` (graphdb_instance.erl `_SUITE`).**

Replace (around lines 1496-1508):

```erlang
%%-----------------------------------------------------------------------------
%% B3 OI-B3-1: unbounded propose yields exactly ONE proposed outcome with
%% index=unbounded.
%%-----------------------------------------------------------------------------
firing_propose_multiplicity_unbounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, unbounded),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(1, length(Outs)),
	[#{index := Idx, status := proposed}] = Outs,
	?assertEqual(unbounded, Idx).
```

with (B-prep: `{1, unbounded}` propose ⇒ one outcome, index 1, `max => unbounded`):

```erlang
%%-----------------------------------------------------------------------------
%% B-prep: {1, unbounded} propose yields one proposed outcome (index 1) carrying
%% max => unbounded.  The old index=unbounded sentinel is retired (BP-D3).
%%-----------------------------------------------------------------------------
firing_propose_multiplicity_unbounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, {1, unbounded}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(1, length(Outs)),
	[#{index := Idx, status := proposed, max := Max}] = Outs,
	?assertEqual(1, Idx),
	?assertEqual(unbounded, Max).
```

(Test name unchanged, so no export/group edits needed.)

- [ ] **Step 15: Migrate EUnit `Dep` fixture maps in `graphdb_instance_tests.erl` (`multiplicity => K → {K, K}`).**

These `Dep` maps are passed verbatim into `add_outcome`/`merge_reports`/
`summarize` (which never destructure multiplicity), so they don't *break* — but
migrate for fixture accuracy. Change all three (lines 72, 83, 111):

```erlang
%% before
Dep = #{mode => mandatory, multiplicity => 2, template => 31},
%% after
Dep = #{mode => mandatory, multiplicity => {2, 2}, template => 31},
```

```erlang
Dep = #{mode => auto, multiplicity => {1, 1}, template => 31},
```

```erlang
Dep = #{mode => mandatory, multiplicity => {1, 1}, template => 31},
```

- [ ] **Step 16: Run the full suite — expect green.**

Run:
```sh
./rebar3 compile && ./rebar3 eunit && make test-ct-parallel
```
Expected: zero warnings; **105 EUnit** pass; all CT suites pass (`graphdb_rules_SUITE`
and `graphdb_instance_SUITE` counts unchanged at 63 / 76 — one rename, no add/remove
yet). If any test fails, it is almost certainly an un-migrated scalar call site or a
scalar deployment assertion — re-grep `grep -rn "mandatory, [0-9]\|auto, [0-9]\|propose, [0-9]\|, unbounded)\|multiplicity := [0-9]\|multiplicity, .*[^}]) ->" apps/graphdb/test/`.

- [ ] **Step 17: Commit.**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/src/graphdb_instance.erl \
        apps/graphdb/test/graphdb_rules_SUITE.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl \
        apps/graphdb/test/graphdb_instance_tests.erl
git commit -m "F4 B-prep: multiplicity becomes {Min,Max} range (cutover, behaviour-preserving)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Validation coverage for the `{Min, Max}` range (BP-D4)

Adds a focused CT case proving the full validation catalogue (§4). Test-after:
the behaviour exists from Task 1; this characterizes it.

**Files:**
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add the `multiplicity_range_validation/1` test.**

Use the `/6` create form (no explicit template — the owning class's default
template is used internally), exactly as `creates_composition_rule_minimal/1`
does. Reuse the existing `make_class` helper. Concretely:

```erlang
%% B-prep BP-D4: the {Min, Max} validation catalogue.
multiplicity_range_validation(_Config) ->
	Parent = make_class("Car"),
	Child  = make_class("Engine"),
	Ok = fun(Mult) ->
		{ok, _} = graphdb_rules:create_composition_rule(
			environment, "ok", Parent, Child, auto, Mult)
	end,
	Bad = fun(Mult) ->
		?assertEqual({error, invalid_multiplicity},
			graphdb_rules:create_composition_rule(
				environment, "bad", Parent, Child, auto, Mult))
	end,
	%% accepted
	Ok({1, 1}),
	Ok({0, 3}),
	Ok({2, unbounded}),
	%% rejected
	Bad({3, 1}),        %% Max < Min
	Bad({1, 0}),        %% Max < 1
	Bad({0, 0}),        %% Max < 1
	Bad(5),             %% bare integer
	Bad(unbounded),     %% bare unbounded
	Bad({a, b}).        %% non-integers
```

- [ ] **Step 2: Wire the test into exports and the group/sequence.**

Add `multiplicity_range_validation/1` to the export list (near
`invalid_multiplicity_rejected/1`, ~line 110) and to the same CT group +
sequence that contains `invalid_multiplicity_rejected` (~lines 192 and the
sequence list). Match the suite's existing grouping convention.

- [ ] **Step 3: Run the rules suite — expect green, +1 case.**

Run: `make test-ct-parallel FILTER=rules`
Expected: `graphdb_rules_SUITE` passes, **64 cases** (was 63).

- [ ] **Step 4: Commit.**

```bash
git add apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B-prep: validation coverage for {Min,Max} range (BP-D4)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Creation-firing coverage — mint = `Min` (BP-D2)

Proves mandatory + auto firing materialise exactly `Min` children, that `Min = 0`
mints none, and that `{Min, unbounded}` mints `Min` with no
`unbounded_multiplicity_not_fireable`. Test-after.

**Files:**
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

- [ ] **Step 1: Add mandatory mint-`Min` cases.**

Use the existing `?config(ob, Config)` fixture (`{Owner, Bolt}`) and
`create_instance/3` as the surrounding `firing_*` tests do. Add:

```erlang
%% B-prep BP-D2: mandatory composition mints Min children.
firing_mandatory_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB2-5", Owner, Bolt, mandatory, {2, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(2, length(Fired)),
	?assertEqual([1, 2], [maps:get(index, O) || O <- Fired]).

%% B-prep: {0, K} mandatory mints nothing (vacuous) and does not fail.
firing_mandatory_min_zero_mints_none(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB0-3", Owner, Bolt, mandatory, {0, 3}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(#{fired => 0, failed => 0, not_attempted => 0, proposed => 0},
				 graphdb_instance:summarize(Report)).
	%% summarize/1 returns exactly this 4-key map (graphdb_instance.erl:1444).

%% B-prep BP-D3: {1, unbounded} mandatory mints Min (1) — no
%% unbounded_multiplicity_not_fireable.
firing_mandatory_min_unbounded_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB1-U", Owner, Bolt, mandatory, {1, unbounded}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(1, length(Fired)),
	?assert(lists:all(fun(O) ->
		maps:get(reason, O, none) =/= unbounded_multiplicity_not_fireable
	end, Outs)).
```

If `summarize/1`'s empty-report shape differs from
`#{fired => 0, failed => 0, not_attempted => 0, proposed => 0}`, match the actual
shape returned (check the `summarize_counts_test` EUnit fixture / B3's 4-key map).

- [ ] **Step 2: Add auto mint-`Min` cases.**

The existing auto fixtures use an auto rule on a config'd owner/child; mirror the
`firing_auto_*` tests' setup. Add:

```erlang
%% B-prep BP-D2: auto composition mints Min children post-commit.
firing_auto_mints_min(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto2-5", Owner, Bolt, auto, {2, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	Fired = [O || O <- Outs, maps:get(status, O) =:= fired],
	?assertEqual(2, length(Fired)).

%% B-prep BP-D3: {0, unbounded} auto mints nothing and does not fail.
firing_auto_min_zero_unbounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBauto0-U", Owner, Bolt, auto, {0, unbounded}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	Outs = lists:append([maps:get(outcomes, RR) || RR <- Report]),
	?assertEqual([], [O || O <- Outs,
		maps:get(reason, O, none) =:= unbounded_multiplicity_not_fireable]),
	#{failed := 0} = graphdb_instance:summarize(Report).
```

- [ ] **Step 3: Wire the five tests into exports + the firing group/sequence.**

Add all five (`firing_mandatory_mints_min`, `firing_mandatory_min_zero_mints_none`,
`firing_mandatory_min_unbounded_mints_min`, `firing_auto_mints_min`,
`firing_auto_min_zero_unbounded`) to the export list and the firing CT group +
sequence (alongside `firing_auto_best_effort` / `firing_propose_multiplicity_*`,
~lines 135-141, 241-247, 309-314).

- [ ] **Step 4: Run the instance suite — expect green, +5 cases.**

Run: `make test-ct-parallel FILTER=instance`
Expected: `graphdb_instance_SUITE` passes, **81 cases** (was 76).

- [ ] **Step 5: Commit.**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "F4 B-prep: creation-firing coverage — mint = Min (BP-D2/BP-D3)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Propose coverage — surface `Min` carrying `max => Max` (BP-D2 choice (b))

Proves propose emits `Min` outcomes each carrying `max => Max`, with no
`index => unbounded` sentinel. Test-after.

**Files:**
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

- [ ] **Step 1: Add the bounded carry-`Max` case.**

```erlang
%% B-prep BP-D2(b): propose {3, 5} surfaces 3 outcomes, each carrying max => 5.
firing_propose_carries_max(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBp3-5", Owner, Bolt, propose, {3, 5}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(3, length(Outs)),
	?assertEqual([1, 2, 3], [maps:get(index, O) || O <- Outs]),
	?assert(lists:all(fun(O) -> maps:get(max, O) =:= 5 end, Outs)),
	?assert(lists:all(fun(O) -> maps:get(status, O) =:= proposed end, Outs)),
	%% no index=unbounded sentinel survives
	?assertEqual([], [O || O <- Outs, maps:get(index, O) =:= unbounded]).
```

- [ ] **Step 2: Add the `{0, K}` surfaces-nothing case (new BP-OI-1 capability).**

```erlang
%% B-prep: {0, K} propose surfaces nothing by default (Min = 0); the ceiling K
%% is for the future interactive-creation session (BP-OI-1).
firing_propose_min_zero_surfaces_none(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBp0-3", Owner, Bolt, propose, {0, 3}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(0, maps:get(proposed, graphdb_instance:summarize(Report))).
```

(The `{1, unbounded}` propose carrying `max => unbounded` is already covered by
`firing_propose_multiplicity_unbounded/1` as rewritten in Task 1 Step 14.)

- [ ] **Step 3: Wire both tests into exports + the firing group/sequence.**

Add `firing_propose_carries_max` and `firing_propose_min_zero_surfaces_none` to the
export list and the firing CT group + sequence (alongside the
`firing_propose_multiplicity_*` entries).

- [ ] **Step 4: Run the instance suite — expect green, +2 cases.**

Run: `make test-ct-parallel FILTER=instance`
Expected: `graphdb_instance_SUITE` passes, **83 cases** (was 81 after Task 3).

- [ ] **Step 5: Commit.**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "F4 B-prep: propose coverage — surface Min carrying max => Max (BP-D2 (b))

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Docs + test-count tables + final verification

Bring the worker doc, parent design, and README in line; run the full suite and
record final counts.

**Files:**
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `docs/designs/f4-graphdb-rules-design.md`
- Modify: `README.md`

- [ ] **Step 1: Update `apps/graphdb/CLAUDE.md` (graphdb_rules section).**

In the `graphdb_rules` API list, note the multiplicity type. Change the
`create_composition_rule` / `create_connection_rule` bullet lines to state the
multiplicity argument is a `{Min, Max}` range (`Min :: non_neg_integer()`,
`Max :: pos_integer() | unbounded`), e.g. append to each bullet:
"`multiplicity` is a `{Min, Max}` cardinality range (B-prep)." Add a one-line note
that the `applies_to` arc's `multiplicity` deployment AVP stores the `{Min, Max}`
tuple.

- [ ] **Step 2: Update `docs/designs/f4-graphdb-rules-design.md`.**

Find the deployment-AVP description (D5) and the `unbounded_multiplicity_not_fireable`
references: `grep -n "multiplicity\|unbounded_multiplicity_not_fireable\|index => unbounded\|index=unbounded" docs/designs/f4-graphdb-rules-design.md`.

- Record that the `multiplicity` deployment AVP value is a `{Min, Max}` range
  (point to `f4-bprep-multiplicity-range-design.md`).
- Mark `unbounded_multiplicity_not_fireable` (PLAN + auto) and the propose
  `index => unbounded` sentinel as **retired by B-prep**; note propose outcomes
  now carry `max => Max`.

Do **not** rewrite the §B pre-decomposition narrative (that reconciliation is a
separately-tracked follow-up) — only the multiplicity-shape and retirement facts.

- [ ] **Step 3: Update the README test-count table.**

Run the full suite first to get exact counts:
```sh
./rebar3 eunit && make test-ct-parallel
```
Then update `README.md`:
- Line ~32 total: EUnit unchanged at 105; CT rises by **+7** (Task 2 +1, Task 3 +5,
  Task 4 +2 — verify against the runner output) to **378**, total **483**. Use the
  measured numbers if they differ.
- `graphdb_rules_SUITE` row: 63 → **64**.
- `graphdb_instance_SUITE` row: 76 → **83**.

- [ ] **Step 4: Final full verification.**

Run:
```sh
./rebar3 compile && ./rebar3 eunit && make test-ct-parallel
```
Expected: zero warnings; 105 EUnit pass; all CT suites pass; aggregate CT count
matches the README update. Confirm `grep -rn "unbounded_multiplicity_not_fireable"
apps/graphdb/` returns **nothing** (fully retired) and
`grep -rn "index => unbounded" apps/graphdb/` returns **nothing** in production
(`apps/graphdb/src/`).

- [ ] **Step 5: Commit.**

```bash
git add apps/graphdb/CLAUDE.md docs/designs/f4-graphdb-rules-design.md README.md
git commit -m "F4 B-prep: docs + test counts for {Min,Max} multiplicity

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Done criteria

- `multiplicity` is `{Min, Max}` at every author/store/decode/validate/fire site,
  composition **and** connection rules, identical shape.
- `validate_multiplicity/1` accepts `{Min, Max}` per BP-D4; bare scalars and
  `{0, 0}` / `Max < Min` / `Max < 1` rejected with `invalid_multiplicity`.
- mandatory + auto firing mint `Min`; propose surfaces `Min` outcomes each carrying
  `max => Max`.
- `unbounded_multiplicity_not_fireable` and the propose `index => unbounded`
  sentinel produce nowhere.
- Full suite green, zero warnings; README counts updated.
- No `bootstrap.terms`, `ontology-tree.md`, or seed changes; no `create_*_rule`
  arity change.

After all tasks: use **superpowers:finishing-a-development-branch** to open the PR
to `upstream/main` (`gh pr create -R davidwt-com/SeerStoneGraphDb --base main
--head david-w-t:develop`). B-prep lands first; B4 then consumes the `{Min, Max}`
shape.
