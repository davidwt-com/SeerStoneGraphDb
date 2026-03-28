# SeerStoneGraphDb — Remaining Tasks

**resume** `opencode -s ses_2d3031f28ffe9zuklhjCtcLdJC`

Generated: 2026-03-15. All modernization work is complete and the project
compiles clean with zero warnings (OTP 27 / rebar3 3.24.0). What follows
is implementation work — completing Dallas's unfinished NYI stubs.

---

## ~~1. dictionary subsystem — missing worker modules~~ ✓ DONE

`dictionary_server` and `term_server` created as gen_server stubs in
`apps/dictionary/src/`. The `dictionary` application now starts cleanly.

Related reference files (not compiled, kept for design context):
- `Dictionary/dict_wkr.erl` — Dallas's earlier worker sketch
- `Dictionary/dictionary_draft.erl` — early draft of the `dictionary` module


## ~~2. dictionary_imp — export_all flag~~ ✓ DONE

`-compile(export_all).` removed. The explicit `-export([...])` list was
already present; the compiler now warns about unused functions normally.


## 3. graphdb worker modules — all are empty stubs

All six graphdb workers exist as gen_server stubs that start cleanly but
do nothing. The knowledge model they must implement is documented in
`knowledge-graph-database-guide.md` (derived from US patents 5,379,366;
5,594,837; 5,878,406 — Noyes).

Graph nodes are identified by **Nrefs** (plain `integer()`, allocated by
`nref_server:get_nref/0`). Every record stores:
```erlang
{
  nref          => Nref,
  relationships => [
    #{characterization => AttrNref,
      value            => TargetNref,
      reciprocal       => AttrNref2}
  ]
}
```

### 3a. `graphdb_attr` — Attribute Library

Maintains the attribute library: the set of named concepts used as
characterizations (labels) for both naming and relationships.

**Sub-tasks:**
- Define ETS/DETS schema for attribute records
- Implement `create_name_attribute/1`, `create_relationship_attribute/2` (attribute + reciprocal)
- Implement `create_relationship_type/1` and grouping of attributes under types
- Implement lookup: `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`

### 3b. `graphdb_class` — Taxonomic Hierarchy

Manages the "is a" hierarchy: class nodes, qualifying characteristics,
and class-level inheritance.

**Sub-tasks:**
- Define schema for class nodes (class name attr Nref, instance name attr Nref, qualifying characteristics)
- Implement `create_class/2` (name, parent class Nref) — allocates Nref, stores class record
- Implement `add_qualifying_characteristic/2` (class Nref, attribute Nref)
- Implement `get_class/1`, `subclasses/1`, `ancestors/1`
- Implement class-level attribute inheritance: `inherited_attributes/1`

### 3c. `graphdb_instance` — Compositional Hierarchy

Creates and retrieves instance nodes; manages the "part of" hierarchy.

**Sub-tasks:**
- Define schema for instance nodes (name attr Nref, class Nref, compositional parent Nref, relationships)
- Implement `create_instance/3` (name, class Nref, compositional parent Nref) — allocates Nref
- Implement `add_relationship/4` (instance Nref, characterization Nref, target Nref, reciprocal Nref)
- Implement `get_instance/1`, `children/1`, `compositional_ancestors/1`
- Implement full inheritance resolution: `resolve_value/2` (instance Nref, attribute Nref)
  following: local → class-bound → compositional ancestor chain → directly connected (one level)

### 3d. `graphdb_rules` — Graph Rules

Stores and enforces graph rules; supports pattern recognition and learning.

**Sub-tasks:**
- Define rule record schema (pattern: list of relationship constraints)
- Implement `create_rule/2` (name, pattern spec)
- Implement `check_rule/2` (rule Nref, candidate instance Nref)
- Implement `suggest_relationships/1` — scan rules against new instance, suggest likely relationships

### 3e. `graphdb_language` — Query Language

Parses and executes graph queries against the node network.

**Sub-tasks:**
- Define query DSL (at minimum: find nodes by class, find by attribute value, traverse relationships)
- Implement `parse_query/1` (binary or string → query term)
- Implement `execute_query/1` (query term → [Nref])
- Implement path queries: `find_path/3` (from Nref, to Nref, via relationship type)

### 3f. `graphdb_mgr` — Primary Coordinator

Routes and coordinates operations across the other five workers.

**Sub-tasks:**
- Define public API (the single entry point for callers outside graphdb)
- Implement delegation to `graphdb_attr`, `graphdb_class`, `graphdb_instance` etc.
- Implement transaction-like sequencing: allocate Nref → write record → confirm Nref

Location: `apps/graphdb/src/graphdb_*.erl`


## ~~4. nref_include — purpose unclear~~ ✓ DONE

`apps/nref/src/nref_include.erl` was Dallas's earlier unsupervised,
plain-function predecessor to `nref_server`. It was fully superseded by
`nref_server` (a proper gen_server supervised by `nref_sup`) and was
never referenced from anywhere in the compiled codebase. The file has
been deleted.


## 5. seerstone:start/2 — non-normal start types NYI

`apps/seerstone/src/seerstone.erl` line 152–153:
```erlang
start(Type, StartArgs) ->
    ?NYI({start, {Type, StartArgs}}),
```
The second clause handles takeover and failover starts
(`{takeover, Node}`, `{failover, Node}`). These are only relevant in a
distributed/failover OTP deployment. Low priority, but the `?NYI` will
crash the application master if a non-normal start is ever attempted.
Same pattern exists in `apps/nref/src/nref.erl`.


## 6. code_change/3 — NYI in all gen_server modules

The following gen_server modules have `?NYI(code_change)` in their
`code_change/3` callback:

- `apps/nref/src/nref_allocator.erl`
- `apps/nref/src/nref_server.erl`
- `apps/graphdb/src/graphdb_mgr.erl` (and the other 5 graphdb workers)

`code_change/3` is only invoked during a hot code upgrade. It can remain
NYI until hot upgrades are a real deployment concern. Low priority.


## 7. Old Directory/ top-level source files

The following files in the old pre-rebar3 locations are **not compiled**
by rebar3 and are not part of the active build:

| File | Status |
|---|---|
| `Dictionary/dict_wkr.erl` | Design reference; not in `apps/`; not compiled |
| `Dictionary/dictionary_draft.erl` | Early draft; not in `apps/`; not compiled |
| `Database/`, `graphdb/` top-level dirs | Old source locations; rebar3 uses `apps/` |
| `*.beam` files at project root | Stale; built from old flat layout |

Decision needed: delete the old directories and root-level `.beam` files,
or keep them as historical reference. They do not interfere with the build.


## 8. seerstone.app.src — start_phases not defined

None of the `.app.src` files define a `start_phases` key, so
`start_phase/3` will never be called by OTP. If phased startup is desired
in the future, `start_phases` must be added to the relevant `.app.src` and
the `start_phase/3` implementations in the app modules filled in.
Currently the callbacks return `ok` (no-op) which is correct for the
present configuration.


## Priority Order

1. **graphdb_attr** (task 3a) — foundational; all other workers depend on attribute Nrefs
2. **graphdb_class** (task 3b) — taxonomic hierarchy; needed before instances can have classes
3. **graphdb_instance** (task 3c) — core graph data; compositional hierarchy and inheritance
4. **graphdb_rules** (task 3d) — pattern recognition and rule enforcement
5. **graphdb_language** (task 3e) — query interface over the completed graph
6. **graphdb_mgr** (task 3f) — coordinator; implement last once workers have stable APIs
7. **seerstone/nref start/2 non-normal clause** (task 5) — low priority, distributed only
8. **code_change/3** (task 6) — low priority, hot upgrades only
9. **Old directory cleanup** (task 7) — housekeeping


---

## Session Notes (2026-03-26)

### Completed this session

All markdown files updated to incorporate knowledge from `knowledge-graph-database-guide.md`:

- `CLAUDE.md` (root) — added Knowledge Model section (node types, hierarchy systems, inheritance rules, Erlang record structure, worker responsibility table); fixed stale `nref_include` reference
- `README.md` — added Knowledge Model section with node types, hierarchies, relationships, worker table; added reference to guide in Contributing section
- `TASKS.md` — expanded task 3 into six sub-tasks (3a–3f) each with schema, role, and concrete API functions; rewrote Priority Order
- `apps/graphdb/CLAUDE.md` — full rewrite with knowledge model, worker responsibilities, correct compile commands
- `apps/dictionary/CLAUDE.md` — fixed compile command (was pointing at old flat layout), updated TASKS alignment
- `apps/database/CLAUDE.md` — removed duplicate TASKS section, fixed compile command, updated TASKS alignment
- `apps/nref/CLAUDE.md` — no changes needed; already accurate

### Pending: improvements to `knowledge-graph-database-guide.md`

Issues 1–4 applied 2026-03-27. 11 issues remain — confirm which to apply in the next session.

**Omissions (5)**

1. No Erlang/SeerStone mapping — the six worker modules and what part of the model each owns, Nrefs as integers, DETS/ETS storage; most impactful addition given the guide's stated purpose
2. No node creation sequence — order of operations (allocate Nref → write → confirm; attributes before arcs; class before instances)
3. Multiple inheritance conflict resolution unspecified — what wins when two parent classes bind conflicting values for the same attribute
4. "External Name Attributes" listed in the Attribute Library tree (line 89) but never defined or exemplified
5. Descriptive Database layer in the 3-layer architecture (lines 236–239) is unexplained — how it is populated, when discarded, role in query execution

**Structural / clarity (4)**

6. "Articulation Principles" section title is opaque — content is about node granularity and query optimisation; suggest renaming "Modelling Guidelines"
7. Instance Inheritance Process steps listed in wrong priority order (lines 174–179) — local values listed second but are highest priority; should read local → class-bound → compositional ancestors → directly connected
8. Contradictory pitfall advice — "Over-compositional parents: use multiple class membership" (line 341) directly contradicts "Prefer multiple compositional parents over multiple class memberships" (line 188); one must be removed or the distinction explained
9. View/Document Derivation section (line 308) reuses "Class" to mean document grammar/format, conflicting with its established meaning as a taxonomic node type; needs disambiguation or renaming

**Minor (2)**

10. Reciprocity table middle column (line 103) labelled "Relationship" but cells contain type names — should be "Type" or "Group"
11. Patent titles incomplete (lines 382–383) — 1997 and 1999 entries have editorial summaries instead of actual titles
