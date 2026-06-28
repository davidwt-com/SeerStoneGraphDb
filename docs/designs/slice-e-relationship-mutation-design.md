<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Slice E — Relationship Mutation (`remove_relationship` / `update_relationship`) — Design

## Goal

Complete the relationship write-path. Today only `add_relationship` exists
— there is no way to remove a connection edge or to edit its per-direction
AVPs. Slice E adds:

- `remove_relationship` — atomically delete both directed rows of a logical
  connection edge.
- `update_relationship` — edit the per-direction AVP metadata of an existing
  connection edge.

Both are built on the write-path transaction seam and compose into
`graphdb_mgr:mutate/1`.

## Scope

**Connection arcs only** — the exact mirror of `add_relationship`, which
creates only `kind=connection` rows. This is the decisive scoping choice and
it moots all cache work: the `parents` (composition/taxonomy) and `classes`
(instantiation) caches never hold connection arcs, so removing or editing a
connection touches no cache.

> **Correction to the prior TASKS.md note.** The earlier slice-E sketch said
> `remove_relationship` "fixes the `parents`/`classes` caches on the
> referrers" and "shares the arc-removal primitive with `delete_node`
> (slice A)." Both are aspirational, not current fact: slice A shipped as
> *soft-retire only*, so there is **no** hard-delete arc-removal primitive to
> share, and connection removal needs no cache fix. The cache-touching arc
> operations are `add_parent`/`add_child`/`remove_parent`/`remove_child` (compositional) — recorded as a
> separate follow-up, not part of this slice.

**Out of scope (deferred):**

- **Structural rewiring** — changing `characterization` / `target_nref` /
  `reciprocal`. A rewire is semantically remove + re-add (full endpoint +
  template-scope + `target_kind` re-validation), and once `remove_relationship`
  and `add_relationship` both compose in `mutate/1`, a caller expresses it
  atomically as `mutate([{remove_relationship, …}, {add_relationship, …}])`.
  Building a dedicated structural-update path now is redundant.
- **A rel-id-keyed form** — the only thing that could disambiguate a genuine
  duplicate edge (see the ambiguity contract). `add_relationship` does not
  return rel-ids, so callers do not hold them; deferred as an escape hatch,
  not a slice-E gap.
- **`add_parent` / `add_child` / `remove_parent` / `remove_child`** —
  compositional-hierarchy arc creators and removers that *do* maintain the
  `parents` cache. Recorded as a `TASKS.md` follow-up.

## Background — how a logical edge is stored

`add_relationship` writes **two** directed rows per logical edge, correlated
only by symmetry — there is no shared edge-id and no write-time dedup:

```
Forward row:  source=S, characterization=C, target=T, reciprocal=R, avps=[Template | Fwd]
Reverse row:  source=T, characterization=R, target=S, reciprocal=C, avps=[Template | Rev]
```

The Template AVP (`?ARC_TEMPLATE`, index 0 of each row's `avps`) records the
connection's scope. Each direction carries its own independent AVP list.

Because nothing dedups at write time, **duplicate logical edges can exist**:
two `add_relationship` calls with identical arguments, or a B4 rule-fired
connection colliding with a manual one, both produce more than one logical
edge sharing the same `(S, C, T, Template)`.

## Edge identity and the ambiguity contract

A caller names an edge by the directed-row key `(S, C, T)`, optionally
narrowed by `Template`. Because duplicates are possible, **ambiguity means
"the supplied key matches more than one logical edge,"** at whatever
specificity was given:

| Form                                  | Matches forward rows by…           | 0 rows                             | exactly 1            | > 1 rows                                       |
|---------------------------------------|------------------------------------|------------------------------------|----------------------|------------------------------------------------|
| `remove_relationship/3 (S,C,T)`       | source / char / target             | `{error, relationship_not_found}`  | remove the pair      | `{error, {ambiguous_relationship, Templates}}` |
| `remove_relationship/4 (S,C,T,Tmpl)`  | + Template AVP                      | `{error, relationship_not_found}`  | remove the pair      | `{error, {ambiguous_relationship, [Tmpl]}}` (true duplicate) |

The ambiguity error carries the matching templates, so a `/3` caller learns
which `Template` value to pass to re-issue as `/4`. A `/4` collision is a
genuine duplicate edge: only the deferred rel-id form could distinguish them.
`update_relationship` carries the identical not-found / ambiguity contract.

## The core asymmetry: remove is edge-level, update is row-level

The same `(S, C, T)` key means different things to the two operations, by
design:

- **`remove_relationship(S, C, T)` deletes both directed rows.** A half-edge
  (one direction without its reciprocal) is an invalid state, so removal
  always operates at logical-edge granularity.
- **`update_relationship(S, C, T, Updates)` edits exactly one directed row**
  — the row whose `(source, characterization, target) = (S, C, T)`. To edit
  the reverse direction, name it from the other endpoint:
  `update_relationship(T, R, S, Updates)`.

This is the one genuine cognitive hazard in the slice; it is intentional and
stated loudly here so it is reviewed, not discovered in code.

## `remove_relationship`

Public arities (homed in `graphdb_instance`, alongside `add_relationship`):

| Arity                              | Form                              |
|------------------------------------|-----------------------------------|
| `remove_relationship/3`            | `(SourceNref, CharNref, TargetNref)` |
| `remove_relationship/4`            | `(SourceNref, CharNref, TargetNref, TemplateNref)` |

Behaviour: resolve the forward row(s) per the ambiguity contract; from the
single forward row derive `R` and `Template`; locate the symmetric partner
`(T, R, S, Template)`; delete both rows. If the forward row exists but its
partner does not, that is an integrity violation — abort a **distinct**
reason (`{dangling_half_edge, …}`), never silently delete a half-edge.

## `update_relationship` — AVP-only edit

Edits the per-direction AVP metadata of an existing connection edge, reusing
slice B's exported, pure helpers unchanged:

- `graphdb_mgr:validate_avp_updates/1` — client-side well-formedness (each
  update map's key-set is exactly `[attribute]` (delete) or
  `[attribute, value]` (upsert)).
- `graphdb_mgr:apply_avp_updates/2` — merge/upsert/delete against an existing
  AVP list.

**The Template AVP (`?ARC_TEMPLATE`) is protected.** Any update — upsert or
delete — targeting it aborts (`{protected_relationship_avp, ?ARC_TEMPLATE}`),
mirroring slice B's retired-marker guard. Changing scope is a structural
rewire, not metadata.

### Single-direction forms (two arities, mirroring `remove`)

| Arity                       | Form                                              |
|-----------------------------|---------------------------------------------------|
| `update_relationship/4`     | `(SourceNref, CharNref, TargetNref, Updates)`     |
| `update_relationship/5`     | `(SourceNref, CharNref, TargetNref, TemplateNref, Updates)` |

Each edits the **single** directed row named by `(S, C, T)`, with the same
not-found / ambiguity arms as `remove`.

### Bidirectional convenience forms (`*_both`)

| Arity                          | Form                                                      |
|--------------------------------|-----------------------------------------------------------|
| `update_relationship_both/4`   | `(SourceNref, CharNref, TargetNref, {FwdUpdates, RevUpdates})` |
| `update_relationship_both/5`   | `(SourceNref, CharNref, TargetNref, TemplateNref, {FwdUpdates, RevUpdates})` |

`*_both` resolves the edge **pair** by symmetry (the same `(T, R, S)`
partner-finding as `remove`, same ambiguity / not-found / dangling-half-edge
arms), then applies `FwdUpdates` to the forward row and `RevUpdates` to the
reverse row — **each through the one single-edge in-transaction primitive.**

### Why two independent update lists

The two directions' AVPs are **independent** — a forward edit need not be
mirrored on the reverse. Real callers update one side without touching the
other, or update each side differently. This is exactly why the
single-direction form is the primitive and why `*_both` takes **two
separate** update lists `{Fwd, Rev}` rather than one shared list.

## Tier structure (write-path seam)

There is exactly **one** tier-1 update primitive — single directed row, no
in-transaction variants. `*_both` is pure composition above it.

### Tier 1 — in-transaction primitives (`graphdb_instance`, exported, `_in_txn`)

Both are allocation-free and state-free: no `gen_server` call inside the
transaction (cleaner than `add_relationship`, and correct against the
load-bearing "never call a gen_server inside an Mnesia activity" invariant).

- `remove_relationship_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec)`
  — resolve forward row(s) (`relationship_not_found` /
  `{ambiguous_relationship, …}`), locate the symmetric partner
  (`{dangling_half_edge, …}` on a missing partner), delete both rows with
  bare `mnesia:delete_object/3`. `TemplateSpec` is a template nref (the `/4`
  path) or `any` (the `/3` path).
- `update_relationship_avps_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec, Updates)`
  — resolve the single directed row (same not-found / ambiguity arms), reject
  any update targeting `?ARC_TEMPLATE`, apply `apply_avp_updates/2` to the
  row's `avps` (preserving the Template AVP at index 0), write it back.

A shared private helper resolves a forward row from `(S, C, T, TemplateSpec)`
and classifies none / one / many — used by every public form.

### Tier 2 — single-op public API (`graphdb_instance`)

Plain exported functions (not `gen_server:call`s), each owning one
`graphdb_mgr:transaction/1` in the caller's process:

- `remove_relationship/3,4`
- `update_relationship/4,5`
- `update_relationship_both/4,5` (compose two `update_relationship_avps_in_txn`
  calls in one transaction)

### Tier 3 — batch (`graphdb_mgr:mutate/1`)

The mutation grammar gains, composing the tier-1 primitives directly:

```erlang
{remove_relationship,        S, C, T}
{remove_relationship,        S, C, T, Template}
{update_relationship,        S, C, T, Updates}
{update_relationship,        S, C, T, Template, Updates}
{update_relationship_both,   S, C, T, {Fwd, Rev}}
{update_relationship_both,   S, C, T, Template, {Fwd, Rev}}
```

Whole-batch rollback and the opaque bare-reason contract are unchanged.

## Reuse note for a future `delete_node` hard-delete

The connection-only row-pair-deletion core (`remove_relationship_in_txn`) is
exactly what a future `delete_node` hard-delete would reuse when tearing down
a node's connection arcs. This slice deliberately does **not** build the
kind-agnostic / cache-fixing machinery that a general arc remover would need
— that belongs to the hard-delete work, against the connection-only scope set
here.

## Deferred work to record in `TASKS.md`

1. **Structural relationship rewiring** — `characterization` / `target_nref`
   / `reciprocal` change; expressible today as `mutate([remove, add])`.
2. **Rel-id-keyed remove/update** — the only disambiguator for genuine
   duplicate edges.
3. **`add_parent` / `add_child` / `remove_parent` / `remove_child`** —
   compositional-hierarchy arc creators and removers (kind=composition,
   part-of) that maintain the `parents` cache. Distinct from slice E's
   connection-only, cache-free scope; the cache-maintenance counterpart to a
   future connection-arc remover.

## Testing

**EUnit (pure):**

- Forward-row classification: none → `relationship_not_found`; one → the row;
  many → `{ambiguous_relationship, Templates}` (templates carried).
- Symmetric-partner derivation from a forward row (`(T, R, S, Template)`).
- Template-AVP rejection: an update map targeting `?ARC_TEMPLATE` (upsert or
  delete) → reject; a non-template update → accept.
- `*_both` decomposition: `{Fwd, Rev}` routes `Fwd` to the forward row and
  `Rev` to the reverse row, each via the single-edge primitive.

**CT (integration):**

- `remove_relationship/3,4` happy path (both rows gone, reverse traversal
  empty); not-found; duplicate-edge ambiguity (carrying templates); `/4`
  disambiguation after a `/3` ambiguity.
- `dangling_half_edge` integrity abort (forward present, partner manually
  removed) — no half-edge deleted, transaction rolled back.
- `update_relationship/4,5` single-direction edit (forward changed, reverse
  untouched — proving independence); reverse-direction edit via `(T, R, S)`;
  `?ARC_TEMPLATE` protection; not-found / ambiguity arms.
- `update_relationship_both/4,5` editing both directions with **different**
  `{Fwd, Rev}` lists in one atomic call.
- `mutate/1` composition: a batch mixing `remove_relationship`,
  `update_relationship`, and `update_relationship_both` commits atomically; a
  failing entry rolls the whole batch back.
- `verify_caches/0` clean in `end_per_testcase` (connection mutation must
  leave caches untouched), as every suite already does.
