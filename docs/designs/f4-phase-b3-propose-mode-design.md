<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B3 — Propose Mode — Design

**Status:** Implemented (PR pending).

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; B1 landed via PR #33; B2 landed via PR #34). This is the third
division of Phase B. Consumes B2's abstract plan tree and rule-centric
report (`docs/designs/f4-phase-b2-composition-firing-design.md`).

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored
Data), §10 (Composition Rules), §11 (Pattern Learning — propose-mode
rules are the runtime surface that learned rules will eventually feed).

---

## 1. Scope

### 1.1 Phase B division map

| Div    | Subject                                                                        | Depends on |
| ------ | ------------------------------------------------------------------------------ | ---------- |
| **B1** | `effective_rules_for_class/2` — read-side taxonomy walk (no firing)            | Phase A    |
| **B2** | Composition firing engine — `mandatory` + `auto`; cascade; return-shape change | B1         |
| **B3** | `propose` mode — proposals always surfaced in the create report                | B2         |
| **B4** | Connection firing engine (Mandatory Connections, §10)                          | B1         |
| **B5** | Horizontal conflict resolution / precedence (OI-2) — rules at one class level  | B2         |

This document specifies **B3 only**.

### 1.2 What B3 delivers

`graphdb_instance:create_instance/3` already fires `mandatory` and `auto`
composition rules (B2) and returns a rule-centric report. B3 makes the
**third** mode, `propose`, contribute to that report:

- A `propose`-mode composition rule effective for the new instance's
  class (or for any mandatory descendant the engine materialises)
  contributes a **`proposed` outcome** to the report — a *description*
  of a child that the rule suggests creating.
- **Nothing is materialised.** No node, no membership arc, no
  compositional arc is written for a proposed child. `propose` has zero
  side effects on the graph.
- The caller decides what to do with each proposal. To accept one, the
  caller issues an ordinary `create_instance/3` for that child class with
  the new instance as compositional parent — which in turn fires *that*
  child's own rules. B3 adds **no** new public API, no confirmation
  protocol, and no session/options argument.

This is the **always-in-report** model. Proposals are surfaced
unconditionally; there is no interactive/non-interactive session flag.

### 1.3 Decision: always-in-report (supersedes the §11 sketch)

The parent design (`f4-graphdb-rules-design.md` §11) sketched B3 as
`propose` mode **plus** an interactive/non-interactive session flag
"most likely threaded through `graphdb_query:new_session/0`." That
phrasing predates B2. With B2 shipped, `create_instance/3` has signature
`(Name, ClassNref, ParentNref)` — no session, no options — so a flag
would be net-new coupling from `graphdb_instance` to `graphdb_query`
plus a confirmation protocol.

**B3 drops the flag.** Proposals always appear in the report; the caller
already has everything needed to act on them (it can call
`create_instance/3` for any child it accepts). This is the smallest
coherent B3 and removes the cross-worker coupling entirely.

The session-flag / interactive-confirmation idea is **deferred**, not
deleted. If a future "propose-with-options" need arises (caller-supplied
selection hints, batched confirmation, an interactive session that
accumulates and commits proposals), it gets its own brainstorm → design
cycle and may supersede the simple defaults recorded in §4.

### 1.4 What B3 does NOT do

- **Connection** rules (`graphdb_rules` ConnectionRule) — that is **B4**.
  B3 surfaces only **composition** propose rules.
- **Horizontal conflict resolution / precedence** — propose proposals are
  **additive**, exactly like B2's mandatory/auto firing. If a class and an
  ancestor both carry propose rules for the same child class, B3 surfaces
  **both** proposals. Collapse/precedence is **B5**.
- **Cascade into proposals.** The engine never recurses *into* a proposed
  child — nothing is created, so there is nothing to recurse into.
  Propose is **shallow**: one proposal per (rule × multiplicity index).
- **`add_class_membership/2` firing** — unchanged from B2 (OI-B2-3).

---

## 2. Background: where propose sits today

B2 left `propose` deliberately un-handled in two places:

- `graphdb_rules.erl` planner (`plan_rules/4`): the `propose` clause
  drops the rule —
  `plan_rules(Rest, OnPath1, State, Acc)  %% B3 owns propose`.
- `validate_mode/1` already **accepts** `propose`, so propose-mode rules
  can be *created* today; they simply contribute nothing at firing time.

The B2 abstract plan tree node is a map with three accumulators:

```erlang
#{class               => ClassNref,
  name                => Name,        %% resolved instance name (or undefined at plan time for root)
  rule                => Rule,        %% the rule node that mandated this node (root for the requested instance)
  deploy              => Deploy,      %% deployment map for that rule
  mandatory_children  => [PlanNode],  %% recursively expanded
  auto_rules          => [{RuleNode, Deploy}]}
```

`auto_rules` carries *unexpanded* rules (multiplicity is expanded at
fire time in `graphdb_instance:fire_auto*`). B3 mirrors this exactly.

---

## 3. Design

### 3.1 Plan tree — `graphdb_rules`

1. **`leaf_plan/4`** gains a fourth accumulator, parallel to the others:

   ```erlang
   #{... , mandatory_children => [], auto_rules => [], propose_rules => []}
   ```

2. **`plan_rules/4`** — the `propose` clause stops dropping the rule and
   accumulates it, mirroring the `auto` clause verbatim:

   ```erlang
   propose ->
       Proposes = maps:get(propose_rules, Acc) ++ [{RuleNode, Deploy}],
       plan_rules(Rest, OnPath1, State, Acc#{propose_rules => Proposes});
   ```

   No multiplicity expansion, no name resolution at plan time — identical
   discipline to `auto_rules`. Propose rules are gathered at **every**
   level the planner visits: the requested root and every mandatory child
   `plan_node/6` recurses into. (Auto children are materialised
   post-commit by `graphdb_instance` via `do_create_instance/5`, so their
   own propose rules surface naturally in their sub-report — see §3.2.)

3. **On-path cycle cut (§4 decision OI-B3-2).** A propose proposal whose
   child class is already on the root→here path is **skipped**, reusing
   B2-D5's guard. This is evaluated at fire time (§3.2), where the
   `OnPath` class list is available, not at plan time — consistent with
   how B2 evaluates the auto-child cut in `fire_one_auto`. The plan tree
   keeps the unfiltered propose rule; the cut happens during expansion.

No new exported functions are required on `graphdb_rules` for B3 — the
existing `rule_child_class/1` and `rule_child_name/4` (added in B2) are
reused by the instance worker to describe proposals.

### 3.2 Firing — `graphdb_instance`

Add a `fire_propose/2` pass, a peer of `fire_auto/2`, run **post-commit**
alongside auto firing. For each instance plan node:

1. Walk `propose_rules`.
2. For each `{RuleNode, Deploy}`, read child class
   (`graphdb_rules:rule_child_class/1`) and multiplicity
   (`maps:get(multiplicity, Deploy, 1)`).
3. **On-path cut:** if the child class is a member of the node's `OnPath`,
   skip the rule entirely (no outcomes).
4. **Expand to outcomes:**
   - Bounded `Mult` (a positive integer): emit `Mult` `proposed`
     outcomes, indices `1..Mult`, each with the name resolved via
     `graphdb_rules:rule_child_name/4` (the existing `name_pattern`
     `{i}` machinery).
   - `unbounded` (§4 decision OI-B3-1): emit a **single** `proposed`
     outcome with `index => unbounded` and a *representative* name
     resolved at index 1 (`rule_child_name(Rule, ChildClass, 1, 1)`). The
     caller decides how many to actually create.
5. Build a rule-centric report entry `#{rule, deployment, outcomes}`,
   exactly the B2 shape, and merge it into the report.

**No instantiability guard.** Unlike `mandatory` (fails) and `auto`
(failed outcome), `fire_propose/2` does **not** check
`graphdb_class:is_instantiable/1` on the proposed child class. A proposal
creates nothing, so an abstract target cannot break the transaction; it is
the caller's responsibility to validate when it chooses to materialise a
proposal. Keeps the propose path side-effect-free and simple.

`fire_propose/2` calls **no** `do_create_instance` and opens **no**
transaction — it is pure report construction over already-resolved class
names.

Because mandatory children are planned recursively and auto children are
fired recursively through `do_create_instance/5`, `fire_propose/2`
running at each materialised level means: **every node that actually
gets created contributes its propose proposals to the report.** Proposed
(unmaterialised) children contribute nothing further — propose is shallow.

### 3.3 Outcome shape

B3 introduces a new outcome **status**, `proposed`, reusing the B2
outcome map otherwise:

```erlang
#{owner          => OwnerNref,             %% materialised parent the accepted child attaches to
  index          => pos_integer() | unbounded,
  status         => proposed,
  proposed_class => ChildClassNref,         %% the class the proposal suggests instantiating
  name           => ResolvedName}            %% resolved per name_pattern (fallback for unbounded)
```

- **`owner` IS present** and meaningful. In B2, `owner` is the **parent
  instance nref** (not "the thing created"). For a proposal, that parent
  is the materialised node whose class carried the propose rule — it
  exists, and the caller needs it to know where to attach an accepted
  child. This matters in a cascade, where proposals surface at several
  materialised levels and the caller must distinguish which parent each
  proposal belongs to.
- **`proposed_class`, not `child`.** B2's `child` key always holds a
  **created instance** nref. A proposal creates no instance, so it must
  not reuse `child` for a *class* nref — that would overload the key with
  two incompatible meanings. `proposed_class` is a distinct key carrying
  the class to instantiate. (A `proposed` outcome therefore has no
  `child` key at all.)
- **No `reason` key.** That is for `failed`/`not_attempted`. A proposal
  is neither — it is a successful *suggestion*.

### 3.4 Report status summary

`summarize/1` gains a `proposed` counter:

```erlang
#{fired => N, failed => M, not_attempted => K, proposed => P}
```

### 3.5 Error path

Unchanged from B2. If a **mandatory** rule fails, `create_instance/3`
returns `{error, Reason, Report}` where `walk_not_attempted/2` collapses
the unreached **mandatory** subtree to `not_attempted` outcomes; propose
(and auto) rules do **not** appear on the error path at all. Propose
proposals are surfaced as `proposed` **only on the success path**, where
the root and its mandatory subtree committed.

---

## 4. Recorded decisions (deliberately simple; supersedable)

These are **intentionally minimal defaults**. They are documented here
*and* commented at their call sites in code so that a future
propose-with-options feature (richer multiplicity, caller selection
hints, interactive confirmation sessions) can find and supersede them.

| ID          | Decision                                                                                                                                                                                                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **OI-B3-1** | **Unbounded multiplicity + propose ⇒ a single `proposed` outcome** with `index => unbounded`. Enumerating ∞ proposals is meaningless, and (unlike mandatory/auto) there is no materialisation to fail. The caller decides cardinality.                         |
| **OI-B3-2** | **On-path cycle cut applies to propose.** A proposal whose child class is already on the root→here path is skipped, reusing B2-D5. Keeps reports free of self-ancestral noise; one `lists:member/2` check. Nothing breaks either way since nothing is created. |
| **OI-B3-3** | **Always-in-report; no session flag, no confirm API.** Supersedes the §11 interactive-flag sketch (see §1.3). Deferred, not deleted.                                                                                                                           |
| **OI-B3-4** | **Additive proposals.** Class + ancestor propose rules for the same child class both surface; collapse/precedence is B5.                                                                                                                                       |
| **OI-B3-5** | **Shallow.** No recursion into proposed children; propose contributes one proposal per (rule × multiplicity index).                                                                                                                                            |

Each of OI-B3-1, OI-B3-2, OI-B3-5 carries a `%% B3 OI-B3-N:` comment at
its enforcement point in code, plus a one-line forward-compat note that a
propose-with-options request may supersede it.

---

## 5. Files touched

| File                                                                                | Change                                                                                                       |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `apps/graphdb/src/graphdb_rules.erl`                                                | `leaf_plan/4` adds `propose_rules => []`; `plan_rules/4` propose clause accumulates instead of dropping.     |
| `apps/graphdb/src/graphdb_instance.erl`                                             | Add `fire_propose/2` (peer of `fire_auto/2`), wire into post-commit; `proposed` status; `summarize/1` count. |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`                                         | Plan-tree cases: propose accumulator, multiplicity unexpanded, mixed mandatory+auto+propose, on-path.        |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`                                      | Firing cases: `proposed` outcomes present, child NOT materialised, unbounded single outcome, summarize.      |
| `docs/diagrams/ontology-tree.md`                                                    | No change (no new seeds).                                                                                    |
| `ARCHITECTURE.md`, `apps/graphdb/CLAUDE.md`, `README.md`, `TASKS.md`, parent design | Status + test-count refresh; mark B3 landed, propose surfaced.                                               |

No schema change, no new seeds, no supervision-tree change.

---

## 6. Test plan outline

**`graphdb_rules_SUITE` (plan tree):**

- `plan_propose_rule_accumulated` — a propose rule lands in
  `propose_rules`, not `auto_rules` / `mandatory_children`.
- `plan_propose_unexpanded` — multiplicity is **not** expanded at plan
  time (rule stored once regardless of multiplicity).
- `plan_mixed_modes` — a class with one rule of each mode populates all
  three accumulators correctly.
- `plan_propose_at_mandatory_child` — a propose rule on a mandatory
  child's class appears in that child's plan node.

**`graphdb_instance_SUITE` (firing):**

- `propose_outcome_in_report` — report carries a `proposed` outcome with
  `owner` (the materialised parent), `proposed_class`, `index`, `name`;
  no `child` key.
- `propose_not_materialised` — after the create, the proposed child class
  has **no** new instance (row count unchanged); only the root (+ any
  mandatory/auto children) exist.
- `propose_multiplicity_bounded` — `multiplicity => 3` yields three
  `proposed` outcomes, indices 1..3, names per `name_pattern`.
- `propose_multiplicity_unbounded` — `unbounded` yields exactly **one**
  `proposed` outcome with `index => unbounded`.
- `propose_on_path_cut` — a propose rule whose child class is an
  on-path ancestor is skipped (no `proposed` outcome).
- `summarize_counts_proposed` — `summarize/1` reports the proposed count.
- `propose_with_mandatory_and_auto` — all three modes on one create:
  mandatory child materialised, auto child materialised, propose surfaced
  but not materialised; report has `fired` + `fired` + `proposed`.

Target: ~11 CT cases. EUnit `graphdb_instance_tests` gains a `proposed`
case for the `summarize/1` fold if the helper set warrants it.

---

## 7. Open items carried forward

- **OI-B3-6 (→ future).** Propose-with-options: caller-supplied selection
  hints, interactive confirmation sessions, batched accept/reject. Out of
  scope; gets its own brainstorm. The §4 defaults are the seam.
- **OI-B3-7 (→ B4).** Connection-rule propose mode. B3 is composition-only.
- **OI-B3-8 (→ B5).** Precedence when class + ancestor propose the same
  child — additive for now.
