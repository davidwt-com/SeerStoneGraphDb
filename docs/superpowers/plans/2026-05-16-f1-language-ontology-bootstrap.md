# F1: Language Ontology Bootstrap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four subcategory nodes (Human Languages, Formal Languages, Diagram Languages, Renderers) under the Languages node (nref 4) in `bootstrap.terms`, update all dependents, and mark F1 complete in `TASKS.md`.

**Architecture:** Pure data addition — four new category nodes (nrefs 32–35) with eight compositional arc rows in `bootstrap.terms`; no production Erlang source changes required. Two CT suites have hardcoded counts that must be updated. The audit confirmed no production code hardcodes nref 4 directly.

**Tech Stack:** Erlang/OTP 27, rebar3 3.24, Mnesia, Common Test, EUnit

---

## Audit Findings (do not re-derive — use these)

**Nref assignments:**

| Nref | Name               | Kind     | Parent |
|------|--------------------|----------|--------|
| 32   | Human Languages    | category | 4      |
| 33   | Formal Languages   | category | 4      |
| 34   | Diagram Languages  | category | 4      |
| 35   | Renderers          | category | 4      |

**Count deltas:**

| Metric                  | Before | After |
|-------------------------|--------|-------|
| Bootstrap nodes         | 31     | 35    |
| Relationship rows       | 60     | 68    |
| Relationship pairs      | 30     | 34    |
| nref_start comment      | 10060  | 10068 |
| `NextNref >= ` assertion | 10060  | 10068 |

**Files touched:**

| File                                                | Change type                         |
|-----------------------------------------------------|-------------------------------------|
| `apps/graphdb/priv/bootstrap.terms`                 | Add 4 nodes + 8 arc rows            |
| `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`     | Update 4 assertions + add 1 test    |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`           | Update 2 assertions                 |
| `CLAUDE.md` (top-level)                             | Update Nref Quick-Reference table   |
| `apps/graphdb/CLAUDE.md`                            | Update Nref Quick-Reference table   |
| `TASKS.md`                                          | Replace "(nref assigned in F1)" ×2  |
| `TASKS-MEDIUM.md`                                   | Replace "(nref assigned in F1)" ×2  |
| `.wolf/cerebrum.md`                                 | Add F1 nref assignments             |

**No changes required:** All other `.erl` source files, `graphdb_bootstrap_tests.erl` (EUnit — tests pure functions with synthetic data only), `graphdb_attr_SUITE.erl`, `graphdb_class_SUITE.erl`, `graphdb_instance_SUITE.erl` (all use relative deltas).

---

## Task 1: Write Failing Tests

**Files:**
- Modify: `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`

### Step 1.1: Update `load_node_count` assertion

- [ ] In `graphdb_bootstrap_SUITE.erl` around line 233, change:

```erlang
%% Verify exactly 31 nodes are loaded (1-30 plus the Template AVP at 31).
```
to:
```erlang
%% Verify exactly 35 nodes are loaded (nrefs 1–31 plus Language subcategories 32–35).
```
and change:
```erlang
?assertEqual(31, mnesia:table_info(nodes, size)).
```
to:
```erlang
?assertEqual(35, mnesia:table_info(nodes, size)).
```

### Step 1.2: Update `load_relationship_count` assertion

- [ ] Around line 240, change:

```erlang
%% Verify exactly 60 relationship rows (30 pairs x 2 directions).
```
to:
```erlang
%% Verify exactly 68 relationship rows (34 pairs x 2 directions).
```
and change:
```erlang
?assertEqual(60, mnesia:table_info(relationships, size)).
```
to:
```erlang
?assertEqual(68, mnesia:table_info(relationships, size)).
```

### Step 1.3: Update `load_relationship_ids_above_floor` assertion

- [ ] Around line 332, change:

```erlang
?assertEqual(60, length(AllRels)),
```
to:
```erlang
?assertEqual(68, length(AllRels)),
```

### Step 1.4: Update `load_nref_floor_set` comment and assertion

- [ ] Around lines 363–366, change:

```erlang
	%% 30 relationship pairs = 60 IDs consumed, starting at 10000
	%% Next nref should be >= 10060
	NextNref = nref_server:get_nref(),
	?assert(NextNref >= 10060).
```
to:
```erlang
	%% 34 relationship pairs = 68 IDs consumed, starting at 10000
	%% Next nref should be >= 10068
	NextNref = nref_server:get_nref(),
	?assert(NextNref >= 10068).
```

### Step 1.5: Add `load_language_subcategories` test case

- [ ] Find the `all/0` test list in `graphdb_bootstrap_SUITE.erl`. Add `load_language_subcategories` to the list of test cases. Example — find the list that includes `load_template_avp_node_correct` and add after it:

```erlang
        load_language_subcategories,
```

- [ ] After the `load_template_avp_node_correct/1` function body, add the new test case:

```erlang
%%-----------------------------------------------------------------------------
%% Verify the four Language subcategory nodes (nrefs 32-35) under Languages (4).
%%-----------------------------------------------------------------------------
load_language_subcategories(_Config) ->
	ok = graphdb_bootstrap:load(),
	%% Each new node exists and has the right kind, name, and parent cache
	Expected = [
		{32, "Human Languages"},
		{33, "Formal Languages"},
		{34, "Diagram Languages"},
		{35, "Renderers"}
	],
	lists:foreach(fun({Nref, Name}) ->
		{atomic, [Node]} = mnesia:transaction(fun() ->
			mnesia:read(nodes, Nref)
		end),
		?assertEqual(Nref,     Node#node.nref),
		?assertEqual(category, Node#node.kind),
		?assertEqual([4],      Node#node.parents),
		?assertEqual([#{attribute => 17, value => Name}],
			Node#node.attribute_value_pairs)
	end, Expected),
	%% Languages (nref 4) has exactly these four children via char=22 (Child/CatRel)
	{atomic, ChildArcs} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, 4, #relationship.source_nref)
	end),
	ChildNrefs = lists:sort([A#relationship.target_nref ||
		A <- ChildArcs,
		A#relationship.kind =:= composition,
		A#relationship.characterization =:= 22]),
	?assertEqual([32, 33, 34, 35], ChildNrefs).
```

### Step 1.6: Update `graphdb_mgr_SUITE.erl` assertions

- [ ] In `graphdb_mgr_SUITE.erl` around lines 263–265, change:

```erlang
	%% 31 nodes and 60 relationship rows should be loaded
	?assertEqual(31, mnesia:table_info(nodes, size)),
	?assertEqual(60, mnesia:table_info(relationships, size)).
```
to:
```erlang
	%% 35 nodes and 68 relationship rows should be loaded
	?assertEqual(35, mnesia:table_info(nodes, size)),
	?assertEqual(68, mnesia:table_info(relationships, size)).
```

### Step 1.7: Run CT to confirm failures

- [ ] Run:

```sh
./rebar3 ct --suite=apps/graphdb/test/graphdb_bootstrap_SUITE,apps/graphdb/test/graphdb_mgr_SUITE
```

Expected: failures on `load_node_count`, `load_relationship_count`, `load_relationship_ids_above_floor`, `load_nref_floor_set`, `load_language_subcategories` (bootstrap suite) and the bootstrap-size test in mgr suite. All other cases should pass.

---

## Task 2: Implement — Update `bootstrap.terms`

**Files:**
- Modify: `apps/graphdb/priv/bootstrap.terms`

### Step 2.1: Add Level 2 Language subcategory nodes

- [ ] After the `Level 1` section (the four root children ending at nref 5), add a new section before the attribute nodes:

```erlang
%% -------------------------------------------------------------------------
%% Level 2 -- Languages' children (category)
%% -------------------------------------------------------------------------
{node, 32, category, {17, "Human Languages"},  []}.
{node, 33, category, {17, "Formal Languages"},  []}.
{node, 34, category, {17, "Diagram Languages"}, []}.
{node, 35, category, {17, "Renderers"},         []}.
```

Place this block between the `%% Level 1 -- Root's children` section and the `%% Level 2 -- Attributes' children` section. Add an appropriate BFS-level comment to the Attributes section to distinguish it: `%% Level 2 -- Attributes' children (attribute)` (it already exists; check it reads cleanly with the new Language block above it).

### Step 2.2: Add hierarchy arcs for Language subcategories

- [ ] In the hierarchy arcs section, after the `%% Root -> category children` block, add:

```erlang
%% Languages -> category children  (ChildArc=22, ParentArc=21, Kind=composition)
{relationship,  4, 22, [], 21, 32, [], composition}.  %% Languages -> Human Languages
{relationship,  4, 22, [], 21, 33, [], composition}.  %% Languages -> Formal Languages
{relationship,  4, 22, [], 21, 34, [], composition}.  %% Languages -> Diagram Languages
{relationship,  4, 22, [], 21, 35, [], composition}.  %% Languages -> Renderers
```

Also update the header comment near the top of the file:
- Change `%% Pre-assigned nrefs: 1-31 (nodes).` to `%% Pre-assigned nrefs: 1-35 (nodes).`

### Step 2.3: Run CT to confirm all tests pass

- [ ] Run:

```sh
./rebar3 ct --suite=apps/graphdb/test/graphdb_bootstrap_SUITE,apps/graphdb/test/graphdb_mgr_SUITE
```

Expected: all cases pass, including the new `load_language_subcategories`.

### Step 2.4: Run the full test suite

- [ ] Run:

```sh
./rebar3 ct && ./rebar3 eunit
```

Expected: all 228+ tests pass, zero failures.

### Step 2.5: Commit

- [ ] Stage and commit:

```sh
git add apps/graphdb/priv/bootstrap.terms \
        apps/graphdb/test/graphdb_bootstrap_SUITE.erl \
        apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "$(cat <<'EOF'
F1: add Language subcategory nodes to bootstrap (nrefs 32-35)

Adds Human Languages (32), Formal Languages (33), Diagram Languages (34),
and Renderers (35) as category children of Languages (nref 4) in
bootstrap.terms.  Updates CT count assertions and adds
load_language_subcategories test.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Update Documentation

**Files:**
- Modify: `CLAUDE.md` (top-level)
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `TASKS.md`
- Modify: `TASKS-MEDIUM.md`
- Modify: `.wolf/cerebrum.md`

### Step 3.1: Update Bootstrap Nref Quick-Reference in `CLAUDE.md` (top-level)

- [ ] In the `Bootstrap Nref Quick-Reference (BFS, nrefs 1–31)` block, change the header to `(BFS, nrefs 1–35)` and add four lines after `31      Template — Connection-arc scope AVP marker (parent: 16)`:

```
32      Human Languages  — Language subcategory (parent: 4)
33      Formal Languages — Language subcategory (parent: 4)
34      Diagram Languages — Language subcategory (parent: 4)
35      Renderers        — Language subcategory (parent: 4)
```

### Step 3.2: Update Bootstrap Nref Quick-Reference in `apps/graphdb/CLAUDE.md`

- [ ] Same change as Step 3.1 — find the identical `Bootstrap Nref Quick-Reference (BFS, nrefs 1–31)` block in `apps/graphdb/CLAUDE.md`, update the header to `(BFS, nrefs 1–35)`, add the four lines after nref 31.

Also update:
```
`apps/graphdb/priv/bootstrap.terms` — Erlang Terms file fully written; contains 31 nodes
(nrefs 1–31, BFS) and 30 hierarchy relationship pairs (4 composition + 26 taxonomy).
```
to:
```
`apps/graphdb/priv/bootstrap.terms` — Erlang Terms file fully written; contains 35 nodes
(nrefs 1–35, BFS) and 34 hierarchy relationship pairs (8 composition + 26 taxonomy).
```

### Step 3.3: Update `TASKS.md` — replace "(nref assigned in F1)" placeholders

- [ ] In `TASKS.md`, find M6-B (search for `"Human Languages (nref assigned in F1)"`). Replace every occurrence of `"Human Languages (nref assigned in F1)"` with `"Human Languages (nref 32)"`.

There are two occurrences — one in M6-B and one in M6-D.

### Step 3.4: Update `TASKS-MEDIUM.md` — same replacements

- [ ] In `TASKS-MEDIUM.md`, find and replace every occurrence of `"Human Languages (nref assigned in F1)"` with `"Human Languages (nref 32)"`.

### Step 3.5: Mark F1 complete in `TASKS.md`

- [ ] In `TASKS.md`, update the F1 section header from:

```markdown
## F1. Language Ontology Bootstrap
```
to:
```markdown
## F1. Language Ontology Bootstrap — RESOLVED
```

Add a status line at the top of F1's body:

```markdown
**Status:** Complete. Nrefs 32–35 seeded in `bootstrap.terms`. CT
coverage in `graphdb_bootstrap_SUITE` (`load_language_subcategories`).
```

### Step 3.6: Update `.wolf/cerebrum.md` — record F1 nref assignments

- [ ] Add to the `## Key Learnings` section of `.wolf/cerebrum.md`:

```
- **F1 Language subcategory nrefs**: Human Languages=32, Formal Languages=33, Diagram Languages=34, Renderers=35. All category nodes, parent=4 (Languages). Bootstrap nref range is now 1–35; runtime nrefs start at 10000 (floor unchanged).
```

### Step 3.7: Run table alignment on modified markdown files

- [ ] Run the table alignment script on the files with tables:

```sh
python3 ~/.claude/scripts/align_md_tables.py CLAUDE.md apps/graphdb/CLAUDE.md
```

### Step 3.8: Commit documentation

- [ ] Stage and commit:

```sh
git add CLAUDE.md apps/graphdb/CLAUDE.md TASKS.md TASKS-MEDIUM.md .wolf/cerebrum.md
git commit -m "$(cat <<'EOF'
F1: update docs — nref table, F1 resolved, M6-B/D nref assignments

CLAUDE.md and apps/graphdb/CLAUDE.md: Bootstrap Nref Quick-Reference
extended to nrefs 1-35.  TASKS.md: F1 marked resolved, M6-B and M6-D
updated with concrete nref 32 (Human Languages).  TASKS-MEDIUM.md: same
M6-B/D updates.  cerebrum.md: F1 nref assignments recorded.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Final Verification

### Step 4.1: Full clean test run

- [ ] Run:

```sh
./rebar3 ct && ./rebar3 eunit
```

Expected: all tests pass. Note final counts in the output (should report 229+ CT cases).

### Step 4.2: Check compile is clean

- [ ] Run:

```sh
./rebar3 compile
```

Expected: zero warnings, zero errors.

### Step 4.3: Update `.wolf/memory.md`

- [ ] Append one-line entry to `.wolf/memory.md`:

```
| HH:MM | F1 complete: nrefs 32-35 added to bootstrap.terms; CT updated; docs updated | bootstrap.terms, CLAUDE.md, TASKS.md | ok | ~400 |
```

---

## Self-Review

**Spec coverage check:**

| F1 spec requirement                                          | Covered by                      |
|--------------------------------------------------------------|---------------------------------|
| Add Human Languages, Formal Languages, Diagram Languages, Renderers under nref 4 | Task 2 Step 2.1 |
| Eight compositional arc rows (ChildArc=22, ParentArc=21)    | Task 2 Step 2.2                 |
| Update CT count assertions                                   | Task 1                          |
| Add CT test for new nodes                                    | Task 1 Step 1.5                 |
| Update CLAUDE.md Nref Quick-Reference                        | Task 3 Steps 3.1–3.2            |
| Update TASKS.md M6-B and M6-D with concrete nref            | Task 3 Step 3.3                 |
| Record nref assignments in cerebrum.md                       | Task 3 Step 3.6                 |
| Mark F1 resolved                                             | Task 3 Step 3.5                 |

No gaps found.
