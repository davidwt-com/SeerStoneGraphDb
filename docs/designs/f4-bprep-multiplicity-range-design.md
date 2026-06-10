<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 B-prep — Multiplicity Range Refactor — Design

**Status:** Specified. No implementation has begun.

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; B1/B2/B3 landed via PRs #33/#34/#35). This is a **prerequisite
refactor** that the connection-firing division (B4) depends on; see
`docs/designs/f4-phase-b4-connection-firing-design.md` §7 and B4-D5.

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored Data),
§9 (instantiation — *guided* vs *automatic*), §10 (Composition rules —
component multiplicity and mandatory connections).

---

## 1. Scope

### 1.1 Why this is a prerequisite (lands before B4)

Today a rule's **multiplicity** is a single `pos_integer() | unbounded`,
and the *minimum* it implies is undocumented and inconsistent across
mode × value (mandatory K ⇒ exactly K; mandatory `unbounded` ⇒ ≥ 1; auto
⇒ ≥ 0). B4's connection firing needs an explicit floor *and* ceiling
(`made_by` = exactly one; `sold_by` = at least one, no cap), which forced
the question. The decision (B4-D5): multiplicity becomes an explicit
`{Min, Max}` **cardinality range**, reshaped **uniformly across both
composition and connection rules** so every rule kind stores the same
shape.

That reshape re-opens already-shipped code (Phase A authoring + validation,
B1 `decode_deployment`, B2 mandatory + auto firing, B3 propose firing), so
it is split out as its own division — **B-prep** — landed and merged
*before* B4. B4 then consumes the new shape with no further data-model
churn. Nothing of B4's design is lost: B4's spec is already committed and
only references this shape.

### 1.2 What B-prep delivers

- `multiplicity :: {Min, Max}` everywhere a rule's multiplicity is
  authored, stored, decoded, validated, or fired — composition **and**
  connection rules, identical shape.
- `Min :: non_neg_integer()` — the required/default floor.
- `Max :: pos_integer() | unbounded` — the ceiling. **`unbounded` survives
  only as a value of `Max`**; it is no longer a standalone multiplicity
  anywhere in deployment.
- **Creation** firing **materialises `Min`** (mandatory mints `Min` in the
  root transaction, auto mints `Min` post-commit) — **decided** (David). For
  **propose** (which surfaces, does not create), the count is an **open
  fork** — see BP-D2 and BP-OI-2.
- `Max` is recorded but not consumed by creation firing — it is the ceiling
  reserved for the future interactive-creation feature (§1.3).
- The `unbounded`-driven dead-end on the **creation** paths is retired:
  `Min` is always finite, so every rule is fireable (BP-D3).

### 1.3 What B-prep does NOT do

- **No new ontology seed.** The existing `multiplicity` literal attribute
  (seeded in `graphdb_rules:init/1`) carries the `{Min, Max}` tuple as its
  AVP value; AVP values are arbitrary terms, so no new literal, no
  `bootstrap.terms` change, no `docs/diagrams/ontology-tree.md` change.
- **No arity change.** `create_composition_rule/6,7,8` and
  `create_connection_rule/7,8` keep their arities; only the **type** of the
  multiplicity parameter changes (scalar → `{Min, Max}`). (B4 later adds a
  *reciprocal* parameter to `create_connection_rule`; that is B4's change,
  not B-prep's.)
- **No interactive creation session.** Consuming `Max` to let a human user
  or an autonomous agent add optional children/connections beyond `Min` up
  to `Max` is a **separate, later feature** (BP-OI-1). B-prep only stores
  `Max` and fires `Min`.
- **No data migration.** Greenfield — no production rules exist — so the
  reshape is a hard cutover; only test call sites change (BP-D6).

---

## 2. Architectural Commitments

### BP-D1. Multiplicity is a `{Min, Max}` range; `unbounded` only as `Max`

`multiplicity :: {Min, Max}` with `Min :: non_neg_integer()` and
`Max :: pos_integer() | unbounded`. The pair is stored verbatim as the
value of the `multiplicity` deployment AVP on the forward `applies_to` arc
(unchanged mechanism — see §3.2). The same shape is authored on both
composition and connection rules. `unbounded` is **only** legal as `Max`;
a bare `unbounded` (or a bare integer) is no longer a valid multiplicity.

Common cardinalities express directly:

| Intent               | `{Min, Max}`     |
| -------------------- | ---------------- |
| exactly one          | `{1, 1}`         |
| at least one, no cap | `{1, unbounded}` |
| exactly K            | `{K, K}`         |
| optional, up to K    | `{0, K}`         |
| optional, any number | `{0, unbounded}` |

### BP-D2. Creation firing materialises `Min`; `Max` is the interactive-session ceiling; propose count is an open fork

**Creation** firing — the paths that actually materialise nodes — is driven
by `Min` (**decided**, David: "minimum drives the count for compositional
children to create"):

- **mandatory composition** — mint `Min` children in the root transaction
  (`graphdb_rules` PLAN, §3.4).
- **auto composition** — mint `Min` children post-commit
  (`graphdb_instance:fire_auto`, §3.5).
- **connection firing (B4, future)** — `mandatory` passes iff the resolver
  supplies ≥ `Min` valid targets; writes are capped at `Max` (B4-D5). The
  resolver-list cap is the **only** place `Max` constrains firing today.

`Max` is otherwise **recorded, not fired** on the creation paths: it is the
ceiling for the future interactive-creation feature (BP-OI-1), where a user
or autonomous agent may add children/connections beyond `Min`, up to `Max`.
This preserves today's composition behaviour exactly under the `K → {K, K}`
migration (`Min = Max = K` ⇒ mint K), while making `{Min, unbounded}` simply
mint `Min`.

**OPEN FORK — propose count (BP-OI-2; needs David before implementation).**
Propose *surfaces*, it does not create, so David's "count for children to
create" does not settle it, and it touches a B3 decision he made on purpose
(OI-B3-1: an `unbounded` propose emits a single `index => unbounded`
outcome, "caller decides cardinality"). Two coherent choices:

- **(a) Minimal** — propose surfaces `Min` discrete `proposed` outcomes and
  the `index => unbounded` case is retired (uniform with the creation
  paths). Simple, but `{Min, unbounded}` propose collapses to `Min`
  outcomes and the "you may add more, up to `Max`" signal is dropped from
  the report.
- **(b) Preserve the open-ended signal (leaning recommendation)** — propose
  surfaces `Min` outcomes **and carries `Max`** (e.g. a `max => Max` key on
  the `proposed` outcome, with `Max = unbounded` retaining today's
  open-ended meaning). This keeps the report — the always-in-report signal
  an **autonomous agent** reads — aware of the ceiling, which is exactly the
  interactive-creation session `Max` exists for. Costs one optional outcome
  key; does not retire OI-B3-1's intent, it generalises it.

This doc *defaults its prose to (a)* only as a placeholder; the firing-path
edits in §3.6 are written so either choice is a small change. **Pick before
the plan is written.**

### BP-D3. `unbounded`-driven dead-ends are retired

Because `Min` is always a finite `non_neg_integer()`, a **creation** rule
can always fire (it mints `Min`, possibly 0). Therefore:

- **`unbounded_multiplicity_not_fireable` is removed** in both places it
  occurs today: the PLAN-stage abort in `graphdb_rules` (mandatory) and the
  `failed`-outcome in `graphdb_instance:fire_one_auto` (auto). `{Min,
  unbounded}` mandatory/auto composition now mints `Min`. **(Decided.)**
- The B3 propose `index => unbounded` special case (OI-B3-1) is **subject to
  the BP-OI-2 fork**, not unilaterally removed. Under choice (a) it is
  retired; under choice (b) it is generalised (the outcome carries `Max =
  unbounded`). Pending David's pick.

### BP-D4. Validation: shape + `Min ≤ Max` + `Max ≥ 1`

`validate_multiplicity/1` is rewritten to accept exactly:

```erlang
{Min, Max}  when is_integer(Min), Min >= 0,
                 ( (is_integer(Max) andalso Max >= 1 andalso Max >= Min)
                   orelse Max =:= unbounded )
```

Everything else (a bare integer, a bare `unbounded`, `Max < Min`, `Max < 1`,
non-integers) ⇒ `{error, invalid_multiplicity}` — the **same** error atom,
so callers/tests keep one rejection path. Validation runs before any nref
is allocated (unchanged ordering in `validate_composition/5` and
`validate_connection/6`).

**Permissive on `mandatory` + `Min = 0`.** A mandatory rule with `Min = 0`
is *vacuous* (mints/requires nothing, never fails) but **allowed** — shape
validation does not inspect `mode`, mirroring the project's permissive
markers (e.g. `instantiable`). Noted, not enforced (BP-OI-3).

### BP-D5. Storage, decode, and authoring arity are structurally unchanged

- **Write** (`do_create_rule` deployment AVPs, §3.2): the `multiplicity`
  AVP's `value` becomes the `{Min, Max}` tuple instead of a scalar. No new
  AVP, no new literal.
- **Decode** (`graphdb_rules:decode_deployment/2`, B1): already copies the
  AVP value verbatim into the deployment map's `multiplicity` key, so it
  carries `{Min, Max}` transparently — **no structural change**, only the
  doc comment and the value's type. The B1 deployment map stays
  `#{mode, multiplicity, template}`.
- **Authoring**: `create_composition_rule/6,7,8` and
  `create_connection_rule/7,8` keep their arities; the `Mult` parameter's
  type is now `{Min, Max}`.

### BP-D6. Greenfield hard cutover; call-site migration by mode-preserving mapping

No production rules exist, so there is no data migration — only test and
internal call-site churn. Existing scalar multiplicities migrate to
preserve today's *observable* behaviour:

| Old multiplicity (by mode) | New `{Min, Max}`   | Rationale                                                                                 |
| -------------------------- | ------------------ | ----------------------------------------------------------------------------------------- |
| any mode, integer `K`      | `{K, K}`           | mints/surfaces K exactly as before                                                        |
| `mandatory`, `unbounded`   | n/a (was an error) | the error is retired; rewrite test to `{1, unbounded}` ⇒ mint 1, or to the intended floor |
| `auto`, `unbounded`        | `{0, unbounded}`   | old auto-unbounded created nothing (failed outcome); `{0, unbounded}` mints 0, no failure |
| `propose`, `unbounded`     | `{1, unbounded}`   | preserves "something is surfaced" (one proposal) while the ceiling rides on `Max`         |

The migration is applied per call site with knowledge of the test's intent;
the table is the default mapping, not a blind substitution.

---

## 3. Algorithm / Touch-points

### 3.1 Validation — `graphdb_rules:validate_multiplicity/1`

Rewrite per BP-D4. `validate_composition/5` and `validate_connection/6`
call it unchanged.

### 3.2 Deployment write — `graphdb_rules:do_create_rule/...`

The deployment AVP list on the forward `applies_to` arc becomes:

```erlang
DeployAVPs = [#{attribute => ?ARC_TEMPLATE,                value => DefaultTemplate},
              #{attribute => State#state.mode_attr,        value => Mode},
              #{attribute => State#state.multiplicity_attr, value => {Min, Max}}].
```

Only the `multiplicity` AVP's value shape changes.

### 3.3 B1 decode — `graphdb_rules:decode_deployment/2`

No code change beyond the doc comment: the fold already copies the AVP
value into `#{multiplicity => V}`, so `V` is now `{Min, Max}`. Downstream
consumers (B2/B3 firing, B4) destructure the tuple.

### 3.4 B2 mandatory — `graphdb_rules:plan_mandatory/5` + `expand_children/8`

`plan_mandatory` reads `{Min, Max} = maps:get(multiplicity, Deploy, {1, 1})`
and drives the mandatory cascade to **`Min`** children (today's
`expand_children` loop bound `Mult` becomes `Min`). The `unbounded` clause
and its `unbounded_multiplicity_not_fireable` failure are **deleted**
(BP-D3). The zero-level self-nest cut (B2-D5) is unchanged; with `Min = 0`
the loop simply produces no children.

### 3.5 B2 auto — `graphdb_instance:fire_one_auto/5` + `fire_auto_children/8`

`fire_one_auto` reads `{Min, _Max}` and `fire_auto_children` mints **`Min`**
children post-commit (loop bound `Mult` becomes `Min`). The `unbounded`
clause and its `failed` outcome are **deleted** (BP-D3).

### 3.6 B3 propose — `graphdb_instance:fire_one_propose/5` + `propose_children/7`

`fire_one_propose` reads `{Min, Max}`. Per the **BP-OI-2 fork**:

- **(a)** `propose_children` emits **`Min`** `proposed` outcomes (loop bound
  `Mult` becomes `Min`); the `index => unbounded` branch is deleted.
- **(b)** `propose_children` emits **`Min`** `proposed` outcomes, each (or a
  single range outcome) carrying `max => Max`; `Max = unbounded` preserves
  today's open-ended meaning instead of the `index => unbounded` sentinel.

Either way the loop bound becomes `Min`; the only difference is whether the
outcome carries `Max`. Settle BP-OI-2 before this step is planned.

### 3.7 Child naming — `graphdb_rules:rule_child_name/4`

The naming context count (the `N` in a `{i}`/"of N" pattern) becomes `Min`
(the count actually being created), consistent across all three firing
paths. Signature unchanged; callers pass `Min` where they passed `Mult`.

---

## 4. Validation / Error Catalogue

| Condition                                                | Result                                    |
| -------------------------------------------------------- | ----------------------------------------- |
| `{Min, Max}`, `Min ≥ 0`, `Max` integer `≥ 1` and `≥ Min` | `ok`                                      |
| `{Min, unbounded}`, `Min ≥ 0`                            | `ok`                                      |
| `{Min, Max}` with `Max < Min`, or `Max < 1`              | `{error, invalid_multiplicity}`           |
| bare integer, bare `unbounded`, or any other term        | `{error, invalid_multiplicity}`           |
| `mandatory` with `Min = 0`                               | `ok` (vacuous; permissive, BP-D4/BP-OI-3) |

**Retired** (no longer produced anywhere): `unbounded_multiplicity_not_fireable`
(PLAN and auto-outcome) and the propose `index => unbounded` outcome (BP-D3).

---

## 5. Files Touched (for the writing-plans handoff)

| File                                                                | Change                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_rules.erl`                                | `validate_multiplicity/1` rewrite (BP-D4); deployment AVP value → `{Min, Max}` (§3.2); `plan_mandatory`/`expand_children` use `Min`, drop `unbounded` branch (§3.4); `rule_child_name/4` count → `Min` (§3.7); `decode_deployment/2` doc comment                                                                 |
| `apps/graphdb/src/graphdb_instance.erl`                             | `fire_one_auto`/`fire_auto_children` use `Min`, drop `unbounded` branch (§3.5); `fire_one_propose`/`propose_children` use `Min`, drop `index=unbounded` branch (§3.6)                                                                                                                                            |
| `apps/graphdb/test/graphdb_rules_SUITE.erl`                         | migrate every multiplicity **authoring arg** AND every **assertion on the decoded deployment map** (`effective_rules_for_class/2` round-trips: `multiplicity => K` → `{Min, Max}`) to `{Min, Max}` (BP-D6); rewrite the `unbounded_multiplicity_not_fireable` mandatory cases; add `{Min, Max}` validation cases |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`                      | migrate firing cases to `{Min, Max}` (authoring args + any `deployment`/report assertions); rewrite the auto `unbounded_multiplicity_not_fireable` case; resolve the propose `index=unbounded` case per the BP-OI-2 fork                                                                                         |
| `apps/graphdb/src/graphdb_rules.erl` doc / `apps/graphdb/CLAUDE.md` | note `multiplicity` deployment value is `{Min, Max}`; `create_*_rule` multiplicity param type                                                                                                                                                                                                                    |
| `docs/designs/f4-graphdb-rules-design.md`                           | record the `{Min, Max}` shape (D5 deployment AVPs) and the retirement of `unbounded_multiplicity_not_fireable` / propose `index=unbounded`                                                                                                                                                                       |
| `README.md` / test-count tables                                     | CT count shift (validation cases added, special-case tests rewritten)                                                                                                                                                                                                                                            |

No change to `apps/graphdb/priv/bootstrap.terms`,
`docs/diagrams/ontology-tree.md`, or any seed (BP-D5).

---

## 6. Decision Log

| ID    | Decision                                                                                                                                                                                             |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BP-D1 | `multiplicity :: {Min, Max}` across **both** rule kinds; `Min` non-neg floor, `Max` `pos_int \| unbounded` cap; `unbounded` only as `Max`.                                                           |
| BP-D2 | Firing materialises **`Min`** (mandatory mint, auto mint, propose surface); `Max` recorded, not fired — the future interactive-session ceiling.                                                      |
| BP-D3 | Retire `unbounded_multiplicity_not_fireable` (PLAN + auto) — `Min` is always finite, so every creation rule fires. The propose `index => unbounded` case follows the BP-OI-2 fork, not retired here. |
| BP-D4 | `validate_multiplicity/1` accepts `{Min, Max}` with `Min ≥ 0`, `Max ≥ 1` (or `unbounded`), `Max ≥ Min`; else `invalid_multiplicity`. `mandatory` + `Min = 0` permissive.                             |
| BP-D5 | No new seed/literal/ontology-tree change; `decode_deployment` carries the tuple transparently; `create_*_rule` arities unchanged (param **type** only).                                              |
| BP-D6 | Greenfield hard cutover; call sites migrate by the mode-preserving mapping table (`K → {K, K}`, etc.).                                                                                               |

---

## 7. Open Issues (carried, not resolved here)

- **BP-OI-1 (future feature).** **Interactive creation session.** Consume
  `Max`: let a human user or an autonomous agent add children (and, with
  B4, connections) beyond `Min`, up to `Max`. B-prep only stores `Max`;
  this is where it earns its keep. Likely pairs with B3 propose (the
  always-in-report signal an agent would read) and B4's resolver.
- **BP-OI-2 (DECISION NEEDED before the plan is written).** Propose count
  under a range — the one point beyond David's stated directive, and it
  overturns/uses a deliberate B3 decision (OI-B3-1). **(a)** surface `Min`
  discrete outcomes, retire `index => unbounded`; or **(b)** surface `Min`
  outcomes carrying `max => Max` so the report keeps the open-ended ceiling
  for the autonomous-agent / interactive session (leaning recommendation,
  since that is what `Max` is for). See BP-D2 / §3.6. Not a follow-up — a
  gate on the propose firing-path edit.
- **BP-OI-3 (validation hardening).** Optionally reject `mandatory` +
  `Min = 0` as a contradiction (a mandatory rule that requires nothing).
  Left permissive for now (BP-D4); revisit if it causes confusion.

---

## 8. Test Plan Outline

(Full TDD steps belong in the implementation plan; this is coverage intent.)

- **Validation** — `{1, 1}`, `{0, 3}`, `{2, unbounded}` accepted; `{3, 1}`
  (Max < Min), `{1, 0}` (Max < 1), bare `5`, bare `unbounded`, `{a, b}`
  rejected with `invalid_multiplicity`.
- **Authoring round-trip** — `create_composition_rule` / `create_connection_rule`
  store `{Min, Max}` on the `applies_to` arc; `effective_rules_for_class/2`
  decodes `multiplicity => {Min, Max}` in the deployment map.
- **Mandatory mint = Min** — a `mandatory` `{2, 5}` composition rule mints
  exactly 2 children in the root transaction; `{0, 3}` mandatory mints
  none; `{1, unbounded}` mints one (no `unbounded_multiplicity_not_fireable`).
- **Auto mint = Min** — `auto` `{2, 5}` mints two post-commit; `{0, unbounded}`
  mints none and does not fail.
- **Propose surface = Min** — `propose` `{3, 5}` surfaces three `proposed`
  outcomes. The `{1, unbounded}` case depends on the BP-OI-2 fork: (a) one
  outcome, no `index=unbounded`; or (b) one outcome carrying `max =>
  unbounded`.
- **Retirement** — assert no creation path produces
  `unbounded_multiplicity_not_fireable` anymore. (The propose
  `index=unbounded` outcome's fate follows BP-OI-2.)
- **Behaviour preservation** — the migrated `{K, K}` cases reproduce the
  pre-refactor child counts and report shapes.
