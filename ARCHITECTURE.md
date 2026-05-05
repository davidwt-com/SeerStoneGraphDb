# SeerStoneGraphDb — Architecture

> High-level shape of the system. Updated as the code's architecture changes — not as
> implementation progresses within an already-described component. The canonical
> spec is [`the-knowledge-network.md`](the-knowledge-network.md); the kernel
> implements that model. Outstanding work is grouped by severity in
> `TASKS-CRITICAL.md`, `TASKS-HIGH.md`, `TASKS-MEDIUM.md`, and `TASKS-LOW.md`.

---

## 1. Status

| Component           | State                                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------- |
| Build               | Compiles clean — zero warnings (OTP 27 / rebar3 3.24)                                                   |
| `nref` subsystem    | Fully implemented; DETS-backed; `set_floor/1` API                                                       |
| `dictionary_imp`    | Implemented; not yet wired to `dictionary_server` / `term_server`                                       |
| `graphdb_bootstrap` | Implemented — Mnesia schema, table creation, scaffold loader                                            |
| `graphdb_mgr`       | Implemented — bootstrap startup, read API, category guard. Write-side delegation pending.               |
| `graphdb_attr`      | Implemented — attribute library (name, literal, relationship attributes)                                |
| `graphdb_class`     | Implemented — taxonomic hierarchy (single inheritance only — see §10)                                   |
| `graphdb_instance`  | Implemented — compositional hierarchy + four-level inheritance (single class membership only — see §10) |
| `graphdb_rules`     | Stub                                                                                                    |
| `graphdb_language`  | Stub                                                                                                    |
| Tests               | 156 passing (94 Common Test + 62 EUnit)                                                                 |

The kernel is functional under single-class-membership / single-inheritance
semantics. Multi-inheritance, template-scoped connections, and
multilingual support are open architectural questions — see §10.

---

## 2. Storage

| Subsystem                          | Storage                    | Why                                                       |
| ---------------------------------- | -------------------------- | --------------------------------------------------------- |
| `graphdb_*` (nodes, relationships) | **Mnesia** (`disc_copies`) | ACID across tables, secondary indexes, distribution-ready |
| `nref_allocator` / `nref_server`   | DETS                       | Simple persistent counter; no relational query needs      |
| `dictionary_imp`                   | ETS + `tab2file`           | In-memory cache, persistent serialisation                 |

### Mnesia tables

```
nodes         — one row per concept node             (primary key: nref)
relationships — one row per directed arc             (primary key: id)
```

Two tables cover the entire graph. Bidirectional logical edges are stored
as two directed rows in `relationships`, written atomically.

**Indexes:**
- `nodes` — secondary on `parent` for O(1) `children/1`.
- `relationships` — secondary on `source_nref` and `target_nref` for O(1)
  forward and reverse traversal.

Embedding relationships inside the node record (Dallas's original DETS
design) is rejected: it makes reverse-lookup an O(N) full-scan and
prevents transactional updates spanning both endpoints.

---

## 3. Node Record

```erlang
-record(node, {
  nref,                   %% integer() — primary key
  kind,                   %% category | attribute | class | instance
  parent,                 %% integer() | undefined  (undefined = root only)
  attribute_value_pairs   %% [#{attribute => Nref, value => term()}]
}).
```

### Node kinds

| Kind        | Purpose                                                                             | Creatable at runtime?   |
| ----------- | ----------------------------------------------------------------------------------- | ----------------------- |
| `category`  | Top-level organisational scaffold; bootstrap skeleton                               | **No** — bootstrap-only |
| `attribute` | Named concept used as an arc label, name attribute, or literal attribute descriptor | Yes                     |
| `class`     | Type/schema; manages the taxonomic ("is a") hierarchy                               | Yes                     |
| `instance`  | Concrete entity in a project; managed by the compositional ("part of") hierarchy    | Yes                     |

`category` immutability is enforced by `graphdb_mgr:check_category_guard/1`;
no runtime API can create, modify, or delete a `category` node.

### Root and bootstrap scaffold

The root node is `nref = 1`, `kind = category`, `parent = undefined`. It is
the only node in the database with `parent = undefined`.

Five top-level categories are pre-assigned at bootstrap:

```
1  Root
2  ├── Attributes  (parent of Names, Literals, Relationships subtrees)
3  ├── Classes     (parent of all class taxonomies)
4  ├── Languages   (multilingual support — see §10)
5  └── Projects    (organisational anchor for project databases — see §6)
```

The full 30-node BFS scaffold (nrefs 1–30) is documented in
`apps/graphdb/priv/bootstrap.terms`. Code that needs specific nrefs uses
the constants defined as macros in the worker that owns them
(`graphdb_attr`, `graphdb_class`, `graphdb_instance`).

---

## 4. Relationship Record

```erlang
-record(relationship, {
  id,               %% integer() — primary key
  source_nref,      %% integer() — arc origin
  characterization, %% integer() — arc label (an attribute nref)
  target_nref,      %% integer() — arc target
  reciprocal,       %% integer() — arc label as seen from target back
  avps              %% [#{attribute => Nref, value => term()}] — per-direction metadata
}).
```

### Bidirectional storage

A logical edge between two nodes is stored as **two** rows, one per
direction, written atomically in a single Mnesia transaction. The
`graphdb_bootstrap` loader and `graphdb_instance:add_relationship` both
expand a single bidirectional intent into two directed records.

### Per-arc metadata

`avps` carries metadata that is asymmetric between the two directions —
provenance, confidence, weights, validity time frames, flags. Per
[`the-knowledge-network.md`](the-knowledge-network.md) §5, this metadata
is part of the connection's identity for ASSOCIATE-type arcs, but does
not participate in graph traversal by default.

### Pending schema additions

One field and one AVP convention are required by the spec but not yet
on the record. See §10 and `TASKS-CRITICAL.md`:

- `kind` — explicit relationship type (`taxonomy | composition |
  connection | instantiation`).
- `Template` AVP — required on `kind = connection` arcs, forbidden
  elsewhere; the AVP attribute itself is bootstrap-seeded as nref 31.

Both must land before the database holds live data.

---

## 5. Supervision Tree

```
seerstone (application)
  └── seerstone_sup (one_for_one)
        └── database_sup
              ├── graphdb_sup
              │     ├── graphdb_mgr        — primary coordinator, bootstrap startup
              │     ├── graphdb_attr       — attribute library
              │     ├── graphdb_class      — taxonomic hierarchy
              │     ├── graphdb_instance   — compositional hierarchy + inheritance
              │     ├── graphdb_rules      — rule storage/enforcement (stub)
              │     └── graphdb_language   — query language (stub)
              └── dictionary_sup
                    ├── dictionary_server  — (stub, not wired to dictionary_imp)
                    └── term_server        — (stub, not wired to dictionary_imp)

nref (application — independent, started before seerstone)
  └── nref_sup
        ├── nref_allocator                 — DETS-backed counter
        └── nref_server                    — public nref API; calls allocator
```

Worker boundaries: each `graphdb_*` worker owns the schema/contract it
maintains. `graphdb_mgr` is the public entry point and routes to the
workers — read path implemented; write-side routing is pending
(`TASKS-LOW.md` L4).

---

## 6. Ontology and Project (Instance Space)

The system separates definitional knowledge from instance data.

| Body                         | Contents                                                                                                  | Mutability                                              |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **Ontology**                 | Categories, attributes, classes, languages, templates, rules — the bootstrap scaffold and the live schema | Categories: immutable. All other nodes grow at runtime. |
| **Project (instance space)** | Instance nodes and their relationships — one database per project                                         | Fully mutable                                           |

The ontology is shared across all projects. The same ontology can serve
unrelated domains. Project databases are independent — multiple may
exist on the same node, each with its own Mnesia schema.

### What lives where

| Concept                                      | Database |
| -------------------------------------------- | -------- |
| Category, attribute, class, language nodes   | Ontology |
| Bootstrap compositional arcs                 | Ontology |
| Runtime attribute / class compositional arcs | Ontology |
| Instance nodes                               | Project  |
| Instance compositional arcs                  | Project  |
| Instance → class membership arcs             | Project  |
| Instance user-defined connections            | Project  |

### Cross-database nref resolution

Nrefs are plain `integer()`s with no embedded database tag. Context
determines routing:

| Relationship field               | Resolves to                                 |
| -------------------------------- | ------------------------------------------- |
| `source_nref`                    | Same database as the relationship row       |
| `characterization`, `reciprocal` | Always the ontology                         |
| `target_nref`                    | Routed by the arc label's `target_kind` AVP |

`target_kind :: category | attribute | class | instance` is stored as a
literal AVP on every arc-label attribute node. Built-in arc labels
(nrefs 21–30) carry it; `graphdb_attr:create_relationship_attribute/3`
requires it for runtime additions.

### The `Projects` node (nref 5)

The `Projects` category node is the organisational anchor for known
projects. Public projects appear as child nodes whose presence is a
discovery hint — at runtime each is overlaid by the actual project
database root. Private projects are not listed; access requires
out-of-band credentials. Listing is independent of project existence.

---

## 7. nref Allocation

### Ontology allocator

Single global allocator served by `nref_server` / `nref_allocator`,
DETS-backed. Counter starts at 1 on a fresh node. `graphdb_bootstrap`
calls `nref_server:set_floor(10000)` once during the first scaffold
load, advancing the counter past the bootstrap range. All subsequent
ontology runtime nrefs are ≥ 10000.

### Project allocators

Per-project; start at **1**; no bootstrap floor. The project allocator
layer is not yet implemented — when added, the simplest design mirrors
the ontology allocator with a per-project DETS file. Numerical nref
overlap with the ontology is not a problem because every lookup is
routed to a specific database (see §6 cross-database resolution).

---

## 8. Bootstrap

### Configuration

Single authoritative config: `apps/seerstone/priv/default.config`.

```erlang
[{seerstone_graph_db, [
   {app_port,       8080},
   {log_path,       "log"},
   {data_path,      "data"},
   {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"}
 ]},
 {mnesia, [{dir, "data"}]}].
```

Relative paths resolve from the OTP release root; absolute paths take
effect as-is. Mnesia reads `dir` from its own application env — no code
sets it.

### Bootstrap file format

Erlang terms via `file:consult/1`. Three term shapes (full schema in
`graphdb_bootstrap.erl`):

```erlang
{nref_start, N}.
{node, Nref, Kind, ParentNref, {NameAttrNref, NameValue}, ExtraAVPs}.
{relationship, N1, R1, AVPs1, R2, N2, AVPs2}.
```

Erlang Terms chosen over JSON / XML / custom DSL for zero added
dependencies and direct pattern matching.

### Loader

`graphdb_bootstrap:load/0` is idempotent: creates Mnesia schema and
tables if absent, loads scaffold only if `nodes` is empty. Called from
`graphdb_mgr:init/1`. Processing order: floor directive → category
nodes → attribute nodes → class nodes → instance nodes →
relationships. Relationship IDs are allocated outside the Mnesia
transaction to avoid retry side-effects.

`category` writes are permitted only inside `graphdb_bootstrap`. After
the loader finishes, `graphdb_mgr` rejects any runtime request to
create, modify, or delete a `category` node.

---

## 9. Inheritance Resolution

`graphdb_instance:resolve_value/2` implements the four-level priority
order from [`the-knowledge-network.md`](the-knowledge-network.md) §6:

1. **Local AVPs** on the instance — highest.
2. **Class-bound values** — values explicitly bound at the class.
3. **Compositional ancestors** — unbroken upward walk via `node.parent`.
4. **Directly connected nodes** — one level deep — lowest.

Each level is consulted only if higher levels returned `not_found`.

The current implementation has known correctness gaps documented in
`TASKS-HIGH.md`: Priority 2 does not walk the class taxonomy (H1),
Priority 4 does not exclude already-walked hierarchical arcs (H2), and
multi-class membership is silently disambiguated by Mnesia ordering
(H5).

---

## 10. Open Architectural Questions

Pending architectural decisions and required additions. Each item has a
detailed task in the severity-grouped task files.

### Pending schema additions

| Schema element              | Purpose                                                                                                                                                    | Spec reference                  |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| `relationship.kind`         | Explicit type: `taxonomy \| composition \| connection \| instantiation`                                                                                    | §5 — `TASKS-CRITICAL.md` C1     |
| `node.kind` adds `template` | Fifth peer to category/attribute/class/instance; templates are nodes whose compositional parent is a class                                                 | §3, §7 — `TASKS-CRITICAL.md` C2 |
| `Template` relationship AVP | Bootstrap-seeded attribute (nref 31); required on `kind = connection` arcs, forbidden elsewhere; per-class default template auto-created at class creation | §5, §7 — `TASKS-CRITICAL.md` C3 |

All three must land before any database ships with live data — schema
migration on populated Mnesia tables is otherwise required.

### Multi-inheritance representation

The spec (§5) requires multiple class inheritance and multiple instance
class membership. The current representation puts the single primary
parent in `node.parent`; additional parents must live in the
relationships table only. The `graphdb_class` ancestor walk and
`graphdb_instance.resolve_from_class` need to traverse via arcs rather
than the single parent field. See `TASKS-HIGH.md` H3, H4, H5.

### Templates

Templates (spec §7) are active concept nodes that scope connections.
Representation choice is open — 5th node `kind = template`, or
`kind = class` with `is_template = true` AVP. Required for §13 query
filtering and §11 connection-pattern learning. See `TASKS-MEDIUM.md`
M7.

### Multilingual storage

Names are currently raw Erlang strings on every node. Spec §15 requires
language-neutral concept storage with per-language labels resolved at
render time. Two design options (per-language map AVPs vs. label
nodes) are open; choice affects every node in the database. See
`TASKS-MEDIUM.md` M6.

### Composition: dual storage

`node.parent` and the 27/28 arc rows both encode the compositional
parent. There is no formal invariant that they stay synchronised. The
arcs are needed for graph queries; the field provides O(1) index
lookup. Either declare the field a denormalised cache (and assert the
invariant in tests), or remove it and use the relationship index.
Decision pending. See `TASKS-MEDIUM.md` M1.
