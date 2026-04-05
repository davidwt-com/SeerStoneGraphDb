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

### ~~0a. Update `default.config`~~ — DONE

File: `apps/seerstone/priv/default.config`

Added `log_path`, `data_path`, `bootstrap_file` keys; added `{mnesia, [{dir, "data"}]}`
stanza; removed unused `index_path`. Also updated `config/sys.config` to match.

### ~~0b. Add `set_floor/1` to `nref_server` and `nref_allocator`~~ — DONE

Files: `apps/nref/src/nref_server.erl`, `apps/nref/src/nref_allocator.erl`

Added `nref_server:set_floor(Floor)` and `nref_allocator:set_floor(Floor)`. Implementation
atomically sets the DETS counter to `max(current_counter, Floor)`. `nref_server` delegates
to `nref_allocator:set_floor/1` first, then advances its own `free` counter and sets
`top = free` to force a fresh block request.

### ~~0c. Delete stale DETS files~~ — DONE

`graphdb_attr.dets`, `graphdb_attr_index.dets`, `graphdb_attr_types.dets` deleted from
the repository root. `nref_allocator.dets` and `nref_server.dets` are retained (live).

---

## ~~Task 1 — `graphdb_bootstrap` — Bootstrap Loader (New Module)~~ — DONE

File: `apps/graphdb/src/graphdb_bootstrap.erl`

Implemented: Mnesia schema/table creation, bootstrap.terms file loader, node and
relationship writers. `load/0` is idempotent — creates schema/tables if needed,
skips data load if the `nodes` table is already populated.

- Mnesia tables: `nodes` (disc_copies, index on `parent`) and `relationships`
  (disc_copies, indexes on `source_nref` and `target_nref`)
- Table names are plural; record names are singular — uses `{record_name, node}` /
  `{record_name, relationship}` option; all Mnesia operations use explicit 3-arg form
- Processing order: `nref_start` → category → attribute → class → instance → relationships
- Each relationship term expands to two directed rows; IDs allocated via
  `nref_server:get_nref/0` outside the Mnesia transaction to avoid side-effects on retry

**Bootstrap file: DONE**
`apps/graphdb/priv/bootstrap.terms` is fully written: 30 nodes (nrefs 1–30, BFS) and
29 relationship pairs (27 compositional + 2 membership arc labels). See ARCHITECTURE.md
Section 4 for the nref table and arc label quick-reference.

---

## ~~Task 2 — `graphdb_mgr` — Startup Wiring~~ — DONE

File: `apps/graphdb/src/graphdb_mgr.erl`

Implemented: bootstrap detection in `init/1`, public API skeleton, category
immutability guard, and read operations.

- **`init/1`**: calls `graphdb_bootstrap:load/0` (idempotent); returns
  `{stop, {bootstrap_failed, Reason}}` on failure
- **Read API** (fully functional):
  - `get_node/1` — Mnesia read by primary key
  - `get_relationships/1` — outgoing relationships (default)
  - `get_relationships/2` — directional query (`outgoing | incoming | both`)
- **Write API** (category guard + delegation stubs):
  - `create_attribute/3`, `create_class/2`, `create_instance/3`,
    `add_relationship/4` — return `{error, not_implemented}` pending worker
    implementation (Tasks 3–5)
  - `delete_node/1`, `update_node_avps/2` — enforce category immutability
    guard; return `{error, not_implemented}` for non-category nodes
- **Category guard**: `check_category_guard/1` reads the node and rejects
  `kind = category` with `{error, category_nodes_are_immutable}`
- **Direction validation**: `validate_direction/1` rejects invalid directions
  client-side before the gen_server call

---

## ~~Task 3 — `graphdb_attr` — Attribute Library~~ — DONE

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
| ~~0a~~ | ~~Update `default.config`~~ — **done** | — |
| ~~0b~~ | ~~Add `nref_server:set_floor/1` API~~ — **done** | — |
| ~~0c~~ | ~~Delete stale DETS files~~ — **done** | — |
| ~~1~~ | ~~`graphdb_bootstrap` + Mnesia schema~~ — **done** | 0a, 0b |
| ~~2~~ | ~~`graphdb_mgr` startup wiring~~ — **done** | 1 |
| ~~3~~ | ~~`graphdb_attr`~~ — **done** | 1, 2 |
| 4 | `graphdb_class` ← **next** | 3 |
| 5 | `graphdb_instance` | 3, 4 |
| 6 | `graphdb_rules` | 5 |
| 7 | `graphdb_language` | 5 |
| 8 | `dictionary_server` / `term_server` | — (independent) |
| L1 | Non-normal start types | — |
| L2 | `code_change/3` | — |
| L3 | `start_phases` | — |

---

## Session Resume

To resume this session, start a new claude or OpenCode session in this repository and paste:

```
We are resuming implementation of SeerStoneGraphDb.
Read ARCHITECTURE.md for full design decisions and TASKS.md for the task list.
All design questions are resolved. bootstrap.terms is complete (nrefs 1-30, BFS).
Tasks 0a-0c, Task 1 (graphdb_bootstrap), Task 2 (graphdb_mgr startup wiring), Task 3 (graphdb_attr) are done.
Next task: Task 4 — `graphdb_class` — Taxonomic Hierarchy (step 8 in ARCHITECTURE.md Section 12).
```
