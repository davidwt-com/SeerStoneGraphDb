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
characterizations (labels) for both naming and relationships, plus literal
attribute descriptors for scalar/external values stored directly on nodes.

**Sub-tasks:**
- Define ETS/DETS schema for attribute records (name, literal, relationship)
- Implement `create_name_attribute/1`, `create_literal_attribute/2` (name, type)
- Implement `create_relationship_attribute/2` (attribute + reciprocal)
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

## Session Notes

### knowledge-graph-database-guide.md — applied corrections

| # | Description | Applied |
|---|---|---|
| 1 | Erlang/SeerStone mapping (workers, Nrefs, storage) | Skipped — guide is conceptual only; implementation detail belongs elsewhere |
| 2 | Node creation sequence (bootstrap order) | Pending |
| 3 | Multiple inheritance conflict resolution rule | Pending |
| 4 | "External Name Attributes" undefined | Applied 2026-03-27 — replaced with Literal Attributes |
| 5 | Descriptive Database layer unexplained | Pending |
| 6 | "Articulation Principles" title opaque | Applied 2026-03-27 — renamed Modelling Guidelines |
| 7 | Instance Inheritance Process wrong priority order | Applied 2026-03-27 — reordered local → class → ancestor → connected |
| 8 | Contradictory multiple-parent pitfall advice | Applied 2026-03-27 — balanced pitfall list for both cases |
| 9 | "Class" reused in View/Document Derivation | Applied 2026-03-27 — renamed to Template |
| 10 | Reciprocity table middle column mislabelled "Relationship" | Applied 2026-03-29 — renamed to "Type" |
| 11 | Patent titles incomplete (1997, 1999 entries) | Applied 2026-03-29 — actual titles inserted; continuation-in-part notes added |

### Pending: improvements to `knowledge-graph-database-guide.md`

**A (was 2) — No node creation sequence**
The guide describes the model structure but not the order of operations required to build it. Attributes must exist before they can be used as characterizations; classes must exist before instances can be members; Nrefs must be allocated before records are written. A "Construction Order" or "Bootstrap Sequence" section is needed.

**B (was 3) — Multiple inheritance conflict resolution unspecified**
The Multiple Inheritance section now documents the pitfalls of attribute conflicts between two parent classes, but gives no resolution rule — which parent wins, or whether an explicit local override is always required. A definitive statement is needed.

**C (was 5) — Descriptive Database layer unexplained**
The three-layer architecture diagram (Environment → Project → Descriptive) describes only the first two layers. The Descriptive Database is noted as "non-permanent working memory" with no explanation of how it is populated, when it is discarded, or what role it plays in query execution.

~~**D (was 10) — Reciprocity table middle column mislabelled**~~
~~Column header is "Relationship" but all cells contain relationship type names (manufacturing, family, location). Should be "Type" or "Group".~~ Applied 2026-03-29.

~~**E (was 11) — Patent titles incomplete**~~
~~The 1997 and 1999 entries in Sources carry editorial summaries ("Continuation with system concepts", "Further refinements") rather than the actual patent titles.~~ Applied 2026-03-29. All three Noyes patents share the title "Method for representation of knowledge in a computer as a network database system"; 5,594,837 is a continuation-in-part of 5,379,366 and 5,878,406 is a continuation-in-part of 5,594,837.
