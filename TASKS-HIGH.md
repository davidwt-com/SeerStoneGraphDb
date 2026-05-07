# SeerStoneGraphDb — High-Severity Tasks

Single-statement bugs against spec semantics. Each one means the engine
silently produces a wrong answer for a case the spec calls out
explicitly.

Tasks are listed in execution order. H1 and H2 were isolated bugs in
`graphdb_instance` and have landed (see RESOLVED markers below); they
also closed M2. H0 establishes a project-wide invariant that H3 and
H4 will build on. H3–H5 require API/schema-shape changes for
multi-parent / multi-class semantics and should land together.

---

## H0. Establish the "arcs authoritative; hierarchy lists cached" invariant

**Spec:** see `arcs-authoritative.md` for the full decision record.

**Substeps** (each substep ends with a commit; PR opens only after
H0e):

  - **H0a.** Charter + task plan. Land `arcs-authoritative.md` and
    this checklist. No code changes.
  - **H0b.** Add `parents :: [integer()]` and
    `classes :: [integer()]` cache fields to the `node` record.
    Migrate every `node.parent` read site. Populate the new caches
    transactionally in `graphdb_class`, `graphdb_instance`,
    `graphdb_attr`, and `graphdb_bootstrap` write paths. Tests
    continue to pass with the caches populated as length-1 lists
    (single-parent semantics preserved).
  - **H0c.** Implement `graphdb_mgr:verify_caches/0` and
    `graphdb_mgr:rebuild_caches/0`. Wire `verify_caches/0` into every
    CT testcase that mutates state. Add direct CT coverage for the
    new APIs.
  - **H0d.** Switch the bootstrap loader to Option B. Drop the parent
    field from `{node, ...}` tuples in
    `apps/graphdb/priv/bootstrap.terms`; keep the existing per-arc
    `%%` comments. Loader writes nodes with `parents = []`,
    `classes = []`, then writes the arcs, then calls
    `rebuild_caches/0` and `verify_caches/0`.
  - **H0e.** Update `ARCHITECTURE.md` to absorb the invariant and the
    cache pattern (see "Future work" section in
    `arcs-authoritative.md`). Mark H0 RESOLVED here and M1 RESOLVED
    in `TASKS-MEDIUM.md`. PR opens after this commit.

**Why before H3:** H3 introduces the first non-bootstrap multi-parent
case. Landing the invariant first means H3 is a small additive change
(`add_superclass/2` and a multi-parent ancestor walk via the cache)
rather than a schema migration tangled with semantic changes.

**Dependencies:** none. Closes M1 on completion.

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

## H3. Classes support only single inheritance

**Spec:** §5 Taxonomy — *"Multiple inheritance is supported natively. A
concept may have any number of generalizations simultaneously."*

**Evidence:**
- `graphdb_class.erl:183` — `create_class(Name, ParentClassNref)` takes
  a single parent.
- `graphdb_class.erl:601-627` — `do_walk_ancestors/2` walks the single
  `node.parent` field.
- `graphdb_class.erl:638-651` — `do_inherited_attributes` builds on the
  single-chain ancestor walk.

The class taxonomy is also stored in 25/26 arcs; multi-parent inheritance
can only live there. The current ancestor walk ignores arcs entirely.

**Fix:**
- New API: `add_superclass/2 :: (ClassNref, AdditionalParentNref) -> ok`.
  Writes a 25/26 arc pair without touching `node.parent`.
- Rewrite `do_walk_ancestors` to traverse via the relationships table —
  read incoming arcs with `characterization =:= ?CLASS_PARENT_ARC` for
  each class as it's visited. Returns a DAG (deduplicated) in BFS order.
- `node.parent` retained as the *primary* (creation-time) parent;
  additional parents live as arcs only.

**Dependencies:** clean implementation benefits from C1 (filter arcs by
kind=taxonomy).

---

## H4. Instances support only single class membership

**Spec:** §5 Instantiation — *"A single instance may belong to multiple
classes simultaneously."*

**Evidence:** `graphdb_instance.erl:171, 313-386`. `create_instance/3`
takes one `ClassNref` and writes one 29/30 membership pair. No
`add_class_membership/2` after creation.

**Fix:**
- New API: `add_class_membership/2 :: (InstanceNref, ClassNref) -> ok`.
  Writes a second 29/30 arc pair.
- New API: `class_memberships/1 :: (InstanceNref) -> {ok, [ClassNref]}`.
  Reads all 29-characterized outgoing arcs.

**Dependencies:** none structurally; the resolver work is H5.

---

## H5. `resolve_from_class` silently picks the first class membership

**Spec:** §6 — *"Two parent classes may define the same attribute with
different bound values — resolution requires an explicit local value on
the instance."*

**Evidence:** `graphdb_instance.erl:564-587`. `lists:search/2` returns
the first match; whichever Mnesia hands back first wins. No ambiguity
detection, no error, no signal that two classes might conflict.

**Fix:** read *all* membership arcs. For each class (and its taxonomy
ancestors per H1), look up the AVP. If multiple distinct values are
found, return `{error, {ambiguous_class_value, AttrNref, [{ClassNref,
Value}]}}`. If exactly one value is found, return `{ok, Value}`. If
none, fall through to Priority 3.

**Dependencies:** H4 (so the multi-membership case is reachable), H1
(so ancestors are checked). The fix is naturally part of the same
rewrite.
