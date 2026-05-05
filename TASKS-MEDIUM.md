# SeerStoneGraphDb — Medium-Severity Tasks

Semantic departures from `the-knowledge-network.md` plus the surviving
feature work from the original TASKS.md (query language, rules engine).
The kernel works without these, but each one is a load-bearing piece of
the spec that's currently missing or inconsistent.

Earlier items are smaller, mechanical fixes. Later items are major
additive feature areas that should wait until the kernel is correct
under the existing model.

---

## M4. Reciprocal attribute pair must be created in one transaction

**Spec:** §5 — reciprocal characterization is part of every connection's
identity.

**Evidence:** `graphdb_attr.erl:313-324`. `create_relationship_attribute/3`
creates the forward attribute node in one transaction, then the reciprocal
in a separate transaction. If the second aborts, the database is left
with a half-pair: the forward arc-label exists, with no usable
reciprocal.

**Fix:** allocate both nrefs and both relationship-id nrefs outside,
then write both nodes and all four compositional arc rows inside a
single `mnesia:transaction/1`.

---

## M3. `add_relationship/4` validates nothing

**Spec:** §5 — relationships are *strictly typed*.

**Evidence:** `graphdb_instance.erl:420-446`. No check that `SourceNref`
or `TargetNref` exist; no check that `CharNref` and `ReciprocalNref`
reference attribute nodes; no check that the characterization's
`target_kind` AVP matches the actual target node's kind.

**Fix:** inside the transaction, read source/target/characterization/
reciprocal. Reject if missing; reject if char/reciprocal aren't kind=
attribute; reject if target's kind disagrees with the characterization's
`target_kind` AVP.

---

## M5. `add_relationship` cannot accept per-arc AVPs at creation

**Spec:** §5 Connection — per-arc metadata (provenance, confidence,
weights, validity time frames) is part of the connection.

**Evidence:** `graphdb_instance.erl:182, 420-446`. `avps = []` hardcoded
on both directions. No `/5` variant accepting AVPs.

**Fix:** add `add_relationship/5 :: (Source, Char, Target, Reciprocal,
{FwdAVPs, RevAVPs})`. Per-direction AVPs because §5 says metadata is
asymmetric. `/4` becomes a thin wrapper passing `{[],[]}`.

**Dependencies:** prefer to land alongside C3 so the `/5` signature
already accommodates the `Template` AVP for connection arcs without a
later signature change.

---

## M2. `resolve_from_class` should consult `graphdb_class`, not Mnesia directly

**Evidence:** `graphdb_instance.erl:564-587` reads class data via
`mnesia:read(nodes, ClassNref)` rather than calling
`graphdb_class:get_class/1`. Worker boundaries blur — `graphdb_instance`
hardcodes `?CLASS_MEMBERSHIP_ARC` and the class node layout.

**Fix:** subsumed by H1. Once `resolve_from_class` walks the taxonomy,
it should ask `graphdb_class` for the chain rather than re-implementing
Mnesia reads.

**Dependencies:** H1.

---

## M1. PART-OF stored in two places with no consistency invariant

**Evidence:** `graphdb_instance.erl:326-386`. `create_instance` writes
`node.parent = ParentNref` AND a 27/28 arc pair. No invariant check;
nothing prevents the two from diverging.

**Decision needed:** is `node.parent` a denormalized cache of the 27-arc,
or are the arcs themselves the cache?

**Recommended:** treat `node.parent` as the cache (it's there for the
O(1) `mnesia:index_read(nodes, _, #node.parent)` lookup). Document the
invariant and add an assertion in tests. Any future re-parent or delete
operation must update both. (Single compositional parent only; multiple
compositional parents are flagged as a smell in §6 and intentionally
not supported.)

**Dependencies:** none. Decide and write down before implementing
delete or re-parent operations.

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
