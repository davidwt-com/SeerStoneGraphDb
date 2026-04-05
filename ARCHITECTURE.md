# Architectural Design Proposal — SeerStoneGraphDb

> **Status:** Design phase complete — all questions resolved. Bootstrap nrefs assigned (BFS, 1–30). `apps/graphdb/priv/bootstrap.terms` written. Ready for implementation.

---

## 1. Codebase Baseline

| Area | State |
|---|---|
| Build | Compiles cleanly — zero warnings (OTP 27 / rebar3 3.24) |
| `nref_server` / `nref_allocator` | Fully implemented; DETS-backed; `set_floor/1` added |
| `dictionary_imp` | Implemented; not yet wired to `dictionary_server` or `term_server` |
| `dictionary_server`, `term_server` | Stubs |
| All 6 `graphdb_*` workers | Empty gen_server stubs — no graph logic |
| Stale DETS files on disk | `graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets` — deleted; were produced by a prior AI session, superseded by Mnesia |

---

## 2. Configuration File

### Decision

Extend the existing `apps/seerstone/priv/default.config` with four new keys under the `seerstone_graph_db` application env. This is the single authoritative runtime config.

```erlang
[{seerstone_graph_db, [
  {app_port,       8080},
  {log_path,       "log"},
  {data_path,      "data"},
  {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"}
]},
 {mnesia, [
  {dir, "data"}                   %% Mnesia reads its own dir from its app env
]}].
```

| Key | Purpose |
|---|---|
| `log_path` | Directory for log files |
| `data_path` | Directory for Mnesia database files and nref DETS files |
| `bootstrap_file` | Path to the bootstrap `.terms` file; read on first startup when schema is empty |

### Path resolution

Both relative and absolute paths are accepted for `log_path`, `data_path`, and `bootstrap_file`. Relative paths are resolved from the OTP release root at runtime (standard OTP convention). Absolute paths take effect as-is. Use relative paths for packaged releases; absolute paths for development overrides.

### Mnesia dir configuration

Mnesia reads its storage directory from its own application env key `{mnesia, dir}`. This is set directly in `default.config` (alongside the `seerstone_graph_db` env) so no code needs to call `application:set_env/3` for it. The value must match `data_path`.

### nref_start does not belong in config

`nref_start` is a one-time bootstrap value, not a runtime config value. After the first
bootstrap run, the nref allocator's DETS counter is already `>= nref_start` and persisted;
the value is never consulted again. It belongs in `bootstrap.terms` alongside the data it
governs — see Section 7.

---

## 3. Storage: graphdb Workers Move to Mnesia

### Decision

Replace DETS (per-worker) with **Mnesia** for all six `graphdb_*` workers.

### Rationale

| Problem with DETS | Mnesia solution |
|---|---|
| No cross-table transactions | Full ACID transactions across tables |
| No secondary indexes | First-class `index_read` on any field |
| Single-writer bottleneck | Concurrent reads; serialized writes via transaction manager |
| No distribution | `{disc_copies, Nodes}` replication built in |
| External files per worker | Single unified schema; files go in `data_path` |

### Scope

- `nref_allocator` / `nref_server` — **stay on DETS** (working; simple counter; already persistent)
- `dictionary_imp` / `dictionary_server` — **stay on ETS** (appropriate for an in-memory cache)
- All `graphdb_*` workers — **move to Mnesia**

### Mnesia table layout

Two tables cover the full graph:

```
nodes         — one record per concept node
relationships — one record per directed arc (two records per logical bidirectional edge)
```

This separation is critical: embedding relationships as a list inside the node record (as in Dallas's original DETS schema) makes reverse-lookup (finding all arcs pointing *to* a node) an O(N) full-table scan. A separate `relationships` table with a secondary index on `target_nref` makes reverse-lookup O(1) via `mnesia:index_read/3`.

---

## 4. Node Record Design

### Mnesia record

```erlang
-record(node, {
  nref,                   %% integer() — primary key
  kind,                   %% category | attribute | class | instance
  parent,                 %% integer() | undefined (undefined = root only)
  attribute_value_pairs   %% [#{attribute => Nref, value => term()}]
}).
```

Secondary index: `parent` — enables efficient `children/1` queries.

### Node kinds

| Kind | Description | Creatable at runtime? |
|---|---|---|
| `category` | Permanent top-level organisational scaffold; forms the skeleton of the entire graph | **No — bootstrap only** |
| `attribute` | Named concept used as an arc label, name attribute, or literal attribute descriptor | Yes |
| `class` | Type/schema node; manages the taxonomic ("is a") hierarchy | Yes |
| `instance` | Concrete entity; managed by the compositional ("part of") hierarchy | Yes |

`category` nodes cannot be created, modified, or deleted via any runtime API. `graphdb_mgr` exposes no `create_category` function. Attempts to write a `category` node outside of `graphdb_bootstrap` are rejected.

### Root node

- Nref = **1** (first and lowest possible nref; pre-assigned in the bootstrap file)
- `kind = category`, `parent = undefined`
- The only node in the database where `parent` is `undefined`

### Bootstrap tree skeleton — nrefs assigned (BFS, 1–30)

Nrefs are assigned breadth-first. Attribute nodes under **Names** provide the `NameAttrNref` values used in node records; attribute nodes under **Relationships** provide the `characterization`/`reciprocal` arc labels used in the `relationships` table.

```
 1  Root (category)
 2  ├── Attributes (category)
 3  ├── Classes (category)
 4  ├── Languages (category)
 5  └── Projects (category)
        (children of Attributes:)
 6      ├── Names (attribute)
 7      ├── Literals (attribute)              ← children TBD
 8      └── Relationships (attribute)
            (children of Names — Attribute before Class:)
 9          ├── Category Name Attributes (attribute)
10          ├── Attribute Name Attributes (attribute)
11          ├── Class Name Attributes (attribute)
12          └── Instance Name Attributes (attribute)
            (children of Relationships — Attribute before Class:)
13          ├── Category Relationships (attribute)
14          ├── Attribute Relationships (attribute)
15          ├── Class Relationships (attribute)
16          └── Instance Relationships (attribute)
            (children of *Name Attributes — one Name per kind, BFS:)
17              ├── Name  ← NameAttrNref for category nodes   (parent:  9)
18              ├── Name  ← NameAttrNref for attribute nodes  (parent: 10, self-ref)
19              ├── Name  ← NameAttrNref for class nodes      (parent: 11)
20              └── Name  ← NameAttrNref for instance nodes   (parent: 12)
            (children of *Relationships — arc label nodes, BFS:)
21              ├── Parent    category  compositional arc label (parent: 13)
22              ├── Child     category  compositional arc label (parent: 13)
23              ├── Parent    attribute compositional arc label (parent: 14, self-ref)
24              ├── Child     attribute compositional arc label (parent: 14, self-ref)
25              ├── Parent    class     compositional arc label (parent: 15)
26              ├── Child     class     compositional arc label (parent: 15)
27              ├── Parent    instance  compositional arc label (parent: 16)
28              ├── Child     instance  compositional arc label (parent: 16)
29              ├── Class     instance→class membership arc    (parent: 16)
30              └── Instance  class→instances membership arc   (parent: 16)
```

### NameAttrNref quick-reference

| Kind | NameAttrNref |
|---|---|
| `category` | 17 |
| `attribute` | 18 |
| `class` | 19 |
| `instance` | 20 |

### Compositional arc labels quick-reference

Arc labels used in `{relationship, ParentNref, ChildArcNref, [], ParentArcNref, ChildNref, []}` terms. `ChildArcNref` is the characterization on the parent→child directed row; `ParentArcNref` is the characterization on the child→parent directed row.

| Child kind | ChildArcNref | ParentArcNref |
|---|---|---|
| `category` | 22 (Child/CatRel) | 21 (Parent/CatRel) |
| `attribute` | 24 (Child/AttrRel) | 23 (Parent/AttrRel) |
| `class` | 26 (Child/ClassRel) | 25 (Parent/ClassRel) |
| `instance` | 28 (Child/InstRel) | 27 (Parent/InstRel) |

The attribute row (nrefs 23 and 24) is self-referential: the arc label attribute nodes for "attribute" compositional arcs are themselves attribute nodes whose own parent arc label is nref 23. This is consistent — the system uses its own arc label vocabulary to describe itself.

### Instance-to-class membership arc labels

| Nref | Name | Direction | Usage |
|---|---|---|---|
| 29 | Class | instance → its class | `characterization` on the instance→class row |
| 30 | Instance | class → its instances | `characterization` on the class→instance row |

Usage in the relationships table:
```erlang
%% Writing instance membership: {relationship, InstNref, 29, [], 30, ClassNref, []}
%% Expands to:
%%   Row 1: source=InstNref,  characterization=29 (Class),    target=ClassNref, reciprocal=30
%%   Row 2: source=ClassNref, characterization=30 (Instance), target=InstNref,  reciprocal=29
```

These are the only arc labels that cross the taxonomic/compositional boundary. `graphdb_instance:create_instance/3` writes this relationship pair atomically alongside the node record.

---

## 5. Relationship Record Design

### Mnesia record

```erlang
-record(relationship, {
  id,               %% integer() — primary key (nref allocated normally)
  source_nref,      %% integer() — arc origin
  characterization, %% integer() — arc label (an attribute nref)
  target_nref,      %% integer() — arc target
  reciprocal,       %% integer() — arc label as seen from target back (an attribute nref)
  avps              %% [#{attribute => Nref, value => term()}] — per-direction metadata
}).
```

Secondary indexes: `source_nref`, `target_nref`.

A logical bidirectional edge is expressed as **two** `relationship` records — one for each direction — written atomically in the same Mnesia transaction. The `graphdb_bootstrap` loader does this expansion when processing `{relationship, ...}` terms from the bootstrap file.

### Arc storage by node kind

| Kind | `parent` field | `relationship` table records |
|---|---|---|
| `category` | Yes — fast tree traversal | **Yes** — explicit arc records using Category Relationships/Parent + Child labels; both directions written atomically |
| `attribute` | Yes | Yes — using Attribute Relationships/Parent + Child labels |
| `class` | Yes | TBD — to be decided when class node implementation begins |
| `instance` | Yes | Yes — user-defined arcs via `add_relationship/4` |

Category and attribute compositional arcs are written as explicit `{relationship, ...}` terms in `bootstrap.terms`. The loader writes them like any other relationship — no special-casing. The `parent` field provides O(1) tree traversal; the `relationships` table provides arc-query consistency (finding all inbound arcs via `index_read` on `target_nref`).

### Additional-parents flag/count: Decision — Not needed

The user raised this question: given single compositional parent (the `parent` field), should the node record carry a flag or count to indicate that additional parents exist in the relationships?

**Recommendation: No.** Reasons:

1. The `relationships` table is indexed on `target_nref`. Finding all inbound arcs for node X is a single `mnesia:index_read(relationship, X, #relationship.target_nref)` call — O(1), no node record scan required.
2. A denormalized flag/count creates an update obligation: every `add_relationship` and `delete_relationship` call must atomically update both the relationship table and the node record. This increases transaction complexity and surface area for bugs.
3. The flag only answers "does an additional parent exist?" — it does not identify which nodes those parents are. So callers still need the `index_read` call regardless.

Conclusion: the secondary index on `target_nref` provides everything the flag would, without the consistency risk.

---

## 6. Multi-Database Architecture

### Two database roles

| Role | Content | Mutability |
|---|---|---|
| **Environment database** | All category, attribute, class, and language nodes; the bootstrap scaffold; arc label definitions | Category nodes: immutable (bootstrap only). All other nodes grow freely at runtime. |
| **Project database** | Instance nodes and their relationships; one database per project | Fully mutable at runtime |

The environment is shared across all projects. It is the single source of truth for the knowledge schema — arc labels, class definitions, name attributes, and the category scaffold. It is a **living, growing database**: new literal attributes, relationship attributes, and classes are added over time as the knowledge base evolves. Only the category nodes (nrefs 1–5) are permanently fixed.

**Code understanding of nrefs**: Only the bootstrap nrefs (1–30) and a small number of explicitly seeded runtime nrefs (e.g., `target_kind`) are referenced directly by nref constant in the implementation. All other runtime-added attributes, classes, and languages are treated generically by the code — their meaning lives in the graph itself, not in the source.

### What lives where

| Concept | Database |
|---|---|
| Category nodes (nrefs 1–5) | Environment |
| Attribute nodes (nrefs 6–30, 10000+) | Environment |
| Class nodes (runtime, 10000+) | Environment |
| Language nodes | Environment |
| Instance nodes | Project |
| Class-membership relationship pairs | Project |
| Instance compositional arcs | Project |
| Instance user-defined arcs | Project |
| Bootstrap compositional arcs (scaffold) | Environment |
| Runtime attribute compositional arcs (new attrs added to library) | Environment |
| Runtime class taxonomy arcs | Environment |

### nref spaces

| Database | nref range | nref_start | Allocator start |
|---|---|---|---|
| Environment | 1–30 (bootstrap) + 10000+ (runtime) | 10000 (in `bootstrap.terms`) | 10000 after bootstrap load |
| Project | 1+ | None — no bootstrap file | **1** |

Project databases have no pre-assigned nrefs and no bootstrap file. Their nref allocator starts at 1 and increments freely. Numerical overlap with environment nrefs (e.g., both may have a node with nref=10001) is not a problem because every nref lookup is routed to a specific database determined by context — see **Cross-database nref resolution** below.

### The Projects node (nref 5)

The `Projects` category node (nref 5) in the environment database is the organisational anchor for all projects. Two access modes exist:

**Known projects** — listed as child nodes of the Projects node in the environment database. Each child node contains everything needed to locate and open the project database (connection info, path, credentials, etc.). At runtime, that environment node is *overlaid* by the root node of the actual project database: queries that arrive at the environment's project-stub node are transparently forwarded to the project's own root.

**Private/unknown projects** — not listed in the environment database. Only users who have been given access to the project can open it. For those users the project root appears as a virtual child of the Projects node, not backed by any node in the environment database.

In both cases, whether a project appears under the Projects node is optional and independent of whether the project database itself exists and is operational.

### Cross-database nref resolution

All nrefs are plain `integer()` values; there is no database tag embedded in the integer. Context determines which database to query for each field:

| Relationship field | Always in |
|---|---|
| `source_nref` | Same database as the relationship record |
| `characterization` | Environment (entire attribute library lives there) |
| `reciprocal` | Environment |
| `target_nref` | Determined by the arc label's `target_kind` annotation |

**`target_kind` annotation**: Every arc label attribute node in the environment must carry a literal AVP specifying what kind of node its arc targets. Since `kind` determines the database, this resolves the lookup:

| target_kind value | Target database |
|---|---|
| `category` | Environment |
| `attribute` | Environment |
| `class` | Environment |
| `instance` | Project |

This annotation is stored in the `Literals` subtree (nref 7) of the environment attribute library. It must be present on all built-in arc labels at bootstrap time and required for all user-defined arc labels at creation time via `graphdb_attr`.

Built-in resolution for the 30 bootstrap arc labels:

| Nref | Arc label | target_kind |
|---|---|---|
| 21 | Parent/CatRel | `category` |
| 22 | Child/CatRel | `category` |
| 23 | Parent/AttrRel | `attribute` |
| 24 | Child/AttrRel | `attribute` |
| 25 | Parent/ClassRel | `class` |
| 26 | Child/ClassRel | `class` |
| 27 | Parent/InstRel | `instance` |
| 28 | Child/InstRel | `instance` |
| 29 | Class | `class` |
| 30 | Instance | `instance` |

### Environment relationships table write policy

The environment relationships table is written at bootstrap and continues to be written at runtime as the knowledge base grows:

- **Bootstrap**: all 29 compositional arc pairs for the category/attribute scaffold
- **Runtime — new attribute**: `graphdb_attr` writes a parent→child arc pair placing the new attribute node in its correct position in the attribute library tree
- **Runtime — new class**: `graphdb_class:create_class/2` writes a parent→child arc pair in the class taxonomy
- **Runtime — new language**: similarly writes compositional arcs under the Languages category

Project databases **never** write to the environment relationships table. All instance-level arcs, including class-membership pairs, are written to the project database only.

---

## 7. nref Layer Changes

### Environment database allocator

The environment allocator (`nref_server` / `nref_allocator`) is started by the `nref`
OTP application. Its DETS counter is initialised from disk on startup (defaulting to 1 on
a fresh node). `graphdb_bootstrap` calls `nref_server:set_floor(10000)` as the first step
of a bootstrap load, advancing the counter to 10000 and persisting it. On all subsequent
startups the persisted counter is already ≥ 10000, so `set_floor` has no effect.

### Project database allocators

Each project database manages its own nref counter independently. Project allocators
**start at 1** — there are no pre-assigned bootstrap nrefs in a project database, so no
floor is needed. The `nref` application as currently designed serves the environment
database. Project nref allocation is a separate concern to be designed when the
project-database layer is implemented; the simplest approach is a per-project DETS file
holding the counter, mirroring the environment allocator's design.

### `nref_server` — new `set_floor/1` API

One new public function has been added to the environment allocator (Task 0b — **done**),
called once by `graphdb_bootstrap`:

```erlang
%% Advance the nref counter to at least Floor.
%% No-op if the counter is already >= Floor.
%% Called once by graphdb_bootstrap before writing any nodes or relationships.
nref_server:set_floor(Floor :: integer()) -> ok.
```

This atomically sets the DETS counter to `max(current_counter, Floor)`, ensuring the
environment allocator never issues any nref in the bootstrap range 1–9999.

---

## 8. Bootstrap Init File  *(environment database only)*

### Format: Erlang Terms via `file:consult/1`

| Format | Decision | Reason |
|---|---|---|
| **Erlang Terms** | **Selected** | Zero new dependencies; already used in project; `%` comments; pattern-matched directly |
| JSON | Rejected | Requires external library |
| Custom DSL | Rejected | Parser maintenance burden |
| XML | Rejected | Too verbose; requires a parser |

### Record schema

```erlang
%% Floor directive — must appear exactly once; processed FIRST by the loader:
{nref_start, N}.
%%
%%   N :: integer()  — calls nref_server:set_floor(N) before any other processing
%%                     so subsequent get_nref/0 calls (for relationship IDs) return >= N.
%%                     All pre-assigned node nrefs in the file must be < N.

%% Node record:
{node, Nref, Kind, ParentNref, {NameAttrNref, NameValue}, [{AttrNref, Value}]}.
%%
%%   Nref         :: integer()              — pre-assigned nref for this node
%%   Kind         :: category | attribute | class | instance
%%   ParentNref   :: integer() | undefined  — undefined for root (nref=1) only
%%   NameAttrNref :: integer()              — nref of the name attribute concept
%%   NameValue    :: string() | binary()    — the node's name
%%   [{AttrNref, Value}] :: shorthand; loader expands to #{attribute => AttrNref, value => Value}

%% Bidirectional relationship record — loader writes two relationship rows atomically:
{relationship, Node1Nref, Rel1Nref, [Node1AVPs], Rel2Nref, Node2Nref, [Node2AVPs]}.
%%
%%   Node1Nref :: integer()   — nref of first node (arc origin)
%%   Rel1Nref  :: integer()   — arc label from Node1 → Node2
%%   Node1AVPs :: list()      — per-direction metadata on the Node1 side
%%   Rel2Nref  :: integer()   — reciprocal arc label from Node2 → Node1
%%   Node2Nref :: integer()   — nref of second node (arc target)
%%   Node2AVPs :: list()      — per-direction metadata on the Node2 side
```

### Processing order

The loader processes the file in this section order:

1. `nref_start` directive — `nref_server:set_floor(N)` called **first**; subsequent `get_nref/0` calls for relationship IDs return `>= N`, avoiding collision with pre-assigned node nrefs
2. `category` nodes
3. `attribute` nodes
4. `class` nodes
5. `instance` nodes
6. `relationship` records — each gets an ID via `nref_server:get_nref()`; expands to two directed rows written atomically

### File location

Configurable via `bootstrap_file` key in `default.config`. Default value:
`"apps/graphdb/priv/bootstrap.terms"`

### File

`apps/graphdb/priv/bootstrap.terms` — fully written; contains all 30 nodes (nrefs 1–30) and 29 relationship pairs (27 compositional + 2 membership). See that file for the authoritative content.

---

## 9. New Module: `graphdb_bootstrap` — **DONE**

File: `apps/graphdb/src/graphdb_bootstrap.erl`

### Responsibilities (all implemented)

1. Called from `graphdb_mgr:init/1` — `load/0` is idempotent (creates tables if needed, skips if already populated)
2. Reads `bootstrap_file` path from application env
3. Calls `file:consult/1`, validates all terms
4. Validates that exactly one `{nref_start, N}` directive is present and all node nrefs are `< N`
5. Calls `nref_server:set_floor(N)` **first** — subsequent `get_nref/0` calls return `>= N`
6. Writes nodes to Mnesia in section order: `category` → `attribute` → `class` → `instance`
7. Expands each `{relationship,...}` term into two directed `relationship` records; each gets an ID via `get_nref()`; writes both rows atomically
8. Logs progress and any validation errors

### Implementation notes

- Mnesia table names are plural (`nodes`, `relationships`); record names are singular (`node`, `relationship`). Uses `{record_name, ...}` table option; all operations use `mnesia:write/3` (explicit 3-arg form).
- nref IDs for relationships are allocated outside Mnesia transactions to avoid side-effects on retry.

### Category-only enforcement

After bootstrap completes, `graphdb_mgr` enforces that no runtime call can create, update,
or delete a `category` node. Any such attempt returns `{error, category_nodes_are_immutable}`.

### Public API

```erlang
%% Called by graphdb_mgr:init/1:
graphdb_bootstrap:load() -> ok | {error, Reason :: term()}.
```

---

## 10. Open Questions

All questions resolved. No blockers for implementation.

| Question | Answer |
|---|---|
| Path format for `log_path`, `data_path`, `bootstrap_file` | Both relative and absolute accepted; relative resolved from OTP release root |
| Who sets Mnesia `dir`? | Set directly in `default.config` under `{mnesia, [{dir, "data"}]}` — no code needed |
| `nref_start` placement | Directive `{nref_start, 10000}` in `bootstrap.terms` — not in config; one-time value belongs with the bootstrap data |
| Stale DETS files | Deleted (`graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets`) |
| Bootstrap file content | **Done** — `apps/graphdb/priv/bootstrap.terms` written; nrefs 1–30, BFS |

---

## 11. Files Affected

```
SeerStoneGraphDb/
├── apps/seerstone/priv/
│   └── default.config               DONE — added log_path, bootstrap_file, mnesia dir; removed index_path
├── apps/nref/src/
│   ├── nref_allocator.erl           DONE — set_floor/1 added
│   └── nref_server.erl              DONE — set_floor/1 added
├── apps/graphdb/src/
│   ├── graphdb_mgr.erl              CHANGE — bootstrap detection in init/1; call graphdb_bootstrap:load()
│   ├── graphdb_attr.erl             IMPLEMENT — attribute library over Mnesia
│   ├── graphdb_class.erl            IMPLEMENT — taxonomic hierarchy over Mnesia
│   ├── graphdb_instance.erl         IMPLEMENT — compositional hierarchy + inheritance over Mnesia
│   ├── graphdb_rules.erl            IMPLEMENT — rule storage and enforcement
│   ├── graphdb_language.erl         IMPLEMENT — query parser and executor
│   └── graphdb_bootstrap.erl        DONE — bootstrap file loader + Mnesia schema/table creation
└── apps/graphdb/priv/
    └── bootstrap.terms              DONE — 30 nodes (nrefs 1–30), 29 relationship pairs (27 compositional + 2 membership)
```

---

## 12. Implementation Order

1. ~~`default.config` — add `log_path`, `bootstrap_file`, `mnesia dir` keys~~ — **done**
2. ~~`nref_server` / `nref_allocator` — add `set_floor/1` API~~ — **done**
3. ~~Delete stale `.dets` files~~ — **done**
3a. ~~`apps/graphdb/priv/bootstrap.terms`~~ — **done** (nrefs 1–30, BFS)
4. ~~`graphdb_bootstrap`~~ — **done** implement loader; includes Mnesia schema/table creation~~ — **done**
5. ~~`graphdb_mgr`~~ — **done** bootstrap detection in `init/1`; read `bootstrap_file` from env; call loader ← **next**
7. ~~`graphdb_attr` — implement attribute library (Mnesia-backed)
8. `graphdb_class` — implement taxonomic hierarchy (Mnesia-backed)
9. `graphdb_instance` — implement compositional hierarchy + inheritance (Mnesia-backed)
10. `graphdb_mgr` — route public API calls to workers
11. `graphdb_rules` — rule storage and enforcement
12. `graphdb_language` — query parser and executor

