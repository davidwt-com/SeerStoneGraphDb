<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B5 — Horizontal Conflict Precedence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert a conflict-resolution pass on the rule-firing path so that when
a class and its taxonomy ancestors attach rules touching the same component or
connection, one rule wins, multiplicity is merged, and templated losers surface
as proposals — without changing the additive B1 read contract.

**Architecture:** A conflict-resolver fun is threaded through `create_instance`
(mirroring B4's connection resolver). The **default** resolver is built by
`graphdb_rules:default_conflict_resolver/0` — a closure that bakes in the seeded
attribute nrefs (read once in the caller's process) and dispatches on a `kind`
field. For **composition** the resolver is applied inside `graphdb_rules:plan_node`
(per cascade level); for **connection** it is applied inside
`graphdb_instance:resolve_nodes` (per plan node). Both apply points run the same
fun; it touches only in-memory `#node` AVPs plus `graphdb_class` (a different
gen_server), so it is deadlock-safe in either process.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27.0, Mnesia, Common Test. Build with
`./rebar3 compile`. Run a single CT suite case with
`./rebar3 ct --suite apps/graphdb/test/<suite> --case <case>`.

**Design:** `docs/designs/f4-phase-b5-conflict-precedence-design.md`
(decisions B5-D1…B5-D7).

---

## Background the engineer needs

### The two seams

- **Composition.** `graphdb_rules:plan_node/6` (runs *inside the graphdb_rules
  gen_server process*) calls `composition_pairs/2` — a flattened, nearest-first
  `[{RuleNode, Deploy}]` list across the class and all its taxonomy ancestors —
  then hands it to `plan_rules/4`. B5 transforms that list before `plan_rules`.
- **Connection.** `graphdb_instance:resolve_nodes/3` (runs *inside the
  graphdb_instance gen_server process*) calls
  `graphdb_rules:effective_connection_rules/2` — a flattened, nearest-first
  `[{Rule, Deploy, Spec}]` list where each `Spec` is
  `#{characterization, reciprocal, target_class}` — then hands it to
  `resolve_rules/4`. B5 transforms that list before `resolve_rules`.

### Why the default resolver is a closure, not an atom

The conflict resolver is **always a fun** (mirrors B4's `report_only/1`
connection-resolver default). `create_instance/3` and `/4` inject the default by
calling `graphdb_rules:default_conflict_resolver/0` **in the caller's process**,
where the `seeded_nrefs/0` gen_server call is safe (no self-call). That function
returns ONE closure that has the three seed nrefs it needs baked in
(`child_class_nref_attr`, `template_nref_attr`, `applied_by`) and dispatches on
the context's `kind`. The closure never calls back into the `graphdb_rules`
gen_server, so applying it inside the `graphdb_rules` process (composition) does
not deadlock. It does call `graphdb_class` — that is a *different* gen_server, and
`plan_mandatory` already calls `graphdb_class:is_instantiable/1` from inside the
rules process (`graphdb_rules.erl:1019`), proving such calls are safe there.

### The B5 algorithm (default resolver), per cascade level / per node

Operating on the nearest-first list for ONE class:

1. **Group** (B5-D1). Walk nearest-first. Each rule joins the first existing
   group whose nearest (anchor) member it *matches*, else starts a new group.
   - Composition match: the anchor's `child_class` **is-a** (descendant-or-self
     of) the candidate's `child_class`.
   - Connection match: same `characterization` **and** anchor's `target_class`
     **is-a** the candidate's `target_class`.
   - The is-a test is `graphdb_class:class_in_ancestry(FartherRef, NearerRef)` —
     **ancestor first, descendant second** (arg-order hazard; B4 has a canary
     test for the same call). Here `FartherRef` = candidate's ref, `NearerRef` =
     anchor's ref.
2. **Winner** (B5-D2). Within a group, the nearest level's members are the
   prefix that shares the head member's owning class. The winner is the
   highest-mode-priority member of that prefix (`mandatory > auto > propose`),
   ties broken by arc/encounter order. The winner contributes the surviving
   **mode** and **`Min`**.
3. **Multiplicity** (B5-D3). Surviving `Min` = winner's `Min`. Surviving `Max` =
   greatest `Max` across the winner and its **dropped** losers (`unbounded`
   dominates). Demoted-to-propose losers do **not** contribute to the merge.
4. **Disposition** (B5-D4/D5). A loser is **dropped** unless **both** the winner
   and that loser carry a **real (non-default) template** — then the loser is
   re-emitted as an independent `propose` entry keeping its own `{Min, Max}`. A
   "real template" is a content `template_nref` AVP whose value differs from the
   rule's *owning class's default template* (re-derived from the rule's
   `applied_by` arc).

### File structure

| File                                          | Responsibility for B5                                                                                  |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `apps/graphdb/src/graphdb_rules.erl`          | `default_conflict_resolver/0`; the private resolver algorithm; `plan_composition_firing/3`; thread the resolver through `plan_node`/`plan_rules`/`plan_mandatory`/`expand_children` |
| `apps/graphdb/src/graphdb_instance.erl`       | `create_instance/5`; carry `conflict_resolver` in `Ctx`; apply it in `resolve_nodes`                   |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`   | resolver-algorithm CT cases (composition + connection grouping, merge, demote)                          |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`| firing-time CT cases proving resolution end-to-end + the custom-resolver override                       |
| `apps/graphdb/CLAUDE.md`, `docs/Architecture.md` (if contract shifts), `docs/diagrams/ontology-tree.md` (no change — B5 seeds nothing) | docs |

The B1 public read contract (`effective_rules_for_class/2`,
`plan_composition_firing/2`) is **preserved as additive** (design §1.3).
Resolution happens only on the `create_instance` firing path.

---

## Task 1: Thread a conflict-resolver fun through the firing path (behaviour-preserving)

Introduce the plumbing with an **identity** default resolver so the whole suite
stays green and behaviour is unchanged. Later tasks replace the default body.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (add `default_conflict_resolver/0`,
  `plan_composition_firing/3`, thread `Resolver` through the plan internals)
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`create_instance/5`, `Ctx`,
  `resolve_nodes` apply point)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

- [ ] **Step 1: Write the failing test (identity default ⇒ unchanged firing; /5 accepted)**

Add to `apps/graphdb/test/graphdb_instance_SUITE.erl`. Add both names to `all/0`
(or the relevant group list) so they run. These cases build their own classes
(they do not need the `ob`/`obw` fixtures; the worker stack is started by
`init_per_testcase` unconditionally).

```erlang
%%-----------------------------------------------------------------------------
%% B5 plumbing: create_instance/5 is accepted and, with the default resolver,
%% a single inherited mandatory rule still fires exactly as /3 (no regression).
%%-----------------------------------------------------------------------------
b5_create_instance_5_accepts_resolvers(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	Conn     = fun(_Ctx) -> defer end,
	Conflict = graphdb_rules:default_conflict_resolver(),
	{ok, Root, Report} =
		graphdb_instance:create_instance("car", Vehicle, 5, Conn, Conflict),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),
	?assertEqual(#{fired => 1, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% B5 plumbing: /3 (built-in default conflict resolver) is unchanged for a
%% plain single-rule fire.
%%-----------------------------------------------------------------------------
b5_default_resolver_single_rule_unchanged(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car", Vehicle, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),
	?assertEqual(1, length(Report)).
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_create_instance_5_accepts_resolvers
```
Expected: FAIL — `graphdb_instance:create_instance/5` and
`graphdb_rules:default_conflict_resolver/0` are undefined.

- [ ] **Step 3: Add `default_conflict_resolver/0` (identity) and export it in `graphdb_rules`**

In `graphdb_rules.erl`, add `default_conflict_resolver/0` and
`plan_composition_firing/3` to the `-export([...])` list. Add this function near
`plan_composition_firing/2` (around `graphdb_rules.erl:322`):

```erlang
%%-----------------------------------------------------------------------------
%% default_conflict_resolver() -> fun((ConflictContext) -> [Pair])
%%
%% The built-in B5 conflict resolver.  Called in the CALLER's process (e.g. from
%% graphdb_instance:create_instance/3,4), where seeded_nrefs/0 is safe.  Returns
%% ONE closure that bakes in the seed nrefs it needs and dispatches on the
%% context `kind'.  The closure is deadlock-safe in either the graphdb_rules or
%% graphdb_instance process: it touches only in-memory #node AVPs, the
%% relationships table (dirty), and graphdb_class (a different gen_server).
%%
%% ConflictContext :: #{kind := composition | connection,
%%                      rules := [Pair], class_nref := integer()}
%%   kind = composition -> Pair = {RuleNode, Deploy}
%%   kind = connection  -> Pair = {RuleNode, Deploy, ConnSpec}
%%
%% This identity stub is replaced by the real algorithm in Task 2/3/4.
%%-----------------------------------------------------------------------------
default_conflict_resolver() ->
	fun(#{rules := Rules}) -> Rules end.
```

- [ ] **Step 4: Add `plan_composition_firing/3` and thread `Resolver` through the plan internals**

Add the public arity beside `/2` (`graphdb_rules.erl:322`):

```erlang
%%-----------------------------------------------------------------------------
%% plan_composition_firing(Scope, ClassNref, ConflictResolver) ->
%%     {ok, PlanNode} | {error, Reason, #{plan_so_far, culprit}}
%%
%% As /2, but applies ConflictResolver to each cascade level's composition pairs
%% before planning.  /2 is preserved as the additive (unresolved) public read.
%%-----------------------------------------------------------------------------
plan_composition_firing(Scope, ClassNref, ConflictResolver) ->
	gen_server:call(?MODULE,
		{plan_composition_firing, Scope, ClassNref, ConflictResolver}).
```

Add the two matching `handle_call` clauses next to the existing
`plan_composition_firing` clauses (`graphdb_rules.erl:501-505`):

```erlang
handle_call({plan_composition_firing, environment, ClassNref, Resolver},
			_From, State) ->
	Reply = plan_node(ClassNref, root, undefined, undefined, [], State, Resolver),
	{reply, Reply, State};
handle_call({plan_composition_firing, {project, _}, ClassNref, _Resolver},
			_From, State) ->
	{reply, {ok, leaf_plan(ClassNref, root, undefined, undefined)}, State};
```

Keep the existing `/2` (3-tuple) clauses, but route them through an identity
resolver so there is a single planning path. Replace the existing environment
clause body (`graphdb_rules.erl:501-502`) with:

```erlang
handle_call({plan_composition_firing, environment, ClassNref}, _From, State) ->
	Identity = fun(#{rules := R}) -> R end,
	Reply = plan_node(ClassNref, root, undefined, undefined, [], State, Identity),
	{reply, Reply, State};
```

Thread `Resolver` through `plan_node`, `plan_rules`, `plan_mandatory`, and
`expand_children`. Replace `plan_node/6` (`graphdb_rules.erl:944-948`):

```erlang
plan_node(ClassNref, Rule, Deploy, Name, OnPath, State, Resolver) ->
	OnPath1 = [ClassNref | OnPath],
	CompRules0 = composition_pairs(ClassNref, State),
	CompRules = Resolver(#{kind => composition, rules => CompRules0,
						   class_nref => ClassNref}),
	plan_rules(CompRules, OnPath1, State, Resolver,
			   leaf_plan(ClassNref, Rule, Deploy, Name)).
```

Replace `plan_rules/4` (`graphdb_rules.erl:987-1007`) — add `Resolver` as the
4th argument (before `Acc`) and pass it through both the recursive calls and
`plan_mandatory`:

```erlang
plan_rules([], _OnPath1, _State, _Resolver, Acc) ->
	{ok, Acc};
plan_rules([{RuleNode, Deploy} | Rest], OnPath1, State, Resolver, Acc) ->
	case maps:get(mode, Deploy, undefined) of
		auto ->
			Autos = maps:get(auto_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Resolver,
					   Acc#{auto_rules => Autos});
		propose ->
			Proposes = maps:get(propose_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Resolver,
					   Acc#{propose_rules => Proposes});
		mandatory ->
			case plan_mandatory(RuleNode, Deploy, OnPath1, State, Resolver, Acc) of
				{ok, Acc1}          -> plan_rules(Rest, OnPath1, State, Resolver, Acc1);
				{error, _, _} = Err -> Err
			end;
		_ ->
			plan_rules(Rest, OnPath1, State, Resolver, Acc)
	end.
```

Replace `plan_mandatory/5` (`graphdb_rules.erl:1011-1030`) — add `Resolver`
(before `Acc`) and pass it to `expand_children`:

```erlang
plan_mandatory(RuleNode, Deploy, OnPath1, State, Resolver, Acc) ->
	ChildClass = content_avp_value(RuleNode,
								   State#state.child_class_nref_attr),
	case lists:member(ChildClass, OnPath1) of
		true ->
			{ok, Acc};
		false ->
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case graphdb_class:is_instantiable(ChildClass) of
				true ->
					expand_children(RuleNode, Deploy, ChildClass, Min, 1,
									OnPath1, State, Resolver, Acc);
				false ->
					fail({class_not_instantiable, ChildClass},
						 RuleNode, Acc);
				{error, Reason} ->
					fail({child_class_invalid, ChildClass, Reason},
						 RuleNode, Acc)
			end
	end.
```

Replace `expand_children/8` (`graphdb_rules.erl:1038-1053`) — add `Resolver`
(before `Acc`) and pass it to the recursive `plan_node`:

```erlang
expand_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _OnPath1, _State,
				_Resolver, Acc) when I > Mult ->
	{ok, Acc};
expand_children(RuleNode, Deploy, ChildClass, Mult, I, OnPath1, State, Resolver,
				Acc) ->
	Name = resolve_child_name(RuleNode, ChildClass, I, Mult, State),
	case plan_node(ChildClass, RuleNode, Deploy, Name, OnPath1, State, Resolver) of
		{ok, ChildPlan} ->
			Kids = maps:get(mandatory_children, Acc) ++ [ChildPlan],
			expand_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OnPath1,
							State, Resolver, Acc#{mandatory_children => Kids});
		{error, R, Failure} ->
			{error, R, Failure#{plan_so_far => Acc}}
	end.
```

- [ ] **Step 5: Add `create_instance/5`, carry the resolver in `Ctx`, apply it for connections**

In `graphdb_instance.erl`, add `create_instance/5` to `-export([...])`. Replace
the `create_instance/3` and `/4` clauses (`graphdb_instance.erl:184-198`):

```erlang
create_instance(Name, ClassNref, ParentNref) ->
	create_instance(Name, ClassNref, ParentNref, fun report_only/1).

create_instance(Name, ClassNref, ParentNref, ConnResolver)
		when is_function(ConnResolver, 1) ->
	create_instance(Name, ClassNref, ParentNref, ConnResolver,
					graphdb_rules:default_conflict_resolver()).

create_instance(Name, ClassNref, ParentNref, ConnResolver, ConflictResolver)
		when is_function(ConnResolver, 1), is_function(ConflictResolver, 1) ->
	gen_server:call(?MODULE,
		{create_instance, Name, ClassNref, ParentNref, ConnResolver,
		 ConflictResolver}).
```

Replace the `create_instance` `handle_call` clause (`graphdb_instance.erl:375-379`):

```erlang
handle_call({create_instance, Name, ClassNref, ParentNref, Resolver,
			 ConflictResolver}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	Ctx = #{inst_attr => InstAttr, on_path => [], resolver => Resolver,
			conflict_resolver => ConflictResolver,
			root_parent => ParentNref, root_source => undefined},
	{reply, do_create_instance(Name, ClassNref, ParentNref, Ctx), State};
```

In `fire_create/4`, change the plan call (`graphdb_instance.erl:498`) to thread
the resolver:

```erlang
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref,
											   maps:get(conflict_resolver, Ctx)) of
```

In `resolve_nodes/3`, apply the same resolver to the effective connection rules
before `resolve_rules`. Replace `graphdb_instance.erl:604-610`:

```erlang
resolve_nodes([{SourceNref, Class} | Rest], Ctx, Acc) ->
	{ok, ConnRules0} =
		graphdb_rules:effective_connection_rules(?RULE_SCOPE, Class),
	ConflictResolver = maps:get(conflict_resolver, Ctx),
	ConnRules = ConflictResolver(#{kind => connection, rules => ConnRules0,
								   class_nref => Class}),
	case resolve_rules(ConnRules, SourceNref, Ctx, Acc) of
		{ok, Acc1}          -> resolve_nodes(Rest, Ctx, Acc1);
		{error, _, _} = Err -> Err
	end.
```

- [ ] **Step 6: Run the new tests and the full graphdb suites to verify green**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_create_instance_5_accepts_resolvers
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_default_resolver_single_rule_unchanged
make test-ct-parallel FILTER=graphdb_instance FILTER=graphdb_rules
```
Expected: PASS; no regressions in either suite (identity resolver ⇒ no
behaviour change).

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/src/graphdb_instance.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "F4 B5 T1: thread conflict-resolver fun through firing path (identity default)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Default composition resolution — group, shadow, merge multiplicity

Replace the identity default with the real composition algorithm (B5-D1/D2/D3),
**losers always dropped** (template demotion arrives in Task 3; here all
fixtures use default templates, so dropping is correct). The connection clause
of `resolve_conflicts/4` is added as a pass-through so connections stay additive
until Task 4.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing tests (composition grouping/shadow/merge)**

Add to `apps/graphdb/test/graphdb_rules_SUITE.erl` and register them in `all/0`
(or the relevant group). These drive the default resolver directly so the
assertions are precise. Helper `make_class/1` exists
(`graphdb_rules_SUITE.erl:1372`); use `graphdb_class:create_class/2` for
subclasses.

```erlang
%%-----------------------------------------------------------------------------
%% Cross-level shadow: Car (nearest) and Vehicle (ancestor) both mandate Engine.
%% Resolved to ONE pair: nearest mode + nearest Min, greatest Max.
%%-----------------------------------------------------------------------------
b5_comp_cross_level_shadow(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 3}),
	{ok, [{_R, Dep}]} = resolve_comp(Car),
	?assertEqual(mandatory, maps:get(mode, Dep)),
	?assertEqual({1, 3}, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% Descendant shadow (B5-D1): Car mandates ElectricMotor (is-a Engine);
%% Vehicle mandates Engine.  ElectricMotor wins; Vehicle's Engine rule shadowed.
%%-----------------------------------------------------------------------------
b5_comp_descendant_shadow(_Config) ->
	{ok, Vehicle}  = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}      = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}   = graphdb_class:create_class("Engine", 3),
	{ok, EMotor}   = graphdb_class:create_class("ElectricMotor", Engine),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CEM", Car, EMotor, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	{ok, [{R, _Dep}]} = resolve_comp(Car),
	?assertEqual(EMotor, graphdb_rules:rule_child_class(R)).

%%-----------------------------------------------------------------------------
%% Additive: unrelated child classes both survive (two pairs).
%%-----------------------------------------------------------------------------
b5_comp_additive_unrelated(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, Radio}   = graphdb_class:create_class("Radio", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VR", Vehicle, Radio, mandatory, {1, 1}),
	{ok, Pairs} = resolve_comp(Car),
	?assertEqual(2, length(Pairs)).

%%-----------------------------------------------------------------------------
%% Greatest-Max merge across 3 levels including unbounded -> unbounded dominates.
%%-----------------------------------------------------------------------------
b5_comp_max_merge_unbounded(_Config) ->
	{ok, A}   = graphdb_class:create_class("A", 3),
	{ok, B}   = graphdb_class:create_class("B", A),
	{ok, C}   = graphdb_class:create_class("C", B),
	{ok, Eng} = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", C, Eng, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "BE", B, Eng, mandatory, {1, 2}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "AE", A, Eng, mandatory, {1, unbounded}),
	{ok, [{_R, Dep}]} = resolve_comp(C),
	?assertEqual({1, unbounded}, maps:get(multiplicity, Dep)).

%%-----------------------------------------------------------------------------
%% Same-level mode-priority tie (B5-D2): two rules on Cell, both child=Nucleus,
%% one mandatory one propose.  mandatory wins; one pair survives.
%%-----------------------------------------------------------------------------
b5_comp_same_level_mode_priority(_Config) ->
	{ok, Cell}    = graphdb_class:create_class("Cell", 3),
	{ok, Nucleus} = graphdb_class:create_class("Nucleus", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-prop", Cell, Nucleus, propose, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-mand", Cell, Nucleus, mandatory, {1, 1}),
	{ok, [{_R, Dep}]} = resolve_comp(Cell),
	?assertEqual(mandatory, maps:get(mode, Dep)).
```

Add a small test helper at the bottom of the suite (near the other helpers,
e.g. after `make_class/1`):

```erlang
%% resolve_comp(ClassNref) -> {ok, [{#node{}, Deploy}]}
%% Drives the default conflict resolver over the composition rules effective for
%% ClassNref, exactly as plan_node would.
resolve_comp(ClassNref) ->
	{ok, Effective} = graphdb_rules:effective_rules_for_class(environment,
															  ClassNref),
	Pairs = [P || {_Level, LvlPairs} <- Effective, P <- LvlPairs,
				  is_composition_pair(P)],
	Resolver = graphdb_rules:default_conflict_resolver(),
	{ok, Resolver(#{kind => composition, rules => Pairs, class_nref => ClassNref})}.

%% is_composition_pair({RuleNode, _Deploy}) -> boolean()
%% A pair is composition iff its rule node is a CompositionRule instance.
is_composition_pair({#node{classes = Classes}, _Deploy}) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	lists:member(maps:get(composition_rule, S), Classes).
```

(The suite already includes the `#node` record via its module's record
definitions and `graphdb/include/graphdb_nrefs.hrl`. `effective_rules_for_class/2`
returns the additive, level-grouped list — the same input `plan_node` resolves.)

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case b5_comp_cross_level_shadow
```
Expected: FAIL — the identity resolver returns both pairs, so the
`{ok, [{_R, Dep}]}` single-element match fails.

- [ ] **Step 3: Replace `default_conflict_resolver/0` with the seed-baking closure**

In `graphdb_rules.erl`, replace the identity body from Task 1:

```erlang
default_conflict_resolver() ->
	{ok, Seeds} = seeded_nrefs(),
	ChildAttr = maps:get(child_class_nref_attr, Seeds),
	TplAttr   = maps:get(template_nref_attr, Seeds),
	AppliedBy = maps:get(applied_by, Seeds),
	fun(Ctx) -> resolve_conflicts(Ctx, ChildAttr, TplAttr, AppliedBy) end.
```

- [ ] **Step 4: Add the resolver algorithm (composition clause + shared helpers)**

Add to `graphdb_rules.erl` (a new private section near the plan path). The
connection clause is a pass-through here; Task 4 replaces it. `comp_item`'s
`real_tpl` is `false` here (templates considered in Task 3) so every loser is
dropped.

```erlang
%%---------------------------------------------------------------------
%% B5 conflict resolution (default resolver body)
%%---------------------------------------------------------------------
%% resolve_conflicts(Ctx, ChildAttr, TplAttr, AppliedBy) -> [Pair]
%% Ctx = #{kind, rules, class_nref}.  Pure over the seed nrefs + graphdb_class +
%% the relationships table; no graphdb_rules gen_server call (deadlock-safe in
%% either process).

resolve_conflicts(#{kind := composition, rules := Pairs}, ChildAttr, TplAttr,
				  AppliedBy) ->
	Items = [comp_item(P, ChildAttr, TplAttr, AppliedBy) || P <- Pairs],
	Groups = assign_groups(Items, composition),
	lists:flatmap(fun(G) -> resolve_group(G, composition) end, Groups);
resolve_conflicts(#{kind := connection, rules := Specs}, _ChildAttr, _TplAttr,
				  _AppliedBy) ->
	%% Additive pass-through until Task 4 implements connection resolution.
	Specs.

%% comp_item({RuleNode, Deploy}, ChildAttr, TplAttr, AppliedBy) -> item()
%% item() = #{pair, ref, char, mode, min, max, owner, real_tpl}
comp_item({RuleNode, Deploy} = Pair, ChildAttr, _TplAttr, AppliedBy) ->
	{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	#{pair  => Pair,
	  ref   => content_avp_value(RuleNode, ChildAttr),
	  char  => undefined,
	  mode  => maps:get(mode, Deploy, mandatory),
	  min   => Min,
	  max   => Max,
	  owner => owning_class(RuleNode, AppliedBy),
	  real_tpl => false}.

%% owning_class(RuleNode, AppliedBy) -> integer() | undefined
%% Re-derives the rule's owning class from its applied_by arc (source=Rule,
%% char=applied_by -> target=owning class).  See do_create_rule/7.
owning_class(#node{nref = RuleNref}, AppliedBy) ->
	Arcs = mnesia:dirty_index_read(relationships, RuleNref,
								   #relationship.source_nref),
	case [A#relationship.target_nref || A <- Arcs,
		  A#relationship.characterization =:= AppliedBy] of
		[Owner | _] -> Owner;
		[]          -> undefined
	end.

%% assign_groups(Items, Kind) -> [[item()]]
%% Walks nearest-first; each item joins the first group whose head (anchor =
%% nearest member) it matches, else starts a new group.  Groups preserve
%% nearest-first member order; group list preserves creation order.
assign_groups(Items, Kind) ->
	lists:foldl(fun(Item, Groups) ->
		case find_group(Item, Groups, Kind, 1) of
			{Idx, _G} -> append_to_group(Idx, Item, Groups);
			none      -> Groups ++ [[Item]]
		end
	end, [], Items).

find_group(_Item, [], _Kind, _Idx) ->
	none;
find_group(Item, [G | Rest], Kind, Idx) ->
	case same_conflict(Kind, hd(G), Item) of
		true  -> {Idx, G};
		false -> find_group(Item, Rest, Kind, Idx + 1)
	end.

append_to_group(Idx, Item, Groups) ->
	{Before, [G | After]} = lists:split(Idx - 1, Groups),
	Before ++ [G ++ [Item]] ++ After.

%% same_conflict(Kind, Anchor, Item) -> boolean()
%% The anchor (nearest member) must be same-or-descendant of the candidate.
%% class_in_ancestry(FartherRef, NearerRef): ANCESTOR first, DESCENDANT second
%% (arg-order hazard -- B4 has a canary for the same call).  FartherRef =
%% candidate's ref, NearerRef = anchor's ref.
same_conflict(composition, Anchor, Item) ->
	graphdb_class:class_in_ancestry(maps:get(ref, Item), maps:get(ref, Anchor));
same_conflict(connection, Anchor, Item) ->
	maps:get(char, Anchor) =:= maps:get(char, Item)
		andalso graphdb_class:class_in_ancestry(maps:get(ref, Item),
												maps:get(ref, Anchor)).

%% resolve_group(Group, Kind) -> [Pair]
%% Winner = highest mode-priority among the nearest-level prefix; losers are
%% dropped (their Max merges) unless both winner and loser are real-templated,
%% in which case the loser is re-emitted as an independent propose (B5-D4).
resolve_group(Group, Kind) ->
	OwnerHd = maps:get(owner, hd(Group)),
	NearestLevel = lists:takewhile(
		fun(I) -> maps:get(owner, I) =:= OwnerHd end, Group),
	Winner = pick_winner(NearestLevel),
	Losers = Group -- [Winner],
	{Demoted, Dropped} = lists:partition(
		fun(L) -> maps:get(real_tpl, Winner) andalso maps:get(real_tpl, L) end,
		Losers),
	MergedMax = lists:foldl(
		fun(I, Acc) -> merge_max(Acc, maps:get(max, I)) end,
		maps:get(max, Winner), Dropped),
	WinnerOut = rebuild(Winner, Kind, {maps:get(min, Winner), MergedMax},
						keep_mode),
	DemotedOuts = [ rebuild(D, Kind, {maps:get(min, D), maps:get(max, D)},
							propose) || D <- Demoted ],
	[WinnerOut | DemotedOuts].

%% pick_winner([item()]) -> item()
%% Highest mode priority; ties keep the earliest (arc order).
pick_winner([H | T]) ->
	lists:foldl(fun(C, Best) ->
		case priority(maps:get(mode, C)) > priority(maps:get(mode, Best)) of
			true  -> C;
			false -> Best
		end
	end, H, T).

priority(mandatory) -> 3;
priority(auto)      -> 2;
priority(propose)   -> 1;
priority(_)         -> 0.

%% merge_max(MaxA, MaxB) -> Max  (unbounded dominates)
merge_max(unbounded, _) -> unbounded;
merge_max(_, unbounded) -> unbounded;
merge_max(A, B)         -> max(A, B).

%% rebuild(item(), Kind, {Min, Max}, keep_mode | propose) -> Pair
rebuild(Item, composition, Mult, ModeSpec) ->
	{RuleNode, Deploy} = maps:get(pair, Item),
	{RuleNode, set_mode(Deploy#{multiplicity => Mult}, ModeSpec)};
rebuild(Item, connection, Mult, ModeSpec) ->
	{Rule, Deploy, Spec} = maps:get(pair, Item),
	{Rule, set_mode(Deploy#{multiplicity => Mult}, ModeSpec), Spec}.

set_mode(Deploy, keep_mode) -> Deploy;
set_mode(Deploy, propose)   -> Deploy#{mode => propose}.
```

- [ ] **Step 5: Run the new tests and the full graphdb suites**

Run:
```
make test-ct-parallel FILTER=graphdb_rules FILTER=graphdb_instance
```
Expected: PASS — all five `b5_comp_*` cases plus the Task 1 cases and every
pre-existing case. (The Task 1 connection-firing paths still see the additive
pass-through, so connection tests are unchanged.)

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B5 T2: default composition resolution (group, shadow, merge)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Composition template demotion (B5-D4/D5)

Make `comp_item` compute `real_tpl` properly so a loser is demoted to `propose`
(keeping its own range) when **both** the winner and that loser carry a real
(non-default) template; a mixed pair still drops the loser.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing tests (both-real demote; mixed drop)**

To create a real template, pass an explicit `TemplateNref` to
`create_composition_rule/7` that differs from the owning class's default
template. `graphdb_class:default_template/1` returns `{ok, DT}`; use a *second*
class's default template as the "non-default" template for the rule (any
template nref ≠ the owning class's default counts as real per B5-D5).

```erlang
%%-----------------------------------------------------------------------------
%% Both-real-template demote (B5-D4): Car@tplA auto Engine; Vehicle@tplB
%% mandatory Engine.  Winner = Car's auto Engine (fires); loser re-emitted as
%% an independent propose keeping its own {1,2} range.
%%-----------------------------------------------------------------------------
b5_comp_both_real_template_demote(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	%% real (non-default) templates: borrow other classes' default templates
	{ok, TplA} = graphdb_class:default_template(Engine),
	{ok, TplB} = graphdb_class:default_template(Vehicle),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, auto, {1, 1}, TplA),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 2}, TplB),
	{ok, Pairs} = resolve_comp(Car),
	?assertEqual(2, length(Pairs)),
	Modes = [maps:get(mode, D) || {_R, D} <- Pairs],
	?assertEqual([auto, propose], Modes),
	%% the demoted propose keeps its OWN {1,2}, not merged
	[{_, _}, {_, PropDep}] = Pairs,
	?assertEqual({1, 2}, maps:get(multiplicity, PropDep)).

%%-----------------------------------------------------------------------------
%% Mixed template drop (B5-D4): only the nearest carries a real template; the
%% ancestor uses its default.  Loser dropped, greatest-Max merged, no propose.
%%-----------------------------------------------------------------------------
b5_comp_mixed_template_drop(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, TplA}    = graphdb_class:default_template(Engine),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, auto, {1, 1}, TplA),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 2}),  %% default tpl
	{ok, [{_R, Dep}]} = resolve_comp(Car),
	?assertEqual(auto, maps:get(mode, Dep)),
	?assertEqual({1, 2}, maps:get(multiplicity, Dep)).   %% greatest Max merged
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case b5_comp_both_real_template_demote
```
Expected: FAIL — `real_tpl` is hard-coded `false`, so the loser is dropped
instead of demoted (one pair, not two).

- [ ] **Step 3: Compute `real_tpl` in `comp_item`; add `real_template/3`**

In `graphdb_rules.erl`, replace `comp_item/4` so it passes `TplAttr` and the
owner into the template check:

```erlang
comp_item({RuleNode, Deploy} = Pair, ChildAttr, TplAttr, AppliedBy) ->
	{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	Owner = owning_class(RuleNode, AppliedBy),
	#{pair  => Pair,
	  ref   => content_avp_value(RuleNode, ChildAttr),
	  char  => undefined,
	  mode  => maps:get(mode, Deploy, mandatory),
	  min   => Min,
	  max   => Max,
	  owner => Owner,
	  real_tpl => real_template(RuleNode, TplAttr, Owner)}.
```

Add `real_template/3` in the B5 section:

```erlang
%% real_template(RuleNode, TplAttr, OwningClass) -> boolean()
%% True iff the rule carries a content template_nref AVP whose value differs from
%% its owning class's default template (B5-D5).  Absent template_nref -> false.
real_template(RuleNode, TplAttr, OwningClass) ->
	case content_avp_value(RuleNode, TplAttr) of
		undefined ->
			false;
		TplNref ->
			case graphdb_class:default_template(OwningClass) of
				{ok, Default} -> TplNref =/= Default;
				_             -> true
			end
	end.
```

- [ ] **Step 4: Run the new tests and the rules suite**

Run:
```
make test-ct-parallel FILTER=graphdb_rules
```
Expected: PASS — both new cases plus all Task 2 cases (default-template fixtures
still drop their losers because `real_template/3` returns `false` for them).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B5 T3: composition template demotion to propose (B5-D4/D5)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Default connection resolution (B5-D1 connection + same disposition)

Replace the connection pass-through with the real algorithm: group by
`characterization` + descendant `target_class`, shadow / merge / demote exactly
like composition (the shared `resolve_group`/grouping helpers already handle
both kinds).

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing tests (connection target shadow; additive)**

Helper `make_rel_pair/2` exists (`graphdb_rules_SUITE.erl:1401`) and returns
`{Char, Recip}`.

```erlang
%%-----------------------------------------------------------------------------
%% Connection target shadow (B5-D1): Car owns Garage (is-a Building); Vehicle
%% owns Building, same `owns' characterization.  One winner -> Garage.
%%-----------------------------------------------------------------------------
b5_conn_target_shadow(_Config) ->
	{ok, Vehicle}  = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}      = graphdb_class:create_class("Car", Vehicle),
	{ok, Building} = graphdb_class:create_class("Building", 3),
	{ok, Garage}   = graphdb_class:create_class("Garage", Building),
	{Owns, Owned}  = make_rel_pair("owns", "owned_by"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CG", Car, Owns, Owned, Garage, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "VB", Vehicle, Owns, Owned, Building, mandatory, {1, 1}),
	{ok, [{_R, _Dep, Spec}]} = resolve_conn(Car),
	?assertEqual(Garage, maps:get(target_class, Spec)).

%%-----------------------------------------------------------------------------
%% Connection additive (unrelated targets, same characterization): both survive.
%%-----------------------------------------------------------------------------
b5_conn_additive_unrelated(_Config) ->
	{ok, Vehicle}  = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}      = graphdb_class:create_class("Car", Vehicle),
	{ok, Building} = graphdb_class:create_class("Building", 3),
	{ok, Boat}     = graphdb_class:create_class("Boat", 3),
	{Owns, Owned}  = make_rel_pair("owns", "owned_by"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CB", Car, Owns, Owned, Boat, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "VB", Vehicle, Owns, Owned, Building, mandatory, {1, 1}),
	{ok, Pairs} = resolve_conn(Car),
	?assertEqual(2, length(Pairs)).
```

Add a `resolve_conn/1` helper alongside `resolve_comp/1`:

```erlang
%% resolve_conn(ClassNref) -> {ok, [{#node{}, Deploy, Spec}]}
resolve_conn(ClassNref) ->
	{ok, Specs} = graphdb_rules:effective_connection_rules(environment, ClassNref),
	Resolver = graphdb_rules:default_conflict_resolver(),
	{ok, Resolver(#{kind => connection, rules => Specs, class_nref => ClassNref})}.
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case b5_conn_target_shadow
```
Expected: FAIL — the connection clause is still the additive pass-through, so
both rules survive (two pairs, not one).

- [ ] **Step 3: Implement the connection clause + `conn_item/3`**

In `graphdb_rules.erl`, replace the connection clause of `resolve_conflicts/4`:

```erlang
resolve_conflicts(#{kind := connection, rules := Specs}, _ChildAttr, TplAttr,
				  AppliedBy) ->
	Items = [conn_item(S, TplAttr, AppliedBy) || S <- Specs],
	Groups = assign_groups(Items, connection),
	lists:flatmap(fun(G) -> resolve_group(G, connection) end, Groups);
```

(Keep the composition clause unchanged above it.) Add `conn_item/3`:

```erlang
%% conn_item({Rule, Deploy, Spec}, TplAttr, AppliedBy) -> item()
%% target_class and characterization come from the connection Spec (no child
%% attr needed); real_tpl re-derives the owning (source) class via applied_by.
conn_item({Rule, Deploy, Spec} = Pair, TplAttr, AppliedBy) ->
	{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	Owner = owning_class(Rule, AppliedBy),
	#{pair  => Pair,
	  ref   => maps:get(target_class, Spec),
	  char  => maps:get(characterization, Spec),
	  mode  => maps:get(mode, Deploy, mandatory),
	  min   => Min,
	  max   => Max,
	  owner => Owner,
	  real_tpl => real_template(Rule, TplAttr, Owner)}.
```

- [ ] **Step 4: Run the new tests and the full graphdb suites**

Run:
```
make test-ct-parallel FILTER=graphdb_rules FILTER=graphdb_instance
```
Expected: PASS — connection grouping resolves; the B4 connection-firing instance
tests still pass (a single connection rule per class is a group of one →
unchanged; multi-rule conflicts now resolve).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B5 T4: default connection resolution (B5-D1 connection)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: End-to-end firing proofs, custom-resolver override, and docs

Prove resolution end-to-end through `create_instance` (the Cell/Nucleus firing
flip and a demote-surfaces-as-proposed case), prove the seam is overridable with
a custom resolver, and update the docs.

**Files:**
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Modify: `apps/graphdb/CLAUDE.md`; `docs/Architecture.md` (only the
  `create_instance` contract line, if present)

- [ ] **Step 1: Write the failing firing + override tests**

Add to `apps/graphdb/test/graphdb_instance_SUITE.erl` and register in `all/0`.

```erlang
%%-----------------------------------------------------------------------------
%% Firing flip (B5-D2 at firing time): Cell mandates Nucleus (mandatory) and
%% proposes Nucleus.  Under B5 only ONE Nucleus is minted (mandatory wins).
%%-----------------------------------------------------------------------------
b5_firing_same_level_mode_priority(_Config) ->
	{ok, Cell}    = graphdb_class:create_class("Cell", 3),
	{ok, Nucleus} = graphdb_class:create_class("Nucleus", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-prop", Cell, Nucleus, propose, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CN-mand", Cell, Nucleus, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("c1", Cell, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)),                 %% exactly one Nucleus minted
	#{fired := 1, proposed := 0} =
		maps:with([fired, proposed], graphdb_instance:summarize(Report)).

%%-----------------------------------------------------------------------------
%% Cross-level shadow at firing time: Car + Vehicle both mandate Engine -> one
%% Engine minted (not two).
%%-----------------------------------------------------------------------------
b5_firing_cross_level_shadow(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	{ok, Root, _Report} = graphdb_instance:create_instance("car", Car, 5),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(1, length(Kids)).

%%-----------------------------------------------------------------------------
%% Custom resolver overrides the seam: a pure-additive resolver makes Car +
%% Vehicle both fire (two Engines), proving the policy is caller-overridable.
%%-----------------------------------------------------------------------------
b5_custom_resolver_pure_additive(_Config) ->
	{ok, Vehicle} = graphdb_class:create_class("Vehicle", 3),
	{ok, Car}     = graphdb_class:create_class("Car", Vehicle),
	{ok, Engine}  = graphdb_class:create_class("Engine", 3),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CE", Car, Engine, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "VE", Vehicle, Engine, mandatory, {1, 1}),
	Additive = fun(#{rules := R}) -> R end,
	Conn     = fun(_Ctx) -> defer end,
	{ok, Root, _Report} =
		graphdb_instance:create_instance("car", Car, 5, Conn, Additive),
	{ok, Kids} = graphdb_instance:children(Root),
	?assertEqual(2, length(Kids)).                 %% additive: both fire
```

- [ ] **Step 2: Run the tests to verify they pass (resolution already implemented)**

Run:
```
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_firing_same_level_mode_priority
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_firing_cross_level_shadow
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case b5_custom_resolver_pure_additive
```
Expected: PASS — Tasks 2–4 implemented the resolution; these are end-to-end
confirmations through `create_instance` plus the override seam.

(If any fail, the defect is in Tasks 2–4's wiring, not in new production code —
fix there and re-run.)

- [ ] **Step 3: Update docs**

In `apps/graphdb/CLAUDE.md`, in the `graphdb_instance` API bullet, note the new
arity and the conflict resolver, e.g. extend the `create_instance` line:

```
- `create_instance/3,4,5` (name, class_nref, compositional_parent_nref
  [, connection_resolver [, conflict_resolver]]) — ... `/5` threads a B5
  **conflict resolver** (`fun((#{kind, rules, class_nref}) -> [Pair])`); `/3`
  and `/4` inject the built-in `graphdb_rules:default_conflict_resolver/0`,
  which shadows conflicting inherited rules, merges multiplicity (nearest Min,
  greatest Max), and demotes both-real-template losers to `propose` (F4 B5).
```

In the `graphdb_rules` section of `apps/graphdb/CLAUDE.md`, add a bullet for
`default_conflict_resolver/0` and `plan_composition_firing/3`, and update the
phase status line from `...+ B4` to `...+ B4 + B5`. Do the same to the file
header table row for `graphdb_rules.erl` and the "NYI Status" / "Remaining Work"
paragraphs (drop "Phase B5 (precedence)" from outstanding; leave Phases C–F).

In the project root `CLAUDE.md` "Known Incomplete Areas" bullet for
`graphdb_rules`, move "conflict precedence" from outstanding to implemented.

`docs/Architecture.md`: update only if it states the `create_instance` arity or
the rules-engine phase status; B5 adds no schema/supervision change, so most of
it is untouched. `docs/diagrams/ontology-tree.md`: **no change** (B5 seeds
nothing).

- [ ] **Step 4: Run the full test suite (both suites + the whole project)**

Run:
```
make test-ct-parallel
./rebar3 eunit
```
Expected: every CT suite and all EUnit tests green; clean compile, zero
warnings.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/CLAUDE.md \
        CLAUDE.md docs/Architecture.md
git commit -m "F4 B5 T5: end-to-end firing proofs, custom-resolver override, docs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review (run after the plan is written, before execution)

- **Spec coverage:**
  - B5-D1 grouping/descendant match — T2 (composition), T4 (connection).
  - B5-D2 nearest winner + mode-priority tie — T2 (`b5_comp_*`), T5 (`b5_firing_same_level_mode_priority`).
  - B5-D3 nearest-Min/greatest-Max — T2 (`b5_comp_max_merge_unbounded`).
  - B5-D4/D5 demote vs drop, real-template — T3.
  - B5-D6 resolver owned by instance, threaded as `/5`, default in rules,
    applied per cascade level (composition) and per node (connection) — T1.
  - B5-D7 integration-free (demoted entries flow through B3/B4 propose) — proven
    by T5 firing (proposed outcomes surface via existing machinery).
  - §6 worked examples — every row has a test (cross-level, descendant,
    additive, max-merge-unbounded, same-level tie, both-real demote, mixed drop,
    connection target shadow, connection additive, custom override).
  - §1.3 B1 contract preserved — `/2` routed through an identity resolver; no
    `effective_rules_for_class/2` change.

- **Edge cases (§5):** "matches two unrelated winners → joins only the nearest"
  is enforced by `find_group` returning the *first* matching group. "Bad/unknown
  nref" is unchanged (`effective_rules` returns `[]` → empty resolver input →
  `[]`). Custom-resolver malformed output is out of scope (caller owns it).

- **Type/name consistency:** the item map keys (`pair, ref, char, mode, min,
  max, owner, real_tpl`) are produced by `comp_item`/`conn_item` and consumed by
  `assign_groups`/`resolve_group`/`pick_winner`/`merge_max`/`rebuild`
  identically. `rebuild` reconstructs the exact `{RuleNode, Deploy}` /
  `{Rule, Deploy, Spec}` shapes the consumers expect. `default_conflict_resolver/0`
  closure shape matches both apply points
  (`#{kind, rules, class_nref}` → `[Pair]`).

- **Deadlock check:** the default resolver closure calls only `graphdb_class`
  (different gen_server) and Mnesia dirty reads — never the `graphdb_rules`
  gen_server. Safe in both the rules process (composition) and the instance
  process (connection).
