<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# OpenWolf

@.wolf/OPENWOLF.md

This project uses OpenWolf for context management. Read and follow .wolf/OPENWOLF.md every session. Check .wolf/cerebrum.md before generating code. Check .wolf/anatomy.md before reading files.


# SeerStoneGraphDb — Project Guide

## Project Background

This is a **distributed graph database** written in Erlang, originally authored by Dallas Noyes (SeerStone, Inc., 2008). Dallas passed away before completing the project. The goal is to finish and extend his work. PRs are welcome. Treat this codebase with care — preserve Dallas's style and conventions wherever possible when completing NYI stubs.

## Language & Runtime

- **Erlang/OTP 27** or later
- **rebar3 3.24** — build tool (`make rebar3` bootstraps it if not on PATH)
- Compile: `make compile` or `rebar3 compile`
- Start an interactive shell: `make shell`
- Start the full system from the shell: `application:start(nref), application:start(database).`

## Directory Structure

```
SeerStoneGraphDb/
├── apps/
│   ├── seerstone/     # Top-level OTP application and supervisor
│   ├── database/      # database application (supervises graphdb + dictionary)
│   ├── graphdb/       # Graph database application and worker stubs
│   ├── dictionary/    # ETS/file-backed key-value dictionary application
│   └── nref/          # Globally unique node-reference ID allocator
├── .github/workflows/
│   └── ci.yml         # GitHub Actions CI (OTP 27, rebar3 3.24, ubuntu-latest)
├── rebar.config       # rebar3 umbrella build configuration
├── rebar.lock         # Locked dependency versions
├── Makefile           # Convenience targets (compile, shell, release, clean, rebar3)
├── ARCHITECTURE.md    # High-level architecture; kept current with the code
└── CLAUDE.md          # This file
```

## OTP Supervision Tree

`nref`, `graphdb`, `dictionary`, `database`, and `seerstone` are peer OTP
applications started by `application_master` in dependency order.

```
nref (application — started first)
  └── nref_sup (supervisor)
        ├── nref_allocator  (DETS-backed block allocator, gen_server — fully implemented)
        └── nref_server     (serves nrefs to callers, gen_server — fully implemented)

graphdb (application — started after mnesia + nref)
  └── graphdb_sup (supervisor)
        ├── graphdb_nref      (gen_server — switchable node-nref allocation facade;
        │                      permanent phase during init, runtime phase after flip)
        ├── rel_id_server     (gen_server — arc row ID allocator)
        ├── graphdb_mgr       (gen_server — implemented: bootstrap init, read API, category guard)
        ├── graphdb_attr      (gen_server — implemented: seeds + create/lookup API)
        ├── graphdb_class     (gen_server — implemented: taxonomic hierarchy, QC inheritance)
        ├── graphdb_instance  (gen_server — implemented: compositional hierarchy, inheritance)
        ├── graphdb_language  (gen_server — implemented: M6 multilingual overlay)
        ├── graphdb_query     (gen_server — implemented: F3 query language)
        └── graphdb_rules     (gen_server — implemented: F4 Phase A rule meta-ontology + create/retrieve)

dictionary (application — started alongside graphdb)
  └── dictionary_sup (supervisor)
        ├── dictionary_server (gen_server — stub, not yet wired to dictionary_imp)
        └── term_server       (gen_server — stub, not yet wired to dictionary_imp)

database (application — started after graphdb + dictionary)
  └── database_sup (supervisor) — empty; attachment point for future database-level services

seerstone (application — top-level; started last)
  └── seerstone_sup (supervisor) — empty; placeholder for future seerstone-specific workers
```

`nref_include.erl` has been deleted — it was Dallas's earlier unsupervised
predecessor to `nref_server` and is fully superseded by it.

`graphdb_bootstrap.erl` — implemented; loaded by `graphdb_mgr:init/1`
on first startup when the Mnesia `nodes` table is empty. The loader uses a
local counter for permanent-tier labels (`?LABEL_START`..`?NREF_START-1`) and
does **not** call `set_floor` — the `graphdb:start/2` phase flip raises the
runtime floor after all child `init/1`s complete.

## Common Coding Conventions

### NYI / UEM Macros (in every module)
```erlang
-define(NYI(X), (begin
    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
    exit(nyi)
end)).
-define(UEM(F, X), (begin
    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
    exit(uem)
end)).
```
- `?NYI(X)` — marks **Not Yet Implemented** functions; exits with `nyi`
- `?UEM(F, X)` — marks **UnExpected Message** handlers; exits with `uem`
- These macros are copy-pasted into every module (sourced from Joe Armstrong's *Programming Erlang*, p. 424)

### Module File Header Pattern
Every source file starts with:
1. Copyright block (SeerStone, Inc. 2008)
2. Author, Created date, Description
3. Revision history (Rev PA1, Rev A)
4. `-module(name).` and `-behaviour(application|supervisor|gen_server).`
5. Module attributes: `-revision(...)`, `-created(...)`, `-created_by(...)`
6. NYI/UEM macro definitions
7. `-export([...]).` — explicit export list (never `-compile(export_all)`)

Maintain this structure when adding new modules.

### Naming Conventions
- Application module: `name.erl` (e.g., `graphdb.erl`)
- Supervisor module: `name_sup.erl` (e.g., `graphdb_sup.erl`)
- Worker/server: `name_server.erl` or `name_worker.erl`
- Implementation module: `name_imp.erl` (e.g., `dictionary_imp.erl`)
- Include/header data: `name_include.erl`

### Key Data Types
- **Nref**: plain positive `integer()`, starting at 1. No wrapper type. Allocated by `nref_server:get_nref/0`.

## Knowledge Model

This database is an implementation of the knowledge graph model described in
`the-knowledge-network.md` (sourced from US patents 5,379,366;
5,594,837; 5,878,406 — Noyes; and Cogito knowledge center documentation).

### Core Concepts

| Concept                     | Erlang mapping                                                                                                                                               |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Node / Concept**          | A record identified by an Nref (positive integer); `kind` is one of `category \| attribute \| class \| instance \| template`                                 |
| **Category Node**           | Permanent top-level organisational scaffold; forms the skeleton of the entire graph; **bootstrap-only** — cannot be created, modified, or deleted at runtime |
| **Instance Node**           | Concrete entity: has a name attribute, class membership, compositional parent, and relationships                                                             |
| **Class Node**              | Type/schema: has a class name attribute, instance name attribute, and qualifying characteristics                                                             |
| **Attribute Node**          | Name attribute, relationship attribute, or literal attribute stored in the attribute library                                                                 |
| **Relationship (Arc)**      | Reciprocal connection between nodes; stored as two directed rows in the `relationships` Mnesia table                                                         |
| **Reference Number (Nref)** | Globally unique `integer()` allocated by `nref_server:get_nref/0`; bootstrap nrefs are pre-assigned (all `< nref_start`)                                     |

### Multi-Database Architecture

Two database roles:

| Role                         | Content                                                                                       | Mutability                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Ontology**                 | All category, attribute, class, and language nodes; bootstrap scaffold; arc label definitions | Category nodes: immutable (bootstrap-only). All other nodes grow freely at runtime. |
| **Project (instance space)** | Instance nodes and their relationships; one database per project                              | Fully mutable at runtime                                                            |

The environment is shared across all projects. Only bootstrap nrefs (1–35) and a small number of explicitly seeded runtime nrefs (e.g., `target_kind`) are referenced by nref constant in code — all other runtime-added nodes are treated generically.

nref spaces:
- **Environment**: scaffold nrefs 1–35; permanent tier `[?LABEL_START, ?NREF_START)` = `[10001, 1000000)` holds English (10000), loader-assigned atom-labeled bootstrap nodes, and worker `init/1` seeds (graphdb_attr, graphdb_language sub-groups); runtime allocations ≥ `?NREF_START` (1000000). Boundaries are macros in `apps/graphdb/include/graphdb_nrefs.hrl` — **not** directives in `bootstrap.terms`. All graphdb node-nref allocation goes through `graphdb_nref` (first child of `graphdb_sup`): permanent phase during init, runtime phase after the `graphdb:start/2` flip.
- **Project**: allocator starts at **1** — no pre-assigned nrefs, no bootstrap file, no floor needed

Cross-database nref resolution: `characterization` and `reciprocal` fields always reference environment nrefs; `target_nref` is routed to environment or project based on the arc label's `target_kind` AVP stored in the environment attribute library.

### Bootstrap Nref Quick-Reference (BFS, nrefs 1–35)

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

Hierarchy arc labels (`{relationship, ParentNref, ChildArcNref, [], ParentArcNref, ChildNref, []}`):
- category child: ChildArc=22, ParentArc=21 — `kind=composition` (organisational scaffold)
- attribute child: ChildArc=24, ParentArc=23 — `kind=taxonomy` (refinement of kind)
- class child: ChildArc=26, ParentArc=25 — `kind=taxonomy` (subclass) or `composition` (template)
- instance child: ChildArc=28, ParentArc=27 — `kind=composition` (part-whole)

Instance-to-class membership arcs: characterization=29 (Class) instance→class; characterization=30 (Instance) class→instance. Written in the **project** database, not the environment.

### Hierarchy Systems

- **Taxonomic hierarchy** ("is a") — class structure managed by `graphdb_class`
- **Compositional hierarchy** ("part of") — instance structure managed by `graphdb_instance`
- These two hierarchies are **perpendicular** — they intersect only at instance-to-class membership

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
  nref,                   %% integer() — unique positive integer; primary key
  kind,                   %% category | attribute | class | instance | template
  parents = [],           %% [integer()] cache of parent arcs (composition/taxonomy)
  classes = [],           %% [integer()] cache of instantiation arcs (instances only)
  attribute_value_pairs   %% [#{attribute => AttrNref, value => Value}]
}).
```

Relationships are stored in a separate Mnesia table (not embedded in the node record):
```erlang
-record(relationship, {
  id,               %% integer() — primary key (nref allocated normally)
  kind,             %% taxonomy | composition | connection | instantiation
  source_nref,      %% integer() — arc origin
  characterization, %% integer() — arc label (an attribute nref)
  target_nref,      %% integer() — arc target
  reciprocal,       %% integer() — arc label as seen from target back
  avps              %% [#{attribute => AttrNref, value => Value}] — per-direction metadata
}).
```

A logical bidirectional edge is two `relationship` rows written atomically (one per direction). Secondary indexes on `source_nref` and `target_nref` make forward and reverse traversal O(1).

`attribute_value_pairs` carries literal and non-topological values (e.g., name strings, measurements, URLs). The value may be any Erlang term; the attribute node holds the definition of permissible value types. These pairs do **not** participate in graph traversal.

`relationships` are graph-topology arcs. Each is a flat triple plus an optional per-arc metadata list: `characterization` is the arc label (an attribute Nref), `value` is the target concept (an Nref), `reciprocal` is the arc label as seen from the target back to this node (also an attribute Nref), and `attribute_value_pairs` is an optional list of per-direction metadata pairs (provenance, weights, flags, revisions, active time frames, etc.). The AVP list does not inherit and does not participate in graph traversal by default; a future traversal-condition mechanism may allow certain AVPs to gate or modify traversal.

### graphdb Worker Responsibilities

| Module             | Knowledge model role                                                                                                                                                                                                                                                    |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `graphdb_attr`     | Maintains the attribute library (name attributes, literal attributes, relationship attributes, relationship types); literal attributes used as relationship arc metadata are identified by carrying a `relationship_avp => true` AVP on their own attribute node record |
| `graphdb_class`    | Manages the taxonomic hierarchy: class nodes, qualifying characteristics, inheritance                                                                                                                                                                                   |
| `graphdb_instance` | Creates and retrieves instance nodes; manages compositional hierarchy                                                                                                                                                                                                   |
| `graphdb_rules`    | Stores and enforces graph rules (pattern recognition, relationship constraints)                                                                                                                                                                                         |
| `graphdb_language` | M6 multilingual overlay layer (label registration, dialect chains, per-language Mnesia overlay tables)                                                                                                                                                                  |
| `graphdb_query`    | F3 query language: parses and executes graph queries (Q1-Q6) against the node network                                                                                                                                                                                   |
| `graphdb_mgr`      | Primary coordinator: routes operations across the other six workers                                                                                                                                                                                                     |

## Known Incomplete Areas (NYI)

These are outstanding items — all previously known bugs have been fixed.

- **`graphdb_rules` rule-firing engine** — F4 Phases A, B1, B2, B3, and B4 are implemented (rule meta-ontology + create/retrieve; taxonomy walk; composition firing; propose mode; connection firing). Phase B5 (precedence) and Phases C–F remain outstanding (TASKS.md F4)
- **`graphdb_mgr` write operations** — `create_attribute/3`, `create_class/2`, `create_instance/3`, `add_relationship/4`, `delete_node/1`, `update_node_avps/2` return `{error, not_implemented}` pending L4 routing work
- **`dictionary_server` and `term_server`** — stubs not yet wired to `dictionary_imp` (TASKS.md Task 7)
- **`seerstone:start/2` and `nref:start/2`**, **`code_change/3`** — deferred (TASKS.md E2, E3)
- **App lifecycle callbacks** — `start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` return `ok` (no-op) across all five app modules; correct for current deployment model

## Remaining Work

Remaining tasks are in `TASKS.md` (feature phases F1–F4 and
Engineering Hygiene). Critical schema-level work is complete (PR #9);
high-severity inheritance/membership correctness work landed in PR
#12.

## Configuration

`apps/seerstone/priv/default.config`:
```erlang
[{seerstone_graph_db, [
  {app_port,       8080},
  {log_path,       "log"},
  {data_path,      "data"},
  {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"}
]},
 {mnesia, [
  {dir, "data"}
]}].
```

Both relative and absolute paths are accepted for `log_path`, `data_path`, and `bootstrap_file`. Relative paths resolve from the OTP release root.

## CI

GitHub Actions workflow at `.github/workflows/ci.yml`:
- Triggers on push to `main`/`develop` and PRs targeting `main`
- Runs on `ubuntu-latest`, OTP 27, rebar3 3.24
- Caches `_build/` keyed on `rebar.lock`
- Steps: checkout → setup-beam → cache → `rebar3 compile`

## Git Workflow

- Main branch: `main`
- Development branch: `develop`
- Feature work goes on `develop`; PRs target `main`

## Documentation

`ARCHITECTURE.md` must reflect the current high-level shape of the code.
Keep it current — but at architectural altitude, not implementation
detail.

**Update `ARCHITECTURE.md` when:**
- The Mnesia schema changes (record fields added/removed/renamed).
- The OTP supervision tree changes (new/removed workers, supervisor
  reorganisation).
- A worker's public API contract changes meaningfully (signatures,
  return shapes, ownership boundaries).
- A new module is added or an existing one is removed.
- An architectural decision is made or revised (storage technology,
  cross-module routing, identity/allocation strategy).

**Don't update `ARCHITECTURE.md` for:**
- Internal refactors that don't change the contract.
- Bug fixes, style changes, comment edits, test additions.
- Implementation progress within an already-described component.

`docs/diagrams/ontology-tree.md` is the visual reference for the
post-bootstrap + init-seeded environment ontology. The Mermaid block in
that file must reflect the current shape of the tree.

**Update `docs/diagrams/ontology-tree.md` when:**
- `apps/graphdb/priv/bootstrap.terms` adds, removes, or reparents a node.
- Any `init/1` in `graphdb_attr`, `graphdb_class`, `graphdb_instance`,
  or `graphdb_language` adds, removes, or reparents a runtime-seeded
  node, sub-group, or arc-label that belongs in the environment tree.
- A new `graphdb_*` worker is added that seeds at startup.

**Don't update `docs/diagrams/ontology-tree.md` for:**
- Per-test or per-project instance-DB additions (the diagram is
  environment-only).
- Internal refactors that leave the seed shape unchanged.

The canonical spec is `the-knowledge-network.md` — it does **not** track
the code. Outstanding work lives in `TASKS.md`.

## Storage Technologies Used

| Technology   | Used by                         | Purpose                                                                                 |
| ------------ | ------------------------------- | --------------------------------------------------------------------------------------- |
| Mnesia       | `graphdb_*` workers             | Graph node and relationship storage; `disc_copies` for RAM-speed reads with persistence |
| DETS         | `nref_allocator`, `nref_server` | Persistent disk-based term storage                                                      |
| ETS          | `dictionary_imp`                | In-memory term storage                                                                  |
| ETS tab2file | `dictionary_imp`                | Persistent serialization of ETS tables                                                  |
