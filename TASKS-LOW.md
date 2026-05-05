# SeerStoneGraphDb — Low-Severity Tasks

Correctness, contract, naming, and OTP-plumbing items. None of these
block the spec; each one improves clarity, performance, or future-
maintenance posture.

---

## L1. Rename `inherited_attributes/1` → `inherited_qcs/1`

**Evidence:** `graphdb_class.erl:230-238, 638-651`.

The function returns the list of qualifying-characteristic *attribute
nrefs* from the class and its ancestors. It does not return inherited
*values* — that's §6 inheritance. A reader expects "the values this
class inherits"; gets "the QCs that apply to this class."

**Fix:** rename to `inherited_qcs/1`. Reserve `inherited_attributes` for
§6 semantics if/when class-level inheritance of bound values is exposed
as its own API.

---

## L2. Separate QC list from bound values on the class node

**Evidence:** `graphdb_class.erl:524-562`. `do_add_qc` writes
qualifying-characteristic pointers into `attribute_value_pairs` keyed
by the `qc_attr_nref` literal. Class-bound values are written into the
same list, keyed by other attribute nrefs.

Today they're separable by attribute key, but the spec treats "what
attributes apply" and "what values are bound here" as different
concepts. The `resolve_from_class` lookup in `graphdb_instance` is
already vulnerable to confusion: ask for the value of attribute
`qc_attr_nref` and you'll get back another attribute's nref.

**Fix:** add a dedicated `qcs :: [integer()]` field to the `node`
record (only meaningful for `kind = class`), or keep AVP storage but
mark QC entries with a distinct AVP shape (e.g.,
`#{kind => qc, attribute => AttrNref}`). Splits the bag without
breaking lookup ergonomics.

**Dependencies:** none. Best done before the rules engine (E1) starts
adding more concept tags to class nodes.

---

## L3. Single-row reads run inside `mnesia:transaction/1`

**Evidence:** `graphdb_class.erl:506, 569-575, 601-611`,
`graphdb_instance.erl:393, 406, 453-459, 486, 499`,
`graphdb_mgr.erl:357`. Every single-key node read is wrapped in a full
Mnesia transaction.

**Fix:** use `mnesia:dirty_read/2` for read-only single-row lookups
that don't need transactional isolation. Reserve transactions for
multi-row writes and reads that must observe atomic state.

**Dependencies:** none. Pure performance.

---

## L4. Wire `graphdb_mgr` write-side to workers

**Evidence:** `graphdb_mgr.erl:278-296`. `create_attribute`,
`create_class`, `create_instance`, `add_relationship` all return
`{error, not_implemented}` despite the workers being fully functional.

The spec's organizing claim is that `graphdb_mgr` is the single public
entry point. Today it is the single entry point only for *reads*;
write-side callers must talk to workers directly.

**Fix:** delegate each handler to the corresponding worker:
- `create_attribute` → `graphdb_attr:create_*` (route by kind in AVPs
  or split the API)
- `create_class` → `graphdb_class:create_class/2`
- `create_instance` → `graphdb_instance:create_instance/3`
- `add_relationship` → `graphdb_instance:add_relationship/4` (or `/5`
  per M5)
- `delete_node`, `update_node_avps` → keep category guard, then
  delegate to the kind-appropriate worker.

**Dependencies:** the API shapes settle after C3, M5, H3, H4. Wire
once the signatures stop changing.

---

## L5. Relationship row IDs allocated from the global `nref_server`

**Evidence:** `graphdb_attr.erl:453-454`, `graphdb_class.erl:416-417,
465-466`, `graphdb_instance.erl:329-332, 421-422`,
`graphdb_bootstrap.erl:388-389`. Every relationship row's primary key
is allocated via `nref_server:get_nref/0`.

The `id` field is the relationship row's primary key, not a
graph-visible reference. Sharing the global nref allocator means
relationship rows consume integers that could otherwise identify
nodes, polluting the address space.

**Fix:** add a separate `relationship_id_server` (or extend
`nref_allocator` with a second counter). Migrate all `id` allocations
to it. Node nrefs and relationship IDs become independent counters.

**Dependencies:** none. Cosmetic for the address space; matters at
scale.

---

## Task 7 — Wire `dictionary_server` and `term_server` to `dictionary_imp`

**Evidence:** `apps/dictionary/src/dictionary_server.erl`,
`apps/dictionary/src/term_server.erl` are gen_server stubs.
`dictionary_imp` is fully implemented.

**Fix:** delegate from each gen_server to the relevant `dictionary_imp`
functions. Independent of all graphdb work.

---

## E2. Non-normal OTP start types

**Evidence:** `seerstone:start/2` and `nref:start/2` both hit `?NYI` for
`{takeover, Node}` and `{failover, Node}` start types. Only relevant in
a distributed/failover OTP deployment.

**Fix:** when distributed deployment is on the roadmap, implement.

---

## E3. `code_change/3` — hot code upgrades

**Evidence:** NYI in all gen_server modules: `nref_allocator`,
`nref_server`, all six `graphdb_*` workers.

**Fix:** only invoked during a hot code upgrade via OTP release
handling. Implement when first hot-upgrade is planned.

---

## E4. `start_phases` / `start_phase/3`

**Evidence:** None of the `.app.src` files define `start_phases`, so
`start_phase/3` is never called. Correct for the present configuration;
revisit if phased startup is desired.
