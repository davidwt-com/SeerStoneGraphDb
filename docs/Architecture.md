<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Architecture

> High-level shape of the system. Updated as the code's architecture changes — not as
> implementation progresses within an already-described component. The canonical
> spec is [`TheKnowledgeNetwork.md`](TheKnowledgeNetwork.md); the kernel
> implements that model. Outstanding work is described in
> [`../TASKS.md`](../TASKS.md).

---

## 1. Status

| Component           | State                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build               | Compiles clean — zero warnings (Erlang/OTP, the Open Telecom Platform, version 28 / rebar3 3.27)                                                                                                                                                                                                                                                                              |
| `nref` subsystem    | Fully implemented; backed by DETS (Disk-based Erlang Term Storage); `set_floor/1` API                                                                                                                                                                                                                                                                                         |
| `dictionary_imp`    | Implemented; not yet wired to `dictionary_server` / `term_server`                                                                                                                                                                                                                                                                                                             |
| `graphdb_bootstrap` | Implemented — Mnesia schema, table creation, scaffold loader                                                                                                                                                                                                                                                                                                                  |
| `graphdb_mgr`       | Implemented — bootstrap startup, read API, category guard, cache audit/repair. Write-side delegation pending.                                                                                                                                                                                                                                                                 |
| `graphdb_attr`      | Implemented — attribute library (name, literal, relationship attributes)                                                                                                                                                                                                                                                                                                      |
| `graphdb_class`     | Implemented — taxonomic hierarchy with multi-parent inheritance (BFS — breadth-first search — over a DAG, a directed acyclic graph); abstract (non-instantiable) classes via the `instantiable` marker                                                                                                                                                                        |
| `graphdb_instance`  | Implemented — compositional hierarchy + four-level inheritance with multi-class membership and ambiguity-detecting class resolver; refuses instantiation/membership of abstract classes; fires composition rules on `create_instance/3` and surfaces `proposed` outcomes for propose-mode rules; fires connection rules via a caller-supplied resolver on `create_instance/4` |
| `graphdb_rules`     | Implemented — rule meta-ontology, applies_to attachment, scope-aware create/retrieve, taxonomy-walking effective-rules read, composition firing engine, propose mode, connection firing                                                                                                                                                                                       |
| `graphdb_language`  | Implemented — multilingual overlay layer (label resolution, dialect chains, per-language Mnesia overlay tables)                                                                                                                                                                                                                                                               |
| `graphdb_query`     | Implemented — query language with snapshot-semantics sessions and continuation-based bounded BFS                                                                                                                                                                                                                                                                              |
| Tests               | 476 passing (371 Common Test + 105 EUnit)                                                                                                                                                                                                                                                                                                                                     |

The kernel is functional under multi-inheritance, multi-class-
membership, and per-class template semantics.  Multilingual label
overlay (§10) and the query language (§11) are landed.
The `graphdb_rules` data model (§12) is landed, along with the
taxonomy-walk effective-rules read, the composition firing engine,
propose mode (`create_instance/3` surfaces `proposed` outcomes), and
connection firing. The later firing-engine work — conflict precedence,
the instantiation engine, and reactive learning — remains.

---

## 2. Storage

| Subsystem                          | Storage                                          | Why                                                       |
| ---------------------------------- | ------------------------------------------------ | --------------------------------------------------------- |
| `graphdb_*` (nodes, relationships) | **Mnesia** (`disc_copies`)                       | ACID across tables, secondary indexes, distribution-ready |
| `nref_allocator` / `nref_server`   | DETS                                             | Simple persistent counter; no relational query needs      |
| `dictionary_imp`                   | ETS (in-memory Erlang Term Storage) + `tab2file` | In-memory cache, persistent serialisation                 |

### Mnesia tables

```
nodes         — one row per concept node             (primary key: nref)
relationships — one row per directed arc             (primary key: id)
```

Two tables cover the entire graph. Bidirectional logical edges are stored
as two directed rows in `relationships`, written atomically.

**Indexes:**
- `relationships` — secondary on `source_nref` and `target_nref` for O(1)
  forward and reverse traversal.
- `nodes` carries no secondary index. Downward queries ("children of X")
  read outgoing arcs from `relationships` filtered by kind +
  characterization (see §3 cache invariant).

Embedding relationships inside the node record (Dallas's original DETS
design) is rejected: it makes reverse-lookup an O(N) full-scan and
prevents transactional updates spanning both endpoints.

---

## 3. Node Record

```erlang
-record(node, {
  nref,                   %% integer() — primary key
  kind,                   %% category | attribute | class | instance | template
  parents = [],           %% [integer()] — cache of parent arcs (composition/taxonomy)
  classes = [],           %% [integer()] — cache of instantiation arcs (instances only)
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
| `template`  | Named semantic context attached to a class; scopes connection arcs (see §4)         | Yes                     |

`category` immutability is enforced by `graphdb_mgr:check_category_guard/1`;
no runtime API can create, modify, or delete a `category` node.

### Cache invariant: arcs authoritative; lists cached

`parents` and `classes` are **caches** of the authoritative arcs in the
`relationships` table. The decision record is
[`arcs-authoritative.md`](../arcs-authoritative.md); the rules are:

  1. Every taxonomic, compositional, and instantiation relationship is
     canonical in `relationships`.
  2. `node.parents` and `node.classes` are reconstructable from those
     arcs at any time. They exist purely so reads that need only the
     "who are my parents / classes" structure can skip the relationship
     index.
  3. A cache that disagrees with the arcs is a fatal error, not
     correctable drift.

Cache field sources:

| Cache field    | Authoritative arcs                               | Owner worker                                                           |
| -------------- | ------------------------------------------------ | ---------------------------------------------------------------------- |
| `node.parents` | 21/22 composition (category)                     | `graphdb_bootstrap` (writes); `graphdb_mgr:rebuild_caches/0` populates |
| `node.parents` | 23/24 taxonomy (attribute)                       | `graphdb_attr`                                                         |
| `node.parents` | 25/26 taxonomy (class) or composition (template) | `graphdb_class`                                                        |
| `node.parents` | 27/28 composition (instance)                     | `graphdb_instance`                                                     |
| `node.classes` | 29 instantiation (instance → class)              | `graphdb_instance`                                                     |

Note on attribute parent/child arcs: arc-label nrefs 23 ("Parent") and
24 ("Child") were minted at bootstrap as the attribute-subtree labels.
Arcs written under those labels carry `kind = taxonomy`, not
composition: an attribute parent/child relation is a refinement of
kind ("welded attachment" is-a-kind-of "attachment"), not part-whole.
The category scaffold above (Root → Attributes/Classes/Languages/
Projects) keeps `kind = composition` because categories are
organisational containers.

Each owner worker writes the arcs and the matching cache update inside
one `mnesia:transaction/1`. Other workers never touch the table
directly — they call the owner's API.

`graphdb_mgr` exposes two audit/repair APIs:

| Function           | Purpose                                                                              |
| ------------------ | ------------------------------------------------------------------------------------ |
| `verify_caches/0`  | Scans every node; returns `ok` or `{error, [{Nref, Field, Expected, Actual}, ...]}`. |
| `rebuild_caches/0` | Rewrites every node's caches from the arcs in one transaction.                       |

CT enforcement: every test suite calls `verify_caches/0` in
`end_per_testcase`. A failed verify is a fatal CT failure. The
bootstrap loader runs `rebuild_caches/0` followed by `verify_caches/0`
once all rows are written; a mismatch throws
`{bootstrap_cache_invariant_failed, Mismatches}` and aborts startup.

### Root and bootstrap scaffold

The root node is `nref = 1`, `kind = category`, `parents = []`. It is
the only node in the database with an empty parents list.

Five top-level categories are pre-assigned at bootstrap:

```
1  Root
2  ├── Attributes  (parent of Names, Literals, Relationships subtrees)
3  ├── Classes     (parent of all class taxonomies)
4  ├── Languages   (language domain concepts — see §10)
5  └── Projects    (organisational anchor for project databases — see §6)
```

The bootstrap loads 38 nodes in total: the 35-node BFS scaffold (nrefs
1–35), the permanent English instance seed (nref 10000), and 2 labeled
permanent nodes (`lang_code`, `lang_human` — nrefs assigned by the
loader's local counter starting at `label_start` = 10001). The full
content is documented in `apps/graphdb/priv/bootstrap.terms`. Code that
needs specific nrefs uses the constants defined as macros in the worker
that owns them (`graphdb_attr`, `graphdb_class`, `graphdb_instance`).

---

## 4. Relationship Record

```erlang
-record(relationship, {
  id,               %% integer() — primary key
  kind,             %% taxonomy | composition | connection | instantiation
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
[`TheKnowledgeNetwork.md`](TheKnowledgeNetwork.md) §5, this metadata
is part of the connection's identity for ASSOCIATE-type arcs, but does
not participate in graph traversal by default.

### Connection arcs and the `Template` AVP

Every `kind = connection` arc carries a `Template` AVP — `#{attribute
=> 31, value => TemplateNref}` — that scopes the connection's
semantic context. The AVP attribute is bootstrap-seeded at nref 31;
it is forbidden on relationships of any other kind. Template nodes
are compositional children of class nodes (see §3 cache field
sources). API: `graphdb_instance:add_relationship/4,5`.

---

## 5. Supervision Tree

Five OTP applications started by `application_master` in dependency order.
`graphdb` declares `mnesia` and `nref` as dependencies; `database` declares
`graphdb` and `dictionary`; `seerstone` declares `nref` and `database`.

```
nref (application — started first)
  └── nref_sup
        ├── nref_allocator       — DETS-backed block allocator
        └── nref_server          — public nref API; calls allocator

graphdb (application — started after mnesia + nref)
  └── graphdb_sup
        ├── graphdb_nref         — switchable node-nref allocation facade (permanent during init; runtime after flip)
        ├── rel_id_server        — arc row ID allocator (separate from nref space)
        ├── graphdb_mgr          — primary coordinator; bootstrap startup
        ├── graphdb_attr         — attribute library
        ├── graphdb_class        — taxonomic hierarchy
        ├── graphdb_instance     — compositional hierarchy + inheritance
        ├── graphdb_language     — multilingual label overlay
        ├── graphdb_query        — query language gen_server
        └── graphdb_rules        — rule meta-ontology + create/retrieve + composition firing + propose mode + connection firing

dictionary (application — started alongside graphdb)
  └── dictionary_sup
        ├── dictionary_server    — ETS-backed key-value store
        └── term_server          — ETS-backed term store

database (application — started after graphdb + dictionary)
  └── database_sup               — empty supervisor; attachment point for future
                                   database-level services

seerstone (application — top-level; started last)
  └── seerstone_sup              — empty supervisor; placeholder for future
                                   seerstone-specific workers
```

`graphdb` and `dictionary` are independent peer applications.
`database_sup` is intentionally empty — it serves as an attachment point for
any future database-level coordination services without reintroducing the
`included_applications` coupling.

Worker boundaries: each `graphdb_*` worker owns the schema/contract it
maintains. `graphdb_mgr` is the public entry point and routes to the
workers — read path implemented; write-side routing is pending
(see [`../TASKS.md`](../TASKS.md)).

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

| Concept                                                      | Location                                       |
| ------------------------------------------------------------ | ---------------------------------------------- |
| Category, attribute, class nodes                             | Ontology                                       |
| Language class nodes; domain connection arcs                 | Ontology — see §10                             |
| Permanent ontology instance seeds (e.g., English nref 10000) | Ontology — see §10                             |
| Bootstrap and runtime compositional arcs                     | Ontology                                       |
| Project anchor nodes (children of Projects nref 5)           | Ontology                                       |
| Language overlay tables for environment nrefs                | Ontology node (`language_<code>`)              |
| Instance nodes (project entities)                            | Project                                        |
| Instance compositional arcs                                  | Project                                        |
| Instance → class membership arcs                             | Project                                        |
| Instance user-defined connections                            | Project                                        |
| Language overlay tables for project nrefs                    | Project node (`language_<code>_<anchor_nref>`) |

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
(nrefs 21–30) carry it; `graphdb_attr:create_relationship_attribute_pair/4`
requires it for runtime additions.

Every `graphdb_attr` creator takes an explicit, validated `ParentNref`
(must name an existing `kind=attribute` node); the named functions
(`create_name_attribute`, `create_literal_attribute`,
`create_relationship_type`, `create_relationship_attribute_pair`) are thin
wrappers over the canonical `create_value_attribute/4` (single node) and
`create_relationship_attribute_pair/4` (reciprocal pair), defaulting the
parent to the appropriate scaffold subtree (6/7/8) when omitted.

### The `Projects` node (nref 5)

Every project **must** have an anchor node in the environment as a
child of the `Projects` category. That node's environment nref is the
project's permanent cross-system identity token — used to scope
project-side language overlay tables and as the stable reference point
for cross-database arcs.

Projects may be **remote**: all project-side Mnesia tables (`nodes`,
`relationships`, per-language overlays) reside on the project's own
node, which may differ from the environment node. Mnesia handles
transparent remote access within a cluster; fully independent remote
projects are a future distribution concern.

Visibility of the anchor node is governed by ACL AVPs on that node
(not yet implemented). Globally visible projects have no access
restriction; owner-specific projects have a permissioned ACL. The node
always exists regardless of its visibility.

---

## 7. nref Allocation

### Ontology nref tiers

Bootstrap introduces three nref tiers:

| Tier                    | Range                              | Contents                                                                                                                                                    |
| ----------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scaffold                | 1 – 9 999                          | Pre-assigned category/attribute bootstrap nodes                                                                                                             |
| Permanent concept seeds | `?LABEL_START` – `?NREF_START` − 1 | English (10000), loader-assigned atom-labeled nodes starting at `?LABEL_START` (10001), and worker init/1 seeds (graphdb_attr, graphdb_language sub-groups) |
| Runtime                 | ≥ `?NREF_START`                    | Post-boot allocations from `nref_server` — all instance/class/attribute runtime APIs, relationship row IDs                                                  |

Tier boundaries are the `?LABEL_START` and `?NREF_START` macros in
`apps/graphdb/include/graphdb_nrefs.hrl` (`?LABEL_START = 10001`,
`?NREF_START = 1 000 000`). They are **not** directives in `bootstrap.terms`
— that file contains only node and relationship terms.

Node-nref allocation is routed through `graphdb_nref` (first child of
`graphdb_sup`): during the init phase it hands out permanent-tier nrefs
computed from the `nodes` table; after the `graphdb:start/2` phase flip it
delegates to `nref_server:get_nref/0`. The phase is held in
`persistent_term` so a process restart cannot resurrect the wrong phase.

`graphdb:start/2` brackets the boot: it calls
`graphdb_nref:set_permanent_phase/0` before `graphdb_sup:start_link/0`, so
the bootstrap loader and every worker `init/1` allocate in the permanent
tier; after all child `init/1`s complete it calls
`graphdb_nref:set_runtime_phase/0`, which also raises the `nref_server`
floor to `?NREF_START`.

`graphdb_bootstrap` assigns atom-labeled node nrefs from a **local counter**
starting at `?LABEL_START`. If the counter would reach `?NREF_START` the
loader throws `{labels_exceeded_nref_start, ...}`; the `graphdb_nref`
spillover path (raise floor and continue via get_nref) is not yet wired to
the loader. With `?NREF_START = 1 000 000` and `?LABEL_START = 10 001` the
permanent tier has roughly 990 000 free slots — spill-over is not expected.

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

Erlang terms via `file:consult/1`. Two term shapes (full schema in
`graphdb_bootstrap.erl`):

```erlang
{node, Nref, Kind, {NameAttrNref, NameValue}, ExtraAVPs}.
{relationship, N1, R1, AVPs1, R2, N2, AVPs2, Kind}.
```

Tier boundaries (`?LABEL_START`, `?NREF_START`) are compile-time macros in
`graphdb_nrefs.hrl` — no `{nref_start, N}` or `{label_start, N}` directives
live in the file.

`Nref` (and endpoint fields `N1`, `N2`) may be either a pre-assigned
`integer()` or an **atom label** — a symbolic placeholder resolved at
load time. Atom labels allow mutable support nodes to be declared in
the bootstrap file without pre-assigning nrefs.

Hierarchy is encoded *only* in the relationship arcs — the node tuple
carries no parent field. Per-arc inline `%%` comments make the file
readable top-to-bottom.

Erlang Terms chosen over JSON / XML / custom DSL for zero added
dependencies and direct pattern matching.

### Loader

`graphdb_bootstrap:load/0` is idempotent: creates Mnesia schema and
tables if absent, loads scaffold only if `nodes` is empty. Called from
`graphdb_mgr:init/1`. Processing is a **two-pass** sequence:

1. `classify_terms` — partition into `{Nodes, Rels}`; unknown terms are rejected
2. `validate` — accept integer nrefs `< ?NREF_START` and atom labels; reject unknown kinds
3. `validate_relationships` — reject unknown relationship kinds
4. `build_symbol_table` — allocate a permanent-tier nref for each unique atom label
   from a local counter starting at `?LABEL_START` (no `nref_server` call)
5. `apply_symbol_table` — substitute all atom labels with their allocated nrefs
6. `validate_no_unresolved_labels` — sanity-check; no atom must survive resolution
7. `write_nodes` → `write_relationships` — write to Mnesia
8. `rebuild_caches` + `verify_caches` — enforce the cache invariant (see §3)

Relationship IDs are allocated outside Mnesia transactions to avoid
retry side-effects. A verify mismatch in step 9 throws
`{bootstrap_cache_invariant_failed, Mismatches}` as a fatal startup
error.

`category` writes are permitted only inside `graphdb_bootstrap`. After
the loader finishes, `graphdb_mgr` rejects any runtime request to
create, modify, or delete a `category` node.

---

## 9. Inheritance Resolution

`graphdb_instance:resolve_value/2` implements the four-level priority
order from [`TheKnowledgeNetwork.md`](TheKnowledgeNetwork.md) §6:

1. **Local AVPs** on the instance — highest.
2. **Class-bound values** — every class membership in
   `node.classes`; for each, walk the class itself plus its taxonomic
   ancestor DAG (`graphdb_class:ancestors/1`, BFS over multi-parent
   classes, nearest first). Per-membership hits are gathered as
   `[{ClassNref, Value}]` and reduced: a single distinct value wins
   (`{ok, Value}`); two or more distinct values produce
   `{error, {ambiguous_class_value, AttrNref, Hits}}`; zero hits fall
   through.
3. **Compositional ancestors** — unbroken upward walk via the
   `node.parents` cache. Composition is a tree (one whole has at most
   one parent), so the walk is single-chain.
4. **Directly connected nodes** — `kind = connection` arcs only, one
   level deep — lowest.

Each level is consulted only if higher levels returned `not_found`.

---

## 10. Languages

The `Languages` category (nref 4) is the organisational root for all
communicative systems recognised by the knowledge network. A language, in
this model, is any system with grammar, syntax, and tokens or icons —
human natural languages, programming languages, diagram notations, and
rendering engines all qualify. Four subcategories are established at
bootstrap:

| Nref | Name              | Domain                                               |
| ---- | ----------------- | ---------------------------------------------------- |
| 32   | Human Languages   | Natural languages spoken or signed by humans         |
| 33   | Formal Languages  | Programming languages, query languages, notations    |
| 34   | Diagram Languages | UML, engineering schematics, tabular notation        |
| 35   | Renderers         | Rendering engines categorised by rendering mechanics |

The subcategory nodes (nrefs 32–35) are domain markers in the
organisational scaffold — analogous to `Attributes` and `Classes` — not
containers for language class nodes. The abstract class hierarchy for
language concepts lives under `Classes` (nref 3); see below.

Language nodes live in the **ontology** (see §6 for cross-database
routing). The connection arcs from language class nodes to their domain
subcategory (e.g., English → Human Languages, nref 32) are also written
to the ontology.

### Language concepts as a knowledge domain

Languages are not merely label lookup tables. Each language is a
**knowledge domain**: a self-contained body of concepts covering grammar,
syntax, vocabulary, and notation. In the knowledge network model:

- The **abstract concepts** — "Human Language", "Dialect", "Grammar Rule",
  "Word", "Token", "Syntax Rule" — are class nodes in the ontology under a
  `Language` superclass seeded at runtime under `Classes` (nref 3).
- Each specific language ("English", "German") and each dialect
  ("en_gb", "pt_br") is an **instance node** — an instance of `Human
  Language` or a more specific class. English is bootstrapped as a
  permanent ontology instance at nref 10000; all other language nodes
  are seeded at runtime by `graphdb_language:init/1` or
  `register_language/2`. Using `kind=instance` eliminates the
  dual-mechanism risk: instances do not participate in taxonomic IS-A
  arcs, so the `base_language` AVP is the sole authority for the
  base/dialect relationship.
- The long-term shape is a dedicated project database per language,
  populated with instances of `Word`, `GrammarRule`, `SyntaxRule`, and
  related classes specific to that language.

The long-term consequence is that all concept names, attribute labels, and
string values are ultimately compositions of instances in language projects.
A label rendered for a node is not a stored string — it is a reference to a
vocabulary instance in the appropriate language project, resolved through the
inheritance chain. This is a direct expression of the self-referential nature
of knowledge: the graph eventually describes itself in its own terms.

Domain membership is recorded by a lateral connection arc from each language
class node to the appropriate subcategory (e.g., English → nref 32). The
subcategory nodes are not parents in the class hierarchy; they are category
anchors in the organisational scaffold.

### Current implementation — multilingual label overlay

The full language-project mechanism is a future capability. The current
implementation provides a pragmatic foundation: per-language Mnesia overlay
tables (`language_en`, `language_de`, …) that store per-attribute label
overrides keyed by nref. A language **chain** — an ordered list of language
codes with a resolution context — walks these tables left to right, falling
back to the terminal ontology node record.

This overlay mechanism is designed as a replaceable abstraction: when
language projects are built out, the backing will shift from flat per-nref
rows to traversal into project instance graphs, and the overlay tables will
become caches of that traversal. The `resolve_label/3` API does not change
when the backing changes. See [`../TASKS.md`](../TASKS.md) for the
remaining multilingual write-path work.

---

## 11. Query Layer (`graphdb_query`)

`graphdb_query` is the sole entry point for read-side traversal of the
graph. It is a gen_server peer to the other graphdb workers under
`graphdb_sup`.

Architectural shape:

- AST records in `apps/graphdb/include/graphdb_query.hrl`
  (`#q_get_node{}`, `#q_get_arcs{}`, `#q_describe{}`,
  `#q_instances_of{}`, `#q_find_path{}`).
- Session is a value-passed map carrying a snapshot timestamp and a
  read-through cache of node and arc reads.
- Sessions are snapshots: `refresh/1` is the only invalidation path.
  Continuations are tagged with their issuing snapshot; resuming
  against a refreshed session returns `{error, snapshot_expired}`.
- Mnesia access is funnelled through `session_read_node/2` and
  `session_read_arcs/4`. The executor never calls `mnesia:dirty_*`
  directly.
- `find_path` is always bounded (caller supplies `max_depth`); reaching
  the bound returns `{partial, Path, Continuation}` for later
  resumption. The cont stores the original `max_depth` as
  `remaining_depth` so resume gets a fresh full budget.
- Category-kind nodes (nrefs 1-5) are filtered as structural scaffold
  in BFS expansion, matching the semantics already encoded in
  `graphdb_class:ancestors/1`'s NREF_CLASSES filter.

See `designs/f3-graphdb-query-design.md` for the durable architectural
contract.

---

## 12. Rules (`graphdb_rules`)

`graphdb_rules` implements the rules data model and the firing engine:
storage and retrieval, taxonomy-walking effective-rules reads, the
composition firing engine, propose mode, and connection firing. The
later firing-engine work — conflict precedence, the instantiation
engine, and reactive learning — remains, tracked in
[`../TASKS.md`](../TASKS.md).

Architectural shape:

- A rule is a `kind = instance` node. Its class membership is one of two
  seeded meta-classes, `CompositionRule` or `ConnectionRule`, both
  subclasses of an abstract `Rule` root (non-instantiable via the
  `instantiable` marker). The meta-ontology, a `Rule Literals` literal
  sub-group, and the `applies_to`/`applied_by` relationship-attribute
  pair are seeded idempotently at `init/1`; `graphdb_rules` is the last
  child of `graphdb_sup` so `graphdb_attr` and `graphdb_class` are ready.
- **Content vs deployment AVP split.** Rule *content* (child/target class,
  characterization, optional template) lives in the rule instance node's
  AVPs. Rule *deployment* (`mode`, `multiplicity`, and the owning class's
  default `Template` at AVP index 0) lives on the forward `applies_to`
  connection arc from the owning class to the rule instance.
- **Attachment.** Each rule is written in one Mnesia transaction: the
  instance node, its instance↔class membership pair (chars 29/30), and
  the `applies_to`/`applied_by` connection pair between owning class and
  rule. `rules_for_class/2` is **direct-attachment only** — it reads the
  owning class's outgoing `applies_to` arcs. `effective_rules_for_class/2`
  additionally walks the class's taxonomy ancestors:
  a nearest-first, deployment-bearing gather of every rule attached to the
  class and its superclasses, grouped by attaching class. It resolves
  nothing — additive-vs-shadow is the firing engine's job (conflict
  precedence, still outstanding).
- **Composition firing.** `graphdb_instance:create_instance/3` calls
  `graphdb_rules:plan_composition_firing/2` to build an abstract plan tree,
  then executes it: `mandatory` rules fire inside the same transaction as
  the parent; `auto` rules fire post-commit. Return shape is `{ok, Nref,
  Report}` on success or `{error, Reason, Report}` on firing failure; pre-
  plan validation errors return `{error, Reason}` (2-tuple). The report is
  rule-centric: `[#{rule, deployment, outcomes}]`.
- **Propose mode.** `propose`-mode composition rules materialise
  nothing; they surface as `proposed` outcomes in the same create report
  (always-in-report — no session flag). A caller accepts a proposal by
  issuing an ordinary `create_instance/3` for the proposed class.
- **Scope.** The API is scope-tagged (`environment` | `{project, _}`).
  It serves the `environment` scope; `{project, _}` creates are
  rejected and `{project, _}` reads return empty.

See `designs/f4-graphdb-rules-design.md` for the durable architectural
contract.
