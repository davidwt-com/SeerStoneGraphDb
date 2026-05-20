# Scaffold Nref Macros Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all hardcoded scaffold nref integers across graphdb source and test files with named macros from a shared header, add a companion module that verifies macro-to-database congruency at bootstrap end, and unload the bootstrap module once startup is complete.

**Architecture:** A single header file (`graphdb_nrefs.hrl`) is the authoritative compile-time catalog of all 35 scaffold nrefs plus the English permanent seed. A companion module (`graphdb_nrefs.erl`) exposes an iterable `scaffold_spec/0` used both by `verify/0` (called at the end of bootstrap) and by CT tests. Source modules drop their per-module inline `-define` macros and include the shared header instead. Test files replace raw integer literals with the same macros.

**Tech Stack:** Erlang/OTP 27, rebar3 3.24, Mnesia (for bootstrap verify), Common Test

---

## File Map

| Action  | Path                                                        | Role                                              |
|---------|-------------------------------------------------------------|---------------------------------------------------|
| Create  | `apps/graphdb/include/graphdb_nrefs.hrl`                    | Compile-time macro catalog (36 nrefs)             |
| Create  | `apps/graphdb/src/graphdb_nrefs.erl`                        | Runtime iterable spec + `verify/0`                |
| Create  | `apps/graphdb/test/graphdb_nrefs_SUITE.erl`                 | CT tests for `verify/0` and bootstrap unloading   |
| Modify  | `apps/graphdb/src/graphdb_bootstrap.erl`                    | Call `graphdb_nrefs:verify/0` at end of `do_load` |
| Modify  | `apps/graphdb/src/graphdb_mgr.erl`                          | Unload bootstrap after successful init            |
| Modify  | `apps/graphdb/src/graphdb_attr.erl`                         | Drop inline defines, include header               |
| Modify  | `apps/graphdb/src/graphdb_class.erl`                        | Drop inline defines, include header               |
| Modify  | `apps/graphdb/src/graphdb_instance.erl`                     | Drop inline defines, include header               |
| Modify  | `apps/graphdb/src/graphdb_language.erl`                     | Drop inline defines, include header               |
| Modify  | `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`             | Replace raw integers with macros                  |
| Modify  | `apps/graphdb/test/graphdb_attr_SUITE.erl`                  | Replace raw integers with macros                  |
| Modify  | `apps/graphdb/test/graphdb_class_SUITE.erl`                 | Replace raw integers with macros                  |
| Modify  | `apps/graphdb/test/graphdb_instance_SUITE.erl`              | Replace raw integers with macros                  |
| Modify  | `apps/graphdb/test/graphdb_language_SUITE.erl`              | Replace raw integers and 10000 with macros        |
| Modify  | `apps/graphdb/test/graphdb_instance_tests.erl`              | Replace raw integers with macros                  |
| Modify  | `apps/graphdb/test/graphdb_mgr_SUITE.erl`                   | Replace inline defines; add bootstrap-unload test |

---

### Task 1: Create `graphdb_nrefs.hrl`

**Files:**
- Create: `apps/graphdb/include/graphdb_nrefs.hrl`

- [ ] **Step 1: Create the header file**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% graphdb_nrefs.hrl -- Compile-time names for immutable scaffold nrefs.
%%
%% Scaffold nrefs 1-35 are written once at bootstrap and never reallocated.
%% Changing any value here requires re-bootstrapping the environment.
%% All values correspond directly to bootstrap.terms entries.
%%
%% nref_english (10000) is a permanent seed in the 10000-99999 tier.
%%---------------------------------------------------------------------

%% -- Top-level categories (scaffold 1-5) ------------------------------
-define(NREF_ROOT,             1).
-define(NREF_ATTRIBUTES,       2).
-define(NREF_CLASSES,          3).
-define(NREF_LANGUAGES,        4).
-define(NREF_PROJECTS,         5).

%% -- Attribute family roots (scaffold 6-8) ----------------------------
-define(NREF_NAMES,            6).
-define(NREF_LITERALS,         7).
-define(NREF_RELATIONSHIPS,    8).

%% -- Name-attribute subcategory nodes (scaffold 9-12) -----------------
-define(NREF_CAT_NAME_ATTRS,   9).
-define(NREF_ATTR_NAME_ATTRS, 10).
-define(NREF_CLS_NAME_ATTRS,  11).
-define(NREF_INST_NAME_ATTRS, 12).

%% -- Relationship-attribute subcategory nodes (scaffold 13-16) --------
-define(NREF_CAT_REL_ATTRS,   13).
-define(NREF_ATTR_REL_ATTRS,  14).
-define(NREF_CLS_REL_ATTRS,   15).
-define(NREF_INST_REL_ATTRS,  16).

%% -- Name attributes: used as #{attribute => ?NAME_ATTR_*, value => Name}
-define(NAME_ATTR_CATEGORY,   17).
-define(NAME_ATTR_ATTRIBUTE,  18).
-define(NAME_ATTR_CLASS,      19).
-define(NAME_ATTR_INSTANCE,   20).

%% -- Category hierarchy arc labels (kind = composition) ---------------
-define(ARC_CAT_PARENT,       21).
-define(ARC_CAT_CHILD,        22).

%% -- Attribute hierarchy arc labels (kind = taxonomy) -----------------
-define(ARC_ATTR_PARENT,      23).
-define(ARC_ATTR_CHILD,       24).

%% -- Class hierarchy arc labels (kind = taxonomy or composition) ------
-define(ARC_CLS_PARENT,       25).
-define(ARC_CLS_CHILD,        26).

%% -- Instance hierarchy arc labels (kind = composition) ---------------
-define(ARC_INST_PARENT,      27).
-define(ARC_INST_CHILD,       28).

%% -- Instance-class membership arc labels -----------------------------
-define(ARC_INST_TO_CLASS,    29).  %% instance -> class direction
-define(ARC_CLASS_TO_INST,    30).  %% class -> instance direction

%% -- Template scope AVP marker ----------------------------------------
-define(ARC_TEMPLATE,         31).

%% -- Language subcategories (scaffold 32-35) --------------------------
-define(NREF_HUMAN_LANGS,     32).
-define(NREF_FORMAL_LANGS,    33).
-define(NREF_DIAGRAM_LANGS,   34).
-define(NREF_RENDERERS,       35).

%% -- Permanent named instance nrefs (10000-99999 tier) ----------------
-define(NREF_ENGLISH,      10000).  %% English; first instance in ontology
```

- [ ] **Step 2: Verify the header compiles**

Add `-include_lib("graphdb/include/graphdb_nrefs.hrl").` to `apps/graphdb/src/graphdb_bootstrap.erl` (it will use it in Task 3). Run:

```sh
./rebar3 compile
```

Expected: zero warnings, zero errors.

- [ ] **Step 3: Commit**

```sh
git add apps/graphdb/include/graphdb_nrefs.hrl apps/graphdb/src/graphdb_bootstrap.erl
git commit -m "feat: add graphdb_nrefs.hrl scaffold nref macro catalog"
```

---

### Task 2: Create `graphdb_nrefs.erl` with `scaffold_spec/0` and `verify/0`

**Files:**
- Create: `apps/graphdb/src/graphdb_nrefs.erl`
- Create: `apps/graphdb/test/graphdb_nrefs_SUITE.erl`

- [ ] **Step 1: Write the failing CT test**

Create `apps/graphdb/test/graphdb_nrefs_SUITE.erl`:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(graphdb_nrefs_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([verify_returns_ok/1,
         bootstrap_module_unloaded/1]).

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "nrefs_").

all() -> [{group, congruency}].

groups() ->
    [{congruency, [sequence], [
        verify_returns_ok,
        bootstrap_module_unloaded
    ]}].

init_per_suite(Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    [{orig_cwd, OrigCwd} | Config].

end_per_suite(_Config) -> ok.

init_per_testcase(_TC, Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
        ?DIR_PREFIX ++ Unique]),
    ok = filelib:ensure_dir(filename:join(TmpDir, "x")),
    ok = file:set_cwd(TmpDir),
    case application:load(nref) of
        ok -> ok;
        {error, {already_loaded, nref}} -> ok
    end,
    case application:load(graphdb) of
        ok -> ok;
        {error, {already_loaded, graphdb}} -> ok
    end,
    ok = application:set_env(seerstone_graph_db, data_path, TmpDir),
    ok = application:set_env(seerstone_graph_db, bootstrap_file,
        filename:join(code:priv_dir(graphdb), "bootstrap.terms")),
    ok = application:set_env(mnesia, dir, TmpDir),
    {ok, _} = rel_id_server:start_link(),
    {ok, _} = graphdb_mgr:start_link(),
    [{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_server:stop(graphdb_mgr),
    catch gen_server:stop(graphdb_attr),
    catch gen_server:stop(graphdb_class),
    catch gen_server:stop(graphdb_instance),
    catch gen_server:stop(graphdb_language),
    catch gen_server:stop(rel_id_server),
    catch dets:close(rel_id_server),
    catch application:stop(nref),
    catch dets:close(nref_allocator),
    catch dets:close(nref_server),
    catch mnesia:stop(),
    application:unset_env(seerstone_graph_db, data_path),
    application:unset_env(seerstone_graph_db, bootstrap_file),
    application:unset_env(mnesia, dir),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    ok.

%%=============================================================================
%% Test Cases
%%=============================================================================

verify_returns_ok(_Config) ->
    %% After a successful bootstrap, every macro value must match
    %% its corresponding Mnesia node.
    ?assertEqual(ok, graphdb_nrefs:verify()).

bootstrap_module_unloaded(_Config) ->
    %% graphdb_mgr:init/1 unloads graphdb_bootstrap after a successful load.
    %% code:is_loaded/1 returns false when a module is not in the code server.
    ?assertEqual(false, code:is_loaded(graphdb_bootstrap)).

%%=============================================================================
%% Helpers
%%=============================================================================

delete_dir_recursive(Dir) ->
    case is_safe_scratch_dir(Dir) of
        true  -> do_delete_dir(Dir);
        false -> error({unsafe_delete, Dir})
    end.

is_safe_scratch_dir(Dir) ->
    Abs = filename:absname(Dir),
    IsAbsolute = (Abs =:= Dir),
    ContainsSentinel = (string:find(Dir, ?SCRATCH_SENTINEL) =/= nomatch),
    Leaf = filename:basename(Dir),
    HasPrefix = lists:prefix(?DIR_PREFIX, Leaf),
    IsAbsolute andalso ContainsSentinel andalso HasPrefix.

do_delete_dir(Dir) ->
    {ok, Entries} = file:list_dir(Dir),
    lists:foreach(fun(E) ->
        Path = filename:join(Dir, E),
        case filelib:is_dir(Path) of
            false -> file:delete(Path);
            true  -> do_delete_dir(Path)
        end
    end, Entries),
    file:del_dir(Dir).
```

- [ ] **Step 2: Run the test to confirm it fails**

```sh
./rebar3 ct --suite apps/graphdb/test/graphdb_nrefs_SUITE
```

Expected: FAIL — `graphdb_nrefs` module does not exist yet.

- [ ] **Step 3: Create `graphdb_nrefs.erl`**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Description: Runtime catalog of scaffold nrefs and bootstrap
%%              congruency verification.
%%---------------------------------------------------------------------

-module(graphdb_nrefs).

-include_lib("graphdb/include/graphdb_nrefs.hrl").

-record(node, {
    nref,
    kind,
    parents              = [],
    classes              = [],
    attribute_value_pairs
}).

-export([scaffold_spec/0, verify/0]).


%%---------------------------------------------------------------------
%% scaffold_spec() -> [{atom(), integer(), atom(), string()}]
%%
%% Returns {MacroName, Nref, Kind, ExpectedName} for every immutable
%% scaffold nref.  Used by verify/0 and CT tests.
%%---------------------------------------------------------------------
scaffold_spec() -> [
    {nref_root,           ?NREF_ROOT,           category,  "Root"},
    {nref_attributes,     ?NREF_ATTRIBUTES,      category,  "Attributes"},
    {nref_classes,        ?NREF_CLASSES,         category,  "Classes"},
    {nref_languages,      ?NREF_LANGUAGES,       category,  "Languages"},
    {nref_projects,       ?NREF_PROJECTS,        category,  "Projects"},
    {nref_names,          ?NREF_NAMES,           attribute, "Names"},
    {nref_literals,       ?NREF_LITERALS,        attribute, "Literals"},
    {nref_relationships,  ?NREF_RELATIONSHIPS,   attribute, "Relationships"},
    {nref_cat_name_attrs, ?NREF_CAT_NAME_ATTRS,  attribute, "Category Name Attributes"},
    {nref_attr_name_attrs,?NREF_ATTR_NAME_ATTRS, attribute, "Attribute Name Attributes"},
    {nref_cls_name_attrs, ?NREF_CLS_NAME_ATTRS,  attribute, "Class Name Attributes"},
    {nref_inst_name_attrs,?NREF_INST_NAME_ATTRS, attribute, "Instance Name Attributes"},
    {nref_cat_rel_attrs,  ?NREF_CAT_REL_ATTRS,   attribute, "Category Relationships"},
    {nref_attr_rel_attrs, ?NREF_ATTR_REL_ATTRS,  attribute, "Attribute Relationships"},
    {nref_cls_rel_attrs,  ?NREF_CLS_REL_ATTRS,   attribute, "Class Relationships"},
    {nref_inst_rel_attrs, ?NREF_INST_REL_ATTRS,  attribute, "Instance Relationships"},
    {name_attr_category,  ?NAME_ATTR_CATEGORY,   attribute, "Name"},
    {name_attr_attribute, ?NAME_ATTR_ATTRIBUTE,  attribute, "Name"},
    {name_attr_class,     ?NAME_ATTR_CLASS,      attribute, "Name"},
    {name_attr_instance,  ?NAME_ATTR_INSTANCE,   attribute, "Name"},
    {arc_cat_parent,      ?ARC_CAT_PARENT,       attribute, "Parent"},
    {arc_cat_child,       ?ARC_CAT_CHILD,        attribute, "Child"},
    {arc_attr_parent,     ?ARC_ATTR_PARENT,      attribute, "Parent"},
    {arc_attr_child,      ?ARC_ATTR_CHILD,       attribute, "Child"},
    {arc_cls_parent,      ?ARC_CLS_PARENT,       attribute, "Parent"},
    {arc_cls_child,       ?ARC_CLS_CHILD,        attribute, "Child"},
    {arc_inst_parent,     ?ARC_INST_PARENT,      attribute, "Parent"},
    {arc_inst_child,      ?ARC_INST_CHILD,       attribute, "Child"},
    {arc_inst_to_class,   ?ARC_INST_TO_CLASS,    attribute, "Class"},
    {arc_class_to_inst,   ?ARC_CLASS_TO_INST,    attribute, "Instance"},
    {arc_template,        ?ARC_TEMPLATE,         attribute, "Template"},
    {nref_human_langs,    ?NREF_HUMAN_LANGS,     category,  "Human Languages"},
    {nref_formal_langs,   ?NREF_FORMAL_LANGS,    category,  "Formal Languages"},
    {nref_diagram_langs,  ?NREF_DIAGRAM_LANGS,   category,  "Diagram Languages"},
    {nref_renderers,      ?NREF_RENDERERS,       category,  "Renderers"},
    {nref_english,        ?NREF_ENGLISH,         instance,  "English"}
].


%%---------------------------------------------------------------------
%% verify() -> ok | {error, {scaffold_nref_mismatch, [term()]}}
%%
%% Reads every scaffold nref from Mnesia and confirms it has the
%% expected kind and name AVP.  Called at the end of bootstrap load.
%%---------------------------------------------------------------------
verify() ->
    Mismatches = lists:flatmap(fun verify_one/1, scaffold_spec()),
    case Mismatches of
        [] -> ok;
        _  -> {error, {scaffold_nref_mismatch, Mismatches}}
    end.

verify_one({Name, Nref, ExpKind, ExpNameValue}) ->
    NameAttr = name_attr_for_kind(ExpKind),
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = ExpKind, attribute_value_pairs = AVPs}] ->
            HasName = lists:any(
                fun(#{attribute := A, value := V}) ->
                    A =:= NameAttr andalso V =:= ExpNameValue
                end, AVPs),
            case HasName of
                true  -> [];
                false -> [{Name, Nref, name_not_found, ExpNameValue}]
            end;
        [#node{kind = ActualKind}] ->
            [{Name, Nref, kind_mismatch, ExpKind, ActualKind}];
        [] ->
            [{Name, Nref, node_not_found}]
    end.

name_attr_for_kind(category)  -> ?NAME_ATTR_CATEGORY;
name_attr_for_kind(attribute) -> ?NAME_ATTR_ATTRIBUTE;
name_attr_for_kind(class)     -> ?NAME_ATTR_CLASS;
name_attr_for_kind(instance)  -> ?NAME_ATTR_INSTANCE.
```

- [ ] **Step 4: Run the test — expect `verify_returns_ok` to pass, `bootstrap_module_unloaded` to fail**

```sh
./rebar3 ct --suite apps/graphdb/test/graphdb_nrefs_SUITE
```

Expected: `verify_returns_ok` PASS (bootstrap already populates Mnesia), `bootstrap_module_unloaded` FAIL — bootstrap is still in the code server until Task 4.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_nrefs.erl apps/graphdb/test/graphdb_nrefs_SUITE.erl
git commit -m "feat: add graphdb_nrefs companion module with scaffold_spec/0 and verify/0"
```

---

### Task 3: Wire `graphdb_nrefs:verify/0` into the bootstrap end sequence

**Files:**
- Modify: `apps/graphdb/src/graphdb_bootstrap.erl`

The bootstrap already calls `rebuild_and_verify_caches/0` at the end of `do_load/0`. Add the scaffold verify immediately after.

- [ ] **Step 1: Find the `rebuild_and_verify_caches` call site in `do_load/0`**

Run:

```sh
grep -n "rebuild_and_verify_caches\|do_load" apps/graphdb/src/graphdb_bootstrap.erl
```

Note the line number of the `rebuild_and_verify_caches` call inside `do_load`.

- [ ] **Step 2: Add the `graphdb_nrefs:verify/0` call**

In `graphdb_bootstrap.erl`, inside `do_load/0`, after the `rebuild_and_verify_caches()` call, add:

```erlang
ok = graphdb_nrefs:verify(),
```

The `verify/0` call must come after nodes and caches are fully written. If it returns `{error, _}`, the `= ok` match causes `do_load` to throw, which is the desired fatal-startup behavior — same semantics as the cache invariant check.

- [ ] **Step 3: Compile and run the full bootstrap test suite**

```sh
./rebar3 compile && ./rebar3 ct --suite apps/graphdb/test/graphdb_bootstrap_SUITE
```

Expected: all bootstrap tests pass (the verify call succeeds silently; existing tests already exercise the post-load state).

- [ ] **Step 4: Commit**

```sh
git add apps/graphdb/src/graphdb_bootstrap.erl
git commit -m "feat: call graphdb_nrefs:verify/0 at end of bootstrap load"
```

---

### Task 4: Unload the bootstrap module after successful startup

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl`

- [ ] **Step 1: Locate the `graphdb_bootstrap:load()` call in `init/1`**

```sh
grep -n "graphdb_bootstrap:load\|code:delete\|code:purge" apps/graphdb/src/graphdb_mgr.erl
```

- [ ] **Step 2: Add the unload sequence after a successful load**

In `graphdb_mgr:init/1`, the successful branch currently reads:

```erlang
ok ->
    logger:info("graphdb_mgr: started, bootstrap loaded"),
    {ok, initial_state()}
```

Change it to:

```erlang
ok ->
    code:delete(graphdb_bootstrap),
    code:purge(graphdb_bootstrap),
    logger:info("graphdb_mgr: started, bootstrap loaded"),
    {ok, initial_state()}
```

`code:delete` marks the module as old. `code:purge` removes old code (safe immediately since `graphdb_bootstrap:load/0` has already returned and no process is executing inside it). Subsequent calls to `graphdb_bootstrap:` in test cases auto-reload the module from the code path — no test setup changes required.

- [ ] **Step 3: Run the `graphdb_nrefs_SUITE` to confirm both tests pass**

```sh
./rebar3 ct --suite apps/graphdb/test/graphdb_nrefs_SUITE
```

Expected: both `verify_returns_ok` and `bootstrap_module_unloaded` PASS.

- [ ] **Step 4: Run the full graphdb CT suite to confirm no regressions**

```sh
./rebar3 ct --dir apps/graphdb/test
```

Expected: all graphdb CT tests pass.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_mgr.erl
git commit -m "feat: unload graphdb_bootstrap from code server after startup"
```

---

### Task 5: Migrate graphdb source files to use the shared header

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl`
- Modify: `apps/graphdb/src/graphdb_class.erl`
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/src/graphdb_mgr.erl`

Each source module currently defines its own inline `-define` macros for the scaffold nrefs it uses. The migration is: add the `include_lib`, remove the inline defines, and rename usages to the standard names.

- [ ] **Step 1: Migrate `graphdb_attr.erl`**

Add after the `?NYI`/`?UEM` macro block:

```erlang
-include_lib("graphdb/include/graphdb_nrefs.hrl").
```

Remove these inline defines (around lines 90-101):

```erlang
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).
-define(ATTR_CHILD_ARC,  24).
-define(ATTR_PARENT_ARC, 23).
-define(TEMPLATE_AVP_NREF, 31).
```

Replace all usages in the module:

| Old macro               | New macro              |
|-------------------------|------------------------|
| `?NAME_ATTR_FOR_ATTRIBUTE` | `?NAME_ATTR_ATTRIBUTE` |
| `?ATTR_CHILD_ARC`          | `?ARC_ATTR_CHILD`      |
| `?ATTR_PARENT_ARC`         | `?ARC_ATTR_PARENT`     |
| `?TEMPLATE_AVP_NREF`       | `?ARC_TEMPLATE`        |

- [ ] **Step 2: Migrate `graphdb_class.erl`**

Add `-include_lib("graphdb/include/graphdb_nrefs.hrl").`

Remove inline defines (around lines 78-82):

```erlang
-define(NAME_ATTR_FOR_CLASS, 19).
-define(CLASS_CHILD_ARC,  26).
-define(CLASS_PARENT_ARC, 25).
```

Replace all usages:

| Old macro            | New macro          |
|----------------------|--------------------|
| `?NAME_ATTR_FOR_CLASS` | `?NAME_ATTR_CLASS` |
| `?CLASS_CHILD_ARC`     | `?ARC_CLS_CHILD`   |
| `?CLASS_PARENT_ARC`    | `?ARC_CLS_PARENT`  |

- [ ] **Step 3: Migrate `graphdb_instance.erl`**

Add `-include_lib("graphdb/include/graphdb_nrefs.hrl").`

Remove inline defines (around lines 78-91):

```erlang
-define(NAME_ATTR_FOR_INSTANCE, 20).
-define(INST_CHILD_ARC,  28).
-define(INST_PARENT_ARC, 27).
-define(CLASS_MEMBERSHIP_ARC,    29).
-define(INSTANCE_MEMBERSHIP_ARC, 30).
-define(TEMPLATE_AVP_NREF, 31).
```

Replace all usages:

| Old macro                  | New macro              |
|----------------------------|------------------------|
| `?NAME_ATTR_FOR_INSTANCE`  | `?NAME_ATTR_INSTANCE`  |
| `?INST_CHILD_ARC`          | `?ARC_INST_CHILD`      |
| `?INST_PARENT_ARC`         | `?ARC_INST_PARENT`     |
| `?CLASS_MEMBERSHIP_ARC`    | `?ARC_INST_TO_CLASS`   |
| `?INSTANCE_MEMBERSHIP_ARC` | `?ARC_CLASS_TO_INST`   |
| `?TEMPLATE_AVP_NREF`       | `?ARC_TEMPLATE`        |

- [ ] **Step 4: Migrate `graphdb_language.erl`**

Add `-include_lib("graphdb/include/graphdb_nrefs.hrl").`

Remove inline defines (around lines 59-69):

```erlang
-define(HUMAN_LANGS,    32).
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).
-define(NAME_ATTR_FOR_CLASS,     19).
-define(NAME_ATTR_FOR_INSTANCE,  20).
-define(ATTR_PARENT_ARC, 23).
-define(ATTR_CHILD_ARC,  24).
-define(CLASS_CHILD_ARC, 26).
-define(INST_PARENT_ARC, 27).
-define(INST_CHILD_ARC,  28).
-define(CLASS_MEMBERSHIP_ARC,    29).
-define(INSTANCE_MEMBERSHIP_ARC, 30).
```

Replace all usages:

| Old macro                  | New macro              |
|----------------------------|------------------------|
| `?HUMAN_LANGS`             | `?NREF_HUMAN_LANGS`    |
| `?NAME_ATTR_FOR_ATTRIBUTE` | `?NAME_ATTR_ATTRIBUTE` |
| `?NAME_ATTR_FOR_CLASS`     | `?NAME_ATTR_CLASS`     |
| `?NAME_ATTR_FOR_INSTANCE`  | `?NAME_ATTR_INSTANCE`  |
| `?ATTR_PARENT_ARC`         | `?ARC_ATTR_PARENT`     |
| `?ATTR_CHILD_ARC`          | `?ARC_ATTR_CHILD`      |
| `?CLASS_CHILD_ARC`         | `?ARC_CLS_CHILD`       |
| `?INST_PARENT_ARC`         | `?ARC_INST_PARENT`     |
| `?INST_CHILD_ARC`          | `?ARC_INST_CHILD`      |
| `?CLASS_MEMBERSHIP_ARC`    | `?ARC_INST_TO_CLASS`   |
| `?INSTANCE_MEMBERSHIP_ARC` | `?ARC_CLASS_TO_INST`   |

- [ ] **Step 5: Migrate `graphdb_mgr.erl`**

Add `-include_lib("graphdb/include/graphdb_nrefs.hrl").`

Replace the two inline defines (around lines 483-484). These are list/alias defines that reference multiple nrefs — keep the local aliases but update their values to use the shared macros:

```erlang
%% Before
-define(PARENT_ARCS, [21, 23, 25, 27]).
-define(CLASS_MEMBERSHIP_ARC, 29).

%% After
-define(PARENT_ARCS, [?ARC_CAT_PARENT, ?ARC_ATTR_PARENT,
                      ?ARC_CLS_PARENT,  ?ARC_INST_PARENT]).
-define(CLASS_MEMBERSHIP_ARC, ?ARC_INST_TO_CLASS).
```

- [ ] **Step 6: Compile — zero warnings**

```sh
./rebar3 compile
```

Expected: zero warnings, zero errors. Any `unused macro` warning means a usage site was missed.

- [ ] **Step 7: Run the full graphdb CT suite**

```sh
./rebar3 ct --dir apps/graphdb/test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```sh
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/src/graphdb_class.erl \
        apps/graphdb/src/graphdb_instance.erl apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/src/graphdb_mgr.erl
git commit -m "refactor: replace per-module scaffold nref defines with shared graphdb_nrefs.hrl"
```

---

### Task 6: Migrate graphdb test files to use the shared header

**Files:**
- Modify: `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_class_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_instance_tests.erl`
- Modify: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

Test files use raw integer literals directly (no inline defines). The migration is: add the `include_lib` line and replace every `17`, `18`, `19`, `20`, `21`–`31`, `32`–`35`, and `10000` that refers to a scaffold nref with the corresponding macro.

For each file in the list below, follow this pattern:

```
1. Add -include_lib("graphdb/include/graphdb_nrefs.hrl"). near the top
   (after -include_lib("common_test/...") or eunit lines)
2. Replace integer literals with macros using the table from Task 5.
3. Replace 10000 with ?NREF_ENGLISH (language_SUITE only — ~20 sites).
```

- [ ] **Step 1: Migrate all seven test files** (do them together — they are mechanical substitutions)

Key pattern: `#{attribute => 17, ...}` → `#{attribute => ?NAME_ATTR_CATEGORY, ...}`.

In `graphdb_language_SUITE.erl`, replace every occurrence of `10000` that refers to the English node nref with `?NREF_ENGLISH`. Do NOT replace `10000` where it appears in comments describing a floor assertion — those are not nref references.

In `graphdb_instance_tests.erl`, replace `#{attribute => 10, value => ...}` with `#{attribute => ?NREF_ATTR_NAME_ATTRS, value => ...}` and other scaffold integers similarly.

- [ ] **Step 2: Compile — zero warnings**

```sh
./rebar3 compile
```

- [ ] **Step 3: Run the full test suite**

```sh
./rebar3 ct --dir apps/graphdb/test && ./rebar3 eunit --app=graphdb
```

Expected: all CT and EUnit tests pass.

- [ ] **Step 4: Commit**

```sh
git add apps/graphdb/test/
git commit -m "refactor: replace raw scaffold nref integers with macros in test files"
```

---

### Task 7: Update TASKS.md and wrap up

**Files:**
- Modify: `TASKS.md`

- [ ] **Step 1: Run the complete test suite one final time**

```sh
./rebar3 compile && ./rebar3 ct --dir apps/graphdb/test && ./rebar3 eunit --app=graphdb
```

Expected: zero warnings; all CT and EUnit tests pass.

- [ ] **Step 2: Mark the task RESOLVED in TASKS.md**

Add a RESOLVED note to the scaffold nref macros entry.

- [ ] **Step 3: Commit**

```sh
git add TASKS.md
git commit -m "docs: mark scaffold nref macros task RESOLVED"
```
