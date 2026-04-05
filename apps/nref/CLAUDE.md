# Nref Server — Globally Unique Node Reference ID Service

## Purpose

The **Nref Server** allocates and recycles **Nrefs** — globally unique integer node reference numbers used to identify nodes throughout the SeerStone graph database. It is designed to be:

- Massively scalable (multiple servers, block-based allocation)
- Highly fault tolerant (DETS-backed persistence)
- Efficient at recycling released Nrefs

The `nref` application is **separate from the main `seerstone` hierarchy** and is started independently:
```erlang
application:start(nref).
```

## Files

| File | Description |
|---|---|
| `nref.erl` | OTP `application` behaviour callback — starts `nref_sup` |
| `nref_sup.erl` | OTP `supervisor` callback — supervises allocator and servers |
| `nref_allocator.erl` | Block-level nref allocator backed by DETS |
| `nref_server.erl` | Per-request nref server; client of `nref_allocator` |
| ~~`nref_include.erl`~~ | Deleted — was Dallas's earlier unsupervised predecessor to `nref_server`; fully superseded |
| `nref_allocator.dets` | Persistent DETS storage for allocator state |

## Architecture

```
nref (application)
  └── nref_sup (supervisor)
        ├── nref_allocator   — manages blocks of nrefs (DETS-backed)
        └── nref_server(s)   — serves individual nrefs from blocks
```

`nref_allocator` is the source of truth. `nref_server` instances request **blocks** of Nrefs from `nref_allocator` and serve individual nrefs from their local block, confirming usage back to `nref_allocator`.

## nref_allocator — DETS Schema

The DETS file stores these keys:

| Key | Type | Description |
|---|---|---|
| `block_size` | `integer()` | Number of nrefs per allocated block (default: 500) |
| `free` | `integer()` | Next nref available for fresh allocation |
| `reuse` | `[Count \| Nrefs]` | List with count prefix: nrefs available for reuse |
| `confirm` | `[Nref]` | Nrefs allocated but not yet confirmed as used |
| `allocated` | `[{Start, End}]` | Outstanding allocated blocks awaiting confirmation |

### Key API

```erlang
nref_allocator:open()                 %% open/initialize DETS file
nref_allocator:close()                %% close DETS file
nref_allocator:allocate_nrefs()       %% -> {Start, End} | {NrefList} | {error, Reason}
nref_allocator:reuse_nref(Nref)       %% return single nref for reuse
nref_allocator:reuse_nrefs(List)      %% return list of nrefs for reuse
nref_allocator:used_nref(Nref)        %% confirm single nref was used
nref_allocator:used_nrefs(List)       %% confirm list of nrefs were used
nref_allocator:used_nref_block(Block) %% confirm block {Start,End} fully used
nref_allocator:update_block_size(N)   %% change the allocation block size
```

Allocation preference: **reuse list first** (if ≥ block_size entries), then **fresh block**.

## nref_server — Per-Request API

```erlang
nref_server:open(File)            %% open DETS file
nref_server:close()               %% close DETS file
nref_server:get_nref()            %% -> Nref (integer)
nref_server:set_floor(Floor)      %% advance counter to max(current, Floor) — PENDING (Task 0b)
nref_server:confirm_nref(Nref)    %% confirm single nref used
nref_server:confirm_nrefs(List)   %% confirm list of nrefs used
nref_server:reuse_nref(Nref)      %% mark nref for reuse
nref_server:reuse_nrefs(List)     %% mark list of nrefs for reuse
nref_server:confirm_nref_block(Nref, Count)
```

`set_floor/1` is a planned addition (Task 0b). It is called exactly once by
`graphdb_bootstrap` as its first action, advancing the environment allocator counter
to 10000 before any nodes or relationships are written. On subsequent startups the
persisted DETS counter is already ≥ 10000 and the call is a no-op.

## NYI Status

- **`nref_server:set_floor/1`** — not yet implemented. Required by `graphdb_bootstrap` (Task 0b).
- **`nref.erl` callbacks** (`start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3`) return `ok` (no-op stubs; correct for current deployment model).
- **`nref:start/2` non-normal clauses**: `?NYI` for `{takeover, Node}` and `{failover, Node}`. Only relevant in distributed/failover deployments. See `TASKS.md` task L1.
- **`code_change/3`**: NYI in `nref_allocator.erl` and `nref_server.erl`. Only invoked during hot code upgrades. See `TASKS.md` task L2.

## DETS File Location

`nref_allocator` opens its DETS file as `"nref_allocator.dets"` (a string),
relative to the Erlang node's working directory.

## Compile

```sh
# with rebar3 (from project root):
./rebar3 compile

# manually (from project root):
erlc apps/nref/src/nref_allocator.erl apps/nref/src/nref_server.erl apps/nref/src/nref_sup.erl apps/nref/src/nref.erl
```
