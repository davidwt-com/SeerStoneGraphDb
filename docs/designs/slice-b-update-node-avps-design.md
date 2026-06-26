# Slice B — `update_node_avps/2` Design

## 1. Goal

Implement `graphdb_mgr:update_node_avps/2`, which today returns
`{error, not_implemented}`. It is the last `not_implemented` stub of its
pair in `graphdb_mgr` (the sibling `delete_node` is slice A's concern) and
unblocks the AVP-edit halves of slice C (template attribute list) and
slice E (relationship-AVP edit).

The operation merges a list of attribute-value-pair updates into a node's
`attribute_value_pairs` list, atomically, through the existing three-tier
write-path transaction seam.

## 2. Scope

In scope:

- Tier-1 in-txn primitive, tier-2 public wrapper, and a `mutate/1` grammar
  entry (a fourth batch mutation kind).
- Merge/upsert semantics with a delete signal that invents no new symbol.
- Existence, category, well-formedness, permanent-tier, attribute-existence,
  and retired-marker guards.

Out of scope (deferred, with reasons):

- **Value type-checking** — validating each value against the attribute
  node's declared `literal_type`. Substantial; belongs with the attribute
  library's type system as its own slice.
- **Per-template instance-only enforcement** — slice C owns this. The same
  `value => undefined` shape this design preserves is what slice C uses for
  a declared-but-unbound qualifying characteristic.

## 3. AVP update semantics

The node record's `attribute_value_pairs` is a list of
`#{attribute => Nref, value => Term}`. `update_node_avps(Nref, AVPs)` folds
each element of `AVPs` over the existing list:

| Input map                                | Meaning                                                            |
|------------------------------------------|--------------------------------------------------------------------|
| `#{attribute => A, value => V}`          | Upsert: replace `A` **in place** if present, else append `{A, V}` |
| `#{attribute => A, value => undefined}`  | Upsert as **declared-but-unbound** (a real, retained entry)       |
| `#{attribute => A}` (no `value` key)     | **Delete** `A` if present; no-op if absent                        |

Key decisions:

- **The delete signal is the *absence* of the `value` key**, not a magic
  value inside it. `undefined` keeps its slice-C meaning (a real, settable
  value). The value-less map shape is currently produced nowhere in the
  system, so repurposing it as the delete instruction collides with nothing.
- **`value => undefined` is never a delete** — it upserts a declared-but-
  unbound entry that stays in the list.
- **Last-write-wins within one call** — the fold is left-to-right, so a
  later update for the same attribute supersedes an earlier one; the result
  is deterministic regardless of duplicate attributes in the input.
- **Order-preserving upsert** — when the attribute already exists, the new
  value replaces it **in its current slot**; only a genuinely-new attribute
  appends to the tail. This honors the codebase's name-AVP-at-head
  convention (every node creator builds `[NameAVP | Rest]`): re-binding the
  name attribute keeps it at the head rather than moving it to the tail.
  Reads are position-independent (`find_avp_value/2` scans by attribute
  nref), so this is a robustness/least-surprise choice, not a correctness
  requirement — but it costs almost nothing and removes a latent
  convention violation.

This is expressed as a pure helper:

```erlang
%% apply_avp_updates(ExistingAVPs, UpdateAVPs) -> NewAVPs
%% Pure. Folds each update over the AVP list, left-to-right:
%%   - update map WITH a `value` key  -> upsert: replace the matching entry
%%     in place if present, else append the new entry to the tail
%%   - update map WITHOUT a `value` key -> delete that attribute (no-op if
%%     absent)
apply_avp_updates(Existing, Updates) ->
    lists:foldl(fun apply_one_avp_update/2, Existing, Updates).
```

## 4. Layering (three-tier seam)

`update_node_avps` lives in **`graphdb_mgr`**, beside the `set_retired` /
`set_retired_` pair it most resembles (shares the AVP-list helper style and
the `ensure_retired_nref/1` cache). A separate worker is rejected: the
stub's old "no worker implements this" comment predates the retire path,
which already established `graphdb_mgr` as the home for generic node-AVP
mutation.

| Tier | Function                               | Role                                                                                              |
|------|----------------------------------------|---------------------------------------------------------------------------------------------------|
| 1    | `update_node_avps_in_txn/3`            | Bare-mnesia, runs inside a caller's txn, `mnesia:abort/1` on failure, never opens its own txn, exported |
| 2    | `update_node_avps/2` (`handle_call`)   | Owns one `graphdb_mgr:transaction/1`; runs gen_server-dependent + pure guards outside the txn     |
| 3    | `mutate/1`                             | Gains a `{update_node_avps, Nref, AVPs}` grammar entry composing the tier-1 primitive             |

Tier-1 signature:

```erlang
%% update_node_avps_in_txn(Nref, AVPs, RetAttr) -> ok
%% Tier-1 primitive. Must run inside an active mnesia transaction. Reads the
%% node under a write lock, validates attribute existence (upserts) and the
%% retired-marker guard, applies the merge, writes the node back. Aborts with
%% a bare reason on any failure. RetAttr is the seeded `retired` nref,
%% resolved by the caller OUTSIDE the transaction.
update_node_avps_in_txn(Nref, AVPs, RetAttr) -> ...
```

`RetAttr` is a parameter (not resolved inside) for the same reason
`add_relationship_in_txn/9` takes `TkAttr`/`RetAttr`: the resolving call,
`graphdb_attr:seeded_nrefs/0`, is a gen_server call and must never run
inside an Mnesia activity (the load-bearing invariant).

## 5. Guard placement

Where each guard runs is dictated by the load-bearing invariant: no
gen_server call inside a transaction.

**Pre-txn, in the tier-2 caller process:**

- **Well-formedness** — pure scan: every element is a map whose key set is
  exactly `{attribute}` (delete) or `{attribute, value}` (upsert), with an
  integer `attribute`; any other key set (extra keys, missing `attribute`,
  non-integer `attribute`) fails fast with `{error, {invalid_avp, Bad}}`.
  Upsert-vs-delete is decided by `is_map_key(value, M)`, not by pattern
  matching `#{attribute := A}` (which also matches an upsert map).
  Client-side-style (like `validate_direction`); unit-testable without
  Mnesia.
- **Permanent-tier guard** — pure arithmetic `Nref < ?NREF_START` →
  `{error, permanent_node_immutable}` (consistent with `set_retired`).
- **Retired-nref resolution** — lazily fetch + cache the seeded `retired`
  nref via the existing `ensure_retired_nref/1`. This is the gen_server
  call that must stay outside the txn.

**In-txn, inside the tier-1 primitive:**

- **Node existence** — `mnesia:read(nodes, Nref, write)`; `[]` →
  `mnesia:abort(not_found)`.
- **Attribute-nref existence (upserts only)** — for each upsert attribute
  `A`, transactional `mnesia:read(nodes, A, read)`; absent or
  `kind =/= attribute` → `mnesia:abort({unknown_attribute, A})`.
  Transactional (not dirty) read so it shares the txn's snapshot. Deletes
  skip this guard — removing a reference to an attribute should not require
  that attribute to still exist, and is a no-op if absent.
- **Retired-marker protection** — any update map (upsert *or* delete) whose
  attribute equals `RetAttr` → `mnesia:abort(use_retire_api)`. Keeps the
  retired state behind exactly one door (`retire_node` / `unretire_node`).

The **category guard** stays where it already is — wired in `handle_call`
ahead of the tier-2 body (`check_category_guard/1`).

## 6. Return contract & atomicity

Mirrors `set_retired` and the `mutate/1` opaque bare-reason convention.

- **Tier-2** `update_node_avps/2` → `ok | {error, Reason}`.
  `transaction/1` maps `{atomic, ok} -> ok` and
  `{aborted, Reason} -> {error, Reason}`. Pre-txn guard failures
  short-circuit to `{error, Reason}` without opening a txn.
- **Tier-1** → `ok`, or `mnesia:abort(Reason)` with a **bare** reason:
  `not_found`, `{unknown_attribute, A}`, `use_retire_api`.
- **Atomicity** — the whole update is one transaction: all AVPs in the call
  apply, or none. A mid-list abort rolls back every change. No partial
  application; no per-AVP indexed error reporting (consistent with the
  `mutate/1` decision that rejected indexed errors on principle).

## 7. `mutate/1` integration

- New grammar entry `{update_node_avps, Nref, AVPs}`, dispatched in the
  batch apply-loop to `update_node_avps_in_txn(Nref, AVPs, RetAttr)`.
- The **permanent-tier** and **well-formedness** checks join `mutate/1`'s
  existing pre-validation pass over the mutation list, so a malformed or
  permanent-tier `update_node_avps` mutation rejects the whole batch
  *before* any write — no partial transaction.
- **Attribute-existence** and **retired-marker** guards ride inside the
  batch txn via the shared tier-1 primitive — no special-casing.
- `RetAttr` is resolved once, up-front (it already is, for the
  `retire_node` / `unretire_node` kinds), and threaded to every
  `update_node_avps` mutation in the batch.
- An abort from an `update_node_avps` mutation rolls back the **entire
  batch**, surfacing the same bare reason — unchanged from the existing
  batch contract.

## 8. Testing

**EUnit (pure, no Mnesia) — `graphdb_mgr_tests`:**

- `apply_avp_updates/2`: upsert-new, upsert-overwrite, delete-present,
  delete-absent (no-op), `value => undefined` retained (not deleted),
  last-write-wins on duplicate attribute, empty update list = identity.
- Ordering: upsert-overwrite preserves the existing entry's position (a
  head name AVP stays at head when re-bound); upsert-new appends after all
  existing entries.
- Well-formedness validator: accepts valid upsert/delete maps; rejects
  non-map elements, missing/non-integer `attribute`, and maps with extra
  keys beyond `{attribute, value}`.

**CT (full stack) — `graphdb_mgr_SUITE`:**

- Round-trip: create instance → `update_node_avps` upsert → `get_node`
  reflects it.
- Delete via value-less map; delete-absent no-op.
- Each guard: category node → `category_nodes_are_immutable`;
  permanent-tier nref → `permanent_node_immutable`; unknown attribute →
  `{unknown_attribute, _}`; `retired` attribute → `use_retire_api`.
- Atomicity: a batch where the 2nd AVP has an unknown attribute leaves the
  node's AVPs unchanged.
- `mutate/1`: batch mixing `add_relationship` + `update_node_avps` commits
  together; one bad `update_node_avps` rolls back the whole batch
  (including the relationship).
