<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# L8 — Generalize `graphdb_attr` Attribute Placement

**Status:** Design — approved, pre-implementation
**Date:** 2026-05-31
**Track:** Engineering Hygiene (standalone; lands before F4 Phase A resumes)

---

## 1. Motivation

Every `graphdb_attr` creator except `create_literal_attribute/3` hardcodes
the parent nref of the attribute node it creates. Name attributes always
land flat under `Names` (nref 6); relationship attributes and
relationship-type groupings always land flat under `Relationships`
(nref 8). The scaffold sub-buckets that exist precisely to organise these
nodes — `Category/Attribute/Class/Instance Name Attributes` (9–12) and the
matching `Relationships` sub-buckets (13–16) — are never populated by any
runtime create. Nothing can file an attribute where it taxonomically
belongs.

F4 Phase A is the first concrete case to expose the gap: it wants the
`applies_to` / `applied_by` arc-label pair filed under `Instance
Relationships` (nref 16), but the only API parks them flat under nref 8.
That mismatch is the pinned question **F4 §10.1 P1**. Rather than answer
P1 narrowly (pick one of three exits), this task removes the underlying
limitation: **parent nref becomes a first-class argument on every
attribute creator.** P1 then dissolves by construction.

This is a focused API generalisation with no schema change and no change
to the structure of what gets written — only *where*.

---

## 2. Current state

Two structural shapes exist under the hood, and they already funnel
through two internal helpers:

| Shape               | Internal helper                          | Writes                  |
|---------------------|------------------------------------------|-------------------------|
| Single node         | `do_create_attribute/3`                   | 1 node + 1 arc pair     |
| Reciprocal pair     | `do_create_relationship_attribute_pair/3` | 2 nodes + 2 arc pairs   |

The public creators differ only in their extra AVPs and their hardcoded
parent:

| Function                              | Parent today              | attribute_type | Extra AVP        |
|---------------------------------------|---------------------------|----------------|------------------|
| `create_name_attribute/1`             | `?NREF_NAMES` (6)          | `name`         | —                |
| `create_literal_attribute/2`          | `?NREF_LITERALS` (7)       | `literal`      | `literal_type`   |
| `create_literal_attribute/3`          | caller-supplied            | `literal`      | `literal_type`   |
| `create_relationship_attribute/3`     | `?NREF_RELATIONSHIPS` (8)  | `relationship` | `target_kind`    |
| `create_relationship_type/1`          | `?NREF_RELATIONSHIPS` (8)  | `relationship` | —                |

The seeded attribute nrefs (`literal_type`, `target_kind`,
`attribute_type`) live in the gen_server `#state{}` and must stay
encapsulated — callers must never have to know them.

---

## 3. Public API after the change

Two **canonical general creators** take a required `ParentNref`; the
existing named functions become thin wrappers that preserve today's
default parents and behaviour.

```erlang
%% ── Canonical general creators ──────────────────────────────────
create_value_attribute(Name, AttrType, TypeArgs, ParentNref)
    -> {ok, Nref} | {error, term()}.
    %% AttrType :: name | literal | relationship   (single-node shapes)
    %% TypeArgs :: []            for name | relationship
    %%           | [LiteralType] for literal   (e.g. [string])

create_relationship_attribute_pair(Name, RecipName, TargetKind, ParentNref)
    -> {ok, {FwdNref, RevNref}} | {error, term()}.   %% reciprocal pair

%% ── Thin wrappers — behaviour unchanged, defaults preserved ─────
create_name_attribute(Name)              %% -> create_value_attribute(Name, name, [], ?NREF_NAMES)
create_name_attribute(Name, Parent)      %% NEW /2
create_literal_attribute(Name, Type)     %% -> create_value_attribute(Name, literal, [Type], ?NREF_LITERALS)
create_literal_attribute(Name, Type, P)  %% -> create_value_attribute(Name, literal, [Type], P)
create_relationship_type(Name)           %% -> create_value_attribute(Name, relationship, [], ?NREF_RELATIONSHIPS)
create_relationship_type(Name, Parent)   %% NEW /2
create_relationship_attribute_pair(N,R,TK) %% -> create_relationship_attribute_pair(N,R,TK, ?NREF_RELATIONSHIPS)
```

The single-node `relationship` `AttrType` covers the grouping/bucket case
(`create_relationship_type`). The reciprocal *pair* is the only shape
served by `create_relationship_attribute_pair`.

### 3.1 `TypeArgs` contract

`TypeArgs` is interpreted per `AttrType`; it is **not** a list of raw AVP
maps (which would leak seeded nrefs):

| `AttrType`     | Valid `TypeArgs` | Server stamps                                   |
|----------------|------------------|-------------------------------------------------|
| `name`         | `[]`             | `attribute_type => name`                         |
| `relationship` | `[]`             | `attribute_type => relationship`                 |
| `literal`      | `[LiteralType]`  | `attribute_type => literal` + `literal_type => LiteralType` |

A non-empty `TypeArgs` for `name`/`relationship`, or a malformed
`TypeArgs` for `literal`, is rejected with
`{error, {bad_type_args, AttrType, TypeArgs}}`. An unrecognised
`AttrType` is rejected with `{error, {bad_attribute_type, AttrType}}`.

---

## 4. The rename

`create_relationship_attribute` → `create_relationship_attribute_pair`.

The function creates a reciprocal *pair* of arc-label nodes; the name now
says so, and it harmonises with the long-standing internal helper
`do_create_relationship_attribute_pair`. Both the /3 wrapper and the new
/4 general creator carry the `_pair` name.

**Migration scope** (all updated in this task):

| Location                              | Change                                          |
|---------------------------------------|-------------------------------------------------|
| `graphdb_attr.erl`                    | export, doc comment, public clause, gen_server message tag |
| `graphdb_mgr.erl` (~line 601)         | the one production delegating caller            |
| `graphdb_attr_SUITE.erl`              | 5 call sites                                     |
| `graphdb_instance_SUITE.erl`          | ~20 call sites                                   |
| `graphdb_query_SUITE.erl`             | 1 call site                                       |
| `graphdb_mgr_SUITE.erl`               | 1 call site                                       |

Existing CT *case names* (e.g. `create_relationship_attribute_delegates`,
`create_relationship_attribute_pair`) describe behaviour, not the API
symbol, and are left as-is. Only the calls inside them change.

No deprecated alias is kept — this is a clean rename, consistent with the
project's clean-slate posture (no runtime callers exist outside the
repo).

---

## 5. Internals

No change to the *structure* of what is written. The two internal helpers
are reused; one gains a parameter:

- `do_create_attribute/3` — unchanged (already takes `ParentNref`).
- `do_create_relationship_attribute_pair/3` →
  `do_create_relationship_attribute_pair/4` — add a `ParentNref`
  parameter, replacing the six hardcoded `?NREF_RELATIONSHIPS` literals
  in the node `parents` fields and the four arc `source_nref` /
  `target_nref` fields.

The three separate `handle_call` clauses
(`create_name_attribute` / `create_literal_attribute` /
`create_relationship_type`) collapse into a single
`{create_value_attribute, Name, AttrType, TypeArgs, ParentNref}` clause
that:

1. validates the parent (§6),
2. validates `AttrType` / `TypeArgs` (§3.1),
3. builds `Extra = [attribute_type AVP | type-specific AVPs]` from
   `#state{}`,
4. delegates to `do_create_attribute(Name, ParentNref, Extra)`.

The reciprocal pair keeps its own clause, now
`{create_relationship_attribute_pair, Name, Recip, TargetKind,
ParentNref}`, delegating to
`do_create_relationship_attribute_pair/4`.

The public wrapper functions are client-side: they call
`gen_server:call/2` with the general message, supplying the default
parent. This removes the duplicated per-type message handling.

---

## 6. Parent validation

A shared `validate_parent/1`, run inside the gen_server before any write,
on **both** general creators:

```erlang
case mnesia:dirty_read(nodes, ParentNref) of
    [#node{kind = attribute}] -> ok;
    [#node{kind = K}]         -> {error, {parent_not_attribute, K}};
    []                        -> {error, {parent_not_found, ParentNref}}
end
```

On error nothing is written (the validation precedes the transaction
entirely; no nref or rel-id is consumed). Scope membership (must descend
from 6/7/8) is deliberately **not** enforced — any attribute-kind parent
is allowed, keeping the creator decoupled from the scaffold's exact
shape.

**Seeding / ordering invariant.** `validate_parent/1` reads with
`dirty_read`, so a parent must be committed before its children are
created. This already holds: `graphdb_attr:init/1` and
`graphdb_language:init/1` create each sub-group, commit it (the
`do_create_attribute` transaction returns only after commit), then file
children under it. The bootstrap scaffold (nrefs 1–35) is written by
`graphdb_mgr`'s bootstrap load, which runs before `graphdb_attr:init/1`
in supervisor order — so parents 6/7/8 and the sub-buckets 9–16 all exist
by the time any worker seeds. The default-parent wrappers therefore never
newly fail.

---

## 7. Testing

New / updated CT cases in `graphdb_attr_SUITE`:

- **Arbitrary placement, single node** — `create_value_attribute` files a
  name attribute under nref 9; assert `parents = [9]` and a taxonomy arc
  pair sourced at 9.
- **Arbitrary placement, pair** — `create_relationship_attribute_pair/4`
  files the pair under nref 16; assert both nodes `parents = [16]` and all
  four arcs reference 16.
- **Grouping placement** — `create_relationship_type/2` files a grouping
  node under an arbitrary attribute parent.
- **Validation: missing parent** — nonexistent nref →
  `{error, {parent_not_found, _}}`, **zero** row delta (nodes and
  relationships counts unchanged).
- **Validation: non-attribute parent** — pass a category nref (1–5) or a
  class/instance nref → `{error, {parent_not_attribute, _}}`, zero delta.
- **Type-args validation** — `create_value_attribute(Name, name, [junk],
  P)` → `{error, {bad_type_args, _, _}}`.
- **Back-compat** — the five existing wrappers still default to 6/7/8;
  assert the parent explicitly for each.

All existing `graphdb_attr_SUITE`, `graphdb_instance_SUITE`,
`graphdb_query_SUITE`, and `graphdb_mgr_SUITE` cases stay green after the
rename and wrapper refactor (behaviour for default parents is unchanged).

EUnit: no new pure-function coverage required — the logic is gen_server /
Mnesia integration.

---

## 8. Documentation updates

- `apps/graphdb/CLAUDE.md` — refresh the `graphdb_attr` API list: new
  general creators, the `_pair` rename, and the new `/2` wrapper arities.
- `ARCHITECTURE.md` — `graphdb_attr` worker public-API contract change.
- `TASKS.md` — add the **L8** entry under Engineering Hygiene; mark
  RESOLVED on landing.
- `docs/designs/f4-graphdb-rules-design.md` §10.1 P1 — record that the
  placement blocker is removed by construction:
  `create_relationship_attribute_pair/4` can file `applies_to` /
  `applied_by` under nref 16 (or a Rule sub-bucket). The *choice* of exact
  parent remains a Phase-A seeding decision; the "would require an API
  extension" tension is gone.

`docs/diagrams/ontology-tree.md` is **not** touched — this task adds no
new seeded environment nodes; it only changes the API by which future
nodes can be placed.

---

## 9. F4 §10.1 P1 — resolution path

P1's three exits were: (1) accept nref 8, (2) add a kind-specific-parent
variant, (3) modify the API. L8 makes exit (2)/(3) the general, principled
default for *all* attribute creation rather than a one-off. Once L8 lands,
F4 Phase A seeds the pair with:

```erlang
create_relationship_attribute_pair("applies_to", "applied_by",
                                   instance, ?NREF_INST_REL_ATTRS).
```

and the §3.1 row-8 / CT-assertion mismatch is settled at the source. The
broader seeding-shape review noted alongside P1 (the `create_class/2`
default-template auto-creation) is **out of scope** for L8 and remains an
F4 Phase A concern.

---

## 10. Out of scope / non-goals

- No Mnesia schema change; no change to node/arc record shapes.
- No subtree-membership enforcement (validation stops at `kind=attribute`).
- No change to `graphdb_mgr:create_attribute/3` routing logic beyond the
  rename of the function it delegates to.
- No new seeded environment nodes (no ontology-tree diagram change).
- The `create_class/2` default-template seeding question stays with F4.

---

## 11. Decision log

| ID  | Decision                                                                                      |
|-----|-----------------------------------------------------------------------------------------------|
| D1  | Canonical general creators + named functions as thin wrappers (one code path, full back-compat). |
| D2  | `ParentNref` validation = exists + `kind=attribute`; no subtree-membership check.              |
| D3  | Rename `create_relationship_attribute` → `create_relationship_attribute_pair` (no alias kept). |
| D4  | `TypeArgs` is a typed argument list interpreted per `AttrType`, not raw AVP maps (encapsulation). |
| D5  | Standalone Engineering-Hygiene task (L8), lands before F4 Phase A resumes.                      |
| D6  | F4 §10.1 P1 resolved by construction; the `create_class/2` seeding review stays with F4.        |
