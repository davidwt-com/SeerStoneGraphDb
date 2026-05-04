# SeerStoneGraphDb

A distributed graph database written in Erlang/OTP, originally authored by
Dallas Noyes (SeerStone, Inc., 2008). Dallas passed away before completing the
project. The goal is to finish and extend his work. PRs are welcome. Treat this
codebase with care — preserve Dallas's style and conventions wherever possible
when completing NYI stubs.

### Current Status

The project compiles clean with zero warnings (OTP 27 / rebar3 3.24). The
architecture is fully designed (see `ARCHITECTURE.md`). Implementation is
underway:

| Component              | Status                                                                                                                                             |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nref` subsystem       | Fully implemented (DETS-backed ID allocator with `set_floor/1`)                                                                                    |
| `dictionary` subsystem | `dictionary_imp` implemented; server stubs not yet wired (Task 7)                                                                                  |
| `graphdb_bootstrap`    | Fully implemented — Mnesia schema/table creation, bootstrap scaffold loader (30 nodes, 29 relationship pairs)                                      |
| `graphdb_mgr`          | Implemented — bootstrap init, public read API (`get_node`, `get_relationships`), category immutability guard; write operations delegate to workers |
| `graphdb_attr`         | Fully implemented — attribute library (name, literal, relationship attributes, relationship types)                                                 |
| `graphdb_class`        | Fully implemented — taxonomic hierarchy, qualifying characteristics, class-level inheritance                                                       |
| `graphdb_instance`     | Fully implemented — compositional hierarchy, instance-to-class membership, four-level inheritance resolution                                       |
| `graphdb_rules`        | Gen_server stub — deferred to Enhancements (pattern recognition, relationship constraints)                                                         |
| `graphdb_language`     | Gen_server stub — next to implement (Task 6)                                                                                                       |

**156 tests** (62 EUnit + 94 Common Test) — all passing. See
`TASKS-CRITICAL.md`, `TASKS-HIGH.md`, `TASKS-MEDIUM.md`, and `TASKS-LOW.md`
for the prioritised task list (organised by severity).

---

## Requirements

- **Erlang/OTP 27** or later
- **rebar3** (bootstrapped automatically via `make rebar3` if not present)

---

## Quick Start

```sh
# 1. Bootstrap rebar3 if you don't have it on PATH
make rebar3

# 2. Compile all applications
make compile

# 3. Start an interactive shell with all apps loaded
make shell
```

Inside the shell, start the full system:

```erlang
application:start(nref),
application:start(database).
```

Or start just the nref subsystem and exercise it:

```erlang
application:start(nref).
nref_server:get_nref().   % => 1
nref_server:get_nref().   % => 2
```

---

## Project Structure

```
SeerStoneGraphDb/
├── apps/
│   ├── seerstone/     # Top-level OTP application and supervisor
│   ├── database/      # database application (supervises graphdb + dictionary)
│   ├── graphdb/       # Graph database application and workers
│   ├── dictionary/    # ETS/file-backed key-value dictionary application
│   └── nref/          # Globally unique node-reference ID allocator
├── rebar.config       # rebar3 umbrella build configuration
├── Makefile           # Convenience targets (compile, shell, release, clean)
├── TASKS-CRITICAL.md  # Schema-level tasks
├── TASKS-HIGH.md      # Inheritance/membership correctness bugs
├── TASKS-MEDIUM.md    # Semantic departures + query language + rules engine
├── TASKS-LOW.md       # Polish, perf, OTP plumbing, dictionary wiring
└── CLAUDE.md          # Project guide and coding conventions
```

### OTP Supervision Tree

```
seerstone (application)
  └── seerstone_sup
        └── database_sup
              ├── graphdb_sup
              │     ├── graphdb_mgr
              │     ├── graphdb_rules
              │     ├── graphdb_attr
              │     ├── graphdb_class
              │     ├── graphdb_instance
              │     └── graphdb_language
              └── dictionary_sup
                    ├── dictionary_server
                    └── term_server

nref (application — started independently)
  └── nref_sup
        ├── nref_allocator   (DETS-backed block allocator)
        └── nref_server      (serves nrefs to callers)
```

---

## Make Targets

| Target         | Description                                               |
| -------------- | --------------------------------------------------------- |
| `make compile` | Compile all applications                                  |
| `make shell`   | Start an Erlang shell with all apps on the code path      |
| `make release` | Build a self-contained production release under `_build/` |
| `make clean`   | Remove all build artifacts                                |
| `make rebar3`  | Download the rebar3 escript into the project root         |

---

## Knowledge Model

The architecture is described in [`the-knowledge-network.md`](the-knowledge-network.md),
derived from US patents 5,379,366; 5,594,837; 5,878,406 (Noyes) and Cogito knowledge
center documentation.

The foundational inversion: *knowledge is primary; documents are projections of it.*
A field report, a data table, and a research abstract are not stored artifacts —
they are different renderings of the same underlying knowledge, always consistent
because they share one source of truth.

### Two Bodies of Knowledge

| Body                         | Contents                                                                              | Scope                      |
| ---------------------------- | ------------------------------------------------------------------------------------- | -------------------------- |
| **Ontology**                 | All classes, attributes, templates, rules, and languages — the definitional knowledge | Shared across all projects |
| **Project** (instance space) | All concrete instances, their values, compositions, and connections                   | One per deployment domain  |

The same ontology can serve multiple projects across unrelated domains. All
domain-specific behavior lives in the ontology; the kernel contains none of it.

### Node Types

Every entity in the system — class, attribute, rule, template, or instance — is a
**concept node** with a stable, unique identity (an Nref).

| Type               | Where defined | Description                                                                                                                                    |
| ------------------ | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Class Node**     | Ontology      | Groups all instances sharing the same attributes; carries a class name attribute, an instance name attribute, and qualifying characteristics   |
| **Instance Node**  | Project       | Concrete member of a class — has a name, class membership, a position in the composition tree, and connections to other instances              |
| **Attribute Node** | Ontology      | Name attribute (human-readable label), relationship attribute (arc characterization), or literal attribute (raw data — numbers, strings, URLs) |

### Four Relationship Types

| Type                               | Description                                                                                                                                                                                                                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Taxonomy (IS-A)**                | Class specialisation hierarchy; multiple inheritance supported. "Golden Retriever IS-A Dog IS-A Mammal."                                                                                                                                                                              |
| **Composition (PART-OF)**          | Instance containment tree; explicit and queryable. "Nucleus PART-OF Cell PART-OF Tissue."                                                                                                                                                                                             |
| **Connection (ASSOCIATE)**         | Lateral arcs between instances — reciprocal (both directions named independently), **template-scoped** (template context permanently recorded as part of the connection's identity, preventing semantic conflation), and metadata-capable (per-arc provenance, confidence, validity). |
| **Instantiation (IS-INSTANCE-OF)** | The link from a project instance to its class(es) in the ontology. One instance may belong to multiple classes simultaneously.                                                                                                                                                        |

IS-A and PART-OF are **perpendicular** — they intersect only at the point where
an instance declares its class membership.

### Templates

A **template** is a named semantic context defined on a class in the ontology — an
active concept node, not a blank form. It determines which attributes of a class are
relevant in a given context, how they are expressed, and what connections made through
it mean. The same class may have multiple templates; each produces a different projection
of the same underlying knowledge. Because the template context is permanently recorded
as part of a connection's identity, two connections between the same pair of instances
via different templates remain semantically distinct and non-conflated.

### Inheritance

Priority order — each step applies only to attributes not yet resolved by a higher-priority step:

1. **Local values** (highest priority — override all else)
2. **Class-level bound values** (values explicitly bound at the class)
3. **Compositional ancestors** (unbroken PART-OF chain upward only)
4. **Directly connected nodes** (one level deep only; lowest priority)

### graphdb Workers

| Module             | Role                                                                                                 |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| `graphdb_attr`     | Attribute library — name attributes, literal attributes, relationship attributes, relationship types |
| `graphdb_class`    | Taxonomic hierarchy — class nodes, qualifying characteristics, class inheritance                     |
| `graphdb_instance` | Instance nodes — creation, retrieval, compositional hierarchy                                        |
| `graphdb_rules`    | Graph rules — pattern recognition and relationship constraints (deferred to Enhancements)            |
| `graphdb_language` | Query language — parsing and executing graph queries                                                 |
| `graphdb_mgr`      | Primary coordinator — routes operations across the other five workers                                |

---

## Storage

| Technology   | Used by                         | Purpose                                                                                 |
| ------------ | ------------------------------- | --------------------------------------------------------------------------------------- |
| Mnesia       | `graphdb_*` workers             | Graph node and relationship storage; `disc_copies` for RAM-speed reads with persistence |
| DETS         | `nref_allocator`, `nref_server` | Persistent disk-based term storage                                                      |
| ETS          | `dictionary_imp`                | In-memory term storage                                                                  |
| ETS tab2file | `dictionary_imp`                | Persistent serialization of ETS tables                                                  |

---

## Testing

```sh
# Run all EUnit tests (pure function tests)
./rebar3 eunit --app=graphdb

# Run all Common Test suites (integration tests with isolated Mnesia)
./rebar3 ct --suite=apps/graphdb/test/graphdb_bootstrap_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE

# Or run everything at once
./rebar3 eunit --app=graphdb && ./rebar3 ct
```

| Suite                     | Type  | Tests | Coverage                                                                   |
| ------------------------- | ----- | ----- | -------------------------------------------------------------------------- |
| `graphdb_bootstrap_tests` | EUnit | 35    | Term parsing, validation, record conversion                                |
| `graphdb_mgr_tests`       | EUnit | 9     | Direction validation, client-side arg checks                               |
| `graphdb_attr_tests`      | EUnit | 11    | Attribute type seeding, pure function checks                               |
| `graphdb_class_tests`     | EUnit | 11    | `is_valid_parent_kind/1`, `collect_qc_nrefs/2`                             |
| `graphdb_instance_tests`  | EUnit | 7     | `find_avp_value/2`                                                         |
| `graphdb_bootstrap_SUITE` | CT    | 16    | Full bootstrap load, Mnesia tables, idempotency, error handling            |
| `graphdb_mgr_SUITE`       | CT    | 19    | Bootstrap init, read ops, category guard, write stubs                      |
| `graphdb_attr_SUITE`      | CT    | 22    | Attribute create/lookup, seeding, relationship types                       |
| `graphdb_class_SUITE`     | CT    | 22    | Class create, QC, lookups, hierarchy, inheritance                          |
| `graphdb_instance_SUITE`  | CT    | 23    | Instance create, relationships, lookups, hierarchy, four-level inheritance |

Each CT test case runs in an isolated Mnesia database with a fresh nref
allocator in a private temp directory.

---

## Configuration

`config/sys.config` is used for releases and the interactive shell. It
configures both the OTP logger and the application settings:

```erlang
[
  {kernel, [
    {logger_level, info},
    {logger, [
      %% Console handler — errors and above to stdout.
      {handler, default, logger_std_h, #{...}},
      %% File handler — info and above to log/seerstone.log (rotating, 5 × 10 MB).
      {handler, file_handler, logger_std_h, #{...}}
    ]}
  ]},
  {seerstone_graph_db, [
    {app_port,       8080},
    {log_path,       "log"},
    {data_path,      "data"},
    {bootstrap_file, "apps/graphdb/priv/bootstrap.terms"}
  ]},
  {mnesia, [
    {dir, "data"}
  ]}
].
```

`apps/seerstone/priv/default.config` carries the `seerstone_graph_db` and
`mnesia` stanzas and is used as a fallback when no `sys.config` is present.

**Note:** the `log/` directory must exist before starting the system; it is
not created automatically. Create it once with `mkdir log`.

---

## Logging

Logs are written to `log/seerstone.log` (rotating, 5 × 10 MB segments).
Errors are also echoed to stdout.

### Changing the log level at runtime

No restart is required. From an Erlang shell connected to the running node:

```erlang
%% Raise or lower the global log level
logger:set_primary_config(level, debug).
logger:set_primary_config(level, info).

%% Or target a specific handler only
logger:set_handler_config(file_handler, level, debug).
logger:set_handler_config(default, level, warning).
```

Valid levels in ascending severity: `debug`, `info`, `notice`, `warning`,
`error`, `critical`, `alert`, `emergency`.

Note: runtime changes do not persist across restarts. The initial level is
controlled by `logger_level` in `config/sys.config`.

---

## Contributing

See `CLAUDE.md` for detailed coding conventions, the NYI/UEM macro pattern,
module header format, naming conventions, and the git workflow. See
`TASKS-CRITICAL.md`, `TASKS-HIGH.md`, `TASKS-MEDIUM.md`, and `TASKS-LOW.md`
for the prioritised list of remaining implementation work, organised by
severity.

Key conventions at a glance:

- Every module uses `?NYI(X)` and `?UEM(F, X)` macros for unimplemented paths
- Module names follow the pattern: `name.erl`, `name_sup.erl`, `name_server.erl`, `name_imp.erl`
- Graph nodes are identified by **Nrefs** — plain positive integers allocated by `nref_server:get_nref/0`
- See `the-knowledge-network.md` for the knowledge model behind the graphdb workers
- PRs target `main`
