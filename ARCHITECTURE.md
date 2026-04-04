# Architectural Design Proposal — SeerStoneGraphDb

> **Status:** Design phase complete — all questions resolved. Stale DETS files deleted. Bootstrap node content deferred by user. Ready for implementation.

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
  {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"},
  {nref_start,     10000}         %% allocator will not issue any nref below this value
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
| `nref_start` | Inclusive lower bound; the nref allocator's counter starts at this value and never issues nrefs below it. Default: `10000` |

### Path resolution

Both relative and absolute paths are accepted for `log_path`, `data_path`, and `bootstrap_file`. Relative paths are resolved from the OTP release root at runtime (standard OTP convention). Absolute paths take effect as-is. Use relative paths for packaged releases; absolute paths for development overrides.

### Mnesia dir configuration

Mnesia reads its storage directory from its own application env key `{mnesia, dir}`. This is set directly in `default.config` (alongside the `seerstone_graph_db` env) so no code needs to call `application:set_env/3` for it. The value must match `data_path`.

### nref_start replaces the compile-time constant

The earlier design proposed a `?BOOTSTRAP_NREF_CEILING` macro. That is replaced by `nref_start` in config. The `nref_allocator` reads this value from application env at startup and initialises its counter to `max(persisted_counter, nref_start)`. Bootstrap nrefs (which are all below `nref_start`) are loaded by the bootstrap loader and written directly to Mnesia without going through the allocator's normal counter.

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
  kind,                   %% attribute | class | instance
  parent,                 %% integer() | undefined (undefined = root only)
  attribute_value_pairs   %% [#{attribute => Nref, value => term()}]
}).
```

Secondary index: `parent` — enables efficient `children/1` queries.

### Root node

- Nref = **1** (first and lowest possible nref; pre-assigned in the bootstrap file)
- `parent = undefined`
- The only node in the database where `parent` is `undefined`

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

1. At startup, read `nref_start` from application env:
   ```erlang
   {ok, NrefStart} = application:get_env(seerstone_graph_db, nref_start).
   ```
2. Initialise the DETS counter to `max(PersistedCounter, NrefStart)` — ensures the counter never falls below `nref_start` even on a fresh node.
3. The `get_nref/0` path is unchanged; it simply increments from wherever the counter sits.

### `nref_server` changes

No new public API is required. Bootstrap nrefs (e.g., nref = 1 for root) are written directly to Mnesia by `graphdb_bootstrap` without going through `nref_server`. Because `nref_allocator` starts its counter at `nref_start`, it will never reissue any bootstrap nref — no explicit reservation call is needed.

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
%% Node record:
{node, Nref, Kind, ParentNref, {NameAttrNref, NameValue}, [{AttrNref, Value}]}.
%%
%%   Nref         :: integer()              — pre-assigned nref for this node
%%   Kind         :: attribute | class | instance
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

The loader processes the file in section order:

1. `attribute` nodes
2. `class` nodes
3. `instance` nodes
4. `relationship` records

### File location

Configurable via `bootstrap_file` key in `default.config`. Default value:
`"apps/graphdb/priv/bootstrap.terms"`

### Example

```erlang
%% bootstrap.terms — SeerStoneGraphDb bootstrap data
%% Copyright (c) SeerStone, Inc. 2008

%% --- Root and attribute nodes ---
{node, 1, attribute, undefined, {2, "Root"},  []}.
{node, 2, attribute, 1,         {2, "Name"},  []}.

%% --- Bidirectional relationship ---
{relationship, 10, 20, [], 21, 11, []}.
```

---

## 8. New Module: `graphdb_bootstrap`

File: `apps/graphdb/src/graphdb_bootstrap.erl`

### Responsibilities

1. Called from `graphdb_mgr:init/1` when the Mnesia `nodes` table is empty
2. Reads `bootstrap_file` path from application env
3. Calls `file:consult/1`, validates all terms
4. Partitions terms into nodes and relationships; processes in section order
5. Writes all node records to Mnesia (`nodes` table)
6. Expands each `{relationship,...}` term into two directed `relationship` records; writes atomically
7. Logs progress and any validation errors

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
| `nref_start` value | `10000` |
| Stale DETS files | Deleted (`graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets`) |
| Bootstrap file content | Deferred — user will supply when ready |

---

## 10. Files Affected

```
SeerStoneGraphDb/
├── apps/seerstone/priv/
│   └── default.config               CHANGE — add log_path, bootstrap_file, nref_start keys
├── apps/nref/src/
│   └── nref_allocator.erl           CHANGE — read nref_start from env; init counter to max(persisted, nref_start)
├── apps/graphdb/src/
│   ├── graphdb_mgr.erl              CHANGE — bootstrap detection in init/1; call graphdb_bootstrap:load()
│   ├── graphdb_attr.erl             IMPLEMENT — attribute library over Mnesia
│   ├── graphdb_class.erl            IMPLEMENT — taxonomic hierarchy over Mnesia
│   ├── graphdb_instance.erl         IMPLEMENT — compositional hierarchy + inheritance over Mnesia
│   ├── graphdb_rules.erl            IMPLEMENT — rule storage and enforcement
│   ├── graphdb_language.erl         IMPLEMENT — query parser and executor
│   └── graphdb_bootstrap.erl        CREATE — bootstrap file loader (new module)
└── apps/graphdb/priv/
    └── bootstrap.terms              CREATE — bootstrap node/relationship data (content TBD)
```

---

## 11. Implementation Order

1. `default.config` — add `log_path`, `bootstrap_file`, `nref_start = 10000`, `mnesia dir` keys
2. `nref_allocator` — read `nref_start` from env; init counter floor
3. ~~Delete stale `.dets` files~~ — **done**
4. `graphdb_bootstrap` — implement loader; includes Mnesia schema/table creation
5. `graphdb_mgr` — bootstrap detection in `init/1`; read `bootstrap_file` from env; call loader
6. `apps/graphdb/priv/bootstrap.terms` — write from user-supplied content (deferred)
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
We are resuming an architecture design session for SeerStoneGraphDb.
Read ARCHITECTURE.md for the full design decisions and TASKS.md for the task list.
All structural questions are resolved. The next action is to begin implementation
in the order listed in ARCHITECTURE.md Section 11, starting at step 1.
Bootstrap file content (step 6) is deferred — skip it and continue with step 7.
```
