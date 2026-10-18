<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Seed Cache, Attribute Placement, and Relationship Label Pairs — Design

**Status:** draft under review (2026-10-18; review round 1 answers folded
in). Supersedes the strict `target_kind` check preserved as tag
`strict-labels-snapshot-1`; that snapshot's code does **not** drive this
design or its plan.

## Goal

Make the seed ontology the authoritative, in-memory source for the decisions
the kernel makes about attributes and relationship labels:

1. **Seed cache** — every seed node is held in memory, whole, and never read
   from persistence once the system is up.
2. **Attribute placement** — runtime attributes may only be created under a
   fixed set of seed groups, with sensible defaults per attribute type.
3. **Relationship label pairs** — each relationship label states what its
   *source* may be; the target expectation is the *reciprocal* label's source
   expectation. Labels are recorded as pairs. This replaces `target_kind`.

Gates are decided from the seed attribute and its parent, held in code and in
the seed cache. The same facts are also stamped as AVPs on the nodes so the
knowledge base describes itself, but no gate reads those AVPs.

## Background

The work started as a follow-up from PR #55: backfill `target_kind` onto
bootstrap arc labels 21–30. That turned out not to fit the data — most of
those labels join nodes of more than one kind (22 also reaches project
anchors, 23/25/27 reach categories, 26 reaches default templates). A first
strict-check implementation (tag `strict-labels-snapshot-1`) rejected
labels with no `target_kind` and structural labels 21–31. Review of that
work produced the decisions below.

Seeds and persistence are declared **in flux**: no backward compatibility,
no migrations (see the note in `CLAUDE.md` and `README.md`).

## Decisions already made

| Topic                | Decision                                                                                                          |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Forbidden parents    | No runtime attribute directly under 2, 6, 7 or 8; none under 9, 10, or the system literal groups                  |
| Name default         | 12 Instance Name Attributes; 11 Class Name Attributes allowed when named explicitly                               |
| Literal default      | New seed group **Instance Literals** under 7; values may sit on classes or instances (use elsewhere not enforced) |
| Relationship default | 16 Instance Relationships; family 14 or 15 → `logger:warning` then proceed; family 13 → blocked                   |
| Label expectations   | Each label states its source; target expectation = reciprocal's source expectation; pairs must be recorded        |
| Seeds                | Cached in full; never read from persistence; seed changes belong to a governed upgrade process                    |
| Gates                | Derived from the seed attribute and its parent, in code / cache, even when also stamped as AVPs                   |
| Placement whitelist  | Accepted (review round 1): a seed group not named in the placement table is closed                                |
| `target_kind`        | Removed entirely — argument, seed attribute and check (review round 1)                                            |
| Structural guard     | Kept: labels 21–31 can never label a connection (review round 1)                                                  |

## Out of scope (tabled)

- Where relationship rows are persisted per label family (the expectation
  that nref-16 labels live only in projects). Today four writers put
  nref-16 labels in the environment: bootstrap English, `graphdb_language`
  registration, `graphdb_rules` rule instances, and `applies_to`/`applied_by`.
- Languages, including `lang_code` sitting directly under 7.
- Enforcing that Instance Literals are used only on classes and instances.
- Deciding the fate of family 14/15 relationship labels (the warnings exist
  to gather evidence for that).

## Piece A — Seed cache

### Seed set

A **seed** is every environment node whose nref is below `?NREF_START` at
the moment the boot flips to the runtime phase. That is the bootstrap
scaffold (1–35), English (10000), loader-assigned atom-labelled nodes, and
everything a worker `init/1` creates in the permanent phase: the literal
sub-groups and their attributes, `applies_to`/`applied_by`, the rule
meta-classes and their default templates, and the Remote Reference class.

Using the tier boundary rather than a hand-kept list means a new seed is
cached without anyone remembering to register it.

### Module and storage

A new module, `graphdb_seeds` (plain module, no process):

| Function         | Purpose                                                                   |
| ---------------- | ------------------------------------------------------------------------- |
| `load/0`         | Read every node below `?NREF_START`, derive per-seed facts, store, verify |
| `node/1`         | `{ok, #node{}}` for a seed (by nref or label atom), `not_seed` otherwise  |
| `nref/1`         | Label atom → nref (for example `retired`, `arc_inst_parent`)              |
| `is_seed/1`      | Boolean                                                                   |
| `anchor/1`       | Nearest seed at or above a node (walks runtime parents via Mnesia)        |
| `placement/1`    | Placement rule for an anchor seed (Piece B)                               |
| `source_kinds/1` | Allowed source kinds for a label (Piece C)                                |
| `erase/0`        | Drop the cache (tests, governed upgrades)                                 |

Storage is `persistent_term`, one key holding a map. Reads are lock-free and
make no gen_server call, so they are safe inside an Mnesia transaction —
consistent with the rule that gen_server calls never run inside one.

Seeds are addressable by **label** as well as nref. Display names cannot be
the key ("Name" is 17–20; "Parent" and "Child" repeat), so the label is an
atom: the keys `graphdb_nrefs` already defines for the bootstrap macros
(`arc_inst_parent`, …) plus the atoms the workers' seeded-nref maps use
today (`retired`, `instantiable`, `applies_to`, …). This lets
`graphdb_seeds:nref/1` replace the 13 `graphdb_attr:seeded_nrefs/0`-style
gen_server lookups — calls the project notes flag as a deadlock hazard if
one ever lands inside a transaction. Which of those to convert in Piece A
is part of open question 2.

### When it loads

`graphdb:start/2`, immediately after `graphdb_nref:set_runtime_phase/0`.
Every seed has been created and stamped by then.

From Piece C onwards, `load/0` ends with a consistency check, fatal on
failure like `graphdb_nrefs:verify/0`: the `source_kind` and
`reciprocal_attribute` AVPs stamped on seed labels must agree with the code
table. Piece A has nothing to verify yet.

### Freezing seeds

The cache is only correct if nothing writes a seed after the flip. Already
guarded: `update_node_avps`, `retire_node`/`unretire_node` (permanent-tier
guard). **Not guarded today** and to be closed with
`{error, permanent_node_immutable}`:

- `graphdb_class:add_superclass/2`, `add_qualifying_characteristic/2,3`,
  `bind_qc_value/3` on a seed class.
- `graphdb_attr:retro_stamp_attribute_types/0` called in the runtime phase.
- `graphdb_mgr:rebuild_caches/0` — skips seeds (their caches are fixed).

### Reads

The new gates (Pieces B and C) read seeds only through `graphdb_seeds`.
Existing incidental reads of seed nodes elsewhere (for example
`graphdb_attr:validate_parent/1`, `classify_attribute_node/2`, the label
read in `graphdb_instance:validate_arc_endpoints_in_txn/7`) are converted
where this work touches them. A full sweep of every remaining read is a
follow-up (see open question 2).

## Piece B — Attribute placement

### Rule

The **anchor** of a proposed parent is the nearest seed at or above it (the
parent itself if it is a seed; otherwise walk its parents through runtime
buckets). Placement is decided by the anchor and the attribute type:

| Anchor seed                 | name    | literal | relationship / relationship type |
| --------------------------- | ------- | ------- | -------------------------------- |
| 11 Class Name Attributes    | allowed | blocked | blocked                          |
| 12 Instance Name Attributes | allowed | blocked | blocked                          |
| Instance Literals (new)     | blocked | allowed | blocked                          |
| 16 Instance Relationships   | blocked | blocked | allowed                          |
| 15 Class Relationships      | blocked | blocked | allowed + warning                |
| 14 Attribute Relationships  | blocked | blocked | allowed + warning                |
| any other seed              | blocked | blocked | blocked                          |

"Any other seed" covers 2, 6, 7, 8, 9, 10, 13, the system literal groups
(Attribute, Rule, Language Literals), and every seed leaf (so nothing can be
created under `retired`, `Template`, an arc label, and so on). The table is
a whitelist: a new seed group is closed until the table names it.

The type columns (a name attribute cannot go under Instance Literals, and so
on) are a proposal — see open question 3.

Blocked: `{error, {parent_not_allowed, AttrType, ParentNref}}`. Warned:
`logger:warning` naming the label, its parent and the family, then the
attribute is created.

The rule applies **only in the runtime phase**. Worker `init/1`s create
seeds through the same public API during the permanent phase, and must not
be gated.

### Defaults

| Function                               | Default parent (was)            |
| -------------------------------------- | ------------------------------- |
| `create_name_attribute/1`              | 12 Instance Name Attributes (6) |
| `create_literal_attribute/2`           | Instance Literals (7)           |
| `create_relationship_type/1`           | 16 Instance Relationships (8)   |
| `create_relationship_attribute_pair/2` | 16 Instance Relationships (8)   |

### New seed

`graphdb_attr:init/1` seeds **Instance Literals** under 7, beside Attribute
Literals, with the same `ensure_seed` pattern.

### Family

A relationship label's **family** is the 13/14/15/16 seed its anchor sits
under (or is). Piece C uses it.

## Piece C — Relationship label pairs

### What a label carries

Two new seed literal attributes under Attribute Literals:

| Attribute              | Value              | Meaning                                            |
| ---------------------- | ------------------ | -------------------------------------------------- |
| `source_kind`          | list of node kinds | What a row labelled by this attribute may start at |
| `reciprocal_attribute` | nref               | The label that names the reverse direction         |

`source_kind` is always a list. Runtime labels get a single kind; seed labels
may need several (see the seed table below).

A label's **target expectation is its reciprocal's `source_kind`**: the
reverse row starts where the forward row ends. That is why pairs must be
recorded.

### Runtime labels

`create_relationship_attribute_pair(Name, ReciprocalName [, ParentNref])`
drops its `TargetKind` argument. Both labels share one parent, so both get
the family's kind:

| Family | `source_kind` stamped |
| ------ | --------------------- |
| 16     | `[instance]`          |
| 15     | `[class]`             |
| 14     | `[attribute]`         |

Each label is stamped with the other as `reciprocal_attribute`. A runtime
pair is therefore always same-kind at both ends — instance↔instance for
family 16. A relation that crosses kinds or stores needs a new seed pair,
as agreed.

`create_relationship_type/1,2` makes an unpaired grouping node. It carries
no `source_kind` and cannot label a connection.

### Seed labels

Seed labels get their facts from a code table, stamped onto the seed nodes
at `init/1` and verified by `graphdb_seeds:load/0`:

| Pair (label → reciprocal)   | `source_kind` of first  | `source_kind` of second |
| --------------------------- | ----------------------- | ----------------------- |
| 22 Child → 21 Parent        | `[category]`            | `[category, instance]`  |
| 24 Child → 23 Parent        | `[attribute, category]` | `[attribute]`           |
| 26 Child → 25 Parent        | `[class, category]`     | `[class, template]`     |
| 28 Child → 27 Parent        | `[instance, category]`  | `[instance]`            |
| 30 Instance → 29 Class      | `[class]`               | `[instance]`            |
| `applies_to` → `applied_by` | `[class]`               | `[instance]`            |

Template (31) is an AVP key, not an arc label; it gets neither.

`applies_to`/`applied_by` are created by `graphdb_rules:init/1` through the
ordinary pair API, which would stamp the family default (`[instance]`). To
keep the seed table authoritative, pair creation **in the permanent phase**
takes the stamp from the seed table when the label is listed there, and
falls back to the family default otherwise. The bootstrap pairs 21–30 are
stamped by `graphdb_attr:init/1`, the same way `attribute_type` is stamped
today.

### The connection gate

In `validate_arc_endpoints_in_txn/7` (shared by `add_relationship` and
`mutate/1,2`), after the existing existence, retired and kind checks:

1. **Structural guard** (kept from the snapshot): neither label may be 21–31
   — `{structural_arc_label, N}`. Still needed: 28/27 would otherwise pass
   the pair and kind checks below.
2. **Pairing**: the characterization must be paired, and the reciprocal must
   be its partner — `{characterization_not_paired, C}` /
   `{reciprocal_mismatch, C, R}`.
3. **Source**: the source node's kind must be in the characterization's
   allowed kinds — `{source_kind_mismatch, Expected, Actual}`.
4. **Target**: the target node's kind must be in the reciprocal's allowed
   kinds — `{target_kind_mismatch, Expected, Actual}` (same shape as today).

Allowed kinds come from `graphdb_seeds:source_kinds/1`: the code table for
seed labels, the family for runtime labels. The stamped AVPs are not read.

### Rules

`graphdb_rules:create_connection_rule/8,9` applies checks 1 and 2, and
requires `[instance]` at both ends (rules connect instances of the source
and target classes). This closes the gap where rule-fired connections skip
the gate.

### Retiring `target_kind`

The `target_kind` seed attribute, the argument, the old
`check_target_kind/3` arm, and `graphdb_mgr`'s `missing_avps` check for it
are removed. `graphdb_ns:target_namespace/2` takes a kind as an argument and
reads no AVP; it is unaffected.

## Test harness

Most test cases run entirely in the permanent phase. Only 4 of the 12 CT
suites call `set_runtime_phase/0` at all, and even those do not do it for
every case (a class created in `graphdb_instance_SUITE` came back as 10031,
a permanent-tier nref). Nodes those tests create would be treated as seeds.
Every suite's per-case setup must mirror `graphdb:start/2`: start the
workers, flip to the runtime phase, call `graphdb_seeds:load/0`; teardown
calls `erase/0`. This is the largest single source of test churn; expect
fallout in tests that assumed permanent-tier nrefs or relied on
permanent-phase allocation.

Other known test impact:

- About 104 call sites rely on attribute defaults; most follow the new
  defaults, those naming 6/7/8 explicitly need a new parent.
- Every `create_relationship_attribute_pair` caller loses its `TargetKind`
  argument.
- `graphdb_query_SUITE` T1/T2/M3 build paths through nref 6 and shadow it
  with ≥6 project instances. With names defaulting to 12 they need ≥12.
- The snapshot's strict-label tests are rewritten for the new error terms.

## Documentation

`docs/Architecture.md` (seed cache, placement, label pairs; replaces the
`target_kind` paragraph), `CLAUDE.md` and `apps/graphdb/CLAUDE.md`,
`docs/diagrams/ontology-tree.md` (Instance Literals, `source_kind`,
`reciprocal_attribute`; `target_kind` removed), and `TASKS.md`.

## Delivery

Three PRs, in order — A, B, C — each through the usual post-merge reset.
The snapshot's code has been set aside (it is preserved in tag
`strict-labels-snapshot-1`); the review branch carries only the
"in flux" notes, the `TASKS.md` pointer and this spec. Piece C writes the
structural guard afresh as part of the new gate.

## Open questions for review

1. **Seed boundary.** Is "every node below `?NREF_START` at the flip" right?
   It includes the rule meta-classes, their default templates, the Remote
   Reference class, `lang_human` and English.
2. **Read sweep.** Convert only the reads this work touches (proposed), or
   sweep every read of a seed node from persistence in Piece A? The same
   question applies to replacing the `seeded_nrefs/0` gen_server lookups
   with `graphdb_seeds:nref/1`.
3. **Type ↔ group.** The whitelist is accepted. Confirm the type columns
   within it too (names only under 11/12, literals only under Instance
   Literals, relationships only under 14–16)?
4. ~~**`target_kind`.**~~ **Resolved:** removed entirely.
5. **Target expectation.** A label's target expectation is its
   reciprocal's `source_kind` — my reading of "if we are not specifying the
   other attribute of the characterization, then we cannot provide the
   target expectations". Is that what you meant?
6. **AVP names and shape.** `source_kind` as a list, and
   `reciprocal_attribute` — acceptable names?
7. **Freezing seed classes.** Guarding them means no QCs, superclasses or
   bound values can be added at runtime to the Remote Reference class, the
   rule meta-classes or `lang_human`. Nothing in `src` or `test` does this
   today, so the guard breaks no existing behaviour. Is it intended?
8. ~~**Branch handling.**~~ **Resolved:** snapshot code set aside; it does
   not drive the design or the plan.
