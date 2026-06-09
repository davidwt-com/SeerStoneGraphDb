<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B3 — Propose Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `propose`-mode composition rules surface as `proposed`
outcomes in the `create_instance/3` report, without materialising
anything and without any new API.

**Architecture:** `graphdb_rules`' pure-read planner gains a fourth
accumulator, `propose_rules`, parallel to `auto_rules` (Task 1).
`graphdb_instance` adds a post-commit, side-effect-free `fire_propose/2`
pass that walks the instantiated plan tree and emits `proposed` outcomes,
plus a `proposed` counter on `summarize/1` (Task 2). Docs refresh (Task 3).

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27, Common Test, EUnit, Mnesia.

**Design:** `docs/designs/f4-phase-b3-propose-mode-design.md`.

**Build/test commands** (from project root, `./rebar3` is on PATH via
`.claude/settings.local.json`):

- Single CT suite: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
- Single CT case: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case plan_propose_accumulated`
- EUnit (one module): `./rebar3 eunit --module=graphdb_instance_tests`
- Full CT (parallel, ~20s): `make test-ct-parallel`
- Compile (warnings are errors in this project's hygiene bar): `./rebar3 compile`

---

## Background the implementer needs

**The abstract plan tree** is built by `graphdb_rules` and consumed by
`graphdb_instance`. Each node is a map. Today (post-B2) `leaf_plan/4`
produces:

```erlang
#{class => ClassNref, name => Name, rule => Rule, deploy => Deploy,
  mandatory_children => [], auto_rules => []}
```

- `mandatory_children` — recursively expanded child plan nodes.
- `auto_rules` — `[{RuleNode, Deploy}]`, **unexpanded** (multiplicity is
  expanded later, at fire time in `graphdb_instance`).

`plan_rules/4` (in `graphdb_rules.erl`) classifies each effective rule by
its deployment `mode`. The `auto` clause accumulates into `auto_rules`;
the `mandatory` clause recurses; the `propose` clause currently **drops**
the rule (`%% B3 owns propose`). B3 replaces that drop with accumulation
into a new `propose_rules` list.

`allocate_plan/1` (in `graphdb_instance.erl`) annotates each plan node
with an allocated `nref` and recurses `mandatory_children`. It uses a map
update (`Node#{nref => ..., mandatory_children => ...}`), so it
**preserves** `auto_rules` and the new `propose_rules` automatically — no
change needed there.

`fire_auto/2` (in `graphdb_instance.erl`) walks the instantiated plan
tree post-commit: at each node it fires `auto_rules`, then recurses
`mandatory_children`. `fire_propose/2` (new in B3) mirrors this exactly
but emits `proposed` outcomes and creates nothing.

**The report** is rule-centric: `[#{rule, deployment, outcomes}]`. An
outcome is a map; B2 statuses are `fired | failed | not_attempted`. B3
adds `proposed`. Helpers `add_outcome/4`, `merge_reports/2`,
`summarize/1` already exist in `graphdb_instance.erl`.

**The two cross-process helpers** B3 reuses (already exported from
`graphdb_rules`, callable from `graphdb_instance`):

- `graphdb_rules:rule_child_class(RuleNode) -> integer() | undefined`
- `graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Mult) -> string()`

---

## File Structure

| File                                                                                                                                                               | Responsibility / change                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`                                                                                                                               | `leaf_plan/4` adds `propose_rules => []`; `plan_rules/4` propose clause accumulates.                                         |
| `apps/graphdb/src/graphdb_instance.erl`                                                                                                                            | New `fire_propose/2`, `fire_one_propose/5`, `propose_children/7`; wire into `fire_create/4`; `summarize/1` gains `proposed`. |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`                                                                                                                        | Plan-tree CT cases + group/fixture-list entries.                                                                             |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`                                                                                                                     | Firing CT cases + group/fixture-list entries; update 3 existing `summarize` assertions.                                      |
| `apps/graphdb/test/graphdb_instance_tests.erl`                                                                                                                     | Update `summarize_counts_test` to include a `proposed` outcome and the new key.                                              |
| `docs/diagrams/ontology-tree.md`                                                                                                                                   | No change (no new seeds).                                                                                                    |
| `ARCHITECTURE.md`, `apps/graphdb/CLAUDE.md`, `README.md`, `TASKS.md`, `docs/designs/f4-graphdb-rules-design.md`, `docs/designs/f4-phase-b3-propose-mode-design.md` | Status + test-count refresh; mark B3 landed.                                                                                 |

---

## Task 1: Plan tree — `propose_rules` accumulator in `graphdb_rules`

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (`leaf_plan/4` ~line 889;
  `plan_rules/4` propose clause ~line 927)
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add three test functions at the end of the Composition Tests section
(just before the `%% Connection Tests` banner, around line 521 of
`graphdb_rules_SUITE.erl`):

```erlang
%%-----------------------------------------------------------------------------
%% B3: a propose-mode rule lands in propose_rules (NOT auto_rules /
%% mandatory_children), unexpanded — exactly one {RuleNode, Deploy} entry
%% regardless of multiplicity.
%%-----------------------------------------------------------------------------
plan_propose_accumulated(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, 3),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{class := Owner, mandatory_children := [], auto_rules := [],
	  propose_rules := [{_RuleNode, Dep}]} = Plan,
	?assertEqual(propose, maps:get(mode, Dep)),
	?assertEqual(3, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% B3: one rule of each mode on the same owner populates all three
%% accumulators independently.
%%-----------------------------------------------------------------------------
plan_mixed_modes(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	Gizmo = make_class("Gizmo"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "man", Owner, Bolt, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "aut", Owner, Widget, auto, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "pro", Owner, Gizmo, propose, 1),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{mandatory_children := Mand, auto_rules := Auto,
	  propose_rules := Prop} = Plan,
	?assertEqual(1, length(Mand)),
	?assertEqual(1, length(Auto)),
	?assertEqual(1, length(Prop)),
	%% the mandatory child is the Bolt class, not Widget/Gizmo
	[#{class := Bolt}] = Mand.

%%-----------------------------------------------------------------------------
%% B3: a propose rule attached to a MANDATORY child's class appears in that
%% child's plan node (propose rides the mandatory-cascade recursion).
%%-----------------------------------------------------------------------------
plan_propose_at_mandatory_child(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BWpropose", Bolt, Widget, propose, 1),
	{ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
	#{mandatory_children := [BoltPlan]} = Plan,
	#{class := Bolt, propose_rules := [{_R, Dep}]} = BoltPlan,
	?assertEqual(propose, maps:get(mode, Dep)).
```

Register the three cases in the `plan_firing` group. In `graphdb_rules_SUITE.erl`
find the `plan_firing` group list (around line 225) and append the three
names, and add the same to the export list (around line 63) and to the
`PlanFiringCases` list in `plan_firing_fixtures/2` (around line 278).

Export list — add after `plan_auto_annotated_not_expanded/1,` (line 66):

```erlang
	plan_propose_accumulated/1,
	plan_mixed_modes/1,
	plan_propose_at_mandatory_child/1,
```

`plan_firing` group (around line 225-233) — append after the last
existing entry in that group's list:

```erlang
			plan_propose_accumulated,
			plan_mixed_modes,
			plan_propose_at_mandatory_child
```

(Add a comma to the previously-last entry so the list stays valid.)

`PlanFiringCases` list in `plan_firing_fixtures/2` (around line 278-284) —
append the three names so they receive the `ob` / `obw` fixtures:

```erlang
		plan_propose_accumulated, plan_mixed_modes,
		plan_propose_at_mandatory_child
```

(Again, fix the trailing comma on the prior last entry.)

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case plan_propose_accumulated
```
Expected: FAIL — the plan map has no `propose_rules` key, so the match
`#{... propose_rules := [...]} = Plan` raises `{badmatch, ...}`. (The
propose rule is currently dropped by `plan_rules/4`.)

- [ ] **Step 3: Implement the plan-tree change**

In `apps/graphdb/src/graphdb_rules.erl`, change `leaf_plan/4` (around
line 889) to add the fourth accumulator:

```erlang
leaf_plan(ClassNref, Rule, Deploy, Name) ->
	#{class => ClassNref, name => Name, rule => Rule, deploy => Deploy,
	  mandatory_children => [], auto_rules => [], propose_rules => []}.
```

Then change the `propose` clause of `plan_rules/4` (around line 927) from
the current drop to accumulation:

```erlang
		propose ->
			%% B3: accumulate (B2 dropped these).  Mirrors the `auto` clause;
			%% graphdb_instance:fire_propose/2 expands multiplicity post-commit
			%% and emits `proposed` outcomes.  Unexpanded here, like auto_rules.
			Proposes = maps:get(propose_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Acc#{propose_rules => Proposes});
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE
```
Expected: PASS — the whole suite is green, including the three new cases.
(Existing partial-map matches like `#{mandatory_children := [],
auto_rules := [...]}` still match because they don't mention
`propose_rules`.)

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "$(cat <<'EOF'
F4 B3: plan tree accumulates propose_rules (was dropped in B2)

leaf_plan/4 gains a fourth accumulator parallel to auto_rules; the
plan_rules/4 propose clause stops dropping propose-mode rules and
accumulates them unexpanded. +3 CT plan-tree cases.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Firing — `fire_propose/2` in `graphdb_instance`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`fire_create/4` ~line
  477; add `fire_propose/2` etc. after `fire_one_auto/5` ~line 642;
  `summarize/1` ~line 1370)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`,
  `apps/graphdb/test/graphdb_instance_tests.erl`

- [ ] **Step 1: Write the failing CT tests**

Add these test functions at the end of the Firing Tests (B2) section in
`graphdb_instance_SUITE.erl` (just before the `%% Internal Helpers`
banner, around line 1422):

```erlang
%%-----------------------------------------------------------------------------
%% B3: a propose rule surfaces a `proposed` outcome carrying owner (the
%% materialised parent), proposed_class, index and name — and creates NOTHING.
%%-----------------------------------------------------------------------------
firing_propose_outcome_in_report(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, 1),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% no child materialised
	?assertEqual({ok, []}, graphdb_instance:children(Root)),
	%% exactly one proposed outcome, owner=Root, proposed_class=Bolt, no child key
	[#{outcomes := [Outcome]}] = Report,
	?assertEqual(proposed, maps:get(status, Outcome)),
	?assertEqual(Root, maps:get(owner, Outcome)),
	?assertEqual(Bolt, maps:get(proposed_class, Outcome)),
	?assertEqual(1, maps:get(index, Outcome)),
	?assertNot(maps:is_key(child, Outcome)).      %% no created-instance key

%%-----------------------------------------------------------------------------
%% B3: a propose rule materialises nothing — node table size is unchanged
%% beyond the single root instance.
%%-----------------------------------------------------------------------------
firing_propose_not_materialised(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, 3),
	Before = mnesia:table_info(nodes, size),
	{ok, _Root, _Report} = graphdb_instance:create_instance("car", Owner, 5),
	After = mnesia:table_info(nodes, size),
	?assertEqual(Before + 1, After).      %% only the root, no proposed children

%%-----------------------------------------------------------------------------
%% B3: multiplicity=3 propose yields three proposed outcomes, indices 1..3,
%% names per name_pattern.
%%-----------------------------------------------------------------------------
firing_propose_multiplicity_bounded(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, 3, undefined,
		#{name_pattern => "Spare {i}"}),
	{ok, _Root, [#{outcomes := Outs}]} =
		graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(3, length(Outs)),
	?assertEqual([1, 2, 3], [maps:get(index, O) || O <- Outs]),
	?assertEqual(["Spare 1", "Spare 2", "Spare 3"],
				 [maps:get(name, O) || O <- Outs]),
	?assert(lists:all(fun(O) -> maps:get(status, O) =:= proposed end, Outs)).

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

%%-----------------------------------------------------------------------------
%% B3 OI-B3-2: a propose rule whose child class is already on the
%% root->here path is cut — no proposed outcome.  Owner's class proposes
%% Owner (self), so nothing is surfaced.
%%-----------------------------------------------------------------------------
firing_propose_on_path_cut(Config) ->
	{Owner, _Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "selfpropose", Owner, Owner, propose, 1),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual([], Report).

%%-----------------------------------------------------------------------------
%% B3: summarize/1 counts proposed outcomes (and the map gains the key).
%%-----------------------------------------------------------------------------
firing_propose_summarize(Config) ->
	{Owner, Bolt} = ?config(ob, Config),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OBpropose", Owner, Bolt, propose, 2),
	{ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	?assertEqual(#{fired => 0, failed => 0, not_attempted => 0, proposed => 2},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% B3: all three modes on one create — mandatory + auto materialise, propose
%% is surfaced but not materialised.
%%-----------------------------------------------------------------------------
firing_propose_with_mandatory_and_auto(Config) ->
	{Owner, Bolt, Widget} = ?config(obw, Config),
	%% graphdb_instance_SUITE has no make_class/1 helper — create the third
	%% class directly (parent nref 3 = Classes category).
	{ok, Gizmo} = graphdb_class:create_class("Gizmo", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "man", Owner, Bolt, mandatory, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "aut", Owner, Widget, auto, 1),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "pro", Owner, Gizmo, propose, 1),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
	%% two children materialised (mandatory Bolt + auto Widget), Gizmo is not
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(2, length(Kids)),
	?assertEqual(#{fired => 2, failed => 0, not_attempted => 0, proposed => 1},
				 graphdb_instance:summarize(Report)).
```

Register the seven cases. In `graphdb_instance_SUITE.erl`:

Export list — add (alongside the other firing exports; search for
`firing_no_rules_baseline/1`):

```erlang
	firing_propose_outcome_in_report/1,
	firing_propose_not_materialised/1,
	firing_propose_multiplicity_bounded/1,
	firing_propose_multiplicity_unbounded/1,
	firing_propose_on_path_cut/1,
	firing_propose_summarize/1,
	firing_propose_with_mandatory_and_auto/1,
```

`firing` group list (around line 227-236) — append after
`firing_auto_cascade_merges` (add a comma to it):

```erlang
			firing_propose_outcome_in_report,
			firing_propose_not_materialised,
			firing_propose_multiplicity_bounded,
			firing_propose_multiplicity_unbounded,
			firing_propose_on_path_cut,
			firing_propose_summarize,
			firing_propose_with_mandatory_and_auto
```

`FiringTests` list in `setup_firing_fixtures/2` (around line 290-294) —
append the seven names so they receive the `ob` / `obw` / `oa` fixtures:

```erlang
				   firing_propose_outcome_in_report,
				   firing_propose_not_materialised,
				   firing_propose_multiplicity_bounded,
				   firing_propose_multiplicity_unbounded,
				   firing_propose_on_path_cut,
				   firing_propose_summarize,
				   firing_propose_with_mandatory_and_auto],
```

(Fix the trailing comma on the prior last entry, `firing_auto_cascade_merges`.)

- [ ] **Step 2: Run the CT tests to verify they fail**

Run:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case firing_propose_outcome_in_report
```
Expected: FAIL — propose rules contribute nothing today, so `Report` is
`[]` and the match `[#{outcomes := [Outcome]}] = Report` raises
`{badmatch, []}`.

- [ ] **Step 3: Implement `fire_propose/2` and wire it in**

In `apps/graphdb/src/graphdb_instance.erl`, update `fire_create/4`
(around line 477) to compute and merge the propose report:

```erlang
fire_create(Name, ClassNref, ParentNref, OnPath) ->
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref) of
		{ok, PlanTree} ->
			case execute(Name, ClassNref, ParentNref, OnPath, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan} ->
					AutoReport    = fire_auto(InstPlan, OnPath),
					ProposeReport = fire_propose(InstPlan, OnPath),
					{ok, RootNref,
					 merge_reports(merge_reports(MandOutcomes, AutoReport),
								   ProposeReport)};
				{error, R, Report} ->
					{error, R, Report}
			end;
		{error, R, Failure} ->
			{error, R, report_not_attempted(R, Failure)}
	end.
```

Add the new functions immediately after `fire_one_auto/5` ends (around
line 642, before the next section banner):

```erlang
%%-----------------------------------------------------------------------------
%% fire_propose(InstPlan, OnPath) -> report()
%%
%% POST-COMMIT, side-effect-free (B3).  Walks the instantiated plan tree
%% (root + mandatory descendants) and surfaces each node's propose_rules as
%% `proposed` outcomes.  Materialises NOTHING — a proposal is a suggestion the
%% caller may accept by calling create_instance/3 for the proposed_class
%% itself (which then fires that child's own rules).  Auto children are not in
%% InstPlan; their propose rules surface via their own do_create_instance
%% sub-report.  Mirrors fire_auto/2's traversal.
%%
%% B3 OI-B3-5 (shallow): no recursion into proposed children — nothing is
%% created, so there is nothing to recurse into.  A future propose-with-options
%% feature may supersede this.
%%-----------------------------------------------------------------------------
fire_propose(#{nref := Nref, class := Class, propose_rules := Props,
			   mandatory_children := Kids}, OnPath) ->
	OnPath1 = [Class | OnPath],
	Here = lists:foldl(
		fun({RuleNode, Deploy}, Acc) ->
			fire_one_propose(RuleNode, Deploy, Nref, OnPath1, Acc)
		end, [], Props),
	lists:foldl(
		fun(Child, Acc) -> merge_reports(Acc, fire_propose(Child, OnPath1)) end,
		Here, Kids).

%%-----------------------------------------------------------------------------
%% fire_one_propose(RuleNode, Deploy, OwnerNref, OnPath1, Acc) -> report()
%%
%% Emits `proposed` outcome(s) for one propose rule.  No instantiability
%% guard (B3 design §3.2): a proposal creates nothing, so an abstract target
%% cannot break anything; the caller validates on accept.
%%-----------------------------------------------------------------------------
fire_one_propose(RuleNode, Deploy, OwnerNref, OnPath1, Acc) ->
	ChildClass = graphdb_rules:rule_child_class(RuleNode),
	%% B3 OI-B3-2: on-path cycle cut — do not propose a class already on the
	%% root->here path (mirrors B2-D5).  Supersedable by propose-with-options.
	case lists:member(ChildClass, OnPath1) of
		true ->
			Acc;
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

%%-----------------------------------------------------------------------------
%% propose_children(RuleNode, Deploy, ChildClass, Mult, I, OwnerNref, Acc)
%%   -> report()
%% Emits one `proposed` outcome per multiplicity index 1..Mult.
%%-----------------------------------------------------------------------------
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

Update `summarize/1` (around line 1370) and its doc comment to add the
`proposed` count:

```erlang
%%-----------------------------------------------------------------------------
%% summarize(Report) -> #{fired => N, failed => M, not_attempted => K,
%%                        proposed => P}
%%-----------------------------------------------------------------------------
summarize(Report) ->
	Outs = [O || #{outcomes := Os} <- Report, O <- Os],
	Count = fun(S) -> length([1 || #{status := X} <- Outs, X =:= S]) end,
	#{fired => Count(fired), failed => Count(failed),
	  not_attempted => Count(not_attempted), proposed => Count(proposed)}.
```

- [ ] **Step 4: Fix the three existing B2 CT summarize assertions**

Adding the `proposed` key changes `summarize/1`'s return shape, so the
three existing B2 assertions in `graphdb_instance_SUITE.erl` must gain
`proposed => 0`:

- Line ~1392 (`firing_auto_best_effort`):
  ```erlang
	?assertEqual(#{fired => 1, failed => 0, not_attempted => 0, proposed => 0},
				 graphdb_instance:summarize(Report)).
  ```
- Line ~1405 (`firing_auto_failure_survives`):
  ```erlang
	?assertEqual(#{fired => 0, failed => 1, not_attempted => 0, proposed => 0},
				 graphdb_instance:summarize(Report)).
  ```
- Line ~1420 (`firing_auto_cascade_merges`):
  ```erlang
	?assertEqual(#{fired => 2, failed => 0, not_attempted => 0, proposed => 0},
				 graphdb_instance:summarize(Report)).
  ```

- [ ] **Step 5: Update the EUnit `summarize_counts_test`**

In `apps/graphdb/test/graphdb_instance_tests.erl`, replace
`summarize_counts_test/0` (around line 109) so it also exercises a
`proposed` outcome and asserts the new key:

```erlang
summarize_counts_test() ->
	Rule = mk_rule(100),
	Dep = #{mode => mandatory, multiplicity => 1, template => 31},
	R0 = graphdb_instance:add_outcome([], Rule, Dep,
			#{owner => 5, index => 1, status => fired, child => 200}),
	R1 = graphdb_instance:add_outcome(R0, Rule, Dep,
			#{owner => 5, index => 1, status => failed, reason => x}),
	R2 = graphdb_instance:add_outcome(R1, Rule, Dep,
			#{owner => 5, index => 1, status => proposed, proposed_class => 9,
			  name => "P"}),
	?assertEqual(#{fired => 1, failed => 1, not_attempted => 0, proposed => 1},
				 graphdb_instance:summarize(R2)).
```

- [ ] **Step 6: Run the full instance suites to verify they pass**

Run:
```bash
./rebar3 eunit --module=graphdb_instance_tests
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE
```
Expected: PASS — both suites green, including the seven new firing cases
and the updated summarize assertions.

- [ ] **Step 7: Run the whole CT suite to confirm nothing else broke**

Run:
```bash
make test-ct-parallel
```
Expected: all suites green. (No other suite asserts `summarize/1`'s shape;
this is a final guard.)

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl \
        apps/graphdb/test/graphdb_instance_tests.erl
git commit -m "$(cat <<'EOF'
F4 B3: fire_propose surfaces proposed outcomes (always-in-report)

Post-commit, side-effect-free pass mirroring fire_auto: walks the
instantiated plan tree, emits `proposed` outcomes carrying owner +
proposed_class + name. Creates nothing. Unbounded => single outcome
(OI-B3-1); on-path cycle cut (OI-B3-2); no instantiability guard;
shallow (OI-B3-5). summarize/1 gains a proposed count; existing B2
assertions updated. +7 CT cases, EUnit summarize case extended.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Documentation refresh

**Files:**
- Modify: `docs/designs/f4-phase-b3-propose-mode-design.md` (status flip)
- Modify: `docs/designs/f4-graphdb-rules-design.md` (B3 row + OI note)
- Modify: `ARCHITECTURE.md`, `apps/graphdb/CLAUDE.md`, `README.md`,
  `TASKS.md`

- [ ] **Step 1: Flip the B3 design status**

In `docs/designs/f4-phase-b3-propose-mode-design.md`, change the header
line:

```
**Status:** Specified. No implementation has begun.
```
to:
```
**Status:** Implemented (PR pending).
```

- [ ] **Step 2: Update the parent design division map and OI notes**

In `docs/designs/f4-graphdb-rules-design.md`:

- In the Phase B division table (around line 813), change the **B3** row's
  Subject to reflect the always-in-report decision (no session flag):
  ```
  | **B3** | `propose` mode — proposals always surfaced in the create report (no session flag) | B2 | `docs/designs/f4-phase-b3-propose-mode-design.md` |
  ```
- Update **OI-B2-2** (around line 652) to mark it RESOLVED by B3:
  ```
  - **OI-B2-2 (RESOLVED by B3).** `propose`-mode rules surface as
    `proposed` outcomes in the create_instance report (always-in-report;
    no session flag). See `docs/designs/f4-phase-b3-propose-mode-design.md`.
  ```

- [ ] **Step 3: Update `apps/graphdb/CLAUDE.md`**

In the `graphdb_rules` worker description, change the phase summary from
"F4 Phase A + B1 + B2" to "F4 Phase A + B1 + B2 + B3" wherever it appears
(the worker table row and the "Worker Responsibilities" heading and the
NYI Status paragraph), and update the one-line description of
`create_instance/3` propose handling: add a sentence to the
`graphdb_instance` `create_instance/3` bullet:

```
Propose-mode composition rules surface as `proposed` outcomes in the
report (B3); nothing is materialised for them.
```

Update the firing-engine remaining-work line to "(Phases B4–F)".

- [ ] **Step 4: Update `ARCHITECTURE.md`**

Find the F4 / rules-engine status text and append B3 to the landed list
(B1 + B2 + B3); note that `create_instance/3` now also surfaces
`proposed` outcomes. Keep it at architectural altitude (one or two
sentences); do not paste implementation detail.

- [ ] **Step 5: Update `README.md` test counts**

Recompute the totals. B3 adds 3 CT (Task 1) + 7 CT (Task 2) = **10 CT**
cases, and changes 0 EUnit case counts (the EUnit change edits an
existing test, not adds one). New totals: **370 CT + 105 EUnit = 475**.

Run the per-suite counts to confirm before editing:
```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE 2>&1 | tail -5
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE 2>&1 | tail -5
```
Update the README test-count line and the per-suite table rows for
`graphdb_rules_SUITE` (+3) and `graphdb_instance_SUITE` (+7) to the
verified numbers. If the verified totals differ from 370/475, use the
verified numbers.

- [ ] **Step 6: Update `TASKS.md`**

Mark F4 Phase B / Division B3 as landed (propose mode, always-in-report);
note B4 (connection firing) and B5 (precedence) remain. If TASKS.md lists
the Phase B division checklist, tick B3.

- [ ] **Step 7: Commit**

```bash
git add docs/designs/f4-phase-b3-propose-mode-design.md \
        docs/designs/f4-graphdb-rules-design.md \
        ARCHITECTURE.md apps/graphdb/CLAUDE.md README.md TASKS.md
git commit -m "$(cat <<'EOF'
F4 B3: docs — mark propose mode landed; test counts; OI-B2-2 resolved

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

- [ ] `./rebar3 compile` — zero warnings (project hygiene bar).
- [ ] `make test-ct-parallel` — all CT suites green.
- [ ] `./rebar3 eunit` — all EUnit green.
- [ ] Spot-check: a `create_instance/3` on a class with one propose rule
  returns `{ok, Nref, [#{outcomes := [#{status := proposed, ...}]}]}` and
  leaves the proposed child class with no new instances.

Then proceed to `superpowers:finishing-a-development-branch`.
