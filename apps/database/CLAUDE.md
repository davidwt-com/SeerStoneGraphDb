<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Database — Database Umbrella OTP Application

## Purpose

`database` is the **coordination OTP application** that declares `graphdb` and `dictionary` as peer-application dependencies. It starts after both and provides an empty `database_sup` as an attachment point for future database-level services.

## Files

| File               | Description                                                     |
| ------------------ | --------------------------------------------------------------- |
| `database.erl`     | OTP `application` behaviour callback module                     |
| `database_sup.erl` | OTP `supervisor` — empty; attachment point for future database-level services |

## Application Lifecycle

`database` is a peer OTP application started by `application_master` —
listed in `seerstone.app.src`'s `applications:` dependency list, so it
starts before `seerstone`. The flow:

```
application_master
  -> database:start(normal, [])
    -> database_sup:start_link/0
      -> database_sup:init/1
```

`database:start/2` calls `database_sup:start_link/0`. Any `StartArgs` from
the `.app` file are not threaded through — `database_sup` takes no args,
matching the `seerstone` / `nref` convention.

## Supervision Tree Position

```
database_sup (one_for_one, MaxR=5, MaxT=5000)
  ├── graphdb_sup    (from apps/graphdb/    — graphdb is included_application)
  └── dictionary_sup (from apps/dictionary/ — dictionary is included_application)
```

`database_sup` is the top supervisor of the `database` application;
`application_master` owns it. `graphdb_sup` and `dictionary_sup` are direct
children declared with `Type = supervisor`, `Shutdown = infinity` —
giving the subtree unlimited time to shut down gracefully.

## NYI Status

The following callbacks in `database.erl` return `ok` (no-op stubs; correct for
the current deployment model — no phased startup, no pre-shutdown hooks needed):

- `start_phase/3`
- `prep_stop/1`
- `stop/1`
- `config_change/3`

## Key Design Notes

- `database_sup:start_link/0` takes no args (matches the convention used by every supervisor in the umbrella)
- The `database` application's `.app` file should declare `graphdb` and `dictionary` as included applications

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/database/src/database_sup.erl apps/database/src/database.erl
```

## Remaining Work

See `apps/graphdb/CLAUDE.md` and `TASKS.md` at the project root for the
remaining graphdb work and `dictionary_server` / `term_server` wiring
(Task 7 in `TASKS.md`).
