<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Medium-Severity Tasks

Semantic departures from `the-knowledge-network.md` plus the surviving
feature work from the original TASKS.md (query language, rules engine).
The kernel works without these, but each one is a load-bearing piece of
the spec that's currently missing or inconsistent.

Earlier items are smaller, mechanical fixes. Later items are major
additive feature areas that should wait until the kernel is correct
under the existing model.

---

## M4. Reciprocal attribute pair must be created in one transaction — RESOLVED

**Status:** Fixed. `graphdb_attr:create_relationship_attribute/3` now
delegates to a private `do_create_relationship_attribute_pair/3` helper
that allocates the 2 node nrefs and 4 compositional arc-id nrefs
outside the transaction (avoiding side-effects on retry) and writes
all 6 rows in a single `mnesia:transaction/1`.  Mid-pair aborts can no
longer leave the database with an orphan half-pair.  CT case
`create_relationship_attribute_pair_atomic` asserts the row deltas
are exactly +2 nodes and +4 relationships after a successful call,
and that both new nodes have exactly one parent->child arc into them
under the Relationships subtree (nref 8).

---

## M3. `add_relationship/4` validates nothing — RESOLVED

**Status:** Fixed. `graphdb_instance:add_relationship` now runs an
explicit `validate_arc_endpoints/5` pass before resolving classes,
templates, and writing arcs.  All four endpoint reads happen in one
`mnesia:transaction/1`.  Failure modes are returned as structured
errors:

  - `{error, {source_not_found, Nref}}`
  - `{error, {target_not_found, Nref}}`
  - `{error, {characterization_not_found, Nref}}`
  - `{error, {reciprocal_not_found, Nref}}`
  - `{error, {characterization_not_an_attribute, Nref, ActualKind}}`
  - `{error, {reciprocal_not_an_attribute, Nref, ActualKind}}`
  - `{error, {target_kind_mismatch, ExpectedKind, ActualKind}}`

The seeded `target_kind` literal-attribute nref is fetched from
`graphdb_attr:seeded_nrefs()` once at `graphdb_instance:init/1` and
cached in a new gen_server state record.  Arc-label nodes that don't
carry a `target_kind` AVP (relationship-type bucket nodes, legacy
data) skip the kind check.

Tests: 5 CT cases under the `relationships` group covering the new
reject paths.

---

## M5. `add_relationship` cannot accept per-arc AVPs at creation — RESOLVED

**Status:** Fixed. New API
`graphdb_instance:add_relationship/6 :: (Source, Char, Target, Reciprocal,
TemplateNref, {FwdAVPs, RevAVPs}) -> ok | {error, _}` accepts
per-direction user AVPs and stamps them on the two connection rows
alongside the auto-applied Template AVP.  Per-direction is required
by §5: connection metadata such as provenance, confidence, weights,
and validity windows is direction-specific.

The Template AVP stays at index 0 of each row's `avps` list; user
AVPs follow.  `/4` and `/5` stay non-breaking and pass `{[], []}` to
`/6` internally.  `write_connection_arcs` was updated to thread the
AVP spec through; the gen_server message form gained an `AVPSpec`
element.

Tests: 3 CT cases under the `relationships` group:
- `add_relationship_stamps_user_avps` — user AVP appears alongside
  Template AVP on the forward row
- `add_relationship_avps_are_per_direction` — fwd-only AVP doesn't
  leak into the reverse row, and vice versa
- `add_relationship_default_avps_empty` — `/4` still produces a row
  carrying exactly the Template AVP

---

## M2. `resolve_from_class` should consult `graphdb_class`, not Mnesia directly — RESOLVED

**Status:** Closed by H1. `resolve_from_class` now drives the class
walk through `graphdb_class:get_class/1` and
`graphdb_class:ancestors/1` instead of reading the `nodes` table
directly; the membership arc lookup reuses `do_class_of/1` so
`?CLASS_MEMBERSHIP_ARC` is no longer hard-coded inside the resolver.

---

## M1. PART-OF stored in two places with no consistency invariant — RESOLVED

**Status:** Closed by H0 (PR #10, commit `4e56761`). The decision:
arcs are authoritative, `node.parents`/`node.classes` are caches with
a hard invariant enforced by `graphdb_mgr:verify_caches/0` (run in
every CT `end_per_testcase` and at bootstrap load completion).
Single-writer ownership rule documented in `arcs-authoritative.md`
and `ARCHITECTURE.md` §3.

---

## M8. Attribute "type" (name vs. literal vs. relationship) is implied by parent subtree

**Spec:** §4 — *"The distinction between relationship attributes and
literal attributes is architecturally significant."*

**Evidence:** `graphdb_attr.erl:303-328`. The three `create_*_attribute`
paths put nodes under different parents (Names=6, Literals=7,
Relationships=8). The node carries no AVP marking its type. Inferring
the type at query time means walking the parent chain.

**Fix:** add an `attribute_type :: name | literal | relationship` AVP at
creation time, keyed by a new seeded `attribute_type` literal attribute.
Or add a dedicated field to the node record (smaller change to the
record set already touched by Critical tasks).

---

## Task 6 — `graphdb_language` query language

**Spec:** §13 (query) and §15 (multilingual).

**Evidence:** `apps/graphdb/src/graphdb_language.erl` is a gen_server stub
returning `?UEM` on every call.

**Scope (per §13/§15, broader than the original TASKS.md description):**
- Multi-criteria queries spanning class membership, attribute values,
  and connections in one query.
- Unit-tracked quantity expressions.
- Template-filtered traversal — depends on C3.
- Language-tagged label resolution at render time — depends on M6.
- Conversational/natural-language entry point (§13).

**Sub-tasks:**
- Define query DSL (term-shaped representation; natural-language frontend
  is later).
- `parse_query/1`, `execute_query/1`.
- Path queries: `find_path/3`.
- Render-time label lookup honoring a per-call `Language :: atom()`.

**Dependencies:** value from this work multiplies after C1 (relationship
kind) and H1, H3–H5 (correct inheritance). Recommend not starting until
those land.

---

## M6. Language-neutral name storage (multilingual support)

**Spec:** §15 — *"Concepts are stored language-neutrally in the
ontology. Labels, prompts, and vocabulary entries are stored per
language and swapped at rendering time without modifying the
knowledge."*

**Evidence:** `bootstrap.terms:41-90` — every node carries
`{17|18|19|20, "Root" | "Names" | ...}` literally as Erlang strings.
`graphdb_attr.erl:425-429` (and equivalent in `graphdb_class.erl:390-394`)
searches by raw string equality. The Languages category (nref 4) is in
the bootstrap but no code reads from it.

**Two options:**

A) **Per-language map AVPs** — name AVP value becomes
   `#{en => "Root", de => "Wurzel"}`. Render-time lookup:
   `maps:get(Lang, M, maps:get(en, M))`.

B) **Label nodes** — names become first-class concept nodes with
   per-language AVPs, connected to the labelled concept via a "label"
   characterization. Section 3 ("Make searchable things into nodes")
   pushes toward this — *"If 'blue' is a literal value stored on
   instances, there is no path to 'find everything that is blue.'"*

**Recommended:** option B for instance/class/attribute names. Ontology
labels (the bootstrap-fixed names) can stay as map AVPs in option A
since they aren't searched-from.

**Dependencies:** harder to do later than now — every name AVP touched.
Prefer to land before any project ships with significant data.

---

## M7. Template support

**Spec:** §7 — *"A **template** is a named semantic context defined on a
class in the ontology. ... Not a blank form waiting to be filled — it
is an active node in the ontology."* Architecturally novel and
load-bearing per §16.

**Evidence:** No template node kind, no `Templates` subtree in the
bootstrap, no `graphdb_template` worker, no template field on
relationships (covered separately by C3).

**Sub-tasks:**
- Decide template representation: 5th node `kind = template`, or
  `kind = class` with an `is_template = true` AVP. (AVP approach is
  more consistent with existing patterns; node-kind approach is more
  type-checkable.)
- Seed a `Templates` subtree at runtime under Classes (nref 3) by the
  worker on first start.
- API: `create_template/2 (Name, ClassNref)`, `attach_template/2`,
  `templates_for_class/1`.
- Template-scoped `add_relationship` — caller specifies the template
  nref, which is recorded as the `Template` AVP on the connection (C3).
- Template-scoped queries — find connections through a specific
  template only (depends on C1 + Task 6).

**Dependencies:** C3 (Template AVP and per-class default template).
Best landed after the kernel is correct under the existing model.

---

## E1. `graphdb_rules` — rule engine

**Spec:** §8 (rules as stored data), §9 (instantiation engine), §10
(composition rules), §11 (reactive learning).

**Evidence:** `apps/graphdb/src/graphdb_rules.erl` is a gen_server stub.

**Scope (much larger than the original TASKS.md "graph rules"):**

- **§10 composition rules** — class declares natural-constituent
  component types and mandatory connections. Engine fires at
  `create_instance` to propose/auto-create components.

- **§9 instantiation engine** — *guided* mode (one attribute at a time,
  ontology constrains options) and *automatic* mode (values derived
  from existing knowledge). Mode chosen by the ontology, not the
  kernel.

- **§11 reactive learning** —
  - *Naming-convention learning*: on attribute set, scan other AVPs on
    the same instance for substring matches; encode detected pattern as
    a class-level rule.
  - *Connection-pattern learning*: on connection creation, record the
    (source class, template, target class, connection type) tuple;
    accumulate into connection rules.

- All rules stored as typed data in the ontology (kind = `class` with a
  `is_rule = true` AVP, or a new `kind = rule` — same decision as
  templates).

**Dependencies:** value depends on C1 (kind), H1 and H3–H5 (correct
inheritance), C3+M7 (templates for connection-pattern learning). This
is genuinely a future-feature track — but called out in the spec as
core, not incidental.
