<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# graphdb — Graph Database OTP Application

## Purpose

`graphdb` is the core **graph database** OTP application within the SeerStone system. It is a peer OTP application started by `application_master` after `mnesia` and `nref`, and manages graph data through `graphdb_sup` and six worker gen_servers. The data model is the knowledge graph described in `../../docs/TheKnowledgeNetwork.md` (US patents 5,379,366; 5,594,837; 5,878,406 — Noyes).

## Files

| File                    | Description                                                                                                                                                            |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `graphdb.erl`           | OTP `application` behaviour callback module; performs permanent→runtime phase flip                                                                                     |
| `graphdb_sup.erl`       | OTP `supervisor` behaviour callback module                                                                                                                             |
| `graphdb_nref.erl`      | Switchable node-nref allocation facade gen_server (first child; permanent during init)                                                                                 |
| `graphdb_bootstrap.erl` | Bootstrap file loader + Mnesia schema creator (implemented)                                                                                                            |
| `graphdb_mgr.erl`       | Primary coordinator gen_server (implemented — bootstrap init, read API, category guard)                                                                                |
| `graphdb_rules.erl`     | Graph rules gen_server (implemented — F4 Phase A+B1+B2+B3+B4+B5: rule meta-ontology, create/retrieve, taxonomy walk, composition firing, propose mode, connection firing, conflict precedence) |
| `graphdb_attr.erl`      | Attribute library gen_server (implemented)                                                                                                                             |
| `graphdb_class.erl`     | Taxonomic hierarchy gen_server (implemented)                                                                                                                           |
| `graphdb_instance.erl`  | Instance/compositional hierarchy gen_server (implemented)                                                                                                              |
| `graphdb_language.erl`  | M6 multilingual overlay layer (implemented)                                                                                                                            |
| `graphdb_query.erl`     | F3 query language gen_server (implemented)                                                                                                                             |

`apps/graphdb/priv/bootstrap.terms` — Erlang Terms file fully written; contains 38 nodes
(nrefs 1–35 scaffold, nref 10000 English, 2 atom-labeled nodes) and hierarchy relationship pairs. Loaded at first ontology startup. Tier boundaries are macros in `graphdb_nrefs.hrl` — no `{nref_start}` or `{label_start}` directives.

## Application Lifecycle

`graphdb` is started by `application_master` as a peer application, after
`mnesia` and `nref` are running. The call chain is:

```
application_master
  -> graphdb:start(normal, [])
    -> graphdb_nref:set_permanent_phase()   %% arm permanent-tier allocation
    -> graphdb_sup:start_link/0             %% starts all children (init/1s allocate in permanent tier)
      -> graphdb_sup:init/1
    -> graphdb_nref:set_runtime_phase()     %% flip to runtime; raises nref_server floor to ?NREF_START
```

`graphdb:start/2` brackets the supervised startup with the permanent→runtime
phase flip so the bootstrap loader and every worker `init/1` allocate in the
permanent tier `[?LABEL_START, ?NREF_START)`.

## Supervisor (`graphdb_sup`)

`graphdb_sup` is a `one_for_one` supervisor. `graphdb_nref` is the first
child (the phase must be armed before any other child starts).

---

## Multi-Database Architecture

Two database roles operate in parallel:

| Role                         | Content                                                                                       | Mutability                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Ontology**                 | All category, attribute, class, and language nodes; bootstrap scaffold; arc label definitions | Category nodes: immutable (bootstrap-only). All other nodes grow freely at runtime. |
| **Project (instance space)** | Instance nodes and their relationships; one per project                                       | Fully mutable at runtime                                                            |

The ontology is shared across all projects and is a **living, growing database**: new literal attributes, relationship attributes, and classes are added over time. Only category nodes (nrefs 1–5) are permanently fixed.

nref spaces:
- **Environment**: scaffold nrefs 1–35; permanent tier `[?LABEL_START, ?NREF_START)` = `[10001, 1000000)` holds English (10000), loader-assigned atom-labeled nodes, and worker `init/1` seeds (graphdb_attr, graphdb_language sub-groups); runtime nrefs ≥ `?NREF_START` (1000000). Boundaries are macros in `apps/graphdb/include/graphdb_nrefs.hrl` — not directives in `bootstrap.terms`. All node-nref allocation goes through `graphdb_nref`.
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
  kind,                   %% category | attribute | class | instance | template
  parents = [],           %% [integer()] cache of parent arcs (composition/taxonomy)
  classes = [],           %% [integer()] cache of instantiation arcs (instances only)
  attribute_value_pairs   %% [#{attribute => AttrNref, value => term()}]
}).
```

`parents` and `classes` are caches of the authoritative arcs in the
`relationships` table.  See `../../docs/Architecture.md` §3 for the cache invariant
and the `graphdb_mgr:verify_caches/0` / `rebuild_caches/0` audit APIs.
Downward queries ("children of X") read outgoing arcs from
`relationships` filtered by kind + characterization.

Relationships are stored in a separate Mnesia table (not embedded in node records):

```erlang
-record(relationship, {
  id,               %% integer() — primary key (nref allocated normally)
  kind,             %% taxonomy | composition | connection | instantiation
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

## Bootstrap Nref Quick-Reference (BFS, nrefs 1–35)

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
23      Parent — attribute taxonomy arc label (parent: 14, self-ref)
24      Child  — attribute taxonomy arc label (parent: 14, self-ref)
25      Parent — class compositional arc label (parent: 15)
26      Child  — class compositional arc label (parent: 15)
27      Parent — instance compositional arc label (parent: 16)
28      Child  — instance compositional arc label (parent: 16)
29      Class  — instance→class membership arc (parent: 16)
30      Instance — class→instances membership arc (parent: 16)
31      Template — Connection-arc scope AVP marker (parent: 16)
32      Human Languages  — Language subcategory (parent: 4)
33      Formal Languages  — Language subcategory (parent: 4)
34      Diagram Languages — Language subcategory (parent: 4)
35      Renderers         — Language subcategory (parent: 4)
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
- Builds a symbol table for atom-labeled nrefs using a **local counter** starting at
  `?LABEL_START` (10001); does **not** call `nref_server:set_floor` — the runtime floor
  is raised by `graphdb:start/2`'s `set_runtime_phase/0` call after all workers start
- Resolves all labels and writes nodes and relationship pairs
- Public API: `graphdb_bootstrap:load() -> ok | {error, Reason}`

### `graphdb_attr` — Attribute Library

Maintains all named attribute concepts used as arc labels. All attribute nodes live in
the ontology `nodes` Mnesia table with `kind = attribute`.

- `create_value_attribute/4` (name, attr_type, type_args, parent_nref) — canonical single-node creator; `attr_type :: name | literal | relationship`, `type_args` = `[]` for name/relationship, `[LiteralType]` for literal
- `create_name_attribute/1,2` (name [, parent_nref]) — defaults parent to nref 6 (Names)
- `create_literal_attribute/2,3` (name, type [, parent_nref]) — defaults parent to nref 7 (Literals)
- `create_relationship_type/1,2` (name [, parent_nref]) — single-node grouping; defaults parent to nref 8 (Relationships)
- `create_relationship_attribute_pair/3,4` (name, reciprocal_name, target_kind [, parent_nref]) — reciprocal arc-label pair; `target_kind :: category | attribute | class | instance`; defaults parent to nref 8
- All creators validate `parent_nref` (must be an existing `kind=attribute` node)
- `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`
- At bootstrap: seeds the `Attribute Literals` sub-group under the `Literals` subtree (nref 7), then seeds `literal_type`, `target_kind`, `relationship_avp`, `attribute_type`, and `instantiable` literal attributes as children of that sub-group. Also stamps the `relationship_avp` marker AVP on the bootstrap Template node and retro-stamps `attribute_type` AVPs across the Attributes subtree. The `instantiable` marker (L9) is stamped on a class node as `instantiable => false` to make it abstract (non-instantiable).

### `graphdb_class` — Taxonomic Hierarchy

Manages the "is a" hierarchy of class nodes in the ontology.

- `create_class/2,3` (name, parent_class_nref [, avps]) — the `/3` form prepends an initial AVP list to the class node; a class created with the `instantiable => false` marker AVP is **abstract** and is born without a default template (L9)
- `add_qualifying_characteristic/2` (class_nref, attribute_nref)
- `is_instantiable/1` (class_nref) — `false` iff the class carries the `instantiable => false` marker
- `get_class/1`, `subclasses/1`, `ancestors/1`, `inherited_qcs/1`
- `get_template_in_txn/1`, `class_in_ancestry_in_txn/2`,
  `default_template_in_txn/1` — tier-1 **in-transaction** read primitives
  (bare-mnesia twins of `get_template`/`class_in_ancestry`/`default_template`);
  must be called inside an Mnesia activity. They compose into a caller's single
  transaction (the seam's tier-1 contract) and are the prerequisite for atomic
  `add_relationship` / `mutate/1`. See
  `docs/designs/atomic-add-relationship-primitives-design.md`.

### `graphdb_instance` — Instance & Compositional Hierarchy

Creates and manages instance nodes in the project (instance space).

- `create_instance/3,4,5` (name, class_nref, compositional_parent_nref [, connection_resolver [, conflict_resolver]]) — atomically writes the node record AND the instance→class membership relationship pair (arc labels nref=29 and nref=30), then fires composition rules (F4 B2). Returns `{ok, Nref, Report}` on success or `{error, Reason, Report}` on rule-firing failure; pre-plan validation errors (unknown class, non-instantiable class, etc.) return `{error, Reason}` (2-tuple). Rejects a class marked non-instantiable with `{error, {class_not_instantiable, ClassNref}}` (L9). Propose-mode composition rules surface as `proposed` outcomes in the report (B3); nothing is materialised for them. `/4` threads a connection **resolver** (`fun((ConnContext) -> {connect, [Target]} | defer end`): the RESOLVE step fires effective ConnectionRules (F4 B4) — `mandatory` connections to existing targets land in the root transaction, `auto` post-commit, `defer`/`propose` are reported only; targets are validated (exists, instance, instance-of target_class-or-subclass). `/3` uses the built-in `report_only` (defer-all) connection resolver, so connection rules surface as `required`/`not_connected`/`proposed` outcomes and nothing is connected. `/5` threads a B5 **conflict resolver** (`fun((#{kind, rules, class_nref}) -> [Pair])`); `/3` and `/4` inject the built-in `graphdb_rules:default_conflict_resolver/0`, which shadows conflicting inherited rules (nearest-level winner by mode priority), merges multiplicity (nearest Min, greatest Max), and demotes both-real-template losers to `propose` (F4 B5).
- `add_relationship/4` (source_nref, characterization_nref, target_nref, reciprocal_nref) — writes two directed rows atomically; IDs allocated via `get_nref()`
- `add_class_membership/2` (instance_nref, class_nref) — adds a membership arc pair; also rejects a non-instantiable class target with `{error, {class_not_instantiable, ClassNref}}` (L9)
- `get_instance/1`, `children/1`, `compositional_ancestors/1`, `resolve_value/2`

### `graphdb_rules` — Graph Rules (F4 Phase A + B1 + B2 + B3 + B4 + B5)

Stores composition and connection rules as instances of a seeded rule
meta-ontology. Phases A, B1, B2, B3, B4, and B5 are implemented; Phases C–F
are tracked in `TASKS.md`.

- `create_composition_rule/6,7,8` (scope, name, parent_class, child_class, mode, multiplicity [, template_nref] [, opts]); `multiplicity :: {Min, Max}` where `Min :: non_neg_integer()`, `Max :: pos_integer() | unbounded` (`unbounded` legal only as `Max`); `opts #{name_pattern => string()}` sets the naming pattern for auto-named child instances
- `create_connection_rule/8,9` (scope, name, source_class, characterization, **reciprocal**, target_class, mode, multiplicity [, template_nref]); same `{Min, Max}` multiplicity shape. The `reciprocal` arg (B4-D3) is the reverse arc label, stored as a `reciprocal_nref` content AVP; it supersedes the Phase A `/7,/8` forms (no reciprocal)
- `get_rule/2`, `rules_for_class/2`, `composition_rules_for_class/2`, `connection_rules_for_class/2`, `list_rules/1`
- `effective_rules_for_class/2` (F4 B1) — taxonomy-walking read:
  every rule attached to a class **and its taxonomy ancestors**, grouped by
  attaching class nearest-first, each paired with its `applies_to`-arc
  deployment (`mode`/`multiplicity`/`template`). Resolves nothing; the B2+
  firing engines consume it.
- `effective_connection_rules/2` (F4 B4) — the connection-filtered companion:
  the effective rules of a class restricted to the ConnectionRule meta-class,
  each paired with its deployment and a content spec
  `#{characterization, reciprocal, target_class}`. Consumed by the connection
  firing engine in `graphdb_instance`.
- `plan_composition_firing/2,3` (scope, class_nref [, conflict_resolver]) —
  pure-read; returns an abstract plan tree (maps, no nrefs) consumed by
  `graphdb_instance` during `create_instance/3` and reused by B3 propose mode.
  The `/3` form applies a B5 conflict resolver at each cascade level; `/2` is
  the additive identity path (no resolution) that preserves the B1 read
  contract.
- `default_conflict_resolver/0` (F4 B5) — builds the default conflict-resolver
  closure (reading the seed nrefs once, in the caller's process). The closure
  dispatches on a `#{kind, rules, class_nref}` context: composition conflicts
  group by referenced child class, connection conflicts by characterization +
  referenced target class; within a group the nearest-level member wins by mode
  priority (mandatory > auto > propose), surviving Min is the winner's, Max is
  the greatest across winner + dropped losers, and both-real-template losers are
  demoted to `propose`. Deadlock-safe in either gen_server (touches only
  in-memory `#node` AVPs, dirty `relationships` reads, and `graphdb_class`).
- `rule_child_class/1`, `rule_child_name/4`
- `seeded_nrefs/0`
- The `applies_to` arc's `multiplicity` deployment AVP stores the `{Min, Max}` tuple. Creation firing mints `Min` children/connections; `Max` is the ceiling for a future interactive-creation session. Propose-mode rules surface `Min` `proposed` outcomes, each carrying `max => Max` (B-prep / `docs/designs/f4-bprep-multiplicity-range-design.md`).
- At bootstrap: seeds the `Rule Literals` sub-group under the `Literals`
  subtree (nref 7) with 8 literal attributes (`child_class_nref`,
  `target_class_nref`, `template_nref`, `characterization_nref`,
  `reciprocal_nref` (B4), `mode`, `multiplicity`, `name_pattern`), the
  `applies_to`/`applied_by`
  relationship-attribute pair under Instance Relationships (nref 16), and
  the `Rule` (abstract) → `CompositionRule` / `ConnectionRule` meta-class
  chain under Classes (nref 3). `graphdb_rules` is the last child of
  `graphdb_sup` so the attribute and class workers are available when its
  `init/1` seeds.

### `graphdb_language` — Multilingual Overlay Layer (M6)

Manages multilingual labels: language registration, dialect chains,
per-language Mnesia overlay tables, label resolution, and async
translation hooks.

- `register_language/2`, `register_dialect/3`,
  `lookup_language_nref/1`
- `set_labels/3`, `resolve_label/4`, `make_chain/1`
- `project_language/1`, `register_translation_hook/1`,
  `unregister_translation_hook/1`, `fire_translation_hooks/2`
- At bootstrap: seeds the `Language Literals` sub-group under the
  `Literals` subtree (nref 7), then seeds `base_language` and
  `project_language` literal attributes as children of that sub-group.
  English concept node (nref 10000) seeded under Human Languages
  (nref 32).

### `graphdb_query` — Query Language (F3)

Parses and executes graph queries. Public API:

- `parse_query/1` — identity until a text DSL lands
- `new_session/0`, `refresh/1` — snapshot-semantics session lifecycle
- `execute_query/1`, `execute_query/2` — ephemeral and session-threaded
- `resume/2` — continue a `#cont_path{}` (returns
  `{error, snapshot_expired}` if the session has been refreshed since)
- `find_path/3` — convenience wrapper for `#q_find_path{}`

Queries are represented as records defined in
`apps/graphdb/include/graphdb_query.hrl`. Every Mnesia read goes
through `session_read_node/2` or `session_read_arcs/4`; direct
`mnesia:dirty_*` calls outside those helpers are a code smell.

See `docs/designs/f3-graphdb-query-design.md` for the architectural contract.

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

There are no remaining empty gen_server stubs. `graphdb_bootstrap`,
`graphdb_mgr`, `graphdb_attr`, `graphdb_class`, `graphdb_instance`,
`graphdb_language` (M6), `graphdb_query` (F3), and `graphdb_rules`
(F4 Phases A + B1 + B2 + B3 + B4 + B5) are all implemented. The `graphdb_rules`
firing engine Phases C–F remain, tracked in `TASKS.md`.

## Key Design Notes

- `graphdb_sup:start_link/0` takes no args, matching every supervisor in the umbrella. It is called from `graphdb:start/2` after `graphdb_nref:set_permanent_phase/0` arms the permanent-tier allocator. `graphdb:start/2` then calls `graphdb_nref:set_runtime_phase/0` after `start_link` returns.
- `graphdb_bootstrap`, `graphdb_mgr` (startup + read API), `graphdb_attr`, `graphdb_class`, `graphdb_instance`, `graphdb_language`, `graphdb_query`, and `graphdb_rules` (F4 A+B1+B2+B3+B4+B5) are implemented. Remaining work is in `TASKS.md` at the project root.
- Consult `../../docs/TheKnowledgeNetwork.md` for the full model spec before implementing

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/graphdb/src/graphdb_sup.erl apps/graphdb/src/graphdb.erl
```

## Remaining Work

`graphdb_bootstrap.erl` is implemented; `graphdb_mgr`, `graphdb_attr`,
`graphdb_class`, `graphdb_instance`, `graphdb_language`, `graphdb_query`,
and `graphdb_rules` (F4 A+B1+B2+B3+B4+B5) are implemented. Outstanding work
(rules engine Phases C–F, etc.) is in `TASKS.md` at the project root.
