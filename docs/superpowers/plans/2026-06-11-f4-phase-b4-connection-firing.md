<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B4 — Connection Firing Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `create_instance` connection-rule-aware — after the composition
subtree is materialised, consult each instance's effective `ConnectionRule`s and
write connection arc pairs to **existing** target instances, governed by a
caller-supplied resolver and each rule's `mode` / `{Min, Max}` multiplicity.

**Architecture:** A new RESOLVE step is inserted between B2's nref allocation and
B2's root transaction. RESOLVE walks the instantiated plan tree (root +
mandatory composition descendants), and for each node consults its effective
connection rules: it calls the resolver once per rule, validates returned
targets, and splits the result by mode — **mandatory** arcs are written in the
**root transaction** (atomic with the composition subtree), **auto** arcs are
written **post-commit** best-effort, and **deferred / propose** rules surface as
report outcomes. `create_instance/3` keeps report-only semantics (built-in
`report_only` resolver = defer-all); `create_instance/4` threads the caller's
resolver. The threaded state (resolver + stable originating-call anchors) rides
in one **context map** to avoid positional-arg drift.

**Tech Stack:** Erlang/OTP 28.5 (kerl), rebar3 3.27 (`./rebar3`), Mnesia,
Common Test + EUnit. TAB indentation, zero-warning bar.

**Design:** `docs/designs/f4-phase-b4-connection-firing-design.md` (B4-D1…D7).
Consumes B1 (`effective_rules_for_class/2`), B2 (three-phase engine +
rule-centric `report()`), and the B-prep `{Min, Max}` multiplicity shape.

---

## On TDD shape

Most tasks are ordinary red-green TDD. Two are not, and the plan calls them out:

- **Task 2** (the `create_connection_rule/8,/9` reciprocal cutover) is a
  **type/arity cutover**: the new `/8` collides in arity with Phase A's
  template-form `/8` and **silently mis-binds** a stale caller (compiles, runs
  wrong). Production + every call-site migration land in **one commit**; the
  existing connection-rule suite is the regression net. Verification is by
  `grep` over the whole tree, not by compiler arity errors.
- **Task 4a** is a **behaviour-preserving refactor** (thread the context map,
  add `create_instance/4` wired to a defer-all resolver). There is no new test —
  the **entire existing suite staying green** is the gate, exactly like B-prep
  Task 1.

Every other task is test-after coverage of one new branch of `resolve_rules/4`.

---

## Module map (what each touched file owns)

| File                                          | Responsibility this division adds                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`          | seed 8th Rule Literal `reciprocal_nref`; `create_connection_rule/8,/9` (reciprocal param); `effective_connection_rules/2` (connection-filtered gather + content spec) |
| `apps/graphdb/src/graphdb_instance.erl`       | `create_instance/4` + `report_only`; context-map threading; RESOLVE / mandatory-EXECUTE / auto-POST-COMMIT connection passes; connection outcome rendering; `summarize/1` extension; `build_connection_rows/6` extraction |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`   | seeded-nref + reciprocal-content + `effective_connection_rules` cases; migrate all connection-rule call sites to the reciprocal arity |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`| B4 firing cases; migrate existing `summarize/1` assertions to the 7-key map                        |
| `apps/graphdb/test/graphdb_instance_tests.erl`| migrate any EUnit `summarize/1` assertion to the 7-key map                                         |
| `docs/diagrams/ontology-tree.md`              | add `reciprocal_nref` (8th literal) to the Rule Literals sub-group                                 |
| `docs/designs/f4-graphdb-rules-design.md`     | division map B4 done; OI-B4-3 candidate; OI-B2-4 resolved; D6 gains `reciprocal_nref`              |
| `README.md`, `apps/graphdb/CLAUDE.md`         | CT/EUnit count shift; API notes                                                                    |

---

## Key shared types (used across tasks — defined once here)

```erlang
%% Resolver (caller-supplied, threaded through create_instance/4)
Resolver :: fun((ConnContext) -> Decision)

ConnContext :: #{rule             => #node{},   %% the ConnectionRule instance node
                 characterization => integer(),
                 reciprocal       => integer(),
                 target_class     => integer(),
                 mode             => mandatory | auto | propose,
                 multiplicity     => {non_neg_integer(), pos_integer() | unbounded},
                 source           => integer(),            %% firing instance (root OR descendant)
                 root_parent      => integer() | undefined,%% the ParentNref arg (stable, committed)
                 root_source      => integer()}            %% top-level new instance (stable)

Decision :: {connect, [Target]} | defer
Target   :: integer() | {integer(), {FwdAVPs :: list(), RevAVPs :: list()}}

%% Internal context map threaded through do_create_instance and the firing passes.
%% on_path is rebound per cascade level; resolver / root_parent / root_source are
%% invariant down the whole cascade (B4-D2a).
Ctx :: #{inst_attr    => integer() | undefined,
         on_path      => [integer()],
         resolver     => Resolver,
         root_parent  => integer() | undefined,
         root_source  => integer() | undefined}   %% undefined at top level; bound in execute

%% Connection outcome (extends B2's rule-centric report(); coexists with composition outcomes)
connection_outcome() ::
    #{source           => integer(),
      index            => pos_integer(),
      status           => connected | required | proposed | not_connected | failed | not_attempted,
      target           => integer(),     %% present iff status = connected
      characterization => integer(),
      target_class     => integer(),
      reason           => term()}         %% present iff status = failed
```

---

### Task 1: Seed the 8th Rule Literal `reciprocal_nref`

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `docs/diagrams/ontology-tree.md`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

Mirrors how B2 seeded `name_pattern`: a plain `ensure_seed/2` literal under the
Rule Literals sub-group, threaded into `#state{}` and `seeded_nrefs/0`, and
retro-stamped by the existing `graphdb_attr:retro_stamp_attribute_types/0` call
already in `init/1`.

- [ ] **Step 1: Write the failing test**

In `apps/graphdb/test/graphdb_rules_SUITE.erl`, add to the `seeding` group a case
asserting the new seeded key exists and is distinct. First add the export and the
group entry, then the body:

```erlang
%% (export list) add:
		seeds_reciprocal_literal/1,

%% (groups/0, seeding group) add seeds_reciprocal_literal to the list.

seeds_reciprocal_literal(_Config) ->
	{ok, S} = graphdb_rules:seeded_nrefs(),
	Recip = maps:get(reciprocal_nref_attr, S),
	?assert(is_integer(Recip)),
	%% distinct from the characterization literal it sits beside
	?assertNotEqual(maps:get(characterization_nref_attr, S), Recip),
	%% it is a child of the Rule Literals sub-group
	RuleLit = maps:get(rule_literals_group, S),
	{ok, Recip2} = graphdb_attr:find_attribute_by_name(RuleLit, "reciprocal_nref"),
	?assertEqual(Recip, Recip2).
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case seeds_reciprocal_literal`
Expected: FAIL — `maps:get(reciprocal_nref_attr, S)` raises `{badkey, reciprocal_nref_attr}`.

- [ ] **Step 3: Add the state field**

In the `-record(state, …)` definition, add `reciprocal_nref_attr` immediately
after `characterization_nref_attr`:

```erlang
	characterization_nref_attr,
	reciprocal_nref_attr,
	mode_attr,
```

- [ ] **Step 4: Seed it in `init/1`**

After the `CharAttr = ensure_seed("characterization_nref", RuleLitGrp),` line,
add:

```erlang
		ReciprocalAttr = ensure_seed("reciprocal_nref",       RuleLitGrp),
```

and set it in the returned `#state{}` (after `characterization_nref_attr = CharAttr,`):

```erlang
			characterization_nref_attr = CharAttr,
			reciprocal_nref_attr       = ReciprocalAttr,
```

- [ ] **Step 5: Expose it from `seeded_nrefs/0`**

In the `handle_call(seeded_nrefs, …)` reply map, after the
`characterization_nref_attr => …` line:

```erlang
		characterization_nref_attr => State#state.characterization_nref_attr,
		reciprocal_nref_attr       => State#state.reciprocal_nref_attr,
```

Update the `seeded_nrefs/0` doc comment: "twelve nrefs" → "thirteen nrefs".

- [ ] **Step 6: Update the ontology diagram**

In `docs/diagrams/ontology-tree.md`, in the **Rule Literals** sub-group under
Literals (nref 7), add `reciprocal_nref` as the 8th literal beside
`characterization_nref` (match the surrounding Mermaid node style exactly).

- [ ] **Step 7: Run the test to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case seeds_reciprocal_literal`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl docs/diagrams/ontology-tree.md
git commit -m "$(cat <<'EOF'
F4 B4: seed 8th Rule Literal reciprocal_nref

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `create_connection_rule/8,/9` reciprocal param (arity cutover)

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

**This is a type/arity cutover (see "On TDD shape").** The new canonical forms
are `/8` and `/9` with `Reciprocal` in position 5 (right after `Char`). Phase A's
`/7` and template-form `/8` are superseded. The new `/8` **collides in arity**
with the old template `/8` but binds `Reciprocal` where the old bound
`TemplateNref` — a stale caller mis-binds **silently**. Production + every
call-site migration land in **one commit**; verify by `grep`.

- [ ] **Step 1: Replace the public API forms**

In the export list, replace:

```erlang
		create_connection_rule/7,
		create_connection_rule/8,
```

with:

```erlang
		create_connection_rule/8,
		create_connection_rule/9,
```

Replace the two `create_connection_rule/7,/8` function clauses (and their doc
block) with:

```erlang
%%-----------------------------------------------------------------------------
%% create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
%%                        Mode, Mult)
%% create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
%%                        Mode, Mult, TemplateNref)
%%     -> {ok, RuleNref} | {error, term()}
%%
%% Creates a connection rule: a kind=instance node whose class membership is
%% the seeded ConnectionRule meta-class.  Rule content (characterization_nref,
%% reciprocal_nref, target_class_nref, optional template_nref) lives on the
%% node; rule deployment (Template, mode, multiplicity) lives on the applies_to
%% connection arc from the owning (source) class to the rule instance.  Recip is
%% the reverse arc label (B4-D3): the arc as seen from the target back.  Scope
%% environment writes to the shared ontology; {project, _} is not supported.
%%-----------------------------------------------------------------------------
create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
					   Mode, Mult) ->
	create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
						   Mode, Mult, undefined).

create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
					   Mode, Mult, TemplateNref) ->
	gen_server:call(?MODULE,
		{create_connection_rule, Scope, Name, SourceClass, Char, Recip,
		 TargetClass, Mode, Mult, TemplateNref}).
```

- [ ] **Step 2: Update the handle_call clauses**

Replace the two `{create_connection_rule, …}` handle_call clauses with:

```erlang
handle_call({create_connection_rule, environment, Name, SourceClass, Char,
			 Recip, TargetClass, Mode, Mult, TemplateNref}, _From, State) ->
	Reply = case validate_connection(SourceClass, Char, Recip, TargetClass,
									 Mode, Mult, TemplateNref) of
		ok ->
			ContentAVPs = [#{attribute => State#state.characterization_nref_attr,
							 value => Char},
						   #{attribute => State#state.reciprocal_nref_attr,
							 value => Recip},
						   #{attribute => State#state.target_class_nref_attr,
							 value => TargetClass}
						   | optional_template_avp(TemplateNref, State)],
			do_create_rule(State#state.connection_rule_nref, Name,
				SourceClass, ContentAVPs, Mode, Mult, State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_connection_rule, {project, _}, _, _, _, _, _, _, _, _},
			_From, State) ->
	{reply, {error, project_rules_not_yet_supported}, State};
```

- [ ] **Step 3: Add reciprocal validation**

Change `validate_connection/6` to `/7` (insert `Recip` after `Char`) and add a
`validate_reciprocal/1` check to the chain:

```erlang
%% validate_connection(SourceClass, Char, Recip, TargetClass, Mode, Mult,
%%                     TemplateNref) -> ok | {error, atom()}
validate_connection(SourceClass, Char, Recip, TargetClass, Mode, Mult,
					TemplateNref) ->
	chain([
		fun() -> validate_mode(Mode) end,
		fun() -> validate_multiplicity(Mult) end,
		fun() -> validate_owning_class(SourceClass) end,
		fun() -> validate_referenced_class(TargetClass) end,
		fun() -> validate_characterization(Char) end,
		fun() -> validate_reciprocal(Recip) end,
		fun() -> validate_template(TemplateNref) end
	]).
```

Add, immediately after `validate_characterization/1`:

```erlang
%% validate_reciprocal(Nref) -> ok | {error, atom()}
%% The reciprocal must exist and be a relationship attribute (B4-D3).
validate_reciprocal(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[] ->
			{error, reciprocal_not_found};
		[#node{}] ->
			case graphdb_attr:attribute_type_of(Nref) of
				{ok, relationship} -> ok;
				_                  -> {error, reciprocal_not_a_relationship_attribute}
			end
	end.
```

- [ ] **Step 4: Add the new content-AVP test + reciprocal-validation test**

In `graphdb_rules_SUITE.erl`, add a `make_rel_pair/2` helper beside
`make_rel_char/2`:

```erlang
%% make_rel_pair(Name, Recip) -> {FwdNref, RevNref}
make_rel_pair(Name, Recip) ->
	{ok, {Fwd, Rev}} =
		graphdb_attr:create_relationship_attribute_pair(Name, Recip, instance),
	{Fwd, Rev}.
```

Add two cases (export them + add to the `connection`/`validation` groups):

```erlang
connection_rule_stores_reciprocal(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	{Char, Recip} = make_rel_pair("placed_by", "placed"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "order-placed-by", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, S} = graphdb_rules:seeded_nrefs(),
	RecipAttr = maps:get(reciprocal_nref_attr, S),
	{ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
	?assert(lists:member(#{attribute => RecipAttr, value => Recip}, AVPs)).

reciprocal_not_a_relationship_attribute_rejected(_Config) ->
	Source = make_class("Order"),
	Target = make_class("Customer"),
	Char   = make_rel_char("placed_by", "placed"),
	{ok, Lit} = graphdb_attr:create_literal_attribute("weight2", integer),
	Before = table_size(nodes),
	?assertEqual({error, reciprocal_not_a_relationship_attribute},
		graphdb_rules:create_connection_rule(
			environment, "x", Source, Char, Lit, Target, mandatory, {1, 1})),
	?assertEqual(Before, table_size(nodes)).
```

- [ ] **Step 5: Migrate every existing connection-rule call site**

`grep -rn 'create_connection_rule' apps/graphdb` across **src and all test
files**. For each test call site, insert the reciprocal nref after `Char`. The
mechanical recipe: where a test had `Char = make_rel_char(F, R)`, switch it to
`{Char, Recip} = make_rel_pair(F, R)` and pass `Recip` as the new 5th argument.
Concretely, each of these existing call sites (line numbers approximate; locate
by behaviour) changes from the `/7` or template `/8` form to the new `/8` or `/9`:

`creates_connection_rule_minimal`, `creates_connection_rule_with_template`,
`instance_to_class_membership_to_connection_rule`,
`characterization_not_found_rejected`,
`not_a_relationship_attribute_rejected`, `template_not_found_rejected`, and the
connection-rule call sites in the `retrieval`, `scope`, `complex_scenarios`,
`effective`, and `plan_firing` groups (greps at lines ~592, 609, 621, 684, 695,
791, 804, 816, 870, 909, 911, 1097). For the `characterization`-error cases that
pass `999999`/`Lit` as the bad characterization, supply a **valid** reciprocal
(`make_rel_char`/`make_rel_pair`) so the rejection is attributable to the
characterization, not the reciprocal.

`attach_existing_rule/4` writes applies_to arcs directly and is **unaffected**.

- [ ] **Step 6: Verify the migration is complete by grep**

Run:
```bash
grep -rn 'create_connection_rule' apps/graphdb | grep -v '/8\|/9'
```
Expected: only the export-list and doc-comment mentions remain; **no call site**
uses the `/7` or old template-`/8` shape. Then:
```bash
grep -rnc 'create_connection_rule(' apps/graphdb/test/graphdb_rules_SUITE.erl
```
and eyeball each call to confirm a reciprocal sits in position 5.

- [ ] **Step 7: Run the connection + validation groups**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group connection`
then `--group validation`, `--group effective`, `--group plan_firing`.
Expected: PASS (migrated cases green; 2 new cases green).

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "$(cat <<'EOF'
F4 B4: create_connection_rule/8,/9 carry reciprocal_nref (supersede Phase A /7,/8)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `effective_connection_rules/2` (connection-filtered gather + content spec)

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: `apps/graphdb/test/graphdb_rules_SUITE.erl`

The seam B4's firing engine consumes (mirrors how composition firing consumes
`plan_composition_firing/2`). Reuses the existing `effective_rules/2` gather,
filters to the ConnectionRule meta-class, and decodes each rule's content AVPs
into a `ConnSpec` map. Runs inside the gen_server (has the meta-class + attr
nrefs in state).

- [ ] **Step 1: Write the failing test**

Add to the `effective` group (export + group entry):

```erlang
effective_connection_rules_returns_specs(_Config) ->
	Source = make_class("Car"),
	Target = make_class("Manufacturer"),
	{Char, Recip} = make_rel_pair("made_by", "manufactures"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Source, Char, Recip, Target,
		mandatory, {1, 1}),
	{ok, Triples} = graphdb_rules:effective_connection_rules(environment, Source),
	[{RuleNode, Deploy, Spec}] = Triples,
	?assertEqual(RuleNref, RuleNode#node.nref),
	?assertEqual(mandatory, maps:get(mode, Deploy)),
	?assertEqual({1, 1}, maps:get(multiplicity, Deploy)),
	?assertEqual(Char,  maps:get(characterization, Spec)),
	?assertEqual(Recip, maps:get(reciprocal, Spec)),
	?assertEqual(Target, maps:get(target_class, Spec)).

effective_connection_rules_excludes_composition(_Config) ->
	Parent = make_class("Engine"),
	Child  = make_class("Cylinder"),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "EC", Parent, Child, mandatory, {1, 1}),
	%% a composition rule must NOT appear among connection rules
	?assertEqual({ok, []},
		graphdb_rules:effective_connection_rules(environment, Parent)).

effective_connection_rules_project_scope_empty(_Config) ->
	Source = make_class("Car"),
	?assertEqual({ok, []},
		graphdb_rules:effective_connection_rules({project, p1}, Source)).
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --case effective_connection_rules_returns_specs`
Expected: FAIL — `undef` (function not exported).

- [ ] **Step 3: Add the public API**

In the export list, after `effective_rules_for_class/2,`:

```erlang
		effective_connection_rules/2,
```

Add the public function after `effective_rules_for_class/2`:

```erlang
%%-----------------------------------------------------------------------------
%% effective_connection_rules(Scope, ClassNref) ->
%%     {ok, [{RuleNode :: #node{}, Deployment :: map(),
%%            ConnSpec :: #{characterization := integer(),
%%                          reciprocal := integer(),
%%                          target_class := integer()}}]}
%%
%% The effective rules of ClassNref (self + taxonomy ancestors, nearest-first;
%% B1) filtered to the ConnectionRule meta-class, each paired with its applies_to
%% deployment and a ConnSpec decoded from the rule node's content AVPs.  The B4
%% firing engine consumes this during create_instance.  Additive — a rule reached
%% from two ancestors appears twice (precedence is B5).  {project, _} -> {ok, []}.
%%-----------------------------------------------------------------------------
effective_connection_rules(Scope, ClassNref) ->
	gen_server:call(?MODULE, {effective_connection_rules, Scope, ClassNref}).
```

- [ ] **Step 4: Add the handle_call clauses**

After the `{effective_rules_for_class, {project, _}, _}` clause:

```erlang
handle_call({effective_connection_rules, environment, ClassNref}, _From, State) ->
	{reply, {ok, connection_specs(ClassNref, State)}, State};
handle_call({effective_connection_rules, {project, _}, _}, _From, State) ->
	{reply, {ok, []}, State};
```

- [ ] **Step 5: Add the internal helpers**

After `composition_pairs/2` (or beside `is_composition_rule/2`):

```erlang
%% connection_specs(ClassNref, State) -> [{#node{}, Deployment, ConnSpec}]
%% Effective rules (self + ancestors, nearest-first) filtered to ConnectionRule,
%% each paired with its deployment and decoded content spec.  Order preserved.
connection_specs(ClassNref, State) ->
	[ {RuleNode, Deploy, connection_spec(RuleNode, State)}
	  || {_Level, Pairs} <- effective_rules(ClassNref, State),
		 {RuleNode, Deploy} <- Pairs,
		 is_connection_rule(RuleNode, State) ].

%% is_connection_rule(Node, State) -> boolean()
is_connection_rule(#node{classes = Classes}, State) ->
	lists:member(State#state.connection_rule_nref, Classes).

%% connection_spec(RuleNode, State) -> #{characterization, reciprocal, target_class}
connection_spec(RuleNode, State) ->
	#{characterization =>
		  content_avp_value(RuleNode, State#state.characterization_nref_attr),
	  reciprocal =>
		  content_avp_value(RuleNode, State#state.reciprocal_nref_attr),
	  target_class =>
		  content_avp_value(RuleNode, State#state.target_class_nref_attr)}.
```

- [ ] **Step 6: Run the new cases**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group effective`
Expected: PASS (3 new cases green).

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "$(cat <<'EOF'
F4 B4: effective_connection_rules/2 — connection-filtered gather + content spec

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4a: Thread the context map (behaviour-preserving refactor)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**No new test — the entire existing suite staying green is the gate** (like
B-prep Task 1). This task bundles the soon-to-be-threaded state into a single
`Ctx` map and adds `create_instance/4` wired to a defer-all `report_only`
resolver, so `create_instance/3` is exactly `/4` with `report_only`. RESOLVE is
NOT added here (Task 4b); behaviour is identical.

- [ ] **Step 1: Add `create_instance/4` + `report_only`**

Add `create_instance/4` to the exports (after `create_instance/3,`). Replace the
`create_instance/3` clause:

```erlang
create_instance(Name, ClassNref, ParentNref) ->
	create_instance(Name, ClassNref, ParentNref, fun report_only/1).

%%-----------------------------------------------------------------------------
%% create_instance(Name, ClassNref, ParentNref, Resolver) ->
%%     {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%%
%% As /3, but threads a connection Resolver (B4).  /3 uses the built-in
%% report_only resolver (defer-all): every connection rule surfaces as a report
%% outcome and nothing is connected.
%%-----------------------------------------------------------------------------
create_instance(Name, ClassNref, ParentNref, Resolver)
		when is_function(Resolver, 1) ->
	gen_server:call(?MODULE,
		{create_instance, Name, ClassNref, ParentNref, Resolver}).

%% report_only(ConnContext) -> defer   (the built-in /3 resolver, B4-D2)
report_only(_Ctx) -> defer.
```

- [ ] **Step 2: Build the Ctx map in handle_call**

Replace the `{create_instance, …}` handle_call clause:

```erlang
handle_call({create_instance, Name, ClassNref, ParentNref, Resolver}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	Ctx = #{inst_attr => InstAttr, on_path => [], resolver => Resolver,
			root_parent => ParentNref, root_source => undefined},
	{reply, do_create_instance(Name, ClassNref, ParentNref, Ctx), State};
```

- [ ] **Step 3: Collapse `do_create_instance/5` to `/4` (Ctx)**

```erlang
%% do_create_instance(Name, ClassNref, ParentNref, Ctx)
%%     -> {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%% Ctx carries inst_attr, on_path, resolver, and the stable root_parent /
%% root_source anchors (B4-D2a).  Every cascade level flows through here.
do_create_instance(Name, ClassNref, ParentNref, Ctx) ->
	InstAttr = maps:get(inst_attr, Ctx),
	case do_validate_class(ClassNref, InstAttr) of
		ok ->
			case do_validate_parent(ParentNref) of
				ok              -> fire_create(Name, ClassNref, ParentNref, Ctx);
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.
```

- [ ] **Step 4: Thread Ctx through `fire_create` + bind root_source**

```erlang
fire_create(Name, ClassNref, ParentNref, Ctx) ->
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref) of
		{ok, PlanTree} ->
			case execute(Name, ClassNref, ParentNref, Ctx, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan} ->
					Ctx1 = bind_root_source(Ctx, RootNref),
					AutoReport    = fire_auto(InstPlan, Ctx1),
					ProposeReport = fire_propose(InstPlan, maps:get(on_path, Ctx1)),
					{ok, RootNref,
					 merge_reports(merge_reports(MandOutcomes, AutoReport),
								   ProposeReport)};
				{error, R, Report} ->
					{error, R, Report}
			end;
		{error, R, Failure} ->
			{error, R, report_not_attempted(R, Failure)}
	end.

%% bind_root_source(Ctx, RootNref) -> Ctx'
%% At the top level root_source is undefined -> bind it to the freshly allocated
%% root nref; for a threaded descendant it is already set and kept unchanged.
bind_root_source(Ctx, RootNref) ->
	case maps:get(root_source, Ctx) of
		undefined -> Ctx#{root_source => RootNref};
		_         -> Ctx
	end.
```

`execute/5` keeps its current 4-tuple return in 4a — change only its signature
to accept `Ctx` (ignored except that 4b will use it). Replace its head:

```erlang
execute(RootName, _RootClass, RootParent, _Ctx, PlanTree) ->
```

and update `fire_create`'s call (already shown) plus the body unchanged.

- [ ] **Step 5: Thread Ctx through `fire_auto`**

`fire_auto/2`, `fire_one_auto/5`, `fire_auto_children/8` currently carry
`OnPath`/`OnPath1`. Replace `OnPath` with `Ctx` and rebind `on_path` as the walk
descends; the recursive create now passes the **same** Ctx (resolver +
root anchors invariant, on_path rebound). The `inst_attr` is carried unchanged —
equivalent to the old `undefined`, because `fire_one_auto` already gates
instantiability before recursing, so `do_validate_class` is only reached for
instantiable children.

```erlang
fire_auto(#{nref := Nref, class := Class, auto_rules := Autos,
			mandatory_children := Kids}, Ctx) ->
	Ctx1 = push_on_path(Ctx, Class),
	Here = lists:foldl(
		fun({RuleNode, Deploy}, Acc) ->
			fire_one_auto(RuleNode, Deploy, Nref, Ctx1, Acc)
		end, [], Autos),
	lists:foldl(
		fun(Child, Acc) -> merge_reports(Acc, fire_auto(Child, Ctx1)) end,
		Here, Kids).

%% push_on_path(Ctx, ClassNref) -> Ctx' with ClassNref prepended to on_path
push_on_path(Ctx, ClassNref) ->
	Ctx#{on_path => [ClassNref | maps:get(on_path, Ctx)]}.

fire_one_auto(RuleNode, Deploy, OwnerNref, Ctx, Acc) ->
	ChildClass = graphdb_rules:rule_child_class(RuleNode),
	case graphdb_class:is_instantiable(ChildClass) of
		false ->
			add_outcome(Acc, RuleNode, Deploy,
				#{owner => OwnerNref, index => 1, status => failed,
				  reason => {class_not_instantiable, ChildClass}});
		_ ->
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case lists:member(ChildClass, maps:get(on_path, Ctx)) of
				true  -> Acc;
				false -> fire_auto_children(RuleNode, Deploy, ChildClass,
									Min, 1, OwnerNref, Ctx, Acc)
			end
	end.

fire_auto_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _Owner, _Ctx, Acc)
		when I > Mult ->
	Acc;
fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I, OwnerNref, Ctx, Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Mult),
	Acc2 = case do_create_instance(Name, ChildClass, OwnerNref, Ctx) of
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
		{error, R} ->
			add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => failed,
					  reason => R})
	end,
	fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OwnerNref,
					   Ctx, Acc2).
```

`fire_propose/2` is **unchanged** — propose composition does not consult the
resolver. It keeps taking the on_path list (passed as `maps:get(on_path, Ctx1)`
from `fire_create`).

- [ ] **Step 6: Compile and run the WHOLE suite**

Run: `./rebar3 compile` (expect zero warnings), then
`make test-ct-parallel FILTER=instance` and `make test-ct-parallel FILTER=rules`,
then the EUnit: `./rebar3 eunit`.
Expected: **all green, zero warnings** — this is the behaviour-preserving gate.
If anything is red, the threading changed behaviour; fix before proceeding.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "$(cat <<'EOF'
F4 B4: thread connection context map; add create_instance/4 (report_only default)

Behaviour-preserving refactor: bundles inst_attr/on_path/resolver/root anchors
into one Ctx map. create_instance/3 = /4 with the defer-all report_only resolver.
No RESOLVE yet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4b: RESOLVE defer-path + outcome rendering + `summarize/1` extension

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Test: `apps/graphdb/test/graphdb_instance_tests.erl`

Insert the RESOLVE step into `execute` and implement the **defer / propose**
branches of `resolve_rules/4` (no writes, no validation — those are Tasks 5/6).
After this task, a class with connection rules is creatable via `/3`; the rules
surface as `required` (mandatory), `not_connected` (auto), or `proposed`
(propose) outcomes, and nothing is connected.

- [ ] **Step 1: Write the failing tests**

Add to the `firing` group in `groups/0` and to the export list (do **not** add
them to `setup_firing_fixtures`'s `FiringTests` — these cases build their own
classes). Add a local resolver/arc helper section at the bottom of the suite:

```erlang
%% --- B4 helpers ---------------------------------------------------------

%% make a (Source, Target, Char, Recip) connection fixture; returns nrefs.
b4_conn_classes(SrcName, TgtName, Fwd, Rev) ->
	{ok, Src} = graphdb_class:create_class(SrcName, 3),
	{ok, Tgt} = graphdb_class:create_class(TgtName, 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair(Fwd, Rev, instance),
	{Src, Tgt, Char, Recip}.

%% make a pre-existing target instance of class Tgt, parented at Projects (5).
b4_target_instance(Name, Tgt) ->
	{ok, Nref, _} = graphdb_instance:create_instance(Name, Tgt, 5),
	Nref.

%% the single connection outcome in a report (asserts exactly one rule, one out).
b4_single_outcome(Report) ->
	[#{outcomes := [Outcome]}] = Report,
	Outcome.

%% outgoing connection arc targets from Source with characterization Char.
b4_conn_targets(Source, Char) ->
	Arcs = mnesia:dirty_index_read(relationships, Source,
								   #relationship.source_nref),
	[A#relationship.target_nref || A <- Arcs,
	 A#relationship.kind =:= connection,
	 A#relationship.characterization =:= Char].
```

Add the cases:

```erlang
%% /3 report-only: a mandatory connection rule surfaces as `required`, nothing
%% connected, create succeeds (the /3 mandatory escape, B4-D4).
firing_conn_report_only_mandatory(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assert(is_integer(Root)),                          %% create succeeded
	?assertEqual([], b4_conn_targets(Root, Char)),      %% nothing connected
	O = b4_single_outcome(Report),
	?assertEqual(required, maps:get(status, O)),
	?assertEqual(Root, maps:get(source, O)),
	?assertEqual(Char, maps:get(characterization, O)),
	?assertEqual(Tgt,  maps:get(target_class, O)),
	?assertTrue(not maps:is_key(target, O)).            %% no target on a non-connect

firing_conn_report_only_auto(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assertEqual(not_connected, maps:get(status, b4_single_outcome(Report))).

firing_conn_report_only_propose(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, propose, {1, 1}),
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(proposed, maps:get(status, b4_single_outcome(Report))).

%% /4 with an explicit defer-all resolver behaves exactly like /3 report-only.
firing_conn_explicit_defer(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> defer end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(required, maps:get(status, b4_single_outcome(Report))).

%% summarize counts the connection statuses alongside the composition ones.
firing_conn_summarize(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, _Root, Report} = graphdb_instance:create_instance("car1", Src, 5),
	S = graphdb_instance:summarize(Report),
	?assertEqual(1, maps:get(required, S)),
	?assertEqual(0, maps:get(connected, S)),
	?assertEqual(0, maps:get(not_connected, S)).
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case firing_conn_report_only_mandatory`
Expected: FAIL — no `required` outcome is produced (RESOLVE not wired).

- [ ] **Step 3: Insert RESOLVE into `execute`**

Replace `execute/5` (now taking `Ctx`) with the full RESOLVE-aware version. Note
its return arity grows to a **5-tuple** `{ok, RootNref, Outcomes, InstPlan,
AutoConnPlan}`; update `fire_create`'s match accordingly (Step 5):

```erlang
execute(RootName, _RootClass, RootParent, Ctx, PlanTree) ->
	InstPlan = allocate_plan(PlanTree#{name => RootName}),
	{Writes, CompOutcomes} = plan_writes(InstPlan, RootParent),
	RootNref = maps:get(nref, InstPlan),
	Ctx1 = bind_root_source(Ctx, RootNref),
	case resolve_connections(InstPlan, Ctx1) of
		{ok, MandRows, AutoConnPlan, ConnReport} ->
			Txn = fun() ->
				lists:foreach(
					fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					Writes ++ MandRows)
			end,
			case mnesia:transaction(Txn) of
				{atomic, ok} ->
					{ok, RootNref,
					 merge_reports(CompOutcomes, ConnReport),
					 InstPlan, AutoConnPlan};
				{aborted, R} ->
					{error, R,
					 report_not_attempted(R,
						#{plan_so_far => PlanTree, culprit => undefined})}
			end;
		{error, Reason, ConnReport} ->
			%% Mandatory-connection shortfall in RESOLVE: nothing written (we
			%% never entered the txn).  Composition subtree becomes
			%% not_attempted; the connection culprit/siblings are in ConnReport.
			CompNA = report_not_attempted(Reason,
				#{plan_so_far => InstPlan, culprit => undefined}),
			{error, Reason, merge_reports(CompNA, ConnReport)}
	end.
```

- [ ] **Step 4: Add the RESOLVE walk (defer / propose branches only)**

Add a new section (place it near the firing helpers):

```erlang
%%=============================================================================
%% Connection Firing — RESOLVE (B4)
%%=============================================================================

%% resolve_connections(InstPlan, Ctx)
%%   -> {ok, MandRows, AutoConnPlan, ConnReport}
%%    | {error, Reason, ConnReport}
%% Walks the instantiated plan tree (root + mandatory composition descendants)
%% pre-order; for each instance consults its effective connection rules.  In this
%% task only the defer/propose branches are implemented (no writes); Tasks 5/6
%% add the {connect, List} mandatory/auto branches.
resolve_connections(InstPlan, Ctx) ->
	Nodes = flatten_plan(InstPlan),
	resolve_nodes(Nodes, Ctx, {[], [], []}).

%% flatten_plan(InstPlanNode) -> [{Nref, ClassNref}]  (root first, pre-order)
flatten_plan(#{nref := N, class := C, mandatory_children := Kids}) ->
	[{N, C} | lists:flatmap(fun flatten_plan/1, Kids)].

%% resolve_nodes(Nodes, Ctx, {MandRows, AutoPlan, Report})
%% Rows/Auto/Report all accumulate in forward order (the connect branches append),
%% so no reversal is needed; Mnesia write order within the txn is irrelevant.
resolve_nodes([], _Ctx, {Rows, Auto, Rep}) ->
	{ok, Rows, Auto, Rep};
resolve_nodes([{SourceNref, Class} | Rest], Ctx, Acc) ->
	{ok, ConnRules} = graphdb_rules:effective_connection_rules(?RULE_SCOPE, Class),
	case resolve_rules(ConnRules, SourceNref, Ctx, Acc) of
		{ok, Acc1}          -> resolve_nodes(Rest, Ctx, Acc1);
		{error, _, _} = Err -> Err
	end.

%% resolve_rules(Rules, SourceNref, Ctx, Acc) -> {ok, Acc'} | {error, R, Report}
%% Acc = {MandRows, AutoPlan, Report}.  First-failure-aborts (mirrors plan_rules).
resolve_rules([], _SourceNref, _Ctx, Acc) ->
	{ok, Acc};
resolve_rules([{Rule, Deploy, Spec} | Rest], SourceNref, Ctx, Acc) ->
	Mode = maps:get(mode, Deploy, mandatory),
	case Mode of
		propose ->
			%% propose connection rules are advisory: surface `proposed`, never
			%% consult the resolver, never connect (mirrors B3 propose).
			Acc1 = add_conn_outcome(Acc, Rule, Deploy,
				conn_outcome_base(SourceNref, Spec, proposed)),
			resolve_rules(Rest, SourceNref, Ctx, Acc1);
		_ ->
			Resolver = maps:get(resolver, Ctx),
			case Resolver(conn_context(Rule, Deploy, Spec, SourceNref, Ctx)) of
				defer ->
					Status = case Mode of
								 mandatory -> required;
								 auto      -> not_connected
							 end,
					Acc1 = add_conn_outcome(Acc, Rule, Deploy,
						conn_outcome_base(SourceNref, Spec, Status)),
					resolve_rules(Rest, SourceNref, Ctx, Acc1)
				%% {connect, List} clause added in Tasks 5 (mandatory) and 6 (auto)
			end
	end.

%% conn_context(Rule, Deploy, Spec, SourceNref, Ctx) -> ConnContext (B4-D2/D2a)
conn_context(Rule, Deploy, Spec, SourceNref, Ctx) ->
	#{rule             => Rule,
	  characterization => maps:get(characterization, Spec),
	  reciprocal       => maps:get(reciprocal, Spec),
	  target_class     => maps:get(target_class, Spec),
	  mode             => maps:get(mode, Deploy, mandatory),
	  multiplicity     => maps:get(multiplicity, Deploy, {1, 1}),
	  source           => SourceNref,
	  root_parent      => maps:get(root_parent, Ctx),
	  root_source      => maps:get(root_source, Ctx)}.

%% conn_outcome_base(SourceNref, Spec, Status) -> connection_outcome()
%% The shared shape for non-connect outcomes (required/not_connected/proposed):
%% index 1, no target.
conn_outcome_base(SourceNref, Spec, Status) ->
	#{source => SourceNref, index => 1, status => Status,
	  characterization => maps:get(characterization, Spec),
	  target_class => maps:get(target_class, Spec)}.

%% add_conn_outcome({Rows, Auto, Rep}, Rule, Deploy, Outcome) -> Acc'
add_conn_outcome({Rows, Auto, Rep}, Rule, Deploy, Outcome) ->
	{Rows, Auto, add_outcome(Rep, Rule, Deploy, Outcome)}.
```

- [ ] **Step 5: Update `fire_create` for the 5-tuple + empty auto plan**

In `fire_create`, change the success match and merge in the (empty for now)
post-commit connection report:

```erlang
			case execute(Name, ClassNref, ParentNref, Ctx, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan, AutoConnPlan} ->
					Ctx1 = bind_root_source(Ctx, RootNref),
					AutoReport     = fire_auto(InstPlan, Ctx1),
					ProposeReport  = fire_propose(InstPlan, maps:get(on_path, Ctx1)),
					ConnAutoReport = fire_connections(AutoConnPlan),
					Merged = merge_reports(
						merge_reports(
							merge_reports(MandOutcomes, AutoReport),
							ProposeReport),
						ConnAutoReport),
					{ok, RootNref, Merged};
				{error, R, Report} ->
					{error, R, Report}
			end;
```

Add the post-commit auto-connection writer as a **no-op for now** (Task 6 fills
the body):

```erlang
%% fire_connections(AutoConnPlan) -> report()
%% POST-COMMIT best-effort writer for `auto` connections (B4).  Empty until B4
%% Task 6; an empty plan yields an empty report.
fire_connections([]) ->
	[].
```

- [ ] **Step 6: Extend `summarize/1` + migrate existing assertions**

Replace `summarize/1`:

```erlang
summarize(Report) ->
	Outs = [O || #{outcomes := Os} <- Report, O <- Os],
	Count = fun(S) -> length([1 || #{status := X} <- Outs, X =:= S]) end,
	#{fired => Count(fired), failed => Count(failed),
	  not_attempted => Count(not_attempted), proposed => Count(proposed),
	  connected => Count(connected), required => Count(required),
	  not_connected => Count(not_connected)}.
```

This **breaks** the existing 4-key `summarize/1` equality assertions. Migrate
each to the 7-key map (add `connected => 0, required => 0, not_connected => 0`):
in `graphdb_instance_SUITE.erl` — `firing_auto_best_effort`,
`firing_auto_failure_survives`, `firing_auto_cascade_merges`,
`firing_propose_summarize` (grep `summarize(` to find all); and any
`summarize/1` assertion in `graphdb_instance_tests.erl`. Example migration:

```erlang
	?assertEqual(#{fired => 1, failed => 0, not_attempted => 0, proposed => 0,
				   connected => 0, required => 0, not_connected => 0},
				 graphdb_instance:summarize(Report)).
```

- [ ] **Step 7: Run the new B4 cases + the migrated suite**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --group firing`
then `./rebar3 eunit --module graphdb_instance_tests`.
Expected: PASS (5 new B4 cases green; migrated `summarize` assertions green).

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_instance_tests.erl
git commit -m "$(cat <<'EOF'
F4 B4: RESOLVE defer-path + connection outcome rendering; summarize/1 7-key

create_instance now surfaces effective connection rules as report outcomes
(required/not_connected/proposed); /3 report-only escape works. No writes yet.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Resolver commit path — mandatory enforcement in the root txn

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

Add the `{connect, List}` branch of `resolve_rules/4` for **mandatory** rules:
validate targets (B4-D6), enforce the `{Min, Max}` floor/cap (B4-D5), build the
arc rows, and write them in the **root transaction** (B4-D4). A shortfall or an
invalid target on a committed mandatory rule **aborts RESOLVE** before the txn —
nothing written.

- [ ] **Step 1: Write the failing tests**

Add (export + `firing` group; not in `FiringTests`):

```erlang
%% mandatory + committing resolver: arc pair written in the root txn; outcome
%% `connected`; reverse arc reaches the source.
firing_conn_mandatory_connected(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Target = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Target]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([Target], b4_conn_targets(Root, Char)),       %% forward arc
	?assertEqual([Root], b4_conn_targets(Target, Recip)),      %% reverse arc
	O = b4_single_outcome(Report),
	?assertEqual(connected, maps:get(status, O)),
	?assertEqual(Target, maps:get(target, O)),
	?assertEqual(Root,   maps:get(source, O)).

%% mandatory shortfall: resolver commits an empty list (< Min=1) -> create fails,
%% nothing written.
firing_conn_mandatory_shortfall_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, RuleNref} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, []} end,
	Before = mnesia:table_info(nodes, size),
	{error, {mandatory_connection_unsatisfied, RuleNref}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)),      %% nothing written
	?assert(lists:any(
		fun(#{outcomes := Os}) ->
			lists:any(fun(#{status := S}) -> S =:= failed end, Os)
		end, Report)).

%% mandatory + invalid target (wrong class) -> create fails, nothing written.
firing_conn_mandatory_invalid_target_fails(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	{ok, Other} = graphdb_class:create_class("Other", 3),
	Wrong = b4_target_instance("wrong", Other),               %% not a Mfr
	R = fun(_Ctx) -> {connect, [Wrong]} end,
	Before = mnesia:table_info(nodes, size),
	{error, {invalid_connection_target, _}, _Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%% multiplicity {1,2}: resolver returns 3 valid -> exactly 2 written (cap=Max).
firing_conn_mandatory_caps_at_max(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, mandatory, {1, 2}),
	T1 = b4_target_instance("m1", Tgt),
	T2 = b4_target_instance("m2", Tgt),
	T3 = b4_target_instance("m3", Tgt),
	R = fun(_Ctx) -> {connect, [T1, T2, T3]} end,
	{ok, Root, _Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(2, length(b4_conn_targets(Root, Char))).

%% rollback cause is discriminable: a class carrying BOTH a mandatory composition
%% rule (abstract child) and a mandatory connection rule.  The composition
%% shortfall aborts in PLAN, before RESOLVE -> culprit is a composition outcome
%% (has `child`/no `target`) and no connection outcome was produced.
firing_conn_rollback_discriminable_composition(_Config) ->
	{ok, InstAttr} = b4_inst_attr(),
	{ok, Src}      = graphdb_class:create_class("Car", 3),
	{ok, Abstract} = graphdb_class:create_class("Abs", 3,
		[#{attribute => InstAttr, value => false}]),
	{ok, Tgt}      = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by","makes",instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CA", Src, Abstract, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CM", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	Mfr = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Mfr]} end,
	{error, {class_not_instantiable, Abstract}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	%% the lone failed outcome is a COMPOSITION culprit: carries no connection keys
	Failed = [O || #{outcomes := Os} <- Report, #{status := failed} = O <- Os],
	?assertEqual(1, length(Failed)),
	[F] = Failed,
	?assertNot(maps:is_key(target, F)),
	?assertNot(maps:is_key(characterization, F)).

%% the mirror case: composition planned cleanly, connection shortfall aborts in
%% RESOLVE -> culprit is a CONNECTION outcome (carries characterization), and the
%% composition outcomes are all not_attempted.
firing_conn_rollback_discriminable_connection(_Config) ->
	{ok, Src} = graphdb_class:create_class("Car", 3),
	{ok, Bolt} = graphdb_class:create_class("Bolt", 3),
	{ok, Tgt}  = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by","makes",instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "CB", Src, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "CM", Src, Char, Recip, Tgt, mandatory, {1, 1}),
	R = fun(_Ctx) -> {connect, []} end,                  %% shortfall
	Before = mnesia:table_info(nodes, size),
	{error, {mandatory_connection_unsatisfied, _}, Report} =
		graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual(Before, mnesia:table_info(nodes, size)),
	%% lone failed outcome is a CONNECTION culprit (has characterization);
	%% the composition Bolt rule is not_attempted.
	Failed = [O || #{outcomes := Os} <- Report, #{status := failed} = O <- Os],
	[F] = Failed,
	?assert(maps:is_key(characterization, F)),
	?assert(lists:any(
		fun(#{outcomes := Os}) ->
			lists:any(fun(#{status := S}) -> S =:= not_attempted end, Os)
		end, Report)).

%% a mandatory connection rule on a mandatory COMPOSITION descendant fires in the
%% same root txn; outcome source = the descendant nref.
firing_conn_descendant_in_root_txn(_Config) ->
	{ok, Owner} = graphdb_class:create_class("Owner", 3),
	{ok, Bolt}  = graphdb_class:create_class("Bolt", 3),
	{ok, Tgt}   = graphdb_class:create_class("Mfr", 3),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("made_by","makes",instance),
	{ok, _} = graphdb_rules:create_composition_rule(
		environment, "OB", Owner, Bolt, mandatory, {1, 1}),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "BM", Bolt, Char, Recip, Tgt, mandatory, {1, 1}),
	Mfr = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Mfr]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Owner, 5, R),
	{ok, [BoltInst]} = graphdb_instance:children(Root),
	BoltNref = element(2, BoltInst),
	?assertEqual([Mfr], b4_conn_targets(BoltNref, Char)),
	%% the connected outcome's source is the Bolt descendant, not the root
	Connected = [O || #{outcomes := Os} <- Report,
					  #{status := connected} = O <- Os],
	[C] = Connected,
	?assertEqual(BoltNref, maps:get(source, C)).
```

Add a tiny helper:

```erlang
b4_inst_attr() ->
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	{ok, InstAttr}.
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case firing_conn_mandatory_connected`
Expected: FAIL — `function_clause` in `resolve_rules` (no `{connect, …}` clause).

- [ ] **Step 3: Extract `build_connection_rows/6`**

Refactor `write_connection_arcs/6` so the row-builder is reusable inside the root
txn (no nested transaction). Replace it with:

```erlang
%% build_connection_rows(S, C, T, R, TemplateNref, {FwdAVPs, RevAVPs})
%%   -> [{relationships, #relationship{}}]
%% Builds the two directed connection rows (Template AVP at index 0).  Rel-ids
%% are allocated here, OUTSIDE any transaction (L10).  No write — the caller
%% decides which transaction the rows land in.
build_connection_rows(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, {FwdAVPs, RevAVPs}) ->
	{Id1, Id2} = rel_id_server:get_id_pair(),
	TemplateAVP = #{attribute => ?ARC_TEMPLATE, value => TemplateNref},
	Fwd = #relationship{
		id = Id1, kind = connection,
		source_nref = SourceNref, characterization = CharNref,
		target_nref = TargetNref, reciprocal = ReciprocalNref,
		avps = [TemplateAVP | FwdAVPs]},
	Rev = #relationship{
		id = Id2, kind = connection,
		source_nref = TargetNref, characterization = ReciprocalNref,
		target_nref = SourceNref, reciprocal = CharNref,
		avps = [TemplateAVP | RevAVPs]},
	[{relationships, Fwd}, {relationships, Rev}].

%% write_connection_arcs/6 — used by add_relationship/4,5,6 (its own txn) and by
%% the post-commit auto-connection pass.  Now a thin wrapper over the builder.
write_connection_arcs(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	Rows = build_connection_rows(SourceNref, CharNref, TargetNref,
								 ReciprocalNref, TemplateNref, AVPSpec),
	Txn = fun() ->
		lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					  Rows)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 4: Add target validation (B4-D6)**

```erlang
%% validate_target(Target, TargetClass, _SourceNref) -> ok | {error, Reason}
%% Target is a bare nref or {Nref, {Fwd, Rev}}.  Valid iff the nref exists, is a
%% kind=instance node, and is an instance of TargetClass or a subclass of it.
%% No self-check is needed: the source is uncommitted at RESOLVE, so a readable
%% instance is necessarily distinct from it (B4-D6).
validate_target(Target, TargetClass, _SourceNref) ->
	Nref = target_nref(Target),
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = instance, classes = Classes}] ->
			case lists:any(
					fun(C) -> graphdb_class:class_in_ancestry(TargetClass, C) end,
					Classes) of
				true  -> ok;
				false -> {error, {target_class_mismatch, Nref, TargetClass}}
			end;
		[#node{}] -> {error, {target_not_an_instance, Nref}};
		[]        -> {error, {target_not_found, Nref}}
	end.

%% target_nref(Target) -> integer()
target_nref(Nref) when is_integer(Nref)     -> Nref;
target_nref({Nref, {_F, _R}}) when is_integer(Nref) -> Nref.

%% target_avps(Target) -> {FwdAVPs, RevAVPs}
target_avps(Nref) when is_integer(Nref) -> {[], []};
target_avps({_Nref, {Fwd, Rev}})        -> {Fwd, Rev}.
```

`class_in_ancestry(TargetClass, C)` is true iff `C =:= TargetClass` **or**
`TargetClass` is an ancestor of `C` — i.e. `C` is `TargetClass` or a subclass of
it. Exactly B4-D6.

- [ ] **Step 5: Add the `{connect, List}` mandatory branch to `resolve_rules`**

Extend the `defer`-only `case Resolver(...)` with the `{connect, List}` clause.
In this task the branch handles **mandatory** mode only (validate-and-abort,
build root-txn rows, emit tentative `connected` outcomes). `connect_targets/9`
has a single `mandatory` clause here; Task 6 adds its `auto` clause. (Task 5
tests never drive an auto rule down the `{connect, …}` path, so the missing
`auto` clause is never reached.)

```erlang
				{connect, List} ->
					connect_targets(Mode, List, Rule, Deploy, Spec, SourceNref,
									Rest, Ctx, Acc)
			end
	end.

%% connect_targets(Mode, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx, Acc)
%%   -> {ok, Acc'} | {error, Reason, Report}
%% Validates targets, applies the {Min, Max} range, and routes by mode.  In B4
%% Task 5 only `mandatory` is implemented; `auto` is added in Task 6.
connect_targets(mandatory, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx,
		{Rows, Auto, Rep} = _Acc) ->
	TClass = maps:get(target_class, Spec),
	case partition_targets(List, TClass, SourceNref) of
		{error, Reason} ->
			%% an invalid target on a committed mandatory rule aborts the create
			{error, {invalid_connection_target, Reason},
			 conn_fail({invalid_connection_target, Reason}, Rule, Spec, Rep)};
		{ok, Valid} ->
			{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case length(Valid) < Min of
				true ->
					Reason = {mandatory_connection_unsatisfied,
							  Rule#node.nref},
					{error, Reason, conn_fail(Reason, Rule, Spec, Rep)};
				false ->
					ToWrite = cap(Valid, Max),
					Template = maps:get(template, Deploy),
					{NewRows, NewOuts} =
						mandatory_rows(ToWrite, SourceNref, Spec, Template),
					Rep1 = lists:foldl(
						fun(O, R) -> add_outcome(R, Rule, Deploy, O) end,
						Rep, NewOuts),
					resolve_rules(Rest, SourceNref, Ctx,
								  {Rows ++ NewRows, Auto, Rep1})
			end
	end.

%% partition_targets(List, TargetClass, SourceNref) ->
%%     {ok, [Target]} | {error, Reason}
%% For a MANDATORY rule: the first invalid target aborts with its reason; an
%% all-valid list returns the (order-preserved) valid targets.
partition_targets([], _TClass, _SourceNref) ->
	{ok, []};
partition_targets([T | Rest], TClass, SourceNref) ->
	case validate_target(T, TClass, SourceNref) of
		ok ->
			case partition_targets(Rest, TClass, SourceNref) of
				{ok, Vs}         -> {ok, [T | Vs]};
				{error, _} = Err -> Err
			end;
		{error, Reason} ->
			{error, Reason}
	end.

%% cap(List, Max) -> List'  (truncate to at most Max; unbounded keeps all)
cap(List, unbounded) -> List;
cap(List, Max)       -> lists:sublist(List, Max).

%% mandatory_rows(Targets, SourceNref, Spec, Template) -> {Rows, Outcomes}
%% Builds the connection rows for each target plus a (tentative) `connected`
%% outcome indexed 1..N.  Outcomes are returned to the report only on commit.
mandatory_rows(Targets, SourceNref, Spec, Template) ->
	Char  = maps:get(characterization, Spec),
	Recip = maps:get(reciprocal, Spec),
	TClass = maps:get(target_class, Spec),
	{Rows, Outs, _} = lists:foldl(
		fun(T, {RAcc, OAcc, I}) ->
			TNref = target_nref(T),
			Rows0 = build_connection_rows(SourceNref, Char, TNref, Recip,
										  Template, target_avps(T)),
			Out = #{source => SourceNref, index => I, status => connected,
					target => TNref, characterization => Char,
					target_class => TClass},
			{RAcc ++ Rows0, OAcc ++ [Out], I + 1}
		end, {[], [], 1}, Targets),
	{Rows, Outs}.

%% conn_fail(Reason, CulpritRule, Spec, RepAcc) -> Report
%% Mandatory-connection abort report: every already-emitted connection outcome
%% becomes not_attempted; the culprit gets one `failed` carrying its connection
%% keys (so the rollback cause is discriminable by rule kind, B4-D7).
conn_fail(Reason, CulpritRule, Spec, RepAcc) ->
	NA = [ RR#{outcomes => [#{index => 1, status => not_attempted}
							|| _ <- Os]}
		   || #{outcomes := Os} = RR <- RepAcc ],
	add_outcome(NA, CulpritRule, #{},
		#{index => 1, status => failed, reason => Reason,
		  characterization => maps:get(characterization, Spec),
		  target_class => maps:get(target_class, Spec)}).
```

- [ ] **Step 6: Run the Task-5 cases**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --group firing`
Expected: PASS — the 7 new mandatory/validation/discriminability cases green, all
prior firing cases still green.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "$(cat <<'EOF'
F4 B4: mandatory connection firing — root-txn enforcement, validation, {Min,Max}

Adds the {connect, List} mandatory branch: validate targets (B4-D6), enforce the
Min floor / Max cap (B4-D5), write arc rows in the root transaction (B4-D4).
Shortfall or invalid target aborts before the txn (nothing written). Extracts
build_connection_rows/6 so mandatory rows share the composition root txn.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Auto connection firing — post-commit best-effort

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

Add the **auto** sub-case of `connect_targets`: valid targets are queued into the
`AutoConnPlan` and written **post-commit** (own transactions); invalid targets
become `failed` outcomes and the create survives (B4-D5/D7). The auto floor is
**not** enforced.

- [ ] **Step 1: Write the failing tests**

```erlang
%% auto + committing resolver: target connected post-commit; root survives.
firing_conn_auto_connected(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	Target = b4_target_instance("acme", Tgt),
	R = fun(_Ctx) -> {connect, [Target]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assertEqual([Target], b4_conn_targets(Root, Char)),
	?assertEqual(connected, maps:get(status, b4_single_outcome(Report))).

%% auto + invalid target: survives as a failed outcome; root still created.
firing_conn_auto_invalid_survives(_Config) ->
	{Src, Tgt, Char, Recip} = b4_conn_classes("Car", "Mfr", "made_by", "makes"),
	{ok, _} = graphdb_rules:create_connection_rule(
		environment, "car-made-by", Src, Char, Recip, Tgt, auto, {1, 1}),
	{ok, Other} = graphdb_class:create_class("Other", 3),
	Wrong = b4_target_instance("wrong", Other),
	R = fun(_Ctx) -> {connect, [Wrong]} end,
	{ok, Root, Report} = graphdb_instance:create_instance("car1", Src, 5, R),
	?assert(is_integer(Root)),
	?assertEqual([], b4_conn_targets(Root, Char)),
	?assertEqual(failed, maps:get(status, b4_single_outcome(Report))).
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case firing_conn_auto_connected`
Expected: FAIL — `function_clause` in `connect_targets` (no `auto` clause).

- [ ] **Step 3: Add the auto `connect_targets` clause**

```erlang
connect_targets(auto, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx,
		{Rows, Auto, Rep} = _Acc) ->
	TClass = maps:get(target_class, Spec),
	{Valid, Invalid} = split_valid(List, TClass, SourceNref),
	%% auto does NOT enforce the floor (B4-D5) — Min is ignored; only Max caps.
	{_Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	ToConnect = cap(Valid, Max),
	Template  = maps:get(template, Deploy),
	%% invalid targets are immediate `failed` outcomes (create survives)
	Rep1 = lists:foldl(
		fun({T, Reason}, R) ->
			add_outcome(R, Rule, Deploy,
				#{source => SourceNref, index => 1, status => failed,
				  reason => Reason, characterization => maps:get(characterization, Spec),
				  target_class => TClass})
		end, Rep, Invalid),
	%% valid targets are queued for the post-commit writer
	AutoEntry = #{rule => Rule, deploy => Deploy, spec => Spec,
				  source => SourceNref, template => Template,
				  targets => ToConnect},
	resolve_rules(Rest, SourceNref, Ctx, {Rows, Auto ++ [AutoEntry], Rep1}).

%% split_valid(List, TClass, SourceNref) -> {Valid :: [Target], Invalid :: [{Target, Reason}]}
%% For AUTO: partition rather than abort — invalids are reported, valids written.
split_valid(List, TClass, SourceNref) ->
	lists:foldr(
		fun(T, {Vs, Is}) ->
			case validate_target(T, TClass, SourceNref) of
				ok              -> {[T | Vs], Is};
				{error, Reason} -> {Vs, [{T, Reason} | Is]}
			end
		end, {[], []}, List).
```

- [ ] **Step 4: Fill in `fire_connections/1` (post-commit writer)**

Replace the `fire_connections([]) -> [].` stub with the real best-effort writer:

```erlang
%% fire_connections(AutoConnPlan) -> report()
%% POST-COMMIT best-effort: writes each queued auto connection in its own
%% transaction.  A successful write is a `connected` outcome; a write failure is
%% a `failed` outcome and never rolls the instance back (B4-D4/D7).
fire_connections(AutoConnPlan) ->
	lists:foldl(fun fire_auto_connection/2, [], AutoConnPlan).

fire_auto_connection(#{rule := Rule, deploy := Deploy, spec := Spec,
					   source := SourceNref, template := Template,
					   targets := Targets}, Acc) ->
	Char  = maps:get(characterization, Spec),
	Recip = maps:get(reciprocal, Spec),
	TClass = maps:get(target_class, Spec),
	{_I, Acc1} = lists:foldl(
		fun(T, {I, A}) ->
			TNref = target_nref(T),
			Outcome = case write_connection_arcs(SourceNref, Char, TNref, Recip,
												 Template, target_avps(T)) of
				ok ->
					#{source => SourceNref, index => I, status => connected,
					  target => TNref, characterization => Char,
					  target_class => TClass};
				{error, Reason} ->
					#{source => SourceNref, index => I, status => failed,
					  reason => Reason, characterization => Char,
					  target_class => TClass}
			end,
			{I + 1, add_outcome(A, Rule, Deploy, Outcome)}
		end, {1, Acc}, Targets),
	Acc1.
```

- [ ] **Step 5: Run the Task-6 cases + full firing group**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --group firing`
Expected: PASS (2 new auto cases green; all prior firing cases green).

- [ ] **Step 6: Run the whole graphdb test set + compile**

Run: `./rebar3 compile` (zero warnings), then
`make test-ct-parallel` and `./rebar3 eunit`.
Expected: all green, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "$(cat <<'EOF'
F4 B4: auto connection firing — post-commit best-effort writes

Auto rules queue valid targets into AutoConnPlan, written post-commit in their
own transactions (connected outcome on success, failed on write error). Invalid
auto targets are failed outcomes; the create survives. Floor (Min) is not
enforced for auto (B4-D5).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Documentation + counts

**Files:**
- Modify: `docs/designs/f4-phase-b4-connection-firing-design.md`
- Modify: `docs/designs/f4-graphdb-rules-design.md`
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Mark the B4 design implemented**

In `docs/designs/f4-phase-b4-connection-firing-design.md`, change the **Status**
line from "Specified. No implementation has begun." to a short "Implemented via
PR — see plan `docs/superpowers/plans/2026-06-11-f4-phase-b4-connection-firing.md`."

- [ ] **Step 2: Update the parent rules design**

In `docs/designs/f4-graphdb-rules-design.md`:
- §11 division map: mark **B4** done (parity with B1/B2/B3 rows).
- D6 (ConnectionRule content): add `reciprocal_nref` to the content AVP list.
- Mark **OI-B2-4 RESOLVED by B4** (connection rules now fired by `create_instance`).
- Record **OI-B4-3** (multi-class instance creation) as a candidate division (it
  already exists in the B4 design §7; cross-reference it here).

- [ ] **Step 3: Update `apps/graphdb/CLAUDE.md`**

- `graphdb_rules` bullet list: `create_connection_rule/8,/9` (now with
  reciprocal); add `effective_connection_rules/2`; note the Rule Literals
  sub-group now seeds **8** literals (add `reciprocal_nref`); `seeded_nrefs/0`
  returns thirteen keys.
- `graphdb_instance` bullet list: `create_instance/4` threads a connection
  resolver; `/3` is report-only; connection rules fire at create
  (mandatory in the root txn, auto post-commit, propose/deferred reported).
- The `graphdb_rules` one-line status in the Files table and the "F4 Phases…"
  prose: add B4.

- [ ] **Step 4: Update README test counts**

Run `make test-ct-parallel` and `./rebar3 eunit` and read the **actual** totals.
B4 adds CT cases (rules: +6 [Tasks 1,2,3]; instance: +14 [Tasks 4b,5,6]) and no
new EUnit. Update README's total and the per-suite `graphdb_rules_SUITE` /
`graphdb_instance_SUITE` rows to the measured numbers. **If the runner disagrees
with this estimate, use the measured numbers and note the delta in the commit
message — do not hand-edit to match the estimate.** Re-align any touched
markdown tables with `python3 ~/.claude/scripts/align_md_tables.py README.md`.

- [ ] **Step 5: Final full verification**

Run: `./rebar3 compile`, `make test-ct-parallel`, `./rebar3 eunit`.
Expected: all green, zero warnings; README counts match the runner.

- [ ] **Step 6: Commit**

```bash
git add docs/designs/f4-phase-b4-connection-firing-design.md docs/designs/f4-graphdb-rules-design.md apps/graphdb/CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
F4 B4: docs + test counts — connection firing implemented

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Decision log (pinned for the implementer — do not improvise)

- **Additive, no dedup.** A rule reached from two ancestors fires twice;
  precedence/dedup is B5. Do not add dedup.
- **`/3` mandatory escape.** `report_only` defers every rule; a mandatory rule
  defers → `required`, and the create **succeeds**. Abort happens **only** on
  `{connect, List}` with valid targets `< Min` (or an invalid target on a
  committed mandatory rule). Never abort on `defer`.
- **Stable anchors.** `resolver`, `root_parent`, `root_source` are **invariant**
  down the whole cascade; only `on_path` (and `source`, the firing instance)
  rebind. `root_source` is `undefined` at the top-level entry and bound to the
  allocated root nref inside `execute`, then threaded into `fire_auto`.
- **Phase ordering makes the two failures disjoint.** A mandatory-composition
  shortfall aborts in PLAN (B2, unchanged) **before** RESOLVE runs; a
  mandatory-connection shortfall aborts in RESOLVE **after** composition planned
  cleanly. The lone `failed` outcome's **rule kind** (CompositionRule with
  `child` vs ConnectionRule with `characterization`/`target`) names the cause.
- **propose connection rules are advisory.** Emit `proposed`; never consult the
  resolver; never connect.
- **build_connection_rows allocates outside the txn (L10);** mandatory rows ride
  the composition root txn, auto rows are written post-commit in their own txns.
- **No `graphdb_report` module.** Report helpers stay co-located in
  `graphdb_instance` (OI-B2-5 not triggered — connection firing also runs here).

## Out of scope (do not start)

- B5 horizontal precedence; OI-B4-3 multi-class create; OI-B4-1 ontology
  resolvers; OI-B4-2 reciprocal backlink. Parent-design §B reconciliation.
- A test for the EXECUTE-transaction-abort connection path (a forced Mnesia
  abort) — like B2, that path is implemented (`execute` `{aborted, R}` branch
  renders composition `not_attempted`) but not unit-tested.
