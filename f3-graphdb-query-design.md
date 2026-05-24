<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F3 — graphdb_query Query Language Design

**Status:** Draft — design spec for the query layer. Not a plan. Not
surface syntax. Not a task list.

> **Module-name note.** The query language lives in a new module
> `graphdb_query`, not `graphdb_language`. The latter is occupied by
> the M6 multilingual overlay layer (label resolution, language
> registration, translation hooks). Earlier task drafts referred to
> `graphdb_language` as the query module — that slot was reclaimed
> by M6 and the query layer needed a new home.

This document fixes the **architectural contract** the query language
will grow into. The query language is open-ended — there is no
"finished" state, only growing capability. The job of this design is
to choose the axes so that new query forms can be added by
*extending*, not *rewriting*.

## 1. Architectural Pattern

Walking-skeleton + representative queries. Seven queries are
specified in full as **independent building blocks**:

- Each is a self-contained capability shipped independently.
- Each stresses one previously-unexercised dimension of the executor.
- After all seven land, the next dozen useful queries are
  *composition* of these primitives, not new primitives.

Implementation order: Q1 → Q1b → Q2 → Q3 → Q4 → Q5 → Q6 (Q1 is the
walking skeleton; Q1b is its sibling primitive that opens the
`relationships` table; later queries extend one layer at a time).

## 2. Layered Architecture

```
+---------------------------------------------+
|  Surface syntax (text DSL)                  |  <- deferred
+---------------------------------------------+
|  Parser (terms -> #q_*{} records)           |  <- identity at first
+---------------------------------------------+
|  Planner (AST -> executor steps)            |  <- single-pass; no optimizer
+---------------------------------------------+
|  Executor (graphdb_query gen_server)        |  <- the work happens here
+---------------------------------------------+
|  graphdb_attr / class / instance / mgr      |  <- existing primitives
|  + Mnesia indexes on source/target_nref     |
+---------------------------------------------+
```

Public API matches the F3 task spec: `parse_query/1`,
`execute_query/1`, `find_path/3`.

## 3. AST Shape

Each query is an Erlang record from a `#q_*{}` family defined in
`apps/graphdb/include/graphdb_query.hrl`. Records — not maps — for
dialyzer support and to match project style.

```erlang
-record(q_get_node,       {nref :: integer()}).
-record(q_get_arcs,       {nref      :: integer(),
                           direction :: outgoing | incoming | both,
                           arc_kinds :: all | [arc_kind()]}).
-record(q_describe,       {nref :: integer(), labels :: language_spec()}).
-record(q_instances_of,   {class :: integer(), recursive :: boolean()}).
-record(q_find_path,      {from :: integer(),
                           to :: integer(),
                           max_depth :: pos_integer(),
                           arc_kinds :: [arc_kind()]}).
```

The parser at first is the identity function: `parse_query(Term) ->
Term`. Term-based queries are the surface for now. A text DSL would
be added later by replacing the parser without touching the AST.

## 4. Result Shape

| Result class              | Shape                       | Returned by |
| ------------------------- | --------------------------- | ----------- |
| Single record             | `{ok, #{...}} \| {error,_}` | Q1–Q4       |
| Set                       | `{ok, [Nref]}`              | Q5          |
| Structure (ordered edges) | `{ok, [#{edge}]}`           | Q6          |

Every **describe-style** result (Q2–Q4) includes a `labels` sub-map
keyed by every nref appearing in the result → its label string in
the requested language. This lets the caller render any nref without
a second lookup pass.

```erlang
language_spec() :: default | {language, LangNref :: integer()}.
```

`default` resolves to English (the M6 baseline). Non-describe queries
(Q5, Q6) return nrefs only — the caller composes with Q1/Q4 for
labelled detail.

## 5. The Seven Queries

| ID  | Query              | Builds on       | Primary new dimension                |
| --- | ------------------ | --------------- | ------------------------------------ |
| Q1  | get_node           | (none)          | end-to-end pipeline; `nodes` table   |
| Q1b | get_arcs           | (none)          | access to `relationships` table      |
| Q2  | describe_attribute | Q1, Q1b         | attribute taxonomy walking + labels  |
| Q3  | describe_class     | Q1, Q1b, Q2     | class taxonomy + QC inheritance      |
| Q4  | describe_instance  | Q1, Q1b, Q2, Q3 | attribute resolution + connections   |
| Q5  | list_instances_of  | Q1, Q1b         | set-returning result shape           |
| Q6  | find_path          | Q1, Q1b         | bounded traversal + structure result |

Q1 and Q1b are sibling foundational primitives — Q1 reads the `nodes`
table, Q1b reads the `relationships` table. Neither requires the
other. Everything past Q1b composes both.

The **Builds on** column shows shared primitives, not hard ordering
dependencies. Q3 does not *require* Q2 to exist — only reuses Q2's
label-resolution helper once Q2 lands.

---

### 5.1 Q1 — `get_node`

**English:** "Give me the raw record for node N."

**Use case:** internal/debug; the smallest query the system can run.
The walking skeleton.

**AST:**

```erlang
#q_get_node{nref = N}
```

**Result:**

```erlang
{ok, #{kind                  => instance,
       nref                  => 12345,
       parents               => [12000],
       classes               => [11000],
       attribute_value_pairs => [#{attribute => 100100,
                                   value     => "Taurus"}]}}
%% or
{error, {nref_not_found, N}}
```

**Primitives used:** `mnesia:dirty_read({nodes, N})`.

**Why this is the walking skeleton:** it forces every layer (parse →
plan → execute → reply) to exist with the minimum possible work in
each. Adding Q1b only requires adding one new AST record and one new
executor clause that hits the `relationships` table.

---

### 5.1b Q1b — `get_arcs`

**English:** "Give me the arcs at node N."

**Use case:** debugging, bulk traversal, programmatic arc inspection
without the cost of a full describe. The complementary primitive to
Q1: Q1 reads the `nodes` table, Q1b reads the `relationships` table.

**AST:**

```erlang
#q_get_arcs{nref      = N,
            direction = outgoing | incoming | both,
            arc_kinds = all | [composition | taxonomy
                              | connection | instantiation]}
```

**Result:**

```erlang
{ok, [#{id               => 70000,
        kind             => connection,
        source_nref      => 50000,
        characterization => 200100,
        target_nref      => 60000,
        reciprocal       => 200101,
        avps             => [...]},
      #{id               => 70001,
        kind             => instantiation,
        source_nref      => 50000,
        characterization => 29,
        target_nref      => 11000,
        reciprocal       => 30,
        avps             => []},
      ...]}
```

**Primitives used:**
- `mnesia:dirty_index_read(relationships, N, #relationship.source_nref)`
  for outgoing
- `mnesia:dirty_index_read(relationships, N, #relationship.target_nref)`
  for incoming
- post-filter by `kind` if `arc_kinds /= all`

Routed through `session_read_arcs/4` so the result is cached for the
rest of the session.

**Why this sits next to Q1:** the two primary Mnesia tables in
graphdb are `nodes` and `relationships`. Q1 covers the first, Q1b the
second. Together they are the complete raw-row surface; everything
else is projection, walking, or composition over these two reads.

**New work introduced:** secondary-index access; bulk arc projection;
direction + kind filtering.

---

### 5.2 Q2 — `describe_attribute`

**English:** "Tell me about attribute A."

**Use case:** introspection of the attribute library — "what is this
attribute, what's its taxonomic parent, what kind of attribute is
it?"

**AST:**

```erlang
#q_describe{nref = A, labels = default}
```

(Dispatch by the looked-up node's `kind`; Q2/Q3/Q4 share an AST and
diverge in the executor.)

**Result:**

```erlang
{ok, #{nref           => 100100,
       kind           => attribute,
       attribute_type => name | literal | relationship,
       parent         => 6,            %% NREF_NAMES — taxonomy parent
       children       => [...],        %% direct subordinates (chars 23/24)
       avps           => [...],
       labels         => #{100100 => "name",
                           6      => "Names"}}}
```

**Primitives used:** Q1 (the node row) + Q1b (incoming char-23/24
taxonomy arcs to find children, outgoing char-23 arc to find parent)
+ `graphdb_attr:label/2` (M6 layer).

**New work introduced:** label resolution; arc-result projection
filtered by characterization nref.

---

### 5.3 Q3 — `describe_class`

**English:** "Tell me about class X." — *user-requested seed query.*

**Use case:** the most common ontology-design introspection — "what
is this class, what's its hierarchy, what attributes do its
instances have?"

**AST:**

```erlang
#q_describe{nref = X, labels = default}
```

**Result:**

```erlang
{ok, #{nref                       => 11000,
       kind                       => class,
       superclasses               => [10000, 9000],
       ancestors                  => [10000, 9000, 1],
       subclasses                 => [12000, 13000],
       qualifying_characteristics =>
           #{own       => [100100, 100200],
             inherited => [#{from => 10000, attr => 100050}]},
       avps                       => [...],
       labels                     => #{...}}}
```

**Primitives used:** Q2's primitives + `graphdb_class:ancestors/1`,
`graphdb_class:inherited_qcs/1` (existing APIs).

**New work introduced:** multi-arc-kind result projection (taxonomy
arcs + QC inheritance shown in one structured map).

---

### 5.4 Q4 — `describe_instance`

**English:** "I want to see the complete knowledge of instance Y." —
*user-requested seed query.*

**Use case:** the richest introspection query — every dimension of
the knowledge model surfaced at once for a single instance.

**AST:**

```erlang
#q_describe{nref = Y, labels = default}
```

**Result:**

```erlang
{ok, #{nref                    => 50000,
       kind                    => instance,
       classes                 => [11000],
       class_ancestors         => [10000, 9000, 1],
       compositional_parent    => 49000,
       compositional_ancestors => [49000, 48000],
       resolved_attributes     =>
           #{100100 => #{value => "Taurus",
                         source => local},
             100200 => #{value => 3500,
                         source => {class, 11000}},
             100300 => #{value => "car",
                         source => {compositional, 48000}}},
       outgoing_connections    =>
           [#{characterization => 200100,
              target           => 60000,
              template         => 31}],
       incoming_connections    => [...],
       labels                  => #{...}}}
```

**Why both directions are listed.** Topology is symmetric — every
relationship is two atomic rows, and each outgoing row already
carries the reciprocal label. The two lists are not redundant for
three reasons:

1. **Per-direction AVPs.** `add_relationship/6` takes
   `{FwdAVPs, RevAVPs}` (M5). The same logical edge can carry
   different metadata on each side (e.g. manufacturing AVPs on the
   maker side; warranty AVPs on the made side). Each direction's
   AVPs live on that direction's row.
2. **Per-direction row IDs.** Each row has its own primary-key nref.
   Future mutation or admin work needs both.
3. **Epistemic stance.** "What I point to" and "what points to me"
   are different rendering perspectives; separating them in the
   result preserves that distinction for the caller.

Topologically deriving incoming from other nodes' outgoing is O(N)
across the graph — incoming-via-index is O(1). The two-row schema
pre-computes this for us; Q4 surfaces both directly.

**Primitives used:** every earlier query's primitives + Q1b in both
directions filtered to `kind=connection` for the connection lists +
`graphdb_instance:resolve_value/2` (the 4-priority inheritance rule,
already implemented).

**New work introduced:** the inheritance-source tagging on each
resolved attribute (the `source => ...` annotation); composing
bidirectional Q1b output into the result map.

---

### 5.5 Q5 — `list_instances_of`

**English:** "All instances of class X (including subclasses)."

**Use case:** the most common *set-returning* query — bulk
operations start here.

**AST:**

```erlang
#q_instances_of{class = X, recursive = true}
```

**Result:**

```erlang
{ok, [50000, 50001, 50002, ...]}
```

No labels: caller composes with Q1/Q4 for labelled detail.

**Primitives used:** `graphdb_class:subclasses/1` (recursive) + Q1b
(incoming char-29 instantiation arcs at each class in the cone).

**New work introduced:** set-returning result shape; bulk
arc-traversal pattern.

---

### 5.6 Q6 — `find_path`

**English:** "A path from A to B, max depth D, restricted to arc
kinds K."

**Use case:** the foundational *structure-returning* query — paths
are intermediate between single records (Q1–Q4) and flat sets (Q5).

**AST:**

```erlang
#q_find_path{from      = A,
             to        = B,
             max_depth = D,
             arc_kinds = [composition, taxonomy, connection]}
```

**Result:**

```erlang
{ok, [#{from => A,  via => Char1, to => N1, kind => composition},
      #{from => N1, via => Char2, to => B,  kind => composition}]}
%% or
{ok, no_path}
```

**Primitives used:** bounded BFS — each hop is one Q1b call (outgoing
direction, filtered by `kind` ∈ ArcKinds). Cycle detection via
visited-set carried through the BFS frame.

**New work introduced:** depth-bounded traversal; structure-shaped
result (ordered list of edge maps, not a flat set).

## 6. Composition After Q6

The proof that the seven axes are right: the next dozen useful
queries are 1–2 lines of composition, not new primitives.

| Compound query                                | =   | Building blocks                         |
| --------------------------------------------- | --- | --------------------------------------- |
| "Everything raw about node N"                 | =   | Q1 + Q1b                                |
| "Describe every instance of class X"          | =   | Q5 → map(Q4)                            |
| "Path from A to B, then describe each hop"    | =   | Q6 → map(Q1) over the hop nrefs         |
| "Path from A to B with full arcs at each hop" | =   | Q6 → map(Q1 + Q1b) over the hop nrefs   |
| "Instances of X whose attribute V matches P"  | =   | Q5 → filter by Q4's resolved_attributes |
| "Subtree under instance Y, depth ≤ 3"         | =   | Q6 with `arc_kinds=[composition]`       |
| "All classes that inherit QC A"               | =   | Q3 inverted — search all classes        |

The last row is the first thing that *won't* compose trivially —
which tells us the next axis to add when it matters: a class-side
search query. We do not build it now.

## 7. Pinned Design Decisions

These are the decisions that get hard to change later. Don't drift.

1. **AST: records, not maps.** Dialyzer support; matches project
   style.
2. **Surface: Erlang terms only.** Text DSL deferred. Parser is
   identity until then.
3. **Result shape: maps with explicit keys.** Lists of maps for set
   queries; single map for single-record queries.
4. **Labels: opt-in sub-map in the result.** Caller specifies a
   language; executor resolves once and includes a `labels` field.
   Default = English.
5. **Executor: gen_server, synchronous calls.** No async streaming
   yet; results fit in memory at this stage.
6. **Inheritance lives in `graphdb_instance`, not
   `graphdb_query`.** Executor calls existing `resolve_value/2`.
   Never duplicate the 4-priority logic.
7. **`find_path` is always bounded.** No unbounded traversal at the
   API. Caller must supply a depth limit. Default = 10.

## 8. Conversation-Scoped Continuity (Forward-Compatible)

Queries are rarely single and final. Two structural concerns must be
designed for now even though they will not be fully implemented in
the walking skeleton — adding them later changes every public
signature and is the most expensive kind of retrofit.

### 8.1 The Two Concerns

**Incidental traversal context.** A query that asks about X, Y, Z
will physically visit A, B, C along the way. Dropping A, B, C and
re-reading them on the next related query is wasteful. The cache
should be filled by traversal as a *side effect* — whatever the
executor touches becomes available to the next query in the same
conversation. The cache is internal to the executor; returned
results, once handed to the caller, are immutable and out of scope
for this freshness model (see §8.4).

**Danglers as resumable continuations.** A bounded query (max-depth
path, capped instance set) stops at a frontier. That frontier is
itself useful — "what was about to be explored." Returning it as a
resumable handle lets the caller pick up the search without
restating the original query.

### 8.2 API Shape — Pinned Now

```erlang
-opaque session()      :: #{snapshot_at => erlang:timestamp(),
                            cache       => #{integer() => term()},
                            ...}.
-opaque continuation() :: #cont{...}.

-spec new_session() -> session().
-spec refresh(session()) -> session().

-spec execute_query(query()) ->
    {ok, result()} |
    {partial, result(), continuation()} |
    {error, term()}.

-spec execute_query(query(), session()) ->
    {ok, result(), session()} |
    {partial, result(), continuation(), session()} |
    {error, term()}.

-spec resume(continuation(), session()) ->
    {ok, result(), session()} |
    {partial, result(), continuation(), session()} |
    {error, snapshot_expired}.
```

The `/1` variant is ephemeral (no session reuse). The `/2` variant
threads a session through. Continuation is an opaque record — in
spirit a resumable lambda, but a record so it can be inspected,
logged, and serialized.

### 8.3 Cache Pattern — Read-Through by Traversal

The executor never calls Mnesia directly. Every node read and every
arc lookup goes through:

```erlang
session_read_node(Session, Nref) -> {Node, Session1}.
session_read_arcs(Session, Nref, Direction, ArcKindFilter) -> {Arcs, Session1}.
```

Cache miss = Mnesia read + populate. Cache hit = return cached. The
cache fills automatically with whatever the traversal touches —
including incidental hops never requested by the caller. The
executor cannot bypass this layer because the layer *is* the
executor's Mnesia interface.

### 8.4 Freshness Model — Snapshot Semantics

A session is a coherent view of the graph as of the moment it was
opened (or last refreshed). The cache, once populated, is not
invalidated by mutations to the underlying tables. This is a
deliberate trade-off — not an oversight.

**Why snapshot, not invalidation:**

- Conversations are short-lived and form coherent inquiries.
  Internally inconsistent answers across `Q3 → Q5 → Q4` would be
  worse than uniformly-snapshot answers.
- Continuations require a fixed graph view. A `#continuation{}`
  paused at frontier F is meaningless if F's nodes have been
  reparented or deleted in the meantime. Snapshot semantics make
  resume well-defined.
- No version stamps on records, no event bus, no subscriber
  registry — the cost of "always fresh" is high and not justified
  at this stage.

**Returned results vs. internal cache.** Once a query returns a
`result()` to the caller, it is immutable and owned by the caller —
re-querying is the only path to fresher data. The freshness model
only governs the internal `session.cache` filled by read-through.

**The escape hatch.** Callers that know they have made a write — or
that simply want to drop a stale view — call:

```erlang
refresh(Session) -> Session1.
```

This drops the cache and bumps `snapshot_at`. Continuations issued
against the previous snapshot are invalidated; resuming one against a
refreshed session returns `{error, snapshot_expired}` so callers
re-query rather than silently mix snapshots.

**Deferred:** event-driven invalidation. If multi-agent concurrent
editing or long-lived monitoring sessions become real use cases, push
invalidation re-enters scope. The snapshot model plus the refresh
escape hatch keeps the door open without prejudging that design.

### 8.5 Minimal First Implementation

The walking skeleton (Q1) ships with the full API surface but
minimal behaviour:

- `new_session/0` returns an empty session map with
  `snapshot_at => os:timestamp()`.
- `session_read_*` always misses and reads Mnesia. Cache is populated
  but no query yet exercises a second read against it.
- `refresh/1` is exported and works (drops cache, bumps
  `snapshot_at`), but no query yet depends on it.
- `execute_query/1` always returns `{ok, _}` — never `{partial, _,
  _}` — because Q1 is not bounded.
- `resume/2` is exported but no continuation type yet exists to call
  it with.

Cost: ~30 lines beyond a no-session implementation. The cache map and
read-through helpers are the only real additions. Everything else is
spec / signatures.

### 8.6 What Build-Out Adds Later

When a real client pattern needs it:

- Q6 returns `{partial, EdgesSoFar, #cont_path{visited, frontier,
  remaining_depth, ...}}` when it hits its depth bound.
- `resume(Cont, Session)` continues a `#cont_path{}` from where it
  stopped, checking that the continuation's snapshot matches the
  session's current snapshot.
- Session may grow to carry: open continuations from prior queries;
  a generation counter to detect continuation/refresh mismatches;
  subscription handles if event-driven invalidation is later added.
- A session may eventually become a gen_server-owned process if
  contention demands it (value-passing now keeps the door open).

### 8.7 Why Pinning the Shape Now is Cheap

| Cost now                                 | Cost if deferred                                |
| ---------------------------------------- | ----------------------------------------------- |
| ~30 lines of skeleton                    | Breaking change to every `execute_query` caller |
| One extra `/2` arity per public function | Editing every query result-shape contract       |
| One read-through helper module           | Auditing every Mnesia call site in the executor |

The implementation is deferred. The contract is not.

## 9. Pinned Design Decisions (Don't Drift)

These are the decisions that get hard to change later.

1. **AST: records, not maps.** Dialyzer support; matches project
   style.
2. **Surface: Erlang terms only.** Text DSL deferred. Parser is
   identity until then.
3. **Result shape: maps with explicit keys.** Lists of maps for set
   queries; single map for single-record queries.
4. **Labels: opt-in sub-map in the result.** Caller specifies a
   language; executor resolves once and includes a `labels` field.
   Default = English.
5. **Executor: gen_server, synchronous calls.** No async streaming
   yet; results fit in memory at this stage.
6. **Inheritance lives in `graphdb_instance`, not
   `graphdb_query`.** Executor calls existing `resolve_value/2`.
   Never duplicate the 4-priority logic.
7. **`find_path` is always bounded.** No unbounded traversal at the
   API. Caller must supply a depth limit. Default = 10.
8. **Session + continuation API shape pinned at v1; implementation
   minimal.** See §8 — `/1` and `/2` arities exist; cache and
   continuations are scaffolded but only filled out when a real
   client pattern demands.
9. **Mnesia access only via `session_read_*` helpers.** The cache
   layer *is* the executor's database interface. Direct
   `mnesia:dirty_*` calls in `graphdb_query` are a code smell.
10. **Sessions are snapshots, not live views.** Once opened, a
    session's cache is not invalidated by concurrent writes.
    `refresh/1` is the sole invalidation mechanism; event-driven
    invalidation is deferred. Returned results are immutable once
    handed to the caller — freshness past the return is the caller's
    concern, not the executor's.

## 10. Out of Scope (Deferred)

- Text surface syntax (DSL)
- Query planner / optimizer (single-pass is fine until we see slow
  queries in practice)
- Aggregation queries (count, group_by) — need a planner to be
  useful at scale
- Class-side search ("classes inheriting QC A") — first axis past
  the building blocks
- Cross-database joins as explicit query forms
- Materialized views, query caching (beyond session-scoped read cache)
- Concurrent or streaming result delivery
- Mutation queries (write side) — the query language is read-only
- Event-driven cache invalidation under concurrent mutation.
  Sessions are snapshots (§8.4); `refresh/1` is the only invalidation
  path. Push invalidation becomes worth designing if multi-agent
  concurrent editing or long-lived monitoring sessions appear.

## 11. Open Questions

*(Empty — escalate here when they arise during implementation.)*
