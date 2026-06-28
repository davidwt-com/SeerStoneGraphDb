<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Slice C — Instance-Only Qualifying Characteristics — Design

## Goal

Let a class declare a qualifying characteristic (QC) as **instance-only**:
the attribute is relevant to the class, but binding a value *at the class
level* is a category error. Binding belongs only on instances. Slice C adds
the marker and enforces the rejection at every class-level value-binding
gate.

*Example:* a `Car` class declares `serial_number` as relevant to every car,
but a class-wide serial number is nonsense — each instance carries its own.
`serial_number` is instance-only; `num_wheels = 4` is class-bindable.

## Background

QCs are stored as AVPs directly on the class node, keyed by attribute nref:

| QC state               | AVP shape                              | Meaning                                  |
|------------------------|----------------------------------------|------------------------------------------|
| Declared, unbound      | `#{attribute => A, value => undefined}` | instances supply the value               |
| Declared, class-bound  | `#{attribute => A, value => V}`         | shared default; instances may override   |

`add_qualifying_characteristic/2` declares (unbound); `bind_qc_value/3`
binds a value; `create_class/3` accepts an initial AVP list that lands on
the class node.

The inheritance chain (`TheKnowledgeNetwork.md` §6, `Architecture.md` §9)
has exactly four levels — local, class-bound, compositional ancestor,
connected. There is **no template layer**: a template is consumed at
instantiation, not queried at resolve time. This design does not change the
inheritance chain.

## Scope

**In scope** — the instance-only marker on class QCs, and rejection of a
class-level value bind on a marked attribute at three gates.

**Deferred** (recorded in `TASKS.md`, see below) — the per-template
attribute list (`TheKnowledgeNetwork.md` §7), template-bound variant values,
instance-side stamping at `create_instance`, and inherited instance-only
enforcement.

## Decision: the flag lives on the class-level QC

The instance-only/class-bindable distinction is a **binding policy on a
single attribute**, stored where the attribute is declared — the class node.
This is a design choice, not a spec mandate; the spec settles the
inheritance chain and template relevance-scoping but not this locus. Two
practical constraints decide it:

- Every enforcement point (`create_class`, `update_node_avps`,
  `bind_qc_value`) operates on the **class node**. A class-QC marker keeps
  enforcement local; a per-template home would force a cross-node template
  lookup on every class-AVP write.
- The per-template attribute list (the alternative home) is exactly the
  deferred template infrastructure. Building it now to host one flag is
  YAGNI against keeping the slice focused.

## Representation

An instance-only QC is the declared-unbound QC plus one boolean key,
colocated on the class node:

```erlang
#{attribute => A, value => undefined, instance_only => true}
```

This mirrors the codebase's marker convention (`instantiable => false`,
`retired => true`) but at *attribute* granularity — the flag must ride on a
specific QC, so it is a key on that QC's map rather than a standalone
node-level AVP.

Erlang map-matching is non-exhaustive, so existing
`#{attribute := A, value := V}` reads keep working unchanged. The only
code that drops the key is code that *rebuilds* a map from extracted
fields — notably `collect_qc_avps/1`, which flattens each QC to a
`{AttrNref, Value}` tuple. That flattening is why inherited enforcement is
deferred (see below).

## Setting the flag

| API                                          | Behaviour                                                        |
|----------------------------------------------|-----------------------------------------------------------------|
| `add_qualifying_characteristic/3`            | `(ClassNref, AttrNref, #{instance_only => true})` — declares an instance-only QC; the existing `/2` stays the unflagged declare |
| `create_class/3`                             | accepts an instance-only QC in its initial AVP list             |

The flag is **never** set through `update_node_avps`. Slice B's
well-formedness (each update map's key-set is exactly `[attribute]` or
`[attribute, value]`) is untouched; `update_node_avps` only enforces.

## Enforcement

Three gates, each reading the **target class node's own AVPs** — all local,
no cross-node lookup. The bare-reason error is consistent with the slice-B
contract:

```erlang
{instance_only_attribute, AttrNref}
```

| Gate                  | Rejects when…                                                                                   |
|-----------------------|-------------------------------------------------------------------------------------------------|
| `bind_qc_value/3`     | the target QC is marked `instance_only` — the direct class-level bind path                       |
| `create_class/3`      | an initial AVP is both `instance_only => true` **and** carries a concrete `value =/= undefined`  |
| `update_node_avps/2`  | a class node, value-bearing update (`value` key present) targets an attr whose stored entry is `instance_only` |

`bind_qc_value/3` is included although the task named only `create_class`
and `update_node_avps`: it is the direct class-level value-binding API, so
leaving it unguarded is a trivial bypass.

`update_node_avps/2` rejects *any* value-bearing update to a marked
attribute — even `value => undefined` — because slice B's upsert replaces
the whole entry and would silently strip the flag. Deletes (no `value` key)
are left alone; removing the QC entirely is not a binding.

Enforcement applies to class nodes only. Instances are the legal binding
locus; instance nodes never carry the flag, so `update_node_avps` on an
instance never triggers the guard.

## Inheritance: local enforcement (C1)

Each gate checks only the class node it is writing. The flag does **not**
propagate through `inherited_qcs/1` (because `collect_qc_avps/1` drops it),
which leaves one known gap: a subclass can re-declare a parent's
instance-only QC *without* the flag via `add_qualifying_characteristic/2`,
then bind a value — bypassing the parent's intent.

This bypass is **deferred**, not fixed in slice C. Closing it (C2) would
require changing the return shape of `collect_qc_avps/1` / `inherited_qcs/1`
to carry the flag and having all three gates consult the effective (local +
ancestor) QC set — a public-API change with its own consumers and tests,
out of proportion to one flag. The bypass requires a deliberate
re-declaration rather than being an accidental hole.

## Deferred work to record in `TASKS.md` before the PR

1. **Template attribute list** — per-template subset/relevance scoping of
   class attributes (`TheKnowledgeNetwork.md` §7).
2. **Template-bound (variant) values** — templates carrying override values
   stamped into instances at instantiation (the custom-color-phone case).
3. **Inherited instance-only enforcement** — close the subclass-redeclare
   bypass (C2 above).

## Testing

**EUnit (pure):**

- `is_instance_only/1` predicate over a QC map.
- `create_class` initial-AVP validator: instance-only + concrete value →
  reject; instance-only + `undefined` → accept; non-flagged + value →
  accept.
- `update_node_avps` instance-only guard predicate: value-bearing update
  against a marked stored entry → reject; delete against a marked entry →
  accept; value update against a non-marked entry → accept.

**CT (integration):**

- `bind_qc_value` reject path on a marked QC; happy path on a non-marked QC.
- `create_class` reject path (instance-only + value); happy path declaring
  an instance-only QC unbound.
- `update_node_avps` reject path (value-bearing update to a marked QC on a
  class node); happy path (delete of a marked QC; value update to a
  non-marked QC).
- An instance-only QC left `undefined` participates normally where reads
  tolerate unbound QCs.
- `verify_caches/0` in `end_per_testcase`, as every suite already does.
