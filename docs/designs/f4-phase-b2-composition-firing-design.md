<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B2 — Composition Firing Engine — Design

**Status:** Specified. No implementation has begun.

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; B1 landed via PR #33). This is the second division of Phase B.
Consumes B1's `effective_rules_for_class/2`
(`docs/designs/f4-phase-b1-effective-rules-design.md`).

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored
Data), §10 (Composition Rules), §9 (Inheritance — compositional
hierarchy).

---

## 1. Scope

### 1.1 Phase B division map

| Div    | Subject                                                                        | Depends on |
| ------ | ------------------------------------------------------------------------------ | ---------- |
| **B1** | `effective_rules_for_class/2` — read-side taxonomy walk (no firing)            | Phase A    |
| **B2** | Composition firing engine — `mandatory` + `auto`; cascade; return-shape change | B1         |
| **B3** | `propose` mode + interactive/non-interactive session flag (`graphdb_query`)    | B2         |
| **B4** | Connection firing engine (Mandatory Connections, §10)                          | B1         |
| **B5** | Horizontal conflict resolution / precedence (OI-2) — rules at one class level  | B2         |

This document specifies **B2 only**.

### 1.2 What B2 delivers

`graphdb_instance:create_instance/3` becomes rule-aware. After the
requested ("root") instance is established, B2 consults the composition
rules effective for its class (via B1) and **materialises child
instances** per each rule's `mode` and `multiplicity`:

- `mandatory` children are created in the **same transaction** as the
  root — all-or-nothing. If a mandatory child cannot be satisfied, the
  whole `create_instance` fails and nothing is written.
- `auto` children are created **best-effort after commit**. An `auto`
  failure is reported, never rolls the root back.
- `propose` is **out of scope** — deferred to **B3**.

Firing cascades: a created child is itself an instance whose class may
carry composition rules, so the engine recurses.

### 1.3 What B2 does NOT do

- **Connection** rules (`graphdb_rules` ConnectionRule) — that is **B4**.
- **`propose`** mode — **B3**.
- **Horizontal conflict resolution / precedence** — when a class and an
  ancestor both carry rules for the same child class, B2 fires **both**
  (additive). Collapsing/precedence is **B5** (OI-2).
- **`add_class_membership/2` firing** — adding a class to an existing
  instance does **not** retroactively fire that class's composition
  rules in B2. Only `create_instance/3` fires. (Deferred; see OI-B2-3.)
- **Project-scoped rules** — B1 returns `{ok, []}` for `{project, _}`;
  B2 therefore fires nothing for project-scope creates beyond the root.

---

## 2. Architectural Commitments

### B2-D1. Plan / Execute / Post-commit — three phases, one process

The firing engine runs in **three phases**, all inside the
`graphdb_instance` gen_server process (never via its own public API —
see B2-D2):

1. **PLAN** — a pure read in `graphdb_rules`
   (`plan_composition_firing/2`). It walks the mandatory cascade
   recursively, applies the cycle guard (B2-D5), resolves child names
   (B2-D7), and returns an **abstract plan tree** (B2-D3) — *no nrefs,
   no writes*. Mandatory-side validation failures (abstract mandatory
   child, unbounded mandatory multiplicity) abort PLAN with
   `{error, Reason, Failure}` — the diagnostic (partial plan + culprit
   rule) lets the engine render `not_attempted` + the one `failed`
   outcome in the report (B2-D6); nothing is written.
2. **EXECUTE** — `graphdb_instance` allocates all nrefs/rel-ids for the
   plan tree (outside the transaction, per project convention), then
   writes the root **and the entire mandatory subtree** in **one**
   `mnesia:transaction/1`. Abort → `{error, Reason, Report}` (every
   planned outcome `not_attempted`), nothing written.
3. **POST-COMMIT** — `graphdb_instance` walks the just-created subtree
   (root included) in deterministic order and fires each node's `auto`
   rules by **recursing the same internal logic** (B2-D2). Each `auto`
   firing is its own transaction family; a failure yields a `failed`
   outcome in the report and does not touch what is already committed.

**Why three phases.** Two locked constraints force this split:

- *Allocate-outside-txn* (project convention, L10): nrefs are allocated
  before `mnesia:transaction/1` so a retry has no side effects. That
  forces "compute the whole shape, then allocate, then write" — i.e.
  PLAN before EXECUTE.
- *Mandatory-atomic vs auto-best-effort*: different transaction
  boundaries. Mandatory must share the root's transaction (all-or-
  nothing); auto must not (a deep auto failure cannot roll back the
  root). That forces EXECUTE (one txn) separate from POST-COMMIT
  (best-effort txns).

### B2-D2. Cascade recurses via internal functions, never the gen_server API

The `graphdb_instance` process is blocked inside its own `handle_call`
for the whole duration of a `create_instance`. Both the mandatory
descent and the post-commit `auto` firing therefore recurse through an
**internal** entry point — call it
`do_create_instance(Name, ClassNref, ParentNref, InstAttr, OnPath)` —
**not** through `graphdb_instance:create_instance/3`. A self-directed
gen_server call would deadlock the process against itself.

Every level of the cascade — root, mandatory descendants, auto
descendants — flows through this one internal function. The public
`create_instance/3` is a thin wrapper: it seeds `OnPath = []` and an
empty report accumulator, then calls the internal entry.

### B2-D3. PLAN returns an abstract plan tree (maps, no nrefs)

`graphdb_rules:plan_composition_firing(Scope, ClassNref)` returns
`{ok, PlanTree} | {error, Reason, Failure}` (§3.1) where a plan node is
a **map**:

```erlang
PlanNode :: #{class    => integer(),          %% class to instantiate
              name     => binary() | string(),%% resolved instance name
              rule     => #node{} | root,      %% the rule that mandated
                                               %%   this node (root sentinel
                                               %%   for the requested instance)
              mandatory_children => [PlanNode],%% recursively expanded
              auto_rules => [{#node{}, Deployment}]}  %% fire post-commit
                                               %%   against this node
PlanTree :: PlanNode    %% the root
Deployment :: #{mode => mandatory|auto|propose,
                multiplicity => pos_integer()|unbounded,
                template => integer()}   %% B1's shape, verbatim
```

**Why maps, not a record.** The plan crosses a module boundary
(`graphdb_rules` produces it, `graphdb_instance` consumes it). The
project convention is **inline records, no shared `graphdb_records.hrl`**
(F4 Phase A decision). A shared record would force a shared header; a map
needs no shared definition. The plan is structural data in flight, not a
stored entity, so a map is the right tool.

**Why abstract (no nrefs).** Two reasons:

- It keeps PLAN a genuine pure read and keeps **instance-nref
  allocation out of the rules module** — `graphdb_instance` owns
  instance identity.
- **B3 (propose) reuses this exact plan** to *describe* proposed
  children to the caller without creating them. If PLAN allocated
  nrefs, propose would orphan them. Designing the abstract plan now
  means B3 consumes it directly.

`auto_rules` are carried but **not expanded** in the plan tree — they
are expanded lazily at post-commit fire time when `do_create_instance`
recurses on the auto child's class (which re-invokes
`plan_composition_firing` for that child). This is what makes auto
best-effort and per-subtree-atomic without bloating the mandatory plan.

### B2-D4. Additive firing — no dedup, no precedence

When a class and a taxonomy ancestor both carry composition rules that
resolve onto the same instance, **every** rule fires independently. If
`Car` mandates 1 `Bolt` and `SportsCar : Car` mandates 2 `Bolt`,
`create_instance(SportsCar)` produces **3** `Bolt` children.

**Why.** B1 already returns rules additively (B1-D1) precisely so the
firing engine can decide. Collapsing same-child-class rules requires a
precedence policy (nearest-level-wins? max-multiplicity?) — that policy
is exactly what **B5 / OI-2** was carved out to own. B2 stays a pure
firing engine over B1's additive output; B5 later layers precedence on
top without B2 having pre-committed to a policy.

**Consequence — duplicate sibling names are accepted.** With additive
firing and per-rule-firing name indices (B2-D7), the two rules above
yield names `Bolt 1` (Car rule), `Bolt 1`, `Bolt 2` (SportsCar rule) —
a collision on `Bolt 1`. Instance names are not unique keys, so this is
legal. B2 accepts it; B5 (which collapses the rules) is where the
collision disappears.

### B2-D5. Cycle guard — on-path (recursion-stack), zero-level cut

Mandatory cascade can recurse forever on a self-referential composition
(`Folder` mandates `Folder`). The guard is the set of classes on the
**current root→node path** — pushed when the planner descends into a
child, popped when it backtracks. It is a **DFS recursion-stack
membership test, NOT a global visited set.**

**Why on-path, not global.** A global "seen" set would suppress the
*same* class wherever it recurs — cousins, uncles, cousins-once-removed
— which are legitimate, distinct sub-trees that must each fire. Only a
class that is its **own compositional ancestor on the same path** is a
true infinite-nesting cycle. (User correction, recorded in
cerebrum/buglog.)

**Zero-level cut (deliberate choice).** When the planner is about to
fire a mandatory rule whose **child class is already on the path**, it
**skips that rule** — the child is not created and the cut edge is not
expanded.

Trace `Folder mandates Folder`:

```
PLAN create_instance(Folder)
  path = {Folder}
  Folder's mandatory rule: child class Folder
  Folder ∈ path  ->  SKIP (fire nothing)
  result: root Folder, 0 children
```

Trace `A mandates B`, `B mandates A`:

```
PLAN create_instance(A)
  path = {A};  A mandates B  ->  B ∉ path  ->  fire, descend
    path = {A, B};  B mandates A  ->  A ∈ path  ->  SKIP
    backtrack, path = {A}
  result: {A, B}    (the second A is cut at the closing edge)
```

The alternative — "create one child, refuse to expand its identical
mandate" — also terminates but treats the *same* rule inconsistently
(root's mandate honoured, child's mandate skipped) and adds an
arbitrary extra level (`{A,B,A}`). Zero-level is uniform: a
self-referential mandate simply does not fire on the path that closes
it. This is a deliberate choice — flag for objection if the
extra-level reading was intended.

The on-path set threads through the **post-commit auto recursion** too:
each created node carries the class path that produced it, so an auto
firing cannot reintroduce a vertical cycle the mandatory pass cut.

### B2-D6. Return shape — rule-centric report on **both** paths (breaking change)

`graphdb_instance:create_instance/3` returns a report on success **and**
on failure:

```erlang
{ok,    Nref :: integer(), Report :: report()}   %% mandatory committed; auto applied
{error, Reason :: term(),  Report :: report()}   %% mandatory failure; nothing persisted

report()      :: [rule_report()]
rule_report() :: #{rule       => #node{},        %% the composition rule (instance node)
                   deployment => Deployment,      %% B1 shape: mode/multiplicity/template
                   outcomes   => [outcome()]}
outcome()     :: #{owner  => integer(),          %% committed instance fired against;
                                                 %%   present ONLY on the {ok,...} path
                   index  => pos_integer(),       %% k of multiplicity (1-based)
                   status => fired | failed | not_attempted,
                   child  => integer(),           %% present iff status = fired
                   reason => term()}              %% present iff status = failed
```

**`owner` is present exactly on the `{ok, Nref, Report}` path.** On that
path every outcome was evaluated against a committed instance, so `owner`
is a real instance nref. On the `{error, Reason, Report}` path **nothing
was allocated or written** (PLAN is pre-allocation; EXECUTE rolled back),
so no instance exists to own anything — `not_attempted` and the
PLAN-stage `failed` culprit therefore omit `owner`. The `rule` node and
its `child_class_nref` content still identify *what* would have fired;
the plan's shape (not the report) carries the would-be nesting.

The no-rules baseline is `{ok, Nref, []}` (empty report).

**Rule-centric, not two parallel lists.** The report is a list of
**rules, each carrying its own outcomes** — superseding the earlier
`#{fired, auto_failed}` shape. One `rule_report` groups every firing of
that rule (a rule fires once per owner instance of its class × each
index). This unifies success and failure under one structure and makes
the report a reusable value other reads can adopt later (OI-B2-5).

**Outcome statuses:**

- `fired` — child created and committed (mandatory in the root txn, or
  `auto` post-commit). Carries `child`.
- `failed` — this firing failed. Carries `reason`. Covers an `auto`
  failure *and* the mandatory rule whose validation aborted the create.
- `not_attempted` — planned but never executed because a **sibling
  mandatory failure** rolled the whole create back. This is the
  "succeeded-in-plan but rolled back" set — the report shows everything
  that *would* have fired next to the one thing that didn't.

**Why the error path carries it.** A bare `{error, Reason}` tells the
caller *that* it failed but not *what* the cascade would have done. With
the report, a mandatory rollback explains itself: the culprit rule's
outcome is `failed` with `reason`, and every rule that planned cleanly is
`not_attempted`. (User decision.)

**Derived from the plan, resolved per phase.** The report is built from
the PLAN tree (B2-D3), with statuses settling as phases complete:

| Phase event                        | Status transition                                               |
| ---------------------------------- | --------------------------------------------------------------- |
| PLAN, mandatory validation failure | culprit → `failed`; rest of plan → returned for `not_attempted` |
| EXECUTE commits                    | planned mandatory outcomes → `fired`                            |
| EXECUTE aborts (Mnesia)            | planned mandatory outcomes → `not_attempted`                    |
| POST-COMMIT auto firing            | `fired` / `failed` outcomes appended                            |

To render `not_attempted` on the error path, `plan_composition_firing/2`
returns a diagnostic on failure: `{error, Reason, Failure}` where
`Failure = #{plan_so_far, culprit}` (see §3.1). The engine converts
`plan_so_far` into `not_attempted` outcomes and the `culprit` rule into a
`failed` outcome.

**Cascade merge.** `auto` sub-reports (from the recursive
`do_create_instance/5`) are merged into the parent report by **grouping
outcomes under the same rule node** (by rule nref), not by list append —
so each rule keeps a single `rule_report` regardless of how many owners
it fired against.

**Why breaking — both contracts.** Every existing `{ok, Nref}` **and**
`{error, Reason}` call site / CT assertion must move to the 3-tuples.
Accepted as one-time churn; migrating call sites is part of the plan.

### B2-D9. Streaming deferred; pure `summarize/1` only

B2 produces the report **value** and one pure helper,
`graphdb_instance:summarize/1` (co-located with the other report helpers
until a second consumer justifies a `graphdb_report` module — OI-B2-5),
folding a `report()` into counts
(e.g. `#{fired => N, failed => M, not_attempted => K}`, optionally
per-rule). It builds **no** live emitter, log hook, or user-facing
renderer.

**Why.** The rule-centric structure already supports both folds —
summary (counts) and stream (one line per outcome) — so a downstream
consumer can render either without B2 committing to a mechanism. A live
per-outcome emitter would also have to respect the transaction boundary
(emit only post-commit), which is avoidable complexity for a firing
engine. The streaming/logging surface is a later division or a separate
`graphdb_report` module. (User decision: structure only.)

### B2-D7. Child naming — optional `name_pattern`, with fallback

A composition rule may carry an optional `name_pattern` **content AVP**
(a string literal attribute, B2-D8). When firing produces child *k* of
*N* (1-based):

- If `name_pattern` is present, the literal token `{i}` is substituted
  with *k*. (`"Bolt {i}"` → `"Bolt 1"`, `"Bolt 2"`, …) Other text is
  copied verbatim; absence of `{i}` yields identical names (accepted,
  B2-D4).
- If `name_pattern` is absent, the fallback is the **child class's
  name**: `"<ClassName>"` when `multiplicity = 1`, `"<ClassName> <i>"`
  when `multiplicity > 1`.

The index `i` is **per rule-firing** (resets for each rule). Combined
with additive firing this can collide (B2-D4); collisions are accepted.

### B2-D8. `name_pattern` literal attribute — new seed

`graphdb_rules` `init/1` seeds a new `name_pattern` attribute in the
**Rule Literals** sub-group (under Literals, nref 7) via the existing
`ensure_seed/2` helper — exactly as its six Phase-A sibling rule-literals
(`child_class_nref`, `mode`, `multiplicity`, …) are seeded. It is added
to `#state{}`, returned from `seeded_nrefs/0` under key `name_pattern`,
and (like its siblings) picked up by the `retro_stamp_attribute_types/0`
call already at the end of `init/1`. **`graphdb_attr` is not touched** —
the Rule Literals group is owned by `graphdb_rules`, not `graphdb_attr`.

`create_composition_rule` gains an **options map** accepting
`name_pattern` (and a forward-compatible slot for future optional
content). Since `/7` is already the positional `TemplateNref` form, the
new arity is **`create_composition_rule/8`**
`(Scope, Name, ParentClass, ChildClass, Mode, Mult, TemplateNref, Opts)`;
`/6` and `/7` delegate into it with `Opts = #{}`, so the Phase A
signatures are unchanged and backward-compatible. `name_pattern` is added
to the rule node's **content** AVPs (alongside `child_class_nref`), via
an `optional_name_pattern_avp/2` helper paralleling the existing
`optional_template_avp/2`.

---

## 3. Algorithm

### 3.1 `graphdb_rules:plan_composition_firing(Scope, ClassNref)`

Pure read. Returns `{ok, PlanTree} | {error, Reason, Failure}`, where the
diagnostic `Failure :: #{plan_so_far => PlanNode, culprit => #node{} |
undefined}` carries both the partial plan (every rule planned cleanly
before the failure) and the rule that broke — exactly what the engine
needs to render `not_attempted` + the one `failed` outcome on the error
path (B2-D6). `culprit => undefined` is reserved for an EXECUTE abort
(§3.2), which has no offending rule.

```
plan_composition_firing(Scope, ClassNref):
    plan_node(Scope, ClassNref, RootName?, root, OnPath=[])

plan_node(Scope, ClassNref, Name, Rule, OnPath):
    OnPath' = [ClassNref | OnPath]
    {ok, Levels} = effective_rules_for_class(Scope, ClassNref)   % B1
    Mand = [], Auto = []
    for each {LevelNref, RuleList} in Levels (nearest-first):
        for each {RuleNode, Deployment} in RuleList:
            ChildClass = content_avp(RuleNode, child_class_nref)
            case Deployment.mode of
              auto      -> Auto += {RuleNode, Deployment}        % expand later
              mandatory ->
                  if ChildClass ∈ OnPath'  -> skip               % B2-D5 cut
                  else:
                      Mult = Deployment.multiplicity
                      Self = #{class=>ClassNref, name=>Name, rule=>Rule,
                               mandatory_children=>Mand, auto_rules=>Auto}
                      if Mult == unbounded ->
                          % culprit = RuleNode; Self = plan so far at this node
                          fail {unbounded_multiplicity_not_fireable, RuleNode.nref}
                               with partial Self, culprit RuleNode    % §4
                      if not instantiable(ChildClass) ->
                          fail {class_not_instantiable, ChildClass}
                               with partial Self, culprit RuleNode    % §4
                      for i in 1..Mult:
                          ChildName = resolve_name(RuleNode, ChildClass, i, Mult)
                          Mand += plan_node(Scope, ChildClass,
                                            ChildName, RuleNode, OnPath')
                          % a nested plan_node failure propagates up,
                          % accumulating PlanSoFar as it unwinds
              propose   -> skip            % B3
    return #{class=>ClassNref, name=>Name, rule=>Rule,
             mandatory_children=>Mand, auto_rules=>Auto}
```

On the first mandatory violation the planner stops and unwinds, carrying
`PlanSoFar` (every node/rule planned cleanly before the culprit) plus the
culprit rule and reason. **First-failure-aborts is deliberate** (user
decision): collecting *every* mandatory failure before aborting was
considered and rejected — the create is doomed at the first violation, so
fail-fast keeps the planner simple and the single `culprit` shape stable.
`Scope` is `{environment, _}` in practice;
`{project, _}` makes B1 return `{ok, []}`, so the recursion bottoms out
immediately with empty mandatory/auto lists.

**What `PlanSoFar` contains (pinned).** When a nested `plan_node`
fails, the in-progress parent node is included **with the children it had
already completed**, and the failing branch is *not* in its
`mandatory_children`. The culprit is the rule that triggered the
violation; the reason is the violation. Concrete trace —
`A` mandates `[B, C]` (in that order); `B` plans clean; `C` mandates a
child class `D` that is **abstract**:

```
plan_node(A):  OnPath={A}
  rule A→B : plan_node(B) -> ok, Mand=[B-node]
  rule A→C : plan_node(C):  OnPath={A,C}
     rule C→D : not instantiable(D)
        fail {class_not_instantiable, D}, culprit = (C→D rule),
             partial Self_C = #{class=>C, rule=>(A→C rule),
                                mandatory_children=>[], auto_rules=>[...]}
     unwinds to A with C NOT appended
  PlanSoFar = #{class=>A, rule=>root,
                mandatory_children=>[B-node],   % B kept; C dropped
                auto_rules=>[...]}
  => {error, {class_not_instantiable, D},
       #{plan_so_far => PlanSoFar, culprit => (C→D rule)}}
```

`report_not_attempted/1` over that `Failure` yields: the `A→B` rule with
one `not_attempted` outcome (owner omitted, B2-D6), and the culprit
`C→D` rule with one `failed` outcome `reason = {class_not_instantiable,
D}`. The `A→C` rule itself — which planned far enough to *enter* C but
whose subtree never completed — is **not** listed as a separate outcome;
only the leaf culprit and the cleanly-planned rules appear. (This keeps
the report to "what would have fired" + "the one thing that broke,"
matching B2-D6.)

### 3.2 `graphdb_instance` EXECUTE

```
execute(RootName, RootClass, RootParent, RootInstAttr, PlanTree):
    % allocate OUTSIDE the txn, for every node in PlanTree
    assign each PlanNode a fresh instance nref + its arc rel-id pairs
    Txn = fun():
        write_instance_node(root: RootName, RootClass, RootParent, RootInstAttr)
        for each mandatory PlanNode (pre-order DFS):
            write_instance_node(node, owner = parent-node's nref)
        ok
    case mnesia:transaction(Txn):
        {atomic, ok}    -> {ok, RootNref, MandOutcomes, InstPlan}
        {aborted, R}    -> {error, R,
                            report_not_attempted(R,
                                #{plan_so_far => PlanTree, culprit => undefined})}
```

`write_instance_node` reuses the existing Phase-A node + membership
(29/30) + compositional (28/27) arc writes. `MandOutcomes` groups, per
mandatory rule in `PlanTree`, an `outcome` `#{owner, index, status=>fired,
child}` for every node that rule produced. `InstPlan` is the same plan
tree with each node annotated with its **assigned nref** — so post-commit
already knows each created instance, its `auto_rules`, and (by its
position in the tree) its class path. No re-read of `effective_rules` is
needed: the plan already gathered every node's `auto_rules`.

On `{aborted, R}` the engine turns the same `PlanTree` into a report of
`not_attempted` outcomes (nothing persisted) and returns
`{error, R, Report}`.

### 3.3 `graphdb_instance` POST-COMMIT (auto)

Returns `auto` outcomes already grouped per rule, ready to merge into the
mandatory report (B2-D6 cascade merge: same rule nref → one `rule_report`).
It walks the **instantiated plan tree** (DFS, deterministic), threading
the class path `OnPath` for the vertical-cycle guard, and fires each
node's already-gathered `auto_rules` — no `effective_rules` re-read.

```
fire_auto(InstPlan, OnPath):    % OnPath = class path to this node (B2-D5)
    AutoReport = []      % [rule_report()], merged by rule nref
    Nref     = InstPlan.nref          % assigned in EXECUTE
    OnPath'  = [InstPlan.class | OnPath]
    for each auto {RuleNode, Deployment} in InstPlan.auto_rules (stable order):
            ChildClass = content_avp(RuleNode, child_class_nref)
            Mult = Deployment.multiplicity
            cond:
              Mult == unbounded ->
                  add_outcome(AutoReport, RuleNode, Deployment,
                      #{owner=>Nref, index=>1, status=>failed,
                        reason=>unbounded_multiplicity_not_fireable})
              ChildClass ∈ OnPath' ->              % vertical cycle, B2-D5
                  skip
              not instantiable(ChildClass) ->
                  add_outcome(AutoReport, RuleNode, Deployment,
                      #{owner=>Nref, index=>1, status=>failed,
                        reason=>{class_not_instantiable, ChildClass}})
              else:
                  for i in 1..Mult:
                      Name = resolve_name(RuleNode, ChildClass, i, Mult)
                      case do_create_instance(Name, ChildClass, Nref, [],
                                              OnPath'):   % recurse, own txn
                        {ok, ChildNref, SubReport} ->
                            add_outcome(AutoReport, RuleNode, Deployment,
                                #{owner=>Nref, index=>i, status=>fired,
                                  child=>ChildNref})
                            AutoReport = merge_reports(AutoReport, SubReport)
                        {error, R, SubReport} ->
                            add_outcome(AutoReport, RuleNode, Deployment,
                                #{owner=>Nref, index=>i, status=>failed,
                                  reason=>R})
                            AutoReport = merge_reports(AutoReport, SubReport)
    % then recurse into the mandatory subtree (auto rules fire at every level)
    for each Child in InstPlan.mandatory_children (pre-order):
        AutoReport = merge_reports(AutoReport, fire_auto(Child, OnPath'))
    AutoReport
```

`add_outcome` appends an outcome under the rule's `rule_report` (creating
it if absent); `merge_reports` unions two reports by rule nref. Both the
`{ok,...}` and `{error,...,SubReport}` arms fold the child's sub-report
in, so a deep `auto` failure is fully attributed. The top-level caller
invokes `fire_auto(InstPlan, [])`; the post-order merge of the mandatory
children fires `auto` rules at **every** mandatory-tree level (root
included). Deterministic walk order (pre-order DFS of the instantiated
plan tree, rules nearest-first within a node) makes report ordering
test-stable.

### 3.4 `do_create_instance/5` — the unifying entry

```
do_create_instance(Name, ClassNref, ParentNref, InstAttr, OnPath):
    validate ClassNref is a class and instantiable           % existing L9
    validate ParentNref                                       % existing
    case plan_composition_firing(Scope, ClassNref) (seeded with OnPath):
        {error, R, Failure} ->
            {error, R, report_not_attempted(R, Failure)}   % nothing written
        {ok, PlanTree} ->
            case execute(Name, ClassNref, ParentNref, InstAttr, PlanTree):
                {error, R, Report} -> {error, R, Report}   % txn abort, all not_attempted
                {ok, RootNref, MandOutcomes, InstPlan} ->
                    AutoReport = fire_auto(InstPlan, []),
                    Report = merge_reports(MandOutcomes, AutoReport),
                    {ok, RootNref, Report}
```

(`plan_composition_firing/2` is the public/arity-2 form for the root;
the recursion threads `OnPath` through an internal arity. The root's own
class is pushed onto `OnPath` by `plan_node`. `report_not_attempted/2`
takes the `Reason` and the `Failure` diagnostic: every rule in
`plan_so_far` becomes one or more `not_attempted` outcomes, and `culprit`
(when not `undefined`) becomes a single `failed` outcome carrying
`Reason`.)

---

## 4. Validation / Error Catalogue

Every mandatory-side failure now returns `{error, Reason, Report}` — the
report carries the culprit rule's `failed` outcome and every cleanly
planned rule as `not_attempted` (B2-D6).

| Condition                                         | Phase       | Result                                                                        |
| ------------------------------------------------- | ----------- | ----------------------------------------------------------------------------- |
| Mandatory rule, `multiplicity = unbounded`        | PLAN        | `{error, {unbounded_multiplicity_not_fireable, RuleNref}, Report}` (no write) |
| Mandatory child class is abstract (L9)            | PLAN        | `{error, {class_not_instantiable, ChildClass}, Report}` (no write)            |
| Mandatory child class is its own on-path ancestor | PLAN        | silently skipped (B2-D5 cut)                                                  |
| EXECUTE transaction aborts                        | EXECUTE     | `{error, Reason, Report}` (nothing written; all outcomes `not_attempted`)     |
| Auto rule, `multiplicity = unbounded`             | POST-COMMIT | `failed` outcome, reason `unbounded_multiplicity_not_fireable`                |
| Auto child class is abstract                      | POST-COMMIT | `failed` outcome, reason `{class_not_instantiable, ChildClass}`               |
| Auto child class is its own on-path ancestor      | POST-COMMIT | silently skipped (B2-D5 cut)                                                  |
| Auto child `create` returns `{error, R, _}`       | POST-COMMIT | `failed` outcome, reason `R` (child sub-report folded in)                     |
| `propose`-mode rule                               | PLAN        | silently skipped (B3 owns it)                                                 |
| Root class abstract / bad parent                  | pre-PLAN    | existing L9 / parent errors, unchanged (2-tuple — pre-firing)                 |

The asymmetry is the point: **mandatory unbounded fails the create**
(`{error, ..., Report}`); **auto unbounded is a `failed` outcome and the
root survives**. The two are not the same path.

(Pre-PLAN root validation — root class not a class, abstract root, bad
parent — keeps the existing **2-tuple** `{error, Reason}`: no firing has
been considered yet, so there is no report to carry.)

---

## 5. Files Touched (for the writing-plans handoff)

| File                                                          | Change                                                                                                                                                                                                                              |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`                          | seed `name_pattern` in Rule Literals (`init/1` via `ensure_seed` + `#state{}` + `seeded_nrefs/0`); `plan_composition_firing/2` (+ internal recursion, partial-plan-on-failure); `create_composition_rule/8` options arity + `optional_name_pattern_avp/2` |
| `apps/graphdb/src/graphdb_instance.erl`                       | `do_create_instance/5`, `execute`, `fire_auto`; **all** report helpers co-located here (`add_outcome`/`merge_reports`/`report_not_attempted`/`summarize/1`); `create_instance/3` → `{ok, Nref, Report}` / `{error, Reason, Report}` |
| existing CT suites asserting `{ok, Nref}` / `{error, Reason}` | migrate to the 3-tuples (breaking-shape churn on **both** paths)                                                                                                                                                                    |
| `docs/diagrams/ontology-tree.md`                              | add `name_pattern` to the Rule Literals sub-group                                                                                                                                                                                   |
| `docs/designs/f4-graphdb-rules-design.md`                     | mark OI relating to B2 firing; note return-shape change                                                                                                                                                                             |
| `README.md` / test-count tables                               | CT count shift (new B2 cases + migrated assertions)                                                                                                                                                                                 |

---

## 6. Decision Log

| ID    | Decision                                                                                                                                                                   |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B2-D1 | Plan / Execute / Post-commit, all inside the `graphdb_instance` process.                                                                                                   |
| B2-D2 | Cascade recurses via internal `do_create_instance/5`, never the gen_server API (deadlock).                                                                                 |
| B2-D3 | PLAN returns an abstract plan tree of **maps** (no nrefs); B3 reuses it for propose.                                                                                       |
| B2-D4 | Additive firing — no dedup/precedence (→ B5); duplicate sibling names accepted.                                                                                            |
| B2-D5 | Cycle guard = on-path recursion-stack membership, **zero-level cut**; threads through auto.                                                                                |
| B2-D6 | Rule-centric report `[#{rule, deployment, outcomes}]` on **both** `{ok,Nref,R}` and `{error,Reason,R}`; outcomes `fired`/`failed`/`not_attempted`; breaking on both paths. |
| B2-D7 | Naming via optional `name_pattern` content AVP, `{i}` 1-based per-firing; class-name fallback.                                                                             |
| B2-D8 | New `name_pattern` string literal seed; `create_composition_rule` gains a delegating arity.                                                                                |
| B2-D9 | Streaming/log emitter deferred; B2 ships only the report value + a pure `summarize/1` fold.                                                                                |

---

## 7. Open Issues (carried, not resolved here)

- **OI-B2-1 (→ B5).** Horizontal precedence when a class and an ancestor
  carry rules for the same child class. B2 fires both; B5 decides
  collapse/precedence and removes the duplicate-name collision.
- **OI-B2-2 (→ B3).** `propose`-mode rules are skipped by B2. B3 surfaces
  the abstract plan (B2-D3) to the caller as proposals.
- **OI-B2-3 (deferred).** `add_class_membership/2` does not fire rules.
  Whether adding a class to an existing instance should retroactively
  materialise its mandatory composition is left open; B2 fires only on
  `create_instance/3`.
- **OI-B2-4 (→ B4).** Connection rules are not fired by B2.
- **OI-B2-5 (future extraction).** The rule-centric `report()` (B2-D6)
  and its `summarize/1` fold (B2-D9) are introduced for B2 but designed
  to be reusable. If a second subsystem needs the same shape (e.g. B4
  connection firing, or a query-side audit), extract a small
  `graphdb_report` module owning the type, `add_outcome`, `merge_reports`,
  `report_not_attempted`, and `summarize`. B2 keeps them local until a
  second consumer exists (YAGNI).

---

## 8. Test Plan Outline

(Full TDD steps belong in the implementation plan; this is coverage
intent.)

- **No-rules baseline** — `create_instance` returns `{ok, Nref, []}`;
  existing behaviour intact.
- **Single mandatory, mult=1** — one child created in the same txn; the
  report has one `rule_report` whose single outcome is
  `#{owner, index=>1, status=>fired, child}`.
- **Mandatory mult=N** — N `fired` outcomes under one rule; per-firing
  `{i}` naming; indices 1..N.
- **Additive** — class + ancestor both mandate same child class → two
  `rule_report`s, counts add (1 + 2 = 3); duplicate `Bolt 1` names
  tolerated.
- **Mandatory cascade** — grandchild mandated by a mandatory child;
  whole subtree in one txn; outcomes carry the right `owner` per level.
- **Mandatory atomicity** — a mandatory child that fails (e.g. abstract)
  aborts the whole create; zero rows written.
- **Mandatory failure report** — the `{error, Reason, Report}` shows the
  culprit rule `failed` (with `reason`) and the cleanly-planned rules
  `not_attempted`; assert nothing persisted.
- **Unbounded mandatory** —
  `{error, {unbounded_multiplicity_not_fireable, _}, Report}`, nothing
  written; report distinguishes culprit vs `not_attempted`.
- **Cycle guard (vertical)** — `Folder mandates Folder` → root only, 0
  children; `A→B→A` → `{A,B}`.
- **Cousins fire** — same class mandated under two different branches →
  both fire (on-path, not global).
- **Auto best-effort** — auto child created post-commit; an auto failure
  (abstract / unbounded / create error) is a `failed` outcome and the
  root + siblings survive (`{ok, Nref, Report}`).
- **Auto cascade** — auto child that itself has mandatory children;
  sub-report merged under the right rules (merge-by-rule, not append).
- **`name_pattern`** — `{i}` substitution; absent → class-name fallback
  (singular vs `<Class> <i>`).
- **Project scope** — `{project, _}` create fires nothing beyond root
  (`{ok, Nref, []}`).
- **`summarize/1`** — folds a mixed report into
  `#{fired => N, failed => M, not_attempted => K}` correctly.
- **Call-site migration** — representative existing suites pass under the
  three-tuple return.
