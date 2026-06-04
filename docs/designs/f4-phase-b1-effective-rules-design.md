<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 Phase B / Division B1 — `effective_rules_for_class/2` — Design

**Status:** Specified. No implementation has begun.

**Parent design:** `docs/designs/f4-graphdb-rules-design.md` (F4 Phase A
landed; this is the first division of Phase B). Resolves that
document's **OI-1** (effective rules / taxonomy walk).

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored
Data), §10 (Composition Rules).

---

## 1. Scope

### 1.1 Phase B division map

Phase B (the rule-*firing* engine) is large. It is split into five
independently shippable divisions, each with its own brainstorm →
design → plan → implement cycle:

| Div    | Subject                                                                        | Depends on |
| ------ | ------------------------------------------------------------------------------ | ---------- |
| **B1** | `effective_rules_for_class/2` — read-side taxonomy walk (no firing)            | Phase A    |
| **B2** | Composition firing engine — `mandatory` + `auto`; cascade; return-shape change | B1         |
| **B3** | `propose` mode + interactive/non-interactive session flag (`graphdb_query`)    | B2         |
| **B4** | Connection firing engine (Mandatory Connections, §10)                          | B1         |
| **B5** | Horizontal conflict resolution / precedence (OI-2) — rules at one class level  | B2         |

This document specifies **B1 only**.

### 1.2 What B1 delivers

A single read-only function on `graphdb_rules` that gathers every rule
attached to a class **and to its taxonomy ancestors**, grouped by the
class it came from, nearest-first, each paired with the deployment
(`mode` / `multiplicity` / `template`) of *that* attachment.

B1 does **not** fire anything, create anything, or resolve any
override/conflict. It is the canonical read the firing engines (B2, B4)
and the conflict resolver (B5) consume.

### 1.3 Vertical vs horizontal

B1 owns the **vertical** dimension only — walking *up* the class
taxonomy so a subclass instance can see its superclasses' rules.
Resolving two rules attached at the **same** class level (horizontal,
OI-2) is **B5**, applied by the engine over B1's output. B1 keeps the
two dimensions cleanly separated.

---

## 2. Architectural Commitments

### B1-D1. Pure gather, not resolve

`effective_rules_for_class/2` returns **every** rule from the class
itself and from every taxonomy ancestor. Nothing is dropped, shadowed,
or deduplicated by content.

**Why.** Override is not always replacement. A parent class can carry a
`mandatory` rule for a relationship while the owning subclass carries
its own rule for the *same* relationship attribute that contributes
**additional** instances (e.g. a higher `multiplicity`). An early
"subclass wins" override would silently lose the parent's mandatory
contribution. B1 therefore surfaces all levels and leaves
additive-vs-shadowing decisions to the firing engine (B2/B5), which has
the firing context B1 does not.

This is choice **A** of the brainstorm (over a self-resolving "effective
set" or a layered both-ways API).

### B1-D2. Element shape carries deployment

Each rule is returned as a pair `{RuleNode, Deployment}`:

```erlang
RuleNode   :: #node{}    %% kind=instance; a rule (content AVPs on the node)
Deployment :: #{mode         => mandatory | auto | propose,
                multiplicity  => pos_integer() | unbounded,
                template      => integer()}
```

**Why.** Per F4 D5/D12 the deployment AVPs (`mode`, `multiplicity`,
`Template`) live on the `applies_to` **arc**, per-attachment — not on
the rule node. The rule node carries only content (`child_class_nref`
etc.). A consumer holding just the node cannot tell that `Vehicle`
attached a rule `mandatory/mult=1` while `SportsCar` attached the same
rule `mandatory/mult=2`. The additive case (B1-D1) is invisible without
the arc AVPs, so the element must carry them. OI-1's literal
`[#node{}]` shape is consequently **insufficient** and is superseded
here.

A `Deployment` map omits any key whose AVP is absent from the arc
(defensive; Phase A always writes all three).

### B1-D3. Ordering by reuse of the canonical ancestor walk

The ancestor sequence is `graphdb_class:ancestors/1` verbatim —
nearest-first BFS over the multi-parent taxonomy DAG, diamond-deduped
(graphdb_class.erl, H3). The class itself is prepended as the
distance-0 head. No new ordering logic; deterministic because
`ancestors/1` is deterministic.

A rule **node attached to two ancestors** (F4 D12 allows reuse) appears
once **per attaching ancestor**, each occurrence carrying that
ancestor's own `Deployment`. This is the natural consequence of
grouping by attachment point.

### B1-D4. Single gather function; consumers filter inline

`effective_rules_for_class/2` is the **only** new function. The
kind-filtered views (composition-only, connection-only) are **not**
separate gather functions — a consumer that wants one kind filters the
gathered result inline (a list comprehension with a meta-class
membership guard, or `lists:foldl`). A formal lazy cursor /
iterator/enumerator abstraction may surface later (B2+) if a consumer
proves the need; it is deliberately not built before then.

This keeps B1 one well-bounded read with no abstraction invented ahead
of a consumer.

### B1-D5. Scope: environment only

`environment` reads the shared ontology. `{project, _} -> {ok, []}`,
mirroring every existing `graphdb_rules` read (F4 D7 / OI-5). The
project-DB read path lands with L6.

### B1-D6. No input validation; unknowns yield `{ok, []}`

A non-existent or non-`class` `ClassNref` is not rejected — the result
is `{ok, []}`, matching how the existing `rules_for_class/2` tolerates a
bad nref (no validation; an empty `attached_rules/2` read).

Mechanism (note — *not* "silent skip"): `graphdb_class:ancestors/1`
returns `{error, not_found}` / `{error, not_a_class}` for a bad
**starting** class (graphdb_class.erl `do_ancestors/1`); it skips
unknown nodes silently only *mid-walk*. So B1's ancestor helper must
**map that error to an empty ancestor set** rather than assume an `{ok,
Nodes}` reply. Combined with the (also empty) direct-attachment read,
the net result for a bad nref is `{ok, []}`. B1 invents no new
validation surface, but it does explicitly catch the ancestor-walk
error — see §4.2.

**Taxonomy correctness is inherited from `ancestors/1`.** The walk reads
the `parents` cache (which by the cache invariant may hold composition
*or* taxonomy parents), but for a `class` node that cache only ever
contains superclass (taxonomy, char 25) entries — templates put the
class in the *template's* parents, not vice versa. B1 relies on this
established `graphdb_class` property (exercised by its `multi_inheritance`
tests) rather than re-filtering by arc kind.

### B1-D7. Empty levels skipped

The result lists **only** levels (class or ancestor) that carry at
least one rule. A level with no attached rules is omitted. List
position still encodes nearness; a consumer wanting the full lineage
(including empty levels) calls `graphdb_class:ancestors/1` directly.

### B1-D8. Non-atomic read; no snapshot

The gather is not a single atomic snapshot: `ancestors/1` executes in
`graphdb_class`, the arc reads in `graphdb_rules`, via separate calls,
and (as in the existing `attached_rules/2`) the arc reads are
`mnesia:dirty_*`. This is acceptable for a pure read of a quiescent
ontology. Snapshot/consistency semantics are explicitly **not** a B1
concern — that is `graphdb_query`'s domain (`#cont_path{}`,
snapshot-expiry) if a future consumer ever needs it. Recorded here as a
known, accepted limitation rather than engineered around.

---

## 3. Public API

```erlang
%%-----------------------------------------------------------------------------
%% effective_rules_for_class(Scope, ClassNref) ->
%%     {ok, [{AncestorNref :: integer(), [{RuleNode :: #node{},
%%                                         Deployment :: map()}]}]}
%%
%% Every rule attached to ClassNref and to each of its taxonomy ancestors,
%% grouped by the class it is attached to, nearest-first (ClassNref itself
%% first), each paired with that attachment's deployment map
%% (#{mode, multiplicity, template}).  Both rule kinds are returned;
%% callers filter inline.  Levels with no rules are omitted.
%% {project, _} -> {ok, []}.
%%
%% DOES NOT resolve override/shadow/conflict -- every level's rules are
%% present.  Resolution is the firing engine's job (B2/B5).
%%-----------------------------------------------------------------------------
effective_rules_for_class(Scope, ClassNref) ->
    gen_server:call(?MODULE, {effective_rules_for_class, Scope, ClassNref}).
```

Export added to the existing `rules_for_class` export group.

---

## 4. Implementation

### 4.1 Handler

```erlang
handle_call({effective_rules_for_class, environment, ClassNref}, _From, State) ->
    {reply, {ok, effective_rules(ClassNref, State)}, State};
handle_call({effective_rules_for_class, {project, _}, _}, _From, State) ->
    {reply, {ok, []}, State};
```

### 4.2 Gather

```
effective_rules(ClassNref, State):
    Chain = [ClassNref | ancestor_nrefs(ClassNref)]   %% self-first, nearest-first
    [ {Level, Pairs}
      || Level <- Chain,
         Pairs <- [attached_rules_with_deployment(Level, State)],
         Pairs =/= [] ]                                %% B1-D7: skip empty levels
```

- `ancestor_nrefs/1` calls `graphdb_class:ancestors(ClassNref)` and
  extracts the nrefs from an `{ok, [#node{}]}` reply; an `{error,
  not_found | not_a_class}` reply maps to `[]` (B1-D6). The class head
  is still attempted directly — a bad nref simply yields no direct
  attachments either, so the overall result is `{ok, []}`.
- `attached_rules_with_deployment/2` is a deployment-preserving sibling
  of the existing `attached_rules/2`. To avoid duplicating the
  arc-read, refactor the shared read into a helper that returns the
  `applies_to` arcs for a class; `attached_rules/2` keeps mapping to
  bare nodes, the new helper maps to `{RuleNode, Deployment}`.

### 4.3 Deployment decode

For each `applies_to` arc, decode its `avps` list into the symbolic
`Deployment` map using the cached attribute nrefs already in `#state{}`:

| Deployment key | Source AVP attribute nref           |
| -------------- | ----------------------------------- |
| `mode`         | `State#state.mode_attr`             |
| `multiplicity` | `State#state.multiplicity_attr`     |
| `template`     | `?ARC_TEMPLATE` (Template, attr 31) |

A key whose AVP is absent is omitted from the map (B1-D2).

Note: the `template` deployment key reads the arc's **Template scope
marker** (`?ARC_TEMPLATE`, attr 31, AVP index 0 per F4 D5) — *not* the
`template_nref` content literal (`State#state.template_nref_attr`), which
is a CompositionRule's optional content AVP on the rule node. The two are
distinct; B1 reads the former from the `applies_to` arc.

### 4.4 No new state, no new seeds

B1 adds no seeded nrefs, no records, no supervisor change, no
`seeded_nrefs/0` change. It is purely a new read over existing data.

---

## 5. Testing

New CT group `effective` in `apps/graphdb/test/graphdb_rules_SUITE.erl`:

| Case                                | Asserts                                                                                                                                                                |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `self_only_no_ancestors`            | Rules attached directly to a root class surface under that class's own group; head group is the class                                                                  |
| `linear_chain_nearest_first`        | `Vehicle ◀ Car ◀ SportsCar`, one rule per level; group order is `[SportsCar, Car, Vehicle]` membership                                                                 |
| `diamond_dag_dedup`                 | A multi-parent shared ancestor appears exactly once                                                                                                                    |
| `shared_rule_node_across_ancestors` | One rule node attached to two ancestors appears once per ancestor, each with that ancestor's deployment                                                                |
| `deployment_avps_surfaced`          | `mode` / `multiplicity` / `template` decoded correctly onto each pair                                                                                                  |
| `additive_parent_and_child`         | Parent `mandatory` rule + subclass rule for the same relationship attribute at higher `multiplicity`: **both** present, each with its own deployment (nothing dropped) |
| `empty_levels_skipped`              | An ancestor with no attached rules is omitted from the result                                                                                                          |
| `mixed_kinds_returned`              | Composition + connection rules both present; inline comprehension filters recover each kind                                                                            |
| `project_scope_empty`               | `effective_rules_for_class({project, _}, _) -> {ok, []}`                                                                                                               |
| `unknown_class_empty`               | A non-existent nref -> `{ok, []}` (ancestor-walk `{error, not_found}` mapped to empty)                                                                                 |
| `non_class_nref_empty`              | An existing non-class nref (e.g. an instance) -> `{ok, []}` (`{error, not_a_class}` mapped to empty)                                                                   |

`end_per_testcase` asserts `graphdb_mgr:verify_caches/0 = ok` (B1 is a
read; the cache invariant must be untouched).

No EUnit cases — there is no pure-function surface beyond the
gen_server read.

---

## 6. Documentation Updates

Shipped with B1:

- `apps/graphdb/CLAUDE.md` — add `effective_rules_for_class/2` to the
  `graphdb_rules` public API list with a one-line "taxonomy-walking
  read; B2+ engines consume it" note.
- `ARCHITECTURE.md` — update the `graphdb_rules` API contract line and
  the test count.
- `docs/designs/f4-graphdb-rules-design.md` — mark **OI-1 resolved**,
  pointing here. **Edit OI-1's `effective_rules_for_class/2` code block
  in place** so its return shape reads `{ok, [{AncestorNref, [{RuleNode,
  Deployment}]}]}` — do *not* merely append a note. Two design docs
  giving contradictory return shapes for the same function is exactly the
  drift this update must prevent.
- `TASKS.md` — record F4 Phase B / B1 status.

No `docs/diagrams/ontology-tree.md` change — B1 seeds nothing.

---

## 7. Decision Log

| Tag   | Decision                                                                                                                | Date       |
| ----- | ----------------------------------------------------------------------------------------------------------------------- | ---------- |
| B1-D1 | Pure gather; no override/shadow resolution (additive contributions must not be pre-empted)                              | 2026-06-03 |
| B1-D2 | Element shape `{RuleNode, Deployment}`; deployment read from the `applies_to` arc (OI-1's bare `[#node{}]` superseded)  | 2026-06-03 |
| B1-D3 | Ordering reuses `graphdb_class:ancestors/1` (nearest-first BFS, deduped); class itself prepended as head                | 2026-06-03 |
| B1-D4 | Single gather function; kind-filtering is inline consumer enumeration; formal cursor deferred until a consumer needs it | 2026-06-03 |
| B1-D5 | Environment scope only; `{project, _} -> {ok, []}` (L6 later)                                                           | 2026-06-03 |
| B1-D6 | No input validation; unknown/non-class nref -> `{ok, []}`                                                               | 2026-06-03 |
| B1-D7 | Levels contributing no rules are omitted from the result                                                                | 2026-06-03 |
| B1-D8 | Non-atomic, dirty, snapshot-free read; accepted limitation                                                              | 2026-06-03 |

---

## 8. Summary

B1 adds one read-only function, `effective_rules_for_class/2`, to
`graphdb_rules`: a nearest-first, deployment-bearing, taxonomy-walking
gather of every rule attached to a class and its ancestors. It resolves
nothing — that is deliberate, so the firing engine can later decide
additive-vs-shadowing with full context. It adds no seeds, records,
state, or supervisor changes, and preserves every existing API
contract. It is the foundation the rest of Phase B (B2–B5) consumes.
