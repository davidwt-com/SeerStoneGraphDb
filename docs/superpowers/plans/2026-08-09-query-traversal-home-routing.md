# Query Traversal — Home Routing for Arc-Discovered Nrefs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `graphdb_query`'s bounded BFS from re-guessing which store each frontier node lives in, so an environment-only path stops silently returning `{ok, no_path}` under a project-bound session.

**Architecture:** Two halves. **Half A** — a new pure `graphdb_ns:arc_target_namespace(Home, Kind, Char)` derives the target's store from the arc the traversal arrived on, keyed on `#relationship.kind` with the 29/30 membership pair distinguished by characterization. **Half B** — the BFS frontier, visited set, and target comparison become Home-qualified via a compact `home_id() :: environment | {project, Anchor}`. `resolve_home/2` is called only for the two `#q_find_path{}` endpoints and is otherwise untouched.

**Tech Stack:** Erlang/OTP 28.5, Mnesia, rebar3 3.27 (repo-local `./rebar3`), Common Test + EUnit.

**Design source:** `docs/designs/query-traversal-home-routing-design.md`

## Global Constraints

- **Branch:** `query-traversal-home-routing` (already created, off `develop` at `12f2f1a`). Do not merge, push, or open a PR — that is the user's call.
- **Indentation is per-file and non-negotiable:**
  - `apps/graphdb/src/graphdb_ns.erl` — **HARD TABS** (currently 8 tab-bearing lines).
  - `apps/graphdb/test/graphdb_ns_tests.erl` — **HARD TABS** (currently 18).
  - `apps/graphdb/src/graphdb_query.erl` — **SPACES, 4-wide. Must stay at 0 tabs.**
  - `apps/graphdb/test/graphdb_query_SUITE.erl` — **SPACES, 4-wide. Must stay at 0 tabs.**
  - `apps/graphdb/include/graphdb_query.hrl` — **SPACES, 4-wide.**
  - Verify after every edit with `grep -cP '\t' <file>` (note: `grep -c` exits 1 when the count is 0, so run it alone, never in an `&&` chain).
- **Header include style:** `-include_lib("graphdb/include/graphdb_nrefs.hrl").` — never a bare `-include`.
- **Never `git add` anything under `.wolf/` or `.superpowers/`.**
- **Erlang does not compile-check cross-module arity.** A clean `./rebar3 compile` proves nothing about cross-module calls. `./rebar3 xref` is the gate — run it after every task.
- **`graphdb_query` is a singleton gen_server.** A `function_clause` inside it kills the query server for every session. Every new function reachable from `dispatch/2` needs a total match or a caller-side gate.
- Commit after every task. Do not squash.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `apps/graphdb/src/graphdb_ns.erl` | Pure namespace resolution | **Modify** — add `arc_target_namespace/3`, add the `graphdb_nrefs.hrl` include |
| `apps/graphdb/test/graphdb_ns_tests.erl` | EUnit for the pure module | **Modify** — add T4 |
| `apps/graphdb/include/graphdb_query.hrl` | Query AST + continuation records | **Modify** — add `home_id()` type, re-type three `#cont_path{}` fields |
| `apps/graphdb/src/graphdb_query.erl` | Query language gen_server | **Modify** — `home_id/1`, `home_of_id/2`, `validate_cont_homes/2`, BFS threading, `is_scaffold_node/2` signature, `make_edge/6` |
| `apps/graphdb/test/graphdb_query_SUITE.erl` | Query CT suite | **Modify** — new `sp2_traversal_home_routing` group (T1, T2, T3, T5, T6) |
| `TASKS.md` | Outstanding work tracker | **Modify** — flip the open defect to resolved |
| `docs/Architecture.md` | Architectural altitude reference | **Modify** — §6 routing table + `graphdb_query` row |
| `apps/graphdb/CLAUDE.md` | Per-app guide | **Modify** — `graphdb_ns` and `graphdb_query` sections |

---

### Task 1: `graphdb_ns:arc_target_namespace/3`

**Files:**
- Modify: `apps/graphdb/src/graphdb_ns.erl`
- Test: `apps/graphdb/test/graphdb_ns_tests.erl`

**Interfaces:**
- Consumes: nothing (pure, first task).
- Produces: `graphdb_ns:arc_target_namespace(Home, ArcKind, Characterization) -> environment | Home`, where `Home :: environment | #{anchor := integer(), nodes := atom(), rels := atom(), counters := atom()}`, `ArcKind :: taxonomy | composition | connection | instantiation`, `Characterization :: integer()`. Task 2 calls this from `expand_arcs/10`.

**HARD TABS in both files.**

- [ ] **Step 1: Write the failing tests**

Append to `apps/graphdb/test/graphdb_ns_tests.erl` (tabs):

```erlang
%%---------------------------------------------------------------------
%% arc_target_namespace/3 -- the arc-row analogue of namespace_of/2.
%% Home is the store the arc row was READ from.
%%---------------------------------------------------------------------
arc_target_namespace_taxonomy_is_always_environment_test() ->
	%% Taxonomy is class/attribute refinement; projects hold only
	%% instances, so a taxonomy arc never targets a project node.
	[ ?assertEqual(environment,
	               graphdb_ns:arc_target_namespace(Home, taxonomy, C))
	  || Home <- [environment, ?PROJECT],
	     C    <- [?ARC_ATTR_PARENT, ?ARC_ATTR_CHILD, 9999] ].

arc_target_namespace_composition_is_home_relative_test() ->
	[ ?assertEqual(Home,
	               graphdb_ns:arc_target_namespace(Home, composition, C))
	  || Home <- [environment, ?PROJECT],
	     C    <- [?ARC_INST_PARENT, ?ARC_INST_CHILD, 9999] ].

arc_target_namespace_connection_is_home_relative_test() ->
	[ ?assertEqual(Home,
	               graphdb_ns:arc_target_namespace(Home, connection, 9999))
	  || Home <- [environment, ?PROJECT] ].

arc_target_namespace_membership_splits_on_characterization_test() ->
	%% The 29/30 pair is the one arc shape whose two directions
	%% deliberately live in different Homes: both rows sit in the
	%% PROJECT's table, but 29 targets an environment class and 30
	%% targets a project instance.
	?assertEqual(environment,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation,
	                                             ?ARC_INST_TO_CLASS)),
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation,
	                                             ?ARC_CLASS_TO_INST)).

arc_target_namespace_unknown_kind_defaults_to_home_test() ->
	%% Deliberately NOT a function_clause: this is reached from inside
	%% the graphdb_query singleton, where a crash would take the query
	%% server down for every session over one malformed row.
	?assertEqual(environment,
	             graphdb_ns:arc_target_namespace(environment, bogus_kind, 1)),
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, bogus_kind, 1)).

arc_target_namespace_unknown_instantiation_char_defaults_to_home_test() ->
	%% instantiation with a characterization outside the 29/30 pair is
	%% not a shape this codebase writes; fall through to the catch-all
	%% rather than crash.
	?assertEqual(?PROJECT,
	             graphdb_ns:arc_target_namespace(?PROJECT, instantiation, 9999)).
```

Add the include at the top of the file, immediately after the existing `-include_lib("eunit/include/eunit.hrl").`:

```erlang
-include_lib("graphdb/include/graphdb_nrefs.hrl").
```

- [ ] **Step 2: Confirm the arc macros exist before relying on them**

Run: `grep -nE 'ARC_(ATTR|INST)_(PARENT|CHILD)|ARC_INST_TO_CLASS|ARC_CLASS_TO_INST' apps/graphdb/include/graphdb_nrefs.hrl`

Expected: six defines — `?ARC_ATTR_PARENT` 23, `?ARC_ATTR_CHILD` 24, `?ARC_INST_PARENT` 27, `?ARC_INST_CHILD` 28, `?ARC_INST_TO_CLASS` 29, `?ARC_CLASS_TO_INST` 30. If any name differs, use the real name — do not invent one.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./rebar3 eunit --module=graphdb_ns_tests`
Expected: FAIL — `undefined function graphdb_ns:arc_target_namespace/3`.

- [ ] **Step 4: Implement `arc_target_namespace/3`**

In `apps/graphdb/src/graphdb_ns.erl` (tabs), add the include after the `-module(graphdb_ns).` line:

```erlang
-include_lib("graphdb/include/graphdb_nrefs.hrl").
```

Extend the export:

```erlang
-export([namespace_of/2, target_namespace/2, arc_target_namespace/3,
	node_table/1, rel_table/1]).
```

Append the function after `target_namespace/2`:

```erlang
%%---------------------------------------------------------------------
%% arc_target_namespace(Home, ArcKind, Characterization)
%%     -> environment | Home
%%
%% The arc-row analogue of namespace_of/2, for a traversal that has an
%% arc in hand.  `Home` is the store the arc row was READ from.
%%
%% Unlike a bare nref, an nref reached BY TRAVERSING AN ARC is not
%% ambiguous: #relationship.kind and .characterization are present on
%% every row and together determine the target's store outright.  This
%% is what lets graphdb_query stop guessing mid-traversal.
%%
%%   taxonomy      -- class/attribute refinement; projects hold only
%%                    instances, so the target is always environment.
%%   composition   -- home-relative: category/class composition is
%%                    environment<->environment, instance composition is
%%                    project<->project.
%%   connection    -- instance<->instance inside one store.
%%   instantiation -- the 29/30 membership pair.  BOTH rows live in the
%%                    project's table, but 29 (instance->class) targets
%%                    an environment class while 30 (class->instance)
%%                    targets a project instance.  This is the one arc
%%                    shape whose ends deliberately differ in Home, and
%%                    the characterization is exactly what says which
%%                    direction we are walking.
%%
%% Deliberately total.  A caller of this module is the graphdb_query
%% singleton; a function_clause here would take the query server down
%% for every session over one malformed row, so an unrecognised shape
%% logs and degrades to same-store (which is what that row did before
%% this function existed).
%%---------------------------------------------------------------------
arc_target_namespace(_Home, taxonomy,    _Char) -> environment;
arc_target_namespace(Home,  composition, _Char) -> Home;
arc_target_namespace(Home,  connection,  _Char) -> Home;
arc_target_namespace(_Home, instantiation, ?ARC_INST_TO_CLASS) -> environment;
arc_target_namespace(Home,  instantiation, ?ARC_CLASS_TO_INST) -> Home;
arc_target_namespace(Home,  Kind, Char) ->
	logger:warning(
		"graphdb_ns: unroutable arc kind ~p (characterization ~p) -- "
		"defaulting to same store ~p",
		[Kind, Char, Home]),
	Home.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./rebar3 eunit --module=graphdb_ns_tests`
Expected: PASS, all tests. Two `logger:warning` lines printed by the catch-all tests are expected output, not failures.

- [ ] **Step 6: Verify tabs and cross-module integrity**

Run these three separately (not chained — `grep -c` exits 1 on a zero count):
```bash
grep -cP '\t' apps/graphdb/src/graphdb_ns.erl
grep -cP '\t' apps/graphdb/test/graphdb_ns_tests.erl
```
Expected: both non-zero (tabs preserved).

Run: `./rebar3 xref`
Expected: clean, no `undefined_function_calls`.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_ns.erl apps/graphdb/test/graphdb_ns_tests.erl
git commit -m "Half A: graphdb_ns:arc_target_namespace/3 routes arc-discovered nrefs"
```

---

### Task 2: Home-qualified BFS

**Files:**
- Modify: `apps/graphdb/include/graphdb_query.hrl:59-67` (the `#cont_path{}` record)
- Modify: `apps/graphdb/src/graphdb_query.erl:321-330` (`dispatch(#q_find_path{}, _)`), `:860-923` (`bfs/8`, `bfs_step/5`, `expand_arcs/8`), `:925-948` (`is_scaffold_node/2`)
- Test: `apps/graphdb/test/graphdb_query_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_ns:arc_target_namespace/3` (Task 1); the **existing** `session_read_arcs_home(Session, Home, Nref, Dir, Kinds) -> {[#relationship{}], Session1}` at `graphdb_query.erl:443`.
- Produces: `home_id(Home) -> environment | {project, integer()}` and `home_of_id(Session, HomeId) -> environment | Project`, both private to `graphdb_query`. Task 3 calls `home_id/1`; Task 4 calls neither but mirrors `home_id/1`'s shape in `validate_cont_homes/2`.

**SPACES in all three files. All must end at 0 tabs.**

- [ ] **Step 1: Write the two failing tests**

Add to `apps/graphdb/test/graphdb_query_SUITE.erl` (spaces, 4-wide). Place the function bodies after `resume_rejects_bad_session_project/1` and before the `proj()` helper block:

```erlang
%%=====================================================================
%% SP2 follow-up — Home routing for arc-discovered nrefs
%% (docs/designs/query-traversal-home-routing-design.md)
%%=====================================================================

%%---------------------------------------------------------------------
%% T1 -- the invariant that broke.  An environment-only path must be
%% returned IDENTICALLY under an environment session, under a project
%% that does not shadow the intermediate hop, and under a project that
%% does.  Before the fix the third case returned {ok, no_path}.
%%---------------------------------------------------------------------
t1_env_only_path_identical_across_sessions(_Config) ->
    %% Both attributes are created under bootstrap nref 6 ("Names"), and
    %% graphdb_attr writes the taxonomy pair 6 -24-> New / New -23-> 6.
    %% So the only [taxonomy] route from A1 to A2 runs through 6.
    {ok, A1} = graphdb_attr:create_name_attribute("T1Alpha"),
    {ok, A2} = graphdb_attr:create_name_attribute("T1Beta"),
    Q = #q_find_path{from = A1, to = A2, max_depth = 4,
                     arc_kinds = [taxonomy]},

    {ok, EnvPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session()),

    %% (b) a project holding a single node -- nref 6 is NOT shadowed.
    {ok, SmallP} = graphdb_project:register_project("T1 small"),
    {ok, Small}  = graphdb_project:open(SmallP),
    _ = root_instance(Small),
    {ok, SmallPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session(Small)),

    %% (c) a project holding >= 6 nodes -- nref 6 IS shadowed.  Project
    %% allocators start at 1, so this is the steady state of any real
    %% project, not a contrived setup.
    {ok, BigP} = graphdb_project:register_project("T1 shadowing"),
    {ok, Big}  = graphdb_project:open(BigP),
    Seeded = [root_instance(Big) || _ <- lists:seq(1, 6)],
    ?assert(lists:member(?NREF_NAMES, Seeded)),
    {ok, BigPath, _} =
        graphdb_query:execute_query(Q, graphdb_query:new_session(Big)),

    ?assertEqual(EnvPath, SmallPath),
    ?assertEqual(EnvPath, BigPath),
    ?assertMatch([#{from := A1, via := ?ARC_ATTR_PARENT,
                    to := ?NREF_NAMES, kind := taxonomy},
                  #{from := ?NREF_NAMES, via := ?ARC_ATTR_CHILD,
                    to := A2, kind := taxonomy}], EnvPath),
    %% An environment-only path crosses no store, so no edge discloses
    %% a Home (see Task 3).
    ?assertEqual([], [E || E <- EnvPath, maps:is_key(home, E)]).

%%---------------------------------------------------------------------
%% T2 -- false `found` via the bare-nref target comparison.  With
%% to = 6 under a shadowing project, resolve_home/2 resolves the
%% ENDPOINT to the project's instance 6 (documented, intentional).  A
%% walk through the environment's attribute 6 must therefore NOT count
%% as having found it.  Pre-fix, `case T of To` compared 6 =:= 6 and
%% returned a one-edge path -- a fabricated result.
%%
%% max_depth = 2 makes the post-fix outcome deterministic: level 1
%% expands A1 to {6}, level 2 expands 6's children, none of which is
%% the project's instance 6, and the budget runs out with a non-empty
%% frontier -> partial.
%%---------------------------------------------------------------------
t2_shadowed_target_is_not_falsely_found(_Config) ->
    {ok, A1} = graphdb_attr:create_name_attribute("T2Alpha"),
    {ok, P}  = graphdb_project:register_project("T2 shadowing"),
    {ok, Project} = graphdb_project:open(P),
    Seeded = [root_instance(Project) || _ <- lists:seq(1, 6)],
    ?assert(lists:member(?NREF_NAMES, Seeded)),
    Session = graphdb_query:new_session(Project),
    Reply = graphdb_query:execute_query(
        #q_find_path{from = A1, to = ?NREF_NAMES, max_depth = 2,
                     arc_kinds = [taxonomy]}, Session),
    %% The invariant: no path is fabricated.
    ?assertNotMatch({ok, [_ | _], _}, Reply),
    ?assertMatch({partial, _Best, _Cont, _S}, Reply).
```

Register both in the export list (after `resume_rejects_bad_session_project/1`, keeping the trailing entry comma-correct):

```erlang
    resume_rejects_bad_session_project/1,
    %% SP2 follow-up — Home routing for arc-discovered nrefs
    t1_env_only_path_identical_across_sessions/1,
    t2_shadowed_target_is_not_falsely_found/1
]).
```

Add a new group in `groups/0`, after the `sp2_project_session` group (add a comma after that group's closing `]}`):

```erlang
     {sp2_traversal_home_routing, [], [
        t1_env_only_path_identical_across_sessions,
        t2_shadowed_target_is_not_falsely_found
     ]}].
```

And add it to `all/0`:

```erlang
     {group, q6_find_path}, {group, sp2_project_session},
     {group, sp2_traversal_home_routing}].
```

- [ ] **Step 2: Run the tests to verify they fail — and check WHY**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=sp2_traversal_home_routing`

Expected: both FAIL.
- `t1_...` must fail on the **third** session with a badmatch against `{ok, no_path, _}` — proving the shadowing defect, not a fixture error. If it fails on the environment session instead, the fixture is wrong; fix the fixture before touching `graphdb_query.erl`.
- `t2_...` must fail at `?assertNotMatch({ok, [_ | _], _}, Reply)` — proving the fabricated path exists today.

Record both failure messages; the reviewer will ask for them.

- [ ] **Step 3: Re-type the continuation record**

In `apps/graphdb/include/graphdb_query.hrl`, add the type above the `-record(cont_path, ...)` block and re-type three fields:

```erlang
%% -- Home identity ----------------------------------------------------
%% Compact, comparable form of a Home: the atom `environment`, or a
%% project named by its anchor nref.  Deliberately NOT the full Project
%% handle -- that carries physical Mnesia table atoms, which have no
%% business in continuation state or in query results.
-type home_id() :: environment | {project, integer()}.

%% -- Continuation -----------------------------------------------------
%% Returned by bounded queries (currently only Q6). Tagged with the
%% snapshot it was issued against; resuming with a mismatched session
%% returns {error, snapshot_expired}.
%%
%% Every nref here is Home-qualified: a bare nref is unique only within
%% a Home, so project-6 and environment-6 must never collapse into one
%% visited entry.
-record(cont_path, {
    snapshot_at      :: erlang:timestamp(),
    target           :: {home_id(), integer()},
    arc_kinds        :: [arc_kind()],
    remaining_depth  :: non_neg_integer(),
    visited          :: #{{home_id(), integer()} => true},
    %% [{HomeId, Nref, PathToHere}] — frontier nodes to expand on resume
    frontier         :: [{home_id(), integer(), [map()]}]
}).
```

- [ ] **Step 4: Add the two Home-id helpers**

In `apps/graphdb/src/graphdb_query.erl`, immediately after `resolve_home/2` (which ends at line 380 with `resolve_home(_Session, _Nref) -> environment.`):

```erlang
%%---------------------------------------------------------------------
%% home_id(Home)              -> home_id()
%% home_of_id(Session, Id)    -> environment | Project
%%
%% `home_id()` is the compact, comparable form of a Home and is what
%% travels in the BFS frontier, the visited set, #cont_path{}, and the
%% public result. The full Project handle stays out of all four: it
%% carries physical table atoms, and it makes an unwieldy map key.
%%
%% home_of_id/2 is the inverse, and is total for any id a session can
%% legitimately produce: a session binds at most ONE Project, so a
%% {project, _} id can only mean that one. resume/2 gates continuations
%% carrying a foreign id before they ever reach here (validate_cont_homes/2).
%%---------------------------------------------------------------------
home_id(environment)         -> environment;
home_id(#{anchor := Anchor}) -> {project, Anchor}.

home_of_id(_Session, environment) ->
    environment;
home_of_id(Session, {project, _Anchor}) ->
    maps:get(project, Session).
```

- [ ] **Step 5: Resolve endpoints once in `dispatch/2`**

Replace the `#q_find_path{}` clause at `graphdb_query.erl:321-330`:

```erlang
dispatch(#q_find_path{from = From, to = To, max_depth = D,
                       arc_kinds = Kinds}, Session) ->
    SnapshotAt = maps:get(snapshot_at, Session),
    %% Entry points -- and ONLY entry points -- resolve Home by
    %% guessing. resolve_home/2 was designed for exactly this position:
    %% a bare nref with no characterization context. From here on Home
    %% travels with the frontier and is derived from each arc (see
    %% graphdb_ns:arc_target_namespace/3); it is never re-guessed.
    FromId = home_id(resolve_home(Session, From)),
    ToId   = home_id(resolve_home(Session, To)),
    %% Initial budget D doubles as the resume budget — partial conts
    %% carry max_depth as remaining_depth so resume gets a fresh full
    %% allotment rather than the exhausted 0.
    bfs(SnapshotAt, {ToId, To}, D, D, Kinds,
        #{{FromId, From} => true},
        [{FromId, From, []}],
        Session);
```

- [ ] **Step 6: Thread Home through `bfs/8` and `bfs_step/5`**

Replace `graphdb_query.erl:860-898`. Update the `bfs/8` head comment's `Frontier` line to `Frontier :: [{HomeId, Nref, PathToHere}]`:

```erlang
bfs(_Snap, _ToKey, _Budget, _D, _Kinds, _Vis, [], Session) ->
    {{ok, no_path}, Session};
bfs(Snap, ToKey, Budget, 0, Kinds, Vis, Frontier, Session) ->
    %% Depth exhausted but frontier non-empty -- partial.
    BestSoFar = case Frontier of
        [{_HomeId, _Nref, P} | _] -> P;
        []                        -> []
    end,
    Cont = #cont_path{snapshot_at     = Snap,
                      target          = ToKey,
                      arc_kinds       = Kinds,
                      remaining_depth = Budget,
                      visited         = Vis,
                      frontier        = Frontier},
    {{partial, BestSoFar, Cont}, Session};
bfs(Snap, ToKey, Budget, D, Kinds, Vis, Frontier, Session) ->
    {NextFrontier, Vis1, FoundPath, Session1} =
        bfs_step(ToKey, Kinds, Frontier, Vis, Session),
    case FoundPath of
        {found, Path} ->
            {{ok, Path}, Session1};
        not_found ->
            bfs(Snap, ToKey, Budget, D - 1, Kinds, Vis1, NextFrontier,
                Session1)
    end.

bfs_step(ToKey, Kinds, Frontier, Vis, Session) ->
    lists:foldl(
        fun({HomeId, Nref, PathToHere}, {Acc, V, Found, S}) ->
            case Found of
                {found, _} ->
                    {Acc, V, Found, S};
                not_found ->
                    %% session_read_arcs_home/5, NOT session_read_arcs/4:
                    %% the Home is known, so there is nothing to guess.
                    Home = home_of_id(S, HomeId),
                    {Arcs, S1} = session_read_arcs_home(S, Home, Nref,
                                                        outgoing, Kinds),
                    expand_arcs(ToKey, HomeId, Home, Nref, PathToHere,
                                Arcs, V, Acc, Found, S1)
            end
        end, {[], Vis, not_found, Session}, Frontier).
```

- [ ] **Step 7: Derive the target's Home in `expand_arcs`**

Replace `graphdb_query.erl:900-923` (`expand_arcs/8` becomes `/10`):

```erlang
expand_arcs(_ToKey, _FromId, _FromHome, _From, _PathHere, [], V, Acc,
            Found, S) ->
    {Acc, V, Found, S};
expand_arcs(ToKey, FromId, FromHome, From, PathHere,
            [#relationship{kind             = K,
                           characterization = C,
                           target_nref      = T} | Rest],
            V, Acc, Found, S) ->
    %% Half A: the target's Home is DERIVED from the arc we arrived on,
    %% never guessed from the bare nref.
    TargetHome = graphdb_ns:arc_target_namespace(FromHome, K, C),
    TargetId   = home_id(TargetHome),
    Edge = #{from => From, via => C, to => T, kind => K},
    NewPath = PathHere ++ [Edge],
    %% Half B: compare and remember the Home-qualified key. A bare nref
    %% is unique only within a Home.
    Key = {TargetId, T},
    case Key of
        ToKey ->
            {Acc, V, {found, NewPath}, S};
        _ ->
            case maps:is_key(Key, V) orelse is_scaffold_node(TargetHome, T) of
                true ->
                    expand_arcs(ToKey, FromId, FromHome, From, PathHere,
                                Rest, V, Acc, Found, S);
                false ->
                    V1 = V#{Key => true},
                    Acc1 = Acc ++ [{TargetId, T, NewPath}],
                    expand_arcs(ToKey, FromId, FromHome, From, PathHere,
                                Rest, V1, Acc1, Found, S)
            end
    end.
```

`ToKey` is already bound at this point, so `case Key of ToKey ->` matches by value — the same idiom the original `case T of To ->` used.

- [ ] **Step 8: Make `is_scaffold_node` take a Home**

Replace `graphdb_query.erl:925-948` (comment block and function):

```erlang
%%---------------------------------------------------------------------
%% is_scaffold_node(Home, Nref) -> boolean()
%%
%% Category nodes are structural scaffold (nrefs 1-5) -- never
%% traversed by graph queries.  Matches the semantics already encoded
%% in graphdb_class:ancestors/1 which filters NREF_CLASSES out of the
%% taxonomy walk.  Without this filter, two classes sharing only
%% NREF_CLASSES as a parent would be considered taxonomically
%% connected, which contradicts both the design and existing helpers.
%%
%% Takes a resolved Home rather than a Session: the caller already
%% derived it from the arc. This needs no policy about what
%% scaffold-ness means under a project session -- a project-homed nref
%% reads from the project's table, finds kind=instance, and yields
%% false, which is the right answer reached structurally.
%%---------------------------------------------------------------------
is_scaffold_node(Home, Nref) ->
    case mnesia:dirty_read(graphdb_ns:node_table(Home), Nref) of
        [#node{kind = category}] -> true;
        _                        -> false
    end.
```

- [ ] **Step 9: Compile and check for stale callers**

Run: `./rebar3 compile`
Expected: zero errors, zero warnings. A warning about an unused function means a caller was missed.

Run: `grep -n "session_read_arcs(S" apps/graphdb/src/graphdb_query.erl`
Expected: **no output**. `session_read_arcs/4` must have no BFS caller left. It stays defined and exported-in-module for `#q_get_arcs{}` and the describe paths — do not delete it.

Run: `./rebar3 xref`
Expected: clean.

- [ ] **Step 10: Run the new tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=sp2_traversal_home_routing`
Expected: 2 passed, 0 failed.

- [ ] **Step 11: Run the whole query suite — T7, non-regression**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: all pass. `resolve_home_prefers_project_and_logs_on_collision`, the full `q6_find_path` group, and `resume_rejects_bad_session_project` must pass **without being edited** — that is the proof that entry-point behaviour is untouched. If any needed a change to stay green, stop and report it rather than editing the test.

- [ ] **Step 12: Verify zero tabs**

Run each separately:
```bash
grep -cP '\t' apps/graphdb/src/graphdb_query.erl
grep -cP '\t' apps/graphdb/test/graphdb_query_SUITE.erl
grep -cP '\t' apps/graphdb/include/graphdb_query.hrl
```
Expected: `0` for all three.

- [ ] **Step 13: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/include/graphdb_query.hrl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "Half B: Home-qualified BFS frontier, visited set and target"
```

---

### Task 3: Disclose the Home on cross-store edges

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl` (`expand_arcs/10`, plus a new `make_edge/6`)
- Test: `apps/graphdb/test/graphdb_query_SUITE.erl`

**Interfaces:**
- Consumes: `home_id/1` (Task 2); `?ARC_INST_TO_CLASS` from `graphdb_nrefs.hrl` (already included at `graphdb_query.erl:55`).
- Produces: path edges of shape `#{from := integer(), via := integer(), to := integer(), kind := arc_kind()}`, plus `home := home_id()` **iff** the target's Home differs from the source's.

**SPACES. 0 tabs.**

- [ ] **Step 1: Write the failing test**

Add to `apps/graphdb/test/graphdb_query_SUITE.erl`:

```erlang
%%---------------------------------------------------------------------
%% T5 -- a path that crosses stores says so.  A project instance's
%% outgoing membership row (characterization 29) lives in the PROJECT's
%% relationship table but targets an environment class, so this is the
%% one crossing reachable under this scope.  The edge must disclose
%% `home => environment`; an environment-only path (T1) discloses
%% nothing.
%%---------------------------------------------------------------------
t5_cross_store_edge_discloses_home(_Config) ->
    Project = proj(),
    Cls = widget_class(),
    {ok, X, _} = graphdb_instance:create_instance(Project, "T5X", Cls,
                                                  root()),
    Session = graphdb_query:new_session(Project),
    {ok, Path, _} = graphdb_query:execute_query(
        #q_find_path{from = X, to = Cls, max_depth = 2,
                     arc_kinds = [instantiation]}, Session),
    ?assertMatch([#{from := X, via := ?ARC_INST_TO_CLASS, to := Cls,
                    kind := instantiation, home := environment}], Path).
```

Register it in the export list and add it to the `sp2_traversal_home_routing` group.

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --case=t5_cross_store_edge_discloses_home`
Expected: FAIL — the returned edge map has no `home` key.

If instead it fails with `no_path`, the membership arc is not being read; check that `create_instance/4` wrote the 29-row into `Project`'s own relationship table before changing anything else.

- [ ] **Step 3: Add `make_edge/6` and call it**

In `apps/graphdb/src/graphdb_query.erl`, add after `expand_arcs/10`:

```erlang
%%---------------------------------------------------------------------
%% make_edge(From, Char, To, Kind, FromId, TargetId) -> map()
%%
%% A path edge discloses `home` iff this hop crosses stores. The absent
%% key means "same store as the previous hop"; the first edge's store is
%% the one the caller named in `from`. A consumer reconstructs the whole
%% Home sequence by carrying the last disclosed value forward.
%%
%% The value is a home_id(), never the raw Project handle -- results
%% must not leak physical table atoms.
%%---------------------------------------------------------------------
make_edge(From, Char, To, Kind, HomeId, HomeId) ->
    #{from => From, via => Char, to => To, kind => Kind};
make_edge(From, Char, To, Kind, _FromId, TargetId) ->
    #{from => From, via => Char, to => To, kind => Kind,
      home => TargetId}.
```

The two clauses discriminate on whether the last two arguments are equal — the first head binds both to `HomeId`, so it matches only when they are.

In `expand_arcs/10`, replace the `Edge = ...` line from Task 2:

```erlang
    Edge = make_edge(From, C, T, K, FromId, TargetId),
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --case=t5_cross_store_edge_discloses_home`
Expected: PASS.

- [ ] **Step 5: Confirm T1 still sees no `home` key**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=sp2_traversal_home_routing`
Expected: all pass, including T1's `?assertEqual([], [E || E <- EnvPath, maps:is_key(home, E)])`.

- [ ] **Step 6: Verify and commit**

```bash
./rebar3 xref
grep -cP '\t' apps/graphdb/src/graphdb_query.erl
```
Expected: xref clean; tab count `0`.

```bash
git add apps/graphdb/src/graphdb_query.erl apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "Disclose home_id on path edges that cross stores"
```

---

### Task 4: `resume/2` validates continuation Homes

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl:184-201` (`resume/2`, beside `validate_session_home/1`)
- Test: `apps/graphdb/test/graphdb_query_SUITE.erl`

**Interfaces:**
- Consumes: `#cont_path{}`'s Task 2 field types.
- Produces: `{error, session_project_mismatch}` as a new `resume/2` return value.

**SPACES. 0 tabs.**

> **Scope note the implementer must not silently "fix":** the design listed a
> test T3 asserting that a hop through environment-6 is not suppressed by
> having visited project-6. That test is **not constructible under this
> scope**. Reaching both keys in one walk requires crossing stores, and the
> only crossing available is project→environment via arc 29, which lands on a
> class — from which the environment attribute subtree containing nref 6 is
> unreachable by taxonomy. The design anticipated this ("if either proves
> unreachable under this scope, the plan must say so explicitly"). It is
> replaced below by T3', which asserts the same Half-B property directly and
> observably: the continuation's state is Home-qualified. Do not invent a
> contrived fixture to resurrect the original T3.

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_query_SUITE.erl`:

```erlang
%%---------------------------------------------------------------------
%% T3' -- Half B's state shape, asserted where it is observable.
%% (The design's original T3 -- visiting project-6 must not suppress
%% environment-6 -- is not constructible under this scope; see the
%% plan's Task 4 scope note.)
%%---------------------------------------------------------------------
t3_continuation_state_is_home_qualified(_Config) ->
    Project = proj(),
    Cls = widget_class(),
    {ok, A, _} = graphdb_instance:create_instance(Project, "T3A", Cls,
                                                  root()),
    {ok, B, _} = graphdb_instance:create_instance(Project, "T3B", Cls, A),
    {ok, C, _} = graphdb_instance:create_instance(Project, "T3C", Cls, B),
    {ok, D, _} = graphdb_instance:create_instance(Project, "T3D", Cls, C),
    Anchor = maps:get(anchor, Project),
    Q = #q_find_path{from = D, to = A, max_depth = 1,
                     arc_kinds = [composition]},
    {partial, _Best, Cont, _S1} = graphdb_query:execute_query(
        Q, graphdb_query:new_session(Project)),
    #cont_path{target = Target, visited = Visited, frontier = Frontier} =
        Cont,
    ?assertEqual({{project, Anchor}, A}, Target),
    ?assert(lists:all(fun({_HomeId, N}) when is_integer(N) -> true;
                         (_)                               -> false
                      end, maps:keys(Visited))),
    ?assert(lists:all(fun({_HomeId, N, P}) -> is_integer(N)
                                              andalso is_list(P);
                         (_)                -> false
                      end, Frontier)).

%%---------------------------------------------------------------------
%% T6 -- the new frontier/visited shapes survive a round trip through
%% #cont_path{}: partial + resume must equal an unbounded run.
%%---------------------------------------------------------------------
t6_resume_round_trip_under_project_session(_Config) ->
    Project = proj(),
    Cls = widget_class(),
    {ok, A, _} = graphdb_instance:create_instance(Project, "T6A", Cls,
                                                  root()),
    {ok, B, _} = graphdb_instance:create_instance(Project, "T6B", Cls, A),
    {ok, C, _} = graphdb_instance:create_instance(Project, "T6C", Cls, B),
    {ok, D, _} = graphdb_instance:create_instance(Project, "T6D", Cls, C),
    Bounded = #q_find_path{from = D, to = A, max_depth = 2,
                           arc_kinds = [composition]},
    S0 = graphdb_query:new_session(Project),
    {partial, _Best, Cont, S1} = graphdb_query:execute_query(Bounded, S0),
    {ok, Resumed, _S2} = graphdb_query:resume(Cont, S1),
    {ok, Direct, _S3} = graphdb_query:execute_query(
        #q_find_path{from = D, to = A, max_depth = 9,
                     arc_kinds = [composition]},
        graphdb_query:new_session(Project)),
    ?assertEqual(Direct, Resumed).

%%---------------------------------------------------------------------
%% A continuation carrying a project id the session is not bound to must
%% be rejected on the caller side, not carried into home_of_id/2 inside
%% the singleton. Same reasoning as validate_session_home/1: the pid
%% must be unchanged afterwards.
%%---------------------------------------------------------------------
resume_rejects_foreign_project_continuation(_Config) ->
    Project = proj(),
    Cls = widget_class(),
    {ok, A, _} = graphdb_instance:create_instance(Project, "TFA", Cls,
                                                  root()),
    {ok, B, _} = graphdb_instance:create_instance(Project, "TFB", Cls, A),
    {ok, C, _} = graphdb_instance:create_instance(Project, "TFC", Cls, B),
    {ok, D, _} = graphdb_instance:create_instance(Project, "TFD", Cls, C),
    Q = #q_find_path{from = D, to = A, max_depth = 1,
                     arc_kinds = [composition]},
    S0 = graphdb_query:new_session(Project),
    {partial, _, Cont, S1} = graphdb_query:execute_query(Q, S0),
    {ok, OtherP}  = graphdb_project:register_project("TF other"),
    {ok, Other}   = graphdb_project:open(OtherP),
    OtherSession  = S1#{project => Other,
                        snapshot_at => maps:get(snapshot_at, S1)},
    PidBefore = whereis(graphdb_query),
    ?assertEqual({error, session_project_mismatch},
                 graphdb_query:resume(Cont, OtherSession)),
    ?assertEqual(PidBefore, whereis(graphdb_query)).
```

Register all three in the export list and add them to the `sp2_traversal_home_routing` group.

- [ ] **Step 2: Run them to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=sp2_traversal_home_routing`

Expected: `t3_...` and `t6_...` **PASS already** (Task 2 delivered the shape they assert — they are regression locks, not drivers). `resume_rejects_foreign_project_continuation` must **FAIL**, because `resume/2` does not yet check continuation Homes.

If `t3_` or `t6_` fails, stop — Task 2 is incomplete and this task cannot proceed.

- [ ] **Step 3: Implement the gate**

In `apps/graphdb/src/graphdb_query.erl`, replace `resume/2` (currently at `:184-188`):

```erlang
resume(Cont, Session) when is_map(Session) ->
    case validate_session_home(Session) of
        ok ->
            case validate_cont_homes(Cont, Session) of
                ok ->
                    gen_server:call(?MODULE, {resume, Cont, Session});
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.
```

Add after `validate_session_home/1` (which ends at `:201`):

```erlang
%% validate_cont_homes(Cont, Session) -> ok | {error, session_project_mismatch}
%%
%% Every home_id() a continuation can feed to home_of_id/2 must be
%% resolvable against THIS session. Checked on the caller side, before
%% the gen_server:call, for the same reason validate_session_home/1 is:
%% home_of_id/2 would otherwise return the wrong project's handle (or
%% `undefined` for an environment-bound session) deep inside the
%% singleton's own handle_call.
%%
%% Only the target and the frontier are checked. Visited keys are never
%% resolved -- they are compared, and a foreign id there can only ever
%% fail to match, which is harmless.
validate_cont_homes(#cont_path{target = {TargetId, _Nref},
                               frontier = Frontier}, Session) ->
    Bound = home_id(maps:get(project, Session, environment)),
    Ids = [TargetId | [Id || {Id, _N, _P} <- Frontier]],
    case lists:all(fun(environment) -> true;
                      (Id)          -> Id =:= Bound
                   end, Ids) of
        true  -> ok;
        false -> {error, session_project_mismatch}
    end.
```

`home_id/1` already accepts both `environment` and a Project handle, so `Bound` is correct for either session kind.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=sp2_traversal_home_routing`
Expected: all pass.

- [ ] **Step 5: Confirm the existing resume tests still pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q6_find_path`
Expected: all pass — in particular `q6_resume_continues_from_frontier` and `resume_against_refreshed_session_fails`, unmodified.

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --case=resume_rejects_bad_session_project`
Expected: PASS. The `validate_session_home/1` gate must still fire **before** `validate_cont_homes/2` — a malformed handle returns `{error, invalid_project}`, not `session_project_mismatch`.

- [ ] **Step 6: Verify and commit**

```bash
./rebar3 xref
grep -cP '\t' apps/graphdb/src/graphdb_query.erl
```
Expected: xref clean; tab count `0`.

```bash
git add apps/graphdb/src/graphdb_query.erl apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "resume/2 rejects continuations carrying a foreign project Home"
```

---

### Task 5: Documentation and full verification

**Files:**
- Modify: `TASKS.md` (the open-defect entry)
- Modify: `docs/Architecture.md:24`, `:31`, `:404-440`
- Modify: `apps/graphdb/CLAUDE.md` (`graphdb_ns` file-table row; `graphdb_query` worker section)

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: nothing consumed by code.

- [ ] **Step 1: Flip the `TASKS.md` entry from open to resolved**

Find the section beginning `**Open defect (Important) — query traversal silently truncates`. Change the heading to `**RESOLVED (query-traversal Home routing) — query traversal silently truncated`, keep the symptom paragraph as the historical record, and replace the "Designed — see ..." paragraph and the "Superseded fix direction" blockquote with:

```markdown
**Implemented.** Half A: `graphdb_ns:arc_target_namespace(Home, Kind, Char)`
derives an arc-discovered nref's store from `#relationship.kind`, with the
29/30 membership pair split on characterization. Half B: the BFS frontier,
visited set, and target comparison are Home-qualified via
`home_id() :: environment | {project, Anchor}`; path edges disclose `home`
when a hop crosses stores; `resume/2` rejects a continuation carrying a
foreign project id. `resolve_home/2` and `session_read_arcs/4` are unchanged
— only `bfs_step/5` changed caller, to `session_read_arcs_home/5`. Design:
`docs/designs/query-traversal-home-routing-design.md`.

Still open, deliberately out of that scope: BFS at an environment-homed node
reads only the environment relationship table, so an environment class cannot
reach its project instances across arc 30 (`?ARC_CLASS_TO_INST`).
`#q_instances_of{}` keeps its `session_read_arcs_home/5` special case. Also
still open: backfilling `target_kind` onto bootstrap arc labels 21–30, which
would let `graphdb_instance:check_target_kind/3` drop its permissive legacy
arm.
```

Leave the **Accepted consequence of `resolve_home/2`** section immediately below untouched — it describes intentional behaviour and is still accurate.

- [ ] **Step 2: Update `docs/Architecture.md`**

At line 31, extend the `graphdb_query` row's SP2 sentence:

```
SP2: `new_session/1` binds a `Project`; bare-nref **entry-point** reads resolve `Home` via `resolve_home/2`, while arc-discovered nrefs during BFS route deterministically via `graphdb_ns:arc_target_namespace/3`. `#q_find_path{}` state is Home-qualified and path edges disclose `home` on a store crossing.
```

In the `graphdb_ns` bullet around line 404, add `arc_target_namespace/3` to the listed functions with a one-clause description. Do not restructure the section.

- [ ] **Step 3: Update `apps/graphdb/CLAUDE.md`**

In the file table, extend the `graphdb_ns.erl` row to list `arc_target_namespace/3`. In the `graphdb_query` worker section, replace the paragraph that currently reads "Every bare-nref read resolves its physical table via `resolve_home/2` (SP2)" so it distinguishes entry points from arc-discovered nrefs, matching the wording used in Step 2.

- [ ] **Step 4: Full verification gate**

Run each and record the output:

```bash
./rebar3 compile
```
Expected: zero errors, zero warnings.

```bash
./rebar3 as test compile
```
Expected: zero errors, zero warnings.

```bash
./rebar3 xref
```
Expected: clean — only the pre-existing `rel_id_server:seed_from_mnesia/0` entry in `xref_ignores` is suppressed; no new ignores may be added.

```bash
make test-ct-parallel
```
Expected: all CT suites green. Baseline at `bb6c8c6` is **544 CT**; this branch adds 6 cases (T1, T2, T3', T5, T6, foreign-continuation) → **550 CT**.

```bash
./rebar3 eunit
```
Expected: all green. Baseline **145 EUnit**; Task 1 adds 6 → **151 EUnit**.

If any count differs from the expected total, report the discrepancy rather than adjusting the expectation.

- [ ] **Step 5: Confirm no unrelated file drifted**

```bash
git status --short
```
Expected: only the files this plan names. Nothing under `.wolf/` or `.superpowers/` may be staged.

- [ ] **Step 6: Commit**

```bash
git add TASKS.md docs/Architecture.md apps/graphdb/CLAUDE.md
git commit -m "Docs: record query-traversal Home routing as implemented"
```

---

## Self-Review

**Spec coverage.** Every section of `docs/designs/query-traversal-home-routing-design.md` maps to a task: Half A → Task 1 + Task 2 Step 7; `is_scaffold_node` → Task 2 Step 8; Half B (`home_id`, frontier, visited, target, `#cont_path{}`) → Task 2 Steps 3–7; result shape → Task 3; error handling clause 1 (`arc_target_namespace/3` catch-all) → Task 1 Step 4; clause 2 (`home_of_id/2` via `resume/2`) → Task 4; "what does not change" → Task 2 Step 9's `grep` and Step 11's unmodified-suite requirement; testing T1/T2/T4/T5/T6/T7 → Tasks 1–4; scope boundary → Task 5 Step 1.

**One deliberate deviation.** The design's T3 is not constructible under this scope. Task 4's scope note states why and substitutes T3', which asserts the same Half-B property observably. The design anticipated exactly this outcome and required it be stated rather than papered over.

**Type consistency.** `home_id()` is `environment | {project, integer()}` everywhere — the `.hrl` type, `home_id/1`'s return, `#cont_path{}`'s three fields, `make_edge/6`'s `home` value, and `validate_cont_homes/2`'s `Bound`. `arc_target_namespace/3` returns `environment | Home` (a full Home, not an id); every caller passes it through `home_id/1` before it enters traversal state. `expand_arcs` is `/10` in Tasks 2, 3, and 4 alike.

---

**Plan complete and saved to `docs/superpowers/plans/2026-08-09-query-traversal-home-routing.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.
