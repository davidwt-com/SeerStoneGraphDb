# Resiliency Notes

Notes-only. Not a design, not an article. Just enough to remember the
threads and pick them back up later. Started 2026-05-27 after pausing
the rules-engine seeding-shape discussion.

## Threads to revisit

### 1. nref stability across env restarts

- Env runtime seeds (10000+) are `disc_copies` — they **persist**.
  They are not ephemeral. Once allocated, an nref is forever.
- Project DBs currently reference env nrefs by integer in:
  - `relationship.characterization`, `relationship.reciprocal`
  - `node.classes` cache (instance → class membership)
  - AVP keys (`#{attribute => AttrNref, value => _}`)
- Therefore: env nrefs are load-bearing identifiers across DB
  boundaries. Reordering worker `init/1` or inserting a new seed
  between existing seeds shifts nrefs and breaks project DBs.

### 2. Prior implementation had no such coupling

- Earlier (pre-current-codebase) implementation used unique
  **string labels** ("system concepts") to tie app code to nodes.
- No project node referenced a system concept directly.
- Once a system concept was declared, its nref was stable for the
  life of the env — but only because the env was the only consumer.
- No nref floor for runtime-created attributes / classes.

### 3. Two framings for the migration problem

- **(A) Restore separation.** Project DB stops referencing env nrefs
  directly. Stable string identifier becomes the cross-DB key. Nref
  stays as internal env handle. Cutover one day = clean.
- **(B) Keep coupling.** Treat current env nrefs as load-bearing now;
  deal with migration on first prod cutover via a deterministic
  allocation + rename map.

Neither is decided. (A) is more invasive but removes the migration
class of problems entirely. (B) is cheaper today.

**Important:** (A) vs (B) does not block the rules data model. That
work and the small commit can land under either framing.

### 4. Brainstorm leftovers (R1–R6)

These were rephrased questions queued at the end of the seeding
brainstorm but never answered. Most are smaller than (A)-vs-(B):

- **R1.** ~~Bump `nref_start` from 10_000 to 1_000_000?~~ **Resolved:
  bumped to 1_000_000.** Permanent tier is now `[10001, 1000000)`,
  runtime allocations `>= 1000000` — a much larger gap between the
  bootstrap/permanent and runtime regions, easier to spot region
  violations at a glance.
- **R2.** ~~Where do `applies_to` / `applied_by` arc-label nodes
  land?~~ **Resolved 2026-06-01:** under **nref 16** (Relationships >
  Instance Relationships, `?NREF_INST_REL_ATTRS`) — candidate (a). No
  dedicated Rule Relationships sub-bucket. Recorded in the rules-engine
  design (§10.1, resolved).
- **R2b.** ~~Should `create_relationship_attribute/3` be fixed to honor
  kind sub-categories (13–16) instead of dropping new arc-labels
  directly under nref 8?~~ **Resolved (attribute-placement
  generalisation, 2026-05-31):**
  `create_relationship_attribute_pair/4` takes an explicit, validated
  `ParentNref`, so arc-labels can be filed under nref 13–16 (or any
  attribute parent); the `/3` arity keeps the nref-8 default.
- **R3.** Default Templates — show them in `ontology-tree.md`?
  Currently no Templates exist at end of bootstrap, so the diagram
  is clean. Decision pending first runtime Template seed. **Update
  2026-06-01:** the `create_class/2` auto-default-template behavior is
  reviewed and **kept** per-class (per the rules-engine design —
  singleton/removal both rejected). So once the rules data model lands,
  the two *instantiable* meta-classes (`CompositionRule`,
  `ConnectionRule`) will each seed a default template into the env tree;
  the abstract `Rule` root will not (non-instantiable classes skip the
  auto-default via the `instantiable => false` marker). Revisit the
  diagram then.
- **R4.** Promote the literals-subtree sub-grouping pattern (sub-group per owning
  worker, idempotent ensure-by-name under a category/attribute
  parent) to **policy** or keep it as **precedent only**?
- **R5.** Where do the **shared creators** live? Module location,
  naming, and whether bootstrap also routes through them or stays
  separate (it currently writes nodes/arcs directly via `mnesia`).
- **R6.** Migration discipline posture: (i) clean-slate-then-strict
  (current implicit stance), (ii) strict-now (no nref reordering
  ever, even pre-prod), or (iii) deterministic-nrefs (every seed
  has a fixed nref assigned in code).

### 5. Bootstrap-vs-init-vs-runtime semantics

Restate for the next session, since the user previously held a
different mental model:

- **Bootstrap** = first-ever start. One transaction. Writes nrefs
  1–35 + English (10000). Single source: `bootstrap.terms`.
  `graphdb_nrefs:verify/0` runs after.
- **Init** (each `graphdb_*` worker's `init/1`) = runs every start.
  **Idempotent ensure-by-name**: looks up by name attribute; creates
  with a fresh nref from `nref_server` only if absent. Each worker
  transacts its own seed set.
- **Runtime** = everything else. Same allocator. Same persistence.

There is no "ephemeral seed" region. Anything written, persists.

### 6. Stable-identifier candidates if (A) is chosen

(Notes for future discussion — not decisions.)

- Re-use the Name attribute as the cross-DB key (already unique per
  kind within env, already used for ensure-by-name).
- Or introduce a separate `stable_id` literal attribute, populated
  for every node that's referenced from outside the env.
- Either way, project DBs would store the stable identifier, and the
  env would resolve identifier → current nref at boundary crossings.
  Cost: an extra lookup on every cross-DB hop.

### 7. Resilience checks worth having either way

- Boot-time invariant check that every bootstrap nref still has the
  expected name and parent. (Partially: `graphdb_nrefs:verify/0`
  covers nref identity; doesn't cover names.)
- Boot-time invariant check that every runtime-seeded sub-group
  still has the expected name and parent.
- A "migration audit" CT case that loads a saved project DB against
  a freshly-bootstrapped env and verifies every characterization /
  reciprocal / classes-cache nref still resolves to the expected
  node.

These are cheap and useful under both (A) and (B).

## Reading order for next session

1. This file (re-orient).
2. `docs/archive/arcs-authoritative.md` (current arc model).
3. `docs/designs/f4-graphdb-rules-design.md` §10.1 (the pinned
   placement question — directly affected by R2).
4. `memory/project-f4-phase-a-pinned-question.md` (the then-current
   blocker on the rules data model).
