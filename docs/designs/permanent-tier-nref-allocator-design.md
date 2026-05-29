<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Permanent-Tier Nref Allocator (init-seed nref tier)

**Status:** Implemented
**Date:** 2026-05-28
**Topic origin:** `memory/project-init-seed-nref-tier.md` (first of two
pending topics flagged 2026-05-27)

## 1. Problem

Module `init/1` one-time seed creates currently allocate node nrefs
from the **runtime tier** (≥ `nref_start`), because they call
`nref_server:get_nref/0` after the bootstrap loader has already called
`nref_server:set_floor(nref_start)`.

Affected paths:

| Worker             | init/1 seed path                          | Seeded nodes                                                                                    |
| ------------------ | ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `graphdb_attr`     | `ensure_seed/2` → `do_create_attribute/3` | `Attribute Literals` group; `literal_type`, `target_kind`, `relationship_avp`, `attribute_type` |
| `graphdb_language` | `ensure_literal_seed/2`                   | `Language Literals` group; `base_language`, `project_language`                                  |

These seeds are bootstrap-equivalent scaffolding — one-time,
deterministic, structural — and belong in the **permanent tier**
`[label_start, nref_start)` alongside English (10000), `lang_code`, and
`lang_human`, not scattered into runtime space.

The bootstrap loader already allocates its atom-labeled nodes from the
permanent tier via a transient local counter in `build_symbol_table/4`,
but that counter dies when `do_load/0` returns. There is no persistent
"next available permanent nref" anywhere after bootstrap, so init/1
seeds (which run *after* bootstrap) have nothing to continue from.

## 2. Scope

**In scope:** a single switchable `graphdb_nref` facade with a
permanent→runtime phase flip; the uniform one-token swap of all graphdb
node-nref allocation sites; promoting the tier boundaries to header
macros; removing the now-redundant `bootstrap.terms` directives; test
and doc updates.

**Out of scope (explicitly):**

- Runtime creates still land in the runtime tier — after the flip
  `graphdb_nref:get_next/0` delegates to `nref_server:get_nref/0`, so
  `graphdb_instance:create_instance/3`, `add_relationship/*`,
  `graphdb_mgr` write ops, and runtime
  `graphdb_language:register_language/2` are unaffected in outcome.
- **Cross-version / cross-environment seed identity.** A monotonic
  allocator (computed or persisted) gives collision-avoidance and
  within-a-single-DB-history determinism only. nref *values* remain
  dependent on allocation order/history: a fresh bootstrap of a future
  code version and an upgraded existing DB will assign different
  integers to the same logical seed. Content-addressed / stable
  identity is the job of the second pending topic
  (`memory/project-nref-identity-indirection.md`), not this work.

## 3. Approach: one switchable nref facade + phase flip

A single new gen_server, `graphdb_nref`, becomes *the* entry point for
**every** graphdb node-nref allocation. It has two modes:

- **permanent mode** (during the init phase) — hands out permanent-tier
  nrefs derived compute-from-DB (§3.2);
- **runtime mode** (after the flip) — delegates straight to
  `nref_server:get_nref/0`.

The mode is held in **durable global state** (`persistent_term`), *not*
in the facade's volatile gen_server state, so that a crash-and-restart
of any single process cannot resurrect the wrong phase (§3.5). The
gen_server owns only the permanent cursor (volatile, recomputed-from-DB
on demand).

The insight that makes this the *least-impact* design: during the init
phase **everything** created is permanent scaffolding, and after it
**everything** created is runtime data. So the tier is a global *phase*,
not a per-call-site decision. Every existing create function changes by
exactly one token — `nref_server:get_nref/0` → `graphdb_nref:get_next/0`
— with no signature changes and no seed-vs-runtime branching. Once all
`init/1`s have run, a single flip switches the facade to runtime mode
(§3.5).

`graphdb_nref` derives its permanent cursor from the `nodes` table
itself, so the database is the only source of truth — no second
persisted counter that can drift. Its runtime mode owns no counter at
all; `nref_server` remains the sole generic runtime allocator
(unpolluted by any permanent-tier or Mnesia knowledge).

### 3.1 Tier boundaries become header macros

The fixed tier dividers move into `apps/graphdb/include/graphdb_nrefs.hrl`
as compile-time constants, read by the loader, the `graphdb_nref`
facade, and the tests:

```erlang
%% -- Permanent / runtime tier boundaries ------------------------------
-define(LABEL_START,    10001).    %% first permanent nref above English
-define(NREF_START,   1000000).    %% runtime tier floor; permanent < this
```

These are **system invariants, not per-bootstrap-file knobs.** The
`{nref_start, N}` / `{label_start, N}` directives added to
`bootstrap.terms` last session are therefore removed; `classify_terms/N`
reverts to returning `{Nodes, Rels}` (no directive parsing), and
`validate_label_start/2` plus its directive-parsing tests are deleted.
The `bootstrap.terms` header comment is updated to reference the macros.

### 3.2 Permanent-mode allocation (compute-from-DB)

- **Supervision:** child of `graphdb_sup`, started *first* — before
  `graphdb_mgr` (whose `init/1` triggers the loader) and before every
  seeding worker — so the facade is available to the earliest
  allocation. Consistent with `nref_server` / `rel_id_server` as
  dedicated allocators.

- **Lazy compute-from-DB, then cached cursor.** On the first
  `get_next/0` call while in permanent mode (which lands during
  `graphdb_attr:init`, after the loader has written its labeled nodes),
  the facade scans the `nodes` table:

  ```
  Cursor = max(?LABEL_START, 1 + max{ N in nodes : N < ?NREF_START })
        %% or ?LABEL_START if no node satisfies the predicate
  ```

  The cursor is cached in gen_server state and incremented per
  allocation. The gen_server serializes all allocations, so concurrent
  callers cannot collide.

- **Scan invariant (load-bearing).** The compute correctness rests on:
  *every node in the `nodes` table with `nref < ?NREF_START` is a
  permanent seed.* This holds today by construction — all runtime
  creates run *after the flip*, so `graphdb_nref:get_next/0` delegates
  to `nref_server:get_nref/0` (floor `?NREF_START`), and runtime nodes
  are always `>= ?NREF_START` even though they share the same `nodes`
  table. **Forward constraint:** the architecture's
  future per-project instance space (allocator starting at 1) must be a
  *physically separate* Mnesia table, never the shared `nodes` table —
  otherwise from-1 project nrefs would fall below `?NREF_START` and
  corrupt this scan. The allocator should assert this invariant cannot
  be silently violated (e.g. it only ever scans the ontology `nodes`
  table).

  Computing lazily (on first use) rather than at the facade's own
  `init/1` avoids a first-boot ordering hazard: on first boot the
  `nodes` table does not exist until the loader creates it, but the
  first allocation request only arrives during `graphdb_attr:init`,
  well after `graphdb_mgr:init` has run the loader.

- **`get_next/0`** in permanent mode returns the cursor, then
  increments it; in runtime mode it returns `nref_server:get_nref/0`.

### 3.3 Spillover rule

While in permanent mode, each allocation hands out `N = cursor` and then
increments. If a handed-out `N >= ?NREF_START`, the permanent tier is
full and the allocation has spilled into runtime space. The facade then
calls `nref_server:set_floor(N + 1)` so the runtime floor floats up
above the spilled region — i.e. *nref_start becomes the next available
nref*. `set_floor/1` is monotonic (`max(current, Floor)`), so this only
ever raises the floor.

With ~990 000 permanent slots this regime is effectively unreachable;
it is defined and enforced for completeness. Sustained spillover that
interleaves permanent and runtime allocations across boots is an
unsupported corner that would be subsumed by the identity-indirection
topic; it is not engineered here.

### 3.4 Loader keeps its local counter

The bootstrap loader keeps its local fold counter for the labeled batch
(decision: do **not** route the loader through `graphdb_nref`). Because
`graphdb_nref` computes its permanent cursor from the DB the loader
produced, the cursor naturally continues immediately past the labeled
nodes when the first init worker calls `get_next/0`. The two permanent
allocators never overlap (loader writes the labels, then the facade
resumes from `max+1`), so coexistence is safe. The loader's tested
two-pass behaviour is untouched apart from sourcing `?LABEL_START` /
`?NREF_START` from macros instead of directives.

The loader **no longer calls `nref_server:set_floor/1`.** During the
init phase no code touches `nref_server` (all node allocations go
through `graphdb_nref` in permanent mode), so the runtime floor is
irrelevant until the flip. `set_floor(?NREF_START)` moves to the flip
(§3.5), which becomes the sole `set_floor` call.

### 3.5 The flip (permanent → runtime)

`graphdb:start/2` **brackets** the boot: it marks the permanent phase
*before* `graphdb_sup:start_link/0` (so the facade and every seeding
worker init in permanent mode) and the runtime phase *after* it returns
(all `init/1`s done):

```erlang
start(_Type, _Args) ->
    ok = graphdb_nref:set_permanent_phase(),       %% persistent_term -> permanent
    case graphdb_sup:start_link() of
        {ok, Pid} ->
            ok = graphdb_nref:set_runtime_phase(),  %% persistent_term -> runtime; set_floor(?NREF_START)
            {ok, Pid};
        ...
    end.
```

`set_permanent_phase/0` / `set_runtime_phase/0` write the durable phase
flag (and the runtime one also calls `nref_server:set_floor(?NREF_START)`
— the sole `set_floor` call). They are module functions that touch only
`persistent_term` + `nref_server`, so they work even before the facade
gen_server is up (it is a child of `graphdb_sup`, started inside
`start_link`).

`graphdb_sup:start_link/0` returns only after all children's `init/1`s
have run, and the `database` app (which depends on `graphdb`) starts
*after* `graphdb:start/2` returns — so there is no window in which
runtime traffic could allocate while still in permanent phase. This is
viable because `graphdb` is a peer application with `{mod, {graphdb,
[]}}`; `graphdb:start/2` is genuinely invoked. (The stale
`apps/graphdb/CLAUDE.md` claim that `graphdb_sup` is started "not by
`graphdb:start/2`" predates the E5 included→peer change and is corrected
in the doc pass.)

**Temporal invariant (load-bearing, document at the call site).** Every
permanent seed must be allocated *synchronously* inside an `init/1` (or
the bootstrap loader) that runs before the flip; nothing may allocate a
node nref expecting permanent tier after `graphdb_sup:start_link/0`
returns. Verified true today: the only synchronous init allocations are
`graphdb_attr` (`do_create_attribute` in `init`) and `graphdb_language`
(`ensure_literal_seed` in `init`); the `register_language` /
`register_dialect` paths and async translation hooks are runtime-only
and correctly receive runtime nrefs post-flip. New seeding workers
(F4 `graphdb_rules`) must keep their seeding synchronous in `init/1`.

**Restart semantics (why the durable flag matters).** Under
`graphdb_sup`'s `one_for_one`, individual children restart in isolation
and `graphdb:start/2` does *not* re-run — so a phase held in volatile
state would be wrong after a restart. With the flag in `persistent_term`:

- **Facade (`graphdb_nref`) crashes at runtime** → restarts, reads
  `runtime` from `persistent_term` → delegates to `nref_server`. No
  corruption. (Its volatile cursor is irrelevant in runtime phase; in
  permanent phase it is recomputed-from-DB on next use.)
- **`graphdb_mgr` or a seeding worker crashes at runtime** → its
  `init/1` re-runs but never writes the phase flag; the phase stays
  `runtime`. Idempotent lookup-by-name finds existing seeds and
  allocates nothing anyway (D7).
- **Full VM / app restart** → `persistent_term` is cleared (VM) or
  re-bracketed by `start/2` (app), re-entering the permanent phase for
  the fresh init before flipping back.

This closes the resurrection hole that a volatile, default-permanent
mode would leave open (a single facade crash silently writing
permanent-tier nrefs as runtime nodes).

## 4. Call-site rewiring (uniform one-token swap)

Every graphdb **node-nref** allocation site swaps
`nref_server:get_nref/0` → `graphdb_nref:get_next/0`. No signatures
change and no function branches on seed-vs-runtime: the facade's mode
decides the tier. `do_create_attribute/3` is therefore reused verbatim
for both init seeding and runtime creation — the awkward seed-vs-runtime
factoring of the previous draft is eliminated.

Known sites to swap (the plan enumerates exhaustively by grepping
`nref_server:get_nref` under `apps/graphdb/src`):

| Module             | Sites                                                                              |
| ------------------ | ---------------------------------------------------------------------------------- |
| `graphdb_attr`     | `do_create_attribute/3`, `do_create_relationship_attribute_pair/3`                 |
| `graphdb_language` | `ensure_literal_seed/2` (init); `register_language` / `register_dialect` (runtime) |
| `graphdb_instance` | `do_create_instance/3`, `add_relationship` paths                                   |
| `graphdb_class`    | `create_class` path                                                                |

Two things stay on their current allocators: **relationship row IDs**
(`rel_id_server:get_id*/*` — a separate id space, never node nrefs) and
the **bootstrap loader** (its own local counter, §3.4).

Future seeding workers (F4 `graphdb_rules`) call `graphdb_nref:get_next/0`
from synchronous `init/1` seeding like the others.

## 5. Testing

- **New `graphdb_nref_SUITE`** (or EUnit): permanent-phase
  compute-from-empty returns `?LABEL_START`; compute-from-populated
  resumes at `max+1`; sequential calls are unique and monotonic;
  spillover raises the runtime floor; after `set_runtime_phase/0`,
  `get_next/0` delegates to `nref_server` and returns `>= ?NREF_START`;
  **restart safety** — with the phase flag set to `runtime`, killing and
  restarting the facade gen_server still yields `>= ?NREF_START` (the
  durable flag survives the restart; no permanent-tier leak).
- **`graphdb_attr_SUITE` / `graphdb_language_SUITE`:** flip seed
  assertions from `>= 1000000` to permanent bounds
  (`> ?NREF_ENGLISH andalso < ?NREF_START`).
- **`graphdb_bootstrap_tests` / `graphdb_bootstrap_SUITE`:** remove
  the directive-parsing tests (`*_label_start_*`, `*_nref_start_*`,
  directive-order cases) and `validate_label_start` group; adjust
  `build_symbol_table` and `classify_terms` tests to the macro-sourced,
  directive-free shapes; fixtures drop the directive lines.

## 6. Documentation

- `bootstrap.terms` header comment — tiers reference the macros, not
  directives; loader no longer calls `set_floor`.
- `ARCHITECTURE.md` nref-tier section — init seeds now permanent;
  boundaries are header macros; describe the `graphdb_nref` facade and
  the phase flip.
- Root `CLAUDE.md` + `apps/graphdb/CLAUDE.md` — nref-spaces bullets,
  the supervision-tree / worker list (add `graphdb_nref`), and **fix
  the stale claim** that `graphdb_sup` is started "not by
  `graphdb:start/2`" (it is — peer app since E5).
- `graphdb.erl` — the flip is added to `start/2`; reflect in any
  module-level lifecycle notes.
- `docs/diagrams/ontology-tree.md` — unaffected (seed *shape*
  unchanged; only nref *values* move tier).

## 7. Open items deferred elsewhere (not part of this work)

- English `category 32 → instance 10000` composition-vs-connection arc
  (`bootstrap.terms` OPEN QUESTION block) — awaits connection-arc infra.
- `lang_code` / `lang_human` labeled-node design review
  (`bootstrap.terms` PROPOSAL block).
- Cross-version seed identity — second pending topic
  (`memory/project-nref-identity-indirection.md`).

## 8. Decision log

| ID  | Decision                                                                 | Rationale                                                                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Compute-from-DB cursor, not a persisted DETS counter                     | DB is single source of truth; resumes correctly when later workers seed; no drift                                                                                                                                                                                           |
| D2  | Tier boundaries as `graphdb_nrefs.hrl` macros; drop bootstrap directives | System invariants, not per-file knobs; one source for loader/facade/tests                                                                                                                                                                                                   |
| D3  | Single switchable `graphdb_nref` facade, not a cursor in `graphdb_mgr`   | Consistent with `nref_server`/`rel_id_server`; one process serializes allocation; loader runs in `graphdb_mgr:init` so a mgr-hosted cursor would self-call                                                                                                                  |
| D4  | Lazy compute on first use, not at facade `init/1`                        | Sidesteps first-boot table-creation ordering hazard                                                                                                                                                                                                                         |
| D5  | Spillover raises runtime floor via `set_floor(N+1)`                      | Matches "nref_start becomes the next available nref"; monotonic set_floor                                                                                                                                                                                                   |
| D6  | This work does NOT deliver cross-version seed identity                   | That is the indirection topic's job; keeps the two topics' scopes crisp                                                                                                                                                                                                     |
| D7  | Cursor recomputed per boot, never persisted across restarts              | Safe because init/1 keeps idempotent lookup-by-name first, allocating only on a miss — a fresh cursor is never consulted for already-seeded nodes. Answers the open persistence question in `project-init-seed-nref-tier.md`.                                               |
| D8  | Mode flip via phase, not per-call intent; uniform one-token swap         | "Least impact, most reuse" — create functions are reused verbatim, no seed-vs-runtime branching. Cost: a global temporally-scoped mode resting on the §3.5 temporal invariant.                                                                                              |
| D9  | Flip lives in `graphdb:start/2` after `graphdb_sup:start_link/0` returns | All child init/1s are done and no runtime traffic exists yet; viable because graphdb is a peer app. Finalizer-child was the alternative.                                                                                                                                    |
| D10 | Loader keeps its local counter (not routed through `graphdb_nref`)       | User choice; the facade computes-from-DB past the loader's labels, so the two never overlap — coexistence is safe.                                                                                                                                                          |
| D11 | Phase flag in `persistent_term`, bracketed by `graphdb:start/2`          | A volatile default-permanent mode lets a single facade restart at runtime resurrect the permanent phase and write permanent-tier nrefs as runtime nodes, corrupting the scan invariant. Durable flag + start/2 bracketing closes the hole across all single-child restarts. |
