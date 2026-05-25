# F3 — graphdb_query Query Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the graphdb_query query layer end-to-end via walking-skeleton pattern: AST in a header, gen_server `graphdb_query` registered locally, snapshot-semantics session, and the seven queries (Q1, Q1b, Q2–Q6) landed one dimension at a time.

**Architecture:** Single gen_server `graphdb_query` (peer to graphdb_mgr/attr/class/instance/language/rules under graphdb_sup). Every Mnesia read goes through `session_read_node/2` and `session_read_arcs/4` helpers that read-through a per-session cache. Sessions are snapshots — `refresh/1` is the only invalidation path. Continuations are opaque records returned by bounded queries (Q6) and tagged with their issuing snapshot so resume can reject mismatches.

**Tech Stack:** Erlang/OTP 28, Mnesia (existing `nodes` and `relationships` tables with secondary indexes), Common Test for integration suites.

**Spec source:** `f3-graphdb-query-design.md` at project root. The plan implements the design verbatim; any conflict between this plan and the design doc means the design doc wins.

---

## File Map

| Action | Path                                                | Role                                                  |
|--------|-----------------------------------------------------|-------------------------------------------------------|
| Modify | `apps/graphdb/src/graphdb_instance.erl`             | Task 0 — extend `resolve_value/2` to return source    |
| Modify | `apps/graphdb/test/graphdb_instance_SUITE.erl`      | Task 0 — update test patterns for new return shape    |
| Modify | `apps/graphdb/src/graphdb_class.erl`                | Task 0 — add `bind_qc_value/3`                        |
| Modify | `apps/graphdb/test/graphdb_class_SUITE.erl`         | Task 0 — tests for `bind_qc_value/3`                  |
| Create | `apps/graphdb/include/graphdb_query.hrl`            | AST records + continuation + session opaque types     |
| Create | `apps/graphdb/src/graphdb_query.erl`                | gen_server: parser, executor, session, all queries    |
| Create | `apps/graphdb/test/graphdb_query_SUITE.erl`         | CT integration tests for every query                  |
| Modify | `apps/graphdb/src/graphdb_sup.erl`                  | Add `graphdb_query` childspec                         |
| Modify | `apps/graphdb/CLAUDE.md`                            | Worker responsibilities — F3 now implemented          |
| Modify | `ARCHITECTURE.md`                                   | §X — query layer description                          |
| Modify | `TASKS.md`                                          | Mark F3 RESOLVED                                      |

---

### Task 0: Extend `resolve_value/2` + add `bind_qc_value/3`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Modify: `apps/graphdb/src/graphdb_class.erl`
- Modify: `apps/graphdb/test/graphdb_class_SUITE.erl`

Prep work that Q4 depends on. Two underlying changes:

1. `graphdb_instance:resolve_value/2` returns `{ok, Value, Source}` instead of `{ok, Value}`. Source is `local | {class, ClassNref} | {compositional, AncNref} | {connected, NodeNref}`. The internal resolver already walks the priority chain — adding the source tag is threading it through, not new logic.
2. `graphdb_class:bind_qc_value/3` lets callers set a class-level value for a declared QC. This is the priority-2 inheritance path; without it, only priorities 1, 3, 4 can be exercised end-to-end.

- [ ] **Step 1: Update the failing test patterns in `graphdb_instance_SUITE.erl`**

Every test case that matches `{ok, V}` from `graphdb_instance:resolve_value/2` must now match `{ok, V, _Source}` (or `{ok, V, Source}` if asserting the source). Update each in place.

The doc comment on `resolve_value/2` (lines around 300 in `graphdb_instance.erl`) should also be updated to describe the 3-tuple return.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE`
Expected: PASS for most tests (you've updated patterns) but **the specific source-asserting cases below will FAIL** because resolve_value/2 still returns the 2-tuple. That's the failing test set we're driving toward.

Add these new source-asserting cases to the suite:

```erlang
resolve_value_source_local(_Config) ->
    {ok, ClassNref}  = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, AttrNref}   = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(ClassNref, AttrNref),
    {ok, InstNref}   = graphdb_instance:create_instance(
                          "Taurus", ClassNref, ?NREF_PROJECTS),
    ok = graphdb_instance:set_avp(InstNref, AttrNref, 3500),
    ?assertEqual({ok, 3500, local},
                 graphdb_instance:resolve_value(InstNref, AttrNref)).

resolve_value_source_class(_Config) ->
    {ok, Veh}    = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, AttrN}  = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN),
    ok = graphdb_class:bind_qc_value(Veh, AttrN, 3500),
    {ok, InstN}  = graphdb_instance:create_instance(
                       "Taurus", Veh, ?NREF_PROJECTS),
    ?assertEqual({ok, 3500, {class, Veh}},
                 graphdb_instance:resolve_value(InstN, AttrN)).
```

> **Implementation discovery.** If `graphdb_instance:set_avp/3` doesn't exist with this exact signature, drop the `set_avp` line and use the existing API for writing instance AVPs (or write directly via Mnesia in the test for setup purposes). The point is the source assertion, not the setup mechanics.

- [ ] **Step 3: Extend `do_resolve_value/2` to thread Source through**

Open `apps/graphdb/src/graphdb_instance.erl` and trace the priority chain in `do_resolve_value/2` (around line 876). Wherever a hit is found, return a 3-tuple instead of `{ok, V}`:

```erlang
%% Priority 1: local
case local_value(InstNref, AttrNref) of
    {ok, V} -> {ok, V, local};
    not_found -> ...
end

%% Priority 2: class-bound
case class_bound_value(ClassNref, AttrNref) of
    {ok, V} -> {ok, V, {class, ClassNref}};
    not_found -> ...
end

%% Priority 3: compositional ancestor
case compositional_value(AncNref, AttrNref) of
    {ok, V} -> {ok, V, {compositional, AncNref}};
    not_found -> ...
end

%% Priority 4: connected node
case connected_value(NodeNref, AttrNref) of
    {ok, V} -> {ok, V, {connected, NodeNref}};
    not_found -> ...
end
```

The exact internal function names are whatever the existing code uses — adapt to fit. The contract change is only at the public `resolve_value/2` return.

- [ ] **Step 4: Add `bind_qc_value/3` to `graphdb_class.erl`**

Public API:

```erlang
%%---------------------------------------------------------------------
%% bind_qc_value(ClassNref, AttrNref, Value) -> ok | {error, term()}
%%
%% Sets the bound value for a declared qualifying characteristic on
%% the class. The QC must already exist (declared via
%% add_qualifying_characteristic/2); calling bind_qc_value/3 on an
%% undeclared QC returns {error, qc_not_declared}.
%%---------------------------------------------------------------------
bind_qc_value(ClassNref, AttrNref, Value) ->
    gen_server:call(?MODULE, {bind_qc_value, ClassNref, AttrNref, Value}).
```

Handle the call by updating the class node's AVP for the matching QC AttrNref. The existing storage shape is `#{attribute => AttrNref, value => Value}` (where Value was `undefined` for declared-but-unbound); writing the new Value in place is the operation.

```erlang
handle_call({bind_qc_value, ClassNref, AttrNref, Value}, _From, State) ->
    {reply, do_bind_qc_value(ClassNref, AttrNref, Value), State};

do_bind_qc_value(ClassNref, AttrNref, Value) ->
    F = fun() ->
        case mnesia:read(nodes, ClassNref) of
            [#node{kind = class, attribute_value_pairs = AVPs} = N] ->
                case lists:any(
                        fun(#{attribute := A}) -> A =:= AttrNref end,
                        AVPs) of
                    false -> mnesia:abort(qc_not_declared);
                    true ->
                        NewAVPs = update_qc_value(AVPs, AttrNref, Value),
                        mnesia:write(nodes,
                            N#node{attribute_value_pairs = NewAVPs},
                            write)
                end;
            [_] -> mnesia:abort(not_a_class);
            []  -> mnesia:abort(not_found)
        end
    end,
    case mnesia:transaction(F) of
        {atomic, ok}      -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

update_qc_value(AVPs, AttrNref, Value) ->
    [case maps:get(attribute, A) of
        AttrNref -> A#{value => Value};
        _        -> A
     end || A <- AVPs].
```

Add `bind_qc_value/3` to the `-export([...])` list.

- [ ] **Step 5: Add CT tests for `bind_qc_value/3`**

Append to `graphdb_class_SUITE.erl`:

```erlang
bind_qc_value_basic(_Config) ->
    {ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, AttrN} = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN),
    ok = graphdb_class:bind_qc_value(Veh, AttrN, 3500),
    {ok, QCs}   = graphdb_class:inherited_qcs(Veh),
    ?assert(lists:member({AttrN, 3500}, QCs)).

bind_qc_value_undeclared_qc(_Config) ->
    {ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, AttrN} = graphdb_attr:create_literal_attribute("weight", number),
    %% Did NOT call add_qualifying_characteristic
    ?assertEqual({error, qc_not_declared},
                 graphdb_class:bind_qc_value(Veh, AttrN, 3500)).

bind_qc_value_updates_existing_binding(_Config) ->
    {ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, AttrN} = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN),
    ok = graphdb_class:bind_qc_value(Veh, AttrN, 3500),
    ok = graphdb_class:bind_qc_value(Veh, AttrN, 4000),
    {ok, QCs}   = graphdb_class:inherited_qcs(Veh),
    ?assert(lists:member({AttrN, 4000}, QCs)),
    ?assertNot(lists:member({AttrN, 3500}, QCs)).
```

Add these case names to the suite's `-export` and into the appropriate group.

- [ ] **Step 6: Run all affected suites**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE`
Expected: PASS — all updated test patterns green; new source-asserting cases green; new bind_qc_value cases green.

Also run the full suite to catch other callers we may have missed:

Run: `./rebar3 ct`
Expected: PASS — any test elsewhere matching `{ok, V}` from `resolve_value/2` needs its pattern updated. Fix on contact.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl \
        apps/graphdb/src/graphdb_class.erl \
        apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "F3 Task 0: resolve_value/2 returns Source; add bind_qc_value/3"
```

---

### Task 1: Create the AST header file

**Files:**
- Create: `apps/graphdb/include/graphdb_query.hrl`

This is a header-only task — no tests, no module changes. The contract surface for everything downstream.

- [ ] **Step 1: Create the header file**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% graphdb_query.hrl -- AST records and opaque types for the query
%% language. Records (not maps) for dialyzer support; matches project
%% style.
%%
%% Design source: f3-graphdb-query-design.md at project root.
%%---------------------------------------------------------------------

-ifndef(GRAPHDB_QUERY_HRL).
-define(GRAPHDB_QUERY_HRL, 1).

%% -- Arc kind atoms (mirror relationship.kind values) -----------------
-type arc_kind() :: composition | taxonomy | connection | instantiation.

%% -- Language spec (Q2-Q4 label resolution) ---------------------------
-type language_spec() :: default | {language, LangNref :: integer()}.

%% -- AST records ------------------------------------------------------

%% Q1 — get_node : raw node record by nref
-record(q_get_node, {
    nref :: integer()
}).

%% Q1b — get_arcs : arcs at nref, filtered by direction + kind
-record(q_get_arcs, {
    nref      :: integer(),
    direction :: outgoing | incoming | both,
    arc_kinds :: all | [arc_kind()]
}).

%% Q2/Q3/Q4 — describe : dispatched in executor by looked-up node kind
-record(q_describe, {
    nref   :: integer(),
    labels :: language_spec()
}).

%% Q5 — list_instances_of : all instances of class (optionally recursive)
-record(q_instances_of, {
    class     :: integer(),
    recursive :: boolean()
}).

%% Q6 — find_path : bounded BFS, optionally restricted to arc kinds
-record(q_find_path, {
    from      :: integer(),
    to        :: integer(),
    max_depth :: pos_integer(),
    arc_kinds :: [arc_kind()]
}).

%% -- Continuation -----------------------------------------------------
%% Returned by bounded queries (currently only Q6). Tagged with the
%% snapshot it was issued against; resuming with a mismatched session
%% returns {error, snapshot_expired}.
-record(cont_path, {
    snapshot_at      :: erlang:timestamp(),
    target           :: integer(),
    arc_kinds        :: [arc_kind()],
    remaining_depth  :: non_neg_integer(),
    visited          :: #{integer() => true},
    %% [{Nref, PathToHere}] — frontier nodes to expand on resume
    frontier         :: [{integer(), [map()]}]
}).

-endif.
```

- [ ] **Step 2: Compile to verify**

Run: `./rebar3 compile`
Expected: PASS — zero warnings (no functions yet, just record definitions).

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/include/graphdb_query.hrl
git commit -m "F3 Task 1: graphdb_query.hrl -- AST records, types, continuation"
```

---

### Task 2: Module skeleton + session API + sup wiring

**Files:**
- Create: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/src/graphdb_sup.erl`
- Create: `apps/graphdb/test/graphdb_query_SUITE.erl`

The skeleton has: `start_link/0`, `parse_query/1` (identity), `new_session/0`, `refresh/1`, `execute_query/1`, `execute_query/2`, `resume/2`. All execute paths return `{error, not_implemented}` except the session API (which is real). Sup wiring lets it boot with the rest of graphdb.

- [ ] **Step 1: Write the failing CT smoke test**

Create `apps/graphdb/test/graphdb_query_SUITE.erl`:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Common Test integration suite for graphdb_query.
%% Each testcase gets an isolated tmp dir + fresh Mnesia + fresh nref
%% allocator + fully started graphdb supervision tree.
%%---------------------------------------------------------------------
-module(graphdb_query_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").
-include_lib("graphdb/include/graphdb_query.hrl").

-export([all/0, groups/0, suite/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    %% skeleton
    starts_and_is_registered/1,
    parse_query_is_identity/1,
    new_session_has_snapshot/1,
    refresh_bumps_snapshot/1,
    unimplemented_query_returns_error/1
]).

suite() -> [{timetrap, {seconds, 30}}].

all() -> [{group, skeleton}].

groups() ->
    [{skeleton, [], [
        starts_and_is_registered,
        parse_query_is_identity,
        new_session_has_snapshot,
        refresh_bumps_snapshot,
        unimplemented_query_returns_error
    ]}].

init_per_suite(Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    ok = ensure_loaded(graphdb),
    PrivDir = code:priv_dir(graphdb),
    BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
    true = filelib:is_file(BootstrapFile),
    [{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Config1 = setup_isolated_env(Config),
    BootstrapFile = proplists:get_value(bootstrap_file, Config),
    application:set_env(seerstone_graph_db, bootstrap_file, BootstrapFile),
    {ok, _} = rel_id_server:start_link(),
    {ok, _} = graphdb_mgr:start_link(),
    {ok, _} = graphdb_attr:start_link(),
    {ok, _} = graphdb_class:start_link(),
    {ok, _} = graphdb_instance:start_link(),
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_query:start_link(),
    Config1.

setup_isolated_env(Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
        "query_" ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    [{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].

end_per_testcase(TC, Config) ->
    verify_cache_invariant(TC),
    catch gen_server:stop(graphdb_query),
    catch gen_server:stop(graphdb_language),
    catch gen_server:stop(graphdb_instance),
    catch gen_server:stop(graphdb_class),
    catch gen_server:stop(graphdb_attr),
    catch gen_server:stop(graphdb_mgr),
    catch gen_server:stop(rel_id_server),
    catch application:stop(nref),
    catch mnesia:stop(),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    catch dets:close(rel_id_server),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    application:unset_env(seerstone_graph_db, bootstrap_file),
    application:unset_env(mnesia, dir),
    ok.

verify_cache_invariant(TC) ->
    case mnesia:system_info(is_running) of
        yes ->
            case graphdb_mgr:verify_caches() of
                ok -> ok;
                {error, M} ->
                    ct:pal("Cache invariant failed in ~p:~n~p", [TC, M]),
                    ct:fail({cache_invariant_failed, TC, M})
            end;
        _ -> ok
    end.

ensure_loaded(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, _}} -> ok;
        {error, R} -> exit({failed_to_load, App, R})
    end.

delete_dir_recursive(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(N) ->
                P = filename:join(Dir, N),
                case filelib:is_dir(P) of
                    true -> delete_dir_recursive(P);
                    false -> file:delete(P)
                end
            end, Names),
            file:del_dir(Dir);
        {error, enoent} -> ok;
        {error, _} -> ok
    end.

%%-- Skeleton tests ---------------------------------------------------

starts_and_is_registered(_Config) ->
    ?assert(is_pid(whereis(graphdb_query))).

parse_query_is_identity(_Config) ->
    Q = #q_get_node{nref = 1},
    ?assertEqual(Q, graphdb_query:parse_query(Q)).

new_session_has_snapshot(_Config) ->
    S = graphdb_query:new_session(),
    ?assert(is_map(S)),
    ?assert(maps:is_key(snapshot_at, S)),
    ?assert(maps:is_key(cache, S)),
    ?assertEqual(#{}, maps:get(cache, S)).

refresh_bumps_snapshot(_Config) ->
    S1 = graphdb_query:new_session(),
    %% Force a different timestamp by sleeping past os:timestamp() resolution
    timer:sleep(2),
    S2 = graphdb_query:refresh(S1),
    ?assertNotEqual(maps:get(snapshot_at, S1),
                    maps:get(snapshot_at, S2)),
    ?assertEqual(#{}, maps:get(cache, S2)).

unimplemented_query_returns_error(_Config) ->
    %% Any unhandled query shape should yield {error, not_implemented}
    %% — Q5 is not landed yet (Task 8), use it as a placeholder.
    Q = #q_instances_of{class = ?NREF_CLASSES, recursive = false},
    ?assertEqual({error, not_implemented},
                 graphdb_query:execute_query(Q)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: FAIL — `graphdb_query` module does not exist.

- [ ] **Step 3: Create the graphdb_query module skeleton**

Create `apps/graphdb/src/graphdb_query.erl`:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Description: graphdb_query is the query-language gen_server. It
%%              parses and executes queries against the graph;
%%              maintains snapshot-semantics sessions with a
%%              read-through cache.
%%
%% Design source: f3-graphdb-query-design.md at project root.
%%---------------------------------------------------------------------
-module(graphdb_query).
-behaviour(gen_server).

-revision('Revision: A ').
-created('Date: May 2026').
-created_by('david@davidwt.com').

-include_lib("graphdb/include/graphdb_nrefs.hrl").
-include_lib("graphdb/include/graphdb_query.hrl").

-define(NYI(X), (begin
                    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
                    exit(nyi)
                 end)).
-define(UEM(F, X), (begin
                    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
                    exit(uem)
                 end)).

%% Mirror of the canonical record shapes (see ARCHITECTURE.md §3).
-record(node, {
    nref,
    kind,
    parents               = [],
    classes               = [],
    attribute_value_pairs
}).

-record(relationship, {
    id,
    kind,
    source_nref,
    characterization,
    target_nref,
    reciprocal,
    avps
}).

%%---------------------------------------------------------------------
%% Public API
%%---------------------------------------------------------------------
-export([start_link/0]).
-export([
    parse_query/1,
    new_session/0,
    refresh/1,
    execute_query/1,
    execute_query/2,
    resume/2,
    find_path/3
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%---------------------------------------------------------------------
%% Public API implementation
%%---------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Parser is the identity until a text DSL lands.
parse_query(Term) -> Term.

new_session() ->
    #{snapshot_at => os:timestamp(),
      cache       => #{}}.

refresh(Session) when is_map(Session) ->
    Session#{snapshot_at := os:timestamp(),
             cache       := #{}}.

execute_query(Query) ->
    gen_server:call(?MODULE, {execute_query_1, Query}).

execute_query(Query, Session) when is_map(Session) ->
    gen_server:call(?MODULE, {execute_query_2, Query, Session}).

resume(Cont, Session) when is_map(Session) ->
    gen_server:call(?MODULE, {resume, Cont, Session}).

%% find_path/3 — public convenience matching the F3 task spec API.
find_path(From, To, MaxDepth) ->
    execute_query(#q_find_path{from      = From,
                               to        = To,
                               max_depth = MaxDepth,
                               arc_kinds = [composition, taxonomy,
                                            connection]}).

%%---------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------

init([]) ->
    {ok, #{}}.

handle_call({execute_query_1, Query}, _From, State) ->
    Session = new_session(),
    {Reply, _Session1} = dispatch(Query, Session),
    {reply, drop_session(Reply), State};
handle_call({execute_query_2, Query, Session}, _From, State) ->
    {Reply, Session1} = dispatch(Query, Session),
    {reply, attach_session(Reply, Session1), State};
handle_call({resume, _Cont, _Session}, _From, State) ->
    {reply, {error, not_implemented}, State};
handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?UEM(handle_cast, {Msg, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%---------------------------------------------------------------------
%% Internal dispatch
%%---------------------------------------------------------------------

%% dispatch(Query, Session) -> {Reply, Session1}
%% Reply is {ok, _} | {ok, _, _} | {partial, _, _} | {error, _}.
dispatch(_Query, Session) ->
    {{error, not_implemented}, Session}.

%% drop_session — for /1 calls, strip the trailing session from the reply.
drop_session({ok, R, _S})            -> {ok, R};
drop_session({partial, R, C, _S})    -> {partial, R, C};
drop_session(Other)                  -> Other.

%% attach_session — for /2 calls, add the session to the reply tail.
attach_session({error, _} = E, _S)   -> E;
attach_session({ok, R}, S)           -> {ok, R, S};
attach_session({partial, R, C}, S)   -> {partial, R, C, S};
attach_session({ok, R, _}, S)        -> {ok, R, S};
attach_session({partial, R, C, _}, S) -> {partial, R, C, S}.
```

- [ ] **Step 4: Wire into graphdb_sup**

In `apps/graphdb/src/graphdb_sup.erl`, change the `init/1` clause:

```erlang
init([]) ->
    Restart_Strategy = one_for_one,
    MaxR = 5,
    MaxT = 5000,
    SupFlags = {Restart_Strategy, MaxR, MaxT},
    {ok, ChSpec0} = childspec(rel_id_server),
    {ok, ChSpec1} = childspec(graphdb_mgr),
    {ok, ChSpec2} = childspec(graphdb_rules),
    {ok, ChSpec3} = childspec(graphdb_attr),
    {ok, ChSpec4} = childspec(graphdb_class),
    {ok, ChSpec5} = childspec(graphdb_instance),
    {ok, ChSpec6} = childspec(graphdb_language),
    {ok, ChSpec7} = childspec(graphdb_query),
    {ok, {SupFlags, [ChSpec0, ChSpec1, ChSpec2, ChSpec3,
                     ChSpec4, ChSpec5, ChSpec6, ChSpec7]}};
init(State) ->
    ?NYI({init, {State}}),
    ignore.
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — 5/5 cases green.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/src/graphdb_sup.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 2: graphdb_query skeleton + sup wiring + smoke tests"
```

---

### Task 3: Q1 — get_node (the walking skeleton)

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q1 forces every layer of the pipeline (parse → dispatch → executor → reply) to exist for the smallest possible query. Adds `session_read_node/2` (the read-through helper) and the first executor clause.

- [ ] **Step 1: Add the failing test cases**

Append to the `-export` list in the suite:

```erlang
    %% Q1 — get_node
    q1_returns_bootstrap_node/1,
    q1_returns_attribute_node/1,
    q1_not_found_returns_error/1,
    q1_session_form_returns_session/1,
    q1_cache_populates_on_read/1
```

Add a new group:

```erlang
all() -> [{group, skeleton}, {group, q1_get_node}].

groups() ->
    [{skeleton, [], [...]},   %% existing
     {q1_get_node, [], [
        q1_returns_bootstrap_node,
        q1_returns_attribute_node,
        q1_not_found_returns_error,
        q1_session_form_returns_session,
        q1_cache_populates_on_read
     ]}].
```

Add the test bodies at the bottom of the file:

```erlang
q1_returns_bootstrap_node(_Config) ->
    {ok, Node} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}),
    ?assertEqual(?NREF_ROOT, maps:get(nref, Node)),
    ?assertEqual(category,   maps:get(kind, Node)),
    %% Root has no parents
    ?assertEqual([], maps:get(parents, Node)),
    ?assertEqual([], maps:get(classes, Node)),
    ?assert(is_list(maps:get(attribute_value_pairs, Node))).

q1_returns_attribute_node(_Config) ->
    {ok, Node} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_NAMES}),
    ?assertEqual(?NREF_NAMES, maps:get(nref, Node)),
    ?assertEqual(attribute,   maps:get(kind, Node)),
    ?assertEqual([?NREF_ATTRIBUTES], maps:get(parents, Node)).

q1_not_found_returns_error(_Config) ->
    ?assertEqual({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_get_node{nref = 9999999})).

q1_session_form_returns_session(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, Node, S1} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S0),
    ?assertEqual(?NREF_ROOT, maps:get(nref, Node)),
    ?assert(is_map(S1)),
    %% Snapshot_at must survive — refresh did not happen
    ?assertEqual(maps:get(snapshot_at, S0),
                 maps:get(snapshot_at, S1)).

q1_cache_populates_on_read(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, _Node, S1} = graphdb_query:execute_query(
        #q_get_node{nref = ?NREF_ROOT}, S0),
    Cache = maps:get(cache, S1),
    ?assert(maps:is_key({node, ?NREF_ROOT}, Cache)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q1_get_node`
Expected: FAIL — `not_implemented` returned for `#q_get_node{}`.

- [ ] **Step 3: Implement Q1 in graphdb_query.erl**

Replace `dispatch/2` and add the helper + projection:

```erlang
%%---------------------------------------------------------------------
%% Internal dispatch
%%---------------------------------------------------------------------

dispatch(#q_get_node{nref = N}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {Node, Session1} ->
            {{ok, node_to_map(Node)}, Session1}
    end;
dispatch(_Query, Session) ->
    {{error, not_implemented}, Session}.

%%---------------------------------------------------------------------
%% session_read_node(Session, Nref) -> {Node | not_found, Session1}
%%
%% Read-through cache: cache hit returns immediately; miss reads
%% Mnesia and populates the cache before returning. The cache key
%% is {node, Nref}.
%%---------------------------------------------------------------------
session_read_node(#{cache := Cache} = Session, Nref) ->
    case maps:get({node, Nref}, Cache, miss) of
        miss ->
            case mnesia:dirty_read(nodes, Nref) of
                [Node] ->
                    Cache1 = Cache#{{node, Nref} => Node},
                    {Node, Session#{cache := Cache1}};
                [] ->
                    Cache1 = Cache#{{node, Nref} => not_found},
                    {not_found, Session#{cache := Cache1}}
            end;
        not_found ->
            {not_found, Session};
        Node ->
            {Node, Session}
    end.

%%---------------------------------------------------------------------
%% node_to_map(Node) -> map()
%%
%% Project a #node{} record into the public result shape.
%%---------------------------------------------------------------------
node_to_map(#node{nref                  = N,
                  kind                  = K,
                  parents               = P,
                  classes               = C,
                  attribute_value_pairs = AVPs}) ->
    #{nref                  => N,
      kind                  => K,
      parents               => P,
      classes               => C,
      attribute_value_pairs => AVPs}.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — 5 skeleton + 5 Q1 = 10/10 cases green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 3: Q1 get_node -- walking skeleton end-to-end"
```

---

### Task 4: Q1b — get_arcs

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q1b reads the `relationships` table via the secondary indexes. Adds `session_read_arcs/4` and a direction/kind filter.

- [ ] **Step 1: Add failing test cases**

Append to the suite's `-export`:

```erlang
    %% Q1b — get_arcs
    q1b_outgoing_all_kinds/1,
    q1b_incoming_all_kinds/1,
    q1b_both_directions/1,
    q1b_kind_filter_taxonomy_only/1,
    q1b_nref_with_no_arcs/1,
    q1b_cache_uses_dir_kind_key/1
```

Add the group:

```erlang
all() -> [{group, skeleton}, {group, q1_get_node}, {group, q1b_get_arcs}].

groups() ->
    [...,
     {q1b_get_arcs, [], [
        q1b_outgoing_all_kinds,
        q1b_incoming_all_kinds,
        q1b_both_directions,
        q1b_kind_filter_taxonomy_only,
        q1b_nref_with_no_arcs,
        q1b_cache_uses_dir_kind_key
     ]}].
```

Test bodies:

```erlang
q1b_outgoing_all_kinds(_Config) ->
    %% NREF_ATTRIBUTES (2) is the parent of NREF_NAMES (6), NREF_LITERALS
    %% (7), NREF_RELATIONSHIPS (8). Outgoing arcs from 2 include three
    %% ARC_CAT_CHILD arcs (composition).
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref      = ?NREF_ATTRIBUTES,
                    direction = outgoing,
                    arc_kinds = all}),
    ?assert(is_list(Arcs)),
    ChildArcs = [A || A <- Arcs,
                      maps:get(characterization, A) =:= ?ARC_CAT_CHILD],
    ?assert(length(ChildArcs) >= 3),
    %% Every arc has the expected projected keys
    [?assertMatch(#{id := _, kind := _, source_nref := _,
                    characterization := _, target_nref := _,
                    reciprocal := _, avps := _}, A) || A <- Arcs].

q1b_incoming_all_kinds(_Config) ->
    %% NREF_NAMES (6) has one incoming child arc from NREF_ATTRIBUTES (2).
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref      = ?NREF_NAMES,
                    direction = incoming,
                    arc_kinds = all}),
    ParentArcs = [A || A <- Arcs,
                       maps:get(characterization, A) =:= ?ARC_CAT_CHILD],
    ?assertEqual(1, length(ParentArcs)),
    [#{source_nref := Src}] = ParentArcs,
    ?assertEqual(?NREF_ATTRIBUTES, Src).

q1b_both_directions(_Config) ->
    %% NREF_NAMES has 1 incoming + several outgoing (to 9, 10, 11, 12).
    {ok, ArcsOut} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = outgoing,
                    arc_kinds = all}),
    {ok, ArcsIn}  = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = incoming,
                    arc_kinds = all}),
    {ok, ArcsBoth} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_NAMES, direction = both,
                    arc_kinds = all}),
    ?assertEqual(length(ArcsOut) + length(ArcsIn),
                 length(ArcsBoth)).

q1b_kind_filter_taxonomy_only(_Config) ->
    %% NREF_LITERALS (7) — its outgoing arcs to children are taxonomy
    %% (chars 23/24).
    {ok, TaxArcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_LITERALS, direction = outgoing,
                    arc_kinds = [taxonomy]}),
    {ok, AllArcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_LITERALS, direction = outgoing,
                    arc_kinds = all}),
    ?assertEqual(length(TaxArcs),
                 length([A || A <- AllArcs,
                              maps:get(kind, A) =:= taxonomy])).

q1b_nref_with_no_arcs(_Config) ->
    %% An unknown nref simply yields an empty list, not an error.
    {ok, Arcs} = graphdb_query:execute_query(
        #q_get_arcs{nref = 9999999, direction = outgoing,
                    arc_kinds = all}),
    ?assertEqual([], Arcs).

q1b_cache_uses_dir_kind_key(_Config) ->
    S0 = graphdb_query:new_session(),
    {ok, _, S1} = graphdb_query:execute_query(
        #q_get_arcs{nref = ?NREF_ROOT, direction = outgoing,
                    arc_kinds = all}, S0),
    Cache = maps:get(cache, S1),
    Key = {arcs, ?NREF_ROOT, outgoing, all},
    ?assert(maps:is_key(Key, Cache)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q1b_get_arcs`
Expected: FAIL — `not_implemented`.

- [ ] **Step 3: Implement Q1b in graphdb_query.erl**

Add a new dispatch clause and the read-through helper. Insert the Q1b clause before the catch-all:

```erlang
dispatch(#q_get_arcs{nref = N, direction = Dir, arc_kinds = Kinds},
         Session) ->
    {Arcs, Session1} = session_read_arcs(Session, N, Dir, Kinds),
    {{ok, [arc_to_map(A) || A <- Arcs]}, Session1};
```

Add the helper after `session_read_node/2`:

```erlang
%%---------------------------------------------------------------------
%% session_read_arcs(Session, Nref, Direction, KindFilter)
%%     -> {[#relationship{}], Session1}
%%
%% Cache key is {arcs, Nref, Direction, KindFilter} — the filter is
%% part of the key because filters with different shapes are not
%% interchangeable. (Heuristic refinement deferred until needed.)
%%---------------------------------------------------------------------
session_read_arcs(#{cache := Cache} = Session, Nref, Dir, Kinds) ->
    Key = {arcs, Nref, Dir, Kinds},
    case maps:get(Key, Cache, miss) of
        miss ->
            Arcs = read_arcs(Nref, Dir, Kinds),
            Cache1 = Cache#{Key => Arcs},
            {Arcs, Session#{cache := Cache1}};
        Cached ->
            {Cached, Session}
    end.

read_arcs(Nref, outgoing, Kinds) ->
    Raw = mnesia:dirty_index_read(relationships, Nref,
                                  #relationship.source_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Nref, incoming, Kinds) ->
    Raw = mnesia:dirty_index_read(relationships, Nref,
                                  #relationship.target_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Nref, both, Kinds) ->
    read_arcs(Nref, outgoing, Kinds) ++ read_arcs(Nref, incoming, Kinds).

filter_kinds(Arcs, all) -> Arcs;
filter_kinds(Arcs, Kinds) when is_list(Kinds) ->
    [A || A <- Arcs, lists:member(A#relationship.kind, Kinds)].

arc_to_map(#relationship{id               = Id,
                         kind             = K,
                         source_nref      = S,
                         characterization = C,
                         target_nref      = T,
                         reciprocal       = R,
                         avps             = AVPs}) ->
    #{id               => Id,
      kind             => K,
      source_nref      => S,
      characterization => C,
      target_nref      => T,
      reciprocal       => R,
      avps             => AVPs}.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 4: Q1b get_arcs -- relationships table via index reads"
```

---

### Task 5: Q2 — describe_attribute

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q2 composes Q1 + Q1b plus M6 label resolution. Dispatches `#q_describe{}` queries by reading the node's `kind` first and routing to a kind-specific helper. Q2 handles `kind = attribute`. Q3/Q4 will piggy-back on the same dispatch later.

- [ ] **Step 1: Add failing test cases**

Append to `-export`:

```erlang
    %% Q2 — describe_attribute
    q2_describes_name_attribute/1,
    q2_includes_parent_and_taxonomy/1,
    q2_includes_labels_default_english/1,
    q2_not_found_returns_error/1,
    q2_rejects_non_attribute_nref/1
```

Group:

```erlang
{q2_describe_attribute, [], [
    q2_describes_name_attribute,
    q2_includes_parent_and_taxonomy,
    q2_includes_labels_default_english,
    q2_not_found_returns_error,
    q2_rejects_non_attribute_nref
]}
```

Test bodies:

```erlang
q2_describes_name_attribute(_Config) ->
    %% NREF_NAMES (6) is an attribute node, child of NREF_ATTRIBUTES.
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    ?assertEqual(?NREF_NAMES, maps:get(nref, R)),
    ?assertEqual(attribute,   maps:get(kind, R)),
    ?assertEqual(?NREF_ATTRIBUTES, maps:get(parent, R)).

q2_includes_parent_and_taxonomy(_Config) ->
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    Children = maps:get(children, R),
    ?assert(is_list(Children)),
    %% Names has children 9, 10, 11, 12 (NameAttr subcategories)
    ?assert(lists:member(?NREF_CAT_NAME_ATTRS, Children)),
    ?assert(lists:member(?NREF_INST_NAME_ATTRS, Children)).

q2_includes_labels_default_english(_Config) ->
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = ?NREF_NAMES, labels = default}),
    Labels = maps:get(labels, R),
    ?assert(is_map(Labels)),
    ?assert(maps:is_key(?NREF_NAMES, Labels)),
    ?assert(is_list(maps:get(?NREF_NAMES, Labels))).

q2_not_found_returns_error(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).

q2_rejects_non_attribute_nref(_Config) ->
    %% NREF_ROOT is a category — Q2 path is for attributes only.
    %% Categories take the category branch (no describe yet).
    {error, {unsupported_kind, category}} =
        graphdb_query:execute_query(
            #q_describe{nref = ?NREF_ROOT, labels = default}).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q2_describe_attribute`
Expected: FAIL — describe not implemented.

- [ ] **Step 3: Implement Q2 in graphdb_query.erl**

Add the describe dispatch clause and the attribute-specific helper:

```erlang
dispatch(#q_describe{nref = N, labels = Lang}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {#node{kind = attribute} = Node, Session1} ->
            describe_attribute(Node, Lang, Session1);
        {#node{kind = Kind}, Session1} ->
            {{error, {unsupported_kind, Kind}}, Session1}
    end;
```

Helper functions (place after `arc_to_map/1`):

```erlang
%%---------------------------------------------------------------------
%% describe_attribute(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%---------------------------------------------------------------------
describe_attribute(#node{nref = N, parents = Parents,
                          attribute_value_pairs = AVPs}, LangSpec,
                   Session) ->
    %% Taxonomy parent is the head of the parents cache list (single-chain).
    Parent = case Parents of
        [P | _] -> P;
        []      -> undefined
    end,
    {ChildArcs, Session1} = session_read_arcs(Session, N, incoming,
                                              [taxonomy]),
    Children = [A#relationship.source_nref || A <- ChildArcs,
        A#relationship.characterization =:= ?ARC_ATTR_CHILD],
    AttrType = avp_value_of(AVPs, attribute_type_marker(Session1)),
    {Labels, Session2} = resolve_labels([N, Parent | Children], LangSpec,
                                        Session1),
    Result = #{nref           => N,
               kind           => attribute,
               attribute_type => AttrType,
               parent         => Parent,
               children       => Children,
               avps           => AVPs,
               labels         => Labels},
    {{ok, Result}, Session2}.

%%---------------------------------------------------------------------
%% attribute_type_marker(Session) -> integer() | undefined
%%
%% Caches the seeded attribute_type nref on the session for repeated use.
%%---------------------------------------------------------------------
attribute_type_marker(#{cache := Cache} = _Session) ->
    case maps:get({seeded, attribute_type}, Cache, miss) of
        miss      -> safe_seeded_attribute_type();
        Cached    -> Cached
    end.

safe_seeded_attribute_type() ->
    try
        {ok, #{attribute_type := At}} = graphdb_attr:seeded_nrefs(),
        At
    catch _:_ -> undefined
    end.

%%---------------------------------------------------------------------
%% avp_value_of(AVPs, undefined | AttrNref) -> term() | undefined
%%---------------------------------------------------------------------
avp_value_of(_AVPs, undefined) -> undefined;
avp_value_of(AVPs, AttrNref) ->
    case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
        {value, #{value := V}} -> V;
        false                  -> undefined
    end.

%%---------------------------------------------------------------------
%% resolve_labels(Nrefs, LangSpec, Session) -> {LabelMap, Session1}
%%
%% Resolves a label for every nref via graphdb_language.  For
%% LangSpec = default, uses base-language English. For
%% {language, LangNref}, looks up the registered chain.
%%---------------------------------------------------------------------
resolve_labels(Nrefs, LangSpec, Session) ->
    Chain = label_chain(LangSpec),
    Map = lists:foldl(fun
        (undefined, Acc) -> Acc;
        (N, Acc) when is_integer(N) ->
            case resolve_one_label(N, Chain) of
                undefined -> Acc;
                Label     -> Acc#{N => Label}
            end
    end, #{}, Nrefs),
    {Map, Session}.

label_chain(default)               -> [en];
label_chain({language, LangNref})  ->
    case lookup_chain_for_nref(LangNref) of
        [] -> [en];
        L  -> L
    end.

lookup_chain_for_nref(LangNref) ->
    %% Translates a language Nref to a code, then asks
    %% graphdb_language:make_chain/1. Simplified for now: returns
    %% [en] as default chain. Future build-out replaces this.
    _ = LangNref,
    [en].

resolve_one_label(Nref, Chain) ->
    NameAttr = name_attr_for_node(Nref),
    case graphdb_language:resolve_label(Nref, NameAttr, Chain, environment) of
        {ok, Label} -> Label;
        not_found   -> undefined
    end.

%%---------------------------------------------------------------------
%% name_attr_for_node(Nref) -> integer()
%%
%% Returns the appropriate NAME_ATTR_* for the node based on its kind.
%% Reads through dirty_read for kind detection.
%%---------------------------------------------------------------------
name_attr_for_node(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = category}]  -> ?NAME_ATTR_CATEGORY;
        [#node{kind = attribute}] -> ?NAME_ATTR_ATTRIBUTE;
        [#node{kind = class}]     -> ?NAME_ATTR_CLASS;
        [#node{kind = instance}]  -> ?NAME_ATTR_INSTANCE;
        _                         -> ?NAME_ATTR_CATEGORY
    end.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 5: Q2 describe_attribute -- taxonomy + label resolution"
```

---

### Task 6: Q3 — describe_class

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q3 extends the describe dispatch to `kind = class`. Calls existing `graphdb_class:ancestors/1` and `graphdb_class:subclasses/1`. QC inheritance via existing `graphdb_class:inherited_qcs/1`. Test cases set up runtime classes under the bootstrap `?NREF_CLASSES` category.

> **API note.** `graphdb_class:ancestors/1` and `subclasses/1` return `{ok, [#node{}]}` — node records, not nrefs. The Q3 implementation projects to nrefs at the call site.

> **Result shape note.** The design doc shows `qualifying_characteristics` split into `own` and `inherited` with a `from` tag on each inherited entry. The existing `graphdb_class:inherited_qcs/1` returns a flat `[{AttrNref, Value}]` list without origin tagging. For F3 v1, Q3 surfaces the flat list directly; the own/inherited+origin split is a deferred enhancement (would require a new `graphdb_class:inherited_qcs_with_origin/1` helper).

- [ ] **Step 1: Add failing test cases**

Append to `-export`:

```erlang
    %% Q3 — describe_class
    q3_describes_class_with_superclasses/1,
    q3_lists_subclasses/1,
    q3_includes_qcs_flat_list/1,
    q3_class_not_found/1
```

Group:

```erlang
{q3_describe_class, [], [
    q3_describes_class_with_superclasses,
    q3_lists_subclasses,
    q3_includes_qcs_flat_list,
    q3_class_not_found
]}
```

Test bodies:

```erlang
q3_describes_class_with_superclasses(_Config) ->
    %% Build: Classes <- Vehicle <- Car
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car", Vehicle),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Car, labels = default}),
    ?assertEqual(Car,       maps:get(nref, R)),
    ?assertEqual(class,     maps:get(kind, R)),
    ?assertEqual([Vehicle], maps:get(superclasses, R)),
    ?assert(lists:member(Vehicle, maps:get(ancestors, R))).

q3_lists_subclasses(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car",   Vehicle),
    {ok, Truck}   = graphdb_class:create_class("Truck", Vehicle),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Vehicle, labels = default}),
    Subs = maps:get(subclasses, R),
    ?assert(lists:member(Car,   Subs)),
    ?assert(lists:member(Truck, Subs)).

q3_includes_qcs_flat_list(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}     = graphdb_class:create_class("Car",   Vehicle),
    {ok, WeightA} = graphdb_attr:create_literal_attribute("weight", number),
    {ok, ColorA}  = graphdb_attr:create_literal_attribute("color",  string),
    ok = graphdb_class:add_qualifying_characteristic(Vehicle, WeightA),
    ok = graphdb_class:add_qualifying_characteristic(Car, ColorA),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Car, labels = default}),
    QCs = maps:get(qualifying_characteristics, R),
    %% Flat [{AttrNref, Value}] list; both Color (own) and Weight
    %% (inherited from Vehicle) appear, each with Value=undefined
    %% because no binding was set.
    ?assert(lists:member({ColorA,  undefined}, QCs)),
    ?assert(lists:member({WeightA, undefined}, QCs)).

q3_class_not_found(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q3_describe_class`
Expected: FAIL — `{unsupported_kind, class}`.

- [ ] **Step 3: Implement Q3 by extending the describe dispatch**

Add a class branch to the describe clause:

```erlang
dispatch(#q_describe{nref = N, labels = Lang}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {#node{kind = attribute} = Node, Session1} ->
            describe_attribute(Node, Lang, Session1);
        {#node{kind = class} = Node, Session1} ->
            describe_class(Node, Lang, Session1);
        {#node{kind = Kind}, Session1} ->
            {{error, {unsupported_kind, Kind}}, Session1}
    end;
```

Add the `describe_class` helper:

```erlang
%%---------------------------------------------------------------------
%% describe_class(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%---------------------------------------------------------------------
describe_class(#node{nref = N, parents = Parents,
                      attribute_value_pairs = AVPs}, LangSpec,
               Session) ->
    Superclasses = Parents,
    {ok, AncestorNodes} = graphdb_class:ancestors(N),
    {ok, SubclassNodes} = graphdb_class:subclasses(N),
    {ok, QCs}           = graphdb_class:inherited_qcs(N),
    Ancestors  = [Nd#node.nref || Nd <- AncestorNodes],
    Subclasses = [Nd#node.nref || Nd <- SubclassNodes],
    QCAttrs    = [A || {A, _Value} <- QCs],
    AllNrefs = lists:usort([N] ++ Superclasses ++ Ancestors
                           ++ Subclasses ++ QCAttrs),
    {Labels, Session1} = resolve_labels(AllNrefs, LangSpec, Session),
    Result = #{nref                       => N,
               kind                       => class,
               superclasses               => Superclasses,
               ancestors                  => Ancestors,
               subclasses                 => Subclasses,
               qualifying_characteristics => QCs,   %% [{AttrNref, Value}]
               avps                       => AVPs,
               labels                     => Labels},
    {{ok, Result}, Session1}.
```

- [ ] **Step 4: Run the suite**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 6: Q3 describe_class -- taxonomy + QC inheritance"
```

---

### Task 7: Q4 — describe_instance

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q4 extends the describe dispatch to `kind = instance`. Uses `graphdb_instance:resolve_value/2` for 4-priority inheritance, now returning `{ok, Value, Source}` after Task 0. Surfaces both outgoing and incoming connections (the design doc's three reasons: per-direction AVPs, per-direction row IDs, epistemic stance).

> **API notes.**
> - `graphdb_instance:compositional_ancestors/1` returns `{ok, [#node{}]}` — projection to nrefs needed at call site.
> - `graphdb_class:ancestors/1` returns `{ok, [#node{}]}` — same.
> - `graphdb_instance:resolve_value/2` returns `{ok, Value, Source}` (after Task 0) where `Source :: local | {class, N} | {compositional, N} | {connected, N}`.
> - Test setup uses `?NREF_PROJECTS` (5) as the top-level compositional parent for instances under a project root, matching the project convention.

- [ ] **Step 1: Add failing test cases**

Append to `-export`:

```erlang
    %% Q4 — describe_instance
    q4_describes_instance_with_class/1,
    q4_resolves_inherited_attributes/1,
    q4_outgoing_and_incoming_connections/1,
    q4_compositional_ancestors/1,
    q4_instance_not_found/1
```

Group:

```erlang
{q4_describe_instance, [], [
    q4_describes_instance_with_class,
    q4_resolves_inherited_attributes,
    q4_outgoing_and_incoming_connections,
    q4_compositional_ancestors,
    q4_instance_not_found
]}
```

Test bodies:

```erlang
q4_describes_instance_with_class(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Taurus}  = graphdb_instance:create_instance(
                       "Taurus", Vehicle, ?NREF_PROJECTS),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}),
    ?assertEqual(instance,  maps:get(kind, R)),
    ?assertEqual([Vehicle], maps:get(classes, R)),
    ?assert(lists:member(Vehicle, maps:get(class_ancestors, R))).

q4_resolves_inherited_attributes(_Config) ->
    {ok, Vehicle} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, WeightA} = graphdb_attr:create_literal_attribute("weight", number),
    ok = graphdb_class:add_qualifying_characteristic(Vehicle, WeightA),
    %% Bind a class-level value (Task 0 adds bind_qc_value/3)
    ok = graphdb_class:bind_qc_value(Vehicle, WeightA, 3500),
    {ok, Taurus} = graphdb_instance:create_instance(
                      "Taurus", Vehicle, ?NREF_PROJECTS),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Taurus, labels = default}),
    Resolved = maps:get(resolved_attributes, R),
    Weight = maps:get(WeightA, Resolved),
    ?assertEqual(3500,             maps:get(value,  Weight)),
    ?assertEqual({class, Vehicle}, maps:get(source, Weight)).

q4_outgoing_and_incoming_connections(_Config) ->
    {ok, Mfr}    = graphdb_class:create_class("Manufacturer", ?NREF_CLASSES),
    {ok, Veh}    = graphdb_class:create_class("Vehicle",      ?NREF_CLASSES),
    {ok, Ford}   = graphdb_instance:create_instance(
                       "Ford",   Mfr, ?NREF_PROJECTS),
    {ok, Tau}    = graphdb_instance:create_instance(
                       "Taurus", Veh, ?NREF_PROJECTS),
    {ok, MakesA}  = graphdb_attr:create_relationship_attribute(
                        "makes",   "made_by", instance),
    {ok, MadeByA} = graphdb_attr:create_relationship_attribute(
                        "made_by", "makes",   instance),
    ok = graphdb_instance:add_relationship(Ford, MakesA, Tau, MadeByA),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Tau, labels = default}),
    Outgoing = maps:get(outgoing_connections, R),
    Incoming = maps:get(incoming_connections, R),
    %% Taurus points at Ford via MadeByA (outgoing).
    %% Ford points at Taurus via MakesA (incoming, from Taurus's pov).
    ?assert(lists:any(fun(#{characterization := C, target := T}) ->
                          C =:= MadeByA andalso T =:= Ford
                      end, Outgoing)),
    ?assert(lists:any(fun(#{characterization := C, source := S}) ->
                          C =:= MakesA andalso S =:= Ford
                      end, Incoming)).

q4_compositional_ancestors(_Config) ->
    {ok, Veh}    = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car}    = graphdb_instance:create_instance(
                       "Car",    Veh, ?NREF_PROJECTS),
    {ok, Engine} = graphdb_instance:create_instance(
                       "Engine", Veh, Car),
    {ok, R} = graphdb_query:execute_query(
        #q_describe{nref = Engine, labels = default}),
    ?assertEqual(Car, maps:get(compositional_parent, R)),
    ?assert(lists:member(Car, maps:get(compositional_ancestors, R))).

q4_instance_not_found(_Config) ->
    ?assertMatch({error, {nref_not_found, 9999999}},
                 graphdb_query:execute_query(
                     #q_describe{nref = 9999999, labels = default})).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q4_describe_instance`
Expected: FAIL — `{unsupported_kind, instance}`.

- [ ] **Step 3: Implement Q4 by extending the describe dispatch**

Add an instance branch:

```erlang
dispatch(#q_describe{nref = N, labels = Lang}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {#node{kind = attribute} = Node, Session1} ->
            describe_attribute(Node, Lang, Session1);
        {#node{kind = class} = Node, Session1} ->
            describe_class(Node, Lang, Session1);
        {#node{kind = instance} = Node, Session1} ->
            describe_instance(Node, Lang, Session1);
        {#node{kind = Kind}, Session1} ->
            {{error, {unsupported_kind, Kind}}, Session1}
    end;
```

Add the `describe_instance` helper:

```erlang
%%---------------------------------------------------------------------
%% describe_instance(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%---------------------------------------------------------------------
describe_instance(#node{nref = N, parents = Parents, classes = Classes,
                         attribute_value_pairs = AVPs} = Node, LangSpec,
                  Session) ->
    CompositionalParent = case Parents of
        [P | _] -> P;
        []      -> undefined
    end,
    {ok, CompAncestorNodes} = graphdb_instance:compositional_ancestors(N),
    CompAncestors = [Nd#node.nref || Nd <- CompAncestorNodes],
    ClassAncestors = lists:usort(lists:flatmap(
        fun(C) ->
            {ok, AncNodes} = graphdb_class:ancestors(C),
            [Nd#node.nref || Nd <- AncNodes]
        end, Classes)),
    Resolved = resolved_attributes(Node),
    {OutArcs, Session1} = session_read_arcs(Session, N, outgoing,
                                            [connection]),
    {InArcs,  Session2} = session_read_arcs(Session1, N, incoming,
                                            [connection]),
    Outgoing = [#{characterization => A#relationship.characterization,
                  target           => A#relationship.target_nref,
                  template         => template_avp(A#relationship.avps)}
                || A <- OutArcs],
    Incoming = [#{characterization => A#relationship.characterization,
                  source           => A#relationship.source_nref,
                  template         => template_avp(A#relationship.avps)}
                || A <- InArcs],
    AllNrefs = lists:usort(
        [N] ++ Classes ++ ClassAncestors
        ++ case CompositionalParent of undefined -> []; X -> [X] end
        ++ CompAncestors
        ++ [maps:get(characterization, M) || M <- Outgoing]
        ++ [maps:get(target,           M) || M <- Outgoing]
        ++ [maps:get(characterization, M) || M <- Incoming]
        ++ [maps:get(source,           M) || M <- Incoming]),
    {Labels, Session3} = resolve_labels(AllNrefs, LangSpec, Session2),
    Result = #{nref                    => N,
               kind                    => instance,
               classes                 => Classes,
               class_ancestors         => ClassAncestors,
               compositional_parent    => CompositionalParent,
               compositional_ancestors => CompAncestors,
               resolved_attributes     => Resolved,
               outgoing_connections    => Outgoing,
               incoming_connections    => Incoming,
               avps                    => AVPs,
               labels                  => Labels},
    {{ok, Result}, Session3}.

%%---------------------------------------------------------------------
%% resolved_attributes(Node) -> #{AttrNref => #{value, source}}
%%
%% Walks every class's full QC list and resolves each via
%% graphdb_instance:resolve_value/2, which returns {ok, Value, Source}
%% after Task 0.
%%---------------------------------------------------------------------
resolved_attributes(#node{nref = N, classes = Classes}) ->
    QCAttrs = lists:usort(lists:flatmap(
        fun(C) ->
            {ok, QCs} = graphdb_class:inherited_qcs(C),
            [A || {A, _Value} <- QCs]
        end, Classes)),
    lists:foldl(fun(Q, Acc) ->
        case graphdb_instance:resolve_value(N, Q) of
            {ok, Value, Source} -> Acc#{Q => #{value  => Value,
                                               source => Source}};
            not_found            -> Acc
        end
    end, #{}, QCAttrs).

template_avp(AVPs) ->
    case lists:search(
            fun(#{attribute := A}) -> A =:= ?ARC_TEMPLATE end,
            AVPs) of
        {value, #{value := V}} -> V;
        false                  -> undefined
    end.
```

- [ ] **Step 4: Run the suite**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 7: Q4 describe_instance -- inheritance + both-direction arcs"
```

---

### Task 8: Q5 — list_instances_of

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q5 returns a flat list of nrefs (the set-result shape). Uses `graphdb_class:subclasses/1` + Q1b on each class to find instantiation arcs.

- [ ] **Step 1: Add failing test cases**

Append to `-export`:

```erlang
    %% Q5 — list_instances_of
    q5_lists_direct_instances/1,
    q5_recursive_includes_subclass_instances/1,
    q5_non_recursive_excludes_subclasses/1,
    q5_class_with_no_instances/1
```

Group:

```erlang
{q5_list_instances_of, [], [
    q5_lists_direct_instances,
    q5_recursive_includes_subclass_instances,
    q5_non_recursive_excludes_subclasses,
    q5_class_with_no_instances
]}
```

Test bodies:

```erlang
q5_lists_direct_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Veh, ?NREF_PROJECTS),
    {ok, Acc} = graphdb_instance:create_instance(
                    "Accord", Veh, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}),
    ?assert(lists:member(Tau, Insts)),
    ?assert(lists:member(Acc, Insts)).

q5_recursive_includes_subclass_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Car, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = true}),
    ?assert(lists:member(Tau, Insts)).

q5_non_recursive_excludes_subclasses(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Tau} = graphdb_instance:create_instance(
                    "Taurus", Car, ?NREF_PROJECTS),
    {ok, Insts} = graphdb_query:execute_query(
        #q_instances_of{class = Veh, recursive = false}),
    ?assertNot(lists:member(Tau, Insts)).

q5_class_with_no_instances(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    ?assertMatch({ok, []},
                 graphdb_query:execute_query(
                     #q_instances_of{class = Veh, recursive = true})).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q5_list_instances_of`
Expected: FAIL — `not_implemented`.

- [ ] **Step 3: Implement Q5 in graphdb_query.erl**

Add the dispatch clause before the catch-all:

```erlang
dispatch(#q_instances_of{class = C, recursive = Recursive}, Session) ->
    Classes = case Recursive of
        true ->
            {ok, SubNodes} = graphdb_class:subclasses(C),
            Subs = [N#node.nref || N <- SubNodes],
            [C | Subs];
        false ->
            [C]
    end,
    {Instances, Session1} = lists:foldl(
        fun(Cl, {Acc, S}) ->
            {Arcs, S1} = session_read_arcs(S, Cl, outgoing,
                                            [instantiation]),
            Members = [A#relationship.target_nref || A <- Arcs,
                A#relationship.characterization =:= ?ARC_CLASS_TO_INST],
            {Members ++ Acc, S1}
        end, {[], Session}, Classes),
    {{ok, lists:usort(Instances)}, Session1};
```

> **Note:** `graphdb_class:subclasses/1` is documented to return *direct* subclasses only. For full transitive coverage on `recursive = true`, the dispatch needs to recurse: collect direct subclasses, then their direct subclasses, until exhausted. If the existing `subclasses/1` only returns direct children (verify on implementation), replace the `Subs` line with a transitive walk helper:
>
> ```erlang
> all_subclasses(C) ->
>     {ok, Direct} = graphdb_class:subclasses(C),
>     DirectNrefs = [N#node.nref || N <- Direct],
>     DirectNrefs ++ lists:flatmap(fun all_subclasses/1, DirectNrefs).
> ```
>
> Then `Subs = all_subclasses(C)` in the dispatch. Confirm the API contract during Q5 implementation.

- [ ] **Step 4: Run the suite**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 8: Q5 list_instances_of -- recursive set query"
```

---

### Task 9: Q6 — find_path + resume + snapshot_expired

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

Q6 is the bounded BFS query — the first that returns `{partial, _, _}` when the depth bound is reached. Implements `resume/2` properly and the `snapshot_expired` mismatch detection.

- [ ] **Step 1: Add failing test cases**

Append to `-export`:

```erlang
    %% Q6 — find_path
    q6_finds_path_via_taxonomy/1,
    q6_returns_no_path_when_disconnected/1,
    q6_respects_max_depth_returns_partial/1,
    q6_resume_continues_from_frontier/1,
    q6_arc_kind_filter/1,
    q6_find_path_3_public_api/1,
    %% resume / snapshot_expired
    resume_against_refreshed_session_fails/1
```

Group:

```erlang
{q6_find_path, [], [
    q6_finds_path_via_taxonomy,
    q6_returns_no_path_when_disconnected,
    q6_respects_max_depth_returns_partial,
    q6_resume_continues_from_frontier,
    q6_arc_kind_filter,
    q6_find_path_3_public_api,
    resume_against_refreshed_session_fails
]}
```

Test bodies:

```erlang
q6_finds_path_via_taxonomy(_Config) ->
    {ok, Veh} = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
    {ok, Car} = graphdb_class:create_class("Car",     Veh),
    {ok, Path} = graphdb_query:execute_query(
        #q_find_path{from      = Car,
                     to        = Veh,
                     max_depth = 5,
                     arc_kinds = [taxonomy]}),
    ?assert(is_list(Path)),
    ?assertNotEqual([], Path),
    Last = lists:last(Path),
    ?assertEqual(Veh, maps:get(to, Last)).

q6_returns_no_path_when_disconnected(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", ?NREF_CLASSES),
    ?assertMatch({ok, no_path},
                 graphdb_query:execute_query(
                     #q_find_path{from      = A,
                                  to        = B,
                                  max_depth = 5,
                                  arc_kinds = [taxonomy]})).

q6_respects_max_depth_returns_partial(_Config) ->
    %% Build a chain A <- B <- C <- D <- E (5 nodes, 4 taxonomy hops)
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, D} = graphdb_class:create_class("D", C),
    {ok, _E} = graphdb_class:create_class("E", D),
    %% From D up to A is 3 hops; cap at 2 → partial.
    Q = #q_find_path{from = D, to = A, max_depth = 2,
                     arc_kinds = [taxonomy]},
    Reply = graphdb_query:execute_query(Q),
    ?assertMatch({partial, _Path, _Cont}, Reply).

q6_resume_continues_from_frontier(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, D} = graphdb_class:create_class("D", C),
    Q = #q_find_path{from = D, to = A, max_depth = 2,
                     arc_kinds = [taxonomy]},
    S0 = graphdb_query:new_session(),
    {partial, _PartialPath, Cont, S1} =
        graphdb_query:execute_query(Q, S0),
    {ok, FullPath, _S2} = graphdb_query:resume(Cont, S1),
    Last = lists:last(FullPath),
    ?assertEqual(A, maps:get(to, Last)).

q6_arc_kind_filter(_Config) ->
    %% B (child) -> A (parent) via composition; restricting to taxonomy
    %% yields no_path because the path is purely compositional.
    {ok, Cls} = graphdb_class:create_class("Cls", ?NREF_CLASSES),
    {ok, A}   = graphdb_instance:create_instance(
                    "A", Cls, ?NREF_PROJECTS),
    {ok, B}   = graphdb_instance:create_instance("B", Cls, A),
    {ok, [_|_]} = graphdb_query:execute_query(
        #q_find_path{from      = B,
                     to        = A,
                     max_depth = 5,
                     arc_kinds = [composition]}),
    ?assertMatch({ok, no_path},
                 graphdb_query:execute_query(
                     #q_find_path{from      = B,
                                  to        = A,
                                  max_depth = 5,
                                  arc_kinds = [taxonomy]})).

q6_find_path_3_public_api(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, Path} = graphdb_query:find_path(B, A, 5),
    ?assert(is_list(Path)),
    ?assertNotEqual([], Path).

resume_against_refreshed_session_fails(_Config) ->
    {ok, A} = graphdb_class:create_class("A", ?NREF_CLASSES),
    {ok, B} = graphdb_class:create_class("B", A),
    {ok, C} = graphdb_class:create_class("C", B),
    {ok, _D} = graphdb_class:create_class("D", C),
    Q = #q_find_path{from = C, to = A, max_depth = 1,
                     arc_kinds = [taxonomy]},
    S0 = graphdb_query:new_session(),
    {partial, _, Cont, S1} = graphdb_query:execute_query(Q, S0),
    timer:sleep(2),
    S2 = graphdb_query:refresh(S1),
    ?assertEqual({error, snapshot_expired},
                 graphdb_query:resume(Cont, S2)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE --group=q6_find_path`
Expected: FAIL — `not_implemented`.

- [ ] **Step 3: Implement Q6 + resume**

Add the dispatch clause:

```erlang
dispatch(#q_find_path{from = From, to = To, max_depth = D,
                       arc_kinds = Kinds} = _Q, Session) ->
    SnapshotAt = maps:get(snapshot_at, Session),
    bfs(SnapshotAt, To, D, Kinds,
        #{From => true},
        [{From, []}],
        Session).
```

Replace the resume gen_server clause:

```erlang
handle_call({resume, #cont_path{snapshot_at = ContSnap} = Cont,
             #{snapshot_at := SessSnap} = Session}, _From, State)
    when ContSnap =/= SessSnap ->
    {reply, {error, snapshot_expired}, State};
handle_call({resume, #cont_path{target          = To,
                                 arc_kinds       = Kinds,
                                 remaining_depth = Remaining,
                                 visited         = Visited,
                                 frontier        = Frontier},
             Session}, _From, State) ->
    SnapshotAt = maps:get(snapshot_at, Session),
    {Reply, Session1} =
        bfs(SnapshotAt, To, Remaining, Kinds, Visited, Frontier, Session),
    {reply, attach_session(Reply, Session1), State};
```

Add the BFS helper:

```erlang
%%---------------------------------------------------------------------
%% bfs(SnapshotAt, Target, RemainingDepth, ArcKinds,
%%     Visited, Frontier, Session) -> {Reply, Session1}
%%
%% Frontier :: [{Nref, PathToHere}]
%% PathToHere :: [#{from, via, to, kind}]   (edges already taken)
%%
%% Returns:
%%   {{ok, EdgeList}, Session1}                       -- target found
%%   {{ok, no_path}, Session1}                        -- exhausted
%%   {{partial, BestSoFar, #cont_path{}}, Session1}   -- depth-bounded
%%---------------------------------------------------------------------
bfs(_Snap, _To, _D, _Kinds, _Vis, [], Session) ->
    {{ok, no_path}, Session};
bfs(Snap, To, 0, Kinds, Vis, Frontier, Session) ->
    %% Depth exhausted but frontier non-empty -> partial.
    BestSoFar = case Frontier of
        [{_, P} | _] -> P;
        []           -> []
    end,
    Cont = #cont_path{snapshot_at     = Snap,
                       target          = To,
                       arc_kinds       = Kinds,
                       remaining_depth = 0,
                       visited         = Vis,
                       frontier        = Frontier},
    {{partial, BestSoFar, Cont}, Session};
bfs(Snap, To, D, Kinds, Vis, Frontier, Session) ->
    {NextFrontier, Vis1, FoundPath, Session1} =
        bfs_step(To, Kinds, Frontier, Vis, Session),
    case FoundPath of
        {found, Path} ->
            {{ok, Path}, Session1};
        not_found ->
            bfs(Snap, To, D - 1, Kinds, Vis1, NextFrontier, Session1)
    end.

bfs_step(To, Kinds, Frontier, Vis, Session) ->
    lists:foldl(
        fun({Nref, PathToHere}, {Acc, V, Found, S}) ->
            case Found of
                {found, _} ->
                    {Acc, V, Found, S};
                not_found ->
                    {Arcs, S1} = session_read_arcs(S, Nref, outgoing,
                                                    Kinds),
                    expand_arcs(To, Nref, PathToHere, Arcs, V, Acc,
                                Found, S1)
            end
        end, {[], Vis, not_found, Session}, Frontier).

expand_arcs(_To, _From, _PathHere, [], V, Acc, Found, S) ->
    {Acc, V, Found, S};
expand_arcs(To, From, PathHere,
            [#relationship{kind             = K,
                           characterization = C,
                           target_nref      = T} | Rest],
            V, Acc, Found, S) ->
    Edge = #{from => From, via => C, to => T, kind => K},
    NewPath = PathHere ++ [Edge],
    case T of
        To ->
            {Acc, V, {found, NewPath}, S};
        _ ->
            case maps:is_key(T, V) of
                true ->
                    expand_arcs(To, From, PathHere, Rest, V, Acc,
                                Found, S);
                false ->
                    V1 = V#{T => true},
                    Acc1 = Acc ++ [{T, NewPath}],
                    expand_arcs(To, From, PathHere, Rest, V1, Acc1,
                                Found, S)
            end
    end.
```

- [ ] **Step 4: Run the suite**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_query_SUITE`
Expected: PASS — all groups green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "F3 Task 9: Q6 find_path + resume + snapshot_expired"
```

---

### Task 10: Documentation closeout

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `TASKS.md`
- Modify: `CLAUDE.md` (root supervision tree picture)

- [ ] **Step 1: Update `apps/graphdb/CLAUDE.md`**

In the Files table, change the `graphdb_query.erl` row from "(planned)" to "(implemented)":

```
| `graphdb_query.erl`     | F3 query language gen_server (implemented)                  |
```

In the Worker Responsibilities section, replace the `graphdb_query` "planned" subsection with:

```markdown
### `graphdb_query` — Query Language (F3)

Parses and executes graph queries. Public API:

- `parse_query/1` — identity until a text DSL lands
- `new_session/0`, `refresh/1` — snapshot-semantics session lifecycle
- `execute_query/1`, `execute_query/2` — ephemeral and session-threaded
- `resume/2` — continue a `#cont_path{}` (returns
  `{error, snapshot_expired}` if the session has been refreshed since)
- `find_path/3` — convenience wrapper for `#q_find_path{}`

Queries are represented as records defined in
`apps/graphdb/include/graphdb_query.hrl`. Every Mnesia read goes
through `session_read_node/2` or `session_read_arcs/4`; direct
`mnesia:dirty_*` calls outside those helpers are a code smell.

See `f3-graphdb-query-design.md` at project root for the architectural
contract.
```

In the NYI status section, drop graphdb_query from the "stubs" list (it is now implemented).

- [ ] **Step 2: Update `ARCHITECTURE.md`**

Add (or update) the query layer section. Typical placement is after the worker descriptions:

```markdown
### Query Layer (graphdb_query)

`graphdb_query` is the sole entry point for read-side traversal of the
graph. It is a gen_server peer to the other graphdb workers under
graphdb_sup.

Architectural shape:

- AST records in `apps/graphdb/include/graphdb_query.hrl`
  (`#q_get_node{}`, `#q_get_arcs{}`, `#q_describe{}`,
  `#q_instances_of{}`, `#q_find_path{}`).
- Session is a value-passed map carrying a snapshot timestamp and a
  read-through cache of node and arc reads.
- Sessions are snapshots: `refresh/1` is the only invalidation path.
  Continuations are tagged with their issuing snapshot; resuming
  against a refreshed session returns `{error, snapshot_expired}`.
- Mnesia access is funnelled through `session_read_node/2` and
  `session_read_arcs/4`. The executor never calls `mnesia:dirty_*`
  directly.
- `find_path` is always bounded (caller supplies `max_depth`);
  reaching the bound returns `{partial, Path, Continuation}` for
  later resumption.
```

- [ ] **Step 3: Update root `CLAUDE.md` supervision tree**

In the `## OTP Supervision Tree` section, add `graphdb_query` to the graphdb_sup children, mark its status:

```
graphdb_sup (supervisor)
      ├── graphdb_mgr       (gen_server — implemented: bootstrap init, read API, category guard)
      ├── graphdb_rules     (gen_server — stub, implementation pending)
      ├── graphdb_attr      (gen_server — implemented: seeds + create/lookup API)
      ├── graphdb_class     (gen_server — implemented: taxonomic hierarchy, QC inheritance)
      ├── graphdb_instance  (gen_server — implemented: compositional hierarchy, inheritance)
      ├── graphdb_language  (gen_server — implemented: M6 multilingual overlay)
      └── graphdb_query     (gen_server — implemented: F3 query language)
```

Also update the **Known Incomplete Areas (NYI)** section: remove the line about `graphdb_language` query stub (F3); leave `graphdb_rules` as the only remaining worker stub.

- [ ] **Step 4: Update `TASKS.md`**

Mark F3 RESOLVED with a one-line note pointing to the commit range. Example structure (match the file's existing style):

```markdown
## F3 — graphdb_language Query Language ✅ RESOLVED

Implemented as `graphdb_query` (the `graphdb_language` slot is occupied
by the M6 multilingual overlay layer). Design at
`f3-graphdb-query-design.md`; plan at
`docs/superpowers/plans/2026-05-23-f3-graphdb-query.md`. Seven query
primitives (Q1, Q1b, Q2-Q6), snapshot-semantics sessions, continuation
+ resume.
```

- [ ] **Step 5: Run the full test suite to catch any cross-suite regressions**

Run: `./rebar3 ct`
Expected: PASS — all suites green. graphdb_query_SUITE adds ~25 new CT cases.

Run: `./rebar3 compile`
Expected: PASS — zero warnings.

- [ ] **Step 6: Commit**

```bash
git add ARCHITECTURE.md apps/graphdb/CLAUDE.md CLAUDE.md TASKS.md
git commit -m "F3 Task 10: documentation closeout -- query layer implemented"
```

---

## Final Notes

**Walking-skeleton ordering matters.** Q1 must land first because it
proves the pipeline. Subsequent queries can in principle be reordered,
but the order in this plan (Q1b → Q2 → Q3 → Q4 → Q5 → Q6) builds each
query on primitives that are already in the cache helpers, minimising
back-fill churn.

**Test isolation pattern.** Every CT testcase gets a tmp directory and
a fresh Mnesia. `verify_caches/0` runs in `end_per_testcase`; a write
that drifts caches will fail the case immediately.

**API contract assumptions.** Task 0 establishes two contract changes
(`resolve_value/2` returns `{ok, Value, Source}`; `bind_qc_value/3`
added) that the rest of the plan depends on. If `subclasses/1` is
later discovered to return transitive subclasses (rather than direct
only as assumed), the Task 8 `all_subclasses/1` recursion can be
dropped — confirm during Q5 implementation. The own/inherited QC
split for Q3 is deferred — Q3 v1 returns a flat `[{AttrNref, Value}]`
list.

**Out of scope per the design doc.** Text DSL, query planner /
optimizer, aggregation queries, class-side search, cross-database
joins, mutation queries, materialized views, event-driven cache
invalidation, streaming results — explicitly deferred.
