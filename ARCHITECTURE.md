# Architectural Design Proposal — SeerStoneGraphDb

> **Status:** Design phase complete — all questions resolved. Bootstrap nrefs assigned (BFS, 1–30). `apps/graphdb/priv/bootstrap.terms` written. Ready for implementation.

---

## 1. Codebase Baseline

| Area | State |
|---|---|
| Build | Compiles cleanly — zero warnings (OTP 27 / rebar3 3.24) |
| `nref_server` / `nref_allocator` | Fully implemented; DETS-backed |
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
            (children of Names:)
 9          ├── Category Name Attributes (attribute)
10          ├── Class Name Attributes (attribute)
11          ├── Instance Name Attributes (attribute)
12          └── Attribute Name Attributes (attribute)
            (children of Relationships:)
13          ├── Category Relationships (attribute)
14          ├── Class Relationships (attribute)
15          ├── Instance Relationships (attribute)
16          └── Attribute Relationships (attribute)
            (children of *Name Attributes — one Name per kind:)
17              ├── Name  ← NameAttrNref for category nodes  (parent: 9)
18              ├── Name  ← NameAttrNref for class nodes     (parent: 10)
19              ├── Name  ← NameAttrNref for instance nodes  (parent: 11)
20              └── Name  ← NameAttrNref for attribute nodes (parent: 12, self-ref)
            (children of *Relationships — arc label nodes:)
21              ├── Parent    category compositional arc label  (parent: 13)
22              ├── Child     category compositional arc label  (parent: 13)
23              ├── Parent    class compositional arc label     (parent: 14)
24              ├── Child     class compositional arc label     (parent: 14)
25              ├── Parent    instance compositional arc label  (parent: 15)
26              ├── Child     instance compositional arc label  (parent: 15)
27              ├── Parent    attribute compositional arc label (parent: 16, self-ref)
28              ├── Child     attribute compositional arc label (parent: 16, self-ref)
            (continued — added after initial BFS; out of strict level order:)
29              ├── Class     instance→class membership arc    (parent: 15)
30              └── Instance  class→instances membership arc   (parent: 15)
```

### NameAttrNref quick-reference

| Kind | NameAttrNref |
|---|---|
| `category` | 17 |
| `class` | 18 |
| `instance` | 19 |
| `attribute` | 20 |

### Compositional arc labels quick-reference

Arc labels used in `{relationship, ParentNref, ChildArcNref, [], ParentArcNref, ChildNref, []}` terms. `ChildArcNref` is the characterization on the parent→child directed row; `ParentArcNref` is the characterization on the child→parent directed row.

| Child kind | ChildArcNref | ParentArcNref |
|---|---|---|
| `category` | 22 (Child/CatRel) | 21 (Parent/CatRel) |
| `attribute` | 28 (Child/AttrRel) | 27 (Parent/AttrRel) |
| `class` | 24 (Child/ClassRel) | 23 (Parent/ClassRel) |
| `instance` | 26 (Child/InstRel) | 25 (Parent/InstRel) |

The last two rows under Attribute Relationships (nrefs 27 and 28) are self-referential: the arc label attribute nodes for "attribute" compositional arcs are themselves attribute nodes whose own parent arc label is nref 27. This is consistent — the system uses its own arc label vocabulary to describe itself.

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

## 6. nref Layer Changes

### `nref_allocator` changes

No startup changes required. The allocator initialises its counter from whatever is
persisted in DETS (defaulting to 1 on a fresh node). It does not read `nref_start` from
config — that value is handled entirely by the bootstrap loader as a one-time operation.

### `nref_server` — new `set_floor/1` API

One new public function is needed, called once by `graphdb_bootstrap` after all bootstrap
nodes and relationships are written:

```erlang
%% Advance the nref counter to at least Floor.
%% No-op if the counter is already >= Floor.
%% Called once by graphdb_bootstrap at the end of a successful bootstrap run.
nref_server:set_floor(Floor :: integer()) -> ok.
```

This atomically sets the DETS counter to `max(current_counter, Floor)`, ensuring the
allocator will never issue any nref in the bootstrap range. On all subsequent startups
the persisted counter is already above the floor, so this function is never called again.

---

## 7. Bootstrap Init File

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

`apps/graphdb/priv/bootstrap.terms` — fully written; contains all 28 nodes (nrefs 1–28) and 27 compositional relationship pairs. See that file for the authoritative content.

---

## 8. New Module: `graphdb_bootstrap`

File: `apps/graphdb/src/graphdb_bootstrap.erl`

### Responsibilities

1. Called from `graphdb_mgr:init/1` when the Mnesia `nodes` table is empty
2. Reads `bootstrap_file` path from application env
3. Calls `file:consult/1`, validates all terms
4. Validates that exactly one `{nref_start, N}` directive is present and all node nrefs are `< N`
5. Calls `nref_server:set_floor(N)` **first** — subsequent `get_nref/0` calls return `>= N`
6. Writes nodes to Mnesia in section order: `category` → `attribute` → `class` → `instance`
7. Expands each `{relationship,...}` term into two directed `relationship` records; each gets an ID via `get_nref()`; writes both rows atomically
9. Logs progress and any validation errors

### Category-only enforcement

After bootstrap completes, `graphdb_mgr` enforces that no runtime call can create, update,
or delete a `category` node. Any such attempt returns `{error, category_nodes_are_immutable}`.

### Public API

```erlang
%% Called by graphdb_mgr:init/1:
graphdb_bootstrap:load() -> ok | {error, Reason :: term()}.
```

---

## 9. Open Questions

All questions resolved. No blockers for implementation.

| Question | Answer |
|---|---|
| Path format for `log_path`, `data_path`, `bootstrap_file` | Both relative and absolute accepted; relative resolved from OTP release root |
| Who sets Mnesia `dir`? | Set directly in `default.config` under `{mnesia, [{dir, "data"}]}` — no code needed |
| `nref_start` placement | Directive `{nref_start, 10000}` in `bootstrap.terms` — not in config; one-time value belongs with the bootstrap data |
| Stale DETS files | Deleted (`graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets`) |
| Bootstrap file content | **Done** — `apps/graphdb/priv/bootstrap.terms` written; nrefs 1–28, BFS |

---

## 10. Files Affected

```
SeerStoneGraphDb/
├── apps/seerstone/priv/
│   └── default.config               CHANGE — add log_path, bootstrap_file, nref_start keys
├── apps/nref/src/
│   ├── nref_allocator.erl           CHANGE — add set_floor/1 internal implementation
│   └── nref_server.erl              CHANGE — expose set_floor/1 public API
├── apps/graphdb/src/
│   ├── graphdb_mgr.erl              CHANGE — bootstrap detection in init/1; call graphdb_bootstrap:load()
│   ├── graphdb_attr.erl             IMPLEMENT — attribute library over Mnesia
│   ├── graphdb_class.erl            IMPLEMENT — taxonomic hierarchy over Mnesia
│   ├── graphdb_instance.erl         IMPLEMENT — compositional hierarchy + inheritance over Mnesia
│   ├── graphdb_rules.erl            IMPLEMENT — rule storage and enforcement
│   ├── graphdb_language.erl         IMPLEMENT — query parser and executor
│   └── graphdb_bootstrap.erl        CREATE — bootstrap file loader (new module)
└── apps/graphdb/priv/
    └── bootstrap.terms              DONE — 30 nodes (nrefs 1–30), 29 relationship pairs
```

---

## 11. Implementation Order

1. `default.config` — add `log_path`, `bootstrap_file`, `mnesia dir` keys
2. `nref_server` / `nref_allocator` — add `set_floor/1` API
3. ~~Delete stale `.dets` files~~ — **done**
3a. ~~`apps/graphdb/priv/bootstrap.terms`~~ — **done** (nrefs 1–28, BFS)
4. `graphdb_bootstrap` — implement loader; includes Mnesia schema/table creation
5. `graphdb_mgr` — bootstrap detection in `init/1`; read `bootstrap_file` from env; call loader
7. `graphdb_attr` — implement attribute library (Mnesia-backed)
8. `graphdb_class` — implement taxonomic hierarchy (Mnesia-backed)
9. `graphdb_instance` — implement compositional hierarchy + inheritance (Mnesia-backed)
10. `graphdb_mgr` — route public API calls to workers
11. `graphdb_rules` — rule storage and enforcement
12. `graphdb_language` — query parser and executor

---

## Session Resume

To resume this session, start a new OpenCode session in this repository and paste:

```
We are resuming implementation of SeerStoneGraphDb.
Read ARCHITECTURE.md for full design decisions and TASKS.md for the task list.
All design questions are resolved. bootstrap.terms is complete (nrefs 1-28, BFS).
Begin implementation in the order listed in ARCHITECTURE.md Section 11, starting at step 1.
```
