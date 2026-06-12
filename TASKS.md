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

### Conflict precedence

When a class and its taxonomy ancestors each attach a rule that touches
the same component type or connection, the effective-rules gather
currently returns them additively, nearest-first, and resolves nothing.
Decide and implement horizontal conflict resolution: when two rules at
different levels genuinely conflict, which wins — does a nearer rule
shadow a farther one, or do they compose — and what the precedence order
is. This is the last outstanding piece of the firing engine's core; the
division is sketched in `docs/designs/f4-graphdb-rules-design.md` §11.

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
gaps that remain are node mutation, the template attribute list, and
wiring the multilingual write path.

### Node deletion and attribute-value-pair update

`graphdb_mgr:delete_node/1` and `update_node_avps/2` still return
`{error, not_implemented}`: no worker implements node deletion or general
AVP update. Both already pass through the category guard (rejecting the
scaffold category nodes) before returning. Wire them to a worker once one
provides the underlying functionality.

### Template attribute list and instance-only enforcement

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

### Multilingual write-path integration

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
