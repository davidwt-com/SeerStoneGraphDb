# Permanent-Tier Nref Facade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move graphdb `init/1` seed nodes into the permanent nref tier `[10001, 1000000)` by routing every graphdb node-nref allocation through one switchable `graphdb_nref` facade whose phase (permanent during init, runtime after a boot-time flip) decides the tier.

**Architecture:** A new `graphdb_nref` gen_server is *the* entry point for all graphdb node-nref allocation. In **permanent** phase it hands out a compute-from-DB cursor in `[?LABEL_START, ?NREF_START)`; in **runtime** phase `get_next/0` delegates to `nref_server:get_nref/0`. The phase lives in `persistent_term` (survives single-process restarts); `graphdb:start/2` brackets the boot — permanent before `graphdb_sup:start_link/0`, runtime after. The bootstrap loader keeps its own local counter; the tier boundaries become header macros.

**Tech Stack:** Erlang/OTP 28, rebar3 3.27, Mnesia (`nodes`/`relationships` `disc_copies`), Common Test + EUnit, DETS-backed `nref_server`.

**Spec:** `docs/designs/permanent-tier-nref-allocator-design.md`

**Build/test commands (run from project root):**
- Compile: `./rebar3 compile`
- One CT suite: `./rebar3 ct --suite apps/graphdb/test/graphdb_nref_SUITE`
- One CT case: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE --case seeded_nrefs_are_above_floor`
- EUnit one module: `./rebar3 eunit --module=graphdb_bootstrap_tests`
- Full suite: `./rebar3 ct && ./rebar3 eunit`

---

## File Structure

| File                                                     | Responsibility                                                       | Action |
| -------------------------------------------------------- | -------------------------------------------------------------------- | ------ |
| `apps/graphdb/include/graphdb_nrefs.hrl`                 | Tier boundary macros `?LABEL_START`, `?NREF_START`                   | Modify |
| `apps/graphdb/src/graphdb_nref.erl`                      | Switchable node-nref allocation facade (gen_server)                  | Create |
| `apps/graphdb/test/graphdb_nref_SUITE.erl`               | CT suite for the facade                                              | Create |
| `apps/graphdb/src/graphdb_sup.erl`                       | Start `graphdb_nref` first in the child list                         | Modify |
| `apps/graphdb/src/graphdb.erl`                           | `start/2` brackets the boot with the phase flip                      | Modify |
| `apps/graphdb/src/graphdb_attr.erl`                      | Swap `get_nref` → `get_next` (3 sites)                               | Modify |
| `apps/graphdb/src/graphdb_language.erl`                  | Swap `get_nref` → `get_next` (3 sites)                               | Modify |
| `apps/graphdb/src/graphdb_instance.erl`                  | Swap `get_nref` → `get_next` (1 site)                                | Modify |
| `apps/graphdb/src/graphdb_class.erl`                     | Swap `get_nref` → `get_next` (3 sites)                               | Modify |
| `apps/graphdb/src/graphdb_bootstrap.erl`                 | Use macros; drop directives + `set_floor`; `classify_terms`→2-tuple  | Modify |
| `apps/graphdb/priv/bootstrap.terms`                      | Remove `{nref_start,_}` / `{label_start,_}` directives; header       | Modify |
| `apps/graphdb/test/graphdb_*_SUITE.erl` (7 suites)       | Start `graphdb_nref` + set permanent phase in harness                | Modify |
| `apps/graphdb/test/graphdb_attr_SUITE.erl`               | Flip seed tier assertions to permanent bounds                        | Modify |
| `apps/graphdb/test/graphdb_language_SUITE.erl`           | Flip seed tier assertions to permanent bounds                        | Modify |
| `apps/graphdb/test/graphdb_bootstrap_tests.erl`          | Delete directive tests; adjust `classify_terms`/`build_symbol_table` | Modify |
| `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`          | Delete floor/directive tests; fix fixtures                           | Modify |
| `ARCHITECTURE.md`, `CLAUDE.md`, `apps/graphdb/CLAUDE.md` | Docs: tiers, facade, supervision tree, stale start/2 claim           | Modify |

---

## Task 1: Tier boundary macros

**Files:**
- Modify: `apps/graphdb/include/graphdb_nrefs.hrl:74` (after `?NREF_ENGLISH`)

- [ ] **Step 1: Add the macros**

After the `?NREF_ENGLISH` line (currently the last define, line 74), add:

```erlang

%% -- Permanent / runtime tier boundaries ------------------------------
%% System invariants (NOT per-bootstrap-file knobs).  Permanent seeds
%% occupy [?LABEL_START, ?NREF_START); runtime nrefs are >= ?NREF_START.
-define(LABEL_START,    10001).    %% first permanent nref above English
-define(NREF_START,   1000000).    %% runtime tier floor; permanent < this
```

- [ ] **Step 2: Compile to verify the header parses**

Run: `./rebar3 compile`
Expected: success, no new warnings.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/include/graphdb_nrefs.hrl
git commit -m "graphdb_nrefs.hrl: add ?LABEL_START / ?NREF_START tier macros"
```

---

## Task 2: `graphdb_nref` facade module (TDD)

**Files:**
- Create: `apps/graphdb/src/graphdb_nref.erl`
- Test: `apps/graphdb/test/graphdb_nref_SUITE.erl`

- [ ] **Step 1: Write the failing CT suite**

Create `apps/graphdb/test/graphdb_nref_SUITE.erl`:

```erlang
%%-----------------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%-----------------------------------------------------------------------------
-module(graphdb_nref_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("graphdb_nrefs.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    compute_from_empty_returns_label_start/1,
    compute_from_populated_resumes/1,
    sequential_unique_and_monotonic/1,
    spillover_raises_runtime_floor/1,
    runtime_phase_delegates_to_nref_server/1,
    restart_in_runtime_phase_stays_safe/1
]).

all() ->
    [compute_from_empty_returns_label_start,
     compute_from_populated_resumes,
     sequential_unique_and_monotonic,
     spillover_raises_runtime_floor,
     runtime_phase_delegates_to_nref_server,
     restart_in_runtime_phase_stays_safe].

init_per_testcase(_TC, Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir = filename:join([OrigCwd, "_build", "test", "ct_scratch",
        "nref_" ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    %% Isolate per-testcase: fresh cwd so nref DETS files (created in cwd)
    %% do not carry the allocator counter across testcases.
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    ok = mnesia:create_schema([node()]),
    ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(nodes,
        [{record_name, node}, {attributes, [nref, kind, parents, classes, avps]}]),
    graphdb_nref:set_permanent_phase(),
    {ok, _} = graphdb_nref:start_link(),
    [{orig_cwd, OrigCwd} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_server:stop(graphdb_nref),
    catch persistent_term:erase({graphdb_nref, phase}),
    catch mnesia:stop(),
    catch mnesia:delete_schema([node()]),
    catch application:stop(nref),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    file:set_cwd(proplists:get_value(orig_cwd, Config)),
    ok.

%% Helper: write a node row with a given nref (only nref matters here).
put_node(Nref) ->
    Rec = {node, Nref, attribute, [], [], []},
    {atomic, ok} = mnesia:transaction(fun() -> mnesia:write(nodes, Rec, write) end),
    ok.

compute_from_empty_returns_label_start(_Config) ->
    ?assertEqual(?LABEL_START, graphdb_nref:get_next()).

compute_from_populated_resumes(_Config) ->
    ok = put_node(10000),   %% English (permanent, below ?NREF_START)
    ok = put_node(10050),
    ok = put_node(2000000), %% a runtime node — must be ignored by the scan
    ?assertEqual(10051, graphdb_nref:get_next()).

sequential_unique_and_monotonic(_Config) ->
    A = graphdb_nref:get_next(),
    B = graphdb_nref:get_next(),
    C = graphdb_nref:get_next(),
    ?assertEqual([?LABEL_START, ?LABEL_START + 1, ?LABEL_START + 2], [A, B, C]).

spillover_raises_runtime_floor(_Config) ->
    ok = put_node(?NREF_START - 1),   %% permanent tier is now "full"
    N = graphdb_nref:get_next(),      %% hands out ?NREF_START (spillover)
    ?assertEqual(?NREF_START, N),
    %% runtime floor must have been raised above the spilled nref
    ?assert(nref_server:get_nref() >= ?NREF_START + 1).

runtime_phase_delegates_to_nref_server(_Config) ->
    ok = graphdb_nref:set_runtime_phase(),
    ?assert(graphdb_nref:get_next() >= ?NREF_START).

restart_in_runtime_phase_stays_safe(_Config) ->
    ok = graphdb_nref:set_runtime_phase(),
    ok = gen_server:stop(graphdb_nref),
    {ok, _} = graphdb_nref:start_link(),
    %% durable phase flag survived the restart: still runtime tier
    ?assert(graphdb_nref:get_next() >= ?NREF_START).
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_nref_SUITE`
Expected: FAIL/ERROR — `graphdb_nref` module does not exist (undef).

- [ ] **Step 3: Write the module**

Create `apps/graphdb/src/graphdb_nref.erl`:

```erlang
%%-----------------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%-----------------------------------------------------------------------------
%% File        : graphdb_nref.erl
%% Author      : David W. Thomas
%% Created     : 2026-05-28
%% Description : Switchable node-nref allocation facade for graphdb.
%%               Permanent phase (init): hands out permanent-tier nrefs
%%               [?LABEL_START, ?NREF_START) computed from the nodes table.
%%               Runtime phase (after the boot flip): delegates to
%%               nref_server:get_nref/0.  The phase lives in persistent_term
%%               so a single process restart cannot resurrect the wrong phase.
%%-----------------------------------------------------------------------------
-module(graphdb_nref).
-behaviour(gen_server).

-revision('Rev: PA1').
-created('2026-05-28').
-created_by('david@davidwt.com').

-define(NYI(X), (begin
    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
    exit(nyi)
end)).
-define(UEM(F, X), (begin
    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
    exit(uem)
end)).

-include("graphdb_nrefs.hrl").

-export([
    start_link/0,
    get_next/0,
    set_permanent_phase/0,
    set_runtime_phase/0,
    phase/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(PHASE_KEY, {?MODULE, phase}).

-record(state, {cursor :: undefined | integer()}).

%%-----------------------------------------------------------------------------
%% start_link() -> {ok, pid()}
%%-----------------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%-----------------------------------------------------------------------------
%% get_next() -> integer()
%%
%% The single entry point for all graphdb node-nref allocation.  The phase
%% decides the tier: permanent (init) -> compute-from-DB cursor; runtime
%% (after the flip) -> nref_server:get_nref/0.
%%-----------------------------------------------------------------------------
get_next() ->
    case phase() of
        runtime   -> nref_server:get_nref();
        permanent -> gen_server:call(?MODULE, next_permanent)
    end.

%%-----------------------------------------------------------------------------
%% phase() -> permanent | runtime   (defaults to permanent when unset)
%%-----------------------------------------------------------------------------
phase() ->
    persistent_term:get(?PHASE_KEY, permanent).

%%-----------------------------------------------------------------------------
%% set_permanent_phase() -> ok
%%-----------------------------------------------------------------------------
set_permanent_phase() ->
    persistent_term:put(?PHASE_KEY, permanent),
    ok.

%%-----------------------------------------------------------------------------
%% set_runtime_phase() -> ok
%%
%% Flips to runtime and raises nref_server's floor to ?NREF_START so the
%% first runtime allocation lands in the runtime tier.  Idempotent
%% (set_floor is monotonic; persistent_term:put overwrites).
%%-----------------------------------------------------------------------------
set_runtime_phase() ->
    ok = nref_server:set_floor(?NREF_START),
    persistent_term:put(?PHASE_KEY, runtime),
    ok.

%%-----------------------------------------------------------------------------
%% init/1
%%-----------------------------------------------------------------------------
init([]) ->
    {ok, #state{cursor = undefined}}.

%%-----------------------------------------------------------------------------
%% handle_call/3
%%-----------------------------------------------------------------------------
handle_call(next_permanent, _From, #state{cursor = undefined}) ->
    allocate(compute_cursor());
handle_call(next_permanent, _From, #state{cursor = C}) ->
    allocate(C);
handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Message, State) ->
    ?UEM(handle_cast, {Message, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% allocate(N) -> {reply, N, #state{}}
%%
%% Hands out N and advances the cursor.  On spillover (N >= ?NREF_START)
%% raises the runtime floor so runtime allocations stay above the spill.
%%-----------------------------------------------------------------------------
allocate(N) when N >= ?NREF_START ->
    ok = nref_server:set_floor(N + 1),
    {reply, N, #state{cursor = N + 1}};
allocate(N) ->
    {reply, N, #state{cursor = N + 1}}.

%%-----------------------------------------------------------------------------
%% compute_cursor() -> integer()
%%
%% Next permanent nref = max(?LABEL_START, 1 + max permanent nref already in
%% the nodes table).  nref is the primary key, so dirty_all_keys/1 yields
%% every nref directly.  Runtime nrefs (>= ?NREF_START) are filtered out.
%%-----------------------------------------------------------------------------
compute_cursor() ->
    Keys  = mnesia:dirty_all_keys(nodes),
    Below = [K || K <- Keys, is_integer(K), K < ?NREF_START],
    case Below of
        [] -> ?LABEL_START;
        _  -> erlang:max(?LABEL_START, lists:max(Below) + 1)
    end.
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_nref_SUITE`
Expected: PASS — 6/6 cases green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_nref.erl apps/graphdb/test/graphdb_nref_SUITE.erl
git commit -m "graphdb_nref: switchable permanent/runtime nref facade (compute-from-DB, persistent_term phase)"
```

---

## Task 3: Wire `graphdb_nref` into `graphdb_sup` (first child)

**Files:**
- Modify: `apps/graphdb/src/graphdb_sup.erl:226-234`

- [ ] **Step 1: Add the childspec and prepend it to the child list**

Replace the block at lines 226-234:

```erlang
	{ok, ChSpec0} = childspec(rel_id_server),
	{ok, ChSpec1} = childspec(graphdb_mgr),
	{ok, ChSpec2} = childspec(graphdb_rules),
	{ok, ChSpec3} = childspec(graphdb_attr),
	{ok, ChSpec4} = childspec(graphdb_class),
	{ok, ChSpec5} = childspec(graphdb_instance),
	{ok, ChSpec6} = childspec(graphdb_language),
	{ok, ChSpec7} = childspec(graphdb_query),
	{ok, {SupFlags, [ChSpec0, ChSpec1, ChSpec2, ChSpec3, ChSpec4, ChSpec5, ChSpec6, ChSpec7]}};
```

with (note `graphdb_nref` is started **first**):

```erlang
	{ok, ChSpecN} = childspec(graphdb_nref),
	{ok, ChSpec0} = childspec(rel_id_server),
	{ok, ChSpec1} = childspec(graphdb_mgr),
	{ok, ChSpec2} = childspec(graphdb_rules),
	{ok, ChSpec3} = childspec(graphdb_attr),
	{ok, ChSpec4} = childspec(graphdb_class),
	{ok, ChSpec5} = childspec(graphdb_instance),
	{ok, ChSpec6} = childspec(graphdb_language),
	{ok, ChSpec7} = childspec(graphdb_query),
	{ok, {SupFlags, [ChSpecN, ChSpec0, ChSpec1, ChSpec2, ChSpec3, ChSpec4, ChSpec5, ChSpec6, ChSpec7]}};
```

- [ ] **Step 2: Compile**

Run: `./rebar3 compile`
Expected: success, no new warnings.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/src/graphdb_sup.erl
git commit -m "graphdb_sup: start graphdb_nref first (before graphdb_mgr and seeding workers)"
```

---

## Task 4: Boot-time phase flip in `graphdb:start/2`

**Files:**
- Modify: `apps/graphdb/src/graphdb.erl` (the `start/2` function)

- [ ] **Step 1: Bracket the boot with the phase flip**

Replace the `start/2` function:

```erlang
start(Type, StartArgs) ->
	case graphdb_sup:start_link() of
		{ok, Pid} ->
			{ok, Pid};
		ignore -> 
			{error, ignore};
		{error, Reason} ->	
			{error, Reason};
		MSG ->
			?UEM({start , {Type, StartArgs}}, MSG)
    end.
```

with:

```erlang
start(Type, StartArgs) ->
	%% Mark the permanent phase before any child init runs, so the bootstrap
	%% loader and every seeding worker allocate in the permanent tier.
	ok = graphdb_nref:set_permanent_phase(),
	case graphdb_sup:start_link() of
		{ok, Pid} ->
			%% All child init/1s have completed; flip to the runtime tier
			%% (also raises nref_server's floor to ?NREF_START).
			ok = graphdb_nref:set_runtime_phase(),
			{ok, Pid};
		ignore -> 
			{error, ignore};
		{error, Reason} ->	
			{error, Reason};
		MSG ->
			?UEM({start , {Type, StartArgs}}, MSG)
    end.
```

- [ ] **Step 2: Compile**

Run: `./rebar3 compile`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/src/graphdb.erl
git commit -m "graphdb:start/2 brackets boot with graphdb_nref permanent->runtime flip"
```

---

## Task 5: Wire `graphdb_nref` into the test harnesses

After Task 6+ the seeding workers call `graphdb_nref:get_next/0`; every suite that starts a node-creating worker standalone must therefore have `graphdb_nref` running and the phase set to permanent. Doing this now (before the swaps) is harmless — it starts an as-yet-unused gen_server.

**Files (each suite's `init_per_testcase` and `end_per_testcase`):**
- `apps/graphdb/test/graphdb_attr_SUITE.erl` (init_per_testcase line 169)
- `apps/graphdb/test/graphdb_class_SUITE.erl` (line 207)
- `apps/graphdb/test/graphdb_instance_SUITE.erl` (line 230)
- `apps/graphdb/test/graphdb_language_SUITE.erl` (line 163)
- `apps/graphdb/test/graphdb_mgr_SUITE.erl` (line 183)
- `apps/graphdb/test/graphdb_query_SUITE.erl` (line 185)

(Not `graphdb_nref_SUITE` — it manages the facade itself.)

- [ ] **Step 1: In each `init_per_testcase`, start the facade in permanent phase**

In each listed suite, immediately **after** the `rel_id_server:start_link()` call (and before any `graphdb_mgr`/`graphdb_attr`/etc. `start_link`), insert these two lines (match the file's indentation — tabs in `attr`/`class`/`mgr`, spaces in `language`/`instance`/`query`):

```erlang
	graphdb_nref:set_permanent_phase(),
	{ok, _} = graphdb_nref:start_link(),
```

If a suite has no `rel_id_server:start_link()` line, insert the two lines immediately after the `application:ensure_all_started(nref)` / nref startup in its setup, before the first worker `start_link`.

- [ ] **Step 2: In each `end_per_testcase`, stop the facade and clear the phase**

In each listed suite's `end_per_testcase`, add alongside the existing `catch gen_server:stop(...)` cleanups:

```erlang
	catch gen_server:stop(graphdb_nref),
	catch persistent_term:erase({graphdb_nref, phase}),
```

- [ ] **Step 3: Run the full CT suite to confirm nothing regressed**

Run: `./rebar3 ct`
Expected: PASS — same green count as before this task (the facade is started but not yet called by the workers).

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/test/graphdb_attr_SUITE.erl apps/graphdb/test/graphdb_class_SUITE.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_language_SUITE.erl \
        apps/graphdb/test/graphdb_mgr_SUITE.erl apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "test: start graphdb_nref (permanent phase) in node-creating suite harnesses"
```

---

## Task 6: Swap `graphdb_attr` to the facade + flip attr tier assertions (TDD)

**Files:**
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl:289-292,336,593`
- Modify: `apps/graphdb/src/graphdb_attr.erl:505,554,555`

- [ ] **Step 1: Flip the seed-tier assertions (write the failing test first)**

In `apps/graphdb/test/graphdb_attr_SUITE.erl`, change the four assertions at lines 289-292 from:

```erlang
	?assert(Lt >= 1000000),
	?assert(Tk >= 1000000),
	?assert(Ra >= 1000000),
	?assert(At >= 1000000).
```

to:

```erlang
	?assert(Lt > ?NREF_ENGLISH andalso Lt < ?NREF_START),
	?assert(Tk > ?NREF_ENGLISH andalso Tk < ?NREF_START),
	?assert(Ra > ?NREF_ENGLISH andalso Ra < ?NREF_START),
	?assert(At > ?NREF_ENGLISH andalso At < ?NREF_START).
```

Change line 336 from `?assert(AttrLitNref >= 1000000),` to:

```erlang
	?assert(AttrLitNref > ?NREF_ENGLISH andalso AttrLitNref < ?NREF_START),
```

Change line 593 from `?assert(At >= 1000000),` to:

```erlang
	?assert(At > ?NREF_ENGLISH andalso At < ?NREF_START),
```

Confirm the suite includes the nref macros (it already uses `?NREF_LITERALS`, so `-include("graphdb_nrefs.hrl").` is present; if not, add it).

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE --case seeded_nrefs_are_above_floor`
Expected: FAIL — seeds still allocated `>= 1000000` (runtime tier) via `nref_server`.

- [ ] **Step 3: Swap the allocation calls**

In `apps/graphdb/src/graphdb_attr.erl`, change the three node-nref allocations:

- line 505: `Nref = nref_server:get_nref(),` → `Nref = graphdb_nref:get_next(),`
- line 554: `FwdNref = nref_server:get_nref(),` → `FwdNref = graphdb_nref:get_next(),`
- line 555: `RevNref = nref_server:get_nref(),` → `RevNref = graphdb_nref:get_next(),`

(Leave `rel_id_server:get_id*` calls untouched — relationship IDs are a separate space.)

- [ ] **Step 4: Run to verify pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: PASS — all attr cases green; seeds now in permanent tier.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "graphdb_attr: allocate seeds via graphdb_nref:get_next (permanent tier); flip tier assertions"
```

---

## Task 7: Swap `graphdb_language` + flip language tier assertions (TDD)

**Files:**
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl:263-265,277`
- Modify: `apps/graphdb/src/graphdb_language.erl:415,595,657`

- [ ] **Step 1: Flip the seed-tier assertions**

In `apps/graphdb/test/graphdb_language_SUITE.erl`, change lines 263-265 from:

```erlang
    ?assert(LL >= 1000000),
    ?assert(BL >= 1000000),
    ?assert(PL >= 1000000).
```

to:

```erlang
    ?assert(LL > ?NREF_ENGLISH andalso LL < ?NREF_START),
    ?assert(BL > ?NREF_ENGLISH andalso BL < ?NREF_START),
    ?assert(PL > ?NREF_ENGLISH andalso PL < ?NREF_START).
```

Also update the comment just above (lines ~260-262) so it no longer says these come from `nref_server` at the runtime floor — replace with: `%% Language Literals sub-group, base_language and project_language are seeded by graphdb_language:init/1 in the permanent tier via graphdb_nref.`

Change line 277 from `?assert(LangLitNref >= 1000000),` to:

```erlang
    ?assert(LangLitNref > ?NREF_ENGLISH andalso LangLitNref < ?NREF_START),
```

(The `LC`/`LH` assertions at 257-259 already check `< 1000000`; leave them — replace the literal `1000000` with `?NREF_START` there too for consistency if desired.)

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_language_SUITE --case seeded_nrefs_above_floor`
Expected: FAIL — `LL`/`BL`/`PL` still `>= 1000000`.

- [ ] **Step 3: Swap the allocation calls**

In `apps/graphdb/src/graphdb_language.erl`, change all three:

- line 415: `Nref = nref_server:get_nref(),` → `Nref = graphdb_nref:get_next(),`
- line 595: `Nref              = nref_server:get_nref(),` → `Nref              = graphdb_nref:get_next(),`
- line 657: `Nref              = nref_server:get_nref(),` → `Nref              = graphdb_nref:get_next(),`

(Lines 595/657 are the runtime `register_language`/`register_dialect` paths — routing them through the facade is correct: post-flip they get runtime nrefs, and the swap keeps the single entry point uniform.)

- [ ] **Step 4: Run to verify pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_language_SUITE`
Expected: PASS — all language cases green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_language.erl apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "graphdb_language: allocate via graphdb_nref:get_next; flip seed tier assertions"
```

---

## Task 8: Swap `graphdb_instance` and `graphdb_class`

These suites carry no nref-tier assertions (verified), so this is a straight swap; the harnesses already start `graphdb_nref` (Task 5).

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl:444`
- Modify: `apps/graphdb/src/graphdb_class.erl:425,427,578`

- [ ] **Step 1: Swap `graphdb_instance`**

Change line 444: `Nref = nref_server:get_nref(),` → `Nref = graphdb_nref:get_next(),`

- [ ] **Step 2: Swap `graphdb_class`**

- line 425: `ClassNref              = nref_server:get_nref(),` → `ClassNref              = graphdb_nref:get_next(),`
- line 427: `TemplateNref           = nref_server:get_nref(),` → `TemplateNref           = graphdb_nref:get_next(),`
- line 578: `TemplateNref = nref_server:get_nref(),` → `TemplateNref = graphdb_nref:get_next(),`

- [ ] **Step 3: Run the affected suites**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS.

- [ ] **Step 4: Confirm no remaining node-nref allocations bypass the facade**

Run: `grep -rn "nref_server:get_nref" apps/graphdb/src/`
Expected: only comment lines (e.g. `graphdb_mgr.erl:190`, `graphdb_attr.erl:500`) — **no live code** outside `graphdb_nref.erl` (which legitimately delegates to it in runtime phase). If a live call remains, swap it.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/src/graphdb_class.erl
git commit -m "graphdb_instance/class: allocate node nrefs via graphdb_nref:get_next"
```

---

## Task 9: Bootstrap revert — macros, drop directives, drop loader set_floor

The loader now sources the boundaries from macros, no longer parses directives, and no longer calls `set_floor` (that moved to `graphdb:start/2`, Task 4).

**Files:**
- Modify: `apps/graphdb/src/graphdb_bootstrap.erl` (`do_load/0`, `classify_terms/*`, delete `validate_label_start/2`, exports)
- Modify: `apps/graphdb/priv/bootstrap.terms` (remove directives + header)
- Modify: `apps/graphdb/test/graphdb_bootstrap_tests.erl`
- Modify: `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`

- [ ] **Step 1: Ensure the loader includes the nref macros**

Confirm `apps/graphdb/src/graphdb_bootstrap.erl` has `-include("graphdb_nrefs.hrl").` near the top (it uses `graphdb_nrefs:verify/0`; if the include is absent, add it).

- [ ] **Step 2: Rewrite `do_load/0` to use macros and drop `set_floor`**

Replace the body of `do_load/0` (lines 233-266) with:

```erlang
do_load() ->
	File = get_bootstrap_file(),
	logger:info("graphdb_bootstrap: loading ~s", [File]),
	case file:consult(File) of
		{ok, Terms} ->
			{Nodes, Rels} = classify_terms(Terms),
			ok = validate(?NREF_START, Nodes),
			ok = validate_relationships(Rels),
			%% Allocate atom-label nrefs from a local counter in the
			%% permanent tier [?LABEL_START, ?NREF_START).  The runtime
			%% floor is set later by graphdb:start/2's phase flip, not here.
			SymTable = build_symbol_table(Nodes, Rels, ?LABEL_START, ?NREF_START),
			logger:info("graphdb_bootstrap: allocated ~p label nrefs from ~p",
				[maps:size(SymTable), ?LABEL_START]),
			{ResNodes, ResRels} = apply_symbol_table(Nodes, Rels, SymTable),
			ok = validate_no_unresolved_labels(ResNodes, ResRels),
			ok = write_nodes(ResNodes),
			ok = write_relationships(ResRels),
			ok = rebuild_and_verify_caches(),
			ok = case graphdb_nrefs:verify() of
				ok -> ok;
				{error, _} = E -> throw(E)
			end,
			logger:info("graphdb_bootstrap: loaded ~p nodes, ~p relationship pairs",
				[length(ResNodes), length(ResRels)]),
			ok;
		{error, Reason} ->
			throw({error, {consult_failed, File, Reason}})
	end.
```

- [ ] **Step 3: Delete `validate_label_start/2`**

Remove the entire `validate_label_start/2` function (lines ~270-281) and its doc comment.

- [ ] **Step 4: Rewrite `classify_terms` to a 2-tuple (no directives)**

Replace `classify_terms/1` and the `classify_terms/5` clauses (lines ~327-end of that function) with:

```erlang
%%-----------------------------------------------------------------------------
%% classify_terms(Terms) -> {SortedNodes, Relationships}
%%
%% Partitions the flat term list into node terms (sorted by kind, category
%% first) and relationship terms (file order).  Tier boundaries are header
%% macros, not directives — any non node/relationship term is rejected.
%%-----------------------------------------------------------------------------
classify_terms(Terms) ->
	classify_terms(Terms, [], []).

classify_terms([], Nodes, Rels) ->
	{sort_nodes_by_kind(lists:reverse(Nodes)), lists:reverse(Rels)};
classify_terms([{node, _, _, _, _} = Node | Rest], Nodes, Rels) ->
	classify_terms(Rest, [Node | Nodes], Rels);
classify_terms([{relationship, _, _, _, _, _, _, _} = Rel | Rest], Nodes, Rels) ->
	classify_terms(Rest, Nodes, [Rel | Rels]);
classify_terms([Other | _Rest], _Nodes, _Rels) ->
	throw({error, {unknown_term, Other}}).
```

- [ ] **Step 5: Update the export list**

In the export list (lines ~104-110), remove `validate_label_start/2` and `classify_terms/5` if present; keep `classify_terms/1`, `build_symbol_table/4`, `collect_labels/2`. Confirm `classify_terms/1` remains exported for the EUnit tests.

- [ ] **Step 6: Remove the directives from `bootstrap.terms`**

In `apps/graphdb/priv/bootstrap.terms`, delete the two directive lines `{nref_start, 1000000}.` and `{label_start, 10001}.` Update the tier-comment header block (lines ~11-29) to state the boundaries are `?LABEL_START`/`?NREF_START` macros in `graphdb_nrefs.hrl` (not file directives), and that `set_floor` is performed by `graphdb:start/2`, not the loader.

- [ ] **Step 7: Compile**

Run: `./rebar3 compile`
Expected: success. (If the compiler reports `validate_label_start/2` undefined in tests, that is fixed in Step 9.)

- [ ] **Step 8: Fix the EUnit `graphdb_bootstrap_tests`**

In `apps/graphdb/test/graphdb_bootstrap_tests.erl`:

  - **Delete** these tests entirely (directive behaviour no longer exists): `classify_terms_missing_nref_start_test`, `classify_terms_missing_label_start_test`, `classify_terms_duplicate_nref_start_test`, `classify_terms_duplicate_label_start_test`, `classify_terms_invalid_nref_start_test`, `classify_terms_zero_nref_start_test`, `classify_terms_invalid_label_start_test`, `classify_terms_zero_label_start_test`, `classify_terms_empty_test`, `classify_terms_nref_start_only_test`, `classify_terms_both_directives_only_test`, `classify_terms_directives_in_any_order_test`, and the whole `validate_label_start_*` group (`_valid_`, `_at_floor_`, `_above_floor_`, `_zero_`, `_negative_`).
  - **Update** the surviving `classify_terms_*` tests to drop directive terms from inputs and match the 2-tuple return:
    - `classify_terms_valid_test`, `classify_terms_sorts_by_kind_test`, `classify_terms_preserves_relationship_order_test`, `classify_terms_all_four_kinds_test`, `classify_terms_unknown_term_test`: remove the `{nref_start, _}` / `{label_start, _}` elements from each `Terms` list, and change destructuring from `{_, _, Nodes, _}` / `{_, _, _, Rels}` to `{Nodes, _}` / `{_, Rels}`.
    - `classify_terms_unknown_term_test`: input becomes just `[{bogus, stuff}]`; expectation becomes `?assertThrow({error, {unknown_term, {bogus, stuff}}}, graphdb_bootstrap:classify_terms([{bogus, stuff}]))`.
    - Add a new `classify_terms_empty_returns_empty_test() -> ?assertEqual({[], []}, graphdb_bootstrap:classify_terms([])).`
  - The `build_symbol_table_*` tests already call `build_symbol_table/4` with literal `10001, 1000000` — leave them unchanged.

- [ ] **Step 9: Fix the CT `graphdb_bootstrap_SUITE`**

In `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`:

  - **Delete** `load_nref_floor_set` (the loader no longer sets the floor — that is now covered by `graphdb_nref_SUITE`) and `load_missing_nref_start` (no such directive). Remove both from the `all/0` / group list (lines ~78-79, 117-119) and their function bodies.
  - **Update** `load_invalid_terms` (line ~520): change the written file content from `"{nref_start, 100}.\n{label_start, 50}.\n{bogus, stuff}.\n"` to `"{bogus, stuff}.\n"`, and the expected error from whatever it was to `{error, {unknown_term, {bogus, stuff}}}`.
  - **Update** `load_nref_above_floor` (line ~544): the fixture must now exceed the macro floor. Change the file content to a single node at the floor: `"{node, 1000000, category, {17, \"X\"}, []}.\n"` and the expectation to `?assertMatch({error, {nref_not_below_floor, 1000000, 1000000}}, Result).` Remove the `{nref_start, 10}.` / `{label_start, 5}.` lines.
  - The permanent-tier label assertions in `load_english_instance` / `load_labeled_nodes` (lines 454, 466, 469) already check `< 1000000`; replace the literal `1000000` with `?NREF_START` for consistency (the suite already includes `graphdb_nrefs.hrl`).

- [ ] **Step 10: Run both bootstrap test sets**

Run: `./rebar3 eunit --module=graphdb_bootstrap_tests && ./rebar3 ct --suite apps/graphdb/test/graphdb_bootstrap_SUITE`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add apps/graphdb/src/graphdb_bootstrap.erl apps/graphdb/priv/bootstrap.terms \
        apps/graphdb/test/graphdb_bootstrap_tests.erl apps/graphdb/test/graphdb_bootstrap_SUITE.erl
git commit -m "graphdb_bootstrap: source tier boundaries from macros; drop directives + loader set_floor"
```

---

## Task 10: Full-suite green + documentation

**Files:**
- Modify: `ARCHITECTURE.md`, `CLAUDE.md`, `apps/graphdb/CLAUDE.md`

- [ ] **Step 1: Run the entire test suite**

Run: `./rebar3 ct && ./rebar3 eunit`
Expected: PASS — all CT + EUnit green (CT count is +6 from the new `graphdb_nref_SUITE`, minus the deleted bootstrap cases).

- [ ] **Step 2: Update `ARCHITECTURE.md`**

In the nref-tier section: state that init seeds now occupy the permanent tier; boundaries are `?LABEL_START` / `?NREF_START` macros in `graphdb_nrefs.hrl` (no longer `bootstrap.terms` directives); add `graphdb_nref` to the supervision tree (first child of `graphdb_sup`) as the switchable allocation facade; note the permanent→runtime phase flip in `graphdb:start/2`.

- [ ] **Step 3: Update `CLAUDE.md` (root)**

Update the nref-spaces bullet: permanent tier `[10001, 1000000)` holds bootstrap labels **and** init seeds; allocation goes through `graphdb_nref` (permanent during init, runtime after the `graphdb:start/2` flip). Add `graphdb_nref` to the supervision-tree diagram under `graphdb_sup`.

- [ ] **Step 4: Update `apps/graphdb/CLAUDE.md`**

  - Add `graphdb_nref.erl` to the Files table (switchable node-nref allocation facade).
  - Add it to the supervisor child list / responsibilities.
  - Update the Environment nref-spaces bullet (init seeds permanent; macros authoritative).
  - **Fix the stale claim** that `graphdb_sup` is started "not by `graphdb:start/2`" — graphdb is a peer app (since E5) and `graphdb:start/2` is invoked (and now performs the phase flip).
  - Update the `graphdb_bootstrap` description: loader uses a local counter for labels in the permanent tier and no longer calls `set_floor` (the flip does).

- [ ] **Step 5: Commit**

```bash
git add ARCHITECTURE.md CLAUDE.md apps/graphdb/CLAUDE.md
git commit -m "docs: graphdb_nref facade, permanent-tier init seeds, phase flip; fix stale start/2 claim"
```

- [ ] **Step 6: Mark the spec accepted**

In `docs/designs/permanent-tier-nref-allocator-design.md`, change `**Status:** Draft — pending review` to `**Status:** Implemented`. Commit:

```bash
git add docs/designs/permanent-tier-nref-allocator-design.md
git commit -m "design: mark permanent-tier nref facade spec Implemented"
```

---

## Notes for the implementer

- **Relationship IDs stay on `rel_id_server`** — never route `rel_id_server:get_id*` through `graphdb_nref`. They are a separate id space, not node nrefs.
- **The loader keeps its own counter** — do not route `build_symbol_table` through `graphdb_nref` (D10). The facade computes-from-DB *past* the loader's labels, so they never overlap.
- **Phase default is permanent** (`persistent_term` unset → permanent). Test harnesses set it explicitly per testcase for determinism and erase it in teardown, because `persistent_term` persists across testcases within a CT node.
- **Indentation:** `graphdb_attr/class/mgr` suites use tabs; `graphdb_language/instance/query` use spaces. Match each file.
