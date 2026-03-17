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
| `nref_include.erl` | Shared include/data definitions (purpose TBD) |
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
nref_server:confirm_nref(Nref)    %% confirm single nref used
nref_server:confirm_nrefs(List)   %% confirm list of nrefs used
nref_server:reuse_nref(Nref)      %% mark nref for reuse
nref_server:reuse_nrefs(List)     %% mark list of nrefs for reuse
nref_server:confirm_nref_block(Nref, Count)
```

## Known Bugs

1. **`nref_server:get_another_nref_block/0`** — **FIXED** (was calling `allocate_nrefs` as a bare atom; now calls `nref_allocator:allocate_nrefs()`).

2. **`nref_server:initialize/1`** — **FIXED** (was calling `dets:init_table/3`; now uses `dets:insert/2` directly, consistent with `nref_allocator:open/0`).

3. **`nref_allocator:open/0`** — **FIXED** (syntax error: `nref_allocator.dets` is not valid Erlang; changed to the string `"nref_allocator.dets"`).

4. **`nref_include:check_file/1`** — **FIXED** (unreachable clause: `[H|_]` matched all non-empty lists, making the `[_|T]` fallthrough dead code; collapsed into a single `[H|T]` clause with a `case` on `dets:open_file/2`).

3. **`nref.erl` callbacks** — `start_phase/3`, `prep_stop/1`, `stop/1`, `config_change/3` are NYI stubs.

4. **`nref_allocator` and `nref_server` lack `start_link/0`** — Both are currently plain API modules that call DETS directly, not gen_servers. `nref_sup` references `nref_server` as a supervised child but `nref_server:start_link/0` does not exist. To properly supervise these processes, both modules need to be wrapped as `gen_server` behaviours. This is NYI — the gen_server skeleton (init/handle_call/handle_cast/terminate) needs to be written for each, with `open()` called in `init/1` and `close()` in `terminate/2`. Once done, `nref_sup` should list `nref_allocator` first, then `nref_server`.

## DETS File Location

`nref_allocator` opens its DETS file with a hardcoded atom filename:
```erlang
File = nref_allocator.dets,
```
This resolves relative to the Erlang node's working directory. The file `nref_allocator.dets` is present in the `Nref Server/` directory.

## Compile

```sh
# with rebar3 (from project root):
./rebar3 compile

# manually (from project root):
erlc apps/nref/src/nref_allocator.erl apps/nref/src/nref_server.erl apps/nref/src/nref_include.erl apps/nref/src/nref_sup.erl apps/nref/src/nref.erl
```
