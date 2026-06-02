<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# L9 — Non-Instantiable (Abstract) Classes — Design

**Status:** Specified, ready for implementation planning. No code
written yet.

**Spec citations:** `the-knowledge-network.md` §7 (Templates) —
this task *extends* §7 with the non-instantiable-class concept, which
the spec does not currently describe.

**Origin:** F4 Phase A pre-implementation review, Decision **D15**
(`docs/designs/f4-graphdb-rules-design.md`). F4 Phase A seeds an
abstract `Rule` meta-class root under nref 3 (Classes); the engine must
not let anyone instantiate it. D15 settled the mechanism; the open
packaging question ("fold into F4 vs a small prerequisite task")
resolved to **a prerequisite task — this one.** L9 delivers the
mechanism only; F4 Phase A later consumes it.

---

## 1. Scope and Motivation

### What L9 delivers

- A seeded `instantiable` boolean marker literal attribute in the
  `Attribute Literals` sub-group (owned by `graphdb_attr`).
- `graphdb_class:create_class/3` — accepts an initial AVP list
  (defaulting to `[]`); `create_class/2` becomes a delegating wrapper.
- A class carrying `instantiable => false` is born **without** a
  default template.
- `graphdb_instance:create_instance/3` **refuses** to instantiate a
  class marked non-instantiable.
- `graphdb_class:is_instantiable/1` read helper.
- A short `the-knowledge-network.md` §7 extension formalizing the
  concept.
- CT/docs follow-through.

### What L9 does **not** deliver

- It does **not** seed any permanently-abstract class. Seeding the
  `Rule` root non-instantiable is F4 Phase A's job, using L9's
  `create_class/3`.
- It does **not** validate arbitrary AVPs passed to `create_class/3`.
  Only the `instantiable` marker carries behavior; all other supplied
  AVPs are written through as-is. General class-AVP validation is a
  separate future concern.
- No `#node` record/schema change. No `bootstrap.terms` change.

### Why it is a prerequisite, not part of F4

L9 touches `graphdb_attr`, `graphdb_class`, and `graphdb_instance` —
the class/instance machinery — and is independent of the rules engine.
Landing it first keeps F4 Phase A focused on `graphdb_rules` and lets
the marker mechanism get its own tests and review.

---

## 2. The Marker — Representation Decision

**Decision: the non-instantiable marker is an AVP on the class node —
`#{attribute => InstantiableNref, value => false}` — where
`InstantiableNref` is a seeded boolean literal attribute.**

Rationale (from the F4 D15 brainstorm):

- AVPs are the model's channel for *non-topological, per-node
  properties*. "Instantiable or not" is exactly that. The `#node`
  record stays minimal (`nref, kind, parents, classes, avps`); no
  schema change.
- A dedicated `#node` field was rejected: overkill for one boolean and
  it bloats every node record.
- A *topological* signal (e.g. "abstract = has no default template")
  was rejected because it **conflates** with the spec's existing
  "forced disambiguation" feature (`the-knowledge-network.md` §7 line
  174), where a class author deletes the default template to force
  explicit-template connections. That class is still instantiable. An
  explicit marker is the only unambiguous encoding.
- It mirrors the existing `relationship_avp` / `attribute_type`
  boolean-marker AVPs `graphdb_attr` already seeds and stamps — same
  machinery, same precedent.

**Default is permissive.** Only abstract classes carry the marker.
Absence of the marker (or `value => true`) means instantiable. This
matches the model's intent: a newly-discovered concept can be
instantiated against a general class before it is fully specialized
(the "Animal could be instantiated for an unclassified discovery"
case).

### Distinguishing the two template-less class shapes

| Class shape                                    | Has default template? | `instantiable` marker | Instantiable? |
| ---------------------------------------------- | --------------------- | --------------------- | ------------- |
| Ordinary class (default)                       | yes                   | absent                | yes           |
| Forced-disambiguation (author deleted default) | no                    | absent                | yes           |
| Non-instantiable (abstract)                    | no (never created)    | `false`               | **no**        |

The marker, not the presence/absence of a template, is authoritative
for instantiability.

---

## 3. API Changes

### 3.1 `graphdb_attr` — seed the marker

In `init/1`, add one `ensure_seed/2` call alongside the existing four,
under the `Attribute Literals` sub-group:

```erlang
State = #state{
    attribute_literals_group_nref = AttrLitNref,
    literal_type_nref     = ensure_seed("literal_type", AttrLitNref),
    target_kind_nref      = ensure_seed("target_kind", AttrLitNref),
    relationship_avp_nref = ensure_seed("relationship_avp", AttrLitNref),
    attribute_type_nref   = ensure_seed("attribute_type", AttrLitNref),
    instantiable_nref     = ensure_seed("instantiable", AttrLitNref)   %% NEW
}.
```

- Add `instantiable_nref` to the `#state{}` record.
- `ensure_seed/2` is idempotent (ensure-by-name); a restart reuses the
  existing nref. The seed is a `kind = attribute` node with the usual
  name AVP + taxonomy arc pair; the `attribute_type` AVP is applied by
  the existing `retro_stamp_bootstrap_attribute_types/1` pass (the seed
  lives in the Attributes subtree), exactly as `relationship_avp`.
- Extend `seeded_nrefs/0` to include `instantiable => InstantiableNref`.

`instantiable` is a marker like `relationship_avp`: its presence on a
target node, with a boolean value, is the whole semantics. No new
stamping helper is needed — abstract classes are *created with* the
marker (see §3.2), not retro-stamped.

### 3.2 `graphdb_class` — `create_class/3` + abstract handling

**New arity.** `create_class/2` becomes a wrapper:

```erlang
create_class(Name, ParentNref) ->
    create_class(Name, ParentNref, []).

create_class(Name, ParentNref, AVPs) when is_list(AVPs) ->
    gen_server:call(?MODULE, {create_class, Name, ParentNref, AVPs}).
```

All 181 existing `create_class/2` call sites are unaffected.

**Cache the marker nref at init.** `graphdb_class:init/1` currently
returns `{ok, #state{}}`. It gains the same cross-worker read
`graphdb_instance` already performs:

```erlang
init([]) ->
    {ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
    {ok, #state{instantiable_nref = InstAttr}}.
```

Supervisor order makes this safe: `graphdb_attr` (5th child) starts
before `graphdb_class` (6th), so `seeded_nrefs/0` is answerable.

**`do_create_class/3` behavior.** The class-name AVP stays first in the
node's `attribute_value_pairs`; the supplied `AVPs` follow it
(`[ClassNameAVP | AVPs]`). The default-template decision becomes
conditional:

- If `AVPs` contains `#{attribute => InstantiableNref, value => false}`
  → write **only** the class node + taxonomy arc pair. No default
  template node, no class→template composition arc pair.
- Otherwise → current behavior unchanged (class node + taxonomy arcs +
  default template node + composition arc pair).

The class node's `attribute_value_pairs` carries the marker so it
persists and is readable by the instantiation guard.

**New read helper.**

```erlang
%% is_instantiable(ClassNref) -> boolean() | {error, term()}
%% true  if the class carries no instantiable=>false marker
%% false if it carries instantiable=>false
%% {error, not_a_class | class_not_found} otherwise
```

### 3.3 `graphdb_instance` — enforce at `create_instance`

`graphdb_instance` already caches a cross-worker nref
(`target_kind_avp_nref`) at init; add `instantiable_nref` the same way
from `graphdb_attr:seeded_nrefs/0`.

The guard lives in `do_validate_class/1` (the existing `kind = class`
gate, which already `dirty_read`s the class node):

```erlang
do_validate_class(ClassNref) ->
    case mnesia:dirty_read(nodes, ClassNref) of
        [#node{kind = class, attribute_value_pairs = AVPs}] ->
            case is_marked_non_instantiable(AVPs, InstAttr) of
                false -> ok;
                true  -> {error, {class_not_instantiable, ClassNref}}
            end;
        [#node{kind = Kind}] -> {error, {not_a_class, Kind}};
        []                   -> {error, class_not_found}
    end.
```

`is_marked_non_instantiable/2` scans the AVP list for
`#{attribute => InstAttr, value => false}`. The check is inline (no
cross-`gen_server` call inside validation); `InstAttr` is the cached
nref. `create_instance/3`'s public contract gains one new error
(`{error, {class_not_instantiable, ClassNref}}`) and is otherwise
unchanged.

---

## 4. Seeding and Cross-Worker Caching

```
graphdb_attr  (init: ensure_seed "instantiable"; seeded_nrefs += instantiable)
   │  seeded_nrefs/0
   ├──────────────► graphdb_class    (init: cache instantiable_nref)
   └──────────────► graphdb_instance (init: cache instantiable_nref)
```

Start order (existing `graphdb_sup`): `graphdb_attr` precedes both
`graphdb_class` and `graphdb_instance`, so both reads resolve. This is
the same pattern M3 introduced for `target_kind`; L9 adds one consumer
(`graphdb_class`) and one cached field per consumer.

The `instantiable` seed lands in the permanent tier
`[?LABEL_START, ?NREF_START)` because all `init/1` seeding runs during
the `graphdb:start/2` permanent phase — consistent with the other
Attribute-Literals seeds.

---

## 5. Spec Extension — `the-knowledge-network.md` §7

`the-knowledge-network.md` is the canonical **conceptual** model — it
describes *what the knowledge model is*, not how the code realizes it
(CLAUDE.md: "it does **not** track the code"). The passage L9 adds must
therefore stay at the conceptual level: it introduces the *idea* of an
abstract class and the permissive-by-default instantiation stance, and
says nothing about marker attributes, seeded nrefs, AVPs,
`create_class/3`, or any engine internals. Those mechanism details live
in this design doc (§2–§4) and in the code — never in the conceptual
spec.

Proposed §7 addition (conceptual only):

> **Abstract classes.** Not every class is meant to have instances.
> Some classes exist purely as organizing abstractions — points in the
> taxonomy that gather and define the more specific classes beneath them
> but are never themselves made concrete. Such a class may be designated
> *non-instantiable*: the model declines to instantiate it and directs
> the modeler to one of its specializations instead. This is permissive
> by default — a class is instantiable unless explicitly designated
> otherwise — so a newly-encountered thing may be placed under a general
> class before it has been fully classified. Having no instances, an
> abstract class engages no connections, and therefore defines no
> template.

---

## 6. Error Catalog

| Error                                 | Raised by                          | When                                                 |
| ------------------------------------- | ---------------------------------- | ---------------------------------------------------- |
| `{class_not_instantiable, ClassNref}` | `graphdb_instance:create_instance` | Target class carries `instantiable => false`         |
| `{not_a_class, Kind}`                 | `graphdb_class:is_instantiable`    | Nref resolves to a non-class node (existing pattern) |
| `class_not_found`                     | `graphdb_class:is_instantiable`    | Nref does not resolve                                |

No new errors in `create_class/3`: arbitrary AVPs are not validated
(§1), so the only failure modes remain the existing parent-validation
ones.

---

## 7. Testing

### 7.1 `graphdb_attr_SUITE`

- `seeds_instantiable_marker` — after init, `seeded_nrefs/0` includes
  `instantiable`; the nref resolves to a `kind = attribute` node named
  `"instantiable"` under the `Attribute Literals` sub-group; it carries
  an `attribute_type` AVP (parity with `relationship_avp`).
- `instantiable_seed_idempotent` — a simulated re-init reuses the same
  nref (no duplicate node under the sub-group).

### 7.2 `graphdb_class_SUITE`

- `create_class_3_default_avps_empty` — `create_class/2` and
  `create_class(Name, Parent, [])` produce identical results (class
  node + taxonomy arcs + default template).
- `create_class_3_writes_avps` — supplied non-marker AVPs land on the
  class node verbatim, alongside the class-name AVP.
- `create_abstract_class_skips_default_template` — creating a class
  with `instantiable => false` produces **no** template-kind
  compositional child; `default_template/1` returns `not_found`;
  `templates_for_class/1` returns `[]`.
- `instantiable_class_keeps_default_template` — a class created without
  the marker still gets its default template (regression guard).
- `is_instantiable_true_false` — returns `true` for an ordinary class
  and a forced-disambiguation class (default deleted, no marker),
  `false` for a marked class.

### 7.3 `graphdb_instance_SUITE`

- `create_instance_refused_for_abstract_class` — instantiating a class
  marked `instantiable => false` returns
  `{error, {class_not_instantiable, ClassNref}}`; no node or arcs are
  written (row-count delta = 0).
- `create_instance_allowed_for_unmarked_class` — ordinary and
  forced-disambiguation classes still instantiate normally (regression
  guard).

### 7.4 Cache invariant

Every CT suite's `end_per_testcase` already asserts
`graphdb_mgr:verify_caches/0 = ok`. L9 writes no new arc kinds; the
abstract class still has its taxonomy parent/child arcs, so the
`parents` cache invariant is unaffected. No new audit logic needed.

---

## 8. Documentation Updates

| File                                      | Update                                                                                                           |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `the-knowledge-network.md` §7             | Add the **conceptual** abstract-class passage (§5) — concept only, no mechanism                                  |
| `ARCHITECTURE.md`                         | `graphdb_class` API: note `create_class/3` + `is_instantiable/1`; `graphdb_instance` `create_instance` new error |
| `apps/graphdb/CLAUDE.md`                  | `graphdb_attr` seed list (+`instantiable`); `graphdb_class` creators; `graphdb_instance` guard                   |
| `docs/diagrams/ontology-tree.md`          | Add `instantiable` under the `Attribute Literals` sub-group                                                      |
| `TASKS.md`                                | Add L9 entry; mark RESOLVED on completion                                                                        |
| `docs/designs/f4-graphdb-rules-design.md` | D15: note the marker mechanism is delivered by L9 (prerequisite landed)                                          |

---

## 9. Decision Log

| Tag  | Decision                                                                                                                                                              | Date       |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| L9-1 | Marker is an AVP (`instantiable => false`) on the class node, backed by a seeded boolean literal attribute. Not a `#node` field, not a topological signal. (= F4 D15) | 2026-06-01 |
| L9-2 | `create_class/2` → `create_class/3` taking an initial AVP list (default `[]`). General over class-creation AVPs, not an `instantiable`-only flag or options map.      | 2026-06-01 |
| L9-3 | `create_class/3` writes supplied AVPs as-is; only the `instantiable` marker carries behavior (skip default template). No arbitrary-AVP validation in L9.              | 2026-06-01 |
| L9-4 | Instantiability is permissive by default; only abstract classes carry the marker; absence = instantiable.                                                             | 2026-06-01 |
| L9-5 | Enforcement is inline in `graphdb_instance:do_validate_class/1` using a cached nref — no cross-`gen_server` call inside validation.                                   | 2026-06-01 |

---

## 10. Out of Scope / Future

- Seeding the `Rule` root non-instantiable — F4 Phase A.
- General validation of class-creation AVPs.
- A runtime "make this existing class abstract / concrete" mutator
  (would interact with already-created instances and the default
  template; not needed by F4).
- Surfacing instantiability through the F3 query language.
