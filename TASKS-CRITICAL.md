# SeerStoneGraphDb — Critical Tasks

Schema-level departures from `the-knowledge-network.md`. These change the
shape of the `relationship` record. Land them before the database has live
data — adding either field afterwards is a Mnesia schema transformation.

Both items touch every module that defines `-record(relationship, ...)`:
`graphdb_bootstrap.erl`, `graphdb_attr.erl`, `graphdb_class.erl`,
`graphdb_instance.erl`, `graphdb_mgr.erl`.

---

## C1. Add `template_nref` field to the `relationship` record

**Spec:** §5 Connection (ASSOCIATE) — *"every connection is scoped by the
template context in which it was made. The template context is recorded as
part of the connection's identity permanently. This prevents semantic
conflation by design."*

**Evidence:** `graphdb_bootstrap.erl:74-81` — the canonical record. The
field is absent.

**Change:**

```erlang
-record(relationship, {
    id,
    source_nref,
    characterization,
    target_nref,
    reciprocal,
    template_nref,    %% integer() | undefined  (undefined for non-Connection arcs)
    avps
}).
```

`template_nref = undefined` for Taxonomy, Composition, and Instantiation
arcs. A concept nref for every Connection arc.

**Touches:** all five record definitions; `graphdb_bootstrap:expand_relationship/1`
to default `undefined`; `graphdb_instance:do_add_relationship/4` (and any
future `/5` accepting AVPs) to accept and store it.

**Dependencies:** none. Should be done first.

---

## C2. Add `kind` field to the `relationship` record

**Spec:** §5 — *"Relationships between concept nodes are strictly typed.
Four types exist: Taxonomy (IS-A), Composition (PART-OF), Connection
(ASSOCIATE), Instantiation (IS-INSTANCE-OF)."*

**Evidence:** Same record definitions as C1. Today the four types are
distinguishable only by which `characterization` nref happens to be in use
(e.g., 27/28 ⇒ composition, 29/30 ⇒ instantiation, 25/26 ⇒ class taxonomy).
Code that needs the type pattern-matches on bootstrap nref constants —
see `graphdb_instance.erl:570` (`?CLASS_MEMBERSHIP_ARC`) and the
`?INST_*_ARC` / `?CLASS_*_ARC` / `?ATTR_*_ARC` macros throughout.

**Change:**

```erlang
-record(relationship, {
    id,
    kind,             %% taxonomy | composition | connection | instantiation
    source_nref,
    characterization,
    target_nref,
    reciprocal,
    template_nref,
    avps
}).
```

Bootstrap loader assigns `kind` based on the characterization nref (or
better: the bootstrap.terms file declares it explicitly).

**Why this matters:**
- §13 multi-criteria queries can filter by relationship type cheaply.
- §7 templates can constrain which connection types are valid in a
  context.
- §11 connection-pattern learning groups observations by type.
- H5 (filter Priority 4 to lateral connections) becomes a one-line guard.

**Dependencies:** none. Pair with C1.
