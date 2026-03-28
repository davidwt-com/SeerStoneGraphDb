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
├── TASKS.md           # Inventory of remaining implementation work
└── CLAUDE.md          # This file
```

Old pre-rebar3 directories (`Database/`, `graphdb/`, `Dictionary/`, `Nref Server/`) remain
as historical design references. They are not compiled by rebar3.

## OTP Supervision Tree

```
seerstone (application)
  └── seerstone_sup (supervisor, one_for_one)
        └── database_sup (supervisor)
              ├── graphdb_sup (supervisor)
              │     ├── graphdb_mgr       (gen_server stub)
              │     ├── graphdb_rules     (gen_server stub)
              │     ├── graphdb_attr      (gen_server stub)
              │     ├── graphdb_class     (gen_server stub)
              │     ├── graphdb_instance  (gen_server stub)
              │     └── graphdb_language  (gen_server stub)
              └── dictionary_sup (supervisor)
                    ├── dictionary_server (gen_server stub)
                    └── term_server       (gen_server stub)

nref (application — started independently)
  └── nref_sup (supervisor)
        ├── nref_allocator  (DETS-backed block allocator, gen_server)
        └── nref_server     (serves nrefs to callers, gen_server)
```

`nref_include.erl` has been deleted — it was Dallas's earlier unsupervised
predecessor to `nref_server` and was fully superseded (TASKS.md item 4 — DONE).

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
`knowledge-graph-database-guide.md` (sourced from US patents 5,379,366;
5,594,837; 5,878,406 — Noyes; and Cogito knowledge center documentation).

### Core Concepts

| Concept                     | Erlang mapping                                                                                   |
|-----------------------------|--------------------------------------------------------------------------------------------------|
| **Node / Concept**          | A record identified by an Nref (positive integer)                                                |
| **Instance Node**           | Concrete entity: has a name attribute, class membership, compositional parent, and relationships |
| **Class Node**              | Type/schema: has a class name attribute, instance name attribute, and qualifying characteristics |
| **Attribute Node**          | Name or relationship descriptor in the attribute library                                         |
| **Relationship (Arc)**      | Reciprocal connection between instances; stored as `{Characterization, Value, Reciprocal}`       |
| **Reference Number (Nref)** | Globally unique `integer()` allocated by `nref_server:get_nref/0`                                |

### Hierarchy Systems

- **Taxonomic hierarchy** ("is a") — class structure managed by `graphdb_class`
- **Compositional hierarchy** ("part of") — instance structure managed by `graphdb_instance`
- These two hierarchies are **perpendicular** — they intersect only at instance-to-class membership

### Inheritance Rules

1. Instances inherit attributes (not values) from their class(es).
2. Local values on an instance override all inherited values.
3. Remaining attributes without local values inherit from: class-level bound values → compositional ancestors (unbroken chain) → directly connected nodes (one level only).

### Record Structure

Every graph record maps to:
```erlang
#{
  nref          => Nref,              %% unique positive integer
  relationships => [
    #{characterization => AttrNref,   %% ref to attribute concept
      value            => TargetNref, %% ref to target concept
      reciprocal       => AttrNref2}  %% ref to reciprocal attribute
  ]
}
```

### graphdb Worker Responsibilities

| Module             | Knowledge model role                                                                           |
|--------------------|------------------------------------------------------------------------------------------------|
| `graphdb_attr`     | Maintains the attribute library (name attributes, relationship attributes, relationship types) |
| `graphdb_class`    | Manages the taxonomic hierarchy: class nodes, qualifying characteristics, inheritance          |
| `graphdb_instance` | Creates and retrieves instance nodes; manages compositional hierarchy                          |
| `graphdb_rules`    | Stores and enforces graph rules (pattern recognition, relationship constraints)                |
| `graphdb_language` | Parses and executes graph queries against the node network                                     |
| `graphdb_mgr`      | Primary coordinator: routes operations across the other five workers                           |

## Known Incomplete Areas (NYI)

These are outstanding items — all previously known bugs have been fixed.

- **graphdb worker modules** — all six are gen_server stubs with no real implementation (`graphdb_mgr`, `graphdb_rules`, `graphdb_attr`, `graphdb_class`, `graphdb_instance`, `graphdb_language`)
- **`seerstone:start/2` and `nref:start/2`** — non-normal start types (`{takeover,Node}`, `{failover,Node}`) hit `?NYI`; only relevant in distributed/failover deployments
- **`code_change/3`** — NYI in all gen_server modules; only relevant for hot code upgrades
- **App lifecycle callbacks** — `start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` return `ok` (no-op) across all five app modules; correct for current deployment model

## TASKS.md Alignment

This guide reflects the state of the project as of `TASKS.md` generation. Key items marked as DONE in `TASKS.md` include:
- Dictionary subsystem worker modules.
- `dictionary_imp` export_all flag.
- `nref_include.erl` deleted (superseded by `nref_server`).

Remaining high-priority items include:
- Implementation of the six graphdb worker modules (see Knowledge Model section above for roles).

## Configuration

`apps/seerstone/priv/default.config`:
```erlang
[{seerstone_graph_db, [
  {app_port, 8080},
  {data_path, "data"},
  {index_path, "index"}
]}].
```

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

## Storage Technologies Used

| Technology | Used by | Purpose |
|---|---|---|
| DETS | `nref_allocator`, `nref_server` | Persistent disk-based term storage |
| ETS | `dictionary_imp` | In-memory term storage |
| ETS tab2file | `dictionary_imp` | Persistent serialization of ETS tables |
