<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Remaining Tasks

Organized by execution sequence. Feature phases must land in the order
shown — each gates the next. Engineering Hygiene tasks have no blocking
dependencies and can be interleaved at any point.

Resolved tasks are archived in `TASKS-DONE.md`.
`TASKS-MEDIUM.md` and `TASKS-LOW.md` are superseded by this file;
they will be removed in the next PR.

---

## Feature Track

---

## F1. Language Ontology Bootstrap — RESOLVED

Gate: must land before F2. `the-knowledge-network.md` §15 now documents
Languages as any communication form with grammar, syntax, and tokens or
icons — significantly broader than human natural languages alone. Four
top-level categories belong under the Languages node (nref 4):

**Status:** Complete. Nrefs 32–35 seeded in `bootstrap.terms`. CT
coverage in `graphdb_bootstrap_SUITE` (`load_language_subcategories`).

- Human Languages — written and verbal natural languages
- Formal Languages — programming languages, query languages,
  mathematical notation
- Diagram Languages — UML, engineering schematics, tabular forms,
  hierarchical diagrams
- Renderers — shared rendering engines (also: views)

The current `bootstrap.terms` has no named subcategories under nref 4.
This task adds them, updates all dependents, and resolves any code
implications before F2 coding begins.

### Planning step

Output: nref assignments + any new sub-tasks appended to Engineering
Hygiene. Audit before writing code:

1. All code that references nref 4 or the Languages subtree by nref
   constant — note what each piece needs.
2. All CT assertions on exact bootstrap node/arc counts — these will
   need updating (+4 nodes, +8 arcs minimum).
3. Final nref assignments for the four new category nodes (candidates:
   32–35; confirm no conflicts with existing bootstrap or seeded nrefs).
4. Any deferred follow-up tasks surfaced — append to Engineering
   Hygiene below.

Record nref assignments in the CLAUDE.md Bootstrap Nref
Quick-Reference table and cerebrum.md before writing any code.

### Execution

1. `apps/graphdb/priv/bootstrap.terms` — add four category nodes and
   eight compositional arc rows (two per parent/child pair, connecting
   each new node to Languages nref 4). Arc labels: ChildArc=22,
   ParentArc=21; `kind=composition` — same pattern as all other
   category arcs.

2. `CLAUDE.md` — update Bootstrap Nref Quick-Reference table with the
   four new entries.

3. CT suites asserting exact node/arc counts — update expectations.

4. This file (F2, M6-B and M6-D) — update English concept node seeding
   target to Human Languages (assigned nref), not nref 4 directly.

**Dependencies:** none upstream. Gates F2.

---

## F2. M6 — Multilingual Layer

**Depends on F1.**

**Spec:** §15 — *"Concepts are stored language-neutrally in the
ontology. Labels, prompts, and vocabulary entries are stored per
language and swapped at rendering time without modifying the
knowledge."* (§15 > Human Languages)

**Design:** The environment node record (`#node{}`) is unchanged and
the environment database is the English default — the terminal fallback
for every language chain. English is the practical common language of
international communication; it is acknowledged as the environment's
base language without apology. Language-specific labels are stored in
per-language Mnesia tables within the same schema (overlay model). A
language chain is a runtime parameter scoped to the session, user, or
use case; resolution walks the chain left-to-right and falls through to
the environment node on miss. Per-AVP override semantics: a language
overlay record carries only the AVPs it overrides; all other AVPs
resolve from the environment node unchanged.

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
under Human Languages (nref 32) using the standard
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

Both create the concept node under Human Languages (nref 32) and its Mnesia overlay table. `register_dialect/3` additionally
stamps the `base_language` AVP on the dialect node, referencing the
base language concept nref. Calling `register_dialect/3` with an
unregistered `BaseCode` is an error. Both calls are idempotent on
restart (seed-by-name pattern).

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
find the base language code authoritatively (not by atom parsing). If
the base code does not appear anywhere in the chain as built so far,
insert it immediately after the dialect. Deduplication: when multiple
dialects of the same base appear, one insertion suffices.

Examples (derive each mechanically from pseudocode before coding):

  - `[de, en_gb, fr]`    → `[de, en_gb, en, fr]`
  - `[en_gb, en_us]`     → `[en_gb, en, en_us]`
  - `[en_gb, en, fr]`    → `[en_gb, en, fr]`   (base already in chain)
  - `[pt_br, de]`        → `[pt_br, pt, de]`

Callers do not construct Mnesia table names directly.

> **R2 (blocker):** Write operational pseudocode for the algorithm
> above and verify each example derives from it mechanically before
> coding. The original prose rule ("not after the dialect") was wrong
> — see Architecture Review. The corrected rule is stated here; the
> pseudocode is the required pre-coding artifact.

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
  - `make_chain/1`: dialect auto-insertion — base inserted when absent
    from chain as built so far (base determined from concept node AVP,
    not atom parsing).
  - `make_chain/1`: multiple dialects of same base — single insertion.
  - `make_chain/1`: base already present in chain — no duplicate.
  - `make_chain([])` → `[]`.

CT (`graphdb_language_SUITE.erl`) — integration:

  - Register language → overlay table created; idempotent on
    re-register.
  - Register dialect → concept node carries `base_language` AVP
    referencing base concept nref; `base_not_found` when base
    unregistered.
  - `set_labels/3` → AVP readable via `resolve_label/3`.
  - `set_labels/3` with unregistered code → error, no write.
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
  - Translation hook crash during node creation: creation must succeed.
  - Re-register an already-registered language with a different name:
    decide (error or overwrite) and test.
  - Dialect node whose `base_language` AVP references a missing
    concept: graceful resolution path.
  - Mnesia transaction abort during `set_labels/3`: caller sees error,
    no partial write.

**Dependencies:** F1 must land first. Must land before F3 — query
render-time label resolution depends on the language overlay API.

---

### Architecture Review — Open Issues

Post-design audit conducted before implementation. Each blocker must be
resolved (with a decision recorded in the Decision Log) before any M6
code is written. Should-fix items should be resolved during the
relevant sub-task. Notes are informational and do not block.

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
M6-I (write-path integration) cannot be specified until this is
resolved.

**R2. Dialect auto-insertion algorithm requires pseudocode.**
*(M6-H)*

The original prose rule ("if the base code does not appear anywhere
*after* the dialect in the remaining list") produces wrong results for
`[en_gb, en_us]` — it inserts `en` twice. The corrected rule is
stated in M6-H: insert base if it does not appear anywhere in the
chain as built so far. Write operational pseudocode and derive every
example in M6-H from it mechanically before coding or writing EUnit
cases.

**R3. Language concept node `kind` must be decided before
implementation.** *(M6-B)*

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

`base_language` is seeded by `graphdb_language:init/1`;
`project_language` is seeded by `graphdb_attr:init/1`. Both are
AVP-marker literals with the same structural role. The established
pattern (`qualifying_characteristic` seeded by `graphdb_class`,
`target_kind` by `graphdb_instance`) is: the *owning worker* seeds
its own attributes. `project_language` belongs to the language layer,
not the attribute library. Move its seeding to
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
write-lock and can block under load or fail under partition. Specify:
synchronous call during `register_language/2`? Timeout?
Concurrent-registration safety across nodes? What happens if the peer
hasn't seen the schema change?

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
    to clean up between cases.

**R8. Environment language declaration mechanism is unspecified.**
*(M6-C)*

M6-C says "`en` by default, readable from `seeded_nrefs/0`" but
`seeded_nrefs/0` returns nrefs, not language codes. Where is the
environment's declared language code stored? Hard-coded atom? Config
parameter? AVP on the Languages category node (nref 4)? Specify
storage and retrieval before coding M6-C.

#### Notes

**R9. Test coverage gaps resolved in M6-J above.** The cases missing
from the original spec have been folded into the M6-J test list.

**R10. Locale code format is undocumented.** `en_gb` (underscore,
lowercase atom) departs from IETF BCP 47 (`en-GB`). Fine for atom
convenience but should be a documented choice in the Decision Log.

**R11. No batch resolver API.** `resolve_label/3` is per-AVP. A
future `resolve_labels(Nref, [AttrNref], Chain) -> #{AttrNref => Value}`
will be wanted at F3 render time. Note for F3 planning; not blocking
M6.

**R12. Mnesia table proliferation ceiling.** Default Mnesia schema
supports ~1024 tables. ISO 639 base codes (~200) plus dialects could
approach that in a fully-internationalised deployment. Most deployments
stay well under 20. Fallback design is a single `language_overlays`
table keyed by `{Code, Nref}`. Revisit if a deployment approaches the
ceiling.

**R13. Project-side overlays absent from write-path plan.** *(M6-I)*

The plan covers project *terminal fallback* but does not specify how
project-instance labels are written into overlay tables or retrieved.
Overlaps with blocker R1 — resolving R1 should also answer this.

**R14. Snapshot consistency during render.** Multiple sequential
`resolve_label/3` calls while a concurrent `set_labels/3` is mid-flight
can return a mix of old and new values. Acceptable for labels; document
in the Decision Log so it is not later misconstrued as a correctness
bug.

**R15. Translation hook return value contract undefined.** *(M6-F)*

The signature `Fun :: fun((Nref, DefaultAVPs) -> ok)` implies the
return is always `ok`, but this is not enforced. Document explicitly
that the return value is discarded, or change the contract to
`-> ok | {error, Reason}` and specify what happens on error.

---

## F3. Task 6 — `graphdb_language` Query Language

**Depends on F2.**

**Spec:** §13 (query) and §15 (languages).

**Evidence:** `apps/graphdb/src/graphdb_language.erl` is a gen_server
stub returning `?UEM` on every call.

**Scope:**

- Multi-criteria queries spanning class membership, attribute values,
  and connections in one query.
- Unit-tracked quantity expressions.
- Template-filtered traversal — kernel-side templates landed (M7);
  this task adds the query-side selectivity that reads the Template
  AVP off connection arcs.
- Language-tagged label resolution at render time — via M6 overlay API.
- Conversational/natural-language entry point (§13).

**Sub-tasks:**

- Define query DSL (term-shaped representation; natural-language
  frontend is later).
- `parse_query/1`, `execute_query/1`.
- Path queries: `find_path/3`.
- Render-time label lookup: call `resolve_label/3` with the per-call
  language chain at result rendering time.

**Dependencies:** F2 must land first.

---

## F4. E1 — `graphdb_rules` Rule Engine

**Can start after F1. Parallel to F3 at discretion — E1 is large
scope; serial execution (F3 then F4) is a reasonable alternative.**

**Spec:** §8 (rules as stored data), §9 (instantiation engine), §10
(composition rules), §11 (reactive learning).

**Evidence:** `apps/graphdb/src/graphdb_rules.erl` is a gen_server stub.

**Scope:**

- **§10 Composition rules** — class declares natural-constituent
  component types and mandatory connections. Engine fires at
  `create_instance` to propose or auto-create components.

- **§9 Instantiation engine** — *guided* mode (one attribute at a
  time, ontology constrains options) and *automatic* mode (values
  derived from existing knowledge). Mode chosen by the ontology, not
  the kernel.

- **§11 Reactive learning:**
  - *Naming-convention learning*: on attribute set, scan other AVPs on
    the same instance for substring matches; encode detected pattern as
    a class-level rule.
  - *Connection-pattern learning*: on connection creation, record the
    (source class, template, target class, connection type) tuple;
    accumulate into connection rules.

- All rules stored as typed data in the ontology (kind = `class` with
  an `is_rule = true` AVP, or a new `kind = rule` — same decision
  point as templates faced).

**Dependencies:** kernel pre-requisites (relationship kind, correct
inheritance, template support) have all landed. E1 is unblocked on the
kernel side.

---

## Engineering Hygiene

No blocking dependencies on any feature phase. Interleave at any point.

---

### L1. Rename `inherited_attributes/1` → `inherited_qcs/1`

**Evidence:** `graphdb_class.erl:230-238, 638-651`.

The function returns qualifying-characteristic *attribute nrefs* from
the class and its ancestors — not inherited *values*. The name
`inherited_attributes` implies §6 value inheritance, which is
different.

**Fix:** rename to `inherited_qcs/1`. Reserve `inherited_attributes`
for §6 semantics if/when class-level bound-value inheritance is exposed
as its own API.

---

### L2. Separate QC list from bound values on the class node

**Evidence:** `graphdb_class.erl:524-562`. `do_add_qc` writes
qualifying-characteristic pointers into `attribute_value_pairs` keyed
by `qc_attr_nref`. Class-bound values are written into the same list,
keyed by other attribute nrefs. The `resolve_from_class` lookup in
`graphdb_instance` is already vulnerable to confusion: asking for the
value of `qc_attr_nref` returns another attribute's nref.

**Fix:** add a dedicated `qcs :: [integer()]` field to the `node`
record (only meaningful for `kind = class`), or mark QC entries with a
distinct AVP shape (e.g., `#{kind => qc, attribute => AttrNref}`).

**Note:** best done before F4 (E1) starts adding more concept tags to
class nodes.

---

### L3. Single-row reads run inside `mnesia:transaction/1`

**Evidence:** `graphdb_class.erl:506, 569-575, 601-611`,
`graphdb_instance.erl:393, 406, 453-459, 486, 499`,
`graphdb_mgr.erl:357`.

**Fix:** use `mnesia:dirty_read/2` for read-only single-row lookups
that don't need transactional isolation. Reserve transactions for
multi-row writes and reads that must observe atomic state.

---

### L4. Wire `graphdb_mgr` write-side to workers

**Evidence:** `graphdb_mgr.erl:278-296`. `create_attribute`,
`create_class`, `create_instance`, `add_relationship` all return
`{error, not_implemented}` despite the workers being fully functional.

The spec's organizing claim is that `graphdb_mgr` is the single public
entry point. Today that is true only for reads. *Higher impact than
others in this section — restores the spec's public API contract.*

**Fix:** delegate each handler to the corresponding worker:
- `create_attribute` → `graphdb_attr:create_*` (route by kind)
- `create_class` → `graphdb_class:create_class/2`
- `create_instance` → `graphdb_instance:create_instance/3`
- `add_relationship` → `graphdb_instance:add_relationship/4`
- `delete_node`, `update_node_avps` → category guard, then
  kind-appropriate worker.

---

### L5. Relationship row IDs allocated from the global `nref_server`

**Evidence:** `graphdb_attr.erl:453-454`, `graphdb_class.erl:416-417,
465-466`, `graphdb_instance.erl:329-332, 421-422`,
`graphdb_bootstrap.erl:388-389`.

The `id` field is the relationship row's primary key, not a
graph-visible reference. Sharing the global nref allocator means
relationship rows consume integers that could otherwise identify nodes.

**Fix:** add a separate `relationship_id_server` (or extend
`nref_allocator` with a second counter). Migrate all `id` allocations
to it.

---

### Task 7. Wire `dictionary_server` and `term_server` to `dictionary_imp`

**Evidence:** `apps/dictionary/src/dictionary_server.erl` and
`apps/dictionary/src/term_server.erl` are gen_server stubs.
`dictionary_imp` is fully implemented.

**Fix:** delegate from each gen_server to the relevant `dictionary_imp`
functions. Independent of all graphdb work.

---

### E2. Non-normal OTP start types

**Evidence:** `seerstone:start/2` and `nref:start/2` both hit `?NYI`
for `{takeover, Node}` and `{failover, Node}` start types.

**Fix:** implement when distributed deployment is on the roadmap.

---

### E3. `code_change/3` — hot code upgrades

**Evidence:** NYI in all gen_server modules: `nref_allocator`,
`nref_server`, all six `graphdb_*` workers.

**Fix:** implement when first hot-upgrade is planned.

---

### E4. `start_phases` / `start_phase/3`

None of the `.app.src` files define `start_phases`, so `start_phase/3`
is never called. Revisit if phased startup is desired.

---

### E5. Replace `included_applications` with peer-app dependencies

**Evidence:** `apps/database/src/database.app.src` declares
`included_applications: [graphdb, dictionary]`. This is Dallas's 2008
OTP idiom; modern OTP discourages it because included apps lose
independent restart, code reload, and application-callback semantics.
The `seerstone`↔`database` boundary was already modernized (2026-05-09);
this applies the same treatment one level deeper.

**Fix:**

1. Remove `included_applications: [graphdb, dictionary]` from
   `database.app.src`. Add `graphdb` and `dictionary` to a higher-level
   `applications:` dependency list.
2. Drop `graphdb_sup` and `dictionary_sup` from `database_sup:init/1`.
3. Decide whether `database` itself remains an OTP application.
4. Update `ARCHITECTURE.md` §5 and supervision-tree diagrams in
   `CLAUDE.md` files.

**Note:** best done before E3 and E2, since `included_applications`
complicates both hot upgrades and distributed-app semantics.
