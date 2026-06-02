<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# SeerStoneGraphDb — Remaining Tasks

Organized by execution sequence. Feature phases must land in the order
shown — each gates the next. Engineering Hygiene tasks have no blocking
dependencies and can be interleaved at any point.

Resolved tasks are archived in `TASKS-DONE.md`.

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

## F2. M6 — Multilingual Layer — RESOLVED

**Status:** Complete. `graphdb_language` is a fully implemented gen_server.
24/24 CT tests pass (`graphdb_language_SUITE`). 192/192 CT total, 99 EUnit,
zero warnings. M6-I (write-path integration) is explicitly deferred — it
depends on L4 (wire `graphdb_mgr` write-side). All Architecture Review issues
R1–R10 are resolved or closed. See Decision Log below.

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

**Completed state:** `graphdb_language.erl` is a full gen_server
implementation covering M6-A through M6-H and M6-J. `bootstrap.terms`
carries English strings as node AVPs — these are the English default and
require no migration. M6-I is deferred to L4.

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
ensure-seed-by-name pattern. **Node kind: `instance`.** English is
already bootstrapped as `kind=instance` at nref 10000 (F2); all
language nodes (base languages, dialects) follow the same kind.
`kind=instance` eliminates the dual-mechanism risk: instances do not
participate in taxonomic IS-A arcs, so `base_language` AVP is the
sole authority for base/dialect relationships. The English nref is
cached in gen_server state and exposed via
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

> **R3: RESOLVED** — `kind=instance` for all language nodes.
> See Decision Log.
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
with a log warning. Applies the dialect auto-insertion rule using the
following verified pseudocode:

```
make_chain(InputCodes):
  ValidCodes = [C || C <- InputCodes, is_registered(C)]
  Output    = []
  Remaining = ValidCodes
  while Remaining != []:
    Code      = head(Remaining)
    Remaining = tail(Remaining)
    Output    = Output ++ [Code]          % always emit
    if is_dialect(Code):                  % concept node has base_language AVP
      Base      = base_language_of(Code)  % AVP nref → concept node → lang_code atom
      FullChain = Output ++ Remaining     % current output (incl. Code) + remaining input
      if Base not in FullChain:
        Output = Output ++ [Base]         % insert base immediately after dialect
  return Output
```

The check is `Base not in (Output ++ Remaining)` — the full current
chain view, not just the output built so far. A base that still
appears later in the remaining input is not re-inserted.

Verified derivations:

  - `[de, en_gb, fr]`  → `[de, en_gb, en, fr]`    (en∉[de,en_gb,fr] → insert)
  - `[en_gb, en_us]`   → `[en_gb, en, en_us]`      (en∉[en_gb,en_us] → insert after en_gb;
                                                      en∈[en_gb,en,en_us] → skip after en_us)
  - `[en_gb, en, fr]`  → `[en_gb, en, fr]`          (en∈[en_gb,en,fr] → skip)
  - `[pt_br, de]`      → `[pt_br, pt, de]`          (pt∉[pt_br,de] → insert)

Implementation notes:
- `base_language_of/1` does two Mnesia reads: concept-node-by-code →
  `base_language` AVP nref → concept-node-by-nref → `lang_code` atom.
  Cache results within a single `make_chain/1` call.
- `is_dialect/1` is a check for the presence of `base_language` AVP
  on the concept node — no separate flag needed.

Callers do not construct Mnesia table names directly.

> **R2: RESOLVED** — pseudocode verified against all four examples.
> See Decision Log.

**M6-I: Write-path integration** *(DEFERRED to L4)*

Depends on L4 (wire `graphdb_mgr` write-side operations). When the
NYI write operations (`create_attribute`, `create_class`,
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

**R1. RESOLVED** — `resolve_label/4` with `Scope :: environment | {project, AnchorNref}`.
Environment tables: `language_<code>`. Project tables: `language_<code>_<anchor_nref>`.
`overlay_table_name/2` encodes both forms. M6-I (write-path integration) depends on
L4 (wire graphdb_mgr write-side) and is explicitly deferred. See Decision Log.

**R2. RESOLVED** — Pseudocode verified in M6-H. The check is
`Base not in (Output ++ Remaining)` (full chain view). See Decision
Log.

**R3. RESOLVED** — `kind=instance` for all language nodes. See
Decision Log.

**R4. RESOLVED** — `project_language` seeded by
`graphdb_language:init/1`. Owning-worker pattern confirmed. See
Decision Log.

#### Should Fix

**R5. RESOLVED** — Environment stores English strings directly on
`#node{}` records (name AVPs on environment nodes). Documented
departure from the strict reading of §15. Rationale: English is the
environment's base language; reading it directly from the node record is
zero-overhead and the en sentinel in `do_resolve_chain/4` makes this
explicit by design, not accident. See Decision Log.

**R6. RESOLVED** — `mnesia:create_table/2` called synchronously from
`ensure_overlay_table/1` during `register_language/2` and
`register_dialect/3`. The gen_server serialises all callers; no
concurrent registration races within a single node. Default Mnesia
timeout applies. Multi-node schema propagation is a known future
concern (R12 tracks table-count ceiling); acceptable for the
current single-node deployment model. See Decision Log.

**R7. RESOLVED** — Hooks spawned via `proc_lib:spawn/1`; never inline.
Each hook body wrapped in try/catch; errors logged and discarded;
never propagated to the caller. `unregister_translation_hook/1`
added for test cleanup. See Decision Log.

**R8. RESOLVED** — Environment language code stored as compile-time
macro `?ENV_LANGUAGE_CODE = en` in `graphdb_language.erl`. Exposed
via `seeded_nrefs/0` as `env_language_code => en` so callers and
tests can read it without a magic atom. See Decision Log.

#### Notes

**R9. Test coverage gaps resolved in M6-J above.** The cases missing
from the original spec have been folded into the M6-J test list.

**R10. RESOLVED** — `en_gb` (underscore-separated lowercase atom)
chosen over IETF BCP 47 `en-GB`. Rationale: Erlang atoms cannot
contain unquoted hyphens; requiring quoted atoms (`'en-GB'`) would
make API usage awkward. Underscore-lowercase is idiomatic in Erlang.
The convention is documented; not a format bug. See Decision Log.

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

#### Decision Log

**R1 — Scope type: `environment | {project, AnchorNref}`** (2026-05-18)

`resolve_label/4` takes a `Scope` argument distinguishing environment
reads (table `language_<code>`) from project reads (table
`language_<code>_<anchor_nref>`). M6-I (project write-path) deferred
to L4; the scope type is already in the public API so the boundary is
clean when L4 lands.

**R2 — Dialect auto-insertion uses full chain view** (2026-05-18)

`do_make_chain/3` checks `Base not in (Output ++ Remaining)` —
the full chain view, not just the output so far. This ensures a base
already scheduled to appear later in the chain is not inserted early
and duplicated. Verified by hand-tracing `[en_gb, en_us]` with
`en_gb=>en, en_us=>en`.

**R5 — English on env node records, not overlay table** (2026-05-18)

English strings live on `#node{}` `attribute_value_pairs` fields, not
in a `language_en` Mnesia table. The `en` sentinel in
`do_resolve_chain/4` bypasses the overlay lookup and reads the node
directly. Rationale: zero-overhead for the most common case; avoids
duplicating every English label into a separate table at bootstrap.
This is a deliberate departure from the strict reading of §15
("language-neutral storage") — English is the structural language of
the environment and is treated specially by design.

**R6 — Synchronous overlay table creation, single-node only** (2026-05-18)

`mnesia:create_table/2` is called synchronously inside the gen_server
handler for `register_language/2`. The gen_server serialises all
callers so there is no concurrent-registration race within a node.
Multi-node schema distribution is a known future concern deferred to
whenever multi-node support is added; for now the single-node model
is the only deployment target.

**R7 — Hooks spawned, crash-safe, unregister for tests** (2026-05-18)

Translation hooks are invoked via `proc_lib:spawn/1` so a slow or
crashing hook cannot block or kill the gen_server. Each hook body is
wrapped in try/catch; errors are logged and discarded. The return
value is always discarded. `unregister_translation_hook/1` exists
specifically so CT cases can clean up their hooks between test cases.

**R8 — Environment language code as compile-time macro** (2026-05-18)

`?ENV_LANGUAGE_CODE = en` is a module-level macro. Exposed through
`seeded_nrefs/0` as `env_language_code => en` so callers can read it
without an atom literal. Chosen over a config parameter because the
environment language is a structural invariant, not a deployment
setting — changing it would require re-bootstrapping the entire
environment.

**R10 — Underscore-lowercase atom convention for locale codes** (2026-05-18)

`en_gb` rather than `'en-GB'`. Erlang atoms containing hyphens must
be quoted; unquoted `en_gb` is idiomatic and avoids the quoting
requirement. All locale codes in the API follow this convention.
Applications bridging to BCP 47 external systems must translate at
the boundary.

---

## F3. graphdb Query Language — RESOLVED

Implemented as `graphdb_query` (the `graphdb_language` slot is occupied
by the M6 multilingual overlay layer). Design at
`docs/designs/f3-graphdb-query-design.md`; plan at
`docs/superpowers/plans/2026-05-23-f3-graphdb-query.md`. Seven query
primitives (Q1, Q1b, Q2-Q6), snapshot-semantics sessions, continuation
+ resume with `snapshot_expired` detection. Template-filtered
traversal lands in a future iteration alongside richer query criteria.

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

### L1. Rename `inherited_attributes/1` → `inherited_qcs/1` — RESOLVED (subsumed by L2)

**Evidence:** `graphdb_class.erl:230-238, 638-651`.

The function returns qualifying-characteristic *attribute nrefs* from
the class and its ancestors — not inherited *values*. The name
`inherited_attributes` implies §6 value inheritance, which is
different.

**Fix:** rename to `inherited_qcs/1`. Reserve `inherited_attributes`
for §6 semantics if/when class-level bound-value inheritance is exposed
as its own API.

---

### L2. Unify QC declarations and class-bound values into a single AVP shape — RESOLVED

**Evidence:** `graphdb_class.erl:524-562, 863-908, 1001-1040`.
`do_add_qc` currently writes a sentinel-keyed AVP
`#{attribute => QcAttrNref, value => AttrNref}` to record that
`AttrNref` is a qualifying characteristic. Class-bound values (e.g.
`#{attribute => ColorAttrNref, value => red}`) share the same AVP list
but use a different key. `resolve_from_class` in `graphdb_instance`
must avoid confusing the two, and adding more concept tags in F4 would
make the list harder to reason about.

**Fix:** replace the sentinel-keyed pattern with a unified shape:

- **QC declared, no bound value:** `#{attribute => AttrNref, value => undefined}`
- **QC with class-level bound value:** `#{attribute => AttrNref, value => SomeValue}`

Both forms are normal AVPs keyed by the actual attribute nref. Adding a
QC writes `undefined`; binding a class value updates the entry (or
writes it if not yet declared). `resolve_from_class` skips
`value = undefined` entries — they are schema declarations, not
resolved values. Inheritance walk collects all unique `attribute` keys
nearest-first, carrying `{AttrNref, Value | undefined}` pairs.

**Changes required:**

1. Remove the seeded `qualifying_characteristic` literal attribute and
   `qc_attr_nref` from `graphdb_class` state — no longer needed.
2. `do_add_qc/3` writes `#{attribute => AttrNref, value => undefined}`.
   Idempotent: if the key already exists (any value), leave it alone.
3. `inherited_attributes/1` → `inherited_qcs/1` (L1 rename, fold in
   here). Return type changes from `[AttrNref]` to
   `[{AttrNref, Value | undefined}]`, deduplicating by `AttrNref` with
   nearest-ancestor priority.
4. `collect_all_qcs/2` and `collect_qc_nrefs/2` simplified to a fold
   over all AVPs with dedup by `attribute` key.
5. `search_class_taxonomy` in `graphdb_instance.erl` — guard
   `value =/= undefined` before treating an AVP as a resolved hit.

**Deferred:** instance-only enforcement (attributes that must never
receive a class-level value) belongs in the template attribute list,
which does not yet exist. The `undefined` shape accommodates this
naturally — an instance-only attribute stays `undefined` at every class
level. Enforcement is a follow-on task adjacent to L4/F4.

**Note:** best done before F4 (E1) starts adding more concept tags to
class nodes. Subsumes L1 (`inherited_attributes/1` → `inherited_qcs/1`).

---

### L3. Single-row reads run inside `mnesia:transaction/1` — RESOLVED

**Evidence:** `graphdb_class.erl:506, 569-575, 601-611`,
`graphdb_instance.erl:393, 406, 453-459, 486, 499`,
`graphdb_mgr.erl:357`.

**Fix:** use `mnesia:dirty_read/2` for read-only single-row lookups
that don't need transactional isolation. Reserve transactions for
multi-row writes and reads that must observe atomic state.

---

### L4. Wire `graphdb_mgr` write-side to workers — RESOLVED

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

**Design note — attribute categories per class context:**

When wiring `create_class` and `update_node_avps`, the write-side must
account for two categories of attributes that a class declares:

- **Class-bindable** — the class may supply a value (or a useful
  default) for this attribute. Instances inherit the value and may
  override it. Example: `num_wheels = 4` on a Car class.
- **Instance-only** — the class declares the attribute as relevant but
  binding a value at the class level is a category error. The value is
  meaningful only per-instance. Example: `serial_number`, `owner_name`.
  Attempting to bind a class-level value for such an attribute should be
  rejected or flagged.

This distinction is **per-class, per-template context** — the same
attribute may be class-bindable in one class's template and instance-only
in another's. The enforcement point belongs in the template's attribute
declaration, not on the attribute node globally.

The template attribute list does not yet exist (templates currently carry
only a name and their compositional arc). L4 implementation should treat
this as a known gap: wire the delegation first, then plan the template
attribute list and instance-only enforcement as a follow-on task (likely
adjacent to F4/E1, which adds rule-driven instantiation). Document the
gap in the Decision Log when L4 lands.

#### Decision Log

**L4 — `create_attribute` routing by ParentNref** (2026-05-18)

`graphdb_mgr:create_attribute/3` routes to the appropriate
`graphdb_attr` worker function based on `ParentNref`:
- 6 / 9–12 (Names subtree) → `create_name_attribute/1`
- 7 (Literals) → `create_literal_attribute/2`; `type` extracted from `AVPs` map (default `string`)
- 8 / 13–16 (Relationships subtree) → `create_relationship_attribute/3` if both
  `reciprocal_name` and `target_kind` present; `create_relationship_type/1` if neither;
  `{error, {missing_avps, ...}}` if exactly one is present
- Unknown parent → `{error, {unknown_attribute_parent, Nref}}`

`create_relationship_attribute/3` returns `{ok, {FwdNref, RevNref}}`; the mgr
normalises to `{ok, FwdNref}` (forward arc nref only).

**L4 — Instance-only attribute enforcement deferred** (2026-05-18)

The template attribute list (which would declare per-class, per-template whether an
attribute is class-bindable or instance-only) does not yet exist. `create_class`
and `update_node_avps` accept any AVP write without enforcement. This is a known
gap; enforcement is a follow-on task adjacent to F4/E1 (rule-driven instantiation).

**L4 — `delete_node` and `update_node_avps` remain `not_implemented`** (2026-05-18)

No worker currently implements node deletion or general AVP-update. Both operations
pass through the category guard (rejecting category nrefs 1–5) and then return
`{error, not_implemented}`. These will be wired when a worker adds the functionality.

---

### L5. Relationship row IDs allocated from the global `nref_server` — **RESOLVED** (2026-05-19)

New `rel_id_server` gen_server added to `apps/graphdb/src/` as first child of
`graphdb_sup`. All 23 `#relationship.id` allocations across 5 files migrated from
`nref_server:get_nref/0` to `rel_id_server:get_id/0`. Bootstrap test assertions
updated (nref floor now `>= 100002`; relationship IDs now start at 1). 4 CT tests added.

---

### L7. Literals subtree restructuring — **RESOLVED** (2026-05-25)

Literals subtree (nref 7) partitioned by owning subsystem so each
worker seeds its literal attributes under a dedicated sub-group:

- `Attribute Literals` — seeded by `graphdb_attr:init/1` (contains
  `literal_type`, `target_kind`, `relationship_avp`, `attribute_type`)
- `Language Literals` — seeded by `graphdb_language:init/1` (contains
  `base_language`, `project_language`)
- `Rule Literals` — seeded by `graphdb_rules:init/1` once F4 Phase A
  lands

`graphdb_attr:create_literal_attribute/3` arity added so callers can
specify a parent nref. `/2` retained as a delegating shim defaulting
to nref 7.

Clean-slate seeding; no runtime migration code.

---

### L8. Generalize `graphdb_attr` attribute placement — **RESOLVED** (2026-05-31)

Parent nref is now a first-class, validated argument on every
`graphdb_attr` creator. Canonical general creators
`create_value_attribute/4` (single node) and
`create_relationship_attribute_pair/4` (reciprocal pair) back thin named
wrappers that preserve the default parents (6/7/8). `validate_parent/1`
rejects a non-existent or non-`attribute` parent before any write.
`create_relationship_attribute` renamed to
`create_relationship_attribute_pair`. Design at
`docs/designs/l8-graphdb-attr-placement-design.md`. Removes the F4 §10.1
P1 placement blocker by construction.

---

### L9. Non-instantiable (abstract) classes — **RESOLVED** (2026-06-01)

A class may be designated non-instantiable (abstract) by an
`instantiable => false` marker AVP on the class node. `graphdb_attr`
seeds the `instantiable` boolean marker literal attribute in the
`Attribute Literals` sub-group. `graphdb_class:create_class/3` takes an
initial AVP list (`/2` delegates with `[]`); a class created with the
marker is born **without** a default template. `graphdb_class:is_instantiable/1`
reports the flag. `graphdb_instance:create_instance/3` **and**
`add_class_membership/2` refuse a non-instantiable class target with
`{error, {class_not_instantiable, ClassNref}}`. Permissive by default —
absence of the marker means instantiable. Design at
`docs/designs/l9-non-instantiable-classes-design.md`. Prerequisite for
F4 Phase A (Decision D15), which seeds the abstract `Rule` meta-class
root.

---

### Task 7. Wire `dictionary_server` and `term_server` to `dictionary_imp` — **RESOLVED** (2026-05-19)

Both gen_servers delegate to `dictionary_imp` via `start_dictionary/stop_dictionary`
in `init/terminate` and forward all CRUD calls. Also fixed a pre-existing one-line bug
in `dictionary_imp:delete/2` (wrong ETS key type). 14 CT tests added (7 per server).

---

### Task 8. Scaffold nref constants → shared `graphdb_nrefs.hrl` header — **RESOLVED** (2026-05-20)

`apps/graphdb/include/graphdb_nrefs.hrl` introduced with 36 named macros covering
scaffold nrefs 1–35 (`NREF_*`, `NAME_ATTR_*`, `ARC_*`) and the permanent English
instance nref 10000 (`NREF_ENGLISH`). All inline `-define` blocks removed from five
source files (`graphdb_attr`, `graphdb_class`, `graphdb_instance`, `graphdb_language`,
`graphdb_mgr`); all raw integers 17–35 and 10000 replaced with macros in seven test
files. Companion `graphdb_nrefs.erl` exports `scaffold_spec/0` and `verify/0`; verify
is called at the end of `graphdb_bootstrap:do_load/0` as a fatal congruency check.
`graphdb_bootstrap` module is deleted+purged from the code server in `graphdb_mgr:init/1`
after successful load. 2 CT tests in `graphdb_nrefs_SUITE`. 320 tests (217 CT +
103 EUnit), all green, zero warnings.

---

### E2. Non-normal OTP start types — **RESOLVED** (2026-05-21)

`seerstone:start/2` and `nref:start/2` now delegate `{takeover, Node}` and
`{failover, Node}` to the normal start path rather than hitting `?NYI`.
Full distributed takeover/failover semantics deferred until a distributed
deployment is planned.

---

### E3. `code_change/3` — hot code upgrades — **DEFERRED**

NYI in all gen_server modules: `nref_allocator`, `nref_server`, all six
`graphdb_*` workers. Implement when the first hot-upgrade deployment is
planned. Premature until there is a versioned release to upgrade in place.

---

### E4. `start_phases` / `start_phase/3` — **DEFERRED**

No `.app.src` file defines `start_phases`, so `start_phase/3` is never
called. Revisit when an externally-visible entry point (API server, socket
listener) is added to `seerstone` that must not accept connections until
the full graphdb stack is bootstrapped — at that point phased startup
becomes necessary to close the window between port-open and data-ready.

---

### E5. Replace `included_applications` with peer-app dependencies — **RESOLVED** (2026-05-21)

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
