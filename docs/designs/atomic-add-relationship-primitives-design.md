<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Tier-1 Class-Read Primitives — Design

**Status:** Approved (design) — not yet planned/implemented
**Date:** 2026-06-20
**Author:** David W. Thomas (with Claude)
**Slice:** Atomic `add_relationship`, PR 1 of 2 (primitives-only)

## Background

The write-path transaction-layering seam shipped in PR #41 (`81b2962`,
`docs/designs/write-path-transaction-seam-design.md`) and was swept across
all 40 hand-rolled transaction sites in PR #43 (`6d48d80`,
`docs/designs/transaction-seam-retrofit-design.md`). It defines three tiers:

- **Tier 1** — in-transaction primitives: bare mnesia ops, signal failure via
  `mnesia:abort/1`, never open their own transaction, so they compose.
- **Tier 2** — single-op public API: owns exactly one transaction via
  `graphdb_mgr:transaction/1`.
- **Tier 3** — batch/composite: wraps one transaction, calls tier-1 primitives
  directly, never tier-2 (no nested transactions).

`TASKS.md` tracks two seam follow-ups still open: **Atomic `add_relationship`**
and **Batch `mutate/1`**. Both are blocked on the same thing — `graphdb_class`
does not expose its reads (`default_template`, `get_template`,
`class_in_ancestry`) as tier-1 primitives. Today they are `gen_server:call`s,
which cannot run inside an Mnesia transaction owned by another process.

## The honest reframe

`graphdb_instance:do_add_relationship/7` runs four sequential phases:

1. `validate_arc_endpoints` — read the four endpoint nodes (its own txn)
2. `resolve_arc_classes` — `do_class_of/1` ×2 (two txns)
3. `resolve_template` — `graphdb_class:default_template/1` (gen_server txn)
4. `validate_template_scope` — `graphdb_class:get_template/1` +
   `class_in_ancestry/2` ×2 (gen_server reads)

…then `write_connection_arcs` writes the two directed rows in a **fifth**
transaction. **Only that last transaction writes.** Phases 1–4 are all
read-only, so a failure in any of them never reaches the write — **there is no
partial-write bug today.**

Collapsing the phases into one transaction therefore does not fix a bug. It
buys two things:

- **TOCTOU isolation** — validation and the write share one consistent
  snapshot, closing the window where another process retires an endpoint,
  deletes a class, or changes a template *between* validation and write.
- **The tier-1 read-primitive library** — the real deliverable, and what
  `mutate/1` needs too.

This design covers **only the primitive library** (PR 1). The
`add_relationship` collapse is PR 2 (see Non-goals).

## Goal

Add three exported, unit-tested, in-transaction read functions to
`graphdb_class` that return results identical to the existing gen_server
reads. **This PR is purely additive** — no existing code path changes; the
539 existing tests are untouched and all new tests are additive.

## The three primitives

Naming convention — this is the first cross-module tier-1 *read* library, so it
sets the pattern: **the `_in_txn` suffix.** Each function assumes it is already
running inside an Mnesia activity and uses bare `mnesia:read` /
`mnesia:index_read` — never `dirty_*`, and never opens its own transaction.

| Primitive                                   | Return contract (identical to gen_server twin)          |
| ------------------------------------------- | ------------------------------------------------------- |
| `default_template_in_txn(ClassNref)`        | `{ok, Nref} \| not_found`                               |
| `get_template_in_txn(Nref)`                 | `{ok, #node{}} \| {error, not_a_template \| not_found}` |
| `class_in_ancestry_in_txn(Cand, ClassNref)` | `boolean()`                                             |

Behavioural notes carried over verbatim from the gen_server twins:

- `class_in_ancestry_in_txn(C, C)` is `true` (self is in its own ancestry);
  the ancestor walk is the BFS over the multi-parent taxonomic DAG, the
  `Classes` category (nref 3) is filtered out, and any lookup error yields
  `false`.
- `default_template_in_txn` looks up the template-kind child of `ClassNref`
  whose class-name AVP (`?NAME_ATTR_CLASS`, nref 19) matches
  `?DEFAULT_TEMPLATE_NAME`; absent → `not_found`.
- `get_template_in_txn` returns `{error, not_a_template}` for a node that
  exists but is not `kind = template`, `{error, not_found}` for a missing nref.

## Add, don't rewrap (the load-bearing decision)

The existing gen_server reads — `do_default_template/1`, `do_get_template/1`,
`do_class_in_ancestry/2` and their `handle_call` clauses — stay **untouched**
for all three. The primitives are **new** functions.

The reason this is not just conservatism: `get_template` and
`class_in_ancestry` use `dirty_read` today, and that is load-bearing.
`graphdb_rules:default_conflict_resolver/0` calls `class_in_ancestry` and is
documented deadlock-safe *because* those reads are dirty. The B5 conflict
resolver runs during `plan_composition_firing` — **outside** any transaction,
before `create_instance`'s write transaction opens. Converting those gen_server
reads to transactional reads would risk a blocking/nested transaction on that
path. So they remain dirty.

`default_template`'s gen_server path is already transactional
(`do_find_template_by_name` wraps a txn), so rewrapping *it* would have been
behaviour-preserving. We considered it (it would remove one duplication) but
chose **uniform add-don't-rewrap** for all three: lowest blast radius, no
existing path touched, and the small duplication is already sanctioned by
project precedent (`is_marked_non_instantiable/2` and `downward_children_by_arc`
are both intentionally duplicated across modules).

Consequence: the default-template name-search walk now exists in two copies —
the gen_server's `do_find_template_by_name` and `default_template_in_txn`. This
duplication is accepted and is **not** converged by PR 2.

## Testing

The existing 539 tests are untouched (nothing they cover changes). New CT cases
go in `graphdb_class_SUITE` — CT, not EUnit, because the primitives must run
inside an Mnesia activity against the bootstrapped schema. Each primitive is
invoked via `graphdb_mgr:transaction(fun() -> graphdb_class:<prim>(...) end)`,
deliberately mirroring the existing gen_server-twin assertions so equivalence
between primitive and gen_server result is demonstrated:

- `default_template_in_txn`: class with a default template → `{ok, _}`; class
  without → `not_found`; abstract (non-instantiable, born without a template)
  class → `not_found`.
- `get_template_in_txn`: a template nref → `{ok, #node{}}`; a non-template node
  (e.g. a class nref) → `{error, not_a_template}`; an unused nref →
  `{error, not_found}`.
- `class_in_ancestry_in_txn`: self → `true`; a direct parent and a transitive
  ancestor → `true`; an unrelated class → `false`; a diamond ancestor → `true`.

## Non-goals (deferred to PR 2)

PR 2 swaps `add_relationship` onto these primitives and collapses its phases
into one transaction. Specifically deferred:

- Collapsing `validate_arc_endpoints` + `resolve_arc_classes` +
  `resolve_template` + `validate_template_scope` + the row write into one
  `graphdb_mgr:transaction/1` fun.
- Converting the `resolve_arc_classes` arms (`source_has_no_class`,
  `target_has_no_class`) from `{error, _}` return values to `mnesia:abort/1`
  with byte-identical Reason terms — and adding their two new tests (those two
  atoms are currently uncovered in `graphdb_instance_SUITE`).
- Allocating the relationship-id pair up-front (outside the single
  transaction), accepting that a validation abort now orphans an id pair —
  harmless under the allocate-outside-transaction doctrine.

`mutate/1` (the tier-3 batch entry point) remains a separate, later slice that
also consumes these primitives.

## Relationship to other follow-ups

This is the unblocking prerequisite shared by both open seam follow-ups in
`TASKS.md`. After this PR, **Atomic `add_relationship` (PR 2)** can proceed
immediately; **Batch `mutate/1`** can reuse the same primitives when it is
taken up.
