# Database — Database Umbrella OTP Application

## Purpose

`database` is the **umbrella OTP application** that groups the `graphdb` and `dictionary` applications under a single supervisor (`database_sup`). It is a direct child of the top-level `seerstone_sup`.

## Files

| File               | Description                                                     |
| ------------------ | --------------------------------------------------------------- |
| `database.erl`     | OTP `application` behaviour callback module                     |
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

The following callbacks in `database.erl` return `ok` (no-op stubs; correct for
the current deployment model — no phased startup, no pre-shutdown hooks needed):

- `start_phase/3`
- `prep_stop/1`
- `stop/1`
- `config_change/3`

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

## Remaining Work

See `apps/graphdb/CLAUDE.md` and the severity-grouped task files
(`TASKS-CRITICAL.md`, `TASKS-HIGH.md`, `TASKS-MEDIUM.md`, `TASKS-LOW.md`) at
the project root for the remaining graphdb work and `dictionary_server` /
`term_server` wiring (Task 7 in `TASKS-LOW.md`).
