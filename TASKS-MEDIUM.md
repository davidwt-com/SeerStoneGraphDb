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

> **Pre-implementation gate:** Blockers R1–R4 in the Architecture
> Review section below must each have a recorded decision before any
> sub-task here is coded. R1 (project nref collision) and R2 (dialect
> algorithm) affect API signatures and test cases; resolving them first
> prevents cascading rework.

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

> **R6 (should fix):** Specify runtime `mnesia:create_table/2`
> behaviour in `register_language/2` and `register_dialect/3` —
> synchronous vs. async, timeout, concurrent-registration safety across
> nodes. See Architecture Review.

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

> **R3 (blocker):** Decide language concept node `kind` before
> implementing — `class` requires explicitly forbidding taxonomic arcs
> as a second base/dialect mechanism. Record decision before coding.
> See Architecture Review.
>
> **R4 (should fix):** Move `project_language` seeding from
> `graphdb_attr:init/1` to `graphdb_language:init/1` — owning worker
> pattern. See Architecture Review.

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

> **R1 (blocker):** Signature is missing the terminal-table parameter,
> and project nrefs share the same integer keyspace as environment
> nrefs — a single `language_*` table keyed by nref alone cannot
> distinguish them. Resolve the project-side overlay story (shared vs.
> per-project tables, key scheme) and update the signature before
> coding. See Architecture Review.
>
> **R8 (should fix):** Specify where the environment's declared
> language code is stored (config, AVP, constant) — the sentinel
> optimisation depends on this lookup being authoritative and fast.
> See Architecture Review.

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

> **R6 (should fix):** Specify runtime `mnesia:create_table/2`
> behaviour — synchronous, timeout, concurrent-registration safety.
> See Architecture Review.

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

> **R7 (should fix):** Hook must be invoked in a spawned process
> (`proc_lib:spawn/1`), never inline — inline blocks all callers and
> crashes the worker on exception. Add `unregister_translation_hook/1`
> for test cleanup. Clarify return-value contract (currently
> unspecified). See Architecture Review.

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

> **R1 (blocker):** Project-side overlay story unresolved — see M6-C
> callout and Architecture Review. This API cannot be fully specified
> until the project nref keyspace collision is resolved.

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

> **R2 (blocker):** Dialect auto-insertion algorithm is incorrect as
> written — "not after the dialect" produces wrong results for
> `[en_gb, en_us]` (inserts `en` twice). Correct rule: insert base if
> absent **anywhere in the chain as built so far**. Replace prose with
> operational pseudocode; re-derive all examples from the pseudocode
> before coding. See Architecture Review.

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

> **R1 (blocker):** Write-path integration for project instances cannot
> be specified until the project-side overlay story is resolved —
> including whether project-instance labels go into shared or
> per-project overlay tables. See Architecture Review R1 and R13.

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

> **R9 (should fix):** Add missing test cases before closing M6-J —
> hook crash during node creation (creation must succeed), `set_labels/3`
> for unregistered code (error, no write), re-register with different
> name (decide + test), dialect with deleted base concept (graceful
> resolution), `make_chain([])` → `[]`, transaction abort in
> `set_labels/3` (no partial write). See Architecture Review.

**Dependencies:** None remaining. Must land before Task 6 — query
render-time label resolution depends on the language overlay API.

---

### Architecture Review — Open Issues

Post-design audit conducted before implementation. Each blocker must be
resolved (with a decision recorded in the Decision Log) before any M6
code is written. Should-fix items should be resolved during the relevant
sub-task. Notes are informational and do not block.

#### Blockers

**R1. Project-side overlay story is unspecified — and nref collision
risk.** *(M6-C, M6-G, M6-I)*

`resolve_label/3` text says "caller passes project `nodes` table name
as explicit terminal parameter" but the 3-argument signature has no
such parameter. More critically: project nrefs start at 1 — the same
keyspace as environment nrefs. A project nref=5 and environment nref=5
are different nodes; a single `language_*` table keyed by nref alone
cannot distinguish them. Resolution options:

  - Extend to `resolve_label/4` with an explicit terminal-table atom;
    keep `language_*` tables environment-only; project overlays use
    separate per-project `<project_id>_language_*` tables.
  - Or: key overlay records by `{Scope, Nref}` (one table, two-part
    key) rather than nref alone.

Decision must also answer: do project instances get their own overlay
tables, or does label localisation for project nodes live elsewhere?
M6-I (write-path integration) cannot be specified until this is resolved.

**R2. Dialect auto-insertion algorithm produces incorrect results.**
*(M6-H)*

The stated rule — "if the base code does not appear anywhere *after*
the dialect in the remaining list" — is wrong for the supplied
examples. Applied to `[en_gb, en_us]`:

  1. Process `en_gb`: base=`en`, not after `en_gb` in `[en_gb, en_us]`
     → insert: `[en_gb, en, en_us]`.
  2. Process `en_us`: base=`en`, not after `en_us` in
     `[en_gb, en, en_us]` → inserts again: `[en_gb, en, en_us, en]`.

Stated result was `[en_gb, en, en_us]`. Also, `[en, en_gb, fr]` would
wrongly trigger insertion because `en` is not *after* the dialect. The
correct rule is: **insert base if it does not appear anywhere in the
chain as built so far (not just after the dialect)**. Replace the
prose description with operational pseudocode and verify each example
derives from the pseudocode mechanically. Correct the algorithm in
M6-H and generate the M6-J EUnit cases from the corrected spec.

**R3. Language concept node `kind` must be decided before implementation.**
*(M6-B)*

Leaving `kind` as "candidate: `class`" creates a risk: if `class` is
chosen, the taxonomic IS-A arc system provides a *second* mechanism for
expressing base/dialect beside the `base_language` AVP. Two mechanisms
for the same fact will diverge. Decision required:

  - Choose `class`: explicitly forbid using class taxonomy for the
    base/dialect relationship; `base_language` AVP is the sole
    authority.
  - Or: introduce `kind = language` (updates `kind_order/1`,
    validators, and bootstrap across the board).

`class` is simpler. Record the decision and the constraint.

**R4. Seeded literal attribute ownership is inconsistent.** *(M6-B,
M6-G)*

`base_language` is seeded by `graphdb_language:init/1`; `project_language`
is seeded by `graphdb_attr:init/1`. Both are AVP-marker literals with
the same structural role. The established pattern (`qualifying_characteristic`
seeded by `graphdb_class`, `target_kind` by `graphdb_instance`) is:
the *owning worker* seeds its own attributes. `project_language` belongs
to the language layer, not the attribute library. Move its seeding to
`graphdb_language:init/1`.

#### Should Fix

**R5. §15 departure is undocumented.** *(Design)*

§15 says "concepts are stored language-neutrally." The design stores
English directly on environment nodes. This is a defensible choice, but
it is a departure from the strict reading of §15. Add a Decision Log
entry documenting the departure and its rationale before closing M6.

**R6. Runtime Mnesia table creation needs operational specification.**
*(M6-A, M6-D)*

`mnesia:create_table/2` called from a running gen_server holds a schema
write-lock and can block under load or fail under partition in a
distributed schema. Specify: synchronous call during
`register_language/2`? Timeout? Concurrent-registration safety across
nodes? What happens if the node is `disc_copies` but the peer hasn't
seen the schema change?

**R7. Translation hook execution model is unsafe as written.** *(M6-F)*

Inline hook invocation from a gen_server blocks all other callers for
the hook's duration and crashes the worker if a hook raises. Required
changes:

  - Invoke each hook in a spawned process (`proc_lib:spawn/1`), never
    inline.
  - Catch all errors; log and discard — never propagate to the caller.
  - Forbid synchronous re-entry into `graphdb_language` from a hook
    (deadlock).
  - Add `unregister_translation_hook(Fun) -> ok` — tests must be able
    to clean up between cases; accumulating hooks across tests is a
    resource leak.

**R8. Environment language declaration mechanism is unspecified.**
*(M6-C)*

M6-C says "`en` by default, readable from `seeded_nrefs/0`" but
`seeded_nrefs/0` returns nrefs, not language codes. Where is the
environment's declared language code stored? Hard-coded atom? Config
parameter? AVP on the Languages category node (nref 4)? The sentinel
optimisation in `resolve_label` depends on this lookup being
authoritative and fast. Specify storage and retrieval before coding
M6-C.

**R9. Test coverage gaps.** *(M6-J)*

Missing cases from the current test spec:

  - Translation hook crashes mid-create: node creation must succeed.
  - `set_labels/3` with an unregistered language code: error before
    any write.
  - Re-register an already-registered language with a different name:
    error or overwrite? (Decision + test.)
  - Dialect concept node whose `base_language` AVP references a
    deleted/missing concept: graceful resolution path.
  - `make_chain([])` → `[]`.
  - Mnesia transaction abort during `set_labels/3`: caller sees error,
    no partial write.

#### Notes

**R10. Locale code format is undocumented.** `en_gb` (underscore,
lowercase atom) departs from IETF BCP 47 (`en-GB`). Fine for atom
convenience but should be a documented choice in the Decision Log.

**R11. No batch resolver API.** `resolve_label/3` is per-AVP.
Task 6 render-time will call it per attribute per node. A future
`resolve_labels(Nref, [AttrNref], Chain) -> #{AttrNref => Value}` will
be wanted. Note for Task 6 planning; not blocking M6.

**R12. Mnesia table proliferation ceiling.** Default Mnesia schema
supports ~1024 tables. ISO 639 base codes (~200) plus dialects could
approach that in a fully-internationalised deployment. Most deployments
stay well under 20. Acceptable now; fallback design is a single
`language_overlays` table keyed by `{Code, Nref}`. Revisit if a
deployment actually approaches the ceiling.

**R13. Project-side overlays absent from write-path plan.** *(M6-I)*

Project instances have labels (instance names, project-specific terms).
The plan covers project *terminal fallback* (project root carries
`project_language` AVP) but does not specify how project-instance
labels are written into overlay tables or retrieved. Overlaps with
blocker R1 — resolving R1 should also answer this.

**R14. Snapshot consistency during render.** Multiple sequential
`resolve_label/3` calls while a concurrent `set_labels/3` is mid-flight
can return a mix of old and new values for the same node. Acceptable
for labels but should be noted in the Decision Log so it is not later
misconstrued as a correctness bug.

**R15. Translation hook return value contract undefined.** *(M6-F)*

The current signature `Fun :: fun((Nref, DefaultAVPs) -> ok)` implies
the return is always `ok`, but this is not enforced. Document explicitly
that the return value is discarded, or change the contract to
`-> ok | {error, Reason}` and specify what happens on error.

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
