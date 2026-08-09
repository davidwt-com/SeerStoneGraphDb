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
- **Batch `mutate([Mutation])`** — IMPLEMENTED. Tier-3 batch entry point
  `graphdb_mgr:mutate/1`: applies an ordered list of `add_relationship` /
  `retire_node` / `unretire_node` mutations atomically in one
  `graphdb_mgr:transaction/1`, composing tier-1 primitives directly. Opaque
  bare-reason contract (`{ok, [ok, ...]}` | `{error, Reason}`, whole-batch
  rollback, `mutate([]) -> {ok, []}`). Phase 2 resolves the seeded attr
  nrefs once and allocates one rel-id pair per `add_relationship` outside
  the transaction; phase 3 folds the prepared list in order. Required one
  behaviour-preserving extraction —
  `graphdb_instance:add_relationship_in_txn/9` (now `/10` — SP2 added a
  leading `Home`). Design
  `docs/designs/batch-mutate-design.md`; plan
  `docs/superpowers/plans/2026-06-24-batch-mutate.md`.

  Deferred extensions (design §1.3): the mutation grammar now covers
  `add_relationship` / `retire_node` / `unretire_node` / `update_node_avps`.
  Extend the grammar to the remaining mutation kinds — `create_instance` /
  `create_class` / `create_attribute`, `delete_node` (real hard delete),
  `remove_relationship` / `update_relationship` (slice E) — as each grows a
  tier-1 primitive (creates also need a txn-safe nref-allocation path, since
  today they allocate through a gen_server). **Symbolic back-references between
  mutations** (`create A; relate A→B`) are a further extension on top of those:
  they need the create primitives plus a bootstrap-style symbol table, and are
  out of scope until creates land. Per-mutation indexed error reporting was
  rejected on principle (design §3.3), not deferred — no entry needed.
- **Converge default-template name search** — IMPLEMENTED. The shared walk is
  now `graphdb_class:find_template_by_name_in_txn/2` (exported tier-1
  in-transaction primitive). `default_template_in_txn/1` delegates to it with
  `?DEFAULT_TEMPLATE_NAME`; `do_find_template_by_name/2` wraps one
  `graphdb_mgr:transaction/1` around it (preserving the `{error,_}->not_found`
  swallow). Behaviour-preserving; +3 CT cases. Design
  `docs/designs/converge-default-template-name-search-design.md`; plan
  `docs/superpowers/plans/2026-06-22-converge-default-template-name-search.md`.

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

### Project boundary — RESOLVED by SP1 + SP2

This entry recorded that the environment/project split was not physically
realized: a single shared `nodes` / `relationships` pair, instances drawing
nrefs from the environment allocator, and the Projects category (`nref` 5)
a bare scaffold. **SP1 (reference & namespace model) and SP2 (physical
project store) closed this** — see *Multi-project sessions* below. Each
registered project now has its own `nodes_<Anchor>` /
`relationships_<Anchor>` / `counters_<Anchor>` tables and its own
allocators starting at 1, so a project instance is physically
distinguishable and there is a real project-local identity space.

What this unblocks, and where each stands now:

- the delete hard-delete fast-path for project instances (slice A above) —
  now unblocked, still to be done;
- project-scoped rules (`graphdb_rules` still returns
  `project_rules_not_yet_supported`) — now unblocked, still to be done;
- per-project isolation and addressing — delivered by SP2. Per-project
  *lifecycle* (residency, distribution, migration) is SP3/SP4.

### Retired-node purge (deferred; depends on the history/versioning feature)

Soft-retire (node deletion, slice A above) hides nodes without removing
them, so retired rows accumulate. Reclaiming them is a separate
**asynchronous background operation** — scheduled or explicitly triggered,
never part of the synchronous delete path. It can run safely only once the
planned history / versioning / bounded-lifetime feature defines what is
safe to forget (e.g. a retired node past its lifetime bound with no live
references). Scheduling, triggering, batching, and traversal are an open
design — recorded here as a need, not a solution.

### Node AVP update (slice B) — IMPLEMENTED

`graphdb_mgr:update_node_avps/2` merges a list of AVP updates onto a node
atomically. Tier-2 wrapper owns one `transaction/1`; tier-1
`update_node_avps_in_txn/4` does the in-txn work. Wired as the fourth
`{update_node_avps, Nref, AVPs}` kind in `mutate/1`. Design
`docs/designs/slice-b-update-node-avps-design.md`.

**Follow-up (pre-existing, low priority) — category-node error-shape
divergence.** A category node (nref 1–5) is rejected by the solo path with
`{error, category_nodes_are_immutable}` (the `handle_call` category guard)
but through `mutate/1` with `{error, permanent_node_immutable}` (the static
`tier_guard`, since 1–5 `< ?NREF_START`). Both correctly refuse the write;
only the reason atom differs. The same divergence already exists for
`retire_node` / `unretire_node` through `mutate/1`. Normalising it would
mean teaching `mutate/1`'s static validation to distinguish category nodes
from the rest of the permanent tier (a DB read in phase 1, which today does
no DB access) — not worth it unless a caller needs to branch on the
specific reason. Revisit if that need arises.

### Instance-only qualifying characteristics (slice C) — IMPLEMENTED

A class QC may be marked `instance_only => true`: the attribute is relevant
to instances, but binding a value at the class level is a category error.
Set via `graphdb_class:add_qualifying_characteristic/3` (`#{instance_only =>
true}`) or a `create_class/3` initial AVP. Enforced at three class-level
value-binding gates — `bind_qc_value/3`, `create_class/3`, and
`update_node_avps/2` (the last covers `mutate/1`, both composing
`update_node_avps_in_txn/4`) — each returning `{error,
{instance_only_attribute, AttrNref}}`. Enforcement is local to the class
node written. Design `docs/designs/slice-c-instance-only-qc-design.md`.

**Deferred follow-ons (from slice C):**

- **Template attribute list** — per-template subset/relevance scoping of
  class attributes (`TheKnowledgeNetwork.md` §7). A template currently
  carries only a name and its compositional arc into the owning class; there
  is no per-template list of which attributes it scopes. This is the
  per-class, per-template axis: the same attribute may be class-bindable in
  one class's template and instance-only in another's.
- **Template-bound (variant) values** — templates carrying override values
  stamped into instances at instantiation (e.g. a later custom-colour phone
  variant whose colour is fixed in a template, not on the base class).
- **Inherited instance-only enforcement (C2)** — close the subclass-redeclare
  bypass: a subclass can re-declare a parent's instance-only QC *without* the
  flag via `add_qualifying_characteristic/2`, then bind a value. Local gates
  do not consult the inherited QC set because `collect_qc_avps/1` flattens
  each QC to `{AttrNref, Value}`, dropping the marker. Closing it means
  carrying the flag through `collect_qc_avps/1` / `inherited_qcs/1` and
  having all three gates consult the effective (local + ancestor) QC set.
- **Marker mutability via the general update path** — today `instance_only`
  is settable only at QC declaration (`add_qualifying_characteristic/3`) or
  `create_class/3`; it can be neither set nor cleared through
  `update_node_avps/2` / `mutate/1`. That restriction is a *side effect* of
  slice B's AVP well-formedness check (which rejects any update map whose
  key-set is not exactly `[attribute]` or `[attribute, value]`), **not** a
  deliberate long-term contract decision. Investigate whether toggling a
  QC's instance-only status — and QC-shape edits generally — should be a
  first-class mutation: a dedicated mutation kind, or a widened update
  grammar that admits marker keys, versus remaining declaration-time only.
  Decide and document the intended contract before any caller comes to
  depend on the current behaviour.

### Relationship mutation (slice E) — IMPLEMENTED

Design: `docs/designs/slice-e-relationship-mutation-design.md`; plan
`docs/superpowers/plans/2026-06-28-slice-e-relationship-mutation.md`.

Delivered, **connection-arcs only** (the exact mirror of `add_relationship`;
no `parents`/`classes` cache work — connection arcs are never cached):

- `remove_relationship/3,4` — atomically delete both directed rows of a
  logical connection edge. (The earlier note that it "fixes the caches" and
  "shares the arc-removal primitive with `delete_node`" was aspirational:
  slice A shipped soft-retire only, so no hard-delete primitive exists to
  share, and connection removal needs no cache fix.)
- `update_relationship/4,5` + `update_relationship_both/4,5` — AVP-only edit
  of an existing edge, reusing slice B's `validate_avp_updates/1` +
  `apply_avp_updates/2`. Single-direction is the one tier-1 primitive;
  `*_both` composes it twice with independent `{Fwd, Rev}` lists. The
  `?ARC_TEMPLATE` scope AVP is protected from edit.

Because nothing dedups connection edges at write time, the identity contract
is: `(S, C, T)` (optionally narrowed by `Template`) matches a logical edge;
zero matches → `relationship_not_found`, more than one → `ambiguous_relationship`.
**Remove is edge-level (both rows); AVP update is directed-row-level (one
row).** Built on the transaction seam; all three kinds compose into
`mutate/1`.

Deferred (recorded in the design): structural rewiring (`characterization` /
`target_nref` / `reciprocal` — expressible as `mutate([remove, add])`); a
rel-id-keyed form (the only disambiguator for genuine duplicate edges).

### Compositional arc mutation — `add_parent` / `add_child` / `remove_parent` / `remove_child` (follow-up)

Compositional-hierarchy ("part of") arc creators and removers between
instances: `add_parent(Child, Parent)` / `add_child(Parent, Child)` write a
`kind=composition` arc, and `remove_parent(Child, Parent)` /
`remove_child(Parent, Child)` delete it — all **maintaining the child's
`parents` cache** — the cache-touching counterpart that slice E
(connection-only) deliberately does not cover. The cache-maintenance core
here is also what a future `delete_node` hard-delete and a general
(kind-agnostic) arc remover would reuse. Built on the transaction seam;
tier-1 primitives + tier-2 wrappers + `mutate/1` grammar, with
`verify_caches/0` clean after each.

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

This is a four-sub-project program (design:
`docs/designs/project-env-reference-namespace-model-design.md`, amended for
SP2 by `docs/designs/sp2-physical-project-store-design.md`). SP1 (the
reference & namespace model) and SP2 (the physical project store) are done;
SP3 (distribution & residency) and SP4 (migration) remain.

### SP1 — reference & namespace model — IMPLEMENTED

At the API/code layer only, no `node`/`relationship` record changes:

- **`graphdb_ns`** — pure module encoding the field-role namespace map
  (`namespace_of/1`, `target_namespace/1`): every nref reference resolves to
  `environment | project | home`. The code expression of design §3.
- **`graphdb_project`** — project registry (`register_project/1`,
  `is_project/1`) creating an anchor node under `Projects` (nref 5); project
  session (`open_session/1`, `session_project/1`, `require_session/1`); and
  the canonical project-scoped relationship API surface (env/project split).
- **Proxy representation contract** — a seeded "Remote Reference" class (under
  Classes, nref 3) + `remote_project` / `remote_nref` literal attributes +
  `graphdb_instance:is_proxy/1` / `proxy_coordinates/1` recognizers. Cross-
  project links are local proxy nodes carrying remote coordinates as AVP
  payload; no structural reference ever crosses a project boundary.
- **Required project session on the project write path** — `create_instance`,
  `add_relationship`, `remove_relationship`, `update_relationship`(`_both`),
  and `add_class_membership` take a `Session` first arg and reject a missing/
  invalid one with `{error, invalid_session}`. Behaviour-preserving against
  today's single store (the session is validated but inert until SP2).

**SP1 deliberate deferrals (to SP2+):**

- `mutate/1` and the instance reads (`get_instance` / `children` /
  `compositional_ancestors` / `resolve_value`) stay **namespace-agnostic** in
  SP1 — like `get_node` / `get_relationships`. `mutate/1` is mixed env/project
  (a project session would over-constrain env-only batches); the reads are
  consumed by `graphdb_query`, so gating them would force the deferred
  query-session unification. Their per-namespace routing lands in SP2.
- `proxy_coordinates/1` assumes a well-formed proxy (both AVPs present); it can
  badmatch on a malformed proxy. Harmless until proxy **creation** lands;
  handle the missing-AVP case there. SP2 did not add proxy creation — still
  open, see below.
- Proxy-node creation API and dereference; private environment overlays
  (a private overlay hiding a project's nref-5 anchor); session unification
  with the `graphdb_query` session.

**Resolved by SP2 (below):** the reads' per-namespace routing, and the
`Session`→`Project` rename (`open_session/1`/`session_project/1`/
`require_session/1` are gone; `open/1`/`require_project/1` replace them).
**Still open after SP2:** proxy-node creation API and dereference — carried
forward to SP3 below.

### SP2 — physical project store — IMPLEMENTED

Plan: `.superpowers/sdd/2026-08-05-sp2-physical-project-store/`; design:
`docs/designs/sp2-physical-project-store-design.md`.

- **Per-project physical store** — `graphdb_project:register_project/1` now
  also creates the project's three Mnesia tables: `nodes_<Anchor>`,
  `relationships_<Anchor>`, `counters_<Anchor>` (`<Anchor>` = the project's
  environment anchor nref). `open/1` resolves a registered project nref into
  a `Project` handle `#{anchor, nodes, rels, counters}`; `require_project/1`
  replaces SP1's `require_session/1`. `session_project/1` is removed — the
  handle itself is the only lookup, there is no ambient project context.
- **Per-project allocators from 1** — `next_nref/1` / `next_rel_id_pair/1`
  via `mnesia:dirty_update_counter/3` on the project's own `counters_<A>`
  table. This closes the SP1-era nref-collision hazard: every project's
  nrefs now restart at 1 in an isolated table instead of colliding
  numerically with environment bootstrap nrefs 1–35 (or with any other
  project's nrefs) inside a shared table.
- **Home-relative namespace routing** — `graphdb_ns:namespace_of/2` /
  `target_namespace/2` take a leading `Home :: environment | Project`;
  `node_table/1` / `rel_table/1` map a `Home` to its physical table atom.
  `characterization`/`reciprocal` (arc labels), class nodes, and attribute
  nodes always resolve to the environment; `source_nref`/`target_nref`
  route through `Home`. Instance↔class membership arcs (both directions,
  including the class→instance row whose `source_nref` is an environment
  class nref) are written in the project's own table.
- **`graphdb_instance` fully Project-routed** — the entire write API and the
  instance reads (`get_instance`, `children`, `compositional_ancestors`,
  `class_of`, `class_memberships`, `resolve_value`) take a leading
  `Project`, no longer namespace-agnostic. SP1's `Session` parameter is
  renamed `Project` throughout and is now load-bearing (SP1 validated it
  but it was inert against the single store).
- **`graphdb_mgr` Project-taking twins** — `get_node/2`, `retire_node/2`,
  `unretire_node/2`, `update_node_avps/3`, `delete_node/2`, `mutate/2`, all
  gated by a private `with_project/2`. `mutate/1` stays environment-only by
  design (a batch mixing environment and project mutations has no single
  physical table set to run against once the store is split).
- **`graphdb_query` sessions bind a Project** — `new_session/1`;
  `resolve_home/2` resolves a bare nref by trying the bound project first,
  falling back to the environment, logging on a genuine collision.

**Scope addition beyond the original design** — Task 10 added Project-taking
twins for `retire_node`/`unretire_node`/`update_node_avps`/`delete_node`,
which were not in the original design's API table. Their absence would have
been a live nref-collision hazard post-SP2: a bare-Nref call against these
would resolve against the shared environment table, silently missing or
clobbering project data sitting at the same numeric nref. The twins close
that gap.

**Known gap** — `graphdb_mgr:get_relationships/1,2` has no Project-taking
twin (the only one of the `graphdb_mgr` read/write operations touched by
SP1/SP2 without one). 15 call sites across 11 test functions in
`graphdb_instance_SUITE` / `graphdb_mgr_SUITE` work around it with direct
`mnesia:index_read(graphdb_ns:rel_table(Project), ...)`. A repo-wide grep
found zero production callers, so this is an API-completeness gap, not a
live bug — pick it up when a project-side relationship-read caller appears.

**RESOLVED (query-traversal Home routing) — query traversal silently truncated
environment-only paths under a project-bound session.**
`graphdb_query:session_read_arcs/4` and `is_scaffold_node/2` push every
*arc-discovered* nref through `resolve_home/2`, which was designed for
entry-point nrefs (where no characterization context exists). Mid-traversal
it re-guesses Home per frontier node, so a bootstrap nref that a project
happens to shadow is read from the project instead of the environment.
Reproduced: a `#q_find_path{}` between two runtime-tier environment
attributes whose only path runs through bootstrap nref 6 ("Names") returns
`{ok, no_path}` under a session bound to a project with 21 instances, while
returning the correct 2-hop path under an environment session and under a
1-instance project. Both endpoints are unshadowed, so this is **not** the
documented, tested "endpoint resolves to the project by caller intent"
behaviour of `resolve_home/2` — it is mid-traversal re-guessing.
Because project allocators start at 1, any project with ≥6 instances
shadows nref 6 and any with ≥35 shadows the whole bootstrap scaffold, so
this is high-likelihood, not theoretical. The result is silently wrong: no
error, only a collision warning in the log.

**Implemented.** Half A: `graphdb_ns:arc_target_namespace(Home, Kind, Char)`
derives an arc-discovered nref's store from `#relationship.kind`, with the
29/30 membership pair split on characterization. Half B: the BFS frontier,
visited set, and target comparison are Home-qualified via
`home_id() :: environment | {project, Anchor}`; path edges disclose `home`
when a hop crosses stores; `resume/2` rejects a continuation carrying a
foreign project id. `resolve_home/2` and `session_read_arcs/4` are unchanged
— only `bfs_step/5` changed caller, to `session_read_arcs_home/5`. Design:
`docs/designs/query-traversal-home-routing-design.md`.

Still open, deliberately out of that scope: BFS at an environment-homed node
reads only the environment relationship table, so an environment class cannot
reach its project instances across arc 30 (`?ARC_CLASS_TO_INST`).
`#q_instances_of{}` keeps its `session_read_arcs_home/5` special case. Also
still open: backfilling `target_kind` onto bootstrap arc labels 21–30, which
would let `graphdb_instance:check_target_kind/3` drop its permissive legacy
arm.

**Defect (Important, pre-existing, unrelated to SP2) —
`rel_id_server` counter seeding — IMPLEMENTED (2026-08-09).** Filed as a
one-line typo; it was three defects stacked in the same path, and the typo
was the least of them.

1. `seed_from_mnesia/0` called `mnesia:dirty_foldl/3`, which does not exist
   in OTP 28 (the real function is `mnesia:foldl/3`, and it must run inside
   a transaction). Invisible to the compiler.
2. Its blanket `catch _:_ -> 1` swallowed the resulting `undef` and
   returned **1** — precisely the corrupting value, so the failure was
   silent by construction. Now 1 is returned only for a definite
   `{no_exists, relationships}`; anything else logs and exits
   `rel_id_server_seed`. A "cannot determine the high-water mark" answer
   must never default to the value that collides.
3. **The ordering defect, which the filed report missed and which the other
   two fixes do not close.** Seeding ran from `init/1`, where the table is
   structurally unreadable: `rel_id_server` must start *before*
   `graphdb_mgr` (`graphdb_bootstrap` consumes ids from `get_id_pair/0`),
   but the `relationships` table is not created — and mnesia is not even
   started — until `graphdb_bootstrap:ensure_mnesia/0` runs *inside*
   `graphdb_mgr:init/1`. An eager seed therefore always read "no rows" and
   landed on 1 regardless. Seeding is now **lazy**, on the first
   `get_id`/`get_id_pair` call, by which point bootstrap has run and the
   table is loaded.

Failure mode closed: DETS file lost while the Mnesia `relationships` table
survives (restore, data-dir move, partial recovery) — the counter no longer
restarts at 1 handing out ids that collide with live primary keys, which
`mnesia:write` would then **silently overwrite**.

The `xref_ignores` entry in `rebar.config` that suppressed this is
**removed**; the gate now runs with an empty ignore list. Regression
coverage in `rel_id_server_SUITE` group `seeding` (4 cases); the suite also
now starts mnesia per case, since starting the server with no mnesia at all
— as it used to — is not a state the system can be in.

**Open design question — `TheKnowledgeNetwork.md` §3 says identity is
uniform; SP2 makes that false at the physical layer.** The canonical spec
states ontology nodes and project nodes "share the same identity space."
Post-SP2 each project's allocator restarts at 1, so a bare nref is unique
only within a `Home` — nref 7 in project A, nref 7 in project B, and
bootstrap nref 7 are three different nodes. The SP2 design doc does not
resolve this either; it only notes the *anchor* nref needs no new identity
scheme. Per this repo's rule that `TheKnowledgeNetwork.md` is conceptual
and does not track code, SP2 flagged rather than edited it. Needs a
deliberate call: either the spec records that identity is now
`Home`-relative, or the model asserts a globally-unique identity that the
implementation must eventually restore (e.g. via the deferred non-integer
nref indirection). Not a code defect — a spec/model decision.

**Accepted consequence of `resolve_home/2` (documented, tested, recorded
here so it is a choice and not a surprise).** A project-bound
`graphdb_query` session resolves a bare nref to the project when it exists
in both stores — so environment nodes numerically below the project's
allocator high-water mark become unaddressable through that session.
`#q_get_node{nref = 3}` under a project with ≥3 instances returns the
project's instance 3, not the `Classes` category. This is deliberate
(caller intent) and covered by
`resolve_home_prefers_project_and_logs_on_collision`; it is called out
because the shadowed range grows with every instance created. Distinct
from the traversal defect above, which is *not* intentional.

**Minor — `graphdb_mgr:do_get_node/1` and `/2` diverge on the retired
marker.** The `/1` (environment) form applies a retired-marker check; the
`/2` (Project) form does not. Documented at `graphdb_mgr.erl:186-188`.
Harmless today, but the asymmetry will surprise someone — make them
consistent, or document why they should differ.

### SP3+ — distribution, residency, migration

- **Distribution & residency (SP3)** — projects on separate nodes / locations;
  environment reachability or replication at each location; proxy-node
  creation API and dereference (still open post-SP2, see above).
- **Migration (SP4)** — move existing instances out of the shared environment
  tables into project storage; reassign their nrefs.
- Session state may carry multiple `{ProjectId, AnchorNref}` and a
  cross-project priority order; project-scoped overlay tables for rule
  instances and language labels (`language_<code>_<anchor_nref>`).

**Open question — multi-class instance creation.** `create_instance`
stays single-class: one primary driving class. Additional class
memberships are expressed as rules *on* the primary class. The
load-bearing question is whether the effective-rules gather should
recurse transitively into a conferred class's rules — which reframes
multi-class creation from an API-signature problem into a gather-
transitivity problem. A class-list / signature-widening framing was
considered and rejected; see `docs/designs/f4-phase-b4-connection-firing-design.md` §7.

---

## Client session

A concept named but deliberately not yet designed.

`Session` is intended as a higher-level, per-user or per-client container
for the state needed to disambiguate that client's operations — a primary
project, a primary language, and whatever else later proves to need
disambiguation.

The intent is that a `Session` is used only at a high level and is
decomposed there into the concrete handles the lower-level functions take:
functions that touch a store receive a `Project`; functions that need a
specific language receive that language. Nothing below the top layer sees a
`Session`.

No design work has been done, and none should be inferred from the name.
The container's content is driven by consumers that do not exist yet, so
its shape is deliberately left open. The existing `graphdb_query` session
is the closest thing in the tree today and is the natural candidate for
`Session` to absorb whenever this is picked up.

Note that the parameter SP1 shipped under the name `Session` was in fact a
project handle; SP2 renames it `Project` and frees the name for this
concept.

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
