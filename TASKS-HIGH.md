# SeerStoneGraphDb — High-Severity Tasks

Single-statement bugs against spec semantics. Each one means the engine
silently produces a wrong answer for a case the spec calls out
explicitly.

Tasks are listed in execution order. H1 and H2 are isolated bugs in
`graphdb_instance` and can be fixed before the multi-inheritance work
(H3–H5). H3–H5 require API/schema-shape changes for multi-parent /
multi-class semantics and should land together.

---

## H1. `resolve_from_class` does not walk the class taxonomy

**Spec:** §5 Taxonomy — *"Golden Retriever IS-A Dog IS-A Mammal IS-A
Animal. Golden Retriever inherits every attribute defined at every level
above it."* §6 Priority 2 — class-bound values must include all
ancestors of the class.

**Evidence:** `graphdb_instance.erl:564-587`. After locating the
membership arc, the code reads exactly one class node's AVPs:

```erlang
{atomic, [#node{attribute_value_pairs = AVPs}]} ->
    find_avp_value(AVPs, AttrNref);
```

Values bound on the superclass are invisible. `graphdb_class:do_ancestors/1`
already produces the chain — `graphdb_instance` should ask for it.

**Fix:** in `resolve_from_class`, after finding the class, call
`graphdb_class:get_class/1` then `graphdb_class:ancestors/1` and walk
the resulting list, returning the first AVP match. Subsumes M2.

**Dependencies:** none. Most consequential single line of incorrect
code in the codebase.

---

## H2. Priority 4 ("directly connected nodes") double-walks Priorities 2 and 3

**Spec:** §6 Priority 4 — *"Directly connected nodes (one level deep
only; lowest priority)."* The intent is non-hierarchical lateral
connections.

**Evidence:** `graphdb_instance.erl:623-635`. `resolve_from_connected`
reads every outgoing relationship via `mnesia:index_read/3`. The result
includes the instance→class membership arc (29) and the
instance→compositional-parent arc (27) — both already searched at higher
priority. A value present on the class or compositional parent can come
back via Priority 4 instead of returning `not_found`.

**Fix (after C1):** filter `Rels` to `R#relationship.kind =:= connection`
before pulling target nrefs.

**Fix (before C1, interim):** filter out characterizations equal to
`?CLASS_MEMBERSHIP_ARC`, `?INST_PARENT_ARC`, `?INST_CHILD_ARC`. Ugly but
correct.

**Dependencies:** clean fix depends on C1.

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
