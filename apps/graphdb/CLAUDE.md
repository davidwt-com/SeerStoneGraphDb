# graphdb — Graph Database OTP Application

## Purpose

`graphdb` is the core **graph database** OTP application within the SeerStone system. It is supervised by `database_sup` and itself manages graph data through `graphdb_sup` and six worker gen_servers. The data model is the knowledge graph described in `knowledge-graph-database-guide.md` (US patents 5,379,366; 5,594,837; 5,878,406 — Noyes).

## Files

| File                   | Description                                        |
|------------------------|----------------------------------------------------|
| `graphdb.erl`          | OTP `application` behaviour callback module        |
| `graphdb_sup.erl`      | OTP `supervisor` behaviour callback module         |
| `graphdb_mgr.erl`      | Primary coordinator gen_server (stub)              |
| `graphdb_rules.erl`    | Graph rules gen_server (stub)                      |
| `graphdb_attr.erl`     | Attribute library gen_server (stub)                |
| `graphdb_class.erl`    | Taxonomic hierarchy gen_server (stub)              |
| `graphdb_instance.erl` | Instance/compositional hierarchy gen_server (stub) |
| `graphdb_language.erl` | Query language gen_server (stub)                   |

## Application Lifecycle

`graphdb` is started by calling `application:start(graphdb)` or indirectly via the `database` application supervisor. The call chain is:

```
database_sup -> graphdb_sup:start_link(StartArgs) -> graphdb_sup:init/1
```

`graphdb:start/2` delegates immediately to `graphdb_sup:start_link/1`.

## Supervisor (`graphdb_sup`)

`graphdb_sup` is a `one_for_one` supervisor for the six worker gen_servers below. All workers must be implemented before the graph database is functional.

---

## Knowledge Model

The six workers collectively implement the knowledge graph model. Every node in the graph is identified by a **Nref** — a plain positive `integer()` allocated by `nref_server:get_nref/0`.

### Node Types

| Type               | Description                                                                                                                                                          |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Instance Node**  | Concrete entity. Has a name attribute, class membership (taxonomic parent), compositional parent ("part of"), and relationships to other instances.                  |
| **Class Node**     | Type/schema. Has a class name attribute (distinguishes sibling classes), an instance name attribute (names instances of this class), and qualifying characteristics. |
| **Attribute Node** | Name or relationship label stored in the attribute library. Used as characterizations (arc labels) in relationships.                                                 |

**Class vs Instance test:** `"X is a [concept]"` must make sense.
- "Blue is a color" → Blue is a subclass/instance of color ✓
- "Color is a blue" → Invalid → Color is NOT a subclass of blue ✗

### Hierarchy Systems

```
Taxonomic ("is a")        Compositional ("part of")
  Animal                    Car
  └── Mammal                ├── Engine
      └── Whale             │   └── Cylinder Block
                            └── Wheels
```

These hierarchies are **perpendicular**: the taxonomic hierarchy organizes classes; the compositional hierarchy organizes instances. They intersect only at instance-to-class membership.

### Relationship Structure

All relationships are **reciprocal**. Every arc is stored as:
```erlang
#{characterization => AttrNref,   %% ref to attribute concept (the label)
  value            => TargetNref, %% ref to target concept
  reciprocal       => AttrNref2}  %% ref to reciprocal attribute on target
```

Example:
- Ford → `{makes, TaurusNref, made_by}` → Taurus
- Taurus → `{made_by, FordNref, makes}` → Ford

### Inheritance Rules

Priority order — each step applies only to attributes not yet resolved by a higher-priority step:

1. **Local values** (highest priority — override all else)
2. **Class-level bound values** (values explicitly bound at the class)
3. **Compositional ancestors** (unbroken chain upward only)
4. **Directly connected nodes** (one level deep only; lowest priority)

### Record Structure

```erlang
{
  nref          => Nref,              %% unique positive integer
  relationships => [
    #{characterization => AttrNref,
      value            => TargetNref,
      reciprocal       => AttrNref2}
  ]
}
```

---

## Worker Responsibilities

### `graphdb_attr` — Attribute Library

Maintains all named attribute concepts used as arc labels.

- Name attributes: class name attributes, instance name attributes
- Literal attributes: scalar/external values stored directly on a node (numbers, strings, URLs, filenames) — not graph nodes; no Nref; do not participate in relationships
- Relationship attributes: grouped into relationship types (e.g., `location_of` / `located_in`)
- API to implement: `create_name_attribute/1`, `create_relationship_attribute/2`,
  `create_relationship_type/1`, `get_attribute/1`, `list_relationship_types/0`

### `graphdb_class` — Taxonomic Hierarchy

Manages the "is a" hierarchy of class nodes.

- Each class has: class name attr Nref, instance name attr Nref, qualifying characteristics
- Child class inherits all parent attributes/values and adds distinguishing qualifiers
- API to implement: `create_class/2`, `add_qualifying_characteristic/2`,
  `get_class/1`, `subclasses/1`, `ancestors/1`, `inherited_attributes/1`

### `graphdb_instance` — Instance & Compositional Hierarchy

Creates and manages instance nodes and the "part of" hierarchy.

- Each instance has: name attr Nref, class Nref, compositional parent Nref, relationships list
- Implements full inheritance resolution (`resolve_value/2`)
- API to implement: `create_instance/3`, `add_relationship/4`,
  `get_instance/1`, `children/1`, `compositional_ancestors/1`, `resolve_value/2`

### `graphdb_rules` — Graph Rules

Stores and enforces graph rules; enables pattern recognition.

- Rules express recurring relationship patterns (e.g., "tanks typically have pressure gauges")
- API to implement: `create_rule/2`, `check_rule/2`, `suggest_relationships/1`

### `graphdb_language` — Query Language

Parses and executes graph queries.

- Minimum query capability: find by class, find by attribute value, traverse relationships
- API to implement: `parse_query/1`, `execute_query/1`, `find_path/3`

### `graphdb_mgr` — Primary Coordinator

Single public entry point; delegates to the five specialized workers.

- Sequences Nref allocation → record write → Nref confirmation
- API to implement: mirrors the combined APIs of the five workers above

---

## NYI Status

The following callbacks in `graphdb.erl` are stubs that call `?NYI(...)` and must be implemented:

- `start_phase/3` — phased startup (only needed if `start_phases` key added to `.app`)
- `prep_stop/1` — pre-shutdown cleanup
- `stop/1` — post-shutdown cleanup
- `config_change/3` — runtime config change notification

All six worker modules (`graphdb_mgr`, `graphdb_rules`, `graphdb_attr`, `graphdb_class`,
`graphdb_instance`, `graphdb_language`) are empty gen_server stubs. See `TASKS.md` task 3
for the detailed sub-task breakdown.

## Key Design Notes

- `graphdb_sup` receives `StartArgs` from `database:start/2`, unlike `seerstone_sup` which takes no args
- The UEM macro in `graphdb:start/2` catches unexpected return values from `graphdb_sup:start_link/1`
- Implement workers in dependency order: `graphdb_attr` → `graphdb_class` → `graphdb_instance` → `graphdb_rules` → `graphdb_language` → `graphdb_mgr`
- Consult `knowledge-graph-database-guide.md` for the full model spec before implementing

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/graphdb/src/graphdb_sup.erl apps/graphdb/src/graphdb.erl
```

## TASKS.md Alignment

Key items marked as DONE in `TASKS.md`:
- Dictionary subsystem worker modules.
- `dictionary_imp` export_all flag.
- `nref_include.erl` deleted (superseded by `nref_server`).

Remaining high-priority items:
- Implementation of the six graphdb worker modules (tasks 3a–3f).
