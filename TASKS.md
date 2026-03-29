# SeerStoneGraphDb — Remaining Tasks

The project compiles clean with zero warnings (OTP 27 / rebar3 3.24). All
modernization work is complete. What follows is implementation work —
completing Dallas's unfinished NYI stubs.

---

## 1. graphdb worker modules — all are empty stubs

All six graphdb workers exist as gen_server stubs that start cleanly but
contain no graph logic. The knowledge model they must implement is documented
in `knowledge-graph-database-guide.md` (derived from US patents 5,379,366;
5,594,837; 5,878,406 — Noyes).

Graph nodes are identified by **Nrefs** (plain `integer()`, allocated by
`nref_server:get_nref/0`). Every record stores:
```erlang
#{
  nref          => Nref,
  relationships => [
    #{characterization => AttrNref,
      value            => TargetNref,
      reciprocal       => AttrNref2}
  ]
}
```

### 1a. `graphdb_attr` — Attribute Library

Maintains the attribute library: the set of named concepts used as
characterizations (labels) for both naming and relationships, plus literal
attribute descriptors for scalar/external values stored directly on nodes.

**Sub-tasks:**
- Define ETS/DETS schema for attribute records (name, literal, relationship)
- Implement `create_name_attribute/1`, `create_literal_attribute/2` (name, type)
- Implement `create_relationship_attribute/2` (attribute + reciprocal)
- Implement `create_relationship_type/1` and grouping of attributes under types
- Implement lookup: `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`

### 1b. `graphdb_class` — Taxonomic Hierarchy

Manages the "is a" hierarchy: class nodes, qualifying characteristics,
and class-level inheritance.

**Sub-tasks:**
- Define schema for class nodes (class name attr Nref, instance name attr Nref, qualifying characteristics)
- Implement `create_class/2` (name, parent class Nref) — allocates Nref, stores class record
- Implement `add_qualifying_characteristic/2` (class Nref, attribute Nref)
- Implement `get_class/1`, `subclasses/1`, `ancestors/1`
- Implement class-level attribute inheritance: `inherited_attributes/1`

### 1c. `graphdb_instance` — Compositional Hierarchy

Creates and retrieves instance nodes; manages the "part of" hierarchy.

**Sub-tasks:**
- Define schema for instance nodes (name attr Nref, class Nref, compositional parent Nref, relationships)
- Implement `create_instance/3` (name, class Nref, compositional parent Nref) — allocates Nref
- Implement `add_relationship/4` (instance Nref, characterization Nref, target Nref, reciprocal Nref)
- Implement `get_instance/1`, `children/1`, `compositional_ancestors/1`
- Implement full inheritance resolution: `resolve_value/2` (instance Nref, attribute Nref)
  following: local → class-bound → compositional ancestor chain → directly connected (one level)

### 1d. `graphdb_rules` — Graph Rules

Stores and enforces graph rules; supports pattern recognition and learning.

**Sub-tasks:**
- Define rule record schema (pattern: list of relationship constraints)
- Implement `create_rule/2` (name, pattern spec)
- Implement `check_rule/2` (rule Nref, candidate instance Nref)
- Implement `suggest_relationships/1` — scan rules against new instance, suggest likely relationships

### 1e. `graphdb_language` — Query Language

Parses and executes graph queries against the node network.

**Sub-tasks:**
- Define query DSL (at minimum: find nodes by class, find by attribute value, traverse relationships)
- Implement `parse_query/1` (binary or string → query term)
- Implement `execute_query/1` (query term → [Nref])
- Implement path queries: `find_path/3` (from Nref, to Nref, via relationship type)

### 1f. `graphdb_mgr` — Primary Coordinator

Routes and coordinates operations across the other five workers.

**Sub-tasks:**
- Define public API (the single entry point for callers outside graphdb)
- Implement delegation to `graphdb_attr`, `graphdb_class`, `graphdb_instance` etc.
- Implement transaction-like sequencing: allocate Nref → write record → confirm Nref

Location: `apps/graphdb/src/graphdb_*.erl`


## 2. seerstone:start/2 and nref:start/2 — non-normal start types NYI

`apps/seerstone/src/seerstone.erl` and `apps/nref/src/nref.erl` both hit
`?NYI` for `{takeover, Node}` and `{failover, Node}` start types. Only
relevant in a distributed/failover OTP deployment. Low priority, but the
`?NYI` will crash the application master if a non-normal start is ever
attempted.


## 3. code_change/3 — NYI in all gen_server modules

The following gen_server modules have `?NYI(code_change)` in their
`code_change/3` callback:

- `apps/nref/src/nref_allocator.erl`
- `apps/nref/src/nref_server.erl`
- `apps/graphdb/src/graphdb_mgr.erl` (and the other five graphdb workers)

Only invoked during a hot code upgrade. Low priority.


## 4. Old pre-rebar3 directories

The following directories at the project root are **not compiled** by rebar3
and are not part of the active build:

| Path | Status |
|---|---|
| `Dictionary/` | Early design reference; not in `apps/`; not compiled |
| `Database/` | Old source location; rebar3 uses `apps/` |
| `graphdb/` (top-level) | Old source location; rebar3 uses `apps/` |
| `*.beam` at project root | Stale; built from old flat layout |

These do not interfere with the build. Delete or retain as historical
reference — your call.


## 5. seerstone.app.src — start_phases not defined

None of the `.app.src` files define a `start_phases` key, so `start_phase/3`
will never be called by OTP. If phased startup is desired in future,
`start_phases` must be added to the relevant `.app.src` and the
`start_phase/3` implementations filled in. Currently the callbacks return
`ok` (no-op), which is correct for the present configuration.


## Priority Order

1. **graphdb_attr** (task 1a) — foundational; all other workers depend on attribute Nrefs
2. **graphdb_class** (task 1b) — taxonomic hierarchy; needed before instances can have classes
3. **graphdb_instance** (task 1c) — core graph data; compositional hierarchy and inheritance
4. **graphdb_rules** (task 1d) — pattern recognition and rule enforcement
5. **graphdb_language** (task 1e) — query interface over the completed graph
6. **graphdb_mgr** (task 1f) — coordinator; implement last once workers have stable APIs
7. **Non-normal start/2** (task 2) — low priority, distributed deployments only
8. **code_change/3** (task 3) — low priority, hot upgrades only
9. **Old directory cleanup** (task 4) — housekeeping
