<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Medium-Severity Tasks

Semantic departures from `the-knowledge-network.md` plus the surviving
feature work from the original TASKS.md (query language, rules engine).
The kernel works without these, but each one is a load-bearing piece of
the spec that's currently missing or inconsistent.

Earlier items are smaller, mechanical fixes. Later items are major
additive feature areas that should wait until the kernel is correct
under the existing model.

---

## M4. Reciprocal attribute pair must be created in one transaction — RESOLVED

**Status:** Fixed. `graphdb_attr:create_relationship_attribute/3` now
delegates to a private `do_create_relationship_attribute_pair/3` helper
that allocates the 2 node nrefs and 4 compositional arc-id nrefs
outside the transaction (avoiding side-effects on retry) and writes
all 6 rows in a single `mnesia:transaction/1`.  Mid-pair aborts can no
longer leave the database with an orphan half-pair.  CT case
`create_relationship_attribute_pair_atomic` asserts the row deltas
are exactly +2 nodes and +4 relationships after a successful call,
and that both new nodes have exactly one parent->child arc into them
under the Relationships subtree (nref 8).

---

## M3. `add_relationship/4` validates nothing — RESOLVED

**Status:** Fixed. `graphdb_instance:add_relationship` now runs an
explicit `validate_arc_endpoints/5` pass before resolving classes,
templates, and writing arcs.  All four endpoint reads happen in one
`mnesia:transaction/1`.  Failure modes are returned as structured
errors:

  - `{error, {source_not_found, Nref}}`
  - `{error, {target_not_found, Nref}}`
  - `{error, {characterization_not_found, Nref}}`
  - `{error, {reciprocal_not_found, Nref}}`
  - `{error, {characterization_not_an_attribute, Nref, ActualKind}}`
  - `{error, {reciprocal_not_an_attribute, Nref, ActualKind}}`
  - `{error, {target_kind_mismatch, ExpectedKind, ActualKind}}`

The seeded `target_kind` literal-attribute nref is fetched from
`graphdb_attr:seeded_nrefs()` once at `graphdb_instance:init/1` and
cached in a new gen_server state record.  Arc-label nodes that don't
carry a `target_kind` AVP (relationship-type bucket nodes, legacy
data) skip the kind check.

Tests: 5 CT cases under the `relationships` group covering the new
reject paths.

---

## M5. `add_relationship` cannot accept per-arc AVPs at creation — RESOLVED

**Status:** Fixed. New API
`graphdb_instance:add_relationship/6 :: (Source, Char, Target, Reciprocal,
TemplateNref, {FwdAVPs, RevAVPs}) -> ok | {error, _}` accepts
per-direction user AVPs and stamps them on the two connection rows
alongside the auto-applied Template AVP.  Per-direction is required
by §5: connection metadata such as provenance, confidence, weights,
and validity windows is direction-specific.

The Template AVP stays at index 0 of each row's `avps` list; user
AVPs follow.  `/4` and `/5` stay non-breaking and pass `{[], []}` to
`/6` internally.  `write_connection_arcs` was updated to thread the
AVP spec through; the gen_server message form gained an `AVPSpec`
element.

Tests: 3 CT cases under the `relationships` group:
- `add_relationship_stamps_user_avps` — user AVP appears alongside
  Template AVP on the forward row
- `add_relationship_avps_are_per_direction` — fwd-only AVP doesn't
  leak into the reverse row, and vice versa
- `add_relationship_default_avps_empty` — `/4` still produces a row
  carrying exactly the Template AVP

---

## M2. `resolve_from_class` should consult `graphdb_class`, not Mnesia directly — RESOLVED

**Status:** Closed by H1. `resolve_from_class` now drives the class
walk through `graphdb_class:get_class/1` and
`graphdb_class:ancestors/1` instead of reading the `nodes` table
directly; the membership arc lookup reuses `do_class_of/1` so
`?CLASS_MEMBERSHIP_ARC` is no longer hard-coded inside the resolver.

---

## M1. PART-OF stored in two places with no consistency invariant — RESOLVED

**Status:** Closed by H0 (PR #10, commit `4e56761`). The decision:
arcs are authoritative, `node.parents`/`node.classes` are caches with
a hard invariant enforced by `graphdb_mgr:verify_caches/0` (run in
every CT `end_per_testcase` and at bootstrap load completion).
Single-writer ownership rule documented in `arcs-authoritative.md`
and `ARCHITECTURE.md` §3.

---

## M8. Attribute "type" (name vs. literal vs. relationship) is implied by parent subtree — RESOLVED

**Status:** Fixed via Option A (AVP-based marker).
`graphdb_attr` now seeds a fourth runtime literal attribute,
`attribute_type`, alongside `literal_type`, `target_kind`, and
`relationship_avp`.  All four `create_*` paths stamp an
`#{attribute => attribute_type_nref, value => name|literal|relationship}`
AVP on the new node:

  - `create_name_attribute/1` → `name`
  - `create_literal_attribute/2` → `literal`
  - `create_relationship_attribute/3` → `relationship` (on both
    forward and reciprocal nodes)
  - `create_relationship_type/1` → `relationship`

Bootstrap attribute nodes (nrefs 6-31) are retro-stamped at
`graphdb_attr:init/1` by walking the `parents` cache up to one of the
three top-level subtrees (Names=6, Literals=7, Relationships=8) — same
pattern as `ensure_template_avp_marker/1`.  The retro-stamp is
idempotent across restarts.

New public API: `graphdb_attr:attribute_type_of/1` returns
`{ok, name | literal | relationship}` directly from the AVP without
walking the parent chain.  `seeded_nrefs/0` now also reports the
`attribute_type` key.

Tests: 10 new CT cases under a new `attribute_type` group cover seed
exposure, AVP stamping on each create path, lookup correctness for
both runtime and bootstrap nodes, error paths, and retro-stamp
idempotence.  Existing strict-equality AVP assertions in the
`creators` group were widened to `lists:member` checks to accommodate
the additional AVP.

---

## M6. Multilingual support — language overlay model

**Spec:** §15 — *"Concepts are stored language-neutrally in the
ontology. Labels, prompts, and vocabulary entries are stored per
language and swapped at rendering time without modifying the
knowledge."*

**Design:** The environment node record (`#node{}`) is unchanged and
the environment database is the English default — the terminal
fallback for every language chain. English is the practical common
language of international communication; it is acknowledged as the
environment's base language without apology. Language-specific labels
are stored in per-language Mnesia tables within the same schema
(overlay model). A language chain is a runtime parameter scoped to the
session, user, or use case; resolution walks the chain left-to-right
and falls through to the environment node on miss. Per-AVP override
semantics: a language overlay record carries only the AVPs it
overrides; all other AVPs resolve from the environment node unchanged.

Dialect distinctions are optionally supported. A dialect code such as
`en_gb` or `pt_br` (atom, underscore convention) identifies a
finer-grained overlay table. Dialect overlays carry only terms that
genuinely differ from the base language; most terms fall through to the
base language or the environment. Dialectal variants are an explicit
authoring decision — the system never infers which dialect a string
belongs to.

Project databases mirror this model. The terminal fallback is the
project node record, authored in an implementer-chosen language. That
language is specified as an AVP on the project root node, referencing a
language concept node in the environment.

**Current state:** `graphdb_language.erl` is a gen_server stub.
`bootstrap.terms` carries English strings as node AVPs — these are the
English default and require no migration.

---

### Sub-tasks

**M6-A: Language overlay record and Mnesia schema**

```erlang
-record(language_node, {
    nref,   %% integer() — same keyspace as environment nodes table
    avps    %% [#{attribute => AttrNref, value => Value}]
             %%   — AVPs that shadow matching AVPs on the environment node
}).
```

One Mnesia `disc_copies` table per language or dialect
(`language_en`, `language_de`, `language_en_gb`, `language_pt_br`, …)
with `{record_name, language_node}`. Tables are created on demand when
a language or dialect is registered. `graphdb_bootstrap` creates
`language_en` at environment init; it will be mostly empty in practice
since the environment node record is itself the English default — the
table exists to make `en` a well-formed chain entry.

**M6-B: Language concept nodes**

`graphdb_language:init/1` seeds a language concept node for English
under the Languages category (nref 4) using the standard
ensure-seed-by-name pattern. Node kind is determined during
implementation (candidate: `class`, as languages are ontology-level
definitional concepts rather than project instances). The English nref
is cached in gen_server state and exposed via
`graphdb_language:seeded_nrefs/0`.

Base languages and dialects are both language concept nodes, but
dialect nodes carry an AVP that references their base language concept
node:

```erlang
#{attribute => base_language_nref, value => BaseLanguageConceptNref}
```

`base_language` is seeded as a literal attribute in
`graphdb_language:init/1` (same seeding pattern as `target_kind`).
Base language nodes carry no such AVP. This makes the base/dialect
relationship explicit, queryable, and independent of the atom naming
convention.

**M6-C: Label resolver**

```erlang
graphdb_language:resolve_label(Nref, AttrNref, Chain) -> Value | not_found
```

`Chain :: [atom()]` — language code atoms in priority order
(e.g., `[de, en_gb, en, fr]`). Walk: for each code in the chain:

  - If the code equals the environment's declared language (`en` by
    default, readable from `graphdb_language:seeded_nrefs/0`): skip
    the overlay table lookup and fall directly to the terminal node
    read. This makes `en` a zero-cost sentinel — `language_en` is not
    read, and the environment node record is used immediately.
  - Otherwise: read `language_<code>` table for Nref; if a record
    exists and its `avps` contains AttrNref, return that value.

If the chain is exhausted without a match, read from the terminal node
table (environment `nodes`, or project `nodes` for project nrefs). If
still absent, return `not_found`.

For project nref resolution, the caller passes the project `nodes`
table name as an explicit terminal parameter — the resolver has no
global state about which database owns a given nref.

**M6-D: Language registration**

```erlang
%% Base language
graphdb_language:register_language(Code :: atom(), Name :: string())
    -> {ok, Nref} | {error, already_registered} | {error, _}

%% Dialect — must name an already-registered base language
graphdb_language:register_dialect(Code :: atom(), Name :: string(),
                                  BaseCode :: atom())
    -> {ok, Nref} | {error, base_not_found}
                  | {error, already_registered}
                  | {error, _}
```

Both create the concept node under nref 4 and its Mnesia overlay table.
`register_dialect/3` additionally stamps the `base_language` AVP on
the dialect node, referencing the base language concept nref. Calling
`register_dialect/3` with an unregistered `BaseCode` is an error.
Both calls are idempotent on restart (seed-by-name pattern).

**M6-E: Overlay write**

```erlang
graphdb_language:set_labels(Nref, Code :: atom(), AVPs) -> ok | {error, _}
```

Writes or merges AVPs into the language overlay record for Nref in
`language_<Code>`. Merge semantics: existing AVPs for other attributes
on the same record are preserved; only the supplied AttrNrefs are
updated or added.

**M6-F: Translation agent hook**

```erlang
graphdb_language:register_translation_hook(Fun) -> ok
%% Fun :: fun((Nref :: integer(), DefaultAVPs :: [avp()]) -> ok)
```

Called after environment node creation with the new nref and its
English AVPs. Initially the hook list is empty (silent no-op). Multiple
hooks accumulate in registration order; all are called post-commit.
This is the designed insertion point for a future LLM-based translation
agent. As language overlays accumulate, translation patterns may emerge
and be encoded as rules — the hook is the path through which that
learning is initiated.

**M6-G: Project default language**

Seed `project_language` literal attribute in `graphdb_attr:init/1`
alongside `target_kind`, `relationship_avp`, `attribute_type`, and
`literal_type`. The project root node carries:

```erlang
#{attribute => project_language_nref, value => LanguageConceptNref}
```

Public API:

```erlang
graphdb_language:project_language(ProjectRootNref)
    -> {ok, Code :: atom()} | not_found
```

Reads the `project_language` AVP from the project root node and
returns the language code atom for the referenced concept node.

**M6-H: Session chain helper**

```erlang
graphdb_language:make_chain(Codes :: [atom()]) -> [atom()]
```

Validates each code against registered languages; drops unknown codes
with a log warning. Applies the dialect auto-insertion rule: for each
dialect code, look up the `base_language` AVP on its concept node to
find the base language code authoritatively (not by atom parsing).
If the base code does not appear anywhere after the dialect in the
remaining list, insert it immediately after the dialect. Deduplication:
when multiple dialects of the same base appear, one insertion suffices.
When the base is already present after the dialect, no insertion is
made.

Examples:

  - `[de, en_gb, fr]`       → `[de, en_gb, en, fr]`
  - `[en_gb, en_us]`        → `[en_gb, en, en_us]`
  - `[en_gb, en, fr]`       → `[en_gb, en, fr]`  (base already present)
  - `[pt_br, de]`           → `[pt_br, pt, de]`

Callers do not construct Mnesia table names directly.

**M6-I: Write-path integration**

When the NYI write operations (`create_attribute`, `create_class`,
`create_instance`) are implemented, each must:

  1. Create the environment node atomically in one Mnesia transaction.
  2. Call all registered translation hooks post-commit with the new
     nref and its English AVPs. (Outside the transaction — best-effort.)
  3. If a session language list is provided with labels, call
     `set_labels/3` for each language. (Also outside the transaction.)

Steps 2–3 are not atomically coupled to step 1 by design. A failed
hook or missing language label does not roll back node creation.

Dialect write discipline: do not auto-duplicate environment labels into
dialect overlay tables. A dialect overlay record is only written when
the label genuinely differs from the base language. The session
language list declares the context for new labels; deciding whether a
term warrants a dialect-specific override is an explicit authoring
decision, never inferred by the system.

**M6-J: Tests**

EUnit (`graphdb_language_tests.erl`) — pure function coverage:

  - `make_chain/1`: unknown codes silently dropped; known codes
    preserved in order.
  - `make_chain/1`: dialect auto-insertion — base inserted after
    dialect when absent (base determined from concept node AVP, not
    atom parsing).
  - `make_chain/1`: multiple dialects of same base — single insertion.
  - `make_chain/1`: base already present after dialect — no duplicate.

CT (`graphdb_language_SUITE.erl`) — integration:

  - Register language → overlay table created; idempotent on re-register.
  - Register dialect → concept node carries `base_language` AVP
    referencing base concept nref; `base_not_found` when base unregistered.
  - `set_labels/3` → AVP readable via `resolve_label/3`.
  - Fallback: no overlay record → resolves from environment node.
  - Chain priority: first-listed language wins over second.
  - `en` sentinel: chain containing `en` reads environment node
    directly; `language_en` table is not consulted.
  - Dialect hit: `en_gb` overlay record returned when present; falls
    through to environment when absent.
  - Dialect fallback chain: `[en_gb, en, fr]` — `en_gb` miss → `en`
    sentinel → environment node (skips `fr` because terminal matched).
  - Project language AVP written and retrieved correctly.
  - Translation hook: registered `Fun` called on node creation; empty
    list is a silent no-op.

**Dependencies:** None remaining. Must land before Task 6 — query
render-time label resolution depends on the language overlay API.

---

## Task 6 — `graphdb_language` query language

**Spec:** §13 (query) and §15 (multilingual).

**Evidence:** `apps/graphdb/src/graphdb_language.erl` is a gen_server stub
returning `?UEM` on every call.

**Scope (per §13/§15, broader than the original TASKS.md description):**
- Multi-criteria queries spanning class membership, attribute values,
  and connections in one query.
- Unit-tracked quantity expressions.
- Template-filtered traversal — kernel-side templates landed (M7);
  this task adds the query-side selectivity that reads the Template
  AVP off connection arcs.
- Language-tagged label resolution at render time — via M6 overlay API.
- Conversational/natural-language entry point (§13).

**Sub-tasks:**
- Define query DSL (term-shaped representation; natural-language frontend
  is later).
- `parse_query/1`, `execute_query/1`.
- Path queries: `find_path/3`.
- Render-time label lookup: call `resolve_label/3` with the per-call
  language chain at result rendering time.

**Dependencies:** C1, H1, H3–H5 (all landed). M6 must land first —
render-time label resolution depends on the language overlay API.

---

## M7. Template support — RESOLVED

**Spec:** §7 — *"A **template** is a named semantic context defined on a
class in the ontology. ... Not a blank form waiting to be filled — it
is an active node in the ontology."* Architecturally novel and
load-bearing per §16.

**Status:** Substantively landed during the H-task series alongside the
Connection-arc and Template-AVP work (C3).  M7 was originally written
expecting an as-yet-unimplemented kernel; the actual implementation
chose a slightly different shape (per-class templates rather than a
shared `Templates` subtree under Classes) which better matches §7's
"named semantic context defined on a class".

**What landed:**

  - 5th node kind: `kind = template` (not the AVP-flagged-class
    alternative).  Validated by `graphdb_bootstrap:kind_order/1`
    (template = 5) and used throughout `graphdb_class`.
  - Bootstrap node 31 — `Template` AVP-marker attribute, parented to
    nref 16 (Instance Relationships).  Stamped with `relationship_avp
    => true` post-bootstrap by `graphdb_attr:ensure_template_avp_
    marker/1`.
  - **Per-class templates** (architectural departure from the original
    sub-task list): templates are written as compositional children of
    their owning class, not as descendants of a shared
    `Classes/Templates` subtree.  Each `create_class/2` automatically
    attaches a `"default"` template; class authors may
    `add_template/2` more, or delete the default to force explicit
    template specification on every connection arc.
  - Public API on `graphdb_class`:
    - `add_template/2 (ClassNref, Name)`
      *(parameter order inverse of the originally proposed
      `create_template(Name, ClassNref)` — chosen for ClassNref-first
      consistency with the rest of the worker)*
    - `get_template/1`
    - `templates_for_class/1`
    - `default_template/1` — returns `not_found` once the default has
      been deleted
    - `class_in_ancestry/2` helper exposed for cross-worker scope
      checks
  - Template-scoped `add_relationship` on `graphdb_instance`:
    - `/4` resolves the source class's `default` template
    - `/5` accepts an explicit `TemplateNref :: integer()`
    - `/6` adds per-direction user AVPs (M5)
    - Template AVP `#{attribute => 31, value => TemplateNref}` is
      stamped at index 0 of each connection row's AVP list
    - `resolve_template/2` and `validate_template_scope/3` enforce
      that the chosen template's parent class is in the source
      instance's class ancestry; out-of-scope templates produce
      `{error, {template_class_not_in_ancestry, ...}}` and non-template
      nrefs produce `{error, {invalid_template, _, not_a_template}}`.

**Tests:**

  - `graphdb_class_SUITE` `templates` group — 7 cases covering create,
    duplicate-name rejection, non-class-parent rejection, lookup, list,
    default detection, and default-after-delete.
  - `graphdb_instance_SUITE` connection-arc cases — 4 cases covering
    Template AVP stamping (`/4` default, `/5` explicit), invalid-nref
    rejection, and out-of-ancestry rejection.
  - `graphdb_attr_SUITE` `seeding` group — 2 cases covering Template
    AVP marker stamping and idempotence on restart.
  - `graphdb_bootstrap_tests.erl` — `kind_order` and
    `validate_template_kind` cases.

**Open (deferred to Task 6):**

  - Template-scoped queries — finding all connections through a given
    template, or all templates routing through a given concept.  This
    is part of the query DSL surface area (Task 6) rather than the
    kernel write path covered by M7.

**Open (minor, deferrable):**

  - No public `delete_template/1` API — the
    `default_template_not_found_after_delete` test currently deletes
    the template node via raw `mnesia:delete`.  A worker-level
    `delete_template/1` would round out the API but is not blocking
    any consumer.

---

## E1. `graphdb_rules` — rule engine

**Spec:** §8 (rules as stored data), §9 (instantiation engine), §10
(composition rules), §11 (reactive learning).

**Evidence:** `apps/graphdb/src/graphdb_rules.erl` is a gen_server stub.

**Scope (much larger than the original TASKS.md "graph rules"):**

- **§10 composition rules** — class declares natural-constituent
  component types and mandatory connections. Engine fires at
  `create_instance` to propose/auto-create components.

- **§9 instantiation engine** — *guided* mode (one attribute at a time,
  ontology constrains options) and *automatic* mode (values derived
  from existing knowledge). Mode chosen by the ontology, not the
  kernel.

- **§11 reactive learning** —
  - *Naming-convention learning*: on attribute set, scan other AVPs on
    the same instance for substring matches; encode detected pattern as
    a class-level rule.
  - *Connection-pattern learning*: on connection creation, record the
    (source class, template, target class, connection type) tuple;
    accumulate into connection rules.

- All rules stored as typed data in the ontology (kind = `class` with a
  `is_rule = true` AVP, or a new `kind = rule` — same decision as
  templates).

**Dependencies:** kernel pre-requisites (C1 relationship kind; H1 and
H3–H5 correct inheritance; C3+M7 template support) have all landed,
so E1 is now unblocked on the kernel side.  Remains a future-feature
track in scope and effort, but called out in the spec as core, not
incidental.
