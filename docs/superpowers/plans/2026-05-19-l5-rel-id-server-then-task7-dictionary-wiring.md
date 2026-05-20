# L5 + Task 7 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (L5) Extract relationship row IDs into a dedicated `rel_id_server` gen_server so arc PKs no longer consume graph-visible nref integers; (Task 7) wire `dictionary_server` and `term_server` to `dictionary_imp` so the dictionary layer is functional.

**Architecture:** `rel_id_server` is a new DETS-backed gen_server in the graphdb app, started as the first child of `graphdb_sup` before `graphdb_mgr`. All 23 `nref_server:get_nref()` calls that assign to `#relationship{id}` fields are migrated to `rel_id_server:get_id()`. Dictionary wiring: each stub gen_server delegates init/terminate to `dictionary_imp:start_dictionary/stop_dictionary` and forwards CRUD calls to `dictionary_imp` helpers.

**Tech Stack:** Erlang/OTP 27, rebar3 3.24, Mnesia, DETS, ETS, Common Test.

---

## Codebase Quick-Reference

### Dallas's file header pattern (all new Erlang files)

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-19
%% Description: <one line>
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-05-19 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026-05-19 Author: David W. Thomas
%%
%%---------------------------------------------------------------------
```

### NYI / UEM macros (copy-paste into every new module)

```erlang
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).
```

### Key call-site classification (L5 migration)

| File                    | Lines         | Variable(s)                             | Dest field         | Action |
|-------------------------|---------------|-----------------------------------------|--------------------|--------|
| `graphdb_bootstrap.erl` | 548–549       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_attr.erl`      | 493–494       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_attr.erl`      | 537–540       | `Id1`, `Id2`, `Id3`, `Id4`              | `#relationship.id` | CHANGE |
| `graphdb_class.erl`     | 423–424       | `TaxId1`, `TaxId2`                      | `#relationship.id` | CHANGE |
| `graphdb_class.erl`     | 426–427       | `TmplCompId1`, `TmplCompId2`            | `#relationship.id` | CHANGE |
| `graphdb_class.erl`     | 516–517       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_class.erl`     | 579–580       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_instance.erl`  | 457–460       | `MembId1`, `MembId2`, `CompId1`, `CompId2` | `#relationship.id` | CHANGE |
| `graphdb_instance.erl`  | 705–706       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_instance.erl`  | 755–756       | `Id1`, `Id2`                            | `#relationship.id` | CHANGE |
| `graphdb_language.erl`  | 428–429       | `ArcId1`, `ArcId2` (in do_register_language) | `#relationship.id` | CHANGE |
| `graphdb_language.erl`  | 602–603       | `ArcId1`, `ArcId2` (in do_register_dialect) | `#relationship.id` | CHANGE |
| `graphdb_language.erl`  | 665–666       | `ArcId1`, `ArcId2` (in do_set_labels)   | `#relationship.id` | CHANGE |
| `graphdb_bootstrap.erl` | 391           | `Nref`                                  | symbol table nref  | KEEP   |
| `graphdb_attr.erl`      | 485, 535–536  | `Nref`, `FwdNref`, `RevNref`            | `#node.nref`       | KEEP   |
| `graphdb_class.erl`     | 422, 425, 578 | `ClassNref`, `TemplateNref`             | `#node.nref`       | KEEP   |
| `graphdb_instance.erl`  | 456           | `Nref`                                  | `#node.nref`       | KEEP   |
| `graphdb_language.erl`  | 420, 601, 664 | `Nref`                                  | `#node.nref`       | KEEP   |

### CT suite cleanup pattern (existing)

All 6 CT suites follow this `end_per_testcase` pattern (line numbers approximate):

```erlang
end_per_testcase(TC, Config) ->
    verify_cache_invariant(TC),
    catch gen_server:stop(Worker),   %% one or more worker stops
    ...
    catch application:stop(nref),
    catch mnesia:stop(),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    ...
```

After Task 8 each suite gains:
- `catch gen_server:stop(rel_id_server),` — before `catch application:stop(nref)`
- `catch dets:close(rel_id_server),` — after `catch dets:close(nref_server)`

And each suite's `init_per_testcase` gains:
- `{ok, _} = rel_id_server:start_link(),` — immediately before any `graphdb_mgr:start_link()` call (or after `application:ensure_all_started(nref)` for suites that start graphdb_mgr in individual test cases)

---

## Task 1: Create `apps/graphdb/src/rel_id_server.erl`

**Files:**
- Create: `apps/graphdb/src/rel_id_server.erl`
- Create: `apps/graphdb/test/rel_id_server_SUITE.erl`

- [ ] **Step 1: Write `apps/graphdb/test/rel_id_server_SUITE.erl` (failing — module doesn't exist yet)**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(rel_id_server_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([get_id_returns_integer/1,
         get_id_returns_distinct_values/1,
         get_id_is_monotonic/1,
         persists_counter_across_restart/1]).

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "rel_id_").

all() -> [{group, counter}].

groups() ->
	[{counter, [sequence], [
		get_id_returns_integer,
		get_id_returns_distinct_values,
		get_id_is_monotonic,
		persists_counter_across_restart
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
	{ok, _} = rel_id_server:start_link(),
	[{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
	catch gen_server:stop(rel_id_server),
	catch dets:close(rel_id_server),
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),
	TmpDir = proplists:get_value(tmp_dir, Config),
	delete_dir_recursive(TmpDir),
	ok.

%%=============================================================================
%% Test Cases
%%=============================================================================

get_id_returns_integer(_Config) ->
	Id = rel_id_server:get_id(),
	?assert(is_integer(Id)),
	?assert(Id > 0).

get_id_returns_distinct_values(_Config) ->
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
	Id3 = rel_id_server:get_id(),
	?assertNotEqual(Id1, Id2),
	?assertNotEqual(Id2, Id3),
	?assertNotEqual(Id1, Id3).

get_id_is_monotonic(_Config) ->
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
	Id3 = rel_id_server:get_id(),
	?assert(Id2 > Id1),
	?assert(Id3 > Id2).

persists_counter_across_restart(_Config) ->
	Id1 = rel_id_server:get_id(),
	_Id2 = rel_id_server:get_id(),
	Id3 = rel_id_server:get_id(),
	ok = gen_server:stop(rel_id_server),
	catch dets:close(rel_id_server),
	{ok, _} = rel_id_server:start_link(),
	Id4 = rel_id_server:get_id(),
	?assert(Id4 > Id3),
	?assert(Id4 > Id1).

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

- [ ] **Step 2: Attempt compile — expect failure (rel_id_server undefined)**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=graphdb --suite=rel_id_server_SUITE 2>&1 | head -20
```

Expected: compile error referencing `rel_id_server` undefined.

- [ ] **Step 3: Create `apps/graphdb/src/rel_id_server.erl`**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-19
%% Description: rel_id_server allocates unique integer IDs for the
%%              #relationship{id} primary key.  Separate from
%%              nref_server so that arc-row IDs do not consume
%%              graph-visible nref integers.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-05-19 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026-05-19 Author: David W. Thomas
%%
%%---------------------------------------------------------------------
-module(rel_id_server).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: PA1 ').
-created('Date: 2026-05-19').
-created_by('david@davidwt.com').


%%---------------------------------------------------------------------
%% Macro Functions
%%---------------------------------------------------------------------
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
-export([
		start_link/0,
		get_id/0
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------
-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

%%---------------------------------------------------------------------
%% start_link() -> {ok, Pid} | {error, Reason}
%%---------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%---------------------------------------------------------------------
%% get_id() -> Id :: integer()
%%
%% Returns the next unique relationship row ID and advances the counter.
%%---------------------------------------------------------------------
get_id() ->
	gen_server:call(?MODULE, get_id).


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

%%---------------------------------------------------------------------
%% init([]) -> {ok, State}
%%
%% Opens the DETS counter file.  If the file is fresh, seeds the counter
%% to max(1, MaxExistingRelId + 1) by scanning the Mnesia relationships
%% table (wrapped in try/catch — the table may not exist on first start).
%%---------------------------------------------------------------------
init([]) ->
	open("rel_id_server.dets"),
	{ok, []}.

handle_call(get_id, _From, State) ->
	Reply = do_get_id(),
	{reply, Reply, State};
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
	dets:close(?MODULE).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.


%%---------------------------------------------------------------------
%% Private Functions
%%---------------------------------------------------------------------

open(File) ->
	case dets:open_file(?MODULE, [{file, File}]) of
		{ok, ?MODULE} ->
			case dets:member(?MODULE, counter) of
				false -> ok = initialize();
				true  -> ok
			end;
		{error, Reason} ->
			logger:error("cannot open rel_id_server dets: ~p", [Reason]),
			exit({cannot_open_rel_id_server_dets, Reason})
	end.

%%---------------------------------------------------------------------
%% initialize() -> ok
%%
%% Seeds the counter from the Mnesia relationships table if it exists,
%% so that restarting with a deleted DETS file does not re-issue IDs
%% already stored in Mnesia.  Falls back to 1 if Mnesia is unavailable.
%%---------------------------------------------------------------------
initialize() ->
	StartId = seed_from_mnesia(),
	dets:insert(?MODULE, {counter, StartId}).

%% element(2, Rec) is the id field of #relationship{id, kind, ...}.
seed_from_mnesia() ->
	try
		Max = mnesia:dirty_foldl(
			fun(Rec, Acc) -> max(element(2, Rec), Acc) end,
			0,
			relationships),
		max(1, Max + 1)
	catch _:_ -> 1
	end.

do_get_id() ->
	[{counter, N}] = dets:lookup(?MODULE, counter),
	ok = dets:insert(?MODULE, {counter, N + 1}),
	N.
```

- [ ] **Step 4: Compile and run rel_id_server_SUITE**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=graphdb --suite=rel_id_server_SUITE 2>&1 | tail -20
```

Expected: 4 tests pass, zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/rel_id_server.erl apps/graphdb/test/rel_id_server_SUITE.erl
git commit -m "$(cat <<'EOF'
L5: add rel_id_server — DETS-backed counter for relationship row IDs

Separate allocator prevents arc PKs from consuming graph-visible nref
integers.  4 CT cases cover counter basics and DETS persistence.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `rel_id_server` into `graphdb_sup` as first child

**Files:**
- Modify: `apps/graphdb/src/graphdb_sup.erl`

- [ ] **Step 1: In `graphdb_sup.erl` `init/1`, add `rel_id_server` as the first child**

Current `init/1` body (lines 226–232):

```erlang
	{ok, ChSpec1} = childspec(graphdb_mgr),
	{ok, ChSpec2} = childspec(graphdb_rules),
	{ok, ChSpec3} = childspec(graphdb_attr),
	{ok, ChSpec4} = childspec(graphdb_class),
	{ok, ChSpec5} = childspec(graphdb_instance),
	{ok, ChSpec6} = childspec(graphdb_language),
	{ok, {SupFlags, [ChSpec1, ChSpec2, ChSpec3, ChSpec4, ChSpec5, ChSpec6]}};
```

Replace with:

```erlang
	{ok, ChSpec0} = childspec(rel_id_server),
	{ok, ChSpec1} = childspec(graphdb_mgr),
	{ok, ChSpec2} = childspec(graphdb_rules),
	{ok, ChSpec3} = childspec(graphdb_attr),
	{ok, ChSpec4} = childspec(graphdb_class),
	{ok, ChSpec5} = childspec(graphdb_instance),
	{ok, ChSpec6} = childspec(graphdb_language),
	{ok, {SupFlags, [ChSpec0, ChSpec1, ChSpec2, ChSpec3, ChSpec4, ChSpec5, ChSpec6]}};
```

- [ ] **Step 2: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings, zero errors.

- [ ] **Step 3: Commit**

```sh
git add apps/graphdb/src/graphdb_sup.erl
git commit -m "$(cat <<'EOF'
L5: wire rel_id_server as first child of graphdb_sup

Must start before graphdb_mgr because bootstrap calls expand_relationship
which calls rel_id_server:get_id/0.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate `graphdb_bootstrap.erl` — rel ID call sites

**Files:**
- Modify: `apps/graphdb/src/graphdb_bootstrap.erl`

Two relationship ID allocations at lines 548–549.  Line 523 has a comment naming `nref_server:get_nref/0` for IDs — update it.

- [ ] **Step 1: Update comment at line ~523**

Find the comment block that reads:

```erlang
%% unique ID from nref_server:get_nref/0 (allocated outside the
```

Change to:

```erlang
%% unique ID from rel_id_server:get_id/0 (allocated outside the
```

- [ ] **Step 2: Change ID allocations at lines 548–549**

Find:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

(These are immediately before the two `#relationship{}` records whose `id` fields are `Id1` and `Id2` — in `expand_relationship/3`.)

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 3: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings.

- [ ] **Step 4: Commit**

```sh
git add apps/graphdb/src/graphdb_bootstrap.erl
git commit -m "$(cat <<'EOF'
L5: migrate graphdb_bootstrap relationship IDs to rel_id_server

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Migrate `graphdb_attr.erl` — rel ID call sites

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl`

Six relationship ID allocations across two functions.  Line 481 has a comment naming `nref_server:get_nref/0` for ID allocations — update it.

- [ ] **Step 1: Update comment at line ~481**

Find:

```erlang
%% All nref_server:get_nref/0 calls are issued OUTSIDE the Mnesia
```

Change to:

```erlang
%% All nref_server:get_nref/0 (node nrefs) and rel_id_server:get_id/0
%% (relationship IDs) calls are issued OUTSIDE the Mnesia
```

- [ ] **Step 2: Change ID allocations in `do_create_attribute` (lines 493–494)**

Find the pair immediately after `Nref = nref_server:get_nref()`:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 3: Change ID allocations in `do_create_relationship_attribute_pair` (lines 537–540)**

Find the block immediately after `FwdNref = nref_server:get_nref()` and `RevNref = nref_server:get_nref()`:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	Id3 = nref_server:get_nref(),
	Id4 = nref_server:get_nref(),
```

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
	Id3 = rel_id_server:get_id(),
	Id4 = rel_id_server:get_id(),
```

- [ ] **Step 4: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_attr.erl
git commit -m "$(cat <<'EOF'
L5: migrate graphdb_attr relationship IDs to rel_id_server

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate `graphdb_class.erl` — rel ID call sites

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl`

Eight relationship ID allocations across three functions.

- [ ] **Step 1: Change ID allocations in `do_create_class` (lines 423–424 and 426–427)**

Find the block (lines 422–427):

```erlang
		ClassNref      = nref_server:get_nref(),
		TaxId1         = nref_server:get_nref(),
		TaxId2         = nref_server:get_nref(),
		TemplateNref   = nref_server:get_nref(),
		TmplCompId1    = nref_server:get_nref(),
		TmplCompId2    = nref_server:get_nref(),
```

Change to:

```erlang
		ClassNref      = nref_server:get_nref(),
		TaxId1         = rel_id_server:get_id(),
		TaxId2         = rel_id_server:get_id(),
		TemplateNref   = nref_server:get_nref(),
		TmplCompId1    = rel_id_server:get_id(),
		TmplCompId2    = rel_id_server:get_id(),
```

- [ ] **Step 2: Change ID allocations in `do_write_superclass` (lines 516–517)**

Find:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

(In the function that writes taxonomy arc pairs for superclass relationships.)

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 3: Change ID allocations near line 578–580 (default template composition arcs)**

Find the block (lines 578–580):

```erlang
	TemplateNref = nref_server:get_nref(),
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

Change to:

```erlang
	TemplateNref = nref_server:get_nref(),
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 4: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_class.erl
git commit -m "$(cat <<'EOF'
L5: migrate graphdb_class relationship IDs to rel_id_server

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate `graphdb_instance.erl` — rel ID call sites

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

Eight relationship ID allocations across three functions.

- [ ] **Step 1: Change ID allocations in `do_write_instance` (lines 457–460)**

Find the block (lines 456–460):

```erlang
	Nref    = nref_server:get_nref(),
	MembId1 = nref_server:get_nref(),
	MembId2 = nref_server:get_nref(),
	CompId1 = nref_server:get_nref(),
	CompId2 = nref_server:get_nref(),
```

Change to:

```erlang
	Nref    = nref_server:get_nref(),
	MembId1 = rel_id_server:get_id(),
	MembId2 = rel_id_server:get_id(),
	CompId1 = rel_id_server:get_id(),
	CompId2 = rel_id_server:get_id(),
```

- [ ] **Step 2: Change ID allocations in `write_connection_arcs` (lines 705–706)**

Find:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

(In the function that writes two directed connection arc rows.)

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 3: Change ID allocations in `do_write_class_membership` (lines 755–756)**

Find:

```erlang
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
```

(In the function that writes the two membership arc rows, char=29/30.)

Change to:

```erlang
	Id1 = rel_id_server:get_id(),
	Id2 = rel_id_server:get_id(),
```

- [ ] **Step 4: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "$(cat <<'EOF'
L5: migrate graphdb_instance relationship IDs to rel_id_server

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Migrate `graphdb_language.erl` — rel ID call sites

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`

Six relationship ID allocations across three functions (`do_register_language`, `do_register_dialect`, `do_set_labels`).  In each function, the pattern is: one `Nref = nref_server:get_nref()` (KEEP) followed by two arc ID allocations (CHANGE).

- [ ] **Step 1: Change arc ID allocations in `do_register_language` (lines 428–429)**

Find the block (lines 420, 428–429):

```erlang
		Nref = nref_server:get_nref(),
		...
		ArcId1 = nref_server:get_nref(),
		ArcId2 = nref_server:get_nref(),
```

Change only the two `ArcId` lines:

```erlang
		ArcId1 = rel_id_server:get_id(),
		ArcId2 = rel_id_server:get_id(),
```

- [ ] **Step 2: Change arc ID allocations in `do_register_dialect` (lines 602–603)**

Find the block (lines 601–603):

```erlang
	Nref   = nref_server:get_nref(),
	ArcId1 = nref_server:get_nref(),
	ArcId2 = nref_server:get_nref(),
```

Change only the two `ArcId` lines:

```erlang
	ArcId1 = rel_id_server:get_id(),
	ArcId2 = rel_id_server:get_id(),
```

- [ ] **Step 3: Change arc ID allocations in `do_set_labels` (lines 665–666)**

Find the block (lines 664–666):

```erlang
		Nref   = nref_server:get_nref(),
		ArcId1 = nref_server:get_nref(),
		ArcId2 = nref_server:get_nref(),
```

Change only the two `ArcId` lines:

```erlang
		ArcId1 = rel_id_server:get_id(),
		ArcId2 = rel_id_server:get_id(),
```

- [ ] **Step 4: Compile**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 compile 2>&1 | tail -10
```

Expected: zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/graphdb/src/graphdb_language.erl
git commit -m "$(cat <<'EOF'
L5: migrate graphdb_language relationship IDs to rel_id_server

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Update 6 CT suites for `rel_id_server` lifecycle

**Files:**
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_bootstrap_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_class_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

Each suite needs: start `rel_id_server` before `graphdb_mgr`; stop + close DETS in cleanup.

### graphdb_attr_SUITE.erl

- [ ] **Step 1: In `init_per_testcase`, add `rel_id_server:start_link()` before `graphdb_mgr:start_link()`**

Find (lines 166–168):

```erlang
	%% Start graphdb_mgr to trigger bootstrap load (populates Mnesia)
	{ok, _} = graphdb_mgr:start_link(),
```

Change to:

```erlang
	%% Start rel_id_server before graphdb_mgr (bootstrap calls get_id/0)
	{ok, _} = rel_id_server:start_link(),
	%% Start graphdb_mgr to trigger bootstrap load (populates Mnesia)
	{ok, _} = graphdb_mgr:start_link(),
```

- [ ] **Step 2: In `end_per_testcase`, add stop before `application:stop(nref)` and close DETS after `dets:close(nref_server)`**

Find (lines 190–195):

```erlang
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	catch application:stop(nref),
	catch mnesia:stop(),
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
```

Change to:

```erlang
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	catch gen_server:stop(rel_id_server),
	catch application:stop(nref),
	catch mnesia:stop(),
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
	catch dets:close(rel_id_server),
```

### graphdb_bootstrap_SUITE.erl

- [ ] **Step 3: In `init_per_testcase`, add `rel_id_server:start_link()` after `application:ensure_all_started(nref)`**

Find (lines 171–173):

```erlang
	{ok, _} = application:ensure_all_started(nref),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].
```

Change to:

```erlang
	{ok, _} = application:ensure_all_started(nref),
	{ok, _} = rel_id_server:start_link(),

	[{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].
```

- [ ] **Step 4: In `end_per_testcase`, add stop before `application:stop(nref)` and close DETS after `dets:close(nref_server)`**

Find (lines 185–190):

```erlang
	%% Stop applications (ignore errors — they may not be running)
	catch application:stop(nref),
	catch mnesia:stop(),

	%% Close any lingering DETS tables
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
```

Change to:

```erlang
	%% Stop rel_id_server before nref app
	catch gen_server:stop(rel_id_server),
	%% Stop applications (ignore errors — they may not be running)
	catch application:stop(nref),
	catch mnesia:stop(),

	%% Close any lingering DETS tables
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
	catch dets:close(rel_id_server),
```

### graphdb_class_SUITE.erl

- [ ] **Step 5: In `init_per_testcase`, add `rel_id_server:start_link()` before `graphdb_mgr:start_link()`**

Apply the same pattern as graphdb_attr_SUITE Step 1 — find the line that starts `graphdb_mgr:start_link()` and prepend `{ok, _} = rel_id_server:start_link(),`.

- [ ] **Step 6: In `end_per_testcase`, add stop + DETS close for rel_id_server**

Find (lines 230–236):

```erlang
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	...
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
```

Add `catch gen_server:stop(rel_id_server),` after `catch gen_server:stop(graphdb_mgr),`, and `catch dets:close(rel_id_server),` after `catch dets:close(nref_allocator),`.

### graphdb_instance_SUITE.erl

- [ ] **Step 7: In `init_per_testcase`, add `rel_id_server:start_link()` before `graphdb_mgr:start_link()`**

Same pattern as Steps 1 and 5.

- [ ] **Step 8: In `end_per_testcase`, add stop + DETS close for rel_id_server**

Find (lines 252–259):

```erlang
	catch gen_server:stop(graphdb_instance),
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	catch gen_server:stop(graphdb_mgr),
	...
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
```

Add `catch gen_server:stop(rel_id_server),` after `catch gen_server:stop(graphdb_mgr),`, and `catch dets:close(rel_id_server),` after `catch dets:close(nref_allocator),`.

### graphdb_language_SUITE.erl

- [ ] **Step 9: In `init_per_testcase`, add `rel_id_server:start_link()` before `graphdb_mgr:start_link()`**

Same pattern.

- [ ] **Step 10: In `end_per_testcase`, add stop + DETS close for rel_id_server**

Same pattern — add after the last `gen_server:stop` and after `dets:close(nref_allocator)`.

### graphdb_mgr_SUITE.erl

- [ ] **Step 11: In the write-delegation `init_per_testcase` clause, add `rel_id_server:start_link()` before `graphdb_mgr:start_link()`**

Find (line 203):

```erlang
	{ok, _} = graphdb_mgr:start_link(),
```

This clause is guarded by a `when TC =:= create_name_attribute_delegates; ...` guard. Add before it:

```erlang
	{ok, _} = rel_id_server:start_link(),
	{ok, _} = graphdb_mgr:start_link(),
```

- [ ] **Step 12: In `end_per_testcase`, add stop + DETS close for rel_id_server**

Find (lines 243–255):

```erlang
	catch gen_server:stop(graphdb_instance),
	catch gen_server:stop(graphdb_class),
	catch gen_server:stop(graphdb_attr),
	...
	catch gen_server:stop(graphdb_mgr),
	...
	catch dets:close(nref_server),
	catch dets:close(nref_allocator),
```

Add `catch gen_server:stop(rel_id_server),` after the `catch gen_server:stop(graphdb_mgr),` line, and `catch dets:close(rel_id_server),` after `catch dets:close(nref_allocator),`.

### Run full test suite

- [ ] **Step 13: Run the full graphdb CT suite and verify all tests pass**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=graphdb 2>&1 | tail -30
```

Expected: all 192 CT tests pass, zero failures, zero warnings.

- [ ] **Step 14: Run EUnit suite as well**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 eunit --app=graphdb 2>&1 | tail -10
```

Expected: 99 EUnit tests pass.

- [ ] **Step 15: Commit**

```sh
git add apps/graphdb/test/
git commit -m "$(cat <<'EOF'
L5: update 6 CT suites for rel_id_server lifecycle

Each suite starts rel_id_server before graphdb_mgr and cleans up both
the gen_server and the DETS file in end_per_testcase.  All 291 tests
(192 CT + 99 EUnit) pass.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wire `dictionary_server` to `dictionary_imp`

**Files:**
- Modify: `apps/dictionary/src/dictionary_server.erl`
- Create:  `apps/dictionary/test/dictionary_server_SUITE.erl`

### dictionary_imp API reminder

```erlang
dictionary_imp:start_dictionary(File, ProcName) -> ok
dictionary_imp:stop_dictionary(File, ProcName)  -> ok
dictionary_imp:create(ProcName, Key)            -> true | false
dictionary_imp:read(ProcName, Key)              -> [{Key, Value}] | []
dictionary_imp:update(ProcName, Key, Value)     -> true
dictionary_imp:delete(ProcName, Key)            -> true
dictionary_imp:all(ProcName)                    -> [{Key, Value}]
dictionary_imp:size(ProcName)                   -> integer()
```

`start_dictionary` spawns an unlinked, unsupervised loop process registered as `ProcName`.  Do NOT link or monitor it — leave it unsupervised; its gen_server is supervised.

`data_path` config: `application:get_env(seerstone_graph_db, data_path, "data")`.

- [ ] **Step 1: Write `apps/dictionary/test/dictionary_server_SUITE.erl` (tests first)**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(dictionary_server_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([create_returns_true/1,
         read_existing_key/1,
         read_missing_key/1,
         update_existing_key/1,
         delete_existing_key/1,
         all_returns_pairs/1,
         size_returns_count/1]).

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "dict_").

all() -> [{group, crud}].

groups() ->
	[{crud, [sequence], [
		create_returns_true,
		read_existing_key,
		read_missing_key,
		update_existing_key,
		delete_existing_key,
		all_returns_pairs,
		size_returns_count
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
	application:set_env(seerstone_graph_db, data_path, TmpDir),
	{ok, _} = dictionary_server:start_link(),
	[{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
	catch gen_server:stop(dictionary_server),
	application:unset_env(seerstone_graph_db, data_path),
	TmpDir = proplists:get_value(tmp_dir, Config),
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),
	delete_dir_recursive(TmpDir),
	ok.

%%=============================================================================
%% Test Cases
%%=============================================================================

create_returns_true(_Config) ->
	?assertEqual(true, dictionary_server:create("hello")).

read_existing_key(_Config) ->
	true = dictionary_server:create("greet"),
	true = dictionary_server:update("greet", "hi"),
	Result = dictionary_server:read("greet"),
	?assertMatch([{_, "hi"}], Result).

read_missing_key(_Config) ->
	?assertEqual([], dictionary_server:read("no_such_key")).

update_existing_key(_Config) ->
	true = dictionary_server:create("color"),
	true = dictionary_server:update("color", "blue"),
	true = dictionary_server:update("color", "red"),
	[{_, Val}] = dictionary_server:read("color"),
	?assertEqual("red", Val).

delete_existing_key(_Config) ->
	true = dictionary_server:create("temp"),
	true = dictionary_server:delete("temp"),
	?assertEqual([], dictionary_server:read("temp")).

all_returns_pairs(_Config) ->
	true = dictionary_server:create("k1"),
	true = dictionary_server:create("k2"),
	true = dictionary_server:update("k1", "v1"),
	true = dictionary_server:update("k2", "v2"),
	Pairs = dictionary_server:all(),
	?assert(length(Pairs) >= 2).

size_returns_count(_Config) ->
	?assert(is_integer(dictionary_server:size())),
	true = dictionary_server:create("x"),
	N = dictionary_server:size(),
	?assert(N >= 1).

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

- [ ] **Step 2: Attempt compile — expect failure (dictionary_server:create/1 undefined)**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=dictionary --suite=dictionary_server_SUITE 2>&1 | head -20
```

Expected: compile error because `dictionary_server` only exports `start_link/0`.

- [ ] **Step 3: Replace `apps/dictionary/src/dictionary_server.erl` with full wired implementation**

Keep the existing copyright/header block and module attributes; replace `start_link/0` + gen_server callbacks with:

```erlang
%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: PA1 ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: Month Day, Year 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%---------------------------------------------------------------------
%% Records
%%---------------------------------------------------------------------
-record(state, {
	imp_proc,  %% atom() — registered name of the dictionary_imp process
	file       %% string() — backing ETS file path
}).


%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		create/1,
		read/1,
		update/2,
		delete/1,
		all/0,
		size/0
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------
-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(Key)        -> gen_server:call(?MODULE, {create, Key}).
read(Key)          -> gen_server:call(?MODULE, {read, Key}).
update(Key, Value) -> gen_server:call(?MODULE, {update, Key, Value}).
delete(Key)        -> gen_server:call(?MODULE, {delete, Key}).
all()              -> gen_server:call(?MODULE, all).
size()             -> gen_server:call(?MODULE, size).


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

init([]) ->
	DataPath = application:get_env(seerstone_graph_db, data_path, "data"),
	File = filename:join(DataPath, "dictionary.dat"),
	ok = dictionary_imp:start_dictionary(File, dictionary),
	{ok, #state{imp_proc = dictionary, file = File}}.

handle_call({create, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:create(P, Key), State};
handle_call({read, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:read(P, Key), State};
handle_call({update, Key, Value}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:update(P, Key, Value), State};
handle_call({delete, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:delete(P, Key), State};
handle_call(all, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:all(P), State};
handle_call(size, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:size(P), State};
handle_call(Request, From, State) ->
	?UEM(handle_call, {Request, From, State}),
	{noreply, State}.

handle_cast(Message, State) ->
	?UEM(handle_cast, {Message, State}),
	{noreply, State}.

handle_info(Info, State) ->
	?UEM(handle_info, {Info, State}),
	{noreply, State}.

terminate(_Reason, #state{imp_proc = P, file = F}) ->
	dictionary_imp:stop_dictionary(F, P).

code_change(_OldVsn, State, _Extra) ->
	?NYI(code_change),
	{ok, State}.
```

- [ ] **Step 4: Run dictionary_server_SUITE**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=dictionary --suite=dictionary_server_SUITE 2>&1 | tail -20
```

Expected: 7 tests pass, zero warnings.

- [ ] **Step 5: Commit**

```sh
git add apps/dictionary/src/dictionary_server.erl apps/dictionary/test/dictionary_server_SUITE.erl
git commit -m "$(cat <<'EOF'
Task 7a: wire dictionary_server to dictionary_imp; 7 CT tests green

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Wire `term_server` to `dictionary_imp`

**Files:**
- Modify: `apps/dictionary/src/term_server.erl`
- Create:  `apps/dictionary/test/term_server_SUITE.erl`

`term_server` is identical in structure to `dictionary_server` but uses proc name `terms` and file `"terms.dat"`.

- [ ] **Step 1: Write `apps/dictionary/test/term_server_SUITE.erl`**

Copy `dictionary_server_SUITE.erl`, then make these substitutions:
- `-module(term_server_SUITE).`
- `?DIR_PREFIX = "term_"` 
- Replace every `dictionary_server:` call with `term_server:`
- Replace every `?assertEqual(true, dictionary_server:create(...))` etc. with `term_server:...`

Full file:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(term_server_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([create_returns_true/1,
         read_existing_key/1,
         read_missing_key/1,
         update_existing_key/1,
         delete_existing_key/1,
         all_returns_pairs/1,
         size_returns_count/1]).

-define(SCRATCH_SENTINEL, "_build/test/ct_scratch/").
-define(DIR_PREFIX, "term_").

all() -> [{group, crud}].

groups() ->
	[{crud, [sequence], [
		create_returns_true,
		read_existing_key,
		read_missing_key,
		update_existing_key,
		delete_existing_key,
		all_returns_pairs,
		size_returns_count
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
	application:set_env(seerstone_graph_db, data_path, TmpDir),
	{ok, _} = term_server:start_link(),
	[{tmp_dir, TmpDir} | Config].

end_per_testcase(_TC, Config) ->
	catch gen_server:stop(term_server),
	application:unset_env(seerstone_graph_db, data_path),
	TmpDir = proplists:get_value(tmp_dir, Config),
	OrigCwd = proplists:get_value(orig_cwd, Config),
	ok = file:set_cwd(OrigCwd),
	delete_dir_recursive(TmpDir),
	ok.

%%=============================================================================
%% Test Cases
%%=============================================================================

create_returns_true(_Config) ->
	?assertEqual(true, term_server:create("hello")).

read_existing_key(_Config) ->
	true = term_server:create("greet"),
	true = term_server:update("greet", "hi"),
	Result = term_server:read("greet"),
	?assertMatch([{_, "hi"}], Result).

read_missing_key(_Config) ->
	?assertEqual([], term_server:read("no_such_key")).

update_existing_key(_Config) ->
	true = term_server:create("color"),
	true = term_server:update("color", "blue"),
	true = term_server:update("color", "red"),
	[{_, Val}] = term_server:read("color"),
	?assertEqual("red", Val).

delete_existing_key(_Config) ->
	true = term_server:create("temp"),
	true = term_server:delete("temp"),
	?assertEqual([], term_server:read("temp")).

all_returns_pairs(_Config) ->
	true = term_server:create("k1"),
	true = term_server:create("k2"),
	true = term_server:update("k1", "v1"),
	true = term_server:update("k2", "v2"),
	Pairs = term_server:all(),
	?assert(length(Pairs) >= 2).

size_returns_count(_Config) ->
	?assert(is_integer(term_server:size())),
	true = term_server:create("x"),
	N = term_server:size(),
	?assert(N >= 1).

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

- [ ] **Step 2: Replace `apps/dictionary/src/term_server.erl` with wired implementation**

Same structure as `dictionary_server.erl`.  Key differences:
- `imp_proc = terms` (registered name of the `dictionary_imp` loop process)
- `File = filename:join(DataPath, "terms.dat")`

Full gen_server callback section (keep existing header/attributes):

```erlang
%%---------------------------------------------------------------------
%% Records
%%---------------------------------------------------------------------
-record(state, {
	imp_proc,  %% atom() — registered name of the dictionary_imp process
	file       %% string() — backing ETS file path
}).


%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		create/1,
		read/1,
		update/2,
		delete/1,
		all/0,
		size/0
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------
-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(Key)        -> gen_server:call(?MODULE, {create, Key}).
read(Key)          -> gen_server:call(?MODULE, {read, Key}).
update(Key, Value) -> gen_server:call(?MODULE, {update, Key, Value}).
delete(Key)        -> gen_server:call(?MODULE, {delete, Key}).
all()              -> gen_server:call(?MODULE, all).
size()             -> gen_server:call(?MODULE, size).


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

init([]) ->
	DataPath = application:get_env(seerstone_graph_db, data_path, "data"),
	File = filename:join(DataPath, "terms.dat"),
	ok = dictionary_imp:start_dictionary(File, terms),
	{ok, #state{imp_proc = terms, file = File}}.

handle_call({create, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:create(P, Key), State};
handle_call({read, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:read(P, Key), State};
handle_call({update, Key, Value}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:update(P, Key, Value), State};
handle_call({delete, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:delete(P, Key), State};
handle_call(all, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:all(P), State};
handle_call(size, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:size(P), State};
handle_call(Request, From, State) ->
	?UEM(handle_call, {Request, From, State}),
	{noreply, State}.

handle_cast(Message, State) ->
	?UEM(handle_cast, {Message, State}),
	{noreply, State}.

handle_info(Info, State) ->
	?UEM(handle_info, {Info, State}),
	{noreply, State}.

terminate(_Reason, #state{imp_proc = P, file = F}) ->
	dictionary_imp:stop_dictionary(F, P).

code_change(_OldVsn, State, _Extra) ->
	?NYI(code_change),
	{ok, State}.
```

- [ ] **Step 3: Run term_server_SUITE**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct --app=dictionary --suite=term_server_SUITE 2>&1 | tail -20
```

Expected: 7 tests pass, zero warnings.

- [ ] **Step 4: Run all tests to confirm nothing regressed**

```sh
cd /c/dev/SeerStoneGraphDb && ./rebar3 ct && ./rebar3 eunit 2>&1 | tail -20
```

Expected: all CT + EUnit tests pass.

- [ ] **Step 5: Commit**

```sh
git add apps/dictionary/src/term_server.erl apps/dictionary/test/term_server_SUITE.erl
git commit -m "$(cat <<'EOF'
Task 7b: wire term_server to dictionary_imp; 7 CT tests green

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Update `TASKS.md` — mark L5 and Task 7 RESOLVED

**Files:**
- Modify: `TASKS.md`

- [ ] **Step 1: In `TASKS.md`, mark the L5 section RESOLVED**

Find the `### L5.` section header (around line 820).  Add `**RESOLVED** (2026-05-19)` to the header line and a one-line resolution note.  Change:

```markdown
### L5. Relationship row IDs allocated from the global `nref_server`
```

To:

```markdown
### L5. Relationship row IDs allocated from the global `nref_server` — **RESOLVED** (2026-05-19)

`rel_id_server` gen_server added to `apps/graphdb/src/`; all 23 `#relationship.id`
allocations migrated from `nref_server:get_nref/0` to `rel_id_server:get_id/0`.
```

- [ ] **Step 2: In `TASKS.md`, mark the Task 7 section RESOLVED**

Find the `### Task 7.` section header (around line 836).  Apply the same treatment:

```markdown
### Task 7. Wire `dictionary_server` and `term_server` to `dictionary_imp` — **RESOLVED** (2026-05-19)

Both gen_servers delegate to `dictionary_imp` via `start_dictionary/stop_dictionary`
in `init/terminate` and forward CRUD calls.  14 CT tests added (7 per server).
```

- [ ] **Step 3: Run table-alignment script on TASKS.md**

```sh
python3 ~/.claude/scripts/align_md_tables.py TASKS.md
```

- [ ] **Step 4: Commit**

```sh
git add TASKS.md
git commit -m "$(cat <<'EOF'
TASKS: mark L5 and Task 7 RESOLVED

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
