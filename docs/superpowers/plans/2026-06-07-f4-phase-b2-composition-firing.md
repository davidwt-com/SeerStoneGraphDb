<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B2 — Composition Firing Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `graphdb_instance:create_instance/3` fire composition rules — materialising `mandatory` children atomically with the root and `auto` children best-effort post-commit — and return a rule-centric `Report` on both success and failure.

**Architecture:** Three phases inside the `graphdb_instance` process. **PLAN** is a pure read in `graphdb_rules` (`plan_composition_firing/2`) returning an abstract map plan tree (no nrefs). **EXECUTE** allocates nrefs and writes the root + entire mandatory subtree in one Mnesia transaction. **POST-COMMIT** fires `auto` rules by recursing the internal `do_create_instance/5` (never the gen_server API — that would deadlock). The cascade recursion threads an on-path class set for a zero-level vertical-cycle cut. The report is a list of `#{rule, deployment, outcomes}`, carried on `{ok, Nref, Report}` and `{error, Reason, Report}`.

**Tech Stack:** Erlang/OTP 28, Mnesia (`disc_copies`, dirty reads), Common Test, EUnit, rebar3. Invoke the build as plain `./rebar3 …` (kerl PATH is preconfigured — no `source ~/.bashrc` prefix).

**Design spec:** `docs/designs/f4-phase-b2-composition-firing-design.md` (B2-D1 … B2-D9). Parent: `docs/designs/f4-graphdb-rules-design.md`. Consumes B1 `effective_rules_for_class/2` (`docs/designs/f4-phase-b1-effective-rules-design.md`).

---

## File Structure

| File                                                                                                            | Responsibility in B2                                                                                                                                                                         |
| --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`                                                                            | Seed `name_pattern` (init/state/`seeded_nrefs`); `create_composition_rule/8` options arity + `optional_name_pattern_avp/2`; `plan_composition_firing/2` + planner helpers (pure read)        |
| `apps/graphdb/src/graphdb_instance.erl`                                                                         | `do_create_instance/5` (internal recursion), `execute/5`, `fire_auto/2`, report helpers (`add_outcome`/`merge_reports`/`report_not_attempted`/`summarize/1`); `create_instance/3` → 3-tuples |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`                                                                     | New CT group `plan_firing` (name_pattern seed, `/8` arity, plan tree, cycle guard, failure diagnostic)                                                                                       |
| `apps/graphdb/test/graphdb_instance_tests.erl`                                                                  | EUnit for the pure report helpers                                                                                                                                                            |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`                                                                  | New CT group `firing` (mandatory, auto, cascade, report); migrate existing `{ok, X}` assertions                                                                                              |
| `apps/graphdb/test/graphdb_query_SUITE.erl`                                                                     | Migrate `{ok, X}` create_instance assertions to `{ok, X, _}`                                                                                                                                 |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`                                                                       | Migrate `{ok, X}` create_instance assertions to `{ok, X, _}`                                                                                                                                 |
| `docs/diagrams/ontology-tree.md`                                                                                | Add `name_pattern` to the Rule Literals sub-group                                                                                                                                            |
| `apps/graphdb/CLAUDE.md`, `ARCHITECTURE.md`, `README.md`, `TASKS.md`, `docs/designs/f4-graphdb-rules-design.md` | API contract, return-shape change, test counts, B2 status, OI marks                                                                                                                          |

---

## Task 1: Seed `name_pattern` rule literal in `graphdb_rules`

`name_pattern` is the optional naming-template attribute for composition rules
(B2-D7/D8). It is seeded exactly like its six Phase-A siblings, via the
existing `ensure_seed/2`, and surfaced through `seeded_nrefs/0`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (the `#state{}` record ~120-133; `init/1` ~270-305; `seeded_nrefs` handler ~316-330)
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing test**

In `apps/graphdb/test/graphdb_rules_SUITE.erl`, add to the exported test list and
a suitable group a case (follow the suite's existing `init_per_suite` start of
the graphdb stack):

```erlang
name_pattern_is_seeded(_Config) ->
    {ok, Seeds} = graphdb_rules:seeded_nrefs(),
    ?assert(maps:is_key(name_pattern, Seeds)),
    NP = maps:get(name_pattern, Seeds),
    ?assert(is_integer(NP)),
    %% it lives under the Rule Literals group
    RuleLit = maps:get(rule_literals_group, Seeds),
    {ok, NP} = graphdb_attr:find_attribute_by_name(RuleLit, "name_pattern").
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case name_pattern_is_seeded`
Expected: FAIL — `seeded_nrefs` has no `name_pattern` key (`maps:is_key` is false).

- [ ] **Step 3: Add the state field**

In the `-record(state, {...})` add a field after `multiplicity_attr`:

```erlang
	multiplicity_attr,
	name_pattern_attr
```

- [ ] **Step 4: Seed it in `init/1`**

In `init/1`, after the `MultAttr = ensure_seed("multiplicity", RuleLitGrp),` line add:

```erlang
		NamePatternAttr= ensure_seed("name_pattern",          RuleLitGrp),
```

and add the field to the returned `#state{...}` (after `multiplicity_attr = MultAttr`):

```erlang
				multiplicity_attr          = MultAttr,
				name_pattern_attr          = NamePatternAttr
```

(The `retro_stamp_attribute_types/0` call already at the end of `init/1` covers
the new attribute — no extra work.)

- [ ] **Step 5: Expose it in `seeded_nrefs`**

In the `handle_call(seeded_nrefs, ...)` reply map add (after `multiplicity_attr`):

```erlang
			multiplicity_attr          => State#state.multiplicity_attr,
			name_pattern_attr          => State#state.multiplicity_attr,  %% placeholder — fix next line
```

then correct it to the real field (this two-line form avoids a stale copy bug):

```erlang
			name_pattern               => State#state.name_pattern_attr
```

So the final two map entries read:

```erlang
			multiplicity_attr          => State#state.multiplicity_attr,
			name_pattern               => State#state.name_pattern_attr
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case name_pattern_is_seeded`
Expected: PASS.

- [ ] **Step 7: Verify idempotency (full suite)**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS — seeding twice across suite restarts does not duplicate (find-first in `ensure_seed`).

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B2: seed name_pattern rule literal in graphdb_rules"
```

---

## Task 2: `create_composition_rule/8` options arity (`name_pattern` content AVP)

Add an options-map arity so callers can attach a `name_pattern` to a composition
rule. `/6` and `/7` delegate in with `Opts = #{}`; the new content AVP is added
to the rule node beside `child_class_nref`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (export list ~89-102; API wrappers ~165-173; `create_composition_rule` handler ~331-344; helpers ~690-694)
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Write the failing test**

```erlang
composition_rule_carries_name_pattern(Config) ->
    %% Two classes with default templates already exist via init_per_testcase
    %% helpers (Owner, Child); see suite's class fixtures.
    {Owner, Child} = ?config(rule_classes, Config),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "PatRule", Owner, Child, mandatory, 2, undefined,
        #{name_pattern => "Bolt {i}"}),
    {ok, #node{attribute_value_pairs = AVPs}} =
        graphdb_rules:get_rule(environment, RuleNref),
    {ok, Seeds} = graphdb_rules:seeded_nrefs(),
    NP = maps:get(name_pattern, Seeds),
    ?assertEqual({ok, "Bolt {i}"}, find_avp(AVPs, NP)).
```

(Use the suite's existing class fixtures; if none expose `{Owner, Child}` with
default templates, create them in `init_per_testcase` with
`graphdb_class:create_class/2` — a class created via `/2` gets a default
template, satisfying `validate_owning_class`. `find_avp/2` is the suite's local
AVP reader; add one if absent:
`find_avp(AVPs, A) -> case lists:search(fun(#{attribute := X}) -> X =:= A end, AVPs) of {value, #{value := V}} -> {ok, V}; false -> not_found end.`)

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case composition_rule_carries_name_pattern`
Expected: FAIL — `create_composition_rule/8` is undefined (`undef`).

- [ ] **Step 3: Add the export and API wrappers**

In the export list add `create_composition_rule/8`:

```erlang
		create_composition_rule/6,
		create_composition_rule/7,
		create_composition_rule/8,
```

Replace the two existing wrappers with three that delegate down to `/8`:

```erlang
create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult) ->
	create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
							undefined, #{}).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
						TemplateNref) ->
	create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
							TemplateNref, #{}).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
						TemplateNref, Opts) when is_map(Opts) ->
	gen_server:call(?MODULE,
		{create_composition_rule, Scope, Name, ParentClass, ChildClass,
		 Mode, Mult, TemplateNref, Opts}).
```

- [ ] **Step 4: Thread `Opts` through the handler**

Replace the environment `create_composition_rule` handler with an 8-element
message form that appends the name_pattern content AVP:

```erlang
handle_call({create_composition_rule, environment, Name, ParentClass,
			 ChildClass, Mode, Mult, TemplateNref, Opts}, _From, State) ->
	Reply = case validate_composition(ParentClass, ChildClass, Mode, Mult,
									  TemplateNref) of
		ok ->
			ContentAVPs = [#{attribute => State#state.child_class_nref_attr,
							 value => ChildClass}]
						  ++ optional_template_avp(TemplateNref, State)
						  ++ optional_name_pattern_avp(Opts, State),
			do_create_rule(State#state.composition_rule_nref, Name,
				ParentClass, ContentAVPs, Mode, Mult, State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_composition_rule, {project, _}, _, _, _, _, _, _, _},
			_From, State) ->
	{reply, {error, project_rules_not_yet_supported}, State};
```

- [ ] **Step 5: Add the helper**

After `optional_template_avp/2` add:

```erlang
%% optional_name_pattern_avp(Opts, State) -> [AVP] | []
%% The optional name_pattern content AVP on the rule node (B2-D7).
optional_name_pattern_avp(Opts, State) ->
	case maps:get(name_pattern, Opts, undefined) of
		undefined -> [];
		Pattern   -> [#{attribute => State#state.name_pattern_attr,
						value => Pattern}]
	end.
```

- [ ] **Step 6: Run the new test + the full rules suite**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS — new case green; `/6` and `/7` callers unaffected (they pass `#{}`).

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B2: create_composition_rule/8 options arity with name_pattern"
```

---

## Task 3: `plan_composition_firing/2` — abstract plan tree (pure read)

The planner walks the **mandatory** cascade recursively, threads the on-path
cycle guard (zero-level cut), resolves child names, annotates `auto` rules per
node, and returns `{ok, PlanTree}` or `{error, Reason, Failure}` with a partial
plan. It runs entirely in `graphdb_rules` (pure read; no nrefs, no writes).

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (export list; one API wrapper; two handler clauses; new "Plan path" helper section)
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl` (new `plan_firing` group)

- [ ] **Step 1: Write failing tests (representative set)**

Add a `plan_firing` CT group. Fixtures (in `init_per_testcase` for the group):
create classes `Owner`, `Bolt`, `Widget` via `graphdb_class:create_class/2`
(each gets a default template); make `Abstract` via
`graphdb_class:create_class/3` with `[#{attribute => InstAttr, value => false}]`
where `InstAttr = maps:get(instantiable, element(2, graphdb_attr:seeded_nrefs()))`.

```erlang
plan_single_mandatory(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _R} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 2),
    {ok, Plan} = graphdb_rules:plan_composition_firing(environment, Owner),
    #{class := Owner, mandatory_children := Kids, auto_rules := []} = Plan,
    ?assertEqual(2, length(Kids)),
    [#{class := Bolt, name := N1}, #{class := Bolt, name := N2}] = Kids,
    ?assertEqual("Bolt 1", N1),                      %% fallback, mult>1
    ?assertEqual("Bolt 2", N2).

plan_name_pattern(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 2, undefined,
        #{name_pattern => "Pin {i}"}),
    {ok, #{mandatory_children := [#{name := "Pin 1"}, #{name := "Pin 2"}]}} =
        graphdb_rules:plan_composition_firing(environment, Owner).

plan_mult_one_singular_name(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 1),
    {ok, #{mandatory_children := [#{name := "Bolt"}]}} =       %% no index suffix
        graphdb_rules:plan_composition_firing(environment, Owner).

plan_auto_annotated_not_expanded(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, auto, 1),
    {ok, #{mandatory_children := [], auto_rules := [{_RuleNode, Dep}]}} =
        graphdb_rules:plan_composition_firing(environment, Owner),
    ?assertEqual(auto, maps:get(mode, Dep)).

plan_unbounded_mandatory_fails(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, R} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, unbounded),
    {error, {unbounded_multiplicity_not_fireable, R},
     #{plan_so_far := #{class := Owner}, culprit := #node{nref = R}}} =
        graphdb_rules:plan_composition_firing(environment, Owner).

plan_abstract_mandatory_child_fails(Config) ->
    {Owner, Abstract} = ?config(oa, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OA", Owner, Abstract, mandatory, 1),
    {error, {class_not_instantiable, Abstract}, #{culprit := _}} =
        graphdb_rules:plan_composition_firing(environment, Owner).

plan_cascade(Config) ->
    %% Owner mandates Bolt; Bolt mandates Widget
    {Owner, Bolt, Widget} = ?config(obw, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "BW", Bolt, Widget, mandatory, 1),
    {ok, #{mandatory_children :=
            [#{class := Bolt, mandatory_children := [#{class := Widget}]}]}} =
        graphdb_rules:plan_composition_firing(environment, Owner).

plan_cycle_self_nest_zero_children(Config) ->
    %% Folder mandates Folder
    Folder = ?config(folder, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "FF", Folder, Folder, mandatory, 1),
    {ok, #{mandatory_children := []}} =       %% zero-level cut, B2-D5
        graphdb_rules:plan_composition_firing(environment, Folder).

plan_cycle_a_b_a(Config) ->
    %% A mandates B; B mandates A  -> {A,B}, the closing A cut
    {A, B} = ?config(ab, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "AB", A, B, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "BA", B, A, mandatory, 1),
    {ok, #{class := A, mandatory_children :=
            [#{class := B, mandatory_children := []}]}} =
        graphdb_rules:plan_composition_firing(environment, A).

plan_project_scope_is_leaf(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 1),
    {ok, #{class := Owner, mandatory_children := [], auto_rules := []}} =
        graphdb_rules:plan_composition_firing({project, p1}, Owner).
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group plan_firing`
Expected: FAIL — `plan_composition_firing/2` is undefined.

- [ ] **Step 3: Add export + API wrapper + handler clauses**

Export `plan_composition_firing/2`. API wrapper:

```erlang
plan_composition_firing(Scope, ClassNref) ->
	gen_server:call(?MODULE, {plan_composition_firing, Scope, ClassNref}).
```

Handlers (place near `effective_rules_for_class`):

```erlang
handle_call({plan_composition_firing, environment, ClassNref}, _From, State) ->
	{reply, plan_node(ClassNref, root, undefined, undefined, [], State), State};
handle_call({plan_composition_firing, {project, _}, ClassNref}, _From, State) ->
	%% B1 returns no rules for project scope -> a leaf plan
	{reply, {ok, leaf_plan(ClassNref, root, undefined, undefined)}, State};
```

(`root` rule + `undefined` deployment for the requested instance; every
mandated child node carries the real rule node **and** its full `Deployment`
map — B2-D6 requires the report to carry the deployment, so it is threaded into
each plan node here, not synthesised later.)

- [ ] **Step 4: Add the planner helpers**

Add a "Plan path (pure read — B2)" section:

```erlang
%% leaf_plan(ClassNref, Rule, Deploy, Name) -> PlanNode
%% Deploy is the deployment map of the rule that mandated this node
%% (`undefined` for the root).  Carried so the report's `deployment` field
%% is the real #{mode, multiplicity, template} (B2-D6).
leaf_plan(ClassNref, Rule, Deploy, Name) ->
	#{class => ClassNref, name => Name, rule => Rule, deploy => Deploy,
	  mandatory_children => [], auto_rules => []}.

%% plan_node(ClassNref, Rule, Deploy, Name, OnPath, State)
%%   -> {ok, PlanNode} | {error, Reason, #{plan_so_far, culprit}}
%% Recursively expands the mandatory cascade for ClassNref.  OnPath is the
%% class path root->here (B2-D5 cycle guard).  Rule/Deploy describe the
%% composition rule that mandated this node (`root`/`undefined` for the
%% requested instance).
plan_node(ClassNref, Rule, Deploy, Name, OnPath, State) ->
	OnPath1 = [ClassNref | OnPath],
	CompRules = composition_pairs(ClassNref, State),
	plan_rules(CompRules, OnPath1, State,
			   leaf_plan(ClassNref, Rule, Deploy, Name)).

%% composition_pairs(ClassNref, State) -> [{#node{}, Deployment}]
%% Effective rules (self + taxonomy ancestors, nearest-first) filtered to the
%% CompositionRule meta-class.  Flattened across levels, preserving order.
composition_pairs(ClassNref, State) ->
	[ {RuleNode, Deploy}
	  || {_Level, Pairs} <- effective_rules(ClassNref, State),
		 {RuleNode, Deploy} <- Pairs,
		 is_composition_rule(RuleNode, State) ].

is_composition_rule(#node{classes = Classes}, State) ->
	lists:member(State#state.composition_rule_nref, Classes).

%% plan_rules(Pairs, OnPath1, State, Acc) -> {ok, PlanNode} | {error, R, Failure}
%% First-failure-aborts (B2-D6): a mandatory violation stops planning.
plan_rules([], _OnPath1, _State, Acc) ->
	{ok, Acc};
plan_rules([{RuleNode, Deploy} | Rest], OnPath1, State, Acc) ->
	case maps:get(mode, Deploy, undefined) of
		auto ->
			Autos = maps:get(auto_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Acc#{auto_rules => Autos});
		propose ->
			plan_rules(Rest, OnPath1, State, Acc);          %% B3 owns propose
		mandatory ->
			case plan_mandatory(RuleNode, Deploy, OnPath1, State, Acc) of
				{ok, Acc1}          -> plan_rules(Rest, OnPath1, State, Acc1);
				{error, _, _} = Err -> Err                  %% first-failure abort
			end;
		_ ->
			plan_rules(Rest, OnPath1, State, Acc)
	end.

%% plan_mandatory(RuleNode, Deploy, OnPath1, State, Acc)
%%   -> {ok, Acc'} | {error, Reason, #{plan_so_far, culprit}}
plan_mandatory(RuleNode, Deploy, OnPath1, State, Acc) ->
	ChildClass = content_avp_value(RuleNode,
								   State#state.child_class_nref_attr),
	case lists:member(ChildClass, OnPath1) of
		true ->
			{ok, Acc};                  %% B2-D5 zero-level cut: self-nest, no fire
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

fail(Reason, CulpritRule, Acc) ->
	{error, Reason, #{plan_so_far => Acc, culprit => CulpritRule}}.

%% expand_children(RuleNode, Deploy, ChildClass, Mult, I, OnPath1, State, Acc)
%%   -> {ok, Acc'} | {error, R, Failure}
expand_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _OnPath1, _State, Acc)
		when I > Mult ->
	{ok, Acc};
expand_children(RuleNode, Deploy, ChildClass, Mult, I, OnPath1, State, Acc) ->
	Name = resolve_child_name(RuleNode, ChildClass, I, Mult, State),
	case plan_node(ChildClass, RuleNode, Deploy, Name, OnPath1, State) of
		{ok, ChildPlan} ->
			Kids = maps:get(mandatory_children, Acc) ++ [ChildPlan],
			expand_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OnPath1,
							State, Acc#{mandatory_children => Kids});
		{error, R, Failure} ->
			%% Nested failure: rewrite plan_so_far to THIS level's Acc (parent
			%% with completed siblings; failing branch dropped), keep the leaf
			%% culprit.  (B2 design §3.1 trace.)
			{error, R, Failure#{plan_so_far => Acc}}
	end.

%% resolve_child_name(RuleNode, ChildClass, I, Mult, State) -> string()
resolve_child_name(RuleNode, ChildClass, I, Mult, State) ->
	resolve_child_name_pub(RuleNode, ChildClass, I, Mult,
						   State#state.name_pattern_attr).

%% resolve_child_name_pub(RuleNode, ChildClass, I, Mult, NamePatternAttr)
%%   -> string()
%% State-free name resolver so graphdb_instance can reuse it post-commit for
%% auto children (via the rule_child_name/4 export below).
resolve_child_name_pub(RuleNode, ChildClass, I, Mult, NamePatternAttr) ->
	case content_avp_lookup(RuleNode, NamePatternAttr) of
		{ok, Pattern} ->
			lists:flatten(string:replace(Pattern, "{i}",
										 integer_to_list(I), all));
		not_found ->
			fallback_name(ChildClass, I, Mult)
	end.

fallback_name(ChildClass, _I, 1) ->
	class_name(ChildClass);
fallback_name(ChildClass, I, _Mult) ->
	class_name(ChildClass) ++ " " ++ integer_to_list(I).

%% class_name(ClassNref) -> string()  (the class-name AVP, or a safe default)
class_name(ClassNref) ->
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case avp_lookup(AVPs, ?NAME_ATTR_CLASS) of
				{ok, N}   -> N;
				not_found -> "instance"
			end;
		_ ->
			"instance"
	end.

%% content_avp_value(RuleNode, AttrNref) -> term() | undefined
content_avp_value(#node{attribute_value_pairs = AVPs}, AttrNref) ->
	case avp_lookup(AVPs, AttrNref) of
		{ok, V}   -> V;
		not_found -> undefined
	end.

%% content_avp_lookup(RuleNode, AttrNref) -> {ok, term()} | not_found
content_avp_lookup(#node{attribute_value_pairs = AVPs}, AttrNref) ->
	avp_lookup(AVPs, AttrNref).

avp_lookup(AVPs, AttrNref) ->
	case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
		{value, #{value := V}} -> {ok, V};
		false                  -> not_found
	end.
```

- [ ] **Step 5: Export the two readers `graphdb_instance` reuses post-commit**

Add to the export list and bodies (so the auto path in Task 6 calls these
instead of duplicating AVP/name logic). Place the bodies in the "Plan path"
section:

```erlang
%% (export list)
		plan_composition_firing/2,
		rule_child_class/1,
		rule_child_name/4,
```

```erlang
%% rule_child_class(RuleNode) -> integer() | undefined
%% The child_class_nref content AVP of a composition rule node.
rule_child_class(RuleNode) ->
	{ok, Seeds} = seeded_nrefs(),
	content_avp_value(RuleNode, maps:get(child_class_nref_attr, Seeds)).

%% rule_child_name(RuleNode, ChildClass, I, Mult) -> string()
%% The resolved name for child I-of-Mult of ChildClass under RuleNode
%% (name_pattern substitution or class-name fallback).  State-free.
rule_child_name(RuleNode, ChildClass, I, Mult) ->
	{ok, Seeds} = seeded_nrefs(),
	resolve_child_name_pub(RuleNode, ChildClass, I, Mult,
						   maps:get(name_pattern, Seeds)).
```

(Both call `seeded_nrefs/0` on the same process — safe; these run from
`graphdb_instance`'s process via a cross-process call to `graphdb_rules`, no
re-entrancy.)

- [ ] **Step 6: Run the `plan_firing` group to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group plan_firing`
Expected: PASS — all plan cases green.

- [ ] **Step 7: Run the full rules suite (no regression)**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 B2: plan_composition_firing/2 abstract plan tree (pure read)"
```

---

## Task 4: Report helpers in `graphdb_instance` (pure functions)

The rule-centric report (B2-D6) and its builders are pure functions. Build and
test them in isolation before wiring firing, so the firing tasks assert against
known-correct helpers.

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (add the helpers + test-only exports)
- Test: `apps/graphdb/test/graphdb_instance_tests.erl` (EUnit)

- [ ] **Step 1: Write the failing EUnit tests**

In `apps/graphdb/test/graphdb_instance_tests.erl` add (the module already runs
under `-ifdef(TEST)` exports from `graphdb_instance`):

```erlang
mk_rule(N) -> {node, N, instance, [], [c], [#{attribute => 1, value => "r"}]}.

add_outcome_creates_then_appends_test() ->
    R0 = [],
    Rule = mk_rule(100),
    Dep = #{mode => mandatory, multiplicity => 2, template => 31},
    R1 = graphdb_instance:add_outcome(R0, Rule, Dep,
            #{owner => 5, index => 1, status => fired, child => 200}),
    ?assertMatch([#{rule := _, deployment := Dep, outcomes := [_]}], R1),
    R2 = graphdb_instance:add_outcome(R1, Rule, Dep,
            #{owner => 5, index => 2, status => fired, child => 201}),
    [#{outcomes := Outs}] = R2,
    ?assertEqual(2, length(Outs)).            %% same rule -> one rule_report

merge_reports_unions_by_rule_test() ->
    Rule = mk_rule(100),
    Dep = #{mode => auto, multiplicity => 1, template => 31},
    A = graphdb_instance:add_outcome([], Rule, Dep,
            #{owner => 5, index => 1, status => fired, child => 200}),
    B = graphdb_instance:add_outcome([], Rule, Dep,
            #{owner => 6, index => 1, status => fired, child => 300}),
    Merged = graphdb_instance:merge_reports(A, B),
    ?assertEqual(1, length(Merged)),          %% one rule_report
    [#{outcomes := Outs}] = Merged,
    ?assertEqual(2, length(Outs)).

report_not_attempted_marks_planned_and_culprit_test() ->
    %% plan_so_far: Owner mandates one Bolt (child rule = mk_rule(100))
    Bolt = #{class => 10, name => "Bolt", rule => mk_rule(100),
             mandatory_children => [], auto_rules => []},
    PlanSoFar = #{class => 9, name => undefined, rule => root,
                  mandatory_children => [Bolt], auto_rules => []},
    Culprit = mk_rule(101),
    Failure = #{plan_so_far => PlanSoFar, culprit => Culprit},
    R = graphdb_instance:report_not_attempted(some_reason, Failure),
    %% one not_attempted (rule 100) + one failed (rule 101)
    Status = fun(N) ->
        [#{outcomes := [#{status := S}]}] =
            [RR || RR = #{rule := {node, X, _,_,_,_}} <- R, X =:= N],
        S
    end,
    ?assertEqual(not_attempted, Status(100)),
    ?assertEqual(failed, Status(101)).

summarize_counts_test() ->
    Rule = mk_rule(100),
    Dep = #{mode => mandatory, multiplicity => 1, template => 31},
    R0 = graphdb_instance:add_outcome([], Rule, Dep,
            #{owner => 5, index => 1, status => fired, child => 200}),
    R1 = graphdb_instance:add_outcome(R0, Rule, Dep,
            #{owner => 5, index => 1, status => failed, reason => x}),
    ?assertEqual(#{fired => 1, failed => 1, not_attempted => 0},
                 graphdb_instance:summarize(R1)).
```

- [ ] **Step 2: Run to verify they fail**

Run: `./rebar3 eunit --module graphdb_instance_tests`
Expected: FAIL — `add_outcome`/`merge_reports`/`report_not_attempted`/`summarize` undefined.

- [ ] **Step 3: Implement the helpers**

In `graphdb_instance.erl`, add a "Firing report (B2-D6)" section:

```erlang
%% add_outcome(Report, RuleNode, Deployment, Outcome) -> Report'
%% Appends Outcome under RuleNode's rule_report (preserving rule order),
%% creating the rule_report if this rule is not yet present.
add_outcome(Report, #node{nref = RuleNref} = RuleNode, Deployment, Outcome) ->
	case lists:any(fun(#{rule := #node{nref := N}}) -> N =:= RuleNref end,
				   Report) of
		true ->
			[ append_if(RR, RuleNref, Outcome) || RR <- Report ];
		false ->
			Report ++ [#{rule => RuleNode, deployment => Deployment,
						 outcomes => [Outcome]}]
	end.

append_if(#{rule := #node{nref := N}, outcomes := Os} = RR, N, Outcome) ->
	RR#{outcomes => Os ++ [Outcome]};
append_if(RR, _N, _Outcome) ->
	RR.

%% merge_reports(R1, R2) -> Report   (union by rule nref)
merge_reports(R1, R2) ->
	lists:foldl(
		fun(#{rule := RuleNode, deployment := Dep, outcomes := Outs}, Acc) ->
			lists:foldl(
				fun(O, A) -> add_outcome(A, RuleNode, Dep, O) end, Acc, Outs)
		end, R1, R2).

%% report_not_attempted(Reason, Failure) -> Report
%% Failure = #{plan_so_far => PlanNode, culprit => #node{} | undefined}.
%% Every mandated child in plan_so_far becomes a not_attempted outcome under
%% its mandating rule; the culprit (if any) becomes one failed outcome.
report_not_attempted(Reason, #{plan_so_far := Plan, culprit := Culprit}) ->
	Base = walk_not_attempted(Plan, []),
	case Culprit of
		undefined ->
			Base;
		#node{} ->
			Dep = #{},      %% deployment not carried on the error path
			add_outcome(Base, Culprit, Dep,
						#{index => 1, status => failed, reason => Reason})
	end.

walk_not_attempted(#{mandatory_children := Kids}, Acc0) ->
	lists:foldl(
		fun(#{rule := Rule} = Child, Acc) ->
			Acc1 = add_outcome(Acc, Rule, #{},
								#{index => 1, status => not_attempted}),
			walk_not_attempted(Child, Acc1)         %% recurse deeper
		end, Acc0, Kids).

%% summarize(Report) -> #{fired => N, failed => M, not_attempted => K}
summarize(Report) ->
	Outs = [O || #{outcomes := Os} <- Report, O <- Os],
	Count = fun(S) -> length([1 || #{status := X} <- Outs, X =:= S]) end,
	#{fired => Count(fired), failed => Count(failed),
	  not_attempted => Count(not_attempted)}.
```

Add the test-only exports under the existing `-ifdef(TEST)` block:

```erlang
-ifdef(TEST).
-export([
		find_avp_value/2,
		add_outcome/4,
		merge_reports/2,
		report_not_attempted/2,
		summarize/1
		]).
-endif.
```

- [ ] **Step 4: Run to verify they pass**

Run: `./rebar3 eunit --module graphdb_instance_tests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_tests.erl
git commit -m "F4 B2: rule-centric report helpers in graphdb_instance"
```

---

## Task 5: EXECUTE + return-shape change + call-site migration (mandatory firing)

Wire mandatory firing: `do_create_instance/5`, `execute/5`, the 3-tuple return,
and migrate all 129 existing `{ok, X}` / `{error, Reason}` create_instance
assertions. The suite must be green at the end of this task.

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`create_instance/3` wrapper, handler, `do_create_instance`, `do_write_instance` → `execute/5`)
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`, `graphdb_query_SUITE.erl`, `graphdb_mgr_SUITE.erl` (migration + new `firing` group)

- [ ] **Step 1: Migrate existing call sites first (keep them green under the new shape after Step 3)**

This is mechanical. In the three suites, every successful create returns a
3-tuple; every mandatory/validation error stays a 2-tuple (pre-PLAN root errors)
or becomes a 3-tuple (firing errors — but existing tests have no rules, so their
create errors are all pre-PLAN root errors and stay 2-tuple). Convert the
success-pattern bindings:

```bash
# Preview first:
grep -rn "= graphdb_instance:create_instance" apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_query_SUITE.erl apps/graphdb/test/graphdb_mgr_SUITE.erl | grep "{ok,"
```

For each `{ok, Var} = graphdb_instance:create_instance(...)` rewrite to
`{ok, Var, _} = graphdb_instance:create_instance(...)`. A guarded sed handles
the common single-line form (review the diff afterward — do NOT blind-apply):

```bash
for f in apps/graphdb/test/graphdb_instance_SUITE.erl \
         apps/graphdb/test/graphdb_query_SUITE.erl \
         apps/graphdb/test/graphdb_mgr_SUITE.erl; do
  sed -i -E 's/\{ok, ([A-Za-z0-9_]+)\} = graphdb_instance:create_instance/{ok, \1, _} = graphdb_instance:create_instance/g' "$f"
done
git diff --stat
```

Manually fix any multi-line or `?assertMatch({ok, _}, ...)` forms the sed missed
(e.g. `?assertMatch({ok, _, _}, graphdb_instance:create_instance(...))`). Leave
`{error, _}` assertions for missing-class/missing-parent/abstract-root untouched
— those remain 2-tuples (pre-PLAN).

- [ ] **Step 2: Change `create_instance/3` to seed the internal recursion**

Replace the API wrapper's doc-return line and keep the message form; the shape
change happens in the handler. In the handler clause:

```erlang
handle_call({create_instance, Name, ClassNref, ParentNref}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	{reply, do_create_instance(Name, ClassNref, ParentNref, InstAttr, []),
		State};
```

- [ ] **Step 3: Rewrite `do_create_instance` to `/5` (plan/execute, mandatory only)**

Replace the existing `do_create_instance/4` and `do_write_instance/3`:

```erlang
%% do_create_instance(Name, ClassNref, ParentNref, InstAttr, OnPath)
%%   -> {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%% The unifying internal entry (B2-D2): every cascade level flows through here,
%% never the gen_server API.  OnPath is the class path for the cycle guard.
do_create_instance(Name, ClassNref, ParentNref, InstAttr, OnPath) ->
	case do_validate_class(ClassNref, InstAttr) of
		ok ->
			case do_validate_parent(ParentNref) of
				ok ->
					fire_create(Name, ClassNref, ParentNref, OnPath);
				{error, _} = Err ->
					Err            %% pre-PLAN root error: 2-tuple (no report)
			end;
		{error, _} = Err ->
			Err                    %% pre-PLAN root error: 2-tuple (no report)
	end.

%% fire_create(Name, ClassNref, ParentNref, OnPath)
%%   -> {ok, Nref, report()} | {error, Reason, report()}
fire_create(Name, ClassNref, ParentNref, OnPath) ->
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref) of
		{ok, PlanTree} ->
			case execute(Name, ClassNref, ParentNref, OnPath, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan} ->
					AutoReport = fire_auto(InstPlan, OnPath),
					{ok, RootNref,
					 merge_reports(MandOutcomes, AutoReport)};
				{error, R, Report} ->
					{error, R, Report}
			end;
		{error, R, Failure} ->
			{error, R, report_not_attempted(R, Failure)}
	end.
```

Add the scope macro near the top (after the record defs):

```erlang
%% Rules live in the shared ontology; project-scoped rules are not yet
%% supported (B1/B2).  Firing always consults environment-scope rules.
-define(RULE_SCOPE, environment).
```

- [ ] **Step 4: Implement `execute/5` (allocate outside txn; write mandatory subtree)**

```erlang
%% execute(RootName, RootClass, RootParent, OnPath, PlanTree)
%%   -> {ok, RootNref, MandOutcomes, InstPlan} | {error, Reason, report()}
%% Allocates every node's nrefs/ids OUTSIDE the transaction, writes the root
%% and the whole mandatory subtree in ONE transaction.
execute(RootName, RootClass, RootParent, _OnPath, PlanTree) ->
	%% Annotate the plan tree with allocated nrefs (root uses RootName).
	InstPlan = allocate_plan(PlanTree#{name => RootName}),
	{Writes, Outcomes} = plan_writes(InstPlan, RootParent),
	Txn = fun() ->
		lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					  Writes)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok} ->
			{ok, maps:get(nref, InstPlan), Outcomes, InstPlan};
		{aborted, R} ->
			{error, R,
			 report_not_attempted(R,
				#{plan_so_far => PlanTree, culprit => undefined})}
	end.

%% allocate_plan(PlanNode) -> InstPlanNode (same tree + nref per node)
allocate_plan(#{mandatory_children := Kids} = Node) ->
	Nref = graphdb_nref:get_next(),
	Node#{nref => Nref,
		  mandatory_children => [allocate_plan(K) || K <- Kids]}.

%% plan_writes(InstPlan, RootParent) -> {Writes, Outcomes}
%% Pre-order DFS over the instantiated plan tree.  The root emits only its own
%% five records (it is the requested instance, not a firing).  Each mandated
%% descendant emits its records plus one `fired` outcome under its rule,
%% indexed 1..N within that rule among its siblings (per-rule counter).
plan_writes(#{nref := RootNref, class := Class, name := Name,
			  mandatory_children := Kids}, RootParent) ->
	Acc0 = {instance_records(RootNref, Class, Name, RootParent), []},
	write_children(Kids, RootNref, Acc0).

%% write_children(Siblings, OwnerNref, {Writes, Outcomes}) -> {Writes, Outcomes}
%% Numbers siblings within their mandating rule (1-based), emits each child's
%% records + fired outcome (carrying the rule's real `deploy` map), then
%% recurses into the child's own mandatory children.  Children always have a
%% real `rule` (#node{}) and `deploy` map — only the root is rule=root, and the
%% root is handled by plan_writes/2 above.
write_children(Siblings, OwnerNref, Acc) ->
	{_Counts, Result} =
		lists:foldl(
			fun(#{nref := CNref, class := CClass, name := CName,
				  rule := Rule, deploy := Deploy,
				  mandatory_children := GKids}, {Counts, {W, O}}) ->
				Idx = maps:get(rule_key(Rule), Counts, 0) + 1,
				W1 = W ++ instance_records(CNref, CClass, CName, OwnerNref),
				O1 = add_outcome(O, Rule, Deploy,
						#{owner => OwnerNref, index => Idx,
						  status => fired, child => CNref}),
				{W2, O2} = write_children(GKids, CNref, {W1, O1}),
				{Counts#{rule_key(Rule) => Idx}, {W2, O2}}
			end, {#{}, Acc}, Siblings),
	Result.

rule_key(#node{nref = N}) -> N.
```

`instance_records/4`:

```erlang
%% instance_records(Nref, ClassNref, Name, ParentNref) -> [{Tab, Rec}]
%% The five records the Phase-A do_write_instance produced, as a write list.
instance_records(Nref, ClassNref, Name, ParentNref) ->
	{MembId1, MembId2} = rel_id_server:get_id_pair(),
	{CompId1, CompId2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	Node = #node{nref = Nref, kind = instance, parents = [ParentNref],
				 classes = [ClassNref], attribute_value_pairs = [NameAVP]},
	I2C = #relationship{id = MembId1, kind = instantiation, source_nref = Nref,
		characterization = ?ARC_INST_TO_CLASS, target_nref = ClassNref,
		reciprocal = ?ARC_CLASS_TO_INST, avps = []},
	C2I = #relationship{id = MembId2, kind = instantiation,
		source_nref = ClassNref, characterization = ?ARC_CLASS_TO_INST,
		target_nref = Nref, reciprocal = ?ARC_INST_TO_CLASS, avps = []},
	P2C = #relationship{id = CompId1, kind = composition,
		source_nref = ParentNref, characterization = ?ARC_INST_CHILD,
		target_nref = Nref, reciprocal = ?ARC_INST_PARENT, avps = []},
	C2P = #relationship{id = CompId2, kind = composition, source_nref = Nref,
		characterization = ?ARC_INST_PARENT, target_nref = ParentNref,
		reciprocal = ?ARC_INST_CHILD, avps = []},
	[{nodes, Node}, {relationships, I2C}, {relationships, C2I},
	 {relationships, P2C}, {relationships, C2P}].
```

(The report's `deployment` field is the real `#{mode, multiplicity, template}`
map carried in each plan node's `deploy` key — `write_children` reads it
directly; no synthesised deployment.)

- [ ] **Step 5: Stub `fire_auto/2` (mandatory-only for now)**

So Task 5 compiles and the mandatory path is exercised without auto:

```erlang
%% fire_auto(InstPlan, OnPath) -> report()   (auto firing — Task 6)
fire_auto(_InstPlan, _OnPath) -> [].
```

- [ ] **Step 6: Write the mandatory firing CT cases (new `firing` group)**

In `graphdb_instance_SUITE.erl` add a `firing` group with fixtures that create
`Owner`/`Bolt` classes (default templates) and composition rules:

```erlang
firing_no_rules_baseline(_Config) ->
    {ok, ClassNref} = graphdb_class:create_class("Plain", 3),
    {ok, Nref, Report} = graphdb_instance:create_instance("p1", ClassNref, 5),
    ?assert(is_integer(Nref)),
    ?assertEqual([], Report).

firing_single_mandatory(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 1),
    {ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
    %% one Bolt child created, reported fired under the rule
    {ok, Kids} = graphdb_instance:children(Root),
    ?assertEqual(1, length(Kids)),
    [#{rule := _, outcomes := [#{owner := Root, status := fired,
                                 child := ChildNref}]}] = Report,
    ?assert(lists:member(ChildNref, [N || {node,N,_,_,_,_} <- Kids])).

firing_mandatory_mult(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 3),
    {ok, _Root, [#{deployment := Dep, outcomes := Outs}]} =
        graphdb_instance:create_instance("car", Owner, 5),
    ?assertEqual(3, length(Outs)),
    ?assertEqual([1,2,3], [maps:get(index, O) || O <- Outs]),
    %% B2-D6: the report carries the rule's real deployment, not a stub
    ?assertEqual(3, maps:get(multiplicity, Dep)),
    ?assertEqual(mandatory, maps:get(mode, Dep)).

firing_mandatory_cascade_atomic(Config) ->
    {Owner, Bolt, Widget} = ?config(obw, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OB", Owner, Bolt, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "BW", Bolt, Widget, mandatory, 1),
    {ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
    {ok, [BoltInst]} = graphdb_instance:children(Root),
    BoltNref = element(2, BoltInst),
    {ok, [_Widget]} = graphdb_instance:children(BoltNref),
    %% both rules report a fired outcome
    ?assertEqual(2, length(Report)).

firing_mandatory_failure_rolls_back(Config) ->
    {Owner, Abstract} = ?config(oa, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OA", Owner, Abstract, mandatory, 1),
    Before = mnesia:table_info(nodes, size),
    {error, {class_not_instantiable, Abstract}, Report} =
        graphdb_instance:create_instance("car", Owner, 5),
    ?assertEqual(Before, mnesia:table_info(nodes, size)),   %% nothing written
    %% culprit failed in the report
    ?assert(lists:any(
        fun(#{outcomes := Os}) ->
            lists:any(fun(#{status := S}) -> S =:= failed end, Os)
        end, Report)).
```

- [ ] **Step 7: Run the instance suite + the migrated suites**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE`
Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_query_SUITE`
Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS — migrated assertions green; new `firing` cases green.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "F4 B2: mandatory composition firing + {ok,Nref,Report} return; migrate call sites"
```

---

## Task 6: POST-COMMIT `auto` firing

Replace the `fire_auto/2` stub with the real best-effort post-commit firing
(B2-D1/D6 §3.3): walk the instantiated plan tree, fire each node's `auto` rules
by recursing `do_create_instance/5`, merge sub-reports by rule.

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`fire_auto/2`)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl` (`firing` group)

- [ ] **Step 1: Write the failing CT cases**

```erlang
firing_auto_best_effort(Config) ->
    {Owner, Bolt} = ?config(ob, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OBauto", Owner, Bolt, auto, 1),
    {ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
    {ok, [_]} = graphdb_instance:children(Root),       %% auto child created
    ?assertEqual(#{fired => 1, failed => 0, not_attempted => 0},
                 graphdb_instance:summarize(Report)).

firing_auto_failure_survives(Config) ->
    {Owner, Abstract} = ?config(oa, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OAauto", Owner, Abstract, auto, 1),
    {ok, Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
    ?assert(is_integer(Root)),                         %% root survived
    ?assertEqual(#{fired => 0, failed => 1, not_attempted => 0},
                 graphdb_instance:summarize(Report)).

firing_auto_cascade_merges(Config) ->
    %% Owner -auto-> Bolt; Bolt -mandatory-> Widget
    {Owner, Bolt, Widget} = ?config(obw, Config),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "OBauto", Owner, Bolt, auto, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "BW", Bolt, Widget, mandatory, 1),
    {ok, _Root, Report} = graphdb_instance:create_instance("car", Owner, 5),
    %% the auto Bolt and its mandatory Widget both fired
    ?assertEqual(#{fired => 2, failed => 0, not_attempted => 0},
                 graphdb_instance:summarize(Report)).
```

- [ ] **Step 2: Run to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --group firing`
Expected: FAIL — `fire_auto/2` is a stub returning `[]`.

- [ ] **Step 3: Implement `fire_auto/2`**

This uses the `graphdb_rules:rule_child_class/1` and
`graphdb_rules:rule_child_name/4` exports added in Task 3 (Step 5) — no
AVP/name logic is duplicated here. `fire_one_auto/5` runs its checks in the
§3.3 order: **instantiable → unbounded → cycle cut → expand**. Because the
abstract case is caught first, the recursive `do_create_instance/5` call passes
`InstAttr = undefined` safely (an unmarked class is treated as instantiable by
`do_validate_class/2`, and abstract children never reach the call).

```erlang
%% fire_auto(InstPlan, OnPath) -> report()
%% Post-commit, best-effort.  Fires this node's auto rules (recursing the
%% internal do_create_instance/5 — never the gen_server API), then recurses
%% into the mandatory subtree so auto rules fire at every level.
fire_auto(#{nref := Nref, class := Class, auto_rules := Autos,
			mandatory_children := Kids}, OnPath) ->
	OnPath1 = [Class | OnPath],
	Here = lists:foldl(
		fun({RuleNode, Deploy}, Acc) ->
			fire_one_auto(RuleNode, Deploy, Nref, OnPath1, Acc)
		end, [], Autos),
	lists:foldl(
		fun(Child, Acc) -> merge_reports(Acc, fire_auto(Child, OnPath1)) end,
		Here, Kids).

%% fire_one_auto(RuleNode, Deploy, OwnerNref, OnPath1, Acc) -> report()
%% Check order matches design §3.3: instantiable, then unbounded, then the
%% vertical-cycle cut, then expansion.
fire_one_auto(RuleNode, Deploy, OwnerNref, OnPath1, Acc) ->
	ChildClass = graphdb_rules:rule_child_class(RuleNode),
	case graphdb_class:is_instantiable(ChildClass) of
		false ->
			add_outcome(Acc, RuleNode, Deploy,
				#{owner => OwnerNref, index => 1, status => failed,
				  reason => {class_not_instantiable, ChildClass}});
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

fire_auto_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _Owner, _OnPath1,
				   Acc) when I > Mult ->
	Acc;
fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I, OwnerNref, OnPath1,
				   Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Mult),
	Acc2 = case do_create_instance(Name, ChildClass, OwnerNref, undefined,
								   OnPath1) of
		{ok, ChildNref, SubReport} ->
			A1 = add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => fired,
					  child => ChildNref}),
			merge_reports(A1, SubReport);
		{error, R, SubReport} ->
			A1 = add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => failed,
					  reason => R}),
			merge_reports(A1, SubReport);
		{error, R} ->        %% pre-PLAN 2-tuple (bad class/parent)
			add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => failed,
					  reason => R})
	end,
	fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OwnerNref,
					   OnPath1, Acc2).
```

- [ ] **Step 4: Run the `firing` group**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --group firing`
Expected: PASS — auto best-effort, failure-survives, and cascade-merge green.

- [ ] **Step 5: Full graphdb suite sweep**

Run: `make test-ct-parallel`
Expected: PASS — all CT suites green (no regression from the return-shape change).

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/src/graphdb_instance.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "F4 B2: post-commit auto firing (best-effort) with cascade report merge"
```

---

## Task 7: Documentation, diagram, and bookkeeping

**Files:**
- Modify: `docs/diagrams/ontology-tree.md`, `apps/graphdb/CLAUDE.md`, `ARCHITECTURE.md`, `README.md`, `TASKS.md`, `docs/designs/f4-graphdb-rules-design.md`

- [ ] **Step 1: Ontology diagram**

In `docs/diagrams/ontology-tree.md`, add `name_pattern` to the Rule Literals
sub-group (alongside `child_class_nref`, `mode`, `multiplicity`, …).

- [ ] **Step 2: graphdb/CLAUDE.md**

Update the `graphdb_rules` API list: add `create_composition_rule/6,7,8` and
`plan_composition_firing/2`; note the new `name_pattern` rule literal (7 rule
literals now). Update the `graphdb_instance` API: `create_instance/3` →
`{ok, Nref, Report}` / `{error, Reason, Report}` with the rule-centric report.

- [ ] **Step 3: ARCHITECTURE.md**

Update the `graphdb_instance` contract line (return shape now carries a firing
report) and the worker description (composition firing engine, B2). Bump the
test count.

- [ ] **Step 4: README.md + TASKS.md**

Update the test-count table to the new totals (run the suites and read the
counts). Mark F4 Phase B / B2 status in `TASKS.md` (B2 complete; B3/B4/B5
remain).

- [ ] **Step 5: Design OI marks**

In `docs/designs/f4-graphdb-rules-design.md` note that B2 (composition firing)
landed and that `create_instance/3` now returns a report; cross-reference
`docs/designs/f4-phase-b2-composition-firing-design.md`.

- [ ] **Step 6: Align tables**

```bash
python3 ~/.claude/scripts/align_md_tables.py docs/diagrams/ontology-tree.md \
    apps/graphdb/CLAUDE.md ARCHITECTURE.md README.md
```

- [ ] **Step 7: Final full sweep + commit**

Run: `make test-ct-parallel && ./rebar3 eunit`
Expected: PASS — all green.

```bash
git add docs/ apps/graphdb/CLAUDE.md ARCHITECTURE.md README.md TASKS.md
git commit -m "F4 B2: docs, ontology diagram, test counts for composition firing"
```

---

## Self-Review Checklist (controller, before final review)

- Every B2-D decision has a task: D1/D2 (Task 5 `do_create_instance/5` internal
  recursion), D3 (Task 3 abstract plan), D4 additive (Task 3/5 — no dedup), D5
  cycle guard (Task 3 plan + Task 6 auto), D6 report (Task 4/5/6), D7/D8
  name_pattern (Task 1/2/3), D9 summarize (Task 4).
- Error catalogue (§4): mandatory unbounded + abstract (Task 3 plan tests);
  txn abort (execute path); auto unbounded/abstract/create-error (Task 6 tests);
  pre-PLAN root errors stay 2-tuple (Task 5 migration leaves them).
- 129-site migration is its own step (Task 5 Step 1) and the suite is green at
  task end.
- No `effective_rules` re-read in `fire_auto` — it uses the plan's `auto_rules`.
- `report_not_attempted/2` (Reason, Failure) matches the design.
