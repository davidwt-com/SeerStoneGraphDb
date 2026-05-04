# graphdb — Graph Database OTP Application

## Purpose

`graphdb` is the core **graph database** OTP application within the SeerStone system. It is supervised by `database_sup` and itself manages graph data through `graphdb_sup` and six worker gen_servers. The data model is the knowledge graph described in `the-knowledge-network.md` (US patents 5,379,366; 5,594,837; 5,878,406 — Noyes).

## Files

| File                    | Description                                                 |
| ----------------------- | ----------------------------------------------------------- |
| `graphdb.erl`           | OTP `application` behaviour callback module                 |
| `graphdb_sup.erl`       | OTP `supervisor` behaviour callback module                  |
| `graphdb_bootstrap.erl` | Bootstrap file loader + Mnesia schema creator (implemented) |
| `graphdb_mgr.erl`       | Primary coordinator gen_server (stub)                       |
| `graphdb_rules.erl`     | Graph rules gen_server (stub)                               |
| `graphdb_attr.erl`      | Attribute library gen_server (stub)                         |
| `graphdb_class.erl`     | Taxonomic hierarchy gen_server (stub)                       |
| `graphdb_instance.erl`  | Instance/compositional hierarchy gen_server (stub)          |
| `graphdb_language.erl`  | Query language gen_server (stub)                            |

`apps/graphdb/priv/bootstrap.terms` — Erlang Terms file fully written; contains 30 nodes
(nrefs 1–30, BFS) and 29 compositional relationship pairs. Loaded at first ontology startup.

## Application Lifecycle

`graphdb` is started by calling `application:start(graphdb)` or indirectly via the `database` application supervisor. The call chain is:

```
database_sup -> graphdb_sup:start_link(StartArgs) -> graphdb_sup:init/1
```

`graphdb:start/2` delegates immediately to `graphdb_sup:start_link/1`.

## Supervisor (`graphdb_sup`)

`graphdb_sup` is a `one_for_one` supervisor for the six worker gen_servers below. All workers must be implemented before the graph database is functional.

---

## Multi-Database Architecture

Two database roles operate in parallel:

| Role                         | Content                                                                                       | Mutability                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Ontology**                 | All category, attribute, class, and language nodes; bootstrap scaffold; arc label definitions | Category nodes: immutable (bootstrap-only). All other nodes grow freely at runtime. |
| **Project (instance space)** | Instance nodes and their relationships; one per project                                       | Fully mutable at runtime                                                            |

The ontology is shared across all projects and is a **living, growing database**: new literal attributes, relationship attributes, and classes are added over time. Only category nodes (nrefs 1–5) are permanently fixed.

nref spaces:
- **Environment**: bootstrap nrefs 1–30; runtime nrefs 10000+ (floor set by `{nref_start, 10000}` directive in `bootstrap.terms`)
- **Project**: allocator starts at **1** — no pre-assigned nrefs, no bootstrap file, no floor needed

Cross-database nref resolution: `characterization` and `reciprocal` fields always reference environment nrefs; `target_nref` is routed to environment or project based on the arc label's `target_kind` AVP.

---

## Knowledge Model

The six workers collectively implement the knowledge graph model. Every node in the graph is identified by a **Nref** — a plain positive `integer()` allocated by `nref_server:get_nref/0`.

### Node Types

| Type               | Description                                                                                                                       | Creatable at runtime?   |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| **Category Node**  | Permanent top-level organisational scaffold; forms the skeleton of the entire graph (nrefs 1–5)                                   | **No — bootstrap only** |
| **Attribute Node** | Name or relationship label stored in the attribute library. Used as arc labels (`characterization`/`reciprocal`) in relationships | Yes                     |
| **Class Node**     | Type/schema. Has a class name attribute, instance name attribute, and qualifying characteristics.                                 | Yes                     |
| **Instance Node**  | Concrete entity. Has a name attribute, class membership (taxonomic parent), compositional parent ("part of"), and relationships   | Yes                     |

`category` nodes cannot be created, modified, or deleted via any runtime API. `graphdb_mgr` rejects such attempts with `{error, category_nodes_are_immutable}`.

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

All relationships are **reciprocal**. Every logical edge is stored as two directed rows in the Mnesia `relationships` table, written atomically:

```erlang
%% Example: Ford makes Taurus
%% Row 1: source=FordNref,   characterization=MakesNref,  target=TaurusNref, reciprocal=MadeByNref
%% Row 2: source=TaurusNref, characterization=MadeByNref, target=FordNref,   reciprocal=MakesNref
```

### Inheritance Rules

Priority order — each step applies only to attributes not yet resolved by a higher-priority step:

1. **Local values** (highest priority — override all else)
2. **Class-level bound values** (values explicitly bound at the class)
3. **Compositional ancestors** (unbroken chain upward only)
4. **Directly connected nodes** (one level deep only; lowest priority)

### Record Structure

Every graph node is stored as a Mnesia record:

```erlang
-record(node, {
  nref,                   %% integer() — primary key
  kind,                   %% category | attribute | class | instance
  parent,                 %% integer() | undefined  (undefined = root node only)
  attribute_value_pairs   %% [#{attribute => AttrNref, value => term()}]
}).
```

Secondary index on `parent` enables efficient `children/1` queries.

Relationships are stored in a separate Mnesia table (not embedded in node records):

```erlang
-record(relationship, {
  id,               %% integer() — primary key (nref allocated normally)
  source_nref,      %% integer() — arc origin
  characterization, %% integer() — arc label (an attribute nref from environment)
  target_nref,      %% integer() — arc target (environment or project per target_kind)
  reciprocal,       %% integer() — arc label as seen from target back (environment nref)
  avps              %% [#{attribute => AttrNref, value => term()}] — per-direction metadata
}).
```

Secondary indexes on `source_nref` and `target_nref` make forward and reverse traversal O(1).

A logical bidirectional edge is two `relationship` rows written atomically (one per direction).

---

## Bootstrap Nref Quick-Reference (BFS, nrefs 1–30)

```
 1  Root (category)
 2  ├── Attributes (category)
 3  ├── Classes (category)
 4  ├── Languages (category)
 5  └── Projects (category)
 6      Names (attribute, parent: 2)
 7      Literals (attribute, parent: 2)
 8      Relationships (attribute, parent: 2)
 9      Category Name Attributes (attribute, parent: 6)
10      Attribute Name Attributes (attribute, parent: 6)
11      Class Name Attributes (attribute, parent: 6)
12      Instance Name Attributes (attribute, parent: 6)
13      Category Relationships (attribute, parent: 8)
14      Attribute Relationships (attribute, parent: 8)
15      Class Relationships (attribute, parent: 8)
16      Instance Relationships (attribute, parent: 8)
17      Name — NameAttrNref for category nodes (parent: 9)
18      Name — NameAttrNref for attribute nodes (parent: 10, self-ref)
19      Name — NameAttrNref for class nodes (parent: 11)
20      Name — NameAttrNref for instance nodes (parent: 12)
21      Parent — category compositional arc label (parent: 13)
22      Child  — category compositional arc label (parent: 13)
23      Parent — attribute compositional arc label (parent: 14, self-ref)
24      Child  — attribute compositional arc label (parent: 14, self-ref)
25      Parent — class compositional arc label (parent: 15)
26      Child  — class compositional arc label (parent: 15)
27      Parent — instance compositional arc label (parent: 16)
28      Child  — instance compositional arc label (parent: 16)
29      Class  — instance→class membership arc (parent: 16)
30      Instance — class→instances membership arc (parent: 16)
```

NameAttrNref quick-reference: category=17, attribute=18, class=19, instance=20

Instance-to-class membership arcs are written in the **project** database, not the environment:
- characterization=29 (Class): instance→class direction
- characterization=30 (Instance): class→instance direction

---

## Worker Responsibilities

### `graphdb_bootstrap` — Bootstrap Loader (new module)

Loaded by `graphdb_mgr:init/1` when the Mnesia `nodes` table is empty (first startup).

- Creates the Mnesia schema and tables (`nodes`, `relationships`)
- Reads `bootstrap_file` path from `application:get_env(seerstone_graph_db, bootstrap_file)`
- Calls `file:consult/1` on the bootstrap file; validates all terms
- Calls `nref_server:set_floor(10000)` first, then writes nodes and relationship pairs
- Public API: `graphdb_bootstrap:load() -> ok | {error, Reason}`

### `graphdb_attr` — Attribute Library

Maintains all named attribute concepts used as arc labels. All attribute nodes live in
the ontology `nodes` Mnesia table with `kind = attribute`.

- `create_name_attribute/1` (name)
- `create_literal_attribute/2` (name, type)
- `create_relationship_attribute/3` (name, reciprocal_name, target_kind) — `target_kind :: category | attribute | class | instance` is mandatory; stored as an AVP on the arc label node and used by the query engine to route target lookups to the correct database
- `create_relationship_type/1`
- `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`
- At bootstrap: seeds the `target_kind` literal attribute into the `Literals` subtree (nref 7) and the `relationship_avp` flag attribute

### `graphdb_class` — Taxonomic Hierarchy

Manages the "is a" hierarchy of class nodes in the ontology.

- `create_class/2` (name, parent_class_nref)
- `add_qualifying_characteristic/2` (class_nref, attribute_nref)
- `get_class/1`, `subclasses/1`, `ancestors/1`, `inherited_attributes/1`

### `graphdb_instance` — Instance & Compositional Hierarchy

Creates and manages instance nodes in the project (instance space).

- `create_instance/3` (name, class_nref, compositional_parent_nref) — atomically writes the node record AND the instance→class membership relationship pair (arc labels nref=29 and nref=30)
- `add_relationship/4` (source_nref, characterization_nref, target_nref, reciprocal_nref) — writes two directed rows atomically; IDs allocated via `get_nref()`
- `get_instance/1`, `children/1`, `compositional_ancestors/1`, `resolve_value/2`

### `graphdb_rules` — Graph Rules

Stores and enforces graph rules; enables pattern recognition.

- `create_rule/2`, `check_rule/2`, `suggest_relationships/1`

### `graphdb_language` — Query Language

Parses and executes graph queries.

- `parse_query/1`, `execute_query/1`, `find_path/3`

### `graphdb_mgr` — Primary Coordinator

Single public entry point; delegates to the five specialized workers.

- In `init/1`: checks if `nodes` table is empty; if so, calls `graphdb_bootstrap:load/0`
- Rejects any runtime request to create, modify, or delete a `category` node with `{error, category_nodes_are_immutable}`
- Sequences Nref allocation → record write → Nref confirmation

---

## NYI Status

The following callbacks in `graphdb.erl` return `ok` (no-op stubs correct for current deployment):

- `start_phase/3` — phased startup (only needed if `start_phases` key added to `.app`)
- `prep_stop/1` — pre-shutdown cleanup
- `stop/1` — post-shutdown cleanup
- `config_change/3` — runtime config change notification

All six worker modules (`graphdb_mgr`, `graphdb_rules`, `graphdb_attr`, `graphdb_class`,
`graphdb_instance`, `graphdb_language`) are empty gen_server stubs.
`graphdb_bootstrap.erl` is fully implemented (Task 1 — done).

## Key Design Notes

- `graphdb_sup` receives `StartArgs` from `database:start/2`, unlike `seerstone_sup` which takes no args
- `graphdb_bootstrap`, `graphdb_mgr` (startup + read API), `graphdb_attr`, `graphdb_class`, and `graphdb_instance` are implemented. Remaining work is grouped by severity in `TASKS-CRITICAL.md`, `TASKS-HIGH.md`, `TASKS-MEDIUM.md`, and `TASKS-LOW.md` at the project root.
- Consult `the-knowledge-network.md` for the full model spec before implementing

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/graphdb/src/graphdb_sup.erl apps/graphdb/src/graphdb.erl
```

## Remaining Work

`graphdb_bootstrap.erl` is implemented; `graphdb_mgr`, `graphdb_attr`,
`graphdb_class`, and `graphdb_instance` are implemented. Outstanding work
(template support, multi-inheritance, query language, rules engine, etc.)
is grouped by severity in `TASKS-CRITICAL.md`, `TASKS-HIGH.md`,
`TASKS-MEDIUM.md`, and `TASKS-LOW.md` at the project root.
