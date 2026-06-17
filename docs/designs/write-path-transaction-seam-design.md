<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Write-Path Transaction-Layering Seam — Design

**Status:** Designed; not yet planned or implemented.

**Context:** First piece of the **write-path completion** track in
`TASKS.md`. The track decomposes into five independent slices —
A `delete_node`, B `update_node_avps`, C template attribute list +
instance-only enforcement, D multilingual write-path wiring, and
E relationship mutation. Slice A is itself split: this document specifies
the **transaction-layering seam** that `delete_node` and
`remove_relationship` are built on; `delete_node` itself follows in a
later design once the seam exists.

**Spec citation:** none. The knowledge-network spec
(`docs/TheKnowledgeNetwork.md`) is a data model and is silent on
transaction mechanics. This is an infrastructural design that records a
convention for how write-path mutations compose over Mnesia.

---

## 1. Scope

### 1.1 The problem

Every existing write operation in the graphdb workers opens its own
`mnesia:transaction/1` (e.g. `graphdb_instance:do_add_relationship/7,
do_write_class_membership/2`). That is correct for a single operation but
does not compose: there is no way to run two mutations as one atomic unit
without nesting transactions, and the upcoming write-path work needs
exactly that —

- `delete_node` (slice A) does blocker-check reads and row deletes that
  must commit or roll back together;
- `remove_relationship` (slice E) removes both directed rows of a logical
  edge atomically;
- a future batch `mutate([Mutation])` (tracked follow-up) runs an
  arbitrary list of mutations in one transaction;
- a future "delete an instance with its parts" composes a generic delete
  with type-specific cleanup.

This design fixes **where the transaction boundary lives** so all of the
above share the same building blocks.

The convention already exists in embryo. `graphdb_mgr` carries several
functions documented "Must run inside an active mnesia transaction" —
`expected_parents/1`, `expected_classes/1`, `verify_one/1`,
`rebuild_one/1` — which are tier-1 primitives in all but name. And the
`{atomic, R} -> {ok, R}; {aborted, Reason} -> {error, Reason}` mapping is
already hand-rolled inline in at least three places (`do_get_relationships/2`
and the `verify_caches/0` / `rebuild_caches/0` wrappers). This slice names
the convention and factors that repeated mapping into one helper.

### 1.2 What this slice delivers

The **minimal seam only**:

1. a documented three-tier convention (§2);
2. one shared transaction-runner helper, `graphdb_mgr:transaction/1`
   (§3);
3. tests proving the runner's atomicity and result normalisation against
   sample primitives (§5).

No existing write operation is changed. `delete_node` and
`remove_relationship` adopt the seam as their first real consumers, in
their own later slices.

### 1.3 Out of scope (tracked elsewhere)

| Item                                           | Where it lives                |
| ---------------------------------------------- | ----------------------------- |
| `delete_node` implementation + deletion policy | Slice A, later design         |
| `remove_relationship` / `update_relationship`  | Slice E                       |
| Retrofitting existing ops onto the seam        | Tracked follow-up in TASKS.md |
| Batch `mutate([Mutation])` tier-3 entry point  | Tracked follow-up in TASKS.md |

The retrofit follow-up's first concrete targets are the inline-mapping
wrappers already in `graphdb_mgr` — `do_get_relationships/2`,
`verify_caches/0`, and `rebuild_caches/0` — which hand-roll the
`{atomic}`/`{aborted}` mapping that `transaction/1` replaces.

---

## 2. The convention — three tiers

The transaction boundary lives in **exactly one tier**. Mutations are
written as composable primitives that assume a surrounding transaction;
only wrappers open one.

### Tier 1 — in-transaction primitives

A *tier-1 primitive* is any function that:

- assumes it is **already inside** an Mnesia activity — it uses
  `mnesia:read/write/delete/index_read` directly and **never** calls
  `mnesia:transaction/1`;
- signals a domain failure by calling `mnesia:abort(Reason)`;
- returns its success value normally.

Because a primitive opens no transaction of its own, primitives compose:
several can run inside one transaction with a single atomic outcome.
`graphdb_mgr:expected_parents/1`, `expected_classes/1`, `verify_one/1`,
and `rebuild_one/1` already satisfy this contract today.

### Tier 2 — single-op public API

A *tier-2* function is the public entry point for one mutation (e.g. the
future `graphdb_mgr:delete_node/1`). It performs any static guards that
need no transaction (argument validation, the permanent-tier nref
boundary, kind lookups), then wraps **one** primitive:

```erlang
delete_node(Nref) ->
    case static_guards(Nref) of
        ok            -> graphdb_mgr:transaction(fun() -> delete_node_(Nref) end);
        {error, _}=E  -> E
    end.
```

### Tier 3 — batch / composite

A *tier-3* function composes several mutations into one atomic unit. It
wraps **one** transaction and calls the **tier-1 primitives directly** —
never the tier-2 wrappers — so there is no transaction nesting:

```erlang
mutate(Mutations) ->
    graphdb_mgr:transaction(
      fun() -> [apply_mutation(M) || M <- Mutations] end).
```

A composite such as "delete an instance with its parts" follows the same
shape: inside one `transaction/1`, call the generic delete primitive plus
whatever type-specific cleanup the owning worker contributes (also as
tier-1 primitives).

### Why not rely on nested transactions

Mnesia *does* support nesting — an inner `mnesia:transaction/1` joins the
outer one and commits with it. The seam deliberately does not lean on
that: nesting muddies abort reasons and return shapes and makes the
atomicity boundary implicit. Standardising on "primitives assume a
transaction; only wrappers open one" keeps the boundary explicit and the
error contract uniform.

---

## 3. The helper

One new export on `graphdb_mgr`. It is a **plain exported function, not a
`gen_server:call`**: `mnesia:transaction/1` runs in the *calling*
process, so routing writes through the `graphdb_mgr` server process would
needlessly serialise every write and risk deadlock. The helper is
stateless and holds no relation to the gen_server's `State`.

```erlang
%% transaction(Fun) -> {ok, Result} | {error, Reason}
%%
%% Runs Fun inside one Mnesia transaction and normalises the result.
%% Fun is a tier-1 primitive (or a composition of them): it does its
%% reads/writes with bare Mnesia ops and signals failure via
%% mnesia:abort/1.
-spec transaction(fun(() -> Result)) -> {ok, Result} | {error, term()}.
transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic,  Result} -> {ok, Result};
        {aborted, Reason} -> {error, Reason}
    end.
```

The helper is added to `graphdb_mgr`'s export list and documented with the
module's existing header-comment style. No supervision-tree change, no new
module.

---

## 4. Error normalisation

| Mnesia outcome                   | `transaction/1` returns    |
| -------------------------------- | -------------------------- |
| `{atomic, R}`                    | `{ok, R}`                  |
| `{aborted, Reason}` (from abort) | `{error, Reason}`          |
| `{aborted, {Reason, Stack}}`     | `{error, {Reason, Stack}}` |

- A primitive's `mnesia:abort(my_reason)` surfaces as `{error,
  my_reason}` — this is the channel tier-1 primitives use to report a
  domain failure (e.g. a future `{error, {has_children, Nref}}`).
- An uncaught Erlang exit/exception inside the transaction body surfaces
  as Mnesia's standard `{aborted, {Reason, Stacktrace}}` shape; the
  helper passes it through as `{error, {Reason, Stacktrace}}` without
  reshaping. Callers that need clean domain errors must `mnesia:abort/1`
  deliberately rather than relying on crashes.

---

## 5. Testing

No real consumer ships in this slice, so the runner is exercised with
**sample throwaway primitives** against the real `nodes` / `relationships`
tables in the Common Test scratch database. Three properties:

1. **Success + result passthrough.** A primitive writes two rows and
   returns a value → `transaction/1` returns `{ok, Value}`; both rows are
   present after commit.
2. **Abort rolls back.** A primitive writes one row, then
   `mnesia:abort(blocked)` → `transaction/1` returns `{error, blocked}`;
   the row it wrote is **not** present (single-primitive atomic rollback).
3. **Composition rolls back.** A fold runs two primitives inside one
   `transaction/1`; the *second* aborts → the *first* primitive's write is
   also absent. This proves the atomicity property tier-3 relies on.

Tests use a scratch nref well above `?NREF_START` and clean up after
themselves, consistent with the suite's per-case isolation.

---

## 6. Files touched

| File                                      | Change                              |
| ----------------------------------------- | ----------------------------------- |
| `apps/graphdb/src/graphdb_mgr.erl`        | Add exported `transaction/1` + doc  |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl` | Add the three runner cases (§5)     |
| `TASKS.md`                                | Already updated — seam + follow-ups |

No `docs/Architecture.md` change is required: the supervision tree, the
Mnesia schema, and the public worker contracts are unchanged. The seam is
an internal convention plus one helper. (Architecture.md may pick up a
one-line note when the first consumer — `delete_node` — lands.)

---

## 7. Open items

None. The convention, the helper signature, the error mapping, and the
test plan are fixed. The name `transaction/1` is confirmed.
