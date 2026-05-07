# Arcs Authoritative; Hierarchy Lists Cached

## Status

Proposed — to land as task **H0** in `TASKS-HIGH.md` before H3.

## Context

The knowledge graph stores every hierarchical relationship — taxonomic
parents, compositional parents, class memberships — in two places today:

  - The `relationships` table (25/26 taxonomy arcs, 27/28 composition
    arcs, 29/30 instantiation arcs).
  - Fields on the `node` record (`parent`).

`TASKS-MEDIUM.md` M1 already calls out the inconsistency for instances.
The same shape reappears in H3 (multi-parent classes) and H4
(multi-class instances). A uniform answer is needed before H3 lands.

## Decision

  1. **Arcs are the sole authoritative source for hierarchy.** Every
     taxonomy, composition, and instantiation relationship is canonical
     in the `relationships` table.
  2. **Hierarchy-shaped fields on `node` records are caches.** They
     summarize "who are my parents / classes" for read performance.
     They are reconstructable from the arcs at any time and they are
     never read in a context where the cache might lie.
  3. **A cache that disagrees with the arcs is a fatal error**, not
     correctable drift. The invariant is enforced, not negotiated.

## Cache fields

`node.parent` (singular) is retired as a record field. The list-shaped
`node.parents` covers the single-parent case as a length-1 list.

| Cache field    | Authoritative arcs                       | Owner worker       |
|----------------|------------------------------------------|--------------------|
| `node.parents` | 25/26 taxonomy (class)                   | `graphdb_class`    |
| `node.parents` | 27/28 composition (instance)             | `graphdb_instance` |
| `node.parents` | 23/24 composition (attribute)            | `graphdb_attr`     |
| `node.classes` | 29 instantiation, instance→class         | `graphdb_instance` |

## Single-writer ownership

  1. Each cache field has exactly one owner worker. Only that worker
     mutates the corresponding arcs and the cache field.
  2. The owner runs every state-change inside one
     `mnesia:transaction/1`: arc write(s) and the matching cache
     update happen together or not at all.
  3. Other workers do not write the table directly. If a worker needs
     an operation in another worker's domain, it calls that worker's
     API.
  4. A generic dispatch entry point on `graphdb_mgr` MAY exist; it
     routes by `node.kind` / `relationship.kind` to the appropriate
     owner. The dispatcher itself never writes.

The `kind` field on both `node` and `relationship` records makes
ownership statically determinable — workers can refuse writes that
don't belong to them.

## Read paths

  1. Reads that need only structure (which ancestors / which classes)
     consult the cache. No arc index_read.
  2. Reads that need per-edge metadata (AVPs on the arc, e.g.
     specifications that resolve ambiguous inheritance) consult the
     arcs directly via `mnesia:index_read/3`.
  3. Future optimization: a structural read can fetch arc metadata in
     parallel and combine. The cache makes that optimization possible
     without a schema change.

## Repair and audit

  1. `graphdb_mgr:verify_caches/0` — scans every node, compares its
     hierarchy cache fields against the corresponding arcs, returns
     `ok` if all caches match, otherwise
     `{error, [{Nref, Field, Expected, Actual}, ...]}`.
  2. `graphdb_mgr:rebuild_caches/0` — rewrites every cache field from
     the arcs. Used as the post-load tail of the bootstrap loader and
     as a diagnostic tool.
  3. The CT suites must call `verify_caches/0` after every mutation
     test case. A failed verify is a test failure.

## Bootstrap

`apps/graphdb/priv/bootstrap.terms` follows **Option B**: arcs are the
only source of hierarchy in the file; node tuples carry no parent
field. Each arc row is preceded by (or trails) a `%%` comment naming
the relationship in plain English so the file remains
human-followable top-to-bottom. The existing inline `%%` comments
already demonstrate the pattern.

Pre-H0 example (today):

```erlang
{node, 6, attribute, 2, {18, "Names"}, []}.
{relationship, 2, 24, [], 23, 6, [], composition}.  %% Attributes -> Names
```

Post-H0d example:

```erlang
{node, 6, attribute, {18, "Names"}, []}.            %% parent comes from the arc below
{relationship, 2, 24, [], 23, 6, [], composition}.  %% Attributes -> Names
```

The loader writes nodes with `parents = []`, `classes = []`, then
writes the arcs, then runs `graphdb_mgr:rebuild_caches/0` followed by
`graphdb_mgr:verify_caches/0` as a final assertion. Any mismatch
between the rebuilt caches and the arcs is a fatal startup error.

## Migration / H0 scope

See `TASKS-HIGH.md` H0 for the substep checklist.

## Consequences

Pro:

  - M1 closed; H3 lands as a small additive change atop established
    cache machinery; H4 follows the same pattern.
  - Future memoization and parallel-fetch optimizations are internal
    changes — no API or schema move.
  - Single read path everywhere; no special-case branches for
    "is this multi-parent or single-parent?".

Con:

  - Schema change in the `nodes` table. Bootstrap data must round-trip
    cleanly through the new shape.
  - Strict write discipline; the `verify_caches/0` CT step is mandatory
    and cannot be skipped.
  - Slightly more node-record churn on writes — every parent-set
    mutation rewrites the node record. Reads dominate this workload by
    a large margin, so the cost is negligible.

## Future work

This document may be folded into `ARCHITECTURE.md` once the invariant
is established. `ARCHITECTURE.md` may itself be split into multiple
focused documents at a later date; that decision is deferred.
