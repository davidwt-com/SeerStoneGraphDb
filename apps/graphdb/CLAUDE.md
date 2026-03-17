# graphdb — Graph Database OTP Application

## Purpose

`graphdb` is the core **graph database** OTP application within the SeerStone system. It is supervised by `database_sup` (see `Database/`) and itself manages graph data through `graphdb_sup`.

## Files

| File | Description |
|---|---|
| `graphdb.erl` | OTP `application` behaviour callback module |
| `graphdb_sup.erl` | OTP `supervisor` behaviour callback module |
| `graphdb-1.boot` / `.rel` / `.script` | OTP release files for standalone graphdb deployment |
| `graphdb-1.tar.gz` | Packaged OTP release |
| `graphdb.beam` / `graphdb_sup.beam` | Compiled BEAM bytecode |

## Application Lifecycle

`graphdb` is started by calling `application:start(graphdb)` or indirectly via the `database` application supervisor. The call chain is:

```
database_sup -> graphdb_sup:start_link(StartArgs) -> graphdb_sup:init/1
```

`graphdb:start/2` delegates immediately to `graphdb_sup:start_link/1`.

## Supervisor (`graphdb_sup`)

The `graphdb_sup` supervisor is responsible for the graph database worker processes. Its `init/1` is **not yet fully implemented** — child specs for actual graph worker processes need to be added.

## NYI Status

The following callbacks in `graphdb.erl` are stubs that call `?NYI(...)` and must be implemented:

- `start_phase/3` — phased startup (only needed if `start_phases` key added to `.app`)
- `prep_stop/1` — pre-shutdown cleanup
- `stop/1` — post-shutdown cleanup
- `config_change/3` — runtime config change notification

## Key Design Notes

- `graphdb_sup` receives `StartArgs` from `database:start/2`, unlike `seerstone_sup` which takes no args
- The UEM macro in `graphdb:start/2` catches unexpected return values from `graphdb_sup:start_link/1`
- Graph nodes are identified by **Nrefs** (globally unique integers) allocated by the `nref` application — see `Nref Server/`

## Compile

From the `graphdb/` directory:
```sh
erlc graphdb_sup.erl graphdb.erl
```

Or from the project root, compile all:
```sh
erlc graphdb/*.erl
```
