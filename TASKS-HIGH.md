<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — High-Severity Tasks

Single-statement bugs against spec semantics. Each one means the engine
silently produces a wrong answer for a case the spec calls out
explicitly.

Tasks are listed in execution order. **All H-tasks have landed**
(see RESOLVED markers below). H0 closed M1; H1+H2 closed M2; H4+H5
landed together as the multi-class instance-membership work (API
surface and resolver disambiguation).  Outstanding work continues
under `TASKS-MEDIUM.md` and `TASKS-LOW.md`.

---

## H0. Establish the "arcs authoritative; hierarchy lists cached" invariant — RESOLVED

**Status:** Landed across H0a–H0e. The full decision record is
`arcs-authoritative.md`; the architectural summary is in
`ARCHITECTURE.md` §3.

**Substeps:**
  - **H0a** (`d5a7244`) — charter + task plan landed.
  - **H0b** (`0b5fc43`) — node record retired `parent`, gained
    `parents :: [integer()]` and `classes :: [integer()]` caches.
    Read sites migrated; downward lookups switched to private
    `downward_children_by_arc/3` helpers reading `relationships`.
  - **H0c** (`ce07cb2`) — `graphdb_mgr:verify_caches/0` and
    `rebuild_caches/0` implemented and wired into every CT suite's
    `end_per_testcase`.  4 direct CT cases in `cache_audit` group.
  - **H0d** (`9e5d64a`) — `bootstrap.terms` to Option B (5-tuple node
    form); loader runs `rebuild_caches/0` + `verify_caches/0` after
    writing all rows.
  - **H0e** — this commit; doc fold + RESOLVED markers.

**Closes:** M1 (`TASKS-MEDIUM.md`).

---

## H1. `resolve_from_class` does not walk the class taxonomy — RESOLVED

**Status:** Fixed. `resolve_from_class` now reuses `do_class_of/1` to
locate the membership arc, then asks `graphdb_class:get_class/1` and
`graphdb_class:ancestors/1` for the nearest-first chain and returns
the first AVP match. Two CT cases cover the new behaviour
(`resolve_value_walks_class_taxonomy`,
`resolve_value_local_class_overrides_taxonomy_ancestor`). Subsumes
M2.

---

## H2. Priority 4 ("directly connected nodes") double-walks Priorities 2 and 3 — RESOLVED

**Status:** Fixed. `resolve_from_connected` now filters the outgoing
relationships to `R#relationship.kind =:= connection` before pulling
target nrefs, so instantiation (membership) and composition
(parent/child) arcs no longer feed Priority 4.  CT case
`resolve_value_p4_ignores_compositional_arc` reproduces the previous
leak (a value bound on the compositional parent's category surfacing
via the parent_arc) and now returns `not_found` as the spec requires.

---

## H3. Classes support only single inheritance — RESOLVED

**Status:** Fixed. New API `graphdb_class:add_superclass/2` writes a
25/26 taxonomy arc pair AND appends to the subject class's `parents`
cache in one transaction (idempotent, rejects self-references).
`do_walk_ancestors` rewritten as a BFS over the multi-parent DAG using
the `node.parents` cache; each ancestor is visited at most once
(diamond inheritance returns shared ancestors exactly once). 10 CT
cases under the new `multi_inheritance` group cover basic add, arc
shape, idempotency, validation, multi-parent BFS, diamond dedup,
multi-parent QC inheritance, and `class_in_ancestry` over added
parents. Composition remains a single-chain walk (compositional
hierarchy is a tree, not a DAG).

---

## H4. Instances support only single class membership — RESOLVED

**Status:** Fixed. New API
`graphdb_instance:add_class_membership/2 :: (InstanceNref, ClassNref)
-> ok` writes a 29/30 instantiation arc pair AND appends to the
instance's `classes` cache in one transaction (idempotent; rejects
non-instance subjects, non-class targets, and missing nrefs). New
`class_memberships/1 :: (InstanceNref) -> {ok, [ClassNref]}` reads the
cache (kept consistent with the 29-characterized outgoing arcs by the
H0c invariant). 8 CT cases under the new `multi_membership` group
cover basic add, arc shape, idempotency, four reject paths, and
initial single-membership readback.

**Closes:** delivered together with H5 as the multi-class
instance-membership work.

---

## H5. `resolve_from_class` silently picks the first class membership — RESOLVED

**Status:** Fixed. `resolve_from_class/2` now reads *all* class
memberships via `do_class_memberships/1` and, for each membership,
walks the class node plus its taxonomy ancestors (`graphdb_class:
get_class/1` + `ancestors/1`) for an AVP match.  Hits are gathered as
`[{ClassNref, Value}]` where `ClassNref` is the class that actually
held the value (may be a taxonomy ancestor of a directly-bound
membership). Three outcomes:

- 0 hits -> `not_found` (caller falls through to Priority 3).
- All hits agree on a single distinct value -> `{ok, Value}`.
- Two or more distinct values -> `{error, {ambiguous_class_value,
  AttrNref, Hits}}`.

5 CT cases under `multi_membership` cover unique-across-two-classes,
same-value-two-classes, ambiguous-two-classes, local-overrides-
ambiguity, and ambiguity-via-taxonomy.
