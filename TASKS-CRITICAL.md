# SeerStoneGraphDb — Critical Tasks

Schema-level departures from `the-knowledge-network.md`. These change
the shape of the `relationship` record, the `node` kind atom set, or
the bootstrap scaffold. Land them before the database has live data —
adding any of them afterwards is a Mnesia schema transformation.

These items touch every module that defines `-record(relationship, ...)`
or `-record(node, ...)`: `graphdb_bootstrap.erl`, `graphdb_attr.erl`,
`graphdb_class.erl`, `graphdb_instance.erl`, `graphdb_mgr.erl`.

Tasks are listed in execution order. C1 establishes the relationship
`kind` field (so Connection-vs-other arcs are distinguishable
structurally). C2 adds the `template` node kind (so template nodes can
exist). C3 then seeds the `Template` AVP attribute in bootstrap, wires
auto-default-template creation in `graphdb_class:create_class`, and
adds the template-AVP enforcement rule that depends on both C1 and C2.

---

## C1. Add `kind` field to the `relationship` record

**Spec:** §5 — *"Relationships between concept nodes are strictly
typed. Four types exist: Taxonomy (IS-A), Composition (PART-OF),
Connection (ASSOCIATE), Instantiation (IS-INSTANCE-OF)."*

**Evidence:** Every `-record(relationship, ...)` in
`graphdb_bootstrap.erl:74-81` and the four worker modules. Today the
four types are distinguishable only by which `characterization` nref
happens to be in use (e.g., 27/28 ⇒ composition, 29/30 ⇒
instantiation, 25/26 ⇒ class taxonomy). Code that needs the type
pattern-matches on bootstrap nref constants — see
`graphdb_instance.erl:570` (`?CLASS_MEMBERSHIP_ARC`) and the
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
    avps
}).
```

Bootstrap loader assigns `kind` based on the characterization nref
(or, cleaner: the `bootstrap.terms` syntax declares it explicitly).

**Why this matters:**

- §13 multi-criteria queries can filter by relationship type cheaply.
- §7 templates can constrain which connection types are valid in a
  context.
- §11 connection-pattern learning groups observations by type.
- C3c (enforce template AVP only for `kind = connection`) becomes a
  one-line guard.
- H2 (filter Priority 4 inheritance to lateral connections) becomes a
  one-line guard.

**Dependencies:** none. Done first.

---

## C2. Add `template` to the node kind atom set

**Spec:** §3 — *"every class, attribute, **rule**, **template**,
instance, and vocabulary entry is a concept node."* §7 — *"a template
is... an active node in the ontology."* Templates are listed parallel
to class and attribute, not as a sub-flavor of either.

**Evidence:** Current kind set in records and code:
`category | attribute | class | instance`. No `template`. See the
node record in `graphdb_bootstrap.erl`, the `category_guard` in
`graphdb_mgr.erl`, kind-switching in `graphdb_class:create_class`, and
the kind validation in `graphdb_attr:lookup_attribute`.

**Change:** Extend the kind atom set to:

```erlang
category | attribute | class | instance | template
```

This is a five-way enumeration. Future spec terms (`rule`,
`vocabulary entry`) may extend it further but are out of scope here.

**What template nodes carry** (in `attribute_value_pairs`):

- Relevant attributes for this context (list of attribute nrefs)
- Valid connection types in this context (list of relationship-attribute nrefs, with optional target-class constraints)
- Presentation/expression rules

The exact AVP keys are spec/design work for §7 enforcement; this task
only makes the kind exist.

**Touches:**

- `graphdb_bootstrap.erl`: node record kind comment; kind validation in expand functions.
- `graphdb_mgr.erl`: any `category_guard`-style kind check; ensure templates are immutable-via-class, not directly editable.
- `graphdb_class.erl`: primary writer of `kind = template` nodes (see C3b); template lookup helpers.
- `graphdb_attr.erl`: must accept `kind = template` when looking up nodes, but reject template nrefs from attribute lookups (templates are not attributes).
- `graphdb_instance.erl`: validation that an instance's class arc target has `kind = class`, not `kind = template`.

**Dependencies:** none. Done before C3.

---

## C3. Establish template scoping (AVP + per-class default template)

**Spec:** §7 Templates — *"a template is a named semantic context
defined on a class in the ontology... an active node in the ontology
that determines which attributes of the class are relevant in this
context, how those attributes are expressed and constrained, what
connections made through it mean."* §5 — *"every connection is scoped
by the template context in which it was made. The template context is
recorded as part of the connection's identity permanently."*

**Decision:** Templates are nodes (kind `template`, added in C2) whose
compositional parent is a class node. On a Connection (ASSOCIATE) arc,
the template scope is recorded as an AVP whose attribute key is a
bootstrap-seeded relationship-AVP attribute named `Template` and whose
value is the nref of the chosen template node. No new field is added
to the `relationship` record — AVPs are the right tool for sparse,
identity-defining metadata that only applies to one of the four
relationship kinds.

Three subparts, all of which must land together:

### C3a. Bootstrap-seed the `Template` AVP attribute

Add one node to `apps/graphdb/priv/bootstrap.terms`:

```erlang
%% Level 4 -- relationship-AVP marker attributes
{node, 31, attribute, 16, {18, "Template"}, []}.
```

`parent = 16` (Instance Relationships) because Connection arcs only
exist between instances. The `relationship_avp => true` AVP is applied
post-bootstrap by `graphdb_attr:init/1`, after the flag-attribute
itself is seeded — bootstrap.terms cannot reference a runtime-seeded
nref.

Add the corresponding compositional arc:

```erlang
{relationship, 16, 24, [], 23, 31, []}.  %% Instance Relationships -> Template
```

The bootstrap nref count grows from 30 to 31. Update the BFS
quick-reference in `CLAUDE.md`, `apps/graphdb/CLAUDE.md`, and
`graphdb_bootstrap.erl` header comments.

### C3b. Auto-attach a default template on class creation

In `graphdb_class:create_class/2`, after the new class node is
written, atomically write a child template node:

```erlang
%% kind = template, parent = ClassNref, name AVP "default"
```

The default-template's nref is allocated by `nref_server:get_nref/0`.
Compositional arcs use the class-child arc labels (26/25). Expose
`graphdb_class:add_template/2` for class authors to add further
named templates as compositional children of the same class.

Class authors who want to *force* explicit disambiguation for a class
can delete the default template; subsequent Connection arcs involving
instances of that class then must specify a non-default template.

### C3c. Enforce template-AVP presence-by-kind on relationship writes

In every relationship-write path
(`graphdb_instance:do_add_relationship`, plus any analogous path in
`graphdb_attr` or `graphdb_class`):

- If the relationship `kind` is `connection`: require an AVP
  `#{attribute => 31, value => TemplateNref}` and verify that
  `TemplateNref` resolves to a node whose `kind = template` and whose
  `parent` is a class in the taxonomic ancestry of the source's or
  target's class.
- If the relationship `kind` is anything else: forbid the `Template`
  AVP.

**Touches:** `bootstrap.terms`; `graphdb_attr:init/1` (post-bootstrap
seed of the `relationship_avp` flag on nref 31); `graphdb_class`
(auto-default-template, `add_template/2`); `graphdb_instance`
(template-AVP validation in `do_add_relationship`); BFS
quick-reference comments throughout.

**Dependencies:** C1 (need relationship `kind` to enforce by); C2
(need `kind = template` for the template nodes).
