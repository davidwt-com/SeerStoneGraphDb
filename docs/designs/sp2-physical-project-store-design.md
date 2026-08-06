> **Note (2026-08-02).** `Session` in this document is used only for the
> *deferred* higher-level concept described in §8. The parameter that SP1
> shipped under the name `Session` is renamed `Project` by this sub-project —
> see §5.

# Project/Environment Separation — SP2: Physical Project Store

**Status:** Design (approved for planning)
**Date:** 2026-08-02
**Scope:** Sub-project 2 of the project/environment separation program.
**Parent:** `docs/designs/project-env-reference-namespace-model-design.md`

## 1. Context

SP1 established, at the API/code layer only, that every nref reference has a
derived namespace, that project write operations carry a session, and that
cross-project links indirect through local proxy nodes. It was deliberately
behaviour-preserving: the namespace contract became correct, but every node and
relationship still lived in one shared `nodes` / `relationships` pair, and every
instance still allocated from the environment's runtime tier
(`?NREF_START` = 1000000).

SP2 gives that contract physical teeth. Each registered project gets its own
table set and its own nref space **starting at 1**. The environment keeps the
shared pair unchanged.

### Position in the program

| #   | Sub-project                 | Status                                        |
| --- | --------------------------- | --------------------------------------------- |
| 1   | Reference & namespace model | Implemented (PR #52)                          |
| 2   | **Physical project store**  | **This spec**                                 |
| 3   | Distribution & residency    | Projects on separate nodes; proxy dereference |
| 4   | Migration                   | Move existing instances into project storage  |

SP2 is confined to **a single Erlang/Mnesia node**. Standing up separate
schemas, fragmentation, or cross-node placement now would front-load SP3's
hardest concerns without the distribution requirements that justify them.

## 2. Goal

Make a project's instance space physically separate and independently
numbered, so that:

- the nref-collision correctness defect is closed by construction — project A's
  instance `5`, project B's instance `5`, and environment `5` (Root) are three
  distinct records in three distinct tables;
- the SP1 resolution seam performs real environment-vs-project routing;
- the project handle binds to physical storage;
- a project's storage is a **single relocatable unit** (tables plus its own
  allocator), which is precisely what SP3 needs to move.

## 3. Storage layout

| Store         | Tables                                           | Allocation                                   |
| ------------- | ------------------------------------------------ | -------------------------------------------- |
| Environment   | `nodes`, `relationships`                         | `graphdb_nref` + `rel_id_server` — unchanged |
| Project `<A>` | `nodes_<A>`, `relationships_<A>`, `counters_<A>` | in-store counters, from 1                    |

`<A>` is the project's **environment anchor nref** — the `kind = instance` node
under `Projects` (bootstrap nref 5) created by `register_project/1`. It is
already unique and already persistent, so project storage needs no new identity
scheme.

`relationships_<A>` carries the same secondary indexes as the environment's
table (`source_nref`, `target_nref`), preserving O(1) forward and reverse
traversal within a project.

All three tables are `disc_copies`, matching the environment.

### Why per-project tables rather than a discriminator column

Adding a project column to the shared tables would leave the primary key
globally scoped, which is the defect SP2 exists to close: allocator-from-1 is
only safe when the key space is physically partitioned. Separate tables also
make a project's storage a unit SP3 can relocate or replicate on its own.

## 4. Identity and allocation

`counters_<A>` holds two keys, `nref` and `rel_id`, each bumped with
`mnesia:dirty_update_counter/3`.

The counter lives **in the project's own store** rather than in a process or a
shared allocator table. Three consequences, all intentional:

1. **The allocator travels with the store.** SP3 relocates a project by moving
   its tables; the allocator comes along with no separate migration step.
2. **No new process.** A central allocator gen_server keyed by project would be
   one more shared singleton that SP3 would have to split apart again.
3. **No gen_server call on the write path.** This is load-bearing. The project
   write path currently calls `graphdb_nref:get_next/0` and
   `rel_id_server:get_id_pair/0` — both gen_server calls, both of which must be
   made *outside* any Mnesia transaction fun. Replacing them with a dirty
   counter update **removes** two gen_server calls from the project write path.

Allocation still happens **outside** the transaction fun.
`mnesia:dirty_update_counter/3` is a dirty operation that does not participate
in the surrounding transaction, so calling it inside a transaction that Mnesia
restarts would burn ids for no benefit. Ids orphaned by an aborted transaction
remain the accepted tradeoff, unchanged from today and harmless given an
unbounded monotonic space.

**First allocation yields 1.** `mnesia:dirty_update_counter/3` on a key that has
never been written creates it with the increment as its value, so the first
`dirty_update_counter(counters_<A>, nref, 1)` returns `1`. `register_project/1`
therefore does **not** need to seed the counter keys, and the first instance in
a project is nref 1 — not 0, and not 2.

The environment's own allocation is untouched: `graphdb_nref` and
`rel_id_server` continue to serve environment nodes and environment
relationship rows, including the environment-resident instances listed in §6.

## 5. The `Project` handle

### Naming correction

SP1 shipped a `Session` first argument on the project write path. That value
was in fact a *project handle* wearing the wrong name. SP2 renames it
`Project` across the project-scoped API. Because the SP1 value was inert
(validated for shape, never used to route), the rename carries no behavioural
risk.

`Session` is reclaimed for the genuine higher-level concept — see §8.

### Shape and lifecycle

```erlang
graphdb_project:open(ProjectNref) ->
        {ok, Project} | {error, not_a_project} | {error, no_store}.
```

`Project` is an **opaque plain value** carrying the resolved table names:

```erlang
#{anchor   => Nref,
  nodes    => nodes_N,
  rels     => relationships_N,
  counters => counters_N}
```

Plain value, resolved once at `open/1`, threaded as data — consistent with the
transaction seam, which runs in the caller's process. Resolution is **pure**,
so dereferencing the handle inside a transaction fun involves no gen_server
call and cannot deadlock. This is the same discipline SP1's session followed,
now made load-bearing.

`register_project(Name)` creates the anchor node in the environment **and**
creates the three tables. `mnesia:create_table/2` is a schema operation and
cannot run inside a transaction, so table creation happens outside the anchor
write; registration is therefore not atomic end-to-end and must be idempotent
on re-run (create-if-absent for both anchor and tables).

Because the tables are `disc_copies`, they survive restart: `open/1` works on a
later boot with no re-registration.

`open/1` returns `{error, no_store}` for an anchor that exists without tables —
the state a project registered before SP2 would be in. SP4's migration is what
resolves that state; SP2 reports it rather than silently creating an empty
store.

`is_project/1` is unchanged: membership under `Projects` (nref 5).

## 6. Routing

The authoritative rule is the **home-relative** map in the parent design's §3
(amended 2026-08-02 alongside this spec). SP2 is where it becomes executable.

`graphdb_ns` gains the home-store parameter:

```erlang
target_namespace(Home, TargetKind)

namespace_of(target_nref) = target_namespace(Home, target_kind(Characterization))
namespace_of(source_nref) = target_namespace(Home, target_kind(Reciprocal))
```

This is where `graphdb_ns` stops being the intentionally-unused classifier SP1
shipped and becomes the live router.

**The arity-1 forms are replaced, not kept alongside.** `namespace_of/1` and
`target_namespace/1` become `namespace_of/2` and `target_namespace/2`, both
taking the home store as the first argument. `graphdb_ns` has zero production
callers today (SP1 shipped it as a tested classifier ahead of its consumer), so
replacement costs nothing and avoids leaving a subtly-wrong arity-1 form in the
tree for someone to call. The six EUnit tests written against the arity-1 forms
are rewritten table-driven across both home values, which also gives the
amendment in the parent design's §3 direct test coverage.

### Environment-resident instances

`kind = instance` does **not** imply project residency. Three instance node
populations live in the environment and stay there in SP2:

| Population              | Location                           |
| ----------------------- | ---------------------------------- |
| Project anchor nodes    | under `Projects` (nref 5)          |
| Language instance nodes | under `Languages` (nref 4)         |
| Rule instance nodes     | instances of the rule meta-classes |

The home-relative rule handles these correctly without special-casing: they
live in environment rows, so their references resolve environment.

### Threading boundary

Environment-only modules keep the **literal** table names `nodes` and
`relationships`:

| Module              | Sites | Scope                                     |
| ------------------- | ----- | ----------------------------------------- |
| `graphdb_class`     | 26    | environment only                          |
| `graphdb_rules`     | 23    | environment only (rule instances are env) |
| `graphdb_attr`      | 20    | environment only                          |
| `graphdb_language`  | 16    | environment only                          |
| `graphdb_bootstrap` | 3     | environment only                          |
| `graphdb_project`   | 3     | environment only (anchor writes)          |
| `graphdb_nrefs`     | 1     | environment only                          |
| `graphdb_instance`  | 25    | **project**                               |
| `graphdb_mgr`       | 13    | **mixed**                                 |
| `graphdb_query`     | 5     | **mixed**                                 |

Roughly 43 project-touching sites take their table names from the handle;
roughly 92 environment-only sites are untouched.

This asymmetry is deliberate, not merely economical. Under SP3 the environment
is replicated by ordinary Mnesia `disc_copies` across nodes and **keeps its
table name**; Mnesia provides location transparency. The environment table name
therefore never needs to be a variable, even under distribution.
Parameterising it would add ~92 sites of churn to buy symmetry with a singleton
that is permanent by design. A module using the literal name is thereby
self-documenting as environment-only.

The two modules whose environment-only status carried real risk were checked
against the tree rather than assumed, because if either were mixed the split
above and the self-documenting claim would both be wrong:

- **`graphdb_class`** — all 26 sites read `ClassNref`, `AttrNref`, or a
  taxonomy `ParentNref`. Qualifying-characteristic inheritance walks the
  taxonomic DAG over class nodes only. No instance read. Confirmed
  environment-only.
- **`graphdb_rules`** — all 23 sites read rule nodes, class nodes, template
  nodes, relationship-attribute nodes, or rule-meta-class instances (which are
  themselves environment-resident, per §6). Rule *planning* is driven by a
  `ClassNref` and produces a plan that `graphdb_instance` executes; the module
  never reads the instance graph and never calls `create_instance`. Confirmed
  environment-only.

The remaining per-module counts are a survey of the current tree, not a
contract; the plan re-checks a module's scope before threading it.

### Reconciling the `graphdb_rules` scope tag

`graphdb_rules` already carries a scope parameter on its entire public API —
`Scope :: environment | {project, _}` — predating SP1. Every `{project, _}`
clause is currently a stub returning `{ok, []}`, `not_found`, or a rejection;
project-scoped rules are deferred.

This is a **third** name for the concept SP1 called `Session` and SP2 calls
`Project`. SP2 aligns it: the project arm becomes `{project, Project}`,
carrying the handle rather than an unspecified term. The stub clauses stay
stubs — SP2 adds no project-rule behaviour — but the shape is then correct for
whenever that work lands, and the codebase stops carrying three vocabularies
for one idea.

### Transactions span both stores

`graphdb_mgr:transaction/1` is unchanged. A single Mnesia transaction on one
node may touch the environment tables and one project's tables together, which
is what makes the atomicity guarantee in §7 for `mutate/2` and for
instance-to-class membership writes hold without new machinery.

## 7. API shape

| Surface                                                                                                                             | Change                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| project writes — `create_instance`, `add_relationship`, `remove_relationship`, `update_relationship(_both)`, `add_class_membership` | `Session` parameter renamed `Project`; now routes rather than merely validating   |
| instance reads — `get_instance`, `children`, `compositional_ancestors`, `resolve_value`                                             | gain a `Project` parameter                                                        |
| `graphdb_query`                                                                                                                     | the query session gains a `Project` field, set when the query session opens       |
| `graphdb_mgr:get_node/1`                                                                                                            | stays environment-only; new `get_node/2` takes a `Project`                        |
| `mutate/1`                                                                                                                          | new `mutate/2` takes a `Project`; `mutate/1` remains for environment-only batches |
| environment ops — `create_class`, `create_attribute`, rules, language registration                                                  | unchanged; no handle                                                              |
| `graphdb_rules` scope tag                                                                                                           | `{project, _}` becomes `{project, Project}`; the clauses stay stubs — see §6      |

### Why instance reads are forced

Under allocator-from-1 a bare nref is meaningless at an API entry point:
`get_instance(5)` has no global table to look in. SP1 deferred read routing;
SP2 cannot. This also means SP2 **cannot be sliced** into "write path first,
reads later" — writes landing in project tables while reads still hit `nodes`
would leave the system incoherent between slices. Project tables, allocator,
routing, write path, and instance reads form one unit.

### Why the query engine takes its `Project` from the query session

`graphdb_query` consumes the instance reads, so it must supply a `Project`.
Placing it in the existing query session rather than in every entry-point
signature keeps the change to a single argument at query-session open. It is
also a step toward §8: the query session is already a per-client state bag, so
holding the primary project is the shape that concept wants, reached from the
consumer side rather than designed top-down.

### Why one project per `mutate` batch

A batch may mix environment and project mutations, but spans **at most one
project plus the environment**. Allowing a per-mutation project would let one
atomic batch touch two project stores. That is satisfiable today — one node,
one transaction — but SP3 places projects on different nodes, potentially in
different data centers with an air gap between them, at which point such a
batch becomes a distributed transaction across stores that may not be mutually
reachable. "One project plus the environment" stays satisfiable under SP3
because the environment is reachable or replicated at every location by design.
Constraining this now avoids building a capability SP3 would have to withdraw.

## 8. `Session` — deferred

`Session` is reserved for a higher-level, per-user/per-client concept: a
container for the state needed to disambiguate that client's operations —
a primary `Project`, a primary language, and whatever else later proves to need
disambiguation. It is decomposed at a high level into the concrete handles the
lower functions take: store-touching functions receive a `Project`;
language-sensitive functions receive a language.

Consequently the multi-project ambiguity that a session-as-parameter would
create cannot arise: by the time a store function is called, the caller holds a
`Project`, which names exactly one store. "Several projects open at once"
becomes purely a `Session`-level concern — which project is primary, how a
client switches — entirely outside the routing path.

SP2 does **not** build `Session`. Its content is driven by consumers that do
not exist yet, so building the container now would mean guessing its shape.
It is tracked as its own item in `TASKS.md` for design later.

## 9. Out of scope

- **Existing instance data.** Instances already sitting in the shared `nodes`
  table are orphaned the moment writes route to project tables. SP4 owns
  migration; development and test environments start fresh. Recorded here so it
  is not discovered during implementation.
- **Project-scoped language overlays** (`language_<code>_<anchor>`) and
  project-scoped rule instances. Language and rule instances stay
  environment-resident in SP2.
- **Proxy creation and dereference** — SP3. SP1's `proxy_coordinates/1` still
  assumes a well-formed proxy; the malformed case is handled when creation
  lands.
- **Distribution, residency, environment replication** — SP3.
- **Multi-project sessions** — see §8.

## 10. Test surface

Every CT suite writes instances through the `sess()` helper introduced in SP1;
it becomes `proj()`, returning a `Project` handle over a registered project.

`graphdb_instance_SUITE`'s table-size delta assertions measure `nodes` and
`relationships` directly and must move to the project tables. SP1 hit a related
problem — a lazily-registered project wrote arc rows inside a measured
before/after window, requiring a pre-warm in `init_per_testcase`. The same
hazard applies to project table creation, which is why this is an explicit plan
item rather than absorbed as incidental churn.

Suites that assert on exact nrefs must be reviewed: instance nrefs move from
the environment runtime tier (≥ 1000000) to per-project values starting at 1.

## 11. Risks

| Risk                                                                   | Mitigation                                                                                                                                     |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| A module surveyed as environment-only turns out to read instance nodes | The two high-risk modules (`graphdb_class`, `graphdb_rules`) are verified against the tree in §6; the plan re-checks the rest before threading |
| Registration is not atomic (schema ops cannot run in a transaction)    | `register_project/1` is idempotent: create-if-absent for both anchor and tables                                                                |
| Table proliferation — three Mnesia tables per project                  | Accepted at SP2's scale; fragmentation and placement are SP3 concerns                                                                          |
| Test churn larger than estimated, since instance nrefs change value    | Scoped as an explicit plan item (§10) rather than absorbed mid-implementation                                                                  |
