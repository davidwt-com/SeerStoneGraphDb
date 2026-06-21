<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Atomic `add_relationship` — Design

**Status:** Approved (design) — not yet planned/implemented
**Date:** 2026-06-21
**Author:** David W. Thomas (with Claude)
**Slice:** Atomic `add_relationship`, PR 2 of 2 (the collapse)

## Background

PR 1 (`ad030f6`, `docs/designs/atomic-add-relationship-primitives-design.md`)
added the tier-1 in-transaction read primitives to `graphdb_class`
(`default_template_in_txn/1`, `get_template_in_txn/1`,
`class_in_ancestry_in_txn/2`) without touching any existing path. This PR
spends them: it collapses `graphdb_instance:do_add_relationship/7`'s five
separate transactions into one.

The three-tier transaction seam (PR #41 / PR #43,
`docs/designs/transaction-seam-retrofit-design.md`):

- **Tier 1** — in-transaction primitives: bare mnesia ops, signal failure via
  `mnesia:abort/1`, never open their own transaction, so they compose.
- **Tier 2** — single-op public API: owns exactly one transaction via
  `graphdb_mgr:transaction/1`.
- **Tier 3** — batch/composite: wraps one transaction, calls tier-1 primitives
  directly.

`add_relationship` is a tier-2 operation that today is *five* transactions
instead of one. This PR makes it own exactly one.

## The honest reframe (carried from PR 1)

`do_add_relationship/7` runs four read-only phases, each in its own
transaction or gen_server call, then writes in a fifth:

1. `validate_arc_endpoints` — read the four endpoint nodes (own txn)
2. `resolve_arc_classes` — `do_class_of/1` ×2 (two txns)
3. `resolve_template` — `graphdb_class:default_template/1` (gen_server txn)
4. `validate_template_scope` — `graphdb_class:get_template/1` +
   `class_in_ancestry/2` ×2 (gen_server reads)
5. `write_connection_arcs` — the two directed rows (fifth txn)

**Only phase 5 writes.** Phases 1–4 are read-only, so a failure in any of
them never reaches the write — **there is no partial-write bug today.** Both
rows already write together in one transaction.

Collapsing therefore does not fix a bug. It buys exactly one thing:

- **TOCTOU isolation** — validation and the write share one consistent
  snapshot, closing the window where another process retires an endpoint,
  deletes a class, or changes a template *between* validation and write.

TOCTOU isolation is protection against a *race*. A race has no deterministic
CT test (see Testing). The behaviour every test can observe is unchanged.

## Goal

Make `do_add_relationship/7` own exactly one transaction, preserving every
externally observable behaviour, and give the two currently-uncovered error
atoms (`source_has_no_class`, `target_has_no_class`) test coverage.

## Refactor shape

A grep over `apps/graphdb/src/` confirms the four phase helpers
(`validate_arc_endpoints`, `resolve_arc_classes`, `resolve_template`,
`validate_template_scope`) are each **single-use** — referenced only at their
definition and the one call site in `do_add_relationship/7`. That settles the
shape:

| Helper                            | Treatment                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `validate_arc_endpoints/6`        | Convert in place to in-txn: drop the `graphdb_mgr:transaction` wrapper, lift its already-abort-based body |
| `resolve_arc_classes/2`           | Convert in place: use `class_of_in_txn/1`; `not_found` arms become `mnesia:abort/1`                      |
| `resolve_template/2`              | Convert in place: `default` arm uses `default_template_in_txn/1`, aborts on `not_found`                  |
| `validate_template_scope/3`       | Convert in place: use `get_template_in_txn/1` + `class_in_ancestry_in_txn/2`, abort on failure           |
| `do_class_of/1`                   | **Add, don't rewrap** — see below                                                                        |

`do_class_of/1` is the one exception. It has a public caller —
`handle_call({class_of, Nref}, …)` at line 425 — so it cannot be converted in
place. Add a new private `class_of_in_txn/1` (bare
`mnesia:index_read(relationships, InstanceNref, #relationship.source_nref)` +
`lists:search` for `?ARC_INST_TO_CLASS`, returning `{ok, ClassNref} |
not_found`); leave `do_class_of/1` untouched. This mirrors PR 1's
add-don't-rewrap decision and the same rationale: the gen_server path keeps
its own transaction for its own caller.

Phases 3 and 4 already have their primitives from PR 1
(`default_template_in_txn/1`, `get_template_in_txn/1`,
`class_in_ancestry_in_txn/2`). No new `graphdb_class` work in this PR.

## The collapsed flow

`do_add_relationship/7`:

1. Allocate the relationship-id pair **up-front**, outside the transaction:
   `{Id1, Id2} = rel_id_server:get_id_pair()`. Allocation is a gen_server call
   and must never run inside an mnesia transaction fun (it would risk blocking,
   and a transaction retry would re-call it). This is the
   allocate-outside-transaction doctrine already followed by the B4 connection
   firing path. A validation abort now orphans one id pair — harmless and
   accepted.
2. Run one `graphdb_mgr:transaction/1` fun, in this order:
   - `validate_arc_endpoints` (in-txn) — reads four nodes, aborts on any
     endpoint/kind/retired/target-kind violation
   - `resolve_arc_classes` (in-txn) — `class_of_in_txn/1` ×2, aborts
     `{source_has_no_class, _}` / `{target_has_no_class, _}`
   - `resolve_template` (in-txn) — yields `TemplateNref`, aborts
     `no_default_template`
   - `validate_template_scope` (in-txn) — aborts `{invalid_template, …}` /
     `{template_class_not_in_ancestry, …}`
   - build the two rows with the pre-allocated `{Id1, Id2}` and resolved
     `TemplateNref`, then `mnesia:write` both
3. Map the result: `{ok, ok}` → `ok`; `{error, Reason}` → `{error, Reason}`.

The public contract (`add_relationship/4,5,6` → `ok | {error, term()}`) is
unchanged.

### `build_connection_rows` split (DRY)

`build_connection_rows/6` currently allocates the id pair *and* builds the
rows. Split it so allocation is the caller's choice:

- `build_connection_rows/7({Id1, Id2}, S, C, T, R, TemplateNref, AVPSpec)` —
  pure builder, no allocation. The id pair rides as a single tuple argument so
  the arity is `/7` (the existing `/6` plus one tuple arg).
- `build_connection_rows/6` — allocates `{Id1, Id2}` via
  `rel_id_server:get_id_pair()` then delegates to `/7`. Unchanged for its
  callers.

The B4 callers (`build_connection_rows/6` at line 767, `write_connection_arcs`
at line 1392) are untouched. The collapsed `do_add_relationship` calls the pure
builder inside its transaction with the up-front-allocated pair.

`write_connection_arcs/6` stays — it is still used by the B4 auto post-commit
connection pass (line 864). It is simply no longer on the `add_relationship`
path.

## Behaviour preservation

Same discipline as the PR #43 transaction-seam retrofit:

- **Phase order is preserved** inside the single fun, so an input violating
  multiple constraints reports the same first error it does today.
- `graphdb_mgr:transaction/1` maps `{aborted, Reason}` → `{error, Reason}`
  byte-identically to the current inline mapping, so an in-fun
  `mnesia:abort(Reason)` surfaces as the same `{error, Reason}`.
- `validate_arc_endpoints`' body is already abort-based, so every endpoint
  atom (`source_not_found`, `target_not_found`, `characterization_not_found`,
  `reciprocal_not_found`, `endpoint_retired`, `*_not_an_attribute`,
  `target_kind_mismatch`) is preserved free when the body is lifted.
- `source_has_no_class` / `target_has_no_class` convert from `{error, _}`
  return values to `mnesia:abort/1` with byte-identical Reason terms.
- The nested Reason inside `{invalid_template, TemplateNref, Reason}` is
  preserved: `get_template_in_txn` returns the same inner `{error,
  not_a_template | not_found}` as the gen_server `get_template`.

## Testing

The collapse buys TOCTOU isolation — a race — which has **no deterministic CT
test**. There is no partial-write state to expose and both rows already write
in one transaction. An "atomicity test" here would either be flaky or assert
nothing. **It will not be written.**

The test deliverable is exactly:

- **Two new tests** in `graphdb_instance_SUITE` for the previously-uncovered
  error atoms: `add_relationship` with a source that has no class →
  `{error, {source_has_no_class, SourceNref}}`; with a target that has no
  class → `{error, {target_has_no_class, TargetNref}}`.
- **The entire existing `add_relationship` suite passing unchanged** — this is
  the behaviour-preservation proof. No existing test is modified.

## Non-goals

- `mutate([Mutation])` — the tier-3 batch entry point. Separate, later slice;
  reuses the same primitives this PR exercises.
- Converging the default-template name-search duplication noted in PR 1's
  design (the gen_server `do_find_template_by_name` vs `default_template_in_txn`
  copies). Out of scope; deliberately not converged.
- Any change to `graphdb_class` — its primitives are complete as of PR 1.
