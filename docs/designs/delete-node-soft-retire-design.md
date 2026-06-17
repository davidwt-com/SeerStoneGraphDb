<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Node Deletion — Soft-Retire — Design

**Status:** Designed; not yet planned or implemented. First real consumer
of the write-path transaction-layering seam.

**Context:** Slice A of the **write-path completion** track in `TASKS.md`.
The transaction-layering seam (`graphdb_mgr:transaction/1`) it builds on is
**already merged** (PR #41); this design assumes it exists. This document
specifies two new operations — `graphdb_mgr:retire_node/1` and its inverse
`graphdb_mgr:unretire_node/1`. The existing `delete_node/1` stub is left
**untouched** (it still returns `{error, not_implemented}`) and is reserved
for a future *real* (hard) delete.

**Spec citation:** none. `docs/TheKnowledgeNetwork.md` is a data model and
is silent on deletion mechanics. This is an infrastructural design that
records *what "delete" means* for a runtime node, chosen to stay compatible
with the planned history / versioning / bounded-lifetime feature.

---

## 1. Decision summary

"Deleting" a node is a **soft-retire**: a boolean `retired => true` marker
AVP is stamped on the node row. The node and all its arcs stay in Mnesia.
The operation is named `retire_node/1` (reversible via `unretire_node/1`);
the name `delete_node` is deliberately **not** reused, so it remains
available for a future real delete.

Soft-retire was chosen over hard delete after grounding the design in the
code:

- The environment/project split that a "refuse-if-referenced hard delete"
  policy depends on is **not physically realized** — there is one shared
  `nodes` / `relationships` table pair, instances draw nrefs from the
  environment runtime allocator (`graphdb_nref`), and the Projects
  category (`nref` 5) is a bare scaffold. So a project instance is not
  reliably distinguishable from an environment instance-kind node (e.g. a
  rule), and any env-vs-project discriminator would be a fragile heuristic
  that could mis-classify catastrophically.
- Soft-retire **never orphans an arc or a cache regardless of node role**,
  so it needs no discriminator at all.
- It is forward-compatible with the future history/versioning feature:
  retirement is a degenerate bounded lifetime, and a later background
  purge (tracked separately in `TASKS.md`) reclaims retired rows once that
  feature defines what is safe to forget. Mistakes are hidden now without
  being destroyed.

The hard-delete fast-path for project instances is deferred behind the
project-boundary work (`TASKS.md`).

### 1.1 Settled decisions

| Question              | Decision                                                                                                       |
| --------------------- | -------------------------------------------------------------------------------------------------------------- |
| Marker representation | **Boolean** `retired => true` AVP; absence = active (mirrors L9 `instantiable`)                                |
| Read-visibility scope | **Pragmatic middle** — hide from direct lookup *and* block a retired node from taking on **new** participation |
| Reversible?           | **Yes** — ship `unretire_node/1` alongside                                                                     |
| Public name           | **`retire_node/1`** — `delete_node/1` is left untouched, reserved for a future real delete                     |
| `get_node` on retired | Returns **`{error, retired}`** (distinct from `not_found`)                                                     |
| Permanent-tier guard  | `retire_node`/`unretire_node` refuse **all** `Nref < ?NREF_START` with a new atom `permanent_node_immutable`   |

---

## 2. The retired marker

A new seeded boolean literal-attribute, `retired`, created by
`graphdb_attr` exactly as `instantiable` is today:
`ensure_seed("retired", AttrLitNref)` in the **Attribute Literals**
sub-group under Literals (`?NREF_LITERALS`, nref 7), cached in
`graphdb_attr`'s state and exposed through `graphdb_attr:seeded_nrefs/0`
(the returned map gains a `retired => integer()` key).

Unlike `instantiable` (a class-only marker), `retired` is a **general
node-lifecycle marker** and may appear on a node of any kind. It is seeded
in the Attribute Literals sub-group for consistency with `instantiable`;
no new sub-group is introduced.

The marker is stored as an ordinary AVP on the `#node.attribute_value_pairs`
list: `#{attribute => RetiredNref, value => true}`. A node is retired iff
that AVP is present with `value => true`; absence (or `value => false`)
means active. The check mirrors `graphdb_class`'s
`is_marked_non_instantiable/2`:

```erlang
%% is_retired(AVPs, RetiredAttr) -> boolean()
is_retired(AVPs, RetiredAttr) ->
    lists:any(
      fun(#{attribute := A, value := true}) when A =:= RetiredAttr -> true;
         (_) -> false
      end, AVPs).
```

Workers that need the marker cache its nref at `init/1` from
`graphdb_attr:seeded_nrefs/0`, as `graphdb_class` / `graphdb_instance`
already do for `instantiable`: `graphdb_mgr` (for the retire/unretire
primitives and the lookup filter) and `graphdb_instance` (for the
block-new-participation guards).

---

## 3. The public API

Two new operations on `graphdb_mgr`, kept as `gen_server:call`s (they need
the seeded `retired` nref cached in state and are low-frequency admin
operations; see §6 for why this deviates from the seam's plain-function
guidance):

```erlang
%% retire_node(Nref) -> ok | {error, Reason}
%%   Soft-retires a runtime node (sets retired => true). Idempotent:
%%   re-retiring an already-retired node returns ok.
retire_node(Nref) -> ...

%% unretire_node(Nref) -> ok | {error, Reason}
%%   Clears the retired marker. Idempotent: unretiring a node that is not
%%   retired returns ok.
unretire_node(Nref) -> ...
```

Both are new exports. `delete_node/1` is **not** modified — it keeps
returning `{error, not_implemented}` and stays reserved for a future real
(hard) delete; `check_category_guard/1` and the
`category_nodes_are_immutable` atom remain in place for that path and for
the still-unimplemented `update_node_avps`.

### 3.1 Error contract (retire / unretire)

| Reason                     | When                                                         |
| -------------------------- | ------------------------------------------------------------ |
| `permanent_node_immutable` | `Nref < ?NREF_START` (categories, scaffold, permanent seeds) |
| `not_found`                | `Nref >= ?NREF_START` but no such node row                   |

The `Nref < ?NREF_START` guard is a pure arithmetic static guard: it
refuses the **whole** permanent tier, not just categories. This is
deliberate — a permanent arc-label attribute (e.g. nref 27, "Parent",
`kind=attribute`) is not a category, so a category-only guard would let it
be retired, and the block-new-participation rule (§4.1) would then break
`create_instance`. The new atom `permanent_node_immutable` is introduced
for the new function only; it renames nothing and changes no existing test.
(Unifying the permanent-tier immutability concept with `delete_node`'s
narrower category guard is a tracked follow-up — see `TASKS.md`.)

`not_found` is detected in-transaction (the marker write reads the row
under a write lock).

---

## 4. Read-visibility — the pragmatic middle

"Retire" means **hidden from address, and blocked from new participation**,
but *not* removed from existing graph structure. Concretely:

### 4.1 What retire DOES change

**(a) Direct lookup is hidden.** The public `graphdb_mgr:get_node/1`
returns `{error, retired}` for a retired node (distinct from `not_found`,
so an admin/unretire flow can tell a retired node from an absent one). The
internal `do_get_node/1` stays **raw** — it still returns the row — because
every internal guard, cache audit, and the retire/unretire primitives
themselves must see retired nodes. Only the public `get_node/1` handle_call
applies the filter.

**(b) New participation is refused.** A retired node may not be newly
referenced by a write. The guards live where the existing endpoint
validation already lives, in `graphdb_instance`:

| Write path                     | New guard                                                              | Reason atom                    |
| ------------------------------ | ---------------------------------------------------------------------- | ------------------------------ |
| `create_instance` target class | class must not be retired (alongside the `instantiable` check)         | `{class_retired, ClassNref}`   |
| `create_instance` parent       | parent must not be retired                                             | `{parent_retired, ParentNref}` |
| `add_class_membership` target  | class must not be retired                                              | `{class_retired, ClassNref}`   |
| `add_relationship` endpoints   | none of source / characterization / target / reciprocal may be retired | `{endpoint_retired, Nref}`     |

These mirror the existing `is_instantiable`-style guard pattern: read the
node inside the existing validation transaction, reject if the marker is
set.

### 4.2 What retire does NOT change (deferred)

Existing structural participation is left intact — this is the deliberate
boundary of the "middle":

- Traversals, children/parent enumeration, class→instance and
  instance→class enumeration still include retired nodes.
- The `graphdb_class` inheritance / ancestors walk still passes through a
  retired class.
- **A retired rule still fires.** A `graphdb_rules` rule node is reached
  through existing structure, so retiring it does not stop it firing.
  This is a concern, not a comfortable limitation, and is tracked as its
  own follow-up in `TASKS.md` ("retired rules must not fire") — the natural
  fix is a single filter at the firing read chokepoint
  (`effective_rules_for_class` / `effective_connection_rules`), kept out of
  this slice so the slice stays scoped to the retire mechanism itself.
- Query-engine results still include retired nodes.
- A node referenced as an AVP *value* elsewhere is unaffected (no index;
  the pre-existing non-goal).
- There is no "list all retired nodes" operation; enumerating retired rows
  is a concern of the background purge (tracked separately).

The justification: these all read existing arcs/rows that remain valid.
Blocking them generally would mean rewriting the hot read/firing paths and
pre-empting lifecycle semantics the versioning feature will define — except
rule firing, which is called out above and tracked.

---

## 5. Tier structure (on the seam)

### 5.1 Tier-1 primitive

```erlang
%% set_retired_(Nref, Bool, RetiredAttr) -> ok
%% Must run inside an active mnesia transaction.
%% Reads the node under a write lock, rewrites its AVP list so the
%% `retired` marker reflects Bool, and writes the row back.
%% Aborts with not_found if the row is absent.
set_retired_(Nref, Bool, RetiredAttr) ->
    case mnesia:read(nodes, Nref, write) of
        []       -> mnesia:abort(not_found);
        [Node]   ->
            AVPs0 = Node#node.attribute_value_pairs,
            AVPs1 = set_marker(AVPs0, RetiredAttr, Bool),
            mnesia:write(nodes, Node#node{attribute_value_pairs = AVPs1}, write)
    end.
```

`set_marker/3` removes any existing `retired` AVP and, when `Bool` is
`true`, appends `#{attribute => RetiredAttr, value => true}`. Setting
`false` simply removes the marker (absence = active), keeping the AVP list
free of dead `value => false` entries and making `retire_node`/
`unretire_node` exact inverses.

### 5.2 Tier-2 wrappers

Both wrappers do the arithmetic static guard, then run the primitive under
`graphdb_mgr:transaction/1`:

```erlang
handle_call({retire_node, Nref}, _From, State) ->
    {reply, set_retired(Nref, true, State), State};
handle_call({unretire_node, Nref}, _From, State) ->
    {reply, set_retired(Nref, false, State), State}.

set_retired(Nref, _Bool, _State) when Nref < ?NREF_START ->
    {error, permanent_node_immutable};
set_retired(Nref, Bool, #state{retired_nref = RetiredAttr}) ->
    case graphdb_mgr:transaction(fun() -> set_retired_(Nref, Bool, RetiredAttr) end) of
        {ok, ok}      -> ok;
        {error, _}=E  -> E
    end.
```

`transaction/1` maps `{atomic, ok}` → `{ok, ok}`; the wrapper normalises
that to a bare `ok` for the public contract, and passes `{error, Reason}`
(including `{error, not_found}` from the abort) straight through.

---

## 6. Why these stay gen_server calls

The seam recommends write entry points be **plain functions** so the
transaction runs in the caller and high-throughput writes are not
serialised through the `graphdb_mgr` process. `retire_node` /
`unretire_node` deliberately deviate:

- they need the seeded `retired` nref, which is cached in `graphdb_mgr`'s
  gen_server state;
- they are **low-frequency administrative** operations, so serialising
  them through the server is harmless.

The transaction body is still the seam's tier-1 primitive run via
`transaction/1`; only the wrapper is a `call`. High-frequency consumers
(e.g. a future batch `mutate/1`) should still follow the plain-function
form. This deviation is recorded here so the seam convention is not read as
violated by accident.

---

## 7. Testing

Common Test in the per-case scratch database, runtime-tier scratch nrefs.
`delete_node` is untouched, so its three existing guard cases
(`category_guard_delete`, `category_guard_allows_noncategory_delete`,
`category_guard_delete_nonexistent`) stay green **unchanged** — no test
churn.

**`graphdb_mgr_SUITE` — retire lifecycle (new)**

1. Retire a runtime node → `ok`; `get_node/1` then returns
   `{error, retired}`; `unretire_node/1` then succeeds (proves the row was
   not removed).
2. `unretire_node/1` → `ok`; `get_node/1` returns `{ok, Node}` again; the
   `retired` AVP is gone (exact-inverse check).
3. Idempotence: re-retiring a retired node → `ok`; unretiring a
   non-retired node → `ok`.
4. `retire_node(Nref)` / `unretire_node(Nref)` with `Nref < ?NREF_START`
   (e.g. a category and a permanent attribute such as nref 27)
   → `{error, permanent_node_immutable}`; the node is unchanged.
5. `retire_node(RuntimeNonexistent)` (nref `>= ?NREF_START`, no row)
   → `{error, not_found}`.

**`graphdb_instance_SUITE` — block-new-participation guards (new)**

6. `create_instance` against a retired class → `{error,
   {class_retired, ClassNref}}`.
7. `create_instance` under a retired parent → `{error,
   {parent_retired, ParentNref}}`.
8. `add_class_membership` to a retired class → `{error,
   {class_retired, ClassNref}}`.
9. `add_relationship` where the characterization / target / reciprocal is
   retired → `{error, {endpoint_retired, Nref}}` (one case per endpoint
   position, plus a clean-arc canary that still succeeds).

---

## 8. Files touched

| File                                           | Change                                                                                                                                 |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_attr.erl`            | Seed `retired` literal-attribute; add to state + `seeded_nrefs/0` map                                                                  |
| `apps/graphdb/src/graphdb_mgr.erl`             | Add `retire_node/1` + `unretire_node/1` (+exports); `get_node/1` retired filter; tier-1 `set_retired_/3`; cache `retired_nref` at init |
| `apps/graphdb/src/graphdb_instance.erl`        | Cache `retired_nref`; block-new-participation guards (class target, parent, arc endpoints)                                             |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`      | New retire/unretire lifecycle cases (existing delete-guard cases unchanged)                                                            |
| `apps/graphdb/test/graphdb_instance_SUITE.erl` | New guard cases                                                                                                                        |
| `docs/Architecture.md`                         | Note `retire_node` / `unretire_node` soft-retire and the `retired` marker                                                              |
| `docs/diagrams/ontology-tree.md`               | Add the `retired` seed under the Attribute Literals sub-group                                                                          |
| `TASKS.md`                                     | Mark node-deletion slice A designed; add the two follow-up tasks (§9)                                                                  |

`delete_node/1` and `check_category_guard/1` are intentionally **not** in
this list.

---

## 9. Dependencies, ordering, and follow-ups

1. **Transaction-layering seam** (`transaction/1`) — already merged (PR
   #41).
2. This slice — `retire_node` + `unretire_node`.
3. **Project boundary** (architectural, `TASKS.md`) — unblocks the later
   hard-delete fast-path for project instances; the reserved `delete_node`
   is where that real delete eventually lands.
4. **Retired-node purge** (background GC, `TASKS.md`) — reclaims retired
   rows once the history/versioning feature defines what is safe to forget.

New follow-up tasks this design adds to `TASKS.md`:

- **Retired rules must not fire** — exclude retired rule nodes at the
  firing read chokepoint (`effective_rules_for_class` /
  `effective_connection_rules`). Deferred from this slice (§4.2).
- **Unify permanent-tier immutability** — `delete_node`'s category-only
  guard (`category_nodes_are_immutable`) is too narrow; categories are not
  the only permanent nodes. When the real `delete_node` lands, its guard
  (and that of `update_node_avps`) should refuse the whole permanent tier,
  consistent with `retire_node`'s `permanent_node_immutable`.

---

## 10. Decision log

All open items from the brainstorm are resolved:

1. `get_node/1` on a retired node → `{error, retired}` (distinguishes
   retired from absent).
2. Operation is named `retire_node/1` (+ `unretire_node/1`); `delete_node`
   is **not** aliased — it is reserved for a future real delete.
3. `retire_node`/`unretire_node` refuse the whole permanent tier
   (`Nref < ?NREF_START`) with the new atom `permanent_node_immutable`;
   `delete_node` and `category_nodes_are_immutable` are untouched; the
   broader-guard unification is a tracked follow-up (§9).
4. Retired rules still firing is a tracked follow-up (§9), not an accepted
   limitation.
