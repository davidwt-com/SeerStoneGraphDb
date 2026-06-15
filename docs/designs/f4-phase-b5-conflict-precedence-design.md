<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B5 — Horizontal Conflict Resolution / Precedence — Design

**Status:** Designed; not yet planned or implemented.

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; B1 via PR #33; B2 via PR #34; B3 via PR #35; B4 via PR #37). This is
the fifth and final core division of Phase B. It consumes B1's
`effective_rules_for_class/2` gather, B2's composition firing engine and
rule-centric report, B3's propose machinery, and B4's connection firing
engine + resolver-threading pattern.

**Spec citation:** `the-knowledge-network.md` §8 (Rules as Stored Data).
The knowledge-network spec stores rules as data and is silent on conflict
precedence; B5 supplies the precedence policy the firing engine applies.

**Resolves:** OI-2 (rule conflicts and precedence) from the parent design.

---

## 1. Scope

### 1.1 Phase B division map

| Div    | Subject                                                                        | Depends on |
| ------ | ------------------------------------------------------------------------------ | ---------- |
| **B1** | `effective_rules_for_class/2` — read-side taxonomy walk (no firing)            | Phase A    |
| **B2** | Composition firing engine — `mandatory` + `auto`; cascade; return-shape change | B1         |
| **B3** | `propose` mode — proposals surfaced in the create report (no session flag)     | B2         |
| **B4** | Connection firing engine (Mandatory Connections)                               | B1, B2     |
| **B5** | Horizontal conflict resolution / precedence (OI-2)                             | B2, B4     |

This document specifies **B5 only**.

### 1.2 The problem

When a class and its taxonomy ancestors each attach a rule that touches the
same component or connection, the effective-rules gather currently returns
them **additively, nearest-first, and resolves nothing**. Both
`graphdb_rules:composition_pairs/2` and `connection_specs/2` flatten the
level-grouped output of `effective_rules/2` into a single ordered list with
no deduplication. Today, if `Car` and its ancestor `Vehicle` both attach
"mandatory 1 `Engine`", the engine fires *two* engines.

B5 inserts a **resolution pass** between the gather and the firing engines
that decides, when two effective rules conflict, which one wins, whether the
loser is dropped or surfaced as a proposal, and how the surviving
multiplicity range is computed.

### 1.3 Out of scope

- **No change to the public B1 contract.** `effective_rules_for_class/2`
  stays additive/unresolved — its documented "resolves nothing" guarantee is
  preserved. Resolution happens only on the firing path.
- **No new rule data.** B5 reads existing rule content and deployment AVPs;
  it seeds nothing and adds no Mnesia fields.
- **Reactive learning, guided/automatic instantiation modes** — later
  phases, tracked in `TASKS.md`.

---

## 2. Decisions

### B5-D1 — Conflict grouping is by referenced class, with descendant matching

Two effective rules are in the same **conflict group** when their referenced
class matches under the taxonomy. Walking nearest-first, each rule either
joins the nearest already-established **winner** whose referenced class it
matches, or it becomes a new winner (its own group of one). Matching is
directional — the nearer rule must be the same as, or a **descendant of**,
the farther rule's referenced class:

| Kind        | Farther rule joins a winner's group when…                                                         |
| ----------- | ------------------------------------------------------------------------------------------------- |
| Composition | the winner's `child_class` **is-a** (descendant-or-self of) the farther's `child_class`           |
| Connection  | same `characterization` **and** the winner's `target_class` **is-a** the farther's `target_class` |

If the referenced classes are taxonomically unrelated, there is **no match**
— the rules are **additive** and both fire independently.

The `is-a` test is `graphdb_class:class_in_ancestry/2`, whose contract is
`class_in_ancestry(CandidateNref, ClassNref)` → true iff `ClassNref` **equals
or is a subclass of** `CandidateNref` (the *second* argument is the
descendant-or-self of the *first*). To test "the winner's child is-a the
farther's child," call it **`class_in_ancestry(FartherChild, WinnerChild)`**
— ancestor first, descendant second. (Arg order is an implementation hazard;
B4 added a wrong-arg-order canary test for the same call. Connection target
matching uses the same order: `class_in_ancestry(FartherTarget,
WinnerTarget)`.)

*Rationale.* For composition the `child_class` **is** the slot, so a nearer
rule that mints a more specific child (`Car`→`ElectricMotor`, where
`ElectricMotor` is-a `Engine`) fills the same slot as the ancestor's generic
`Vehicle`→`Engine` rule — one child, the more specific wins. For connection
the `characterization` (the arc-label attribute) plus a descendant target is
the analogous "same edge, more specific endpoint" case (`Car`--owns-->`Garage`
refines `Vehicle`--owns-->`Building` when `Garage` is-a `Building`). Unrelated
targets under the same `characterization` are genuinely different connections.

### B5-D2 — Winner is the nearest rule; same-level ties break by mode priority

Within a conflict group the **winner is the nearest rule** (smallest
taxonomy distance). The winner contributes the surviving **mode** and the
surviving **`Min`**.

When two rules in a group sit at the **same** class level (distance 0 — e.g.
the Phase A `duplicate_child_class_with_different_modes` fixture: two rules
on `Cell`, both `child_class=Nucleus`, one `mandatory` and one `propose`),
"nearest" cannot pick. Break the tie by **mode priority
`mandatory > auto > propose`**; if the mode also ties, break by **arc order**
(the order rules are encountered in the gather, which follows
`applies_to`-arc traversal).

### B5-D3 — Surviving multiplicity is nearest `Min`, greatest `Max`

The resolved multiplicity is:

- **`Min`** = the **winner's** `Min` (the most specific floor; all other
  `Min`s are ignored).
- **`Max`** = the **greatest** `Max` across the winner and all of its
  **dropped** members (`unbounded` dominates). A member that is *demoted to
  propose* (B5-D4) does **not** contribute its `Max` to this merge — it is
  fully independent.

Firing continues to mint `Min` (per B-prep); `Max` remains the ceiling for a
future interactive-creation session.

### B5-D4 — Losers are dropped, except both-real-template losers, which demote to `propose`

A farther (losing) member of a conflict group is **dropped** (shadowed); its
`Max` merges into the winner's greatest-`Max` per B5-D3.

**Exception:** when **both** the winner **and** the losing member carry a
**real (non-default) template** (B5-D5), the loser is **not** dropped — it is
re-emitted as an independent **`propose`** entry, regardless of its original
mode, keeping its **own** `{Min, Max}`. Deliberate templated authoring is
surfaced to the caller as a proposal rather than silently discarded.

If only one of the pair carries a real template (mixed), the loser is simply
**dropped** — the propose-demotion requires *both* to be real-templated.

### B5-D5 — "Real (non-default) template" is read from the content `template_nref` AVP

The deployment `?ARC_TEMPLATE` AVP is always set to the rule's *owning
class's default template* (`graphdb_rules:do_create_rule/7`), so it can never
be the signal for "this rule targets a specific template slot." The signal
is the optional **content** `template_nref` AVP on the rule node (the
caller-supplied `TemplateNref`, absent for most rules). A rule has a **real
(non-default) template** iff it carries a `template_nref` content AVP whose
value differs from its owning class's default template.

### B5-D6 — The resolver is owned by `graphdb_instance` and threaded in, mirroring B4

`graphdb_rules`' plan path **stops resolving on its own**.
`graphdb_instance` owns the conflict-resolution policy and supplies it,
exactly as B4 threads a connection resolver through `create_instance/4`:

- `create_instance` gains a **conflict-resolver parameter** (a fun; default
  = the B5 algorithm in this document). The new arity is
  `create_instance/5 (Name, ClassNref, ParentNref, ConnResolver,
  ConflictResolver)`; `/3` and `/4` delegate with the built-in B5 default.
- For **composition**, the resolver is threaded **into**
  `graphdb_rules:plan_composition_firing` (new arity taking the resolver) and
  applied at **each cascade level** inside `plan_node`'s recursion — the plan
  is built per-level, so resolution must run per-level, not on a
  pre-flattened list.
- For **connection**, `graphdb_instance` applies the **same** resolver to the
  output of `graphdb_rules:effective_connection_rules/2` during the B4
  RESOLVE walk, per plan node.

This keeps the policy in the instance layer (per-call overridable, symmetric
with the connection resolver) while the **default** algorithm lives in
`graphdb_rules`, next to the rule content and taxonomy access it needs.

### B5-D7 — Integration is free; demoted entries flow through existing machinery

The resolution pass only **rewrites and reorders** the
`[{RuleNode, Deploy}]` (composition) and `[{RuleNode, Deploy, ConnSpec}]`
(connection) lists. No firing-engine changes are required:

- A demoted composition entry (`mode => propose`) flows through B3's existing
  `propose_rules` accumulator → `fire_propose` → `proposed` outcome.
- A demoted connection entry (`mode => propose`) flows through B4's existing
  propose handling (resolver not consulted; `proposed` outcome emitted).
- A winner with a merged `{Min, Max}` fires exactly as any rule with that
  deployment.

---

## 3. The resolver contract

The conflict resolver is a fun supplied at `create_instance` and threaded as
in B5-D6. It is invoked **per cascade level / per plan node**, on the
nearest-first, meta-class-filtered rule list for that level, and returns the
**resolved** list in the shape its consumer already expects.

Because composition pairs (`{RuleNode, Deploy}`) and connection specs
(`{RuleNode, Deploy, ConnSpec}`) differ in shape, the resolver receives a
**conflict context** map identifying the kind and carrying the level's
rules, and returns the resolved list of the same kind:

```
ConflictResolver ::
  fun((#{ kind        := composition | connection,
          rules       := [Pair],           %% nearest-first, this level only
          class_nref  := integer() }) -> [Pair])
```

- `kind = composition` → `Pair = {RuleNode, Deploy}`.
- `kind = connection`  → `Pair = {RuleNode, Deploy, ConnSpec}`.

The **default** resolver (`graphdb_rules:default_conflict_resolver/0`, or an
internal function the default fun wraps) implements §2 in full for both
kinds: group by B5-D1, resolve by B5-D2/D3, dispose by B5-D4/D5. A caller
may pass a custom fun to override the policy entirely (e.g. force pure
additive, or pure nearest-shadow).

*Note.* Grouping spans the whole effective set for a node (self + all
ancestors), so the resolver is given the **flattened** nearest-first list for
that node, not the per-ancestor sublists. For composition this is the list
`plan_node` currently builds via `composition_pairs/2`; for connection it is
`effective_connection_rules/2`'s output for that node.

---

## 4. Worked examples

| Scenario                                    | Effective rules (nearest-first)                                                              | Resolved outcome                                                                                       |
| ------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Cross-level shadow**                      | `Car`: mandatory `{1,1}` Engine; `Vehicle`: mandatory `{1,3}` Engine                         | One winner: mandatory `{1,3}` Engine (nearest mode+Min, greatest Max). One engine minted.              |
| **Descendant shadow** (B5-D1)               | `Car`: mandatory `{1,1}` ElectricMotor (is-a Engine); `Vehicle`: mandatory `{1,1}` Engine    | One winner: mandatory `{1,1}` ElectricMotor. One ElectricMotor minted; Vehicle's Engine rule shadowed. |
| **Additive** (unrelated)                    | `Car`: mandatory `{1,1}` Engine; `Vehicle`: mandatory `{1,1}` Radio (unrelated)              | Two winners, both fire: one Engine + one Radio.                                                        |
| **Same-level tie** (B5-D2)                  | `Cell`: mandatory `{1,1}` Nucleus; `Cell`: propose `{1,1}` Nucleus                           | Mode priority → mandatory wins; one Nucleus minted. (Propose loser dropped — default templates.)       |
| **Both-real-template demote** (B5-D4)       | `Car`@tpl-A: auto `{1,1}` Engine; `Vehicle`@tpl-B: mandatory `{1,2}` Engine (both real tpls) | Winner: auto `{1,1}` Engine (fires). Loser re-emitted as **propose** `{1,2}` Engine (own range).       |
| **Mixed template drop** (B5-D4)             | `Car`@tpl-A: auto `{1,1}` Engine; `Vehicle`@default: mandatory `{1,2}` Engine                | Winner: auto `{1,2}` Engine (greatest Max merged). Loser dropped — not both real templates.            |
| **Connection target shadow** (B5-D1)        | `Car`--owns-->Garage (Garage is-a Building); `Vehicle`--owns-->Building, same `owns` label   | One winner: Car--owns-->Garage. Vehicle's Building connection shadowed.                                |
| **Connection additive** (unrelated targets) | `Car`--owns-->Garage; `Vehicle`--owns-->Boat (unrelated), same `owns` label                  | Both fire: owns-->Garage and owns-->Boat.                                                              |

---

## 5. Edge cases

- **Farther rule matches two unrelated winners.** A farther rule whose
  referenced class is a common ancestor of two unrelated winners' classes
  joins **only the nearest** winner it matches (single assignment); it does
  not merge into both.
- **Same-level descendant-related rules** (two rules on one class whose child
  classes are in a subclass relation) — resolved by B5-D2 (mode priority,
  then arc order); the winner's own referenced class is the one minted.
- **Bad / unknown / non-class starting nref** — unchanged: the existing
  `ancestors/1 → {error,_} ⇒ []` mapping in `effective_rules` keeps the
  effective set empty, so resolution sees an empty list and returns `[]`.
- **Custom resolver returning a malformed list** — out of scope; the default
  resolver is total over well-formed input, and a caller passing a custom fun
  owns its correctness (same posture as B4's connection resolver).

---

## 6. Testing

New CT cases in the rules / instance suites, one per path:

- cross-level shadow (nearest mode + Min, greatest Max);
- descendant-match shadow (the `Car`/`ElectricMotor` case);
- additive when referenced classes are unrelated;
- max-of-all merge across ≥ 3 levels including `unbounded`;
- same-level mode-priority tie (the `Cell`/`Nucleus` fixture — its outcome
  flips under B5, so the Phase A fixture's "no dedup" assertion is updated to
  the firing-time resolution);
- both-real-template demote-to-propose (loser surfaces as `proposed` with its
  own range; winner fires at its own range);
- mixed-template drop (no propose; greatest-Max merge);
- connection target descendant-match shadow;
- connection additive on unrelated targets;
- a `create_instance/5` call passing a **custom** resolver (e.g. pure
  additive) to prove the seam is overridable.

---

## 7. Open items

- **OI-B5-1 — Resolved-rule provenance in the report.** The rule-centric
  report currently names the winning rule node. When a loser is shadowed
  (dropped), the report does not record that a farther rule was suppressed.
  A future enhancement could add a `shadowed_by` / `shadows` note. Deferred
  — not engine-correctness.
- **OI-B5-2 — Resolver as ontology.** B4 raised OI-B4-1 (resolvers expressed
  as ontology rather than caller-supplied funs). The conflict resolver shares
  that future: the default policy could be encoded as ontology metadata a
  class author tunes. Deferred with OI-B4-1.
- **OI-B5-3 — Multi-class instance creation interaction.** When OI-B4-3
  (multi-class creation via transitive gather) is taken up, B5 grouping must
  span the union of all conferred classes' rules; the per-node resolver
  contract already operates on the flattened effective set, so the change is
  in the gather, not the resolver. Tracked with OI-B4-3.
