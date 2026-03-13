# Database — Database Umbrella OTP Application

## Purpose

`database` is the **umbrella OTP application** that groups the `graphdb` and `dictionary` applications under a single supervisor (`database_sup`). It is a direct child of the top-level `seerstone_sup`.

## Files

| File | Description |
|---|---|
| `database.erl` | OTP `application` behaviour callback module |
| `database_sup.erl` | OTP `supervisor` — supervises graphdb and dictionary subsystems |
| `database-1.boot` / `.rel` / `.script` | OTP release files |
| `database.beam` / `database_sup.beam` | Compiled BEAM bytecode |

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
        ├── graphdb_sup    (from graphdb/)
        └── dictionary_sup (from Dictionary/)
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
- Both `database.beam` and `database_sup.beam` are also present in the project root (copies — keep in sync or resolve)

## Compile

```sh
erlc Database/database_sup.erl Database/database.erl
```
