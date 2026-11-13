# Seed Cache (Piece A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold every seed node in memory after boot, make the CT suites boot
the way production does, and stop runtime paths from writing seeds.

**Architecture:** A new plain module, `graphdb_seeds`, reads every
environment node below `?NREF_START` once, right after the
`graphdb:start/2` phase flip. It stores them and a label → nref index in
one `persistent_term` map. Reads make no gen_server call, so they are safe
inside Mnesia transactions. Freeze guards key off `graphdb_seeds:is_seed/1`,
which is `false` until `load/0` has run, so bootstrap and worker `init/1`
seeding are never gated. Every CT suite that starts graphdb workers flips to
the runtime phase and loads the cache, then checks at teardown that no seed
row changed.

**Tech Stack:** Erlang/OTP 28.5, Mnesia, `persistent_term`, Common Test,
rebar3 3.27 (`./rebar3`).

**Spec:** `docs/designs/seed-cache-attribute-placement-label-pairs-design.md`
— Piece A, "Test harness", "Documentation". Pieces B and C get their own
plans after this PR merges; they consume this plan's interfaces.

## Global Constraints

- Source files use **hard tabs** and Dallas's header: copyright block,
  author, created date, description, revision history, `-module`, module
  attributes, NYI/UEM macros, explicit `-export` (never `export_all`).
- Every modified module gets a new revision-history entry.
- `-record(node, …)` is copy-pasted per module (house convention); do not
  add a shared header for it.
- **No gen_server call inside an Mnesia transaction.** `graphdb_seeds`
  reads (`node/1`, `nref/1`, `is_seed/1`, `all/0`) must touch only
  `persistent_term`. `load/0` makes gen_server calls and must never be
  called inside a transaction.
- Error term for a refused seed write from a class API:
  `{error, permanent_node_immutable}` (the existing term, unchanged).
- Seeds and persistence are in flux: no migrations, no compatibility shims.
- Build gates: `./rebar3 compile` with zero warnings; `./rebar3 xref` clean
  with no new `xref_ignores`; `./rebar3 eunit`; `make test-ct-parallel`.
- If `./rebar3 ct` cannot find `graphdb_nrefs.hrl`, the `_build/test` cache
  is stale — use `make test-ct-parallel` (see `.wolf/cerebrum.md`).
- Do not read or search `docs/archive/`.
- Markdown edits: aligned table pipes
  (`python3 ~/.claude/scripts/align_md_tables.py FILE`), consecutive
  numbering, language-tagged fences, prose wrapped near 80 columns where the
  file already wraps.

## Review Focus

1. **A worker restarted after the flip** (a `one_for_one` restart in
   production, or a test that stops and starts a worker) must still pass its
   `init/1`. `graphdb_language` and `graphdb_rules` call
   `graphdb_attr:retro_stamp_attribute_types/0` from `init/1`. Pinned by
   `attr_restart_after_load_succeeds` (Task 5) and
   `rules_restart_after_load_succeeds` (Task 5).
2. **A runtime path the spec did not list writes a seed.** The "frozen"
   claim rests on this never happening. Pinned by
   `graphdb_test_boot:assert_seeds_unchanged/1`, run at the end of every
   test case in every migrated suite (Tasks 3–4).
3. **Project nrefs overlap seed nrefs numerically** (projects allocate from
   1). Nothing may treat a project node as a seed. Pinned by
   `rebuild_caches_project_ignores_seed_set` (Task 5).
4. **A stale cache leaking into the next test case or suite** (sequential
   `./rebar3 ct` shares one VM). Pinned by `before_load_nothing_is_seed`
   (Task 1) and by `graphdb_test_boot:reset/0` in every migrated
   `end_per_testcase` (Tasks 3–4).
5. **A seeding worker started after the flip** gives seeds runtime-tier
   nrefs that the cache never sees. `load/0` must fail loudly. Pinned by
   `load_rejects_worker_started_after_flip` (Task 1).

---

## Before Task 1: branch

The spec commit `b95d85f` sits on `seed-cache-label-pairs`; `develop`
equals `upstream/main` (`f6dfae8`). Unless told otherwise, fast-forward
`develop` to `seed-cache-label-pairs` and do all work on `develop`, so the
PR from `david-w-t:develop` ships the spec, the "in flux" notes and Piece A
together:

```bash
git checkout develop
git merge --ff-only seed-cache-label-pairs
```

## File Structure

| File                                        | Change | Responsibility                                         |
| ------------------------------------------- | ------ | ------------------------------------------------------ |
| `apps/graphdb/src/graphdb_seeds.erl`        | Create | Seed cache: load, lookups, erase                       |
| `apps/graphdb/test/graphdb_seeds_SUITE.erl` | Create | Cache behaviour and the real application boot          |
| `apps/graphdb/test/graphdb_test_boot.erl`   | Create | Test helper: flip + load, reset, seeds-unchanged check |
| `apps/graphdb/src/graphdb.erl`              | Modify | `start/2` loads the cache after the flip               |
| `apps/graphdb/src/graphdb_class.erl`        | Modify | Refuse superclass / QC / bound value on a seed class   |
| `apps/graphdb/src/graphdb_attr.erl`         | Modify | Retro-stamp and Template marker refuse to write a seed |
| `apps/graphdb/src/graphdb_mgr.erl`          | Modify | `rebuild_caches/0` skips seeds once loaded             |
| 8 CT suites (Tasks 3–4)                     | Modify | Boot like production; assert seeds unchanged           |
| Docs (Task 6)                               | Modify | Architecture, CLAUDE files, TASKS, README counts       |

---

### Task 1: `graphdb_seeds` module

**Files:**
- Create: `apps/graphdb/src/graphdb_seeds.erl`
- Create: `apps/graphdb/test/graphdb_seeds_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_nrefs:scaffold_spec/0` (`[{Atom, Nref, Kind, Name}]`);
  `graphdb_attr:seeded_nrefs/0`, `graphdb_language:seeded_nrefs/0`,
  `graphdb_rules:seeded_nrefs/0` (each `{ok, #{atom() => term()}}`);
  `graphdb_instance:remote_reference_class/0` (`integer()`).
- Produces:
  - `graphdb_seeds:load() -> ok | {error, {label_not_seed, atom(), integer()}}`
  - `graphdb_seeds:node(integer() | atom()) -> {ok, #node{}} | not_seed`
  - `graphdb_seeds:nref(atom()) -> {ok, integer()} | not_seed`
  - `graphdb_seeds:is_seed(integer()) -> boolean()` — environment nrefs only;
    `false` when not loaded
  - `graphdb_seeds:all() -> [#node{}]` — `[]` when not loaded
  - `graphdb_seeds:erase() -> ok` — idempotent

**Suite setup** (`graphdb_seeds_SUITE`): copy `graphdb_rules_SUITE`'s
`init_per_suite`, `setup_isolated_env` (scratch prefix `"seeds_"`) and
teardown. `init_per_testcase` starts `rel_id_server`, `graphdb_nref`
(after `set_permanent_phase()`), `graphdb_mgr`, `graphdb_attr`,
`graphdb_class`, `graphdb_instance`, `graphdb_language`, `graphdb_rules`,
then calls `ok = graphdb_nref:set_runtime_phase()`. It does **not** call
`load/0` — each case does. `end_per_testcase` calls `graphdb_seeds:erase()`
before stopping workers. Put the cases in group `cache`; Task 2 adds group
`app_boot`.

- [ ] **Step 1: Write the failing tests**

```erlang
load_caches_every_permanent_tier_node(_Config) ->
	ok = graphdb_seeds:load(),
	Keys = [N || N <- mnesia:dirty_all_keys(nodes), N < ?NREF_START],
	?assert(length(Keys) > 36),
	?assertEqual(length(Keys), length(graphdb_seeds:all())),
	lists:foreach(fun(N) ->
		[Row] = mnesia:dirty_read(nodes, N),
		?assert(graphdb_seeds:is_seed(N)),
		?assertEqual({ok, Row}, graphdb_seeds:node(N))
	end, Keys).

runtime_node_is_not_seed(_Config) ->
	ok = graphdb_seeds:load(),
	{ok, C} = graphdb_class:create_class("Runtime", ?NREF_CLASSES),
	?assert(C >= ?NREF_START),
	?assertNot(graphdb_seeds:is_seed(C)),
	?assertEqual(not_seed, graphdb_seeds:node(C)).

lookup_by_label(_Config) ->
	ok = graphdb_seeds:load(),
	{ok, #{retired := Ret}}      = graphdb_attr:seeded_nrefs(),
	{ok, #{applies_to := App}}   = graphdb_rules:seeded_nrefs(),
	{ok, #{lang_human := LH}}    = graphdb_language:seeded_nrefs(),
	RR = graphdb_instance:remote_reference_class(),
	?assertEqual({ok, ?ARC_INST_PARENT}, graphdb_seeds:nref(arc_inst_parent)),
	?assertEqual({ok, ?NREF_ENGLISH},    graphdb_seeds:nref(nref_english)),
	?assertEqual({ok, Ret}, graphdb_seeds:nref(retired)),
	?assertEqual({ok, App}, graphdb_seeds:nref(applies_to)),
	?assertEqual({ok, LH},  graphdb_seeds:nref(lang_human)),
	?assertEqual({ok, RR},  graphdb_seeds:nref(remote_reference_class)),
	?assertEqual(graphdb_seeds:node(Ret), graphdb_seeds:node(retired)).

non_nref_map_values_are_not_labels(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(env_language_code)).

unknown_label_is_not_seed(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(no_such_seed)),
	?assertEqual(not_seed, graphdb_seeds:node(no_such_seed)).

label_sources_are_disjoint(_Config) ->
	%% Two sources claiming one label would silently overwrite each other.
	ok = graphdb_seeds:load(),
	Ints = fun(M) -> [K || {K, V} <- maps:to_list(M), is_integer(V)] end,
	{ok, A} = graphdb_attr:seeded_nrefs(),
	{ok, L} = graphdb_language:seeded_nrefs(),
	{ok, R} = graphdb_rules:seeded_nrefs(),
	All = [K || {K, _, _, _} <- graphdb_nrefs:scaffold_spec()]
		++ Ints(A) ++ Ints(L) ++ Ints(R) ++ [remote_reference_class],
	?assertEqual(length(All), length(lists:usort(All))).

before_load_nothing_is_seed(_Config) ->
	ok = graphdb_seeds:load(),
	ok = graphdb_seeds:erase(),
	?assertNot(graphdb_seeds:is_seed(?NREF_ROOT)),
	?assertEqual(not_seed, graphdb_seeds:node(?NREF_ROOT)),
	?assertEqual(not_seed, graphdb_seeds:nref(nref_root)),
	?assertEqual([], graphdb_seeds:all()),
	?assertEqual(ok, graphdb_seeds:erase()).

load_skips_absent_workers(_Config) ->
	{ok, #{applies_to := App}} = graphdb_rules:seeded_nrefs(),
	ok = gen_server:stop(graphdb_rules),
	ok = graphdb_seeds:load(),
	?assertEqual(not_seed, graphdb_seeds:nref(applies_to)),
	?assert(graphdb_seeds:is_seed(App)).

lookups_run_inside_a_transaction(_Config) ->
	ok = graphdb_seeds:load(),
	?assertEqual({atomic, true},
		mnesia:transaction(fun() -> graphdb_seeds:is_seed(?NREF_ROOT) end)).
```

Plus one case whose `init_per_testcase` arm differs: for
`load_rejects_worker_started_after_flip`, start every worker **except**
`graphdb_rules`, flip, then start `graphdb_rules` inside the test.

```erlang
load_rejects_worker_started_after_flip(_Config) ->
	{ok, _} = graphdb_rules:start_link(),
	{ok, #{rule := Rule}} = graphdb_rules:seeded_nrefs(),
	?assert(Rule >= ?NREF_START),
	?assertMatch({error, {label_not_seed, _, N}} when N >= ?NREF_START,
		graphdb_seeds:load()),
	?assertNot(graphdb_seeds:is_seed(?NREF_ROOT)).
```

The last assertion pins that a failed load stores nothing.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_seeds_SUITE`
Expected: FAIL — `undef` for `graphdb_seeds:load/0`.

- [ ] **Step 3: Implement `apps/graphdb/src/graphdb_seeds.erl`**

Plain module (no behaviour), header modelled on `graphdb_ns.erl`, exports
exactly the six functions in **Interfaces**. Storage key
`{graphdb_seeds, cache}` holding `#{nodes := #{integer() => #node{}},
labels := #{atom() => integer()}}`.

`load/0`:
1. Seeds: `mnesia:dirty_select(nodes, [{#node{nref = '$1', _ = '_'},
   [{'<', '$1', ?NREF_START}], ['$_']}])`, keyed by nref.
2. Labels, merged in this order: `scaffold_spec/0` atoms; then the integer
   entries of each `seeded_nrefs/0` map of `graphdb_attr`,
   `graphdb_language`, `graphdb_rules`; then
   `remote_reference_class => graphdb_instance:remote_reference_class()`.
   Skip a worker whose `whereis/1` is `undefined`.
3. The first label whose nref is not a key of the seed map →
   `{error, {label_not_seed, Label, Nref}}`, storing nothing.
4. Otherwise `persistent_term:put/2` and return `ok`.

Readers use `persistent_term:get(Key, undefined)`; `undefined` answers
`not_seed` / `false` / `[]`. `erase/0` uses `persistent_term:erase/1` and
ignores its boolean.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_seeds_SUITE`
Expected: all 10 cases PASS. Then `./rebar3 xref` — clean.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_seeds.erl apps/graphdb/test/graphdb_seeds_SUITE.erl
git commit -m "Add graphdb_seeds: in-memory cache of every seed node"
```

---

### Task 2: Load the cache at boot

**Files:**
- Modify: `apps/graphdb/src/graphdb.erl:140-156` (`start/2`)
- Test: `apps/graphdb/test/graphdb_seeds_SUITE.erl` (group `app_boot`)

**Interfaces:**
- Consumes: `graphdb_seeds:load/0` (Task 1).
- Produces: after `application:start(graphdb)` returns, the cache is loaded
  and `graphdb_nref:phase()` is `runtime`.

- [ ] **Step 1: Write the failing test**

`init_per_testcase(app_start_loads_seed_cache, Config)` sets up the isolated
directory and the `bootstrap_file` env but starts **no** workers by hand.
Its `end_per_testcase` runs `application:stop(graphdb)` and
`graphdb_seeds:erase()`, then the normal teardown.

```erlang
app_start_loads_seed_cache(_Config) ->
	{ok, _} = application:ensure_all_started(graphdb),
	?assertEqual(runtime, graphdb_nref:phase()),
	?assert(graphdb_seeds:is_seed(?NREF_ROOT)),
	?assertMatch({ok, _}, graphdb_seeds:nref(applies_to)),
	?assertMatch({ok, _}, graphdb_seeds:nref(remote_reference_class)).
```

No test exercises `graphdb:start/2` today. If `ensure_all_started(graphdb)`
fails for a reason unrelated to this change, stop and report the error
rather than replacing the test with a hand-started worker list.

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_seeds_SUITE --group app_boot`
Expected: FAIL on `is_seed(?NREF_ROOT)` (cache not loaded).

- [ ] **Step 3: Call `ok = graphdb_seeds:load()` in `graphdb:start/2`**

Immediately after `ok = graphdb_nref:set_runtime_phase()`, before returning
`{ok, Pid}`. A failed load crashes the start, like the line above it.
Update the comment and add a revision entry.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_seeds_SUITE`
Expected: all 11 cases PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb.erl apps/graphdb/test/graphdb_seeds_SUITE.erl
git commit -m "Load the seed cache after the runtime-phase flip"
```

---

### Task 3: Test harness helper and the first four suites

This task changes no production code. Its job is that the existing suites
pass while booting like production.

**Files:**
- Create: `apps/graphdb/test/graphdb_test_boot.erl`
- Modify: `graphdb_attr_SUITE`, `graphdb_class_SUITE`,
  `graphdb_language_SUITE`, `graphdb_project_SUITE` (all in
  `apps/graphdb/test/`)

**Interfaces:**
- Consumes: `graphdb_seeds:load/0`, `all/0`, `erase/0`;
  `graphdb_nref:set_runtime_phase/0`.
- Produces (test-only module):
  - `graphdb_test_boot:flip() -> ok` — `set_runtime_phase()` then
    `load()`; both matched `ok`.
  - `graphdb_test_boot:reset() -> ok` — `graphdb_seeds:erase()` and
    `persistent_term:erase({graphdb_nref, phase})`.
  - `graphdb_test_boot:assert_seeds_unchanged(TC :: atom()) -> ok` — when
    Mnesia is running, compares every `graphdb_seeds:all()` record with its
    `mnesia:dirty_read(nodes, Nref)` row. Any mismatch → `ct:pal` the list
    of `{Nref, Cached, Stored}` and
    `ct:fail({seeds_changed, TC, Nrefs})`. Mirrors the suites'
    `verify_cache_invariant/1`.

**Migration rule** (applies to Task 4 too):

1. `flip()` runs once per test case, **after the last seeding worker has
   started** (`graphdb_mgr`, `graphdb_attr`, `graphdb_instance`,
   `graphdb_language`, `graphdb_rules`) and before the case creates
   anything. When a suite starts its workers in `init_per_testcase`, put it
   at the end of `init_per_testcase`, before any fixture creation. When the
   test body starts the worker under test, put it right after that start.
2. `end_per_testcase` calls `graphdb_test_boot:assert_seeds_unchanged(TC)`
   right after `verify_cache_invariant(TC)`, and replaces
   `catch persistent_term:erase({graphdb_nref, phase})` with
   `graphdb_test_boot:reset()`.
3. Remove ad-hoc runtime flips the rule makes redundant (for example
   `graphdb_project_SUITE:153`).
4. **Exception:** a case whose subject is init-time seeding itself (for
   example one asserting a seed lands in the permanent tier on restart) may
   flip later or not at all. Mark it with
   `%% permanent phase on purpose: <reason>`.

**Triaging failures.** A case that fails after migration is one of two
things:

- **It relied on permanent-phase allocation** (an expected nref, or a
  permanent-tier node it then mutated). Fix the test, and say which in the
  commit message.
- **`seeds_changed`, or a runtime path that rewrites a seed.** This is a
  gap in the spec. **Stop and report it** with the case name and the
  `{Nref, Cached, Stored}` triple. Do not weaken the assertion or exempt the
  case.

- [ ] **Step 1: Write `graphdb_test_boot.erl`** with the three functions
  above (test module: header comment and explicit exports, no NYI/UEM
  needed).

- [ ] **Step 2: Migrate `graphdb_attr_SUITE`** per the rule (workers start
  in each body after `graphdb_mgr` comes up in `init_per_testcase`).

- [ ] **Step 3: Run it**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: same case count as before, all PASS; triage any failure as above.

- [ ] **Step 4: Migrate and run `graphdb_class_SUITE`, `graphdb_language_SUITE`, `graphdb_project_SUITE`**, one at a time, running each with
  `./rebar3 ct --suite apps/graphdb/test/<suite>` before moving on.
  Expected: unchanged case counts, all PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/test/graphdb_test_boot.erl apps/graphdb/test/graphdb_{attr,class,language,project}_SUITE.erl
git commit -m "Test harness: boot attr/class/language/project suites like production"
```

---

### Task 4: Migrate the remaining four suites

**Files:**
- Modify: `graphdb_instance_SUITE`, `graphdb_mgr_SUITE`,
  `graphdb_query_SUITE`, `graphdb_rules_SUITE` (all in
  `apps/graphdb/test/`)

**Interfaces:**
- Consumes: `graphdb_test_boot:flip/0`, `reset/0`,
  `assert_seeds_unchanged/1` (Task 3).
- Produces: every CT suite that starts graphdb workers now runs its cases in
  the runtime phase with the cache loaded. `graphdb_bootstrap_SUITE`,
  `graphdb_nref_SUITE`, `graphdb_nrefs_SUITE` and `rel_id_server_SUITE`
  test pre-flip machinery and stay as they are.

- [ ] **Step 1: Migrate `graphdb_instance_SUITE`.** Delete
  `maybe_set_runtime_phase/1` and its guard list; `flip()` goes after
  `graphdb_rules:start_link()` and before `proj()`/`root()` and
  `setup_firing_fixtures/2`.

- [ ] **Step 2: Migrate `graphdb_mgr_SUITE`.** In the full-stack
  `init_per_testcase` arm (`:308-374`), replace
  `ok = graphdb_nref:set_runtime_phase()` with `ok = graphdb_test_boot:flip()`.
  Cases in the default arm start `graphdb_mgr` in their body; flip right
  after that start. Leave `init_fails_on_bad_config` alone (nothing boots).
  **Keep in the permanent phase** on purpose, with the marker comment:
  `verify_caches_detects_poisoned_parents`,
  `verify_caches_detects_poisoned_classes` and
  `rebuild_caches_restores_after_poison`. They poison seed nodes 6, 7 and
  18 and rely on `rebuild_caches/0` to repair them, which Task 5 allows only
  before the cache is loaded.

- [ ] **Step 3: Migrate `graphdb_query_SUITE` and `graphdb_rules_SUITE`.**

- [ ] **Step 4: Run each migrated suite, then the whole CT set**

Run: `./rebar3 ct --suite apps/graphdb/test/<suite>` for each, then
`make test-ct-parallel`.
Expected: all suites PASS. CT total = 559 + the Task 1–2 cases (11), no
existing case lost. Triage per Task 3.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/test/graphdb_{instance,mgr,query,rules}_SUITE.erl
git commit -m "Test harness: boot instance/mgr/query/rules suites like production"
```

---

### Task 5: Freeze guards

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl:373-385` (handle_call clauses)
- Modify: `apps/graphdb/src/graphdb_attr.erl` —
  `retro_stamp_bootstrap_attribute_types/1`,
  `stamp_attribute_type_if_missing/2`, `ensure_template_avp_marker/1`, and
  the `retro_stamp_attribute_types` `handle_call` clause
- Modify: `apps/graphdb/src/graphdb_mgr.erl:666` (`rebuild_caches_/1`)
- Test: `graphdb_class_SUITE`, `graphdb_attr_SUITE`, `graphdb_mgr_SUITE`,
  `graphdb_rules_SUITE`

**Interfaces:**
- Consumes: `graphdb_seeds:is_seed/1`, `graphdb_seeds:all/0`,
  `graphdb_seeds:erase/0`, `graphdb_test_boot:flip/0`.
- Produces:
  - `graphdb_class:add_superclass/2`, `add_qualifying_characteristic/2,3`,
    `bind_qc_value/3` return `{error, permanent_node_immutable}` when the
    **class** argument is a seed. A seed as the *new parent* of a runtime
    class is still allowed (only the runtime class's record changes).
  - `graphdb_attr:retro_stamp_attribute_types() -> ok |
    {error, {permanent_node_immutable, Nref}}` — the error only when a seed
    would actually be written; the worker keeps running.
  - `rebuild_caches/0` leaves seed rows untouched once the cache is
    loaded; `rebuild_caches/1` (project) is unchanged.

Test helper used below, local to each suite:
`seed_class() -> hd([N || #node{kind = class, nref = N} <- graphdb_seeds:all()])`.
It needs no particular worker, since `lang_human` is a bootstrap class.

- [ ] **Step 1: Write the failing tests**

`graphdb_class_SUITE`:

```erlang
add_superclass_refuses_seed_class(_Config) ->
	{ok, P} = graphdb_class:create_class("P", ?NREF_CLASSES),
	?assertEqual({error, permanent_node_immutable},
		graphdb_class:add_superclass(seed_class(), P)).

add_superclass_under_seed_parent_allowed(_Config) ->
	{ok, C} = graphdb_class:create_class("C", ?NREF_CLASSES),
	?assertEqual(ok, graphdb_class:add_superclass(C, seed_class())).

add_qc_refuses_seed_class(_Config) ->
	{ok, A} = graphdb_attr:create_literal_attribute("qa", string),
	?assertEqual({error, permanent_node_immutable},
		graphdb_class:add_qualifying_characteristic(seed_class(), A)),
	?assertEqual({error, permanent_node_immutable},
		graphdb_class:add_qualifying_characteristic(seed_class(), A,
			#{instance_only => true})).

bind_qc_value_refuses_seed_class(_Config) ->
	{ok, A} = graphdb_attr:create_literal_attribute("qb", string),
	?assertEqual({error, permanent_node_immutable},
		graphdb_class:bind_qc_value(seed_class(), A, "v")).

seed_class_writable_before_load(_Config) ->
	%% Init-time seeding runs before load/0 and must not be gated.
	S = seed_class(),
	ok = graphdb_seeds:erase(),
	{ok, A} = graphdb_attr:create_literal_attribute("qc_pre", string),
	?assertEqual(ok, graphdb_class:add_qualifying_characteristic(S, A)).
```

`graphdb_attr_SUITE` (after the worker under test has started and the case
has flipped):

```erlang
retro_stamp_after_load_is_noop(_Config) ->
	?assertEqual(ok, graphdb_attr:retro_stamp_attribute_types()).

retro_stamp_refuses_to_write_a_seed(_Config) ->
	{ok, #{attribute_type := At}} = graphdb_attr:seeded_nrefs(),
	[Row] = mnesia:dirty_read(nodes, ?NREF_INST_NAME_ATTRS),
	Stripped = Row#node{attribute_value_pairs =
		[P || #{attribute := K} = P <- Row#node.attribute_value_pairs, K =/= At]},
	ok = mnesia:dirty_write(nodes, Stripped),
	?assertEqual({error, {permanent_node_immutable, ?NREF_INST_NAME_ATTRS}},
		graphdb_attr:retro_stamp_attribute_types()),
	?assert(is_pid(whereis(graphdb_attr))),
	ok = mnesia:dirty_write(nodes, Row).

attr_restart_after_load_succeeds(_Config) ->
	ok = gen_server:stop(graphdb_attr),
	?assertMatch({ok, _}, graphdb_attr:start_link()).
```

`graphdb_rules_SUITE`:

```erlang
rules_restart_after_load_succeeds(_Config) ->
	ok = gen_server:stop(graphdb_rules),
	?assertMatch({ok, _}, graphdb_rules:start_link()).
```

`graphdb_mgr_SUITE` — add both cases to the full-stack `init_per_testcase`
guard list (without it they fail with `node_not_running`). The first
restores the seed row before returning, so the teardown checks still hold.
The "rebuilds seeds before load" side is already pinned by the existing
`rebuild_caches_restores_after_poison`, kept in the permanent phase by
Task 4.

```erlang
rebuild_caches_skips_seeds_after_load(_Config) ->
	[Seed] = mnesia:dirty_read(nodes, ?NREF_NAMES),
	ok = mnesia:dirty_write(nodes, Seed#node{parents = []}),
	ok = graphdb_mgr:rebuild_caches(),
	?assertMatch([#node{parents = []}], mnesia:dirty_read(nodes, ?NREF_NAMES)),
	ok = mnesia:dirty_write(nodes, Seed).

rebuild_caches_project_ignores_seed_set(_Config) ->
	%% A project nref can equal a seed nref; the project row is still rebuilt.
	Project = proj(),
	{ok, C} = graphdb_class:create_class("RebuildProj", ?NREF_CLASSES),
	{ok, I, _} = graphdb_instance:create_instance(Project, "RP", C, root()),
	?assert(graphdb_seeds:is_seed(I)),
	NodesTab = maps:get(nodes, Project),
	[Row] = mnesia:dirty_read(NodesTab, I),
	ok = mnesia:dirty_write(NodesTab, Row#node{classes = []}),
	ok = graphdb_mgr:rebuild_caches(Project),
	?assertEqual([Row], mnesia:dirty_read(NodesTab, I)).
```

`proj()` and `root()` are the suite's existing helpers (`:1751`, `:1773`).
Project nrefs start at 1, so `I` is small and overlaps a seed nref; that is
what the `is_seed(I)` assertion pins. If it fails, the premise is wrong, not
the code — report it.

- [ ] **Step 2: Run them to verify they fail**

Run each suite with `./rebar3 ct --suite apps/graphdb/test/<suite>`.
Expected: the class "refuses" cases return `ok` instead of the error;
`retro_stamp_refuses_to_write_a_seed` returns `ok`;
`rebuild_caches_skips_seeds_after_load` sees the cache repaired. The
`*_allowed`, `*_before_load`, `*_restart_*`, `retro_stamp_after_load_is_noop`
and project cases already PASS — they pin behaviour the change must keep.

- [ ] **Step 3: Implement the guards**

- `graphdb_class`: in the four `handle_call` clauses, refuse with
  `{error, permanent_node_immutable}` when `graphdb_seeds:is_seed(ClassNref)`,
  otherwise call the existing `do_*` function unchanged.
- `graphdb_attr`: before each `mnesia:write` in
  `stamp_attribute_type_if_missing/2` and `ensure_template_avp_marker/1`,
  `mnesia:abort({permanent_node_immutable, Nref})` when
  `graphdb_seeds:is_seed(Nref)`. The `retro_stamp_attribute_types`
  `handle_call` replies with the `{error, Reason}` instead of crashing on
  `ok =`. `init/1` keeps its current failure behaviour (a seed write refused
  during init is a real fault).
- `graphdb_mgr:rebuild_caches_/1`: filter `mnesia:all_keys(NodesTab)` with
  `skip_seed(Home, N)`, where `skip_seed(environment, N) ->
  graphdb_seeds:is_seed(N); skip_seed(_Project, _N) -> false`.

Add a revision entry to each module.

- [ ] **Step 4: Run the four suites, then everything**

Run: each suite, then `make test-ct-parallel` and `./rebar3 eunit` and
`./rebar3 xref`.
Expected: all PASS; xref clean; zero compile warnings.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_{class,attr,mgr}.erl apps/graphdb/test/graphdb_{class,attr,mgr,rules}_SUITE.erl
git commit -m "Freeze seeds after load: class mutators, retro-stamp, rebuild_caches"
```

---

### Task 6: Documentation and counts

**Files:**
- Modify: `docs/Architecture.md` — new module `graphdb_seeds` (seed cache,
  `persistent_term`, loaded by `graphdb:start/2` after the flip, freeze
  guards); the update rule triggers on a new module.
- Modify: `apps/graphdb/CLAUDE.md` — Files table row for
  `graphdb_seeds.erl`; Application Lifecycle call chain gains
  `graphdb_seeds:load()`; `graphdb_class` / `graphdb_attr` / `graphdb_mgr`
  notes gain the freeze behaviour.
- Modify: `CLAUDE.md` — Application lifecycle / nref-spaces text mentions
  the seed cache in one sentence.
- Modify: `TASKS.md` — Piece A marked IMPLEMENTED (pointing at the spec);
  Pieces B and C remain.
- Modify: `README.md` — test totals and per-suite rows, from a fresh run.
- Modify: `.wolf/anatomy.md` — entries for the three new files.

`docs/diagrams/ontology-tree.md` is unchanged: Piece A adds no seed.

- [ ] **Step 1: Get the real counts**

Run: `./rebar3 eunit` and `make test-ct-parallel`.
Expected: EUnit 151; CT 559 + every case added in Tasks 1, 2 and 5. Use the
printed numbers, not this arithmetic.

- [ ] **Step 2: Edit the docs above**, add the `graphdb_seeds_SUITE` row to
  the README per-suite table, and align every touched table with
  `python3 ~/.claude/scripts/align_md_tables.py <file>`.

- [ ] **Step 3: Commit**

```bash
git add docs/Architecture.md apps/graphdb/CLAUDE.md CLAUDE.md TASKS.md README.md
git commit -m "Document the seed cache; refresh test counts"
```
