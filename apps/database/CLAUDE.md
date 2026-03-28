# Database — Database Umbrella OTP Application

## Purpose

`database` is the **umbrella OTP application** that groups the `graphdb` and `dictionary` applications under a single supervisor (`database_sup`). It is a direct child of the top-level `seerstone_sup`.

## Files

| File | Description |
|---|---|
| `database.erl` | OTP `application` behaviour callback module |
| `database_sup.erl` | OTP `supervisor` — supervises graphdb and dictionary subsystems |

## Application Lifecycle

`database` is started by the top-level `seerstone_sup`, which calls:

```
seerstone_sup:init/1
  -> childspec(database_sup)
    -> database_sup:start_link/0
      -> database_sup:init/1
```

`database:start/2` passes `StartArgs` through to `database_sup:start_link/1`.

## Supervision Tree Position

```
seerstone_sup (one_for_one, MaxR=5, MaxT=5000)
  └── database_sup   ← this application's supervisor
        ├── graphdb_sup    (from apps/graphdb/)
        └── dictionary_sup (from apps/dictionary/)
```

`database_sup` is declared as `Type = supervisor`, `Shutdown = infinity` in `seerstone_sup`'s child spec — giving the subtree unlimited time to shut down gracefully.

## NYI Status

The following callbacks in `database.erl` are stubs:

- `start_phase/3` — NYI
- `prep_stop/1` — NYI
- `stop/1` — NYI
- `config_change/3` — NYI

`database_sup:init/1` child specs for `graphdb_sup` and `dictionary_sup` need to be verified / completed.

## Key Design Notes

- `database_sup` receives `StartArgs` forwarded from `database:start/2`
- The `database` application's `.app` file should declare `graphdb` and `dictionary` as included applications

## Compile

```sh
# with rebar3 (from project root — preferred):
./rebar3 compile

# manually (from project root):
erlc apps/database/src/database_sup.erl apps/database/src/database.erl
```

## TASKS.md Alignment

Key items marked as DONE in `TASKS.md`:
- Dictionary subsystem worker modules (`dictionary_server`, `term_server`).
- `dictionary_imp` export_all flag removed.
- `nref_include.erl` deleted (superseded by `nref_server`).

Remaining high-priority items:
- Implementation of the six graphdb worker modules (see `apps/graphdb/CLAUDE.md` and `TASKS.md` task 3).
