<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Batch `mutate/1` — Tier-3 Entry Point — Design

**Status:** Designed; not yet planned or implemented.

**Context:** The last open follow-up of the write-path transaction-layering
seam (`docs/designs/write-path-transaction-seam-design.md`). The seam
defined three tiers; tiers 1 and 2 are built out (PRs #43–#47). This slice
delivers the **tier-3 batch entry point** the seam sketched:
`mutate([Mutation])` applies a list of mutations atomically in one Mnesia
transaction, composing tier-1 primitives directly.

**Spec citation:** none. The knowledge-network spec
(`docs/TheKnowledgeNetwork.md`) is a data model and is silent on
transaction mechanics. This is infrastructural — it records how a batch of
write-path mutations composes over Mnesia.

---

## 1. Scope

### 1.1 What this slice delivers

A single public function `graphdb_mgr:mutate/1` that applies an ordered
list of mutations **atomically** — all commit or none do — by folding the
seam's tier-1 primitives inside one `graphdb_mgr:transaction/1`.

### 1.2 Mutation set

The batch covers the three write operations that are fully implemented
today and already have (or cleanly yield) tier-1 primitives:

| Mutation         | Tier-1 primitive it dispatches to                        |
| ---------------- | -------------------------------------------------------- |
| `add_relationship` | `graphdb_instance:add_relationship_in_txn/9` (extracted, §4) |
| `retire_node`    | `graphdb_mgr:set_retired_/3` (already exists)            |
| `unretire_node`  | `graphdb_mgr:set_retired_/3` (already exists)            |

### 1.3 Out of scope (deferred, with reasons)

| Item                                      | Why deferred                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `create_instance` / `create_class` / `create_attribute` | No tier-1 write primitives exist; creates allocate node nrefs through a gen_server (cannot run inside a txn) and `create_instance` is entangled with B2–B5 rule firing. A separate, larger slice. |
| `delete_node`, `update_node_avps`         | Both return `{error, not_implemented}` today — nothing to batch.                                   |
| Symbolic back-references between mutations (`create A; relate A→B`) | Requires the create primitives above plus a bootstrap-style symbol table. Out of scope until creates land. |
| Per-mutation indexed error reporting      | Rejected on principle — see §3.3.                                                                  |
| Named composites (e.g. "delete an instance with its parts") | A *separate* tier-3 shape — see §6. Not this slice.                                       |

---

## 2. Mutation grammar

Mutations are **tagged tuples** mirroring the existing public arities of
the operations they batch (no maps — tuples are the codebase's write-API
idiom and pattern-match directly in the fold):

```erlang
{add_relationship, S, C, T, R}                       %% default template, no AVPs
{add_relationship, S, C, T, R, Template}             %% explicit template nref
{add_relationship, S, C, T, R, Template, {Fwd, Rev}} %% + per-direction AVPs
{retire_node,   Nref}
{unretire_node, Nref}
```

The `add_relationship` arities map onto `do_add_relationship`'s
`(TemplateSpec, AVPSpec)` exactly as the public `add_relationship/4,5,6`
do:

| Tuple                                          | `TemplateSpec` | `AVPSpec`     |
| ---------------------------------------------- | -------------- | ------------- |
| `{add_relationship, S, C, T, R}`               | `default`      | `{[], []}`    |
| `{add_relationship, S, C, T, R, Template}`     | `Template`     | `{[], []}`    |
| `{add_relationship, S, C, T, R, Template, AVP}`| `Template`     | `AVP`         |

---

## 3. Contract

### 3.1 Return shape

```erlang
-spec mutate([mutation()]) -> {ok, [Result]} | {error, term()}.
```

- **Success:** `{ok, [Result]}` — one element per mutation, in list order,
  each the underlying operation's **native success value**. All three
  operations return `ok` today (`do_add_relationship` returns `ok`, not the
  id pair), so a successful batch is `{ok, [ok, ok, …]}`. The list length
  confirms every mutation applied.
- **Failure:** `{error, Reason}` — the **bare** domain reason of the first
  mutation that aborts (`not_found`, `{endpoint_retired, X}`,
  `permanent_node_immutable`,
  …). The **whole batch is rolled back** (atomicity); no partial effects
  survive.
- **Empty batch:** `mutate([]) -> {ok, []}` (vacuous, no transaction
  opened).

### 3.2 Why a list, and why opaque

A generic batch cannot return each operation's bespoke solo shape because
those shapes are heterogeneous. The aggregate `{ok, [Result]}` is the
minimum a batch can be; the *elements* are each op's native value, so a
direct caller sees no surprises inside the list.

The error is **bare**, not `{error, {Index, Reason}}`, by design. Every
solo operation returns `{error, Reason}` with a bare domain reason. Wrapping
the reason in an index would change the reason *structure* — a caller that
matches `{error, not_found}` today would have to rewrite to
`{error, {_, not_found}}`. That destructuring is itself a form of wrapping.
Keeping the reason bare makes `mutate/1` **drop-in compatible** with the
error-handling callers already write for the solo operations — which is the
whole point of a directly-usable tier-3 entry (it should not require a
mandatory adapter).

### 3.3 Indexed errors: considered and rejected

An earlier draft proposed `{error, {Index, Reason}}` to name *which*
mutation failed. It was rejected for two independent reasons:

1. **Contract (decisive).** Per §3.2 it breaks drop-in compatibility with
   existing `{error, Reason}` handling.
2. **Mechanism (confirms it).** `add_relationship`'s failures abort with a
   *bare* reason deep inside `validate_arc_endpoints_in_txn` /
   `validate_template_scope_in_txn` (shipped in PR #45), nowhere near the
   fold that knows the index. `mnesia:abort(Reason)` is
   `exit({aborted, Reason})` (OTP 28.5 `mnesia.erl:700`), and mnesia's
   **deadlock-restart signal uses the same shape** —
   `exit({aborted, #cyclic{}})` / `{node_not_running,_}` / `{bad_commit,_}`
   (`mnesia_tm.erl:908–913`). A `catch exit:{aborted, R}` at the fold to
   attach the index would also swallow the restart signal, converting a
   retryable deadlock into a hard failure. Avoiding that means either
   re-raising mnesia's internal restart records (couples to `mnesia.hrl`
   internals) or tracking the index in the process dictionary. Neither is
   warranted once the contract argument has already settled the question.

Callers who need to localise a failure keep batches short or bisect.

### 3.4 Read-your-writes ordering

Mutations apply in **list order** inside one transaction, so each sees the
*uncommitted* writes of those before it. Concretely,
`[{retire_node, X}, {add_relationship, X, C, T, R}]` aborts with
`{endpoint_retired, X}` (the relationship's endpoint validation —
`validate_arc_endpoints_in_txn` at `graphdb_instance.erl:1248` — sees `X`
already carrying the uncommitted `retired` marker) and rolls back **both**
mutations — `X` is not retired after the call. This is the
correct, predictable semantics and is covered by a test (§7).

---

## 4. The one refactor: extract `add_relationship_in_txn/9`

`retire`/`unretire` already dispatch to a tier-1 primitive
(`graphdb_mgr:set_retired_/3` — bare mnesia, aborts on failure, takes the
`retired` attr nref as a parameter). `add_relationship` does not yet: its
in-transaction body is inline in `do_add_relationship/7`, and it reads two
seeded attr nrefs (`target_kind_avp_nref`, `retired_nref`) from the
`graphdb_instance` gen_server state.

Apply the **"add, don't rewrap"** pattern from PRs #44/#45: extract the
transaction body verbatim into an exported tier-1 primitive that takes the
seeds and the pre-allocated id pair as parameters:

```erlang
%% Tier-1. Must run inside an active mnesia transaction. Aborts on failure.
-spec add_relationship_in_txn(IdPair, S, C, T, R, TemplateSpec, AVPSpec,
                              TkAttr, RetAttr) -> ok.
add_relationship_in_txn({_Id1, _Id2} = IdPair, SourceNref, CharNref,
        TargetNref, ReciprocalNref, TemplateSpec, AVPSpec, TkAttr, RetAttr) ->
    ok = validate_arc_endpoints_in_txn(SourceNref, CharNref, TargetNref,
        ReciprocalNref, TkAttr, RetAttr),
    {SourceClass, TargetClass} =
        resolve_arc_classes_in_txn(SourceNref, TargetNref),
    TemplateNref = resolve_template_in_txn(TemplateSpec, SourceClass),
    ok = graphdb_class:validate_template_scope_in_txn(TemplateNref,
        SourceClass, TargetClass),
    Rows = build_connection_rows(IdPair, SourceNref, CharNref, TargetNref,
        ReciprocalNref, TemplateNref, AVPSpec),
    lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
        Rows).
```

`do_add_relationship/7` then becomes a thin tier-2 wrapper that is
**byte-for-byte behaviour-identical** to today — it reads `TkAttr`/`RetAttr`
from `State`, allocates the id pair up-front (outside the txn, as now), and
runs the primitive through `transaction/1`:

```erlang
do_add_relationship(S, C, T, R, TemplateSpec, AVPSpec, State) ->
    TkAttr  = State#state.target_kind_avp_nref,
    RetAttr = State#state.retired_nref,
    IdPair  = rel_id_server:get_id_pair(),
    case graphdb_mgr:transaction(fun() ->
            add_relationship_in_txn(IdPair, S, C, T, R, TemplateSpec,
                AVPSpec, TkAttr, RetAttr)
        end) of
        {ok, ok}         -> ok;
        {error, _} = Err -> Err
    end.
```

No phase logic changes; the existing `add_relationship` suite must stay
green unchanged, which is the proof the extraction preserves behaviour.

---

## 5. Architecture — three phases

`graphdb_mgr:mutate/1` is a **plain exported function**, not a
`gen_server:call` — exactly like `transaction/1`. `mnesia:transaction/1`
runs in the *calling* process, and the pre-pass makes gen_server calls to
*other* servers (`graphdb_attr`, `rel_id_server`), so routing `mutate`
itself through the `graphdb_mgr` process would needlessly serialise batches
and risk deadlock.

### Phase 1 — static validation (no DB, no allocation)

Walk the list once. For each element:

- check tuple shape/arity against the §2 grammar; a malformed term →
  `{error, {bad_mutation, M}}`;
- for `retire_node`/`unretire_node`, apply the permanent-tier arithmetic
  guard (`Nref >= ?NREF_START`, else `{error, permanent_node_immutable}`) —
  the same static guard `set_retired/3` applies in the solo path.

This fails fast **before** any nref or rel-id is allocated, so a malformed
batch wastes no resources. `mutate([])` short-circuits to `{ok, []}` here.

### Phase 2 — resource pre-pass (gen_server calls, outside the txn)

For a non-empty, validated batch:

- resolve `{TkAttr, RetAttr}` **once** via `graphdb_attr:seeded_nrefs/0`
  (the identical source `graphdb_instance:init/1` reads its
  `target_kind`/`retired` seeds from);
- allocate **one rel-id pair per `add_relationship`** via
  `rel_id_server:get_id_pair/0`.

Produces a list of *prepared* mutations, each term paired with the
resources its tier-1 primitive needs. As with the solo `add_relationship`
path, a later abort orphans any rel-id pairs already allocated — harmless,
per the allocate-outside-transaction doctrine (PR #45).

### Phase 3 — one transaction

`graphdb_mgr:transaction(fun() -> [dispatch(P) || P <- Prepared] end)`,
folding the prepared list **in order**:

| Prepared mutation | Dispatch                                                                 |
| ----------------- | ------------------------------------------------------------------------ |
| add_relationship  | `graphdb_instance:add_relationship_in_txn(IdPair, S,C,T,R, TemplateSpec, AVPSpec, TkAttr, RetAttr)` |
| retire_node       | `set_retired_(Nref, true,  RetAttr)`                                     |
| unretire_node     | `set_retired_(Nref, false, RetAttr)`                                     |

Each primitive returns `ok` or calls `mnesia:abort(Reason)`. The first
abort unwinds the whole transaction; `transaction/1` maps `{aborted, Reason}`
→ `{error, Reason}` (the bare reason, §3.1). On success the list comprehension
yields `[ok, ok, …]`, and `transaction/1` maps `{atomic, L}` → `{ok, L}`.

`set_retired_/3` is module-local to `graphdb_mgr`, so `mutate/1` (same
module) calls it directly. `add_relationship_in_txn/9` is a plain exported
function on `graphdb_instance`, called directly inside the transaction
fun — the seam's intended cross-module tier-1 composition.

---

## 6. Relationship to named composites

The seam lists two tier-3 shapes: this generic `mutate([Mutation])` **and**
named composites such as "delete an instance with its parts." They are
distinct and both legitimate:

- **Generic `mutate/1`** — ad-hoc, list-driven, returns the generic
  aggregate contract (§3). Directly usable; no mandatory wrapper.
- **A named composite `F`** — a specific recurring sequence with a *bespoke*
  return matching its domain (e.g. `ok | {error, Reason}`). It composes the
  tier-1 primitives **directly** inside one `transaction/1` and returns its
  own shape. It does **not** route through generic `mutate/1`, precisely
  because it wants a return that the generic aggregate cannot provide.

This slice builds only the generic `mutate/1`. Named composites, if any are
needed later, are separate slices that reuse the same tier-1 primitives.

---

## 7. Testing

New `mutate` cases (CT, against the real `nodes`/`relationships` scratch
tables, per the suite's per-case isolation):

1. **Empty batch** — `mutate([])` → `{ok, []}`; no transaction side effects.
2. **Single `add_relationship`** — `{ok, [ok]}`; both directed rows present.
3. **Single `retire_node`** / **`unretire_node`** — `{ok, [ok]}`; marker
   set / cleared.
4. **Mixed all-succeed** — e.g. two `add_relationship` + one `retire_node`
   → `{ok, [ok, ok, ok]}`; every effect present after commit.
5. **Atomic rollback** — a valid `add_relationship` followed by
   `{retire_node, NonexistentNref}` → `{error, not_found}`, **and** the
   relationship rows the first mutation wrote are **absent** (the batch
   rolled back). This is the core atomicity guarantee.
6. **Read-your-writes rollback** —
   `[{retire_node, X}, {add_relationship, X, C, T, R}]` →
   `{error, {endpoint_retired, X}}`, and `X` is **not** retired afterward
   (§3.4).
7. **Malformed term** — a batch containing a malformed tuple →
   `{error, {bad_mutation, M}}`, and the well-formed mutation that preceded
   it in the same batch left **no rows written** (phase 1 rejects the whole
   batch before phase 2/3 run). The "no rel-id allocated" property is real
   but not asserted: `rel_id_server` exposes no non-consuming peek, and
   orphaned rel-ids are harmless by design (allocate-outside-transaction
   doctrine), so the test asserts the *contract* — error reason + no rows —
   not the internal allocation count.
8. **Permanent-tier guard** — `{retire_node, NrefBelowStart}` →
   `{error, permanent_node_immutable}`; nothing written.

Plus **behaviour preservation:** the existing `add_relationship` CT suite
must pass unchanged, proving the §4 extraction is byte-identical. A direct
test of `add_relationship_in_txn/9` via `transaction/1` is optional (the
solo suite already exercises every branch through `do_add_relationship/7`).

---

## 8. Files touched

| File                                       | Change                                                              |
| ------------------------------------------ | ------------------------------------------------------------------- |
| `apps/graphdb/src/graphdb_instance.erl`    | Extract + export tier-1 `add_relationship_in_txn/9`; `do_add_relationship/7` delegates (§4) |
| `apps/graphdb/src/graphdb_mgr.erl`         | Add exported `mutate/1` + phase-1/phase-2 helpers; reuse `set_retired_/3` |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`  | New `mutate` test group (§7)                                        |
| `apps/graphdb/CLAUDE.md`                   | `graphdb_mgr` API blurb: `mutate/1`; `graphdb_instance` tier-1 list: `add_relationship_in_txn/9` |
| `docs/Architecture.md`                     | One line noting the tier-3 `mutate/1` public entry on the write path |
| `TASKS.md`                                 | Flip "Batch `mutate([Mutation])`" to IMPLEMENTED                    |

---

## 9. Open items

None. Scope, grammar, contract (opaque, bare-reason), the three-phase
architecture, the single behaviour-preserving extraction, and the test plan
are fixed. The name `mutate/1` is confirmed.
