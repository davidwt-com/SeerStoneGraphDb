<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# F4 — `graphdb_rules` Rule Engine — Design

**Status:** Phase A specified in detail. Phases B–F outlined. No
implementation has begun.

**Spec citations:** `the-knowledge-network.md` §8 (Rules as Stored
Data), §9 (Instantiation Engine), §10 (Composition Rules), §11
(Reactive Learning).

---

## 1. Scope and Phasing

F4 is large enough that single-PR execution is impractical. This
design splits it into six phases. Phase A is the data-model
foundation that every later phase depends on. Phases B–F are
outlined here but each will have its own dedicated brainstorm + design
+ plan cycle when its turn comes.

| Phase | Subject                                              | Depends on   |
|-------|------------------------------------------------------|--------------|
| A     | Rule data model + meta-ontology + Phase-A rule kinds | —            |
| B     | Composition engine (fires at `create_instance`)      | A            |
| C     | Reactive learning — naming pattern                   | A            |
| D     | Reactive learning — connection pattern               | A            |
| E     | Instantiation engine — guided + automatic modes      | A, B; needs interaction layer (no UI yet) |
| F     | Connection constraints + enforcement                 | A            |

This design document specifies **Phase A** end-to-end. Subsequent
phases are sketched in §11.

### Phase A scope (Scope α)

Phase A delivers:

- Meta-ontology: `Rule` class root + two leaf meta-classes
  (`CompositionRule`, `ConnectionRule`) seeded at runtime.
- AVP schemas locked for both Phase A rule kinds.
- Attachment mechanism: `applies_to` / `applied_by` arc pair from
  owning class to rule instance.
- Public API: scope-aware create + retrieve.
- Validation catalog with 11 named error atoms.
- CT coverage for creation, retrieval, validation, idempotent seeding.
- Supervisor reorder: `graphdb_rules` becomes the last child of
  `graphdb_sup` so it can seed via `graphdb_attr` and `graphdb_class`
  APIs at init.

Phase A does **not** deliver: any engine that fires rules; any
instance-creation integration; reactive learning; rule deletion; rule
inheritance through class taxonomy; project-scoped rule writes.

### Prerequisite: L7 — Literals Subtree Restructuring

**Phase A depends on L7 having landed first.** L7 partitions the
Literals subtree (nref 7) by owning subsystem so that newly-seeded
literal attributes go into the sub-group their owning worker maintains.

```
2 Attributes (category)
└── 7 Literals (attribute)
    ├── Attribute Literals      [seeded by graphdb_attr:init/1]
    ├── Language Literals       [seeded by graphdb_language:init/1]
    └── Rule Literals           [seeded by graphdb_rules:init/1; added by Phase A]
```

L7 bundles all dependent changes into a single PR: introduces
`Attribute Literals` and `Language Literals` sub-groups, updates
`graphdb_attr:init/1` to seed `target_kind`, `relationship_avp`,
`attribute_type`, `literal_type` under `Attribute Literals`, and
updates `graphdb_language:init/1` to seed `base_language` and
`project_language` under `Language Literals`. **No runtime migration
code** — the environment is treated as a clean slate; all seeding is
written as if for a fresh deployment.

Phase A then adds `Rule Literals` as the third sub-group, seeded by
`graphdb_rules:init/1`, following the same pattern L7 establishes.

---

## 2. Architectural Commitments

The eight commitments below come out of the brainstorming session and
are load-bearing for the design.

### D1. Rule meta-ontology placement (P2)

The rule meta-classes are seeded as children of nref 3 (Classes) under
a single `Rule` class root, at runtime via `graphdb_rules:init/1`
using the ensure-seed-by-name pattern. No `bootstrap.terms` change.

```
nref 3 (Classes, category)
  ├── Rule                                    (class, seeded by graphdb_rules)
  │    ├── CompositionRule                    (subclass of Rule)
  │    └── ConnectionRule                     (subclass of Rule)
  └── ... user-authored domain classes
```

**Why:** keeps the class taxonomy clean (no rule meta-classes mixed
with user classes), parses naturally ("a CompositionRule is a Rule"),
gives the engine a single ancestor to pattern-match on, and adds zero
bootstrap scaffold. Mirrors the L7 precedent where `graphdb_attr` and
`graphdb_language` seed sub-groups and literal attributes at runtime
via `init/1` rather than expanding `bootstrap.terms` (English itself
is bootstrap-seeded in `bootstrap.terms:203`; the runtime
ensure-seed-by-name pattern is the L7 contribution).

### D2. Rule representation (A2 + B3)

A rule is an **instance** (`kind = instance`) whose **class
membership** is one of the rule meta-classes. The rule's parameters
live in its AVP list.

**Why:** rules are "typed data" per §8; typed by class membership is
the most literal reading. Reuses the fully implemented
`graphdb_instance` machinery. No new node `kind` to add. Reactive
learning (§11) maps perfectly: a learned rule is just a new instance
of an existing meta-class — same code path as any authored instance.

### D3. Rule instance storage (Y1)

General rules live in the **environment** `nodes` table (alongside
the seeded English instance at nref 10000). Project-specific rules
are a future capability that depends on L6 (multi-project sessions).

**Why:** simplest possible storage. The English instance precedent
shows the environment table already holds instances. No new database
to manage. Path to project-scoped rules is open via the
scope-discriminator API (D7).

### D4. Unified ConnectionRule with 3-state mode

Both rule kinds carry `mode :: mandatory | auto | propose` as a
required AVP. There is **no** separate `MandatoryConnectionRule`
meta-class — mandatory is an enforcement level, not a rule kind.

| Mode        | Engine behaviour at `create_instance` (Phase B+)                                                                                 |
|-------------|----------------------------------------------------------------------------------------------------------------------------------|
| `mandatory` | Component/connection must exist for the parent to be complete. Engine fails or rolls back creation if it cannot satisfy.         |
| `auto`      | Engine creates the component/connection by default. May be later deleted or changed without invalidating the parent.            |
| `propose`   | Engine surfaces it through the API as a pending proposal. Interactive sessions present for confirmation; non-interactive sessions skip (engine-phase decision how). |

The interactive vs non-interactive distinction is a **session
parameter** the engine (Phase B+) consumes. Phase A only locks the
data shape needed to drive it.

**Why:** mandatory/auto/propose are orthogonal to the rule's kind. A
single class can declare multiple rules across all three enforcement
levels (e.g., Car requires Engine [mandatory], creates Sunroof [auto],
proposes SoundSystem [propose]). Learned rules from §11 land
naturally as `propose`-mode entries — the engine learns by suggesting,
not enforcing.

### D5. Attachment mechanism (Attachment B + arc-AVP enforcement)

A rule attaches to its **owning class** by a `kind = connection`
relationship arc pair with characterization `applies_to` (reciprocal
`applied_by`). Secondary class references (`child_class` for
CompositionRule, `target_class` for ConnectionRule) live as AVPs on
the rule instance.

The connection arc carries three AVPs:

| Index | AVP                  | Source                                                                              |
|-------|----------------------|-------------------------------------------------------------------------------------|
| 0     | `Template` (attr 31) | Owning class's default template (preserves the connection-arc convention)           |
| 1     | `mode`               | `mandatory \| auto \| propose` — enforcement level of *this attachment*             |
| 2     | `multiplicity`       | `pos_integer() \| unbounded` — number of children/connections the engine creates    |

`mode` and `multiplicity` live on the arc, not on the rule node,
because they describe the *deployment* of a rule (how strictly the
owning class enforces it) — not the rule's *content* (what the rule
references). The same rule node can attach to two classes with
different enforcement levels by varying only the arc AVPs.

```
                    [Template, mode, multiplicity AVPs on arc]
                              │
ClassNode  ──applies_to──▶  RuleInstance
ClassNode  ◀──applied_by──  RuleInstance
```

Lookup "rules attached to class C" reads the `relationships` table
filtered by `source_nref = C, characterization = applies_to` — O(1)
via the existing secondary index on `source_nref`. Reading the
attachment's AVPs gives the engine its enforcement contract for that
class.

**Why kind=connection:** lateral, metadata-carrying arc; matches the
existing graph-kind set without introducing a fifth kind. The
Template AVP convention is preserved (owning class's default template
scopes the attachment). `verify_caches/0` already ignores
`kind=connection`, so no cache-audit changes are required.

**Why mode and multiplicity on the arc:** enforcement is a property
of the binding, not the rule. Reactive learning (§11) maps cleanly:
a learned rule node can attach to multiple classes with different
modes (e.g., `propose` on the originating class, `auto` once
promoted) without duplicating the rule data.

**Phase B+ semantics (informative):** even when the attachment mode
is `auto` or `propose`, it does not restrict the rules attached to
the target/child class's template — each class resolves its own rules
based on its own attachment modes. A `propose`-mode attachment that
the user executes promotes downstream resolution at the child/target
class without retroactively gating the parent.

### D6. AVP schemas

Per D5, rule-content AVPs live on the rule instance node; deployment
AVPs (`mode`, `multiplicity`) live on the `applies_to` connection
arc.

**CompositionRule instance** (content) — owning class = parent_class,
via `applies_to` arc:

```
AVP child_class_nref :: integer()  [required]
AVP template_nref    :: integer()  [optional]
```

**ConnectionRule instance** (content) — owning class = source_class,
via `applies_to` arc:

```
AVP characterization_nref :: integer()  [required]
AVP target_class_nref     :: integer()  [required]
AVP template_nref         :: integer()  [optional]
```

Both rule instances additionally carry the standard instance-name AVP
(nref 20 = `?NAME_ATTR_INSTANCE`) required of every `kind = instance`
node.

**`applies_to` connection arc** (deployment, per D5):

```
AVP Template     :: integer()                  [required, attr 31, index 0]
AVP mode         :: mandatory | auto | propose [required]
AVP multiplicity :: pos_integer() | unbounded  [required, default 1]
```

The Template AVP is the owning class's default template (mirroring
the standard connection-arc convention). `mode` and `multiplicity`
follow.

### D7. Scope-aware API (env-only in Phase A)

Every public API takes `Scope :: environment | {project, AnchorNref}`
following the M6 R1 precedent. Phase A accepts `environment` only;
project scope returns `{error, project_rules_not_yet_supported}` as
the L6 placeholder.

**Why:** locks the forward-compatible shape before L6 lands. No API
break when project-scoped rule storage becomes possible. Same
discipline as M6's `resolve_label/4`.

### D8. Direct entry point (not via `graphdb_mgr`)

`graphdb_rules` is called directly by external code, not routed
through `graphdb_mgr`. Same precedent as `graphdb_language` and
`graphdb_query`.

**Why:** `graphdb_rules` is a self-contained domain; mgr routing is
a uniformity-of-API concern that does not gate Phase A. Can be added
later as a thin delegation layer if a unified
`graphdb_mgr:create_node`-style API is wanted.

### D9. Multiplicity attribute_type — `term` for now

The unioned multiplicity type (`pos_integer() | unbounded`) has no
precedent in M8's attribute_type set. The literal attribute carries
`attribute_type => term` in Phase A.

**Why:** introducing a union/constraint mechanism is M8 evolution
work that does not gate F4. Validation at create time (D11) catches
out-of-range values regardless.

---

## 3. Seeded Scaffold

`graphdb_rules:init/1` runs the ensure-seed-by-name sequence below.
All seeds are idempotent — re-running them after restart is a no-op.
All nrefs are cached in gen_server state and exposed via
`seeded_nrefs/0`.

**Side-effect of `graphdb_class:create_class/2`:** the existing API
atomically writes the class node *and* a default Template node
(`kind = template`) plus the class→template composition arc pair.
Seeding `Rule`, `CompositionRule`, and `ConnectionRule` therefore
creates three meta-class nodes **plus three default Template nodes**.
The default-template nrefs are not exposed via `seeded_nrefs/0` in
Phase A — Phase B+ engines dispatch on `classes` cache on rule
instances, never on meta-class default templates. The owning class's
default template (e.g., Car's default template) is what scopes the
`applies_to` arc per D5, not the meta-class's default template.

### 3.1 Seed list

`Rule Literals` is seeded first as the sub-group parent for the six
literal attributes. The relationship-attribute pair and the
meta-class chain follow. `graphdb_attr:create_literal_attribute/3` is
the /3 variant that takes an explicit parent nref (introduced by L7);
in L7 `graphdb_attr` and `graphdb_language` already use the /3 form
to seed under their own sub-groups.

| #  | Seeded entity                          | API call                                                                                            | Stored under                |
|----|----------------------------------------|-----------------------------------------------------------------------------------------------------|-----------------------------|
| 1  | `Rule Literals` sub-group attribute    | seeded directly by `graphdb_rules:init/1` as a child attribute of nref 7                            | nref 7 (Literals)           |
| 2  | `child_class_nref` literal attr        | `graphdb_attr:create_literal_attribute("child_class_nref", integer, RuleLiteralsNref)`              | Rule Literals               |
| 3  | `target_class_nref` literal attr       | `graphdb_attr:create_literal_attribute("target_class_nref", integer, RuleLiteralsNref)`             | Rule Literals               |
| 4  | `template_nref` literal attr           | `graphdb_attr:create_literal_attribute("template_nref", integer, RuleLiteralsNref)`                 | Rule Literals               |
| 5  | `characterization_nref` literal attr   | `graphdb_attr:create_literal_attribute("characterization_nref", integer, RuleLiteralsNref)`         | Rule Literals               |
| 6  | `mode` literal attr                    | `graphdb_attr:create_literal_attribute("mode", atom, RuleLiteralsNref)`                             | Rule Literals               |
| 7  | `multiplicity` literal attr            | `graphdb_attr:create_literal_attribute("multiplicity", term, RuleLiteralsNref)`                     | Rule Literals               |
| 8  | `applies_to` / `applied_by` rel attrs  | `graphdb_attr:create_relationship_attribute("applies_to", "applied_by", instance)`                  | **PINNED — see §10.1 P1** (current API parks under nref 8; nref 16 placement requires API extension) |
| 9  | `Rule` class                           | `graphdb_class:create_class("Rule", ?NREF_CLASSES)`                                                 | nref 3 (Classes)            |
| 10 | `CompositionRule` class                | `graphdb_class:create_class("CompositionRule", RuleNref)` (taxonomy arc)                            | subclass of Rule            |
| 11 | `ConnectionRule` class                 | `graphdb_class:create_class("ConnectionRule", RuleNref)` (taxonomy arc)                             | subclass of Rule            |

Order matters: the `Rule Literals` sub-group (step 1) before its
children (2–7); the relationship-attribute pair (8) before the class
meta-ontology (9–11), so AVPs referencing the seeded literal attrs
are resolvable in any later rule-instance writes.

### 3.2 `seeded_nrefs/0` shape

```erlang
seeded_nrefs() ->
    #{rule                       => RuleNref,
      composition_rule           => CompositionRuleNref,
      connection_rule            => ConnectionRuleNref,
      applies_to                 => AppliesToArcNref,
      applied_by                 => AppliedByArcNref,
      rule_literals_group        => RuleLiteralsNref,
      child_class_nref_attr      => ChildClassAttrNref,
      target_class_nref_attr     => TargetClassAttrNref,
      template_nref_attr         => TemplateAttrNref,
      characterization_nref_attr => CharacterizationAttrNref,
      mode_attr                  => ModeAttrNref,
      multiplicity_attr          => MultiplicityAttrNref}.
```

### 3.3 Supervisor reorder

Current child order in `graphdb_sup` (verified in
`graphdb_sup.erl:226-234`):

```
rel_id_server → graphdb_mgr → graphdb_rules → graphdb_attr
→ graphdb_class → graphdb_instance → graphdb_language → graphdb_query
```

New child order (Phase A) — `rel_id_server` and `graphdb_mgr` keep
their positions; `graphdb_rules` moves to the end:

```
rel_id_server → graphdb_mgr → graphdb_attr → graphdb_class
→ graphdb_instance → graphdb_language → graphdb_query → graphdb_rules
```

`graphdb_rules` becomes the last child so that
`graphdb_attr:create_*` and `graphdb_class:create_class` are available
when `graphdb_rules:init/1` runs. No other worker depends on
`graphdb_rules` in Phase A.

---

## 4. Public API

All exports are in `apps/graphdb/src/graphdb_rules.erl`.

### 4.1 Lifecycle

```erlang
start_link() -> {ok, pid()} | ignore | {error, term()}.

seeded_nrefs() -> map().     %% as described in §3.2
```

### 4.2 Creation

```erlang
-type scope() :: environment | {project, AnchorNref :: integer()}.
-type rule_mode() :: mandatory | auto | propose.
-type multiplicity() :: pos_integer() | unbounded.

create_composition_rule(
    Scope        :: scope(),
    Name         :: string(),
    ParentClass  :: integer(),
    ChildClass   :: integer(),
    Mode         :: rule_mode(),
    Multiplicity :: multiplicity()
) -> {ok, RuleNref :: integer()} | {error, term()}.

create_composition_rule(
    Scope        :: scope(),
    Name         :: string(),
    ParentClass  :: integer(),
    ChildClass   :: integer(),
    Mode         :: rule_mode(),
    Multiplicity :: multiplicity(),
    TemplateNref :: integer()
) -> {ok, RuleNref :: integer()} | {error, term()}.

create_connection_rule(
    Scope                :: scope(),
    Name                 :: string(),
    SourceClass          :: integer(),
    CharacterizationNref :: integer(),
    TargetClass          :: integer(),
    Mode                 :: rule_mode(),
    Multiplicity         :: multiplicity()
) -> {ok, RuleNref :: integer()} | {error, term()}.

create_connection_rule(
    Scope                :: scope(),
    Name                 :: string(),
    SourceClass          :: integer(),
    CharacterizationNref :: integer(),
    TargetClass          :: integer(),
    Mode                 :: rule_mode(),
    Multiplicity         :: multiplicity(),
    TemplateNref         :: integer()
) -> {ok, RuleNref :: integer()} | {error, term()}.
```

Each create call performs the validation set (§5) in a single Mnesia
transaction managed directly by `graphdb_rules`. The existing
`graphdb_instance:create_instance/3` API is **not** used: it requires
a compositional parent and writes a composition arc, which is wrong
for rule instances. D2 reuses the *data model*
(`kind=instance`, `classes` cache, AVP storage) — not the worker API.

On success:

1. The rule's nref is allocated via `nref_server:get_nref/0`.
2. The instance node is written with `kind = instance`,
   `classes = [RuleMetaClassNref]`, `parents = []`, and the
   content-only AVP list (per D6).
3. The instance↔class membership arc pair (chars 29/30,
   `kind = instantiation`) is written.
4. The `applies_to` / `applied_by` arc pair is written as
   `kind = connection` rows between the owning class and the new
   rule instance, stamped with the Template + mode + multiplicity
   AVPs (per D5).

All four writes happen in the same Mnesia transaction. If any
validation check or write fails, no nref is consumed and no records
are written.

### 4.3 Retrieval

```erlang
get_rule(Scope :: scope(), RuleNref :: integer()) ->
    {ok, #node{}} | not_found.

%% All rules attached to ClassNref, regardless of rule kind
rules_for_class(Scope :: scope(), ClassNref :: integer()) ->
    {ok, [#node{}]}.

composition_rules_for_class(Scope :: scope(), ClassNref :: integer()) ->
    {ok, [#node{}]}.

connection_rules_for_class(Scope :: scope(), ClassNref :: integer()) ->
    {ok, [#node{}]}.

%% Every rule instance in the given scope (admin/inspection)
list_rules(Scope :: scope()) ->
    {ok, [#node{}]}.
```

Retrieval reads only direct attachments — rules attached to the
class's ancestors are **not** included. An `effective_rules_for_class/2`
that walks the class taxonomy is a Phase B addition when the engine
needs it.

### 4.4 Scope acceptance

In Phase A:

| Scope                     | Behaviour                                                                  |
|---------------------------|----------------------------------------------------------------------------|
| `environment`             | Reads and writes the environment `nodes` and `relationships` tables.       |
| `{project, AnchorNref}`   | Returns `{error, project_rules_not_yet_supported}` from every API.         |

---

## 5. Validation

All checks run inside the create transaction before any write.

| Error atom                          | Trigger                                                                 |
|-------------------------------------|-------------------------------------------------------------------------|
| `class_not_found`                   | Owning class (ParentClass / SourceClass) does not exist                 |
| `not_a_class`                       | Owning class exists but `kind ≠ class`                                  |
| `referenced_class_not_found`        | ChildClass / TargetClass does not exist                                 |
| `referenced_not_a_class`            | Referenced node exists but `kind ≠ class`                               |
| `characterization_not_found`        | Characterization nref does not exist (ConnectionRule)                   |
| `not_a_relationship_attribute`      | Characterization exists but is not a relationship attribute              |
| `template_not_found`                | Optional `TemplateNref` does not exist                                  |
| `not_a_template`                    | Template nref exists but `kind ≠ template`                              |
| `invalid_mode`                      | Mode ∉ `{mandatory, auto, propose}`                                     |
| `invalid_multiplicity`              | Multiplicity ∉ `pos_integer() ∪ {unbounded}`                            |
| `project_rules_not_yet_supported`   | Scope = `{project, _}` (L6 placeholder; Phase A only)                   |

Errors are returned as `{error, AtomReason}` (or, where useful for
diagnostics, `{error, {AtomReason, OffendingValue}}`).

---

## 6. Module Header & Conventions

`graphdb_rules.erl` follows the project conventions:

- Copyright block: 2008 SeerStone (Dallas Noyes) + 2026 David W. Thomas
  + SPDX `GPL-2.0-or-later`.
- Revision history block updated through Rev A (this design); PA1 is
  Dallas's original stub.
- NYI / UEM macros copy-pasted as in every other gen_server.
- Explicit `-export([...])` list — no `-compile(export_all)`.
- `-include("graphdb_nrefs.hrl")` for `?NREF_CLASSES`,
  `?NREF_LITERALS`, `?NREF_INST_REL_ATTRS`,
  `?NAME_ATTR_INSTANCE`, `?ARC_CLS_PARENT`,
  `?ARC_CLS_CHILD`, etc.

---

## 7. Testing

### 7.1 CT — `graphdb_rules_SUITE.erl`

| Group              | Test case                                              | What it verifies                                         |
|--------------------|--------------------------------------------------------|----------------------------------------------------------|
| `seeding`          | `seeds_rule_meta_ontology_idempotent`                  | Rule + CompositionRule + ConnectionRule seeded; second start no-op |
| `seeding`          | `seeds_rule_literals_subgroup`                         | `Rule Literals` attribute node exists; its `parents` cache contains nref 7 (Literals) |
| `seeding`          | `seeds_literal_attributes_under_rule_literals`         | All 6 literal attrs present; each is a direct child of `Rule Literals` (i.e. `RuleLiteralsNref ∈ AttrNode#node.parents`). Looser equivalent: each literal attr is a descendant of nref 7 reachable by walking `parents`. |
| `seeding`          | `seeds_applies_to_pair`                                | `applies_to` / `applied_by` rel attr pair under nref 16 (Instance Relationships) |
| `seeding`          | `seeded_nrefs_returns_all_twelve`                      | `seeded_nrefs/0` map has all 12 expected keys (including `rule_literals_group`) |
| `composition`      | `creates_composition_rule_minimal`                     | Required args only; multiplicity defaults to 1; no template |
| `composition`      | `creates_composition_rule_with_template`               | /7 arity stamps template_nref AVP                        |
| `composition`      | `applies_to_arc_pair_written`                          | `kind=connection` arc pair from parent class to rule + reciprocal; Template + `mode` + `multiplicity` AVPs stamped on the forward arc |
| `composition`      | `instance_to_class_membership_written`                 | 29/30 arc pair to CompositionRule meta-class present     |
| `composition`      | `avps_present_and_correct`                             | Content AVPs (`child_class_nref`, optional `template_nref`) on the rule node; deployment AVPs (Template, `mode`, `multiplicity`) on the `applies_to` arc; all equal to the args |
| `connection`       | `creates_connection_rule_minimal`                      | Required args only                                       |
| `connection`       | `creates_connection_rule_with_template`                | /8 arity stamps template_nref AVP                        |
| `connection`       | `instance_to_class_membership_to_connection_rule`      | 29/30 arc pair to ConnectionRule meta-class present      |
| `validation`       | `class_not_found_rejected`                             | Owning class missing → error, nothing written            |
| `validation`       | `not_a_class_rejected`                                 | Owning nref present but kind=attribute → error           |
| `validation`       | `referenced_class_not_found_rejected`                  | Child/target class missing → error                       |
| `validation`       | `referenced_not_a_class_rejected`                      | Child/target present but kind=instance → error           |
| `validation`       | `characterization_not_found_rejected`                  | ConnectionRule with missing char nref                    |
| `validation`       | `not_a_relationship_attribute_rejected`                | Char is a literal attribute, not relationship            |
| `validation`       | `template_not_found_rejected`                          | Optional template doesn't exist                          |
| `validation`       | `not_a_template_rejected`                              | Template present but kind=class                          |
| `validation`       | `invalid_mode_rejected`                                | Mode atom not in the enum                                |
| `validation`       | `invalid_multiplicity_rejected`                        | Multiplicity is a string or zero or negative             |
| `validation`       | `failed_validation_consumes_no_nref`                   | Floor of nref_server unchanged after a rejected create   |
| `retrieval`        | `rules_for_class_returns_all_kinds`                    | Both composition + connection rules attached to one class |
| `retrieval`        | `composition_rules_for_class_filters_by_kind`          | Only CompositionRule instances returned                  |
| `retrieval`        | `connection_rules_for_class_filters_by_kind`          | Only ConnectionRule instances returned                   |
| `retrieval`        | `get_rule_returns_full_record`                         | Node record with all AVPs as written                     |
| `retrieval`        | `get_rule_not_found`                                   | Nonexistent nref → `not_found`                           |
| `retrieval`        | `list_rules_returns_all`                               | Multiple rules across multiple classes                   |
| `scope`            | `project_scope_rejected_on_create`                     | `{project, _}` → `{error, project_rules_not_yet_supported}` |
| `scope`            | `project_scope_returns_empty_on_retrieve`              | `rules_for_class({project, _}, _)` → `{ok, []}` (Phase A; future L6 changes this) |
| `cache_audit`      | `verify_caches_passes_after_rule_creation`             | `graphdb_mgr:verify_caches/0 = ok` after the suite runs (per project convention) |
| `complex_scenarios` | `mixed_rules_on_one_class`                            | A `Car` class with five rules in one suite: CompositionRule(mandatory, 1)→Engine, CompositionRule(auto, 4, with template)→Wheel, CompositionRule(propose, 1)→Sunroof, ConnectionRule(mandatory, 1, with template) via `made_by`→Manufacturer, ConnectionRule(propose, unbounded) via `sold_by`→Dealer. Asserts: (a) `rules_for_class(env, Car)` returns all 5; (b) `composition_rules_for_class` returns 3 with correct mode/multiplicity AVPs; (c) `connection_rules_for_class` returns 2 with correct characterization/target AVPs; (d) five distinct `applies_to` arcs and five reciprocal `applied_by` arcs from/to Car; (e) `verify_caches/0 = ok`. Catches: incorrect kind-filtering, AVP cross-talk between rules, arc-pair miscounts, cache invariant breakage at scale. |
| `complex_scenarios` | `rule_isolation_across_class_taxonomy`                | Setup: `Vehicle ◀── Car ◀── SportsCar` taxonomy. Attach one CompositionRule to each: Engine to Vehicle, SteeringWheel to Car, Spoiler to SportsCar. Asserts: `rules_for_class(env, Vehicle)` returns only Engine (1); `rules_for_class(env, Car)` returns only SteeringWheel (1); `rules_for_class(env, SportsCar)` returns only Spoiler (1). Documents the **direct-attachment-only** semantics of Phase A — `rules_for_class` does not walk class taxonomy ancestors. `effective_rules_for_class/2` (Phase B, OI-1) is the future API that will walk. |
| `complex_scenarios` | `duplicate_child_class_with_different_modes`          | Two CompositionRules attached to `Cell`, both with child_class=`Nucleus`: one with mode=`mandatory, multiplicity=1`, the other with mode=`propose, multiplicity=1`. Asserts: both rules created successfully (data model does not dedup by `(owning_class, referenced_class)` tuple); both retrievable; each carries its own mode AVP and its own `applies_to` arc; the two rule nrefs are distinct. Documents that Phase A is silent on conflict resolution — engines (Phase B) decide what to do with semantically overlapping rules. |

Approximately 30 CT cases.

### 7.2 EUnit

No EUnit cases planned for Phase A. The pure-function surface is
minimal (mostly Mnesia I/O wrappers); the integration CT coverage
above is sufficient.

### 7.3 Cache invariant

Every CT suite's `end_per_testcase` already asserts
`graphdb_mgr:verify_caches/0 = ok`. Rule instances carry
`classes = [RuleMetaClassNref]` and `parents = []`. The cache audit
verifies `classes` against the `kind=instantiation, char=29` arc
(present) and `parents` against parent-direction `kind ∈ {taxonomy,
composition}` arcs (none — rules have no compositional or taxonomic
parents). The `applies_to` connection arcs are invisible to the
audit (it ignores `kind=connection`), which is the correct outcome:
rule attachments are deployment metadata, not hierarchy.

---

## 8. Documentation Updates

When Phase A lands the following documentation updates ship with it:

- `apps/graphdb/CLAUDE.md` — `graphdb_rules` row in files table marked
  *(implemented, Phase A)*; new "Rule Meta-Ontology" subsection
  documenting the scaffold; NYI status updated.
- `CLAUDE.md` (root) — supervision tree updated; new
  `graphdb_rules` row in worker responsibilities table; NYI section
  updated.
- `ARCHITECTURE.md` — new §12 "Rules" section covering the
  meta-ontology, attachment mechanism, and Phase A public API; status
  table updated.
- `TASKS.md` — F4 entry restructured into the six-phase outline with
  Phase A marked RESOLVED on land; L6 added to Engineering Hygiene
  (see §11).

---

## 9. Scope Discriminator and L6

The `Scope` argument on every public API is the forward-compatibility
hook for L6 (Multi-Project Sessions). Today every M6, F3, and now F4
API takes Scope explicitly — context is never read from worker state
or implicit session globals. When L6 lands and a session can hold
multiple open projects, the Scope-aware APIs already accept
`{project, _}` and need only their gen_server handlers extended.

L6 (added to Engineering Hygiene by this design) is the home for:

1. Session state carrying `[{ProjectId, AnchorNref}]` (a list, not a
   singleton).
2. Cross-project arc traversal — arcs whose target is a project nref
   currently carry `target_kind` but not *which* project.
3. Session-level priority resolution (env, then project A's rules,
   then project B's rules — or a declared order).
4. Project-scoped overlay tables for rule instances when project
   rules are turned on.

L6 is **not** blocked by Phase A. Phase A is not blocked by L6.

---

## 10. Open Issues

### 10.1 Pinned — Resolve Before Implementation

These questions surfaced during pre-implementation review of the
design. They must be answered before Phase A coding begins. They are
kept prominent so an implementer reading top-down encounters them
before assuming the design is complete.

**P1. Parent placement of `applies_to` / `applied_by` arc-label
nodes.**

The seeded `applies_to` / `applied_by` pair are the
relationship-attribute nodes that name the arc characterization.
Their parent in the Attributes subtree is unresolved.

- The existing `graphdb_attr:create_relationship_attribute/3` API
  parks both arc-label nodes directly under nref 8
  (`?NREF_RELATIONSHIPS`), with the `TargetKind = instance` argument
  stamped only as a routing AVP (`target_kind => instance`). This is
  the L7-shipped behaviour.
- An earlier version of §3.1 row 8 asserted the pair should live
  under nref 16 (`?NREF_INST_REL_ATTRS`) to mirror the Instance
  Relationships subcategory. The current API does not place them
  there.

Three exits:

- **Accept nref 8.** Fix §3.1 row 8 and the CT case
  `seeds_applies_to_pair` to assert parent under nref 8. The
  `target_kind = instance` AVP suffices for query-engine routing.
  Lowest scope.
- **Add a kind-specific-parent variant** of
  `create_relationship_attribute` so arc-label nodes can be parked
  under nref 13/14/15/16. Scope creep into the attribute worker;
  affects L7 conventions.
- **Modify the existing API.** Would touch L7's already-shipped
  behavior and re-open closed tests.

**Status:** pinned pending review of broader seeding questions that
surfaced alongside it (the default-template auto-creation by
`create_class/2` noted in §3, and any related seed-shape questions
the user wishes to explore). Resolution of those questions may
shape or directly answer P1.

### 10.2 Deferred — Later Phases or Follow-up Tasks

Items surfaced during design that Phase A deliberately leaves for
later phases or follow-up tasks.

**OI-1. Effective rules (taxonomy walk).** `rules_for_class/2`
returns directly-attached rules only. Phase B will add an
`effective_rules_for_class/2` that walks class taxonomy ancestors so
subclass instances inherit superclass composition rules. The shape:

```erlang
effective_rules_for_class(Scope, ClassNref) ->
    {ok, [{AncestorNref, [#node{}]}]}.
```

Returns rules grouped by which ancestor they came from, so the engine
can apply override/shadow semantics.

**OI-2. Rule conflicts and precedence.** If two CompositionRules
attached to the same class both create a child of the same class,
what fires? Engine-phase decision (Phase B). Phase A makes no
commitment about firing order or conflict resolution.

**OI-3. Rule deletion.** `graphdb_mgr:delete_node/1` is currently
`{error, not_implemented}` (L4 decision log). Rule deletion follows
the same path — deferred until a worker adds the functionality.

**OI-4. Multiplicity attribute_type tightening.** D9 leaves
`multiplicity` as `attribute_type => term`. A future M8 enhancement
could introduce union or constraint types — track separately, not
blocking F4.

**OI-5. Project-scoped rule writes.** Phase A returns
`project_rules_not_yet_supported` for `{project, _}` writes. When L6
lands the gen_server handlers gain a project-DB write path. The API
shape is already in place.

**OI-6. Auto-naming for learned rules.** Reactive learning phases (C,
D) will need a naming convention for system-generated rules. Phase A
takes the name as an explicit caller argument — the learning engine
will derive a name internally and call the same API.

**OI-7. Rule inheritance through *rule* taxonomy.** A user could
subclass `CompositionRule` to add domain-specific behaviour. The
meta-ontology supports this by construction (P2). Engines that
dispatch on rule meta-class membership must use ancestor membership,
not exact class membership, to pick up subclasses. Phase B+ concern.

**OI-8. Rule update semantics.** Once a rule is created its AVPs
cannot be changed in Phase A. `graphdb_mgr:update_node_avps/2` is
`{error, not_implemented}`. A rule that needs to change is deleted
and recreated. Engine-phase concern.

**OI-9. `create_literal_attribute/3` arity introduced by L7.** L7
adds a /3 variant taking an explicit parent nref so workers can seed
into their own sub-group. The /2 form continues to default to nref 7
for any caller that does not target a sub-group. F4 Phase A relies
on the /3 form being available.

---

## 11. Phases B–F — Outline

This section is intentionally light. Each subsequent phase will have
its own dedicated brainstorm + design + plan cycle.

### Phase B — Composition Engine

Triggered by `graphdb_instance:create_instance/3`. Walks
`effective_rules_for_class/2` on the new instance's class for
CompositionRule instances; per rule, applies mode:

- `mandatory` → create the child(ren) inside the same transaction;
  fail the create if cannot satisfy.
- `auto` → create the child(ren) in a post-commit step; record on the
  instance which auto-applications happened.
- `propose` → return the proposals through the
  `create_instance` reply for the caller to confirm.

Includes the same logic for ConnectionRule (Mandatory Connections per
§10).

Surfaces an interactive-vs-non-interactive session flag — most likely
threaded through `graphdb_query:new_session/0` since sessions are the
existing context-holding mechanism.

### Phase C — Naming Pattern Learning (§11)

A new `NamingPatternRule` meta-class with AVPs encoding the substring
pattern and source attributes. On `update_node_avps/2` (when
implemented) the engine scans the new value for substrings matching
other AVPs on the same instance; if a pattern is detected, a
`NamingPatternRule(mode=propose)` is created attached to the
instance's class.

### Phase D — Connection Pattern Learning (§11)

A new `ConnectionPatternRule` meta-class accumulating `(source_class,
template_nref, target_class, characterization_nref)` tuples on
connection creation. Counts accumulate; rules with sufficient counts
become `ConnectionRule(mode=propose)` candidates.

### Phase E — Instantiation Engine (§9)

A new `InstantiationRule` meta-class encoding how an attribute's
value is derived: from a literal, from a connection, from a
computation. Guided mode presents valid options; automatic mode
fills without interaction. Likely needs an interaction layer (no UI
exists yet) — may motivate an HTTP/JSON-RPC API for external clients
to drive the engine.

### Phase F — Connection Constraints (§8)

A new `ConnectionConstraintRule` meta-class restricting valid
characterization + target_class combinations per template. Engines
that build connections consult these rules to filter user options
(in guided mode) or reject inappropriate connections (in automatic
mode).

---

## 12. Decision Log

Decisions taken during brainstorming. Each maps to one of the
commitments in §2.

| Tag  | Decision                                                             | Date         |
|------|----------------------------------------------------------------------|--------------|
| D1   | P2 placement: Rule class root under nref 3 with leaf meta-classes as subclasses | 2026-05-25 |
| D2   | A2 + B3: rule is `kind=instance` whose class is a rule meta-class    | 2026-05-25   |
| D3   | Y1: general rules live in environment; project rules deferred to L6  | 2026-05-25   |
| D4   | Unified ConnectionRule with 3-state mode (mandatory \| auto \| propose) — mandatory is enforcement, not a rule kind | 2026-05-25 |
| D5   | Attachment B: `applies_to` / `applied_by` arc from owning class      | 2026-05-25   |
| D6   | AVP schemas locked for CompositionRule and ConnectionRule            | 2026-05-25   |
| D7   | Scope-aware API; Phase A env-only; project returns placeholder error | 2026-05-25   |
| D8   | `graphdb_rules` is a direct entry point, not routed through `graphdb_mgr` | 2026-05-25 |
| D9   | Multiplicity literal attr uses `attribute_type => term`; union types are future M8 work | 2026-05-25 |
| D10  | Supervisor reorder: `graphdb_rules` becomes last child of `graphdb_sup` | 2026-05-25 |
| D11  | Literals subtree partitioned by owning subsystem (`Attribute Literals` / `Language Literals` / `Rule Literals`). L7 lands the first two; Phase A adds the third. No runtime migration — clean-slate seeding. | 2026-05-25 |
| D12  | `applies_to` / `applied_by` arc pair is `kind = connection`. The arc carries Template (owning class's default), `mode`, and `multiplicity` as AVPs. `mode` and `multiplicity` move off the rule instance node — they are properties of the binding, not the rule. Same rule node reusable across classes with different enforcement. | 2026-05-26 |

---

## 13. Summary

Phase A delivers the foundation: a self-contained, scope-aware rule
data model with two locked rule kinds, an attachment mechanism that
mirrors the rest of the graph, and a complete validation catalog. No
engine. No firing. No learning. Those are Phases B–F.

The design preserves every existing public API contract. It depends
on L7 (Literals subtree restructuring) having landed first. Phase A
itself adds 12 seeded nrefs to the environment ontology (1 sub-group
parent + 6 literal attrs + 1 relationship-attribute pair + 1 Rule
class + 2 leaf meta-classes), one new worker capability surface, one
supervisor child reorder, and approximately 30 new CT cases. It
unblocks the entire F4 track.
