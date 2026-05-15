<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Resolved Tasks

Archive of completed work. Entries are in the order they were resolved.
See `TASKS.md` for active remaining work.

---

## M1. PART-OF stored in two places with no consistency invariant — RESOLVED

**Status:** Closed by H0 (PR #10, commit `4e56761`). The decision:
arcs are authoritative, `node.parents`/`node.classes` are caches with
a hard invariant enforced by `graphdb_mgr:verify_caches/0` (run in
every CT `end_per_testcase` and at bootstrap load completion).
Single-writer ownership rule documented in `arcs-authoritative.md`
and `ARCHITECTURE.md` §3.

---

## M2. `resolve_from_class` should consult `graphdb_class`, not Mnesia directly — RESOLVED

**Status:** Closed by H1. `resolve_from_class` now drives the class
walk through `graphdb_class:get_class/1` and
`graphdb_class:ancestors/1` instead of reading the `nodes` table
directly; the membership arc lookup reuses `do_class_of/1` so
`?CLASS_MEMBERSHIP_ARC` is no longer hard-coded inside the resolver.

---

## M3. `add_relationship/4` validates nothing — RESOLVED

**Status:** Fixed. `graphdb_instance:add_relationship` now runs an
explicit `validate_arc_endpoints/5` pass before resolving classes,
templates, and writing arcs. All four endpoint reads happen in one
`mnesia:transaction/1`. Failure modes are returned as structured
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
cached in a new gen_server state record. Arc-label nodes that don't
carry a `target_kind` AVP skip the kind check.

Tests: 5 CT cases under the `relationships` group covering the new
reject paths.

---

## M4. Reciprocal attribute pair must be created in one transaction — RESOLVED

**Status:** Fixed. `graphdb_attr:create_relationship_attribute/3` now
delegates to a private `do_create_relationship_attribute_pair/3` helper
that allocates the 2 node nrefs and 4 compositional arc-id nrefs
outside the transaction (avoiding side-effects on retry) and writes
all 6 rows in a single `mnesia:transaction/1`. Mid-pair aborts can no
longer leave the database with an orphan half-pair.

Tests: CT case `create_relationship_attribute_pair_atomic` asserts
the row deltas are exactly +2 nodes and +4 relationships after a
successful call, and that both new nodes have exactly one parent→child
arc into them under the Relationships subtree (nref 8).

---

## M5. `add_relationship` cannot accept per-arc AVPs at creation — RESOLVED

**Status:** Fixed. New API
`graphdb_instance:add_relationship/6 :: (Source, Char, Target, Reciprocal,
TemplateNref, {FwdAVPs, RevAVPs}) -> ok | {error, _}` accepts
per-direction user AVPs and stamps them on the two connection rows
alongside the auto-applied Template AVP. Per-direction is required
by §5: connection metadata such as provenance, confidence, weights,
and validity windows is direction-specific.

The Template AVP stays at index 0 of each row's `avps` list; user
AVPs follow. `/4` and `/5` stay non-breaking and pass `{[], []}` to
`/6` internally.

Tests: 3 CT cases under the `relationships` group:
- `add_relationship_stamps_user_avps`
- `add_relationship_avps_are_per_direction`
- `add_relationship_default_avps_empty`

---

## M7. Template support — RESOLVED

**Spec:** §7 — *"A **template** is a named semantic context defined on
a class in the ontology. ... Not a blank form waiting to be filled —
it is an active node in the ontology."*

**Status:** Substantively landed during the H-task series alongside
the Connection-arc and Template-AVP work. What landed:

  - 5th node kind: `kind = template`. Validated by
    `graphdb_bootstrap:kind_order/1` (template = 5).
  - Bootstrap node 31 — `Template` AVP-marker attribute, parented to
    nref 16 (Instance Relationships). Stamped with
    `relationship_avp => true` post-bootstrap.
  - **Per-class templates**: templates are written as compositional
    children of their owning class. Each `create_class/2` automatically
    attaches a `"default"` template; class authors may `add_template/2`
    more, or delete the default to force explicit template specification
    on every connection arc.
  - Public API on `graphdb_class`: `add_template/2`, `get_template/1`,
    `templates_for_class/1`, `default_template/1`,
    `class_in_ancestry/2`.
  - Template-scoped `add_relationship` on `graphdb_instance`: `/4`
    resolves the source class's default template; `/5` accepts an
    explicit `TemplateNref`; `/6` adds per-direction user AVPs (M5).
    Template AVP `#{attribute => 31, value => TemplateNref}` is stamped
    at index 0 of each connection row's AVP list. Out-of-scope templates
    produce `{error, {template_class_not_in_ancestry, ...}}`.

Tests: `graphdb_class_SUITE` templates group (7 cases),
`graphdb_instance_SUITE` connection-arc cases (4 cases),
`graphdb_attr_SUITE` seeding group (2 cases),
`graphdb_bootstrap_tests.erl` kind_order cases.

---

## M8. Attribute "type" implied by parent subtree — RESOLVED

**Status:** Fixed via AVP-based marker. `graphdb_attr` seeds a fourth
runtime literal attribute, `attribute_type`, alongside `literal_type`,
`target_kind`, and `relationship_avp`. All `create_*` paths stamp an
`#{attribute => attribute_type_nref, value => name|literal|relationship}`
AVP on the new node. Bootstrap attribute nodes (nrefs 6–31) are
retro-stamped at `graphdb_attr:init/1` by walking the `parents` cache.

New public API: `graphdb_attr:attribute_type_of/1` returns
`{ok, name | literal | relationship}` directly from the AVP.

Tests: 10 CT cases under the `attribute_type` group.
