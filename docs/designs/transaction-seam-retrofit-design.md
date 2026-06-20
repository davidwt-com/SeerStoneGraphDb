# Transaction-Seam Retrofit — Design

**Status:** Approved (design) — not yet planned/implemented
**Date:** 2026-06-20
**Author:** David W. Thomas (with Claude)
**Slice:** Transaction-layering seam, tracked follow-up 1 of 2

## Background

The write-path transaction-layering seam shipped in PR #41 (`81b2962`,
`docs/designs/write-path-transaction-seam-design.md`). It defines three tiers:

- **Tier 1** — in-transaction primitives: bare mnesia ops, signal failure via
  `mnesia:abort/1`, never open their own transaction, so they compose.
- **Tier 2** — single-op public API: owns exactly one transaction via
  `graphdb_mgr:transaction/1`.
- **Tier 3** — batch/composite: wraps one transaction, calls tier-1 primitives
  directly, never tier-2 (no nested transactions).

`graphdb_mgr:transaction/1` is the seam's helper — a plain exported function
(not a `gen_server:call`, because `mnesia:transaction/1` runs in the calling
process):

```erlang
transaction(Fun) ->
    case mnesia:transaction(Fun) of
        {atomic,  Result} -> {ok, Result};
        {aborted, Reason} -> {error, Reason}
    end.
```

`TASKS.md` records two tracked follow-ups under "Transaction-layering seam":

1. **Retrofit existing write ops** onto the primitive/wrapper layering —
   uniform convention, no behaviour change. *(This document.)*
2. **Batch `mutate([Mutation])`** — the tier-3 entry point. *(Separate spec;
   consumes the primitives this retrofit produces.)*

The two have a producer/consumer relationship: this retrofit produces the
clean tier-1 primitives; `mutate/1` composes them. Hence retrofit first.

## Goal

Make `graphdb_mgr:transaction/1` the **single** place in the `graphdb`
application that pattern-matches `{atomic, _}` / `{aborted, _}`. Every other
`mnesia:transaction` call site is reshaped into a tier-1 primitive invoked
through `transaction/1`, with its public return shape and error terms
unchanged.

## Scope

A full sweep of every hand-rolled `mnesia:transaction` call site across the
six graphdb workers, plus the two assertion-form sites in the bootstrap
loader — **40 sites total** (counts in the inventory below).

### Non-goals (explicitly out)

| Out of scope                           | Why / where it goes                                                                                                                                                                  |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Atomic `add_relationship`              | Needs `graphdb_class` tier-1 in-txn read primitives (its reads are `gen_server:call` today). Its own slice, sequenced with / before `mutate/1`, which wants those primitives anyway. |
| Batch `mutate/1`                       | The next spec (tracked follow-up 2).                                                                                                                                                 |
| Any public return-shape / error change | This is a behaviour-preserving refactor.                                                                                                                                             |

`add_relationship` currently runs **four separate transactions** (validate →
resolve classes → resolve template → write); it is not atomic today. This
retrofit converts each of those sites' `{atomic/aborted}` mapping to the
convention but does **not** merge them — making the operation atomic is the
deferred slice above.

## The convention

- **Tier-1 primitive** — body is bare mnesia ops; returns the operation's
  natural success value; signals a *rollback-worthy* failure via
  `mnesia:abort(Reason)` using the **exact** `Reason` term the public contract
  already exposes. Documented "Must run inside an active mnesia transaction."
- **Tier-2 wrapper** — calls `graphdb_mgr:transaction(fun() -> Primitive(...)
  end)`, then projects `{ok, Value}` to the public shape and propagates
  `{error, Reason}` in whatever form that site's contract already uses.
- **Single mnesia mapping point** — only `transaction/1` matches
  `{atomic, _}` / `{aborted, _}`. After this slice, `grep "mnesia:transaction"`
  over `apps/graphdb/src/` should return only `transaction/1`'s own definition.

## Conversion taxonomy

Every site maps to exactly one recipe. The recipe is determined by the site's
current `{atomic,_}` / `{aborted,_}` arms.

| Shape                | Current arm(s)                                          | Recipe                                                                                                                |
| -------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Identity value/list  | `{atomic, V} -> {ok, V}`                                | `graphdb_mgr:transaction(F)` (the mapping is already identity)                                                        |
| Unwrap ok            | `{atomic, ok} -> ok`                                    | wrapper `{ok, ok} -> ok`                                                                                              |
| Tagged success       | `{atomic, ok} -> {ok, Nref}`                            | fun returns `ok`; wrapper `{ok, ok} -> {ok, Nref}` (Nref from outer scope)                                            |
| Projection-in-fun    | `{atomic, {value, R}} -> {ok, X}; false -> not_found`   | move projection into the fun (fun returns `{ok, X}` \| `not_found`); wrapper `{ok, Result} -> Result`                 |
| Collapse idempotent  | `{atomic, ok} -> ok; already_exists -> ok`              | fun returns `ok` in both branches; wrapper `{ok, ok} -> ok`                                                           |
| Abort-relocation     | `{atomic, {[], _, _, _}} -> {error, ...}` (tuple-match) | relocate each domain failure into the fun via `mnesia:abort(ExactReason)`; fun returns `ok`; wrapper `{ok, ok} -> ok` |
| Throw-on-abort       | `{aborted, R} -> throw({error, R})`                     | wrapper re-throws: `{error, R} -> throw({error, R})` (combined with the value recipe)                                 |
| Reply-in-handle_call | `{atomic, ok} -> {reply, ok, State}`                    | wrapper builds the reply tuple from `{ok, _}` / `{error, _}`                                                          |
| Side-effects-after   | `{atomic, ok} -> <more work; NewState>`                 | wrapper runs the same post-commit work on `{ok, ok}`                                                                  |
| Assertion form       | `{atomic, ok} = mnesia:transaction(..)`                 | `{ok, ok} = graphdb_mgr:transaction(..)` (preserves crash-on-failure)                                                 |

## Behaviour-preservation traps

This is not a blind find-and-replace. Four traps must be honored per site:

1. **Failure propagation is not uniform.** Three contracts coexist —
   return `{error, R}`, `throw({error, R})` (the init/seed helpers in
   `graphdb_attr`, `graphdb_language`, `graphdb_rules`), and
   `{reply, {error, R}, State}` (`graphdb_language` `set_labels`). Each
   wrapper must reproduce *its* site's contract; do not normalize them.

2. **`{atomic, {error, _} = E} -> E` must NOT become an abort.**
   `graphdb_class:832` lets the fun *return* `{error, _}` as a committed
   value (no rollback). Converting it to `mnesia:abort` would change rollback
   semantics. Preserve via `{ok, {error, _} = E} -> E`.

3. **Abort-swallow sites.** `graphdb_class:704`
   (`do_find_template_by_name`) and `graphdb_instance:1760`
   (`resolve_from_connected`) map `{aborted, _} -> not_found` — a real mnesia
   abort is swallowed to a domain value. Preserve via
   `{ok, Result} -> Result; {error, _} -> not_found`.

4. **Abort-relocation must use the exact `Reason` term** so the public error
   is byte-for-byte unchanged (e.g. `mnesia:abort({source_not_found,
   SourceNref})`). The relocated funs are read-only, so they are retry-safe
   under mnesia's lock-conflict re-execution.

## Inventory

All 40 sites, grouped by module, with line, function, and recipe. The
implementation plan repeats this with the exact before/after code per site.

### `graphdb_mgr` (4)

| Line | Function                            | Recipe                                                          |
| ---- | ----------------------------------- | --------------------------------------------------------------- |
| 317  | `verify_caches/0`                   | Projection (read-only): `{ok, []} -> ok; {ok, M} -> {error, M}` |
| 338  | `rebuild_caches/0`                  | Unwrap ok                                                       |
| 502  | `do_get_relationships/2` (outgoing) | Identity                                                        |
| 509  | `do_get_relationships/2` (incoming) | Identity                                                        |

### `graphdb_instance` (7)

| Line | Function                      | Recipe                                                                  |
| ---- | ----------------------------- | ----------------------------------------------------------------------- |
| 579  | `execute/5`                   | Result-building on both arms (success report vs `report_not_attempted`) |
| 1238 | `validate_arc_endpoints/6`    | Abort-relocation (the marquee trap-4 site)                              |
| 1394 | `write_connection_arcs/6`     | Unwrap ok                                                               |
| 1453 | `do_write_class_membership/2` | Collapse idempotent (`already_exists -> ok`)                            |
| 1487 | `do_class_of/1`               | Projection-in-fun                                                       |
| 1518 | `do_children/1`               | Identity list                                                           |
| 1760 | `resolve_from_connected/2`    | Side-effects-after + abort-swallow → `not_found`                        |

### `graphdb_attr` (9)

| Line | Recipe                                                                           |
| ---- | -------------------------------------------------------------------------------- |
| 499  | Projection-in-fun (`{value} -> {ok, Nref}; false -> not_found`) + throw-on-abort |
| 562  | Tagged success (`{ok, Nref}`)                                                    |
| 657  | Tagged success (`{ok, {FwdNref, RevNref}}`)                                      |
| 685  | Projection (multi-clause read: `{ok, N}` / `not_an_attribute` / `not_found`)     |
| 700  | Identity list                                                                    |
| 713  | Identity list                                                                    |
| 755  | Projection-in-fun + side-effects-after (nested `find_attribute_type_value`)      |
| 799  | Collapse (`ok` / `_Other -> ok`) + throw-on-abort                                |
| 883  | Unwrap ok + throw-on-abort                                                       |

### `graphdb_class` (8)

| Line | Recipe                                                                     |
| ---- | -------------------------------------------------------------------------- |
| 499  | Tagged success (txn value ignored: `{atomic, _Writes} -> {ok, ClassNref}`) |
| 624  | Collapse idempotent                                                        |
| 682  | Tagged success (`{ok, TemplateNref}`)                                      |
| 704  | Projection-in-fun + abort-swallow → `not_found` (trap 3)                   |
| 738  | Identity list                                                              |
| 832  | Collapse idempotent + fun-returns-`{error, _}`-value (trap 2)              |
| 869  | Unwrap ok                                                                  |
| 911  | Identity list                                                              |

### `graphdb_language` (7)

| Line | Recipe                                                                      |
| ---- | --------------------------------------------------------------------------- |
| 310  | Reply-in-handle_call (`set_labels`)                                         |
| 395  | Projection-in-fun + throw (`false -> throw({class_not_found, Name})`)       |
| 447  | Tagged success + throw                                                      |
| 508  | Tuple-value (`{atomic, {CM, DM}} -> {CM, DM}`) + throw                      |
| 629  | Side-effects-after (`register_language`: `ensure_overlay_table` + NewState) |
| 692  | Side-effects-after (`register_dialect`)                                     |
| 734  | Projection (`not_found` / `{ok, Code}`)                                     |

### `graphdb_rules` (3)

| Line | Recipe                                          |
| ---- | ----------------------------------------------- |
| 608  | Tagged success (`{atomic, ok} -> Nref`) + throw |
| 654  | Projection-in-fun + throw                       |
| 857  | Tagged success (`{ok, RuleNref}`)               |

### `graphdb_bootstrap` (2)

| Line | Recipe                                    |
| ---- | ----------------------------------------- |
| 509  | Assertion form (node writes)              |
| 546  | Assertion form (relationship-pair writes) |

## Testing standard

Two-part:

1. **The existing suite is the behaviour oracle.** All 537 tests
   (432 CT + 105 EUnit) must stay green with **zero test-expectation edits**.
   Any required edit signals an unintended behaviour change — a defect, not a
   test to update.

2. **New or reshaped code paths require new, passing tests.** A pure 1:1
   refactor of an existing path rides the existing tests. Where a conversion
   creates a branch the suite does not already exercise, that branch gets its
   own test. Each task includes a **coverage check** per converted site and
   adds a test wherever the converted path is otherwise unverified. The likely
   spots:

   - **Abort-relocation arms** (`validate_arc_endpoints`): each domain failure
     now flows through `mnesia:abort(Reason)`. Every relocated arm
     (`source_not_found`, `target_not_found`, `characterization_not_found`,
     `reciprocal_not_found`, `endpoint_retired`, characterization/reciprocal
     "not an attribute", `target_kind_mismatch`) must have a test asserting the
     **exact** error term. Any arm not already covered → add a test.
   - **Collapse / projection sites** where a branch (`already_exists -> ok`,
     `false -> not_found`) is not currently asserted → add a test that locks
     it.
   - Any tier-1 primitive that becomes **independently reachable** in this
     slice (none planned — primitives stay internal, invoked only via their
     wrapper; flagged so the plan re-checks).

The coverage check doubles as a guard against the four traps: if a
relocated/collapsed branch has no test, the conversion's behaviour-preservation
is unproven — so write the test first, then convert.

Principle: **behaviour-preserving conversions ride existing tests; every new
or newly-shaped path gets a new, passing test.**

## Risks

| Risk                                            | Mitigation                                                                                                                 |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| The four traps (silent behaviour change)        | Each affected site is flagged by recipe in the inventory; the coverage check forces a test before conversion               |
| Throw-vs-return contract mismatch               | Trap 1 is called out per affected module; the plan repeats the exact contract per site                                     |
| Large mechanical diff hiding a subtle change    | Convert and run the full suite **per module**, not once at the end                                                         |
| Init-time call into `transaction/1` (bootstrap) | `transaction/1` is a plain function, not a `gen_server:call`; safe to call from `graphdb_mgr:init/1`'s bootstrap load path |

## Relationship to the other seam follow-ups

- **Atomic `add_relationship`** (deferred slice): once `graphdb_class` exposes
  tier-1 in-transaction read primitives, the four `add_relationship`
  transactions can collapse into one. The primitives this retrofit produces
  in `graphdb_instance` are the write half of that future work.
- **Batch `mutate/1`** (follow-up 2): the tier-3 entry point composes the
  tier-1 primitives this retrofit establishes. Brainstormed as its own spec
  after this slice lands.

## References

- `docs/designs/write-path-transaction-seam-design.md` — the seam (PR #41)
- `TASKS.md` — "Transaction-layering seam" section (tracked follow-ups)
- `apps/graphdb/src/graphdb_mgr.erl:291` — `transaction/1`
- `apps/graphdb/src/graphdb_mgr.erl:551` — `set_retired/3` + `set_retired_/3`,
  the reference tier-1/tier-2 pair (PR #42)
