<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb

A distributed graph database written in Erlang/OTP (the Open Telecom
Platform), originally authored by Dallas Noyes (SeerStone, Inc., 2008).
Dallas passed away before completing the project. The goal is to finish
and extend his work. PRs are welcome.

### Current Status

The project compiles clean with zero warnings (OTP 27 / rebar3 3.24). The
architecture is fully designed (see [`docs/Architecture.md`](docs/Architecture.md)).
Implementation is underway:

| Component              | Status                                                                                                                                                                                                                                                                                                                     |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nref` subsystem       | Fully implemented (DETS — Disk-based Erlang Term Storage — backed ID allocator with `set_floor/1`)                                                                                                                                                                                                                         |
| `dictionary` subsystem | `dictionary_imp` implemented; `dictionary_server` / `term_server` wired to it                                                                                                                                                                                                                                              |
| `graphdb_bootstrap`    | Fully implemented — Mnesia (Erlang's built-in distributed database) schema/table creation, bootstrap scaffold loader (38 nodes, 38 relationship pairs)                                                                                                                                                                     |
| `graphdb_mgr`          | Implemented — bootstrap init, public read API (`get_node`, `get_relationships`), category immutability guard, cache audit/repair (`verify_caches/0`, `rebuild_caches/0`); write operations delegate to workers                                                                                                             |
| `graphdb_attr`         | Fully implemented — attribute library (name, literal, relationship attributes, relationship types)                                                                                                                                                                                                                         |
| `graphdb_class`        | Fully implemented — taxonomic hierarchy with multi-parent inheritance (BFS — breadth-first search — over a DAG, a directed acyclic graph), qualifying characteristics, class-level inheritance                                                                                                                             |
| `graphdb_instance`     | Fully implemented — compositional hierarchy, multi-class membership, four-level inheritance with class-resolver ambiguity detection; fires composition rules on `create_instance/3`, surfaces `proposed` outcomes for propose-mode rules, and fires connection rules via a caller-supplied resolver on `create_instance/4` |
| `graphdb_rules`        | Implemented — rule meta-ontology + create/retrieve; `effective_rules_for_class/2` + `effective_connection_rules/2` (taxonomy walk); composition firing engine; propose mode; connection firing; conflict precedence and the later firing-engine phases outstanding (see `TASKS.md`)                                        |
| `graphdb_language`     | Fully implemented — multilingual overlay (language registration, dialect chains, per-language overlay tables, label resolution, translation hooks)                                                                                                                                                                         |
| `graphdb_query`        | Implemented — query language (parse/execute, snapshot-semantics sessions, path finding)                                                                                                                                                                                                                                    |

**509 tests** (105 EUnit + 404 Common Test) — all passing. See
`TASKS.md` for remaining work.

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
│   ├── dictionary/    # In-memory (ETS — Erlang Term Storage) and file-backed key-value dictionary
│   └── nref/          # Globally unique node-reference ID allocator
├── rebar.config       # rebar3 umbrella build configuration
├── Makefile           # Convenience targets (compile, shell, release, clean)
└── CLAUDE.md          # Project guide and coding conventions
```

### OTP Supervision Tree

```
seerstone (application)
  └── seerstone_sup
        └── database_sup
              ├── graphdb_sup
              │     ├── graphdb_nref       (switchable node-nref allocation facade)
              │     ├── rel_id_server      (relationship-row ID allocator)
              │     ├── graphdb_mgr
              │     ├── graphdb_attr
              │     ├── graphdb_class
              │     ├── graphdb_instance
              │     ├── graphdb_language
              │     ├── graphdb_query
              │     └── graphdb_rules
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

The architecture is described in [`docs/TheKnowledgeNetwork.md`](docs/TheKnowledgeNetwork.md),
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
**concept node** with a stable, unique identity called an **Nref** (node
reference number — a positive integer allocated by the `nref` subsystem).

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

| Module             | Role                                                                                                                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `graphdb_attr`     | Attribute library — name attributes, literal attributes, relationship attributes, relationship types                                                                                                  |
| `graphdb_class`    | Taxonomic hierarchy — class nodes, qualifying characteristics, class inheritance                                                                                                                      |
| `graphdb_instance` | Instance nodes — creation, retrieval, compositional hierarchy                                                                                                                                         |
| `graphdb_rules`    | Graph rules — rule meta-ontology + create/retrieve; taxonomy-walk effective-rules reads; composition firing engine; propose mode; connection firing; conflict precedence and later phases outstanding |
| `graphdb_language` | Multilingual overlay — language registration, dialect chains, per-language overlay tables, label resolution                                                                                           |
| `graphdb_query`    | Query language — parses and executes graph queries; snapshot-semantics sessions                                                                                                                       |
| `graphdb_mgr`      | Primary coordinator — routes operations across the other specialized workers                                                                                                                          |

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

# Run individual Common Test suites (examples; see the full list below)
./rebar3 ct --suite=apps/graphdb/test/graphdb_bootstrap_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE
./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE

# Or run everything at once
./rebar3 eunit --app=graphdb && ./rebar3 ct
```

| Suite                     | Type  | Tests | Coverage                                                                                                                                                                                                                                                                                                                            |
| ------------------------- | ----- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `graphdb_bootstrap_tests` | EUnit | 61    | Term parsing, validation, record conversion, nref macro consistency                                                                                                                                                                                                                                                                 |
| `graphdb_class_tests`     | EUnit | 13    | `is_valid_parent_kind/1`, `collect_qc_nrefs/2`                                                                                                                                                                                                                                                                                      |
| `graphdb_instance_tests`  | EUnit | 13    | `find_avp_value/2`, composition-firing helpers (`summarize/1` etc.)                                                                                                                                                                                                                                                                 |
| `graphdb_language_tests`  | EUnit | 9     | Dialect-chain building, label-resolution helpers                                                                                                                                                                                                                                                                                    |
| `graphdb_mgr_tests`       | EUnit | 9     | Direction validation, client-side arg checks                                                                                                                                                                                                                                                                                        |
| `graphdb_bootstrap_SUITE` | CT    | 19    | Full bootstrap load, Mnesia tables, idempotency, error handling, Language subcategory nodes                                                                                                                                                                                                                                         |
| `graphdb_mgr_SUITE`       | CT    | 28    | Bootstrap init, read ops, category guard, write stubs, cache audit/repair                                                                                                                                                                                                                                                           |
| `graphdb_attr_SUITE`      | CT    | 37    | Attribute create/lookup, seeding, relationship types, atomic reciprocal pair, literal sub-groups, `attribute_type`/`instantiable` markers                                                                                                                                                                                           |
| `graphdb_class_SUITE`     | CT    | 49    | Class create, QC (qualifying characteristics), lookups, hierarchy, multi-inheritance, inheritance, templates, abstract classes                                                                                                                                                                                                      |
| `graphdb_instance_SUITE`  | CT    | 101   | Instance create (incl. composition rule firing, propose-mode outcomes, `{Min,Max}` multiplicity, and connection firing — resolver-driven mandatory/auto/propose, target validation), relationships (incl. arc validation, per-arc AVPs — attribute-value pairs), lookups, hierarchy, four-level inheritance, multi-class membership |
| `graphdb_language_SUITE`  | CT    | 27    | Multilingual overlay: language/dialect registration, per-language overlay tables, label resolution, translation hooks                                                                                                                                                                                                               |
| `graphdb_query_SUITE`     | CT    | 43    | Query language: parse/execute, snapshot-semantics sessions, `#cont_path{}` resume, path finding                                                                                                                                                                                                                                     |
| `graphdb_rules_SUITE`     | CT    | 71    | Rule meta-ontology seeding (incl. `reciprocal_nref` literal), composition/connection rule create/retrieve (incl. reciprocal param), validation catalog (incl. `{Min,Max}` multiplicity range), `effective_rules_for_class/2` taxonomy walk, `effective_connection_rules/2`, composition firing engine, propose mode                 |
| `graphdb_nref_SUITE`      | CT    | 6     | Switchable node-nref allocation facade; permanent/runtime phase flip                                                                                                                                                                                                                                                                |
| `graphdb_nrefs_SUITE`     | CT    | 2     | `graphdb_nrefs:verify/0` bootstrap nref-macro consistency check                                                                                                                                                                                                                                                                     |
| `rel_id_server_SUITE`     | CT    | 7     | Relationship-row ID allocator (`get_id/0`, `get_id_pair/0`)                                                                                                                                                                                                                                                                         |
| `dictionary_server_SUITE` | CT    | 7     | `dictionary_server` gen_server behaviour                                                                                                                                                                                                                                                                                            |
| `term_server_SUITE`       | CT    | 7     | `term_server` gen_server behaviour                                                                                                                                                                                                                                                                                                  |

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
`TASKS.md` for the list of remaining implementation work.

Key conventions at a glance:

- Every module uses `?NYI(X)` and `?UEM(F, X)` macros for unimplemented paths
- Module names follow the pattern: `name.erl`, `name_sup.erl`, `name_server.erl`, `name_imp.erl`
- Graph nodes are identified by **Nrefs** — plain positive integers allocated by `nref_server:get_nref/0`
- See [`docs/TheKnowledgeNetwork.md`](docs/TheKnowledgeNetwork.md) for the knowledge model behind the graphdb workers
- PRs target `main`
