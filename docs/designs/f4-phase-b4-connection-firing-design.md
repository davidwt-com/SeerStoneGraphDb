<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B4 — Connection Firing Engine — Design

**Status:** Specified. No implementation has begun.

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; B1 landed via PR #33; B2 landed via PR #34; B3 landed via PR #35).
This is the fourth division of Phase B. Consumes B1's
`effective_rules_for_class/2` gather and B2's three-phase firing engine +
rule-centric report (`docs/designs/f4-phase-b2-composition-firing-design.md`).

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored Data),
§10 (Composition Rules — *Mandatory connections*: "a class definition can
require that a new instance be connected to an instance of a specified
class before creation is complete").

---

## 1. Scope

### 1.1 Phase B division map

| Div    | Subject                                                                        | Depends on |
| ------ | ------------------------------------------------------------------------------ | ---------- |
| **B1** | `effective_rules_for_class/2` — read-side taxonomy walk (no firing)            | Phase A    |
| **B2** | Composition firing engine — `mandatory` + `auto`; cascade; return-shape change | B1         |
| **B3** | `propose` mode — proposals surfaced in the create report (no session flag)     | B2         |
| **B4** | Connection firing engine (Mandatory Connections, §10)                          | B1, B2     |
| **B5** | Horizontal conflict resolution / precedence (OI-2) — rules at one class level  | B2         |

This document specifies **B4 only**. (The parent map lists B4's dependency
as B1; in practice B4 also extends B2's report plumbing and three-phase
engine, so its true dependency is B1 + B2.)

### 1.2 What B4 delivers

`create_instance` becomes **connection-rule-aware**. After B2 has
materialised the requested instance and its composition subtree, B4
consults the **ConnectionRule** instances effective for each materialised
instance's class (via B1) and writes connection arc pairs to **existing**
target instances, governed by a caller-supplied **resolver** and each
rule's `mode` / `multiplicity`.

The central asymmetry with B2: **composition firing *creates* its child;
connection firing *cannot*.** A `Manufacturer` is not minted per `Car` — it
is a pre-existing, shared instance. And `create_instance/3` has no channel
to learn *which* target to connect to. B4 resolves this with a resolver
strategy supplied by the caller, not a target-selection policy baked into
the engine.

- **`create_instance/3`** keeps **report-only** semantics: every effective
  ConnectionRule surfaces as an outcome in the report; **nothing is
  connected**. Equivalent to `/4` with the built-in `report_only` resolver.
- **`create_instance/4`** threads a resolver. The engine consults it per
  connection rule to obtain target(s) or a `defer` decision; then
  **rule mode × resolver decision** governs what happens — a committed
  `mandatory` rule enforces in the root transaction, a committed `auto`
  rule connects post-commit, and a deferred rule (or any rule under
  `report_only`) surfaces as an outcome without failing the create.

Connection rules fire for **every** instance materialised by the call —
the root **and** each composition descendant B2 created — by walking B2's
instantiated plan tree.

### 1.3 What B4 does NOT do

- **Create target instances.** Connection firing only connects to
  instances that already exist; it never mints a target (B4-D1).
- **Cascade / recurse.** Connecting to an existing instance materialises
  nothing, so there is no firing recursion and **no cycle guard** (contrast
  B2-D5). Connection firing is a single pass per materialised instance
  (B4-D5).
- **Multi-class instance creation.** `create_instance` still takes a single
  class. Firing all of several classes' rules atomically at create time is
  a separate, larger capability that re-opens B2's contract and B1's
  signature — promoted to its own candidate division (OI-B4-3), **not**
  folded into connection firing.
- **Retroactive firing on `add_class_membership/2`.** Adding a class to an
  existing instance does not fire that class's connection (or composition)
  rules. Mirrors OI-B2-3; subsumed by OI-B4-3.
- **Project-scoped rules.** B1 returns `{ok, []}` for `{project, _}`, so a
  project-scope create fires no connection rules beyond what the root's
  environment-scope class carries.

---

## 2. Architectural Commitments

### B4-D1. Connection firing connects to existing instances — never creates targets

The spec's Mandatory-connection clause ("connected to an instance of a
specified class") is about a **pre-existing** instance. A target like
`Manufacturer` is shared across many `Car`s; minting one per car would be
wrong. Therefore connection firing's only act is to write a connection arc
pair from the (new) source instance to a target the **resolver** selects
among instances that already exist. This is the single fact that collapses
the design: the engine cannot invent a target, and `create_instance` has no
target argument, so target selection must be a caller-supplied strategy.

### B4-D2. Resolver = caller-supplied callback, one call per rule, returns a list

A **resolver** is a callback fun the caller hands to `create_instance/4`:

```erlang
Resolver :: fun((ConnContext) -> Decision)

ConnContext :: #{rule           => #node{},               %% the ConnectionRule instance
                 characterization => integer(),           %% arc label (content AVP)
                 reciprocal       => integer(),           %% reverse arc label (content AVP, B4-D3)
                 target_class     => integer(),           %% content AVP
                 mode             => mandatory | auto | propose,
                 multiplicity     => pos_integer() | unbounded,
                 source           => integer()}           %% pre-allocated new-instance nref

Decision :: {connect, [Target]} | defer
Target   :: integer()                       %% TargetNref
          | {integer(), {FwdAVPs, RevAVPs}} %% TargetNref + per-connection metadata
```

- The engine calls the resolver **once per effective ConnectionRule** (not
  per index). The returned list's length is the number of connections the
  resolver wants made; multiplicity is a **validation constraint** on that
  list, not a generator (B4-D5). This handles `unbounded` connection
  multiplicity naturally — "a `Car` may be `sold_by` any number of
  `Dealer`s" simply means the resolver returns however many targets it
  chooses.
- `{connect, List}` — the resolver **commits** to connecting to `List`.
- `defer` — the resolver declines; the rule surfaces as a report outcome
  and **never** fails the create, regardless of mode (B4-D4). This is the
  signal that distinguishes "report-only / I'll handle it later" from "I'm
  connecting and I came up short."
- **`/3` uses the built-in `report_only` resolver** = `fun(_) -> defer end`.
  Every connection rule defers ⇒ everything is reported, nothing connected,
  nothing fails. This is exactly the report-only contract.

**Why a callback, not a data map or behaviour module.** A fun lets the
caller close over a live Mnesia query ("find the unique existing
`Manufacturer`"), a fixed map, or anything — without the engine inventing a
selection policy. A bare fun is also lighter than a behaviour module when
only one or two strategies exist today (YAGNI). The resolver runs during
PLAN, **before** the new instance commits (B4-D4): it is expected to be
**read-only** and must not assume the source instance is readable — it
selects among *other*, already-committed instances. The `source` nref
(pre-allocated outside the transaction, per project convention L10) is
provided for context only.

**OI (future, OI-B4-1).** Resolvers should eventually be expressible *in the
ontology* — a resolver strategy stored as knowledge rather than supplied as
host-language code, the same "push behaviour into the knowledge graph" arc
that makes rules themselves data. Deferred; recorded so the future
enhancement has a home.

### B4-D3. Reciprocal is ConnectionRule content (new AVP), authored on the rule

A connection arc pair needs a **reciprocal** label (the arc as seen from
the target back — `made_by` pairs with `manufactures`). Phase A's
ConnectionRule content (D6) carries only `characterization_nref` and
`target_class_nref` — no reciprocal — and the schema **cannot derive** it:
relationship-attribute pairs are created together but **not cross-linked**
(`do_create_relationship_attribute_pair/4` writes only taxonomy arcs to the
parent group; the Fwd↔Rev pairing is returned to the caller at creation and
then lost).

The reciprocal is fixed by the **characterization** (it is a property of the
connection *type*, identical regardless of which target is chosen), so it
belongs to the rule, not to target selection. B4 therefore adds a
**`reciprocal_nref` content AVP** to ConnectionRule, set when the rule is
authored.

**This requires seeding a new literal attribute.** The Rule Literals
sub-group (under Literals, nref 7) currently seeds **7** literals
(`child_class_nref`, `target_class_nref`, `template_nref`,
`characterization_nref`, `mode`, `multiplicity`, `name_pattern`) — there is
**no** `reciprocal_nref`. B4 seeds an **8th**, `reciprocal_nref`, exactly as
B2 seeded `name_pattern`: via `graphdb_rules` `init/1`'s `ensure_seed/2`,
added to `#state{}`, returned from `seeded_nrefs/0`, and retro-stamped by the
existing `retro_stamp_attribute_types/0` call. `docs/diagrams/ontology-tree.md`
gains the new literal in the Rule Literals sub-group.

The authoring API changes accordingly:

- `create_connection_rule` gains a required `Reciprocal` parameter,
  positioned immediately after `Characterization`:

  ```erlang
  create_connection_rule(Scope, Name, SourceClass,
                         Characterization, Reciprocal, TargetClass,
                         Mode, Multiplicity)                -> {ok, RuleNref} | {error, term()}.
  create_connection_rule(Scope, Name, SourceClass,
                         Characterization, Reciprocal, TargetClass,
                         Mode, Multiplicity, TemplateNref)  -> {ok, RuleNref} | {error, term()}.
  ```

  These are the new canonical `/8` and `/9` forms. **Breaking:** Phase A's
  `/7` and `/8` (no reciprocal) are superseded; the Phase A connection-rule
  CT cases migrate to supply a reciprocal. Greenfield (no production rules),
  so no data migration — only test call-site churn, in the spirit of B2-D6
  but far smaller. **Arity hazard:** the new `/8` collides in *arity* with
  Phase A's `/8` (the template form) but binds different parameters
  (`Reciprocal` in position 5 vs `TemplateNref` in position 9). A stale `/8`
  caller therefore mis-binds **silently** rather than failing to compile, so
  the migration step must locate every connection-rule call site by
  behaviour, not lean on compiler arity errors.

**OI (future hygiene, OI-B4-2).** A reciprocal **backlink** on each
arc-label node (a `reciprocal => Nref` AVP stamped at pair-creation in
`graphdb_attr`) would let the graph derive the reciprocal globally — and
eventually let `add_relationship` drop its explicit reciprocal argument.
Broader blast radius than B4 needs (touches attr seeding; only new pairs get
it); recorded as a separate candidate.

### B4-D4. A connection RESOLVE step (post-allocation, pre-commit) feeds B2's EXECUTE; mandatory enforces in the root transaction

B2's composition PLAN is **abstract** — it returns a plan tree of maps with
**no nrefs**; instance nrefs are allocated as the **first step of B2's
EXECUTE** (outside the transaction, per L10). The resolver needs each
source instance's nref in its `ConnContext`, so connection resolution
**cannot** ride in B2's abstract PLAN. B4 instead inserts a distinct
**RESOLVE** step between B2's allocation and B2's transaction:

1. **B2 PLAN** — composition abstract plan tree (connections untouched).
2. **ALLOCATE** (B2 EXECUTE step 1) — assign a fresh nref to every plan
   node (root + composition subtree). Allocation is side-effect-free.
3. **CONNECTION RESOLVE** (B4, post-allocation, pre-commit). Every
   instance now has an nref. For each, B1's gather is filtered to
   ConnectionRule instances; each rule's content AVPs (`characterization`,
   `reciprocal`, `target_class`) are read; the **resolver is called** with
   the real `source` nref and its targets **validated** (B4-D6). A
   `{connect, List}` **mandatory** rule whose valid targets cannot satisfy
   multiplicity **aborts here** → `{error, Reason, Report}`, **nothing
   written** (allocation has no side effects to undo). `defer`, `auto`, and
   `propose` rules never abort. The mandatory connection arc rows are
   computed and handed to the next step.
4. **EXECUTE** (the root transaction). B2 writes the instance + composition
   subtree; B4's **mandatory** connection arc pairs are written in the
   **same `mnesia:transaction/1`** — genuine "before creation is complete"
   atomicity. A transaction abort makes every planned connection outcome
   `not_attempted`.
5. **POST-COMMIT** (best-effort). **`auto`** connection arc pairs are
   written after commit; a write failure is a `failed` outcome and never
   rolls the instance back. Deferred and `propose` rules contribute report
   outcomes only.

**Why this works with a caller callback.** The resolver runs in RESOLVE,
*outside* any transaction, so an arbitrary callback never executes inside
`mnesia:transaction/1`; yet it runs *after* allocation, so `source` is a
real nref, and *before* the txn, so a mandatory shortfall aborts with
nothing written. RESOLVE computes the full connection shape; EXECUTE writes
the mandatory subset atomically alongside the composition subtree;
POST-COMMIT writes the auto subset best-effort.

**The `/3` mandatory escape.** Under `report_only` every rule defers, so a
class with a mandatory connection rule is still creatable via `/3`: the
mandatory rule surfaces as a `required` outcome (an unmet requirement the
caller can satisfy later via `add_relationship`), and creation **succeeds**.
Enforcement bites only when a real `/4` resolver **commits**
(`{connect, List}`) to a mandatory rule and the list falls short.

### B4-D5. Multiplicity is a constraint on the resolver's list; no cascade

Multiplicity governs the resolver's returned list rather than generating
firings:

- **`pos_integer()` K** — at most K connections are written (a **cap**).
  For a committed **mandatory** rule, the resolver must supply **K** valid
  targets (parity with composition's "create K"); fewer ⇒ the create fails
  (B4-D4). For **auto**, up to K valid targets are connected and a shortfall
  is **not** a failure.
- **`unbounded`** — no cap; every valid target the resolver returns is
  connected. A committed **mandatory** `unbounded` rule requires **≥ 1**
  valid target; **auto** accepts any number including zero.

Because connecting to an existing instance creates nothing, connection
firing **does not recurse** and needs **no cycle guard**. It is a single
pass over each instance B2 already materialised (root + composition
descendants), reusing B2's instantiated plan tree as the walk order. A
mandatory connection for a deep composition child still lands in the root
transaction (that child is in the same EXECUTE txn); auto connections for
any node land post-commit.

### B4-D6. Target validation

Per resolver-returned target, the engine validates (during RESOLVE):

- the target nref **exists**;
- the target is `kind = instance`;
- the target is an instance of `target_class` **or a subclass** of it
  (membership via the `classes` cache, widened through `target_class`'s
  taxonomy descendants).

A violation on a **`{connect, …}` mandatory** rule fails the create
(B4-D4); on any other committed rule it yields a `failed` outcome for that
index and the create proceeds. `defer` rules are not validated (no targets).

**No self-connection check is needed.** The source instance is not committed
at RESOLVE time, and B4 never connects to a same-batch instance (composition
descendants are likewise uncommitted), so a returned target is *necessarily*
a pre-existing instance distinct from the source — the "exists + is an
instance" checks already exclude the source. (If OI-B4-3 multi-class or a
future same-batch-target capability lands, revisit.)

### B4-D7. Report — connection outcomes reuse B2's rule-centric `report()`

B4 produces the **same** `report()` value B2 introduced
(`[#{rule, deployment, outcomes}]`); a ConnectionRule simply contributes its
own `rule_report` whose outcomes use connection-shaped keys:

```erlang
connection_outcome() ::
    #{source           => integer(),   %% the new instance; present iff a real instance exists
      index            => pos_integer(),%% k within this rule's connection list (1-based)
      status           => connected | required | proposed
                        | not_connected | failed | not_attempted,
      target           => integer(),   %% present iff status = connected
      characterization => integer(),
      target_class     => integer(),
      reason           => term()}       %% present iff status = failed
```

Statuses (the three **deferred** statuses map one-to-one onto the rule's
mode, so the label is never misleading):

- **`connected`** — arc pair written (mandatory in the root txn, or `auto`
  post-commit). Carries `target`.
- **`required`** — a `mandatory` rule the resolver **deferred** (always, for
  `report_only` / `/3`): an unmet *requirement*. The create **succeeded**;
  the caller may satisfy it later.
- **`not_connected`** — an `auto` rule the resolver **deferred**: a default
  connection that simply wasn't taken. Distinct from `required` — the caller
  is *not* obligated to act.
- **`proposed`** — a `propose`-mode rule, surfaced for the caller (mirrors
  B3's propose outcomes); nothing connected.
- **`failed`** — an `auto` connection that errored, or a committed target
  that failed validation on a non-mandatory rule. Carries `reason`.
- **`not_attempted`** — planned but rolled back by a sibling mandatory
  failure (the EXECUTE abort set), mirroring B2-D6.

Composition and connection outcomes coexist in one report: the `rule` node's
kind (`CompositionRule` vs `ConnectionRule`) and the outcome's keys
distinguish them. `summarize/1` extends its fold to count the connection
statuses (`connected` / `required` / `not_connected` / `proposed`) alongside
the composition ones. Report helpers stay **co-located in `graphdb_instance`** — connection
firing also runs there, so OI-B2-5's "extract a `graphdb_report` module when
a second *module* needs the shape" is still not triggered.

---

## 3. Algorithm

### 3.1 Where B4 hooks in

B2's `do_create_instance/5` already returns the instantiated plan tree
(`InstPlan`) after EXECUTE and fires composition `auto`/`propose` passes
post-commit. B4 adds a **connection pass** threaded through the same
phases:

```
do_create_instance(Name, ClassNref, ParentNref, InstAttr, OnPath, Resolver):
    plan composition firing (B2)      -> PlanTree         %% abstract, no nrefs (unchanged)
    allocate nrefs for PlanTree (B2)  -> InstPlan         %% root + composition subtree
    resolve connections (B4)          -> ConnPlan         %% NEW: resolver consulted (source nref known),
        on committed-mandatory shortfall -> {error, Reason, Report}   %%      targets validated; nothing written
    EXECUTE: write instance + mandatory composition subtree (B2)
             + mandatory connection arcs (B4)             %% same root txn
    POST-COMMIT: fire_auto composition (B2)
               + fire_propose composition (B3)
               + fire_connections auto/propose/required/connected (B4)  %% best-effort + report
    return {ok, RootNref, merge_reports(... , ConnReport)}
```

The public `create_instance/3` calls this with `Resolver = report_only`;
`create_instance/4` passes the caller's resolver. The resolver threads
**unchanged** down the composition cascade so a composition descendant's
connection rules use the same strategy.

### 3.2 Connection RESOLVE (per materialised instance, post-allocation)

```
resolve_connections(Scope, InstNode, SourceNref, Resolver):
    {ok, Levels} = effective_rules_for_class(Scope, InstNode.class)     %% B1
    ConnRules = [ {R, Dep} || {R, Dep} <- flatten(Levels),
                              kind_of(R) == 'ConnectionRule' ]
    for each {Rule, Dep} in ConnRules (nearest-first, stable):
        Char   = content_avp(Rule, characterization_nref)
        Recip  = content_avp(Rule, reciprocal_nref)            %% B4-D3
        TClass = content_avp(Rule, target_class_nref)
        Ctx    = #{rule=>Rule, characterization=>Char, reciprocal=>Recip,
                   target_class=>TClass, mode=>Dep.mode,
                   multiplicity=>Dep.multiplicity, source=>SourceNref}
        case Resolver(Ctx) of
            defer ->
                emit outcome status by mode = (mandatory -> required;
                                               auto      -> not_connected;
                                               propose   -> proposed)
            {connect, List} ->
                Valid = [ T || T <- List, validate_target(T, TClass, SourceNref) ]   %% B4-D6
                case {Dep.mode, length(Valid), Dep.multiplicity} of
                    {mandatory, N, K}  when is_integer(K), N <  K -> FAIL create
                    {mandatory, 0, unbounded}                     -> FAIL create
                    _                                             -> ok
                end,
                ToWrite = cap(Valid, Dep.multiplicity),
                record planned connections (mandatory -> EXECUTE txn;
                                            auto       -> POST-COMMIT)
```

**Note on deferred statuses.** The three modes give three distinct deferred
labels: `mandatory -> required` (caller must act), `auto -> not_connected`
(a default not taken), `propose -> proposed` (a suggestion). `proposed` stays
reserved for propose-mode, matching B3; `required` never misleads an `auto`
rule into looking obligatory (B4-D7).

RESOLVE is a pure read: the resolver is expected read-only, and validation
uses `mnesia` reads only. A mandatory shortfall aborts RESOLVE with the
culprit rule, exactly as B2 aborts PLAN on a mandatory composition
violation, so the error-path report renders the culprit
`failed`/`not_attempted` set (B4-D7). Because the source instance is not yet
committed, the resolver necessarily selects among **other, already-committed**
instances (B4-D6).

### 3.3 Connection EXECUTE / POST-COMMIT

- **EXECUTE** — for each planned **mandatory** connection, write the two
  directed `relationship` rows (`kind = connection`; `characterization` /
  `reciprocal` per B4-D3; the owning rule's `Template` AVP at index 0 plus
  any resolver `AVPSpec`) inside the **root transaction**. Rel-ids are
  allocated outside the txn (L10), like every other arc write.
- **POST-COMMIT** — for each planned **auto** connection, write the same
  arc pair in its own transaction; a failure becomes a `failed` outcome.
  Emit `proposed` / `required` outcomes for the deferred and propose rules.

Connection arc writes reuse the existing `add_relationship` write path
(`write_connection_arcs`), so per-direction AVP handling and the Template
convention are already in place.

---

## 4. Validation / Error Catalogue

| Condition                                                      | Phase         | Result                                                               |
| ------------------------------------------------------------- | ------------- | ------------------------------------------------------------------- |
| Committed mandatory rule, valid targets `< K` (or 0/unbounded) | RESOLVE       | `{error, {mandatory_connection_unsatisfied, RuleNref}, Report}` (no write) |
| Committed target invalid (missing / not instance / wrong class), **mandatory** | RESOLVE | `{error, {invalid_connection_target, …}, Report}` (no write)      |
| Committed target invalid, **auto**                            | RESOLVE→report | `failed` outcome (reason carries the violation); create proceeds    |
| Mandatory rule, resolver returns `defer`                      | RESOLVE       | `required` outcome; create **succeeds** (the `/3` escape, B4-D4)     |
| Auto rule, resolver returns `defer`                           | RESOLVE       | `not_connected` outcome; create **succeeds**                        |
| EXECUTE transaction aborts                                    | EXECUTE       | `{error, Reason, Report}` (all connection outcomes `not_attempted`)  |
| Auto connection write fails post-commit                       | POST-COMMIT   | `failed` outcome; instance + committed siblings survive              |
| `propose`-mode connection rule                                | RESOLVE       | `proposed` outcome; nothing connected                               |
| Project scope                                                 | RESOLVE       | no connection rules (B1 returns `[]`)                               |

The asymmetry mirrors B2: a **committed** mandatory shortfall fails the
create; an auto shortfall is a `failed`/`required` outcome and the root
survives.

---

## 5. Files Touched (for the writing-plans handoff)

| File                                                          | Change                                                                                                                                                              |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`                          | seed an 8th Rule Literal `reciprocal_nref` (`init/1` `ensure_seed` + `#state{}` + `seeded_nrefs/0`); `reciprocal_nref` added to ConnectionRule content AVPs; `create_connection_rule/8,/9` (reciprocal param) supersede `/7,/8`; connection content readers (`characterization`/`reciprocal`/`target_class`) |
| `apps/graphdb/src/graphdb_instance.erl`                       | `create_instance/4` (resolver) + `report_only` default; resolver threaded through `do_create_instance`; connection PLAN/EXECUTE/POST-COMMIT passes; connection outcome rendering; `summarize/1` extension |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`                   | migrate Phase A connection-rule cases to the reciprocal arity; new content-AVP assertions                                                                            |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`               | new B4 firing cases (report-only, mandatory-enforced, auto, multiplicity, validation, project scope, composition-descendant connections)                            |
| `docs/diagrams/ontology-tree.md`                              | add the new `reciprocal_nref` literal to the Rule Literals sub-group (8th literal under Literals, nref 7)                                                            |
| `docs/designs/f4-graphdb-rules-design.md`                     | division map: B4 done; record OI-B4-3 (multi-class create) as a candidate division; D6 ConnectionRule content gains `reciprocal_nref`; mark OI-B2-4 RESOLVED by B4  |
| `README.md` / test-count tables                               | CT count shift (new B4 cases + migrated connection-rule assertions)                                                                                                 |

---

## 6. Decision Log

| ID    | Decision                                                                                                                                  |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------- |
| B4-D1 | Connection firing connects to **existing** instances — never creates a target.                                                         |
| B4-D2 | Resolver = caller-supplied callback fun; one call per rule; returns `{connect, [Target]} \| defer`. `/3` = `report_only` (`defer` all). |
| B4-D3 | Reciprocal is **ConnectionRule content** (`reciprocal_nref` AVP); `create_connection_rule/8,/9` gain the param (breaking vs Phase A `/7,/8`). |
| B4-D4 | Firing wires into B2's PLAN/EXECUTE/POST-COMMIT; **committed** mandatory connections enforce in the root txn; `defer` never fails (the `/3` escape). |
| B4-D5 | Multiplicity = constraint on the resolver's list (cap for `pos_int`, none for `unbounded`); **no cascade, no cycle guard**.             |
| B4-D6 | Target validation: exists, `kind=instance`, instance-of `target_class`-or-subclass, not self.                                            |
| B4-D7 | Connection outcomes reuse B2's rule-centric `report()`; statuses `connected`/`required`/`not_connected`/`proposed`/`failed`/`not_attempted` (deferred status maps one-to-one onto mode); `summarize/1` extended. |

---

## 7. Open Issues (carried, not resolved here)

- **OI-B4-1 (future).** Resolvers expressible **in the ontology** — a
  resolver strategy stored as knowledge rather than supplied as host
  code (the "push behaviour into the knowledge graph" arc). A future
  resolver-with-options surface may supersede the bare-callback contract;
  recorded with a `%% B4 OI-B4-1:` code comment, mirroring B3's OI markers.
- **OI-B4-2 (future hygiene).** Reciprocal **backlink** on arc-label nodes
  so the graph derives a characterization's reciprocal (and `add_relationship`
  could eventually drop its explicit reciprocal arg). Touches `graphdb_attr`
  seeding; broader than B4.
- **OI-B4-3 (candidate division — promoted from OI-B2-3).** **Multi-class
  instance creation.** An instance that belongs to several classes should
  have all of those classes' composition + connection rules fire atomically
  at create time. This is the principled successor to "`add_class_membership/2`
  does not fire rules" — better than retroactive firing because it keeps all
  firing inside `create_instance`'s transaction model. The future
  brainstorming for this division owns the mechanism; **the favoured
  direction (David, 2026-06-10) is *not* signature widening:**

  - `create_instance` is expected to **stay single-class** — the instance is
    always driven by one **primary** class. Multi-class-ness is **ontology,
    not call-site arity:** a rule *on the primary class* declares that its
    instances are also instances of class X (consistent with F4's thesis
    that behaviour lives in stored rules, not API shape, and with the §10
    "obligation rides on the class" model).
  - The load-bearing question is therefore **gather transitivity, not a new
    argument:** when `effective_rules_for_class/2` (B1) encounters a rule
    that confers membership in class X, does it **recurse into X's effective
    rules** and fold them into the same firing pass? That turns "multi-class"
    from a signature problem into a B1 transitive-gather problem — a cleaner
    seam that never touches the entry-point arity.

  (The earlier framing — `create_instance` and a composition rule's child
  spec accept a **class list** with B1 unioning across it — is recorded as
  the rejected alternative.) Touches B1 + B2 + B4 together; taken up
  deliberately, not folded into B4. Genuine post-hoc **reclassification**
  firing (adding a class to an already-existing instance) remains a further,
  separate deferral.
- **OI-B2-4 (RESOLVED by B4).** Connection rules are now fired by
  `create_instance`.

---

## 8. Test Plan Outline

(Full TDD steps belong in the implementation plan; this is coverage intent.)

- **Report-only baseline (`/3`)** — a class with a `mandatory` connection
  rule is creatable via `/3`; the rule surfaces as a `required` outcome;
  nothing connected; create **succeeds**. An `auto` rule on the same class
  surfaces as `not_connected` (not `required`); a `propose` rule as
  `proposed`.
- **Mandatory enforced (`/4`, resolver commits)** — resolver returns a valid
  target; arc pair written in the root txn; outcome `connected`; reverse
  traversal finds the source.
- **Mandatory shortfall fails** — resolver commits but supplies an invalid /
  insufficient target for a mandatory rule → `{error, …, Report}`, **zero
  rows written**; report shows the culprit and `not_attempted` siblings.
- **Auto best-effort** — `auto` rule, resolver commits → connected
  post-commit; an auto target that fails validation is a `failed` outcome
  and the instance survives.
- **`propose` connection** — `propose`-mode rule → `proposed` outcome,
  nothing connected.
- **Multiplicity** — `mult=K` mandatory needs K valid targets (K-1 fails);
  `unbounded` connects all returned; `auto` shortfall tolerated.
- **Validation** — missing target / non-instance / wrong target_class
  rejected; subclass-of-target_class accepted.
- **Reciprocal content** — `create_connection_rule/8` stores
  `reciprocal_nref`; fired arc's reverse row carries it.
- **Composition-descendant connections** — a `mandatory` composition child
  whose class has a connection rule: the child's connection fires in the
  same create (root txn for mandatory), outcome `source` = the child nref.
- **Project scope** — `{project, _}` create fires no connection rules.
- **`summarize/1`** — folds a mixed composition+connection report into per-
  status counts including `connected` / `required` / `proposed`.
- **Call-site migration** — Phase A connection-rule CT cases pass under the
  reciprocal arity.
