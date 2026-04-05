# SeerStoneGraphDb — Remaining Tasks

The project compiles clean with zero warnings (OTP 27 / rebar3 3.24). All
modernization work is complete. The architecture has been fully designed
(see `ARCHITECTURE.md`). What follows is implementation work in priority order.

---

## Architecture Summary (read ARCHITECTURE.md for full detail)

- **Two database roles**: *Environment* (categories, attributes, classes, languages — shared, living schema that grows over time) and *Project* (instances and their relationships — one database per project, independent). Only category nodes are immutable; all other environment nodes grow freely at runtime. Only bootstrap nrefs (1–30) and a small number of explicitly seeded runtime nrefs (e.g., `target_kind`) are referenced by nref constant in code — all other runtime-added nodes are treated generically.
- **Storage**: Mnesia for all six `graphdb_*` workers (two tables per database: `nodes`, `relationships`)
- **nref spaces**: Environment allocator starts at 10000 (protected by `{nref_start, 10000}` in bootstrap.terms). Project allocators start at **1** — no pre-assigned nrefs, no bootstrap file, no floor needed
- **Cross-database nref resolution**: `characterization` and `reciprocal` fields always reference environment nrefs; `target_nref` is routed to environment or project based on the arc label's `target_kind` AVP (see ARCHITECTURE.md Section 6)
- **nref layer**: Environment allocator stays on DETS; `nref_server` gains `set_floor/1` API called once by bootstrap loader. Project allocators are a separate concern (TBD)
- **Dictionary**: Stays on ETS
- **Bootstrap**: `graphdb_bootstrap` loads `bootstrap.terms` on first environment-database startup; `{nref_start, 10000}` directive is first term in that file
- **Config**: `default.config` is the single runtime config; gains `log_path`, `bootstrap_file`, and `{mnesia, [{dir, "data"}]}`
- **Node kinds**: `category | attribute | class | instance`; `category` is bootstrap-only and immutable at runtime
- **Root node**: nref = 1; `kind = category`; only node with `parent = undefined`
- **Bootstrap tree**: category/attribute scaffold pre-built at first environment startup (see ARCHITECTURE.md Section 4 for full tree)
- **Relationships**: Separate Mnesia table; indexed on `source_nref` and `target_nref`; bidirectional edge = two directed rows written atomically; class/instance relationships stored in project database, not environment

---

## Task 0 — Pre-implementation: Config and Infrastructure

### 0a. Update `default.config`

File: `apps/seerstone/priv/default.config`

Add the following keys. Both relative and absolute paths are accepted; relative paths
resolve from the OTP release root. Note: `nref_start` is NOT here — it is a one-time
bootstrap directive in `bootstrap.terms`.

```erlang
[{seerstone_graph_db, [
  {app_port,       8080},
  {log_path,       "log"},
  {data_path,      "data"},
  {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"}
]},
 {mnesia, [
  {dir, "data"}    %% must match data_path; Mnesia reads this from its own app env
]}].
```

### 0b. Add `set_floor/1` to `nref_server` and `nref_allocator`

Files: `apps/nref/src/nref_server.erl`, `apps/nref/src/nref_allocator.erl`

- Add `nref_server:set_floor(Floor :: integer()) -> ok`
- Implementation: atomically set the DETS counter to `max(current_counter, Floor)`
- Called exactly once by `graphdb_bootstrap` at the end of a successful bootstrap run,
  after all nodes and relationships have been written to Mnesia
- On all subsequent startups the persisted counter is already `>= Floor`; this function
  is never called again
- `get_nref/0` is unchanged; `nref_allocator` startup is unchanged (no config read needed)

### 0c. ~~Delete stale DETS files~~ — DONE

`graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets` deleted from
the repository root. `nref_allocator.dets` and `nref_server.dets` are retained (live).

---

## Task 1 — `graphdb_bootstrap` — Bootstrap Loader (New Module)

File: `apps/graphdb/src/graphdb_bootstrap.erl`

This module is called by `graphdb_mgr:init/1` when the Mnesia `nodes` table is empty.

**Sub-tasks:**

- Define Mnesia record types:
  ```erlang
  -record(node, {nref, kind, parent, attribute_value_pairs}).
  %% kind :: category | attribute | class | instance
  -record(relationship, {id, source_nref, characterization, target_nref, reciprocal, avps}).
  ```
- Implement Mnesia schema and table creation (called once at first startup):
  - `nodes` table: `{disc_copies, [node()]}`, index on `parent`
  - `relationships` table: `{disc_copies, [node()]}`, indexes on `source_nref` and `target_nref`
- Read `bootstrap_file` path from `application:get_env(seerstone_graph_db, bootstrap_file)`
- Call `file:consult/1` on the bootstrap file; validate all terms
- Validate that exactly one `{nref_start, N}` directive is present and that all node
  nrefs are `< N`; fail fast otherwise
- Process in this order:
  1. `{nref_start, N}` directive — call `nref_server:set_floor(N)` **first** so subsequent
     `get_nref/0` calls for relationship IDs return `>= N`, never colliding with pre-assigned nrefs
  2. `category` nodes
  3. `attribute` nodes
  4. `class` nodes
  5. `instance` nodes
  6. `relationship` records — each gets an ID via `get_nref()`; two directed rows per term, atomic
- Write each node to Mnesia in a transaction
- Expand each `{relationship, N1, R1, AVPs1, R2, N2, AVPs2}` term into two directed
  `relationship` records; write both atomically in the same Mnesia transaction
- Public API:
  ```erlang
  graphdb_bootstrap:load() -> ok | {error, Reason :: term()}.
  ```

**Bootstrap file: DONE**
`apps/graphdb/priv/bootstrap.terms` is fully written: 28 nodes (nrefs 1–28, BFS) and
27 compositional relationship pairs. See ARCHITECTURE.md Section 4 for the nref table
and arc label quick-reference.

---

## Task 2 — `graphdb_mgr` — Startup Wiring

File: `apps/graphdb/src/graphdb_mgr.erl`

**Sub-tasks:**
- In `init/1`: check if Mnesia `nodes` table exists and is empty
- If empty (first startup): call `graphdb_bootstrap:load/0`; halt with error if it fails
- Define the public API (the single entry point for callers outside `graphdb`):
  - Delegate to `graphdb_attr`, `graphdb_class`, `graphdb_instance` etc.
  - Reject any runtime request to create, modify, or delete a `category` node with
    `{error, category_nodes_are_immutable}`
- Implement transaction-like sequencing: allocate Nref via `nref_server:get_nref/0`
  → write record → confirm Nref

---

## Task 3 — `graphdb_attr` — Attribute Library

File: `apps/graphdb/src/graphdb_attr.erl`

Maintains the set of named concepts used as characterizations (arc labels) for both
naming and relationships. Attribute nodes live in the `nodes` Mnesia table with
`kind = attribute`.

**Sub-tasks:**
- Implement `create_name_attribute/1` (name) — allocates Nref, stores attribute node
- Implement `create_literal_attribute/2` (name, type) — stores type in AVPs
- Implement `create_relationship_attribute/3` (name, reciprocal name, target_kind) — pair of
  attribute nodes; `target_kind :: category | attribute | class | instance` specifies which
  database the arc's `target_nref` lives in. This annotation is stored as an AVP on the
  arc label attribute node and is used by the query engine to route target lookups to the
  correct database (environment vs. project). All built-in arc labels (nrefs 21–30) carry
  this annotation; it is required for all user-defined relationship attributes.
- Implement `create_relationship_type/1` and grouping of attributes under types
- Implement lookup: `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`
- At bootstrap, seed the `target_kind` literal attribute into the `Literals` subtree (nref 7):
  this is the attribute used to annotate all arc label nodes with their target database context
- At bootstrap, the `relationship_avp` flag attribute must be seeded: a literal attribute
  whose presence (value `true`) in another attribute node's own AVPs marks that attribute
  as intended for use on relationship arcs

---

## Task 4 — `graphdb_class` — Taxonomic Hierarchy

File: `apps/graphdb/src/graphdb_class.erl`

Manages the "is a" hierarchy: class nodes, qualifying characteristics, and class-level
inheritance. Class nodes live in the `nodes` table with `kind = class`.

**Sub-tasks:**
- Implement `create_class/2` (name, parent class Nref) — allocates Nref, stores class node
- Implement `add_qualifying_characteristic/2` (class Nref, attribute Nref)
- Implement `get_class/1`, `subclasses/1`, `ancestors/1`
- Implement class-level attribute inheritance: `inherited_attributes/1`

---

## Task 5 — `graphdb_instance` — Compositional Hierarchy and Inheritance

File: `apps/graphdb/src/graphdb_instance.erl`

Creates and retrieves instance nodes; manages the "part of" hierarchy. Instance nodes
live in the `nodes` table with `kind = instance`. Their single compositional parent is
stored as the `parent` field. Additional relational parents (multiple allowed) appear
only in the `relationships` table — no flag or count on the node record is needed because
`mnesia:index_read(relationship, X, #relationship.target_nref)` is O(1).

**Sub-tasks:**
- Implement `create_instance/3` (name, class Nref, compositional parent Nref) — allocates Nref;
  atomically writes the node record AND the instance→class membership relationship pair using
  arc labels nref=29 (Class) and nref=30 (Instance) from the bootstrap scaffold
- Implement `add_relationship/4` (source Nref, characterization Nref, target Nref, reciprocal Nref):
  - Allocates an id Nref for the relationship record
  - Writes two directed `relationship` rows atomically (one per direction)
  - Initial `avps = []`; a later `add_relationship/5` variant will accept caller-supplied AVPs
- Implement `get_instance/1`, `children/1` (uses Mnesia index on `parent`), `compositional_ancestors/1`
- Implement full inheritance resolution: `resolve_value/2` (instance Nref, attribute Nref)
  following priority order:
  1. Local values (highest)
  2. Class-level bound values
  3. Compositional ancestor chain (unbroken upward only)
  4. Directly connected nodes (one level deep; lowest)

---

## Task 6 — `graphdb_rules` — Graph Rules

File: `apps/graphdb/src/graphdb_rules.erl`

Stores and enforces graph rules; supports pattern recognition and learning.

**Sub-tasks:**
- Define rule record schema (pattern: list of relationship constraints)
- Implement `create_rule/2` (name, pattern spec)
- Implement `check_rule/2` (rule Nref, candidate instance Nref)
- Implement `suggest_relationships/1` — scan rules against new instance, suggest likely relationships

---

## Task 7 — `graphdb_language` — Query Language

File: `apps/graphdb/src/graphdb_language.erl`

Parses and executes graph queries against the node network.

**Sub-tasks:**
- Define query DSL (at minimum: find nodes by class, find by attribute value, traverse relationships)
- Implement `parse_query/1` (binary or string → query term)
- Implement `execute_query/1` (query term → [Nref])
- Implement path queries: `find_path/3` (from Nref, to Nref, via relationship type)

---

## Task 8 — `dictionary_server` and `term_server` — Wire to `dictionary_imp`

Files: `apps/dictionary/src/dictionary_server.erl`, `apps/dictionary/src/term_server.erl`

`dictionary_imp` is fully implemented but neither server stub is wired to it.
Implement delegation from each gen_server to the relevant `dictionary_imp` functions.

---

## Lower Priority

### L1. `seerstone:start/2` and `nref:start/2` — non-normal start types NYI

Both hit `?NYI` for `{takeover, Node}` and `{failover, Node}` start types.
Only relevant in a distributed/failover OTP deployment.

### L2. `code_change/3` — NYI in all gen_server modules

Applies to: `nref_allocator`, `nref_server`, and all six `graphdb_*` workers.
Only invoked during a hot code upgrade.

### L3. `seerstone.app.src` — `start_phases` not defined

None of the `.app.src` files define `start_phases`, so `start_phase/3` is never called.
Correct for the present configuration; revisit if phased startup is desired.

---

## Priority Order

| # | Task | Depends on |
|---|---|---|
| 0a | Update `default.config` | — |
| 0b | Add `nref_server:set_floor/1` API | — |
| ~~0c~~ | ~~Delete stale DETS files~~ — **done** | — |
| 1 | `graphdb_bootstrap` + Mnesia schema | 0a |
| 2 | `graphdb_mgr` startup wiring | 1 |
| 3 | `graphdb_attr` | 1, 2 |
| 4 | `graphdb_class` | 3 |
| 5 | `graphdb_instance` | 3, 4 |
| 6 | `graphdb_rules` | 5 |
| 7 | `graphdb_language` | 5 |
| 8 | `dictionary_server` / `term_server` | — (independent) |
| L1 | Non-normal start types | — |
| L2 | `code_change/3` | — |
| L3 | `start_phases` | — |
