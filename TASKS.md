<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Remaining Tasks

What is left to build, grouped by area. None of these blocks the others
in a strict gate the way earlier feature phases did; the rule-engine
items build on one another, but the write-path, multi-project, and
operational tracks are independent and can be picked up in any order.

The kernel is functional: bootstrap, the attribute library, the
taxonomic and compositional hierarchies with four-level inheritance,
templates, the multilingual overlay, the query language, and the rules
data model with its composition and connection firing engines have all
landed. Completed work — with its original phase labels and decision
logs — is archived in [`docs/archive/TASKS-DONE.md`](docs/archive/TASKS-DONE.md).

The canonical model is [`docs/TheKnowledgeNetwork.md`](docs/TheKnowledgeNetwork.md);
the current architecture is [`docs/Architecture.md`](docs/Architecture.md).

---

## Rule Engine — completing the firing engine

The rules data model, the composition firing engine (mandatory / auto /
propose modes), and the connection firing engine (resolver-driven
mandatory / auto / propose) are implemented in `graphdb_rules` and
`graphdb_instance`. The remaining work is the rest of the engine that
consumes the rule data: conflict resolution, the interactive
instantiation modes, and reactive learning. The durable design contract
is `docs/designs/f4-graphdb-rules-design.md`.

### Conflict precedence — IMPLEMENTED (F4 B5)

When a class and its taxonomy ancestors each attach a rule that touches
the same component type or connection, the effective-rules gather returns
them additively, nearest-first, and resolves nothing. Horizontal
conflict resolution is now applied at firing time by a **conflict
resolver** threaded through `create_instance/5`: the nearest-level member
of each conflict group wins by mode priority (mandatory > auto >
propose), surviving Min is the winner's and Max is the greatest across
winner + dropped losers, and a loser is demoted to `propose` only when it
and the winner both carry a non-default template. The default policy is
`graphdb_rules:default_conflict_resolver/0` (injected by `/3` and `/4`);
callers can override it via `/5`. Design
`docs/designs/f4-phase-b5-conflict-precedence-design.md`; the division is
also sketched in `docs/designs/f4-graphdb-rules-design.md` §11.

**B5 follow-up — equidistant-diamond precedence.** The nearest-level
resolution assumes a distinct owning class per taxonomic distance (a
linear ancestor chain). An equidistant multi-parent diamond — two
parents at the same taxonomic distance, each attaching a conflicting
rule on the same child — resolves by `graphdb_class:ancestors/1` BFS
order rather than by mode-priority arbitration across the equidistant
parents. Revisit if equidistant-diamond ontologies become common.

### Instantiation engine — guided and automatic modes

Spec §9. Two creation modes, chosen by the ontology rather than the
kernel:

- **Guided** — the engine presents valid options one attribute at a
  time, using ontology rules to constrain the choices at each step.
- **Automatic** — values are derived entirely from existing knowledge,
  with no user interaction.

### Reactive learning

Spec §11. The ontology grows from observed use, not only from explicit
authoring:

- **Naming-convention learning** — when an attribute value is set, scan
  the other attribute-value pairs on the same instance for substring
  matches; when the new value is composed of existing attribute values,
  encode that pattern as a class-level rule so future instances populate
  the attribute automatically.
- **Connection-pattern learning** — when a connection is made, record
  the `(source class, template, target class, connection type)` tuple
  and accumulate the observations into connection rules that guide
  future connections of the same kind.
- **Report-driven learning** — treat the firing report the engine
  already emits (the `proposed` / `auto` / `required` / `connected` /
  `not_connected` outcomes) as a feedback signal. Observe which
  proposals a caller accepts versus ignores, and which `required`
  connections get satisfied after the fact, then feed the accumulated
  signal back into the rule set — adjusting a rule's mode or
  multiplicity, or promoting a recurring manually-made pattern into a
  new rule.

---

## Write-path completion

`graphdb_mgr` routes node and relationship creation to the workers. The
gaps that remain are node mutation, relationship mutation, the template
attribute list, and wiring the multilingual write path. They are
independent and broken into slices A–E below. `graphdb_mgr` owns the
generic low-level node/relationship CRUD; type-specific behaviour
delegates to the owning worker.

### Transaction-layering seam (slice A prerequisite) — IMPLEMENTED

The decided convention for all write-path mutation: separate the Mnesia
transaction boundary from the CRUD logic, so operations compose into one
atomic transaction without nesting.

- **Tier 1 — in-transaction primitives.** Assume they already run inside
  an Mnesia activity; do their reads + writes with bare Mnesia ops; signal
  failure via `mnesia:abort/1`. They never open a transaction, so they
  compose.
- **Tier 2 — single-op public API** (e.g. `graphdb_mgr:delete_node/1`).
  Owns the transaction: static guards, then
  `mnesia:transaction(fun() -> Primitive end)`, mapping `{atomic, R}` →
  `{ok, R}` and `{aborted, Reason}` → `{error, Reason}`.
- **Tier 3 — batch / composite** (a future `mutate([Mutation])`, or
  "delete an instance with its parts"). Wraps one transaction and calls
  the tier-1 primitives directly — never the tier-2 wrappers; no nested
  transactions.

This slice delivers the **minimal seam only**: the convention plus a
shared transaction-runner helper in `graphdb_mgr`, with tests proven
against a sample primitive. No existing write op changes. `delete_node`
and `remove_relationship` adopt it as their first consumers.

Tracked follow-ups (not in the seam spec):

- **Retrofit existing write ops** — IMPLEMENTED. Full sweep: all 40
  `mnesia:transaction` sites across the six workers + bootstrap now route
  through `graphdb_mgr:transaction/1` (the single `{atomic,_}`/`{aborted,_}`
  mapping point). Behaviour-preserving; existing tests unchanged, +2 new
  instance CT cases (`characterization_not_found`/`reciprocal_not_found`
  arms). Design `docs/designs/transaction-seam-retrofit-design.md`; plan
  `docs/superpowers/plans/2026-06-20-transaction-seam-retrofit.md`.
- **Atomic `add_relationship`** — IMPLEMENTED. `do_add_relationship/7`'s five
  separate transactions (validate endpoints → resolve classes → resolve
  template → validate scope → write) are collapsed into one
  `graphdb_mgr:transaction/1` (TOCTOU isolation). The four single-use phase
  helpers were converted in place to in-txn (abort-based) form; a private
  `class_of_in_txn/1` was added (`do_class_of/1` keeps its own txn for its
  public caller); `build_connection_rows` was split into `/6` (allocates) +
  `/7` (pure) so the rel-id pair is allocated up-front outside the
  transaction. Behaviour-preserving; existing `add_relationship` suite
  unchanged, +2 new instance CT cases (`source_has_no_class` /
  `target_has_no_class`). Design
  `docs/designs/atomic-add-relationship-design.md`; plan
  `docs/superpowers/plans/2026-06-21-atomic-add-relationship.md`.
- **Batch `mutate([Mutation])`** — the tier-3 entry point.
- **Converge default-template name search** — `graphdb_class` carries two
  copies of the default-template name-search walk: the gen-server
  `do_find_template_by_name/2` (own txn) and the tier-1
  `default_template_in_txn/1` (PR 1). `do_default_template/1` already wraps its
  own transaction, so it could be rewritten to call `default_template_in_txn/1`
  inside that txn, removing the duplication.
  Deliberately deferred (the duplication is sanctioned project precedent);
  a future cleanup, not blocking anything.

### Node deletion (slice A) — IMPLEMENTED

Design: `docs/designs/delete-node-soft-retire-design.md`. Delivered:
`graphdb_mgr:retire_node/1` / `unretire_node/1` (idempotent, permanent-tier
guard), `graphdb_attr` seeds the `retired` boolean marker, `graphdb_instance`
refuses retired nodes as new targets/parents/endpoints.

Decided policy: **soft-retire, applied uniformly to all runtime nodes.** Two
operations, `graphdb_mgr:retire_node/1` and its inverse
`graphdb_mgr:unretire_node/1`, mark a node retired (a boolean `retired`
lifecycle AVP on the node row); the node and its arcs stay in Mnesia, and
the public `get_node/1` returns `{error, retired}` for a retired node.
Because nothing is removed, no arc or cache is ever orphaned — so the
operation needs **no environment-vs-project discriminator**, and
refuse-if-referenced is not required for integrity. Retire additionally
blocks a retired node from taking on **new** participation (new instance
target/parent, new arc endpoint); existing structural participation is left
intact.

`delete_node/1` is **left untouched** (still `{error, not_implemented}`) and
reserved for a future *real* (hard) delete; `retire_node`/`unretire_node`
refuse the whole permanent tier (`nref < ?NREF_START`) with a new
`permanent_node_immutable` atom. Built on the seam (`transaction/1`, merged
in PR #41).

This is forward-compatible with the planned history / versioning /
bounded-lifetime feature: retirement is a degenerate lifetime bound, and a
later purge pass under that feature reclaims retired nodes once it defines
what is safe to forget — so mistakes are hidden now without being
destroyed.

**Superseded:** the earlier refuse-if-referenced *hard-delete* policy. A
hard-delete fast-path for project instances — where dependencies are
local and knowable — is deferred behind the project-boundary work below
(it has no distinguishable node population until projects are physically
realized) and is where the reserved `delete_node` eventually lands.

Follow-ups this design adds:

- **Retired rules must not fire.** A retired `graphdb_rules` rule node is
  still reached through existing structure, so retiring it does not stop it
  firing. Exclude retired rule nodes at the firing read chokepoint
  (`effective_rules_for_class` / `effective_connection_rules`). Deferred
  from slice A to keep that slice scoped to the retire mechanism.
- **Unify permanent-tier immutability.** `delete_node`'s category-only
  guard (`category_nodes_are_immutable`) is too narrow — categories are not
  the only permanent nodes. When the real `delete_node` lands, its guard
  (and `update_node_avps`') should refuse the whole permanent tier,
  consistent with `retire_node`'s `permanent_node_immutable`.

### Project boundary (architectural; prerequisite for the delete hard-delete fast-path)

The environment/project split described in the knowledge model is not
physically realized. Today there is a single shared `nodes` /
`relationships` pair; instances draw nrefs from the environment runtime
allocator (`graphdb_nref`); and the Projects category (`nref` 5) is a bare
scaffold with nothing attached. Consequently a project instance is not
reliably distinguishable from an environment instance-kind node (e.g. a
rule), and there is no project-local identity space.

Until this exists, several things stay blocked or degraded:

- the delete hard-delete fast-path for project instances (slice A above);
- project-scoped rules (`graphdb_rules` returns
  `project_rules_not_yet_supported`);
- any per-project isolation, addressing, or lifecycle.

How projects are separated, identified, and addressed is an **open
architectural question to be brainstormed** — this entry records the need
and what it unblocks, not the solution.

### Retired-node purge (deferred; depends on the history/versioning feature)

Soft-retire (node deletion, slice A above) hides nodes without removing
them, so retired rows accumulate. Reclaiming them is a separate
**asynchronous background operation** — scheduled or explicitly triggered,
never part of the synchronous delete path. It can run safely only once the
planned history / versioning / bounded-lifetime feature defines what is
safe to forget (e.g. a retired node past its lifetime bound with no live
references). Scheduling, triggering, batching, and traversal are an open
design — recorded here as a need, not a solution.

### Node AVP update (slice B)

`graphdb_mgr:update_node_avps/2` still returns `{error, not_implemented}`:
basic AVP merge/replace + validation on a node row. Independent. Mirrors
the arc-AVP edit in slice E.

### Template attribute list and instance-only enforcement (slice C, depends on slice B)

A template currently carries only a name and its compositional arc into
the owning class — there is no per-template list of which attributes the
template scopes. Without it, the class write-side cannot distinguish two
categories of attribute a class declares:

- **Class-bindable** — the class may supply a value (or a useful
  default); instances inherit it and may override. *Example:
  `num_wheels = 4` on a Car class.*
- **Instance-only** — the class declares the attribute as relevant, but
  binding a value at the class level is a category error; the value is
  meaningful only per instance. *Example: `serial_number`,
  `owner_name`.* Binding a class-level value for such an attribute should
  be rejected.

The distinction is per-class, per-template — the same attribute may be
class-bindable in one class's template and instance-only in another's.
Build the template attribute list, then enforce instance-only rejection
in `create_class` and `update_node_avps`. The unified qualifying-
characteristic AVP shape (a declared-but-unbound attribute carries
`value => undefined`) already accommodates an instance-only attribute
naturally — it stays `undefined` at every class level.

### Relationship mutation (slice E)

Only `add_relationship` (create) exists today — there is no remove or
update. `remove_relationship` deletes both directed rows of a logical edge
atomically and fixes the `parents`/`classes` caches on the referrers; it
shares the arc-removal primitive with `delete_node` (slice A).
`update_relationship` changes `characterization` / `target_nref` /
`reciprocal` / AVPs; the AVP-only edit mirrors `update_node_avps`
(slice B). Built on the transaction seam.

### Multilingual write-path integration (slice D)

Now unblocked — the `graphdb_mgr` write-side is wired. When an
environment node is created, the write path must additionally:

1. Create the node atomically in one Mnesia transaction.
2. Post-commit and outside that transaction (best-effort), call every
   registered translation hook with the new nref and its English AVPs.
3. If a session language list is supplied with labels, call
   `set_labels/3` for each language.

Steps 2–3 are deliberately not atomically coupled to step 1: a failed
hook or a missing language label does not roll back node creation. Do not
auto-duplicate environment labels into dialect overlay tables — a dialect
override is an explicit authoring decision, never inferred. Project-
instance label writes depend on the multi-project work below (project-
scoped overlay tables).

---

## Multilingual overlay — structural gaps

Two items deferred from the original multilingual work that have not yet landed.

### Language superclass hierarchy

`lang_human` (the root class for all human natural languages) is currently
a direct child of `Classes` (nref 3) with no intermediate superclass. The
architecture specifies a `Language` superclass node sitting above `lang_human`
under `Classes`. Two implementation paths:

- **Option A** — Add `Language` as a bootstrap node in `bootstrap.terms`
  and make `lang_human` a child of it there. Structurally cleanest; the
  node belongs to the permanent scaffold, not a worker's `init/1`.
- **Option B** — Seed `Language` at `graphdb_language:init/1` time and call
  `graphdb_class:add_superclass/2` to place `lang_human` under it. No
  bootstrap change required.

Decide and implement one option.

### Domain subcategory connection rules

When a language instance is created at runtime (e.g., French), it is not
automatically placed under the appropriate domain subcategory node (nrefs
32–35: Human Languages, Formal Languages, Diagram Languages, Renderers).
English is wired in `bootstrap.terms` directly; runtime-created languages
are not.

The connection firing engine is now implemented (`graphdb_instance`,
`graphdb_rules`). Add a connection rule to `lang_human` (and the equivalent
class nodes for the other language kinds) that fires at instance creation
and connects the new language instance to the correct subcategory. The
resolver is supplied via `create_instance/4`.

---

## Multi-project sessions

Every public API already accepts a `Scope` of `environment | {project,
_}`; the handlers serve the `environment` scope only and reject or empty
`{project, _}` requests. This area turns project scope on:

- Session state carrying a list of `{ProjectId, AnchorNref}` (a list,
  not a singleton).
- Cross-project arc traversal — an arc whose target is a project nref
  carries `target_kind` but not *which* project; the session must supply
  that context.
- Session-level priority resolution — environment first, then project
  A's rules, then project B's, or a declared order.
- Project-scoped overlay tables for rule instances and for language
  labels (`language_<code>_<anchor_nref>`).

**Open question — multi-class instance creation.** `create_instance`
stays single-class: one primary driving class. Additional class
memberships are expressed as rules *on* the primary class. The
load-bearing question is whether the effective-rules gather should
recurse transitively into a conferred class's rules — which reframes
multi-class creation from an API-signature problem into a gather-
transitivity problem. A class-list / signature-widening framing was
considered and rejected; see `docs/designs/f4-phase-b4-connection-firing-design.md` §7.

---

## Operational and lifecycle

No feature dependencies; interleave at any point.

### Transaction observability

Every write-path worker allocates node nrefs and relationship row IDs
*outside* the `mnesia:transaction/1` that writes the rows, so the
transaction fun stays free of side-effects when Mnesia re-runs it on a
lock conflict. The deliberate cost is that an aborted transaction orphans
the already-allocated ids — harmless given the unbounded monotonic nref
space, but currently unmeasured.

Add a development helper that snapshots Mnesia's cumulative counters
(`transaction_restarts`, `transaction_failures`, `transaction_commits`,
`transaction_log_writes` via `mnesia:system_info/1`) around a fun and
returns the deltas. Decide whether the write paths warrant their own
per-callsite `{atomic, _}` / `{aborted, _}` counters or whether the
global counters suffice, and document the decision. Confirm the
allocate-outside-transaction rationale carries an inline comment at each
allocation site. Observability only — no behavioural change to the write
paths.

### Hot code upgrade — `code_change/3` *(deferred)*

`code_change/3` is unimplemented in every gen_server (`nref_allocator`,
`nref_server`, and all `graphdb_*` workers). Implement when the first
hot-upgrade deployment is planned — premature until there is a versioned
release to upgrade in place.

### Phased application startup *(deferred)*

No `.app.src` defines `start_phases`, so `start_phase/3` is never called.
Revisit when an externally-visible entry point (an API server or socket
listener) is added to `seerstone` that must not accept connections until
the full graphdb stack is bootstrapped — phased startup then closes the
window between port-open and data-ready.
