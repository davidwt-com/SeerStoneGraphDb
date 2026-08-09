# SP2: Physical Project Store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each registered project its own physical Mnesia table set
(`nodes_<A>` / `relationships_<A>` / `counters_<A>`) and its own nref
allocator starting at 1, so a project's instance space is a distinct,
relocatable unit and the nref-collision defect (project nref 5 vs
environment nref 5) is closed by construction.

**Architecture:** Every project write op and every instance read gains a
`Project` handle (`#{anchor, nodes, rels, counters}`, resolved once by
`graphdb_project:open/1`) that names the three table atoms to use instead of
the literal `nodes`/`relationships`. `graphdb_ns:target_namespace/2` becomes
the live home-relative router (`Home :: environment | Project`). Tier-1
primitives shared between `graphdb_instance`'s project write path and
`graphdb_mgr:mutate/1,2` take a general `Home`; primitives that only ever
run inside a project's own `create_instance`/`add_relationship` cascade take
a concrete `Project` directly, since that cascade is never environment-only.

**Tech Stack:** Erlang/OTP 28, Mnesia (`disc_copies`), rebar3 3.27, Common
Test + EUnit.

## Global Constraints

- Hard tabs in every `apps/graphdb/` source and test file — **except**
  `apps/graphdb/src/graphdb_query.erl` and its test suite, which already use
  space indentation throughout (verified: zero tab characters in the file
  today). Match each file's own existing indentation; do not convert
  `graphdb_query.erl` to tabs as part of this work.
- No shared graphdb records header — every module keeps its own inline
  `-record(node, {...})` / `-record(relationship, {...})` copy. Do not
  introduce a shared `.hrl` for these.
- Small predicates that would otherwise be shared across workers (e.g.
  `is_retired/2`) are deliberately duplicated per module (YAGNI, no new
  shared util module) — follow this precedent for the new `Home`-dispatch
  helpers described in Task 9 rather than centralizing them.
- LOAD-BEARING INVARIANT: no gen_server call may run inside an Mnesia
  transaction fun. `graphdb_nref:get_next()`, `rel_id_server:get_id_pair()`,
  and `graphdb_attr:seeded_nrefs()` are gen_server calls and must happen
  outside the transaction; `mnesia:dirty_update_counter/3` (the new project
  allocator) is a dirty op and is exempt from this rule but must still run
  outside the transaction for the same reason stated in the design (§4):
  calling it inside a transaction Mnesia might restart would burn ids.
  `graphdb_class` reads inside a firing-engine transaction must stay
  `dirty_read`/`dirty_index_read` (existing convention — do not change).
- Every `mutate/1`-composed tier-1 primitive keeps signalling failure via
  `mnesia:abort/1` and never opens its own transaction.
- Design source: `docs/designs/sp2-physical-project-store-design.md`
  (amendments to `docs/designs/project-env-reference-namespace-model-design.md`
  §3 already merged). Read both before starting; this plan assumes their
  content.
- `Project` is always a real handle from `graphdb_project:open/1` in the
  project-scoped write path (`graphdb_instance`) — it is never the atom
  `environment` there. Only `graphdb_mgr:mutate/1,2` and `graphdb_query`
  need the `Home :: environment | Project` duality.
- Run tests with `./rebar3 eunit --app=graphdb` and
  `./rebar3 ct --app=graphdb` (or `make test-ct-parallel` for the fast path)
  from the repo root. `./rebar3` is repo-local; no `source ~/.bashrc` prefix
  needed.

---

## File Structure

| File | Responsibility after this plan |
| --- | --- |
| `apps/graphdb/src/graphdb_ns.erl` | Home-relative routing: `namespace_of/2`, `target_namespace/2`, `node_table/1`, `rel_table/1`. Pure — no gen_server calls, no Mnesia I/O beyond table-name string building. |
| `apps/graphdb/test/graphdb_ns_tests.erl` | Table-driven EUnit coverage of the arity-2 forms across both `Home` values. |
| `apps/graphdb/src/graphdb_project.erl` | Project registry + physical store: `register_project/1` (anchor + tables), `open/1`, `is_project/1`, `require_project/1`, `next_nref/1`, `next_rel_id_pair/1`; canonical project-scoped relationship API (renamed `Session`→`Project`). |
| `apps/graphdb/test/graphdb_project_SUITE.erl` | CT coverage for table creation, `open/1` (including `no_store`), and the counters. |
| `apps/graphdb/src/graphdb_instance.erl` | Every project write/read routes through `Project`; internal cascade (`Ctx`) carries it; tier-1 primitives shared with `mutate` take `Home`. |
| `apps/graphdb/test/graphdb_instance_SUITE.erl` | `proj()` replaces `sess()`; delta assertions read project tables; `invalid_session` → `invalid_project`. |
| `apps/graphdb/src/graphdb_mgr.erl` | New `Project`-taking twins: `get_node/2`, `retire_node/2`, `unretire_node/2`, `update_node_avps/3`, `delete_node/2`, `mutate/2`. Existing `/1` forms stay environment-only, unchanged behaviour. |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl` | `proj()` replaces `sess()`; new tests for the six new entry points. |
| `apps/graphdb/src/graphdb_query.erl` | `new_session/1` binds a `Project`; `session_read_node`/`session_read_arcs` resolve `Home` per nref instead of assuming the environment table. |
| `apps/graphdb/test/graphdb_query_SUITE.erl` | `proj()` replaces `sess()`; new tests for project-scoped reads and the collision-log path. |
| `apps/graphdb/src/graphdb_rules.erl` | Moduledoc/comment polish only — `{project, _}` becomes `{project, Project}` in prose; stub clauses unchanged (still pattern-match `_`). |
| `apps/graphdb/test/graphdb_rules_SUITE.erl` | Dummy `{project, 1}` placeholders become a realistic synthetic `Project` map shape. |
| `apps/graphdb/CLAUDE.md`, `docs/Architecture.md`, `TASKS.md` | Reflect the shipped SP2 surface. |

---

## Task 1: `graphdb_ns` — home-relative routing (arity-2)

**Files:**
- Modify: `apps/graphdb/src/graphdb_ns.erl`
- Test: `apps/graphdb/test/graphdb_ns_tests.erl`

**Interfaces:**
- Produces: `graphdb_ns:namespace_of/2 :: (Home, Role) -> environment | Home`
  where `Role :: characterization | reciprocal | avp_attribute |
  node_classes | taxonomy_parent | compositional_parent | node_nref`.
  `graphdb_ns:target_namespace/2 :: (Home, TargetKind) -> environment | Home`
  where `TargetKind :: category | attribute | class | instance`.
  `graphdb_ns:node_table/1 :: (Home) -> atom()`,
  `graphdb_ns:rel_table/1 :: (Home) -> atom()`, where
  `Home :: environment | #{anchor := integer(), nodes := atom(),
  rels := atom(), counters := atom()}`. Every later task depends on these
  four functions.

- [ ] **Step 1: Write the failing tests**

Replace the whole file (the arity-1 forms it tests are being removed, so
this is a full rewrite, not an addition):

```erlang
-module(graphdb_ns_tests).
-include_lib("eunit/include/eunit.hrl").

-define(PROJECT, #{anchor => 42, nodes => nodes_42,
                    rels => relationships_42, counters => counters_42}).

namespace_of_environment_roles_test() ->
	[ ?assertEqual(environment, graphdb_ns:namespace_of(Home, R))
	  || Home <- [environment, ?PROJECT],
	     R    <- [characterization, reciprocal, avp_attribute,
	              node_classes, taxonomy_parent] ].

namespace_of_home_relative_roles_test() ->
	[ ?assertEqual(Home, graphdb_ns:namespace_of(Home, R))
	  || Home <- [environment, ?PROJECT],
	     R    <- [compositional_parent, node_nref] ].

target_namespace_instance_is_home_test() ->
	[ ?assertEqual(Home, graphdb_ns:target_namespace(Home, instance))
	  || Home <- [environment, ?PROJECT] ].

target_namespace_others_are_environment_test() ->
	[ ?assertEqual(environment, graphdb_ns:target_namespace(Home, K))
	  || Home <- [environment, ?PROJECT],
	     K    <- [category, attribute, class] ].

namespace_of_unknown_role_crashes_test() ->
	?assertError(function_clause, graphdb_ns:namespace_of(environment, bogus_role)).

target_namespace_unknown_kind_crashes_test() ->
	?assertError(function_clause, graphdb_ns:target_namespace(environment, bogus_kind)).

node_table_environment_is_literal_test() ->
	?assertEqual(nodes, graphdb_ns:node_table(environment)).

node_table_project_is_its_own_table_test() ->
	?assertEqual(nodes_42, graphdb_ns:node_table(?PROJECT)).

rel_table_environment_is_literal_test() ->
	?assertEqual(relationships, graphdb_ns:rel_table(environment)).

rel_table_project_is_its_own_table_test() ->
	?assertEqual(relationships_42, graphdb_ns:rel_table(?PROJECT)).
```

- [ ] **Step 2: Run to verify it fails**

Run: `./rebar3 eunit --app=graphdb --module=graphdb_ns_tests`
Expected: compile error (`namespace_of/2`, `target_namespace/2`,
`node_table/1`, `rel_table/1` undefined) — `graphdb_ns.erl` still only
exports the arity-1 forms.

- [ ] **Step 3: Rewrite `graphdb_ns.erl`**

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-06-29
%% Description: Pure namespace resolution module.  Encodes which
%%				database namespace each kind of nref reference belongs
%%				to, and resolves a Home into its physical table atoms.
%%				No dependencies on other modules; fixed lookup table
%%				based on the project-environment separation model.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-06-29 Author: David W. Thomas
%% Initial implementation.
%% Rev PA2 Date: 2026-08-05 Author: David W. Thomas
%% SP2: home-relative routing.  namespace_of/1 and target_namespace/1
%% replaced by /2 forms taking a Home (environment | project handle).
%% node_table/1 and rel_table/1 added.
%%---------------------------------------------------------------------

-module(graphdb_ns).

-export([namespace_of/2, target_namespace/2, node_table/1, rel_table/1]).

%%---------------------------------------------------------------------
%% NYI / UEM Macros
%%---------------------------------------------------------------------
-define(NYI(X), (begin
	io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
	exit(nyi)
end)).
-define(UEM(F, X), (begin
	io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
	exit(uem)
end)).


%%---------------------------------------------------------------------
%% namespace_of(Home, Role) -> environment | Home
%%
%% Encodes docs/designs/project-env-reference-namespace-model-design.md §3
%% (amended 2026-08-02 for home-relative routing). `Home` is the store the
%% containing record was read from: `environment` or a `graphdb_project`
%% handle. target_nref and source_nref are NOT roles here — they need the
%% arc label's target_kind too, so they route through target_namespace/2
%% directly at the call site (see that design's §6 code block).
%%---------------------------------------------------------------------
namespace_of(_Home, characterization)     -> environment;
namespace_of(_Home, reciprocal)           -> environment;
namespace_of(_Home, avp_attribute)        -> environment;
namespace_of(_Home, node_classes)         -> environment;
namespace_of(_Home, taxonomy_parent)      -> environment;
namespace_of(Home,  compositional_parent) -> Home;
namespace_of(Home,  node_nref)            -> Home.


%%---------------------------------------------------------------------
%% target_namespace(Home, TargetKind) -> environment | Home
%%
%% The routed-field resolver: category/attribute/class targets are always
%% environment; an instance target is home-relative (Home itself — whatever
%% that Home is, environment or a specific project).
%%---------------------------------------------------------------------
target_namespace(_Home, category)  -> environment;
target_namespace(_Home, attribute) -> environment;
target_namespace(_Home, class)     -> environment;
target_namespace(Home,  instance)  -> Home.


%%---------------------------------------------------------------------
%% node_table(Home) -> atom()
%% rel_table(Home)  -> atom()
%%
%% Resolves a Home into its physical Mnesia table atoms. `environment`
%% resolves to the literal shared tables; a project handle (as returned by
%% graphdb_project:open/1) carries its own table atoms directly.
%%---------------------------------------------------------------------
node_table(environment)   -> nodes;
node_table(#{nodes := T}) -> T.

rel_table(environment)  -> relationships;
rel_table(#{rels := T}) -> T.
```

- [ ] **Step 4: Run to verify it passes**

Run: `./rebar3 eunit --app=graphdb --module=graphdb_ns_tests`
Expected: PASS, 10/10.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_ns.erl apps/graphdb/test/graphdb_ns_tests.erl
git commit -m "SP2 T1: graphdb_ns home-relative routing (arity-2)"
```

---

## Task 2: `graphdb_project` — physical store + handle + allocators

**Files:**
- Modify: `apps/graphdb/src/graphdb_project.erl`
- Modify: `apps/graphdb/test/graphdb_project_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_ns:node_table/1`, `graphdb_ns:rel_table/1` (Task 1).
- Produces: `graphdb_project:register_project/1 :: (string()) -> {ok,
  integer()} | {error, term()}` (now also creates the three tables).
  `graphdb_project:open/1 :: (integer()) -> {ok, Project} | {error,
  not_a_project} | {error, no_store}` where `Project :: #{anchor :=
  integer(), nodes := atom(), rels := atom(), counters := atom()}` — this
  is the `Project` shape every later task threads.
  `graphdb_project:require_project/1 :: (term()) -> ok | {error,
  invalid_project}`.
  `graphdb_project:next_nref/1 :: (Project) -> pos_integer()`.
  `graphdb_project:next_rel_id_pair/1 :: (Project) -> {pos_integer(),
  pos_integer()}`.
  `is_project/1` unchanged. `open_session/1`, `session_project/1`,
  `require_session/1` are REMOVED (no deprecation shim — SP1 had zero
  external callers outside this tree, all of which Task 12 updates).

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_project_SUITE.erl`. First update the
`all/0` and export list, then append the new test bodies:

```erlang
-export([
	register_project_creates_child_of_projects/1,
	register_project_creates_tables/1,
	register_project_is_idempotent/1,
	is_project_false_for_non_child/1,
	open_returns_project_handle/1,
	open_rejects_non_project/1,
	open_rejects_project_without_store/1,
	require_project_accepts_valid_handle/1,
	require_project_rejects_malformed_term/1,
	next_nref_starts_at_one/1,
	next_nref_is_sequential/1,
	next_rel_id_pair_returns_two_consecutive_ids/1
]).
```

```erlang
all() ->
	[register_project_creates_child_of_projects,
	 register_project_creates_tables,
	 register_project_is_idempotent,
	 is_project_false_for_non_child,
	 open_returns_project_handle,
	 open_rejects_non_project,
	 open_rejects_project_without_store,
	 require_project_accepts_valid_handle,
	 require_project_rejects_malformed_term,
	 next_nref_starts_at_one,
	 next_nref_is_sequential,
	 next_rel_id_pair_returns_two_consecutive_ids].
```

```erlang
%%-----------------------------------------------------------------------------
%% register_project creates the three physical tables, all initially empty.
%%-----------------------------------------------------------------------------
register_project_creates_tables(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	Tables = mnesia:system_info(tables),
	?assert(lists:member(list_to_atom("nodes_" ++ integer_to_list(P)), Tables)),
	?assert(lists:member(list_to_atom("relationships_" ++ integer_to_list(P)),
		Tables)),
	?assert(lists:member(list_to_atom("counters_" ++ integer_to_list(P)),
		Tables)).

%%-----------------------------------------------------------------------------
%% Calling ensure_tables again for an already-registered project's anchor
%% (simulated by opening twice) does not error.
%%-----------------------------------------------------------------------------
register_project_is_idempotent(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, P1} = graphdb_project:open(P),
	{ok, P2} = graphdb_project:open(P),
	?assertEqual(P1, P2).

%%-----------------------------------------------------------------------------
%% open/1 returns a Project handle carrying the three table atoms.
%%-----------------------------------------------------------------------------
open_returns_project_handle(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(#{anchor => P,
	               nodes => list_to_atom("nodes_" ++ integer_to_list(P)),
	               rels => list_to_atom("relationships_" ++ integer_to_list(P)),
	               counters => list_to_atom("counters_" ++ integer_to_list(P))},
	             Project).

%%-----------------------------------------------------------------------------
%% open/1 rejects a non-project nref.
%%-----------------------------------------------------------------------------
open_rejects_non_project(_Config) ->
	?assertEqual({error, not_a_project}, graphdb_project:open(?NREF_CLASSES)).

%%-----------------------------------------------------------------------------
%% open/1 reports {error, no_store} for a registered anchor whose tables
%% were never created (the SP1-era state) -- simulated by writing an anchor
%% node directly under Projects without calling register_project/1.
%%-----------------------------------------------------------------------------
open_rejects_project_without_store(_Config) ->
	Nref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Node = #node{nref = Nref, kind = instance, parents = [?NREF_PROJECTS],
	             attribute_value_pairs = []},
	F = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id1, kind = composition,
			              source_nref = ?NREF_PROJECTS,
			              characterization = ?ARC_CAT_CHILD,
			              target_nref = Nref, reciprocal = ?ARC_CAT_PARENT,
			              avps = []}, write),
		ok = mnesia:write(relationships,
			#relationship{id = Id2, kind = composition,
			              source_nref = Nref,
			              characterization = ?ARC_CAT_PARENT,
			              target_nref = ?NREF_PROJECTS,
			              reciprocal = ?ARC_CAT_CHILD, avps = []}, write)
	end,
	{ok, ok} = graphdb_mgr:transaction(F),
	?assert(graphdb_project:is_project(Nref)),
	?assertEqual({error, no_store}, graphdb_project:open(Nref)).

%%-----------------------------------------------------------------------------
%% require_project accepts a well-formed handle, rejects everything else.
%%-----------------------------------------------------------------------------
require_project_accepts_valid_handle(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(ok, graphdb_project:require_project(Project)).

require_project_rejects_malformed_term(_Config) ->
	?assertEqual({error, invalid_project}, graphdb_project:require_project(undefined)),
	?assertEqual({error, invalid_project}, graphdb_project:require_project(#{})).

%%-----------------------------------------------------------------------------
%% next_nref/1: first allocation yields 1; no seeding needed.
%%-----------------------------------------------------------------------------
next_nref_starts_at_one(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(1, graphdb_project:next_nref(Project)).

next_nref_is_sequential(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual(1, graphdb_project:next_nref(Project)),
	?assertEqual(2, graphdb_project:next_nref(Project)),
	?assertEqual(3, graphdb_project:next_nref(Project)).

%%-----------------------------------------------------------------------------
%% next_rel_id_pair/1: two consecutive ids, independent of the nref counter.
%%-----------------------------------------------------------------------------
next_rel_id_pair_returns_two_consecutive_ids(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, Project} = graphdb_project:open(P),
	?assertEqual({1, 2}, graphdb_project:next_rel_id_pair(Project)),
	?assertEqual({3, 4}, graphdb_project:next_rel_id_pair(Project)),
	?assertEqual(1, graphdb_project:next_nref(Project)).
```

- [ ] **Step 2: Run to verify these fail**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_project_SUITE`
Expected: compile errors / undef for `register_project/1` creating tables,
`open/1`, `require_project/1`, `next_nref/1`, `next_rel_id_pair/1`.

- [ ] **Step 3: Rewrite `graphdb_project.erl`**

Replace the exports and add the new sections (keep the moduledoc header,
copyright block, and NYI/UEM macros unchanged; keep the inline `-record`
definitions unchanged):

```erlang
-export([register_project/1, is_project/1, open/1,
		require_project/1, next_nref/1, next_rel_id_pair/1,
		add_relationship/5, add_relationship/6, add_relationship/7,
		add_class_membership/3,
		remove_relationship/4, remove_relationship/5,
		update_relationship/5, update_relationship/6,
		update_relationship_both/5, update_relationship_both/6]).


%%=====================================================================
%% Public API
%%=====================================================================

%%---------------------------------------------------------------------
%% register_project(Name) -> {ok, ProjectNref} | {error, term()}
%%
%% Creates the project's anchor node (a kind=instance node in the
%% environment under the Projects category, nref 5) then its three
%% physical tables (nodes_<A>, relationships_<A>, counters_<A>).
%%
%% mnesia:create_table/2 is a schema operation and cannot run inside a
%% transaction, so table creation happens AFTER the anchor write, not
%% atomically with it. ensure_tables/1 is idempotent (already_exists is
%% not an error), so a retried register_project/1 call converges.
%%
%% The anchor's nref and rel-id pair are allocated OUTSIDE the transaction
%% fun: calling gen_servers (graphdb_nref, rel_id_server) inside a Mnesia
%% activity is a latent deadlock -- load-bearing invariant in this
%% codebase.
%%---------------------------------------------------------------------
register_project(Name) when is_list(Name) ->
	case create_anchor(Name) of
		{ok, Nref} ->
			try
				ok = ensure_tables(Nref),
				{ok, Nref}
			catch
				throw:{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.

create_anchor(Name) ->
	Nref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	Node = #node{nref = Nref, kind = instance,
				 parents = [?NREF_PROJECTS],
				 attribute_value_pairs = [NameAVP]},
	P2C = #relationship{id = Id1, kind = composition,
						source_nref = ?NREF_PROJECTS,
						characterization = ?ARC_CAT_CHILD,
						target_nref = Nref, reciprocal = ?ARC_CAT_PARENT,
						avps = []},
	C2P = #relationship{id = Id2, kind = composition,
						source_nref = Nref,
						characterization = ?ARC_CAT_PARENT,
						target_nref = ?NREF_PROJECTS, reciprocal = ?ARC_CAT_CHILD,
						avps = []},
	Fun = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write),
		Nref
	end,
	graphdb_mgr:transaction(Fun).


%%---------------------------------------------------------------------
%% ensure_tables(Anchor) -> ok    (throws {error, {create_table_failed, ...}})
%%
%% Creates the project's three physical tables if absent. Mirrors
%% graphdb_bootstrap:create_tables/0's shape (disc_copies, record_info-
%% derived attributes, source_nref/target_nref index on relationships).
%% The counters table has no fixed record shape -- it is looked up by a
%% bare {Key, Value} tuple via mnesia:dirty_update_counter/3.
%%---------------------------------------------------------------------
ensure_tables(Anchor) ->
	NodeList = [node()],
	ok = ensure_table(nodes_table(Anchor), [
		{record_name, node},
		{attributes, record_info(fields, node)},
		{disc_copies, NodeList}
	]),
	ok = ensure_table(rels_table(Anchor), [
		{record_name, relationship},
		{attributes, record_info(fields, relationship)},
		{disc_copies, NodeList},
		{index, [source_nref, target_nref]}
	]),
	ok = ensure_table(counters_table(Anchor), [
		{disc_copies, NodeList}
	]),
	ok.

ensure_table(Name, Opts) ->
	case mnesia:create_table(Name, Opts) of
		{atomic, ok}                       -> ok;
		{aborted, {already_exists, Name}}  -> ok;
		{aborted, Reason} ->
			throw({error, {create_table_failed, Name, Reason}})
	end.

nodes_table(Anchor)    -> list_to_atom("nodes_" ++ integer_to_list(Anchor)).
rels_table(Anchor)     -> list_to_atom("relationships_" ++ integer_to_list(Anchor)).
counters_table(Anchor) -> list_to_atom("counters_" ++ integer_to_list(Anchor)).


%%---------------------------------------------------------------------
%% is_project(Nref) -> boolean()
%%
%% Returns true iff the node at Nref has ?NREF_PROJECTS (5) in its
%% parents cache -- i.e. it was registered as a project anchor node.
%%---------------------------------------------------------------------
is_project(Nref) ->
	case graphdb_mgr:get_node(Nref) of
		{ok, #node{parents = Parents}} -> lists:member(?NREF_PROJECTS, Parents);
		_                              -> false
	end.


%%---------------------------------------------------------------------
%% open(ProjectNref) ->
%%     {ok, Project} | {error, not_a_project} | {error, no_store}
%%
%% Resolves a registered project's nref into its physical store handle.
%% {error, no_store} covers an anchor that predates SP2 (registered, but
%% without tables); SP4's migration resolves that state -- open/1 reports
%% it rather than silently creating an empty store.
%%---------------------------------------------------------------------
open(ProjectNref) ->
	case is_project(ProjectNref) of
		false ->
			{error, not_a_project};
		true ->
			case tables_exist(ProjectNref) of
				true ->
					{ok, #{anchor   => ProjectNref,
						   nodes    => nodes_table(ProjectNref),
						   rels     => rels_table(ProjectNref),
						   counters => counters_table(ProjectNref)}};
				false ->
					{error, no_store}
			end
	end.

tables_exist(Anchor) ->
	lists:member(nodes_table(Anchor), mnesia:system_info(tables)).


%%---------------------------------------------------------------------
%% require_project(Project) -> ok | {error, invalid_project}
%%
%% Gate for project-scoped operations: a well-formed Project handle
%% passes; any other term is rejected. Pure (no store access) -- the
%% handle was already validated against the registry by open/1.
%%---------------------------------------------------------------------
require_project(#{anchor := _, nodes := _, rels := _, counters := _}) -> ok;
require_project(_)                                                    ->
	{error, invalid_project}.


%%---------------------------------------------------------------------
%% next_nref(Project) -> pos_integer()
%% next_rel_id_pair(Project) -> {pos_integer(), pos_integer()}
%%
%% Project-local allocators. mnesia:dirty_update_counter/3 on a key that
%% has never been written creates it with the increment as its value, so
%% the first call to either yields the low end of the unbounded monotonic
%% space -- no seeding needed at register_project/1 time. Dirty ops do not
%% participate in a surrounding transaction; callers must invoke these
%% OUTSIDE any transaction fun, same discipline as graphdb_nref:get_next/0
%% and rel_id_server:get_id_pair/0 for the environment.
%%---------------------------------------------------------------------
next_nref(#{counters := Counters}) ->
	mnesia:dirty_update_counter(Counters, nref, 1).

next_rel_id_pair(#{counters := Counters}) ->
	Id2 = mnesia:dirty_update_counter(Counters, rel_id, 2),
	{Id2 - 1, Id2}.
```

Then update the delegator functions (mechanical rename, same bodies,
`Session` → `Project`):

```erlang
add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateNref).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateNref, AVPSpec).

add_class_membership(Project, InstanceNref, ClassNref) ->
	graphdb_instance:add_class_membership(Project, InstanceNref, ClassNref).

remove_relationship(Project, SourceNref, CharNref, TargetNref) ->
	graphdb_instance:remove_relationship(Project, SourceNref, CharNref,
		TargetNref).

remove_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref) ->
	graphdb_instance:remove_relationship(Project, SourceNref, CharNref,
		TargetNref, TemplateNref).

update_relationship(Project, SourceNref, CharNref, TargetNref, Updates) ->
	graphdb_instance:update_relationship(Project, SourceNref, CharNref,
		TargetNref, Updates).

update_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		Updates) ->
	graphdb_instance:update_relationship(Project, SourceNref, CharNref,
		TargetNref, TemplateNref, Updates).

update_relationship_both(Project, SourceNref, CharNref, TargetNref, Pair) ->
	graphdb_instance:update_relationship_both(Project, SourceNref, CharNref,
		TargetNref, Pair).

update_relationship_both(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		Pair) ->
	graphdb_instance:update_relationship_both(Project, SourceNref, CharNref,
		TargetNref, TemplateNref, Pair).
```

- [ ] **Step 4: Run to verify it passes**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_project_SUITE`
Expected: PASS, 12/12. Also run
`./rebar3 ct --app=graphdb --suite=graphdb_instance_SUITE,graphdb_mgr_SUITE,graphdb_query_SUITE`
to confirm the compile break from removing `open_session/1` /
`session_project/1` / `require_session/1` is visible now (it will be —
those suites' `sess()` helpers call `open_session/1`). This is expected;
Task 12 fixes it. Note the failure and move on.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_project.erl apps/graphdb/test/graphdb_project_SUITE.erl
git commit -m "SP2 T2: graphdb_project physical store + Project handle + allocators"
```

---

## Task 3: `graphdb_instance` — rename `Session`→`Project`, thread the handle through the public write API

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes: `graphdb_project:require_project/1` (Task 2).
- Produces: every public write function now takes `Project` first and
  ships it into the `gen_server:call` message tuple (previously dropped by
  `with_session`). New gen_server message shapes (consumed by Task 4-9's
  `handle_call` clauses): `{create_instance, Project, Name, ClassNref,
  ParentNref, Resolver, ConflictResolver}`, `{add_relationship, Project, S,
  C, T, R, TemplateSpec, AVPSpec}`, `{add_class_membership, Project,
  InstanceNref, ClassNref}`.

This task only touches the **public function heads and the gate**; the
`handle_call` clauses and internal primitives are Tasks 4-9. The module will
not compile standalone after this task — that's expected; Tasks 4-9 land in
the same PR before the suite is expected to pass.

- [ ] **Step 1: Rename the gate**

```erlang
%% Gate a project operation on a valid Project handle. A missing or
%% malformed handle short-circuits with {error, invalid_project}; a valid
%% one runs Fun(Project). SP2: Fun now receives Project so it can route.
with_project(Project, Fun) when is_function(Fun, 1) ->
	case graphdb_project:require_project(Project) of
		ok               -> Fun(Project);
		{error, _} = Err -> Err
	end.
```

(Replaces the old `with_session/2`, which took a zero-arity `Fun` and
discarded `Session`.)

- [ ] **Step 2: Rewrite the public write API heads**

```erlang
create_instance(Project, Name, ClassNref, ParentNref) ->
	create_instance(Project, Name, ClassNref, ParentNref, fun report_only/1).

create_instance(Project, Name, ClassNref, ParentNref, ConnResolver)
		when is_function(ConnResolver, 1) ->
	create_instance(Project, Name, ClassNref, ParentNref, ConnResolver,
					graphdb_rules:default_conflict_resolver()).

create_instance(Project, Name, ClassNref, ParentNref, ConnResolver,
		ConflictResolver)
		when is_function(ConnResolver, 1), is_function(ConflictResolver, 1) ->
	with_project(Project, fun(P) ->
		gen_server:call(?MODULE,
			{create_instance, P, Name, ClassNref, ParentNref, ConnResolver,
			 ConflictResolver})
	end).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref) ->
	with_project(Project, fun(P) ->
		gen_server:call(?MODULE,
			{add_relationship, P, SourceNref, CharNref, TargetNref,
				ReciprocalNref, default, {[], []}})
	end).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref) when is_integer(TemplateNref) ->
	with_project(Project, fun(P) ->
		gen_server:call(?MODULE,
			{add_relationship, P, SourceNref, CharNref, TargetNref,
				ReciprocalNref, TemplateNref, {[], []}})
	end).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, {FwdAVPs, RevAVPs} = AVPSpec)
		when is_integer(TemplateNref), is_list(FwdAVPs), is_list(RevAVPs) ->
	with_project(Project, fun(P) ->
		gen_server:call(?MODULE,
			{add_relationship, P, SourceNref, CharNref, TargetNref,
				ReciprocalNref, TemplateNref, AVPSpec})
	end).

add_class_membership(Project, InstanceNref, ClassNref) ->
	with_project(Project, fun(P) ->
		gen_server:call(?MODULE,
			{add_class_membership, P, InstanceNref, ClassNref})
	end).
```

- [ ] **Step 3: Rewrite `remove_relationship`/`update_relationship`/`update_relationship_both` heads**

```erlang
remove_relationship(Project, SourceNref, CharNref, TargetNref) ->
	with_project(Project, fun(P) ->
		txn_ok(fun() ->
			remove_relationship_in_txn(P, SourceNref, CharNref, TargetNref, any)
		end)
	end).

remove_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref)
		when is_integer(TemplateNref) ->
	with_project(Project, fun(P) ->
		txn_ok(fun() ->
			remove_relationship_in_txn(P, SourceNref, CharNref, TargetNref,
				TemplateNref)
		end)
	end).

update_relationship(Project, SourceNref, CharNref, TargetNref, Updates) ->
	with_project(Project, fun(P) ->
		do_update_relationship(P, SourceNref, CharNref, TargetNref, any, Updates)
	end).

update_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		Updates) when is_integer(TemplateNref) ->
	with_project(Project, fun(P) ->
		do_update_relationship(P, SourceNref, CharNref, TargetNref,
			TemplateNref, Updates)
	end).

update_relationship_both(Project, SourceNref, CharNref, TargetNref,
		{Fwd, Rev}) ->
	with_project(Project, fun(P) ->
		do_update_both(P, SourceNref, CharNref, TargetNref, any, Fwd, Rev)
	end).

update_relationship_both(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		{Fwd, Rev}) when is_integer(TemplateNref) ->
	with_project(Project, fun(P) ->
		do_update_both(P, SourceNref, CharNref, TargetNref, TemplateNref, Fwd, Rev)
	end).
```

Note `do_update_relationship/6` and `do_update_both/7` gain a leading
`Project`/`Home` argument here — their bodies are rewritten in Task 6.

- [ ] **Step 4: Commit (module intentionally non-compiling until Task 9)**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T3: graphdb_instance public write API takes Project (WIP, compiles after T4-T9)"
```

If your workflow requires green-at-every-commit, squash Tasks 3-9 into one
commit instead — they are one reviewable unit (the design's "SP2 cannot be
sliced" constraint applies at the code level too: the public heads, the
create/connection cascade, and the reads must land together for the module
to compile and its own test suite to run at all).

---

## Task 4: `graphdb_instance` — creation cascade routes through `Project`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes: `graphdb_project:next_nref/1`, `next_rel_id_pair/1` (Task 2).
- Produces: `Ctx` map gains a `project` key, threaded unchanged through the
  whole cascade (same pattern as the existing `root_parent`/`root_source`
  anchors). `allocate_plan/2`, `instance_records/5`, `plan_writes/3`,
  `write_children/4` all take `Project` explicitly (not buried only in
  `Ctx`) so their signatures self-document.

- [ ] **Step 1: `handle_call` for `create_instance` binds `Project` into `Ctx`**

```erlang
handle_call({create_instance, Project, Name, ClassNref, ParentNref, Resolver,
			 ConflictResolver}, _From,
		#state{instantiable_nref = InstAttr, retired_nref = RetAttr} = State) ->
	Ctx = #{inst_attr => InstAttr, ret_attr => RetAttr, on_path => [],
			resolver => Resolver, conflict_resolver => ConflictResolver,
			project => Project, root_parent => ParentNref,
			root_source => undefined},
	{reply, do_create_instance(Name, ClassNref, ParentNref, Ctx), State};
```

- [ ] **Step 2: `do_create_instance`/`do_validate_parent` route the parent read**

`do_create_instance/4` is unchanged except it now has a `project` key
available in `Ctx`; pass it to `do_validate_parent/3`:

```erlang
do_create_instance(Name, ClassNref, ParentNref, Ctx) ->
	InstAttr = maps:get(inst_attr, Ctx),
	RetAttr  = maps:get(ret_attr, Ctx),
	Project  = maps:get(project, Ctx),
	case do_validate_class(ClassNref, InstAttr, RetAttr) of
		ok ->
			case do_validate_parent(Project, ParentNref, RetAttr) of
				ok ->
					fire_create(Name, ClassNref, ParentNref, Ctx);
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.
```

`do_validate_class/3` is unchanged (class reads are always environment —
no `Project` needed, per the design's §6 verification that `graphdb_class`
and every class-nref read in this module stay environment-only).

`do_validate_parent/3` gains `Project` and reads the project's own nodes
table (the compositional parent is always another instance in the same
project — see design §6, "node.parents ... home-relative"):

```erlang
do_validate_parent(Project, ParentNref, RetAttr) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), ParentNref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case is_retired(AVPs, RetAttr) of
				true  -> {error, {parent_retired, ParentNref}};
				false -> ok
			end;
		[]      -> {error, parent_not_found}
	end.
```

- [ ] **Step 3: `allocate_plan/1` → `/2`, allocates from the project counter**

```erlang
%%-----------------------------------------------------------------------------
%% allocate_plan(PlanNode, Project) -> InstPlanNode (same tree + nref per node)
%%
%% Depth-first pre-order walk: allocates one nref per node from Project's
%% own counter, OUTSIDE the Mnesia transaction.
%%-----------------------------------------------------------------------------
allocate_plan(#{mandatory_children := Kids} = Node, Project) ->
	Nref = graphdb_project:next_nref(Project),
	Node#{nref => Nref,
		  mandatory_children => [allocate_plan(K, Project) || K <- Kids]}.
```

- [ ] **Step 4: `plan_writes/2` → `/3`, `write_children/3` → `/4`, `instance_records/4` → `/5`**

```erlang
%%-----------------------------------------------------------------------------
%% plan_writes(InstPlan, RootParent, Project) -> {Writes, Outcomes}
%%-----------------------------------------------------------------------------
plan_writes(#{nref := RootNref, class := Class, name := Name,
			  mandatory_children := Kids}, RootParent, Project) ->
	Acc0 = {instance_records(RootNref, Class, Name, RootParent, Project), []},
	write_children(Kids, RootNref, Acc0, Project).

write_children(Siblings, OwnerNref, Acc, Project) ->
	{_Counts, Result} =
		lists:foldl(
			fun(#{nref := CNref, class := CClass, name := CName,
				  rule := Rule, deploy := Deploy,
				  mandatory_children := GKids}, {Counts, {W, O}}) ->
				Idx = maps:get(rule_key(Rule), Counts, 0) + 1,
				W1 = W ++ instance_records(CNref, CClass, CName, OwnerNref,
					Project),
				O1 = add_outcome(O, Rule, Deploy,
						#{owner => OwnerNref, index => Idx,
						  status => fired, child => CNref}),
				{W2, O2} = write_children(GKids, CNref, {W1, O1}, Project),
				{Counts#{rule_key(Rule) => Idx}, {W2, O2}}
			end, {#{}, Acc}, Siblings),
	Result.

%%-----------------------------------------------------------------------------
%% instance_records(Nref, ClassNref, Name, ParentNref, Project) -> [{Tab, Rec}]
%%
%% Builds the five Mnesia records for one instance node. Rel-IDs come from
%% Project's own counter (allocated here, outside the transaction, same as
%% before -- only the source changed from rel_id_server to
%% graphdb_project:next_rel_id_pair/1). Node record and both composition rows
%% tag their table via graphdb_ns:node_table/rel_table; the instantiation
%% pair's class-side row (C2I) still writes to Project's own relationships
%% table -- the row lives wherever its SOURCE lives (source_nref = ClassNref
%% would suggest environment, but per the design's arc-shape table the
%% class->instance membership row's source_nref routes environment while its
%% home store is still recorded with the instance -- see Task 5's
%% add_relationship_in_txn for the general rule; membership rows are written
%% here directly rather than through that general primitive, and both rows
%% of this specific arc pair are written to the SAME table as the instance
%% they describe, matching how SP1/pre-SP2 always wrote them together).
%%-----------------------------------------------------------------------------
instance_records(Nref, ClassNref, Name, ParentNref, Project) ->
	{MembId1, MembId2} = graphdb_project:next_rel_id_pair(Project),
	{CompId1, CompId2} = graphdb_project:next_rel_id_pair(Project),
	NodesTab = graphdb_ns:node_table(Project),
	RelsTab  = graphdb_ns:rel_table(Project),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	Node = #node{nref = Nref, kind = instance, parents = [ParentNref],
				 classes = [ClassNref], attribute_value_pairs = [NameAVP]},
	%% Instance -> Class (char=29, reciprocal=30)
	I2C = #relationship{id = MembId1, kind = instantiation, source_nref = Nref,
		characterization = ?ARC_INST_TO_CLASS, target_nref = ClassNref,
		reciprocal = ?ARC_CLASS_TO_INST, avps = []},
	%% Class -> Instance (char=30, reciprocal=29)
	C2I = #relationship{id = MembId2, kind = instantiation,
		source_nref = ClassNref, characterization = ?ARC_CLASS_TO_INST,
		target_nref = Nref, reciprocal = ?ARC_INST_TO_CLASS, avps = []},
	%% Parent -> Child (char=28, reciprocal=27)
	P2C = #relationship{id = CompId1, kind = composition,
		source_nref = ParentNref, characterization = ?ARC_INST_CHILD,
		target_nref = Nref, reciprocal = ?ARC_INST_PARENT, avps = []},
	%% Child -> Parent (char=27, reciprocal=28)
	C2P = #relationship{id = CompId2, kind = composition, source_nref = Nref,
		characterization = ?ARC_INST_PARENT, target_nref = ParentNref,
		reciprocal = ?ARC_INST_CHILD, avps = []},
	[{NodesTab, Node}, {RelsTab, I2C}, {RelsTab, C2I},
	 {RelsTab, P2C}, {RelsTab, C2P}].
```

**Design note to record verbatim in the module comment above
`instance_records/5`:** the class→instance membership row (`C2I`, whose
`source_nref` is the environment `ClassNref`) is written to the **project's**
`relationships` table, not split across two stores. This is a deliberate,
narrow exception to "route by source's home": SP2 keeps both directions of
one arc-write co-located with the instance they describe so a project
remains a genuinely single relocatable unit (design §2's stated goal) — a
project's full membership history lives with it. Reads of this row still
resolve correctly under the home-relative rule because a reader who already
knows the row is a `char=30` reciprocal reaches it via `target_nref` from the
project side, never by scanning the environment's `relationships` table by
`source_nref=ClassNref` for this purpose. `add_relationship_in_txn` (Task 5)
does NOT follow this exception — it is the general connection-arc primitive
and routes each row by its own endpoints.

- [ ] **Step 5: `execute/5` and `fire_create/4` pass `Project` down**

```erlang
fire_create(Name, ClassNref, ParentNref, Ctx) ->
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref,
											   maps:get(conflict_resolver, Ctx)) of
		{ok, PlanTree} ->
			case execute(Name, ClassNref, ParentNref, Ctx, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan, AutoConnPlan} ->
					Ctx1 = bind_root_source(Ctx, RootNref),
					AutoReport     = fire_auto(InstPlan, Ctx1),
					ProposeReport  = fire_propose(InstPlan,
									 maps:get(on_path, Ctx1)),
					ConnAutoReport = fire_connections(AutoConnPlan),
					Merged = merge_reports(
						merge_reports(
							merge_reports(MandOutcomes, AutoReport),
							ProposeReport),
						ConnAutoReport),
					{ok, RootNref, Merged};
				{error, R, Report} ->
					{error, R, Report}
			end;
		{error, R, Failure} ->
			{error, R, report_not_attempted(R, Failure)}
	end.

execute(RootName, _RootClass, RootParent, Ctx, PlanTree) ->
	Project = maps:get(project, Ctx),
	InstPlan = allocate_plan(PlanTree#{name => RootName}, Project),
	{Writes, CompOutcomes} = plan_writes(InstPlan, RootParent, Project),
	RootNref = maps:get(nref, InstPlan),
	Ctx1 = bind_root_source(Ctx, RootNref),
	case resolve_connections(InstPlan, Ctx1) of
		{ok, MandRows, AutoConnPlan, ConnReport} ->
			Txn = fun() ->
				lists:foreach(
					fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					Writes ++ MandRows)
			end,
			case graphdb_mgr:transaction(Txn) of
				{ok, ok} ->
					{ok, RootNref,
					 merge_reports(CompOutcomes, ConnReport),
					 InstPlan, AutoConnPlan};
				{error, R} ->
					{error, R,
					 report_not_attempted(R,
						#{plan_so_far => PlanTree, culprit => undefined})}
			end;
		{error, Reason, ConnReport} ->
			CompNA = report_not_attempted(Reason,
				#{plan_so_far => InstPlan, culprit => undefined}),
			{error, Reason, merge_reports(CompNA, ConnReport)}
	end.
```

`fire_create/4` itself is textually unchanged (shown for context/diff
clarity) — only `execute/5`'s body changes, extracting `Project` from `Ctx`
once and threading it to `allocate_plan/2` and `plan_writes/3`.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T4: creation cascade allocates from and writes to Project"
```

---

## Task 5: `graphdb_instance` — connection-arc write primitives take `Home`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes: `graphdb_ns:node_table/1`, `rel_table/1`, `target_namespace/2`
  (Task 1).
- Produces: `add_relationship_in_txn/10` (was `/9` — gains a leading `Home`),
  `validate_arc_endpoints_in_txn/7` (was `/6`), `resolve_arc_classes_in_txn/3`
  (was `/2`), `class_of_in_txn/2` (was `/1`), `build_connection_rows/8` (was
  `/7`) and its `/9` twin (was `/8`), `write_connection_arcs/7` (was `/6`),
  `do_add_relationship/8` (was `/7`, gains leading `Home`/`Project`). These
  are consumed by Task 8 (remove/update) and by `graphdb_mgr:mutate`
  (Task 11), which is why they take the general `Home :: environment |
  Project` rather than a concrete `Project` — `graphdb_instance`'s own
  callers always pass a concrete `Project` (Home ⊇ Project).

`Home` here is `environment | Project` — reads of `CharNref`/`ReciprocalNref`
(always environment, per the design's field-role table: characterization and
reciprocal are always environment) stay on the literal `nodes` table
regardless of `Home`; only `SourceNref`/`TargetNref` route through `Home`.

- [ ] **Step 1: `handle_call` for `add_relationship` passes `Home` through**

```erlang
handle_call({add_relationship, Home, S, C, T, R, TemplateSpec, AVPSpec},
		_From, State) ->
	{reply,
		do_add_relationship(Home, S, C, T, R, TemplateSpec, AVPSpec, State),
		State};
```

- [ ] **Step 2: `do_add_relationship/8`**

```erlang
do_add_relationship(Home, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateSpec, AVPSpec, State) ->
	TkAttr  = State#state.target_kind_avp_nref,
	RetAttr = State#state.retired_nref,
	IdPair = case Home of
		environment -> rel_id_server:get_id_pair();
		_           -> graphdb_project:next_rel_id_pair(Home)
	end,
	case graphdb_mgr:transaction(fun() ->
			add_relationship_in_txn(Home, IdPair, SourceNref, CharNref,
				TargetNref, ReciprocalNref, TemplateSpec, AVPSpec, TkAttr,
				RetAttr)
		end) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 3: `add_relationship_in_txn/10`**

```erlang
add_relationship_in_txn(Home, {_Id1, _Id2} = IdPair, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateSpec, AVPSpec, TkAttr, RetAttr) ->
	ok = validate_arc_endpoints_in_txn(Home, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TkAttr, RetAttr),
	{SourceClass, TargetClass} =
		resolve_arc_classes_in_txn(Home, SourceNref, TargetNref),
	TemplateNref = resolve_template_in_txn(TemplateSpec, SourceClass),
	ok = graphdb_class:validate_template_scope_in_txn(TemplateNref,
		SourceClass, TargetClass),
	Rows = build_connection_rows(Home, IdPair, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, AVPSpec),
	lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
		Rows).
```

- [ ] **Step 4: `validate_arc_endpoints_in_txn/7`**

Only the two reads of `Source`/`Target` change table; `Char`/`Recip` stay
literal `nodes` (always environment attribute nodes):

```erlang
validate_arc_endpoints_in_txn(Home, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TkAttr, RetAttr) ->
	Source = mnesia:read(graphdb_ns:node_table(Home), SourceNref),
	Target = mnesia:read(graphdb_ns:node_table(Home), TargetNref),
	Char   = mnesia:read(nodes, CharNref),
	Recip  = mnesia:read(nodes, ReciprocalNref),
	case {Source, Target, Char, Recip} of
		{[], _, _, _} ->
			mnesia:abort({source_not_found, SourceNref});
		{_, [], _, _} ->
			mnesia:abort({target_not_found, TargetNref});
		{_, _, [], _} ->
			mnesia:abort({characterization_not_found, CharNref});
		{_, _, _, []} ->
			mnesia:abort({reciprocal_not_found, ReciprocalNref});
		{[#node{attribute_value_pairs = SAVPs}],
		 [#node{kind = TKind, attribute_value_pairs = TAVPs}],
		 [#node{kind = CKind, attribute_value_pairs = CAVPs} = CharNode],
		 [#node{kind = RKind, attribute_value_pairs = RAVPs}]} ->
			case first_retired([{SourceNref, SAVPs}, {TargetNref, TAVPs},
								 {CharNref, CAVPs}, {ReciprocalNref, RAVPs}],
							   RetAttr) of
				{retired, RNref} ->
					mnesia:abort({endpoint_retired, RNref});
				none ->
					case {CKind, RKind} of
						{attribute, attribute} ->
							case check_target_kind(CharNode, TKind, TkAttr) of
								ok              -> ok;
								{error, Reason} -> mnesia:abort(Reason)
							end;
						{attribute, _} ->
							mnesia:abort({reciprocal_not_an_attribute,
								ReciprocalNref, RKind});
						{_, _} ->
							mnesia:abort({characterization_not_an_attribute,
								CharNref, CKind})
					end
			end
	end.
```

`first_retired/2` and `check_target_kind/3` are unchanged (they operate on
already-read AVP lists, no table access).

- [ ] **Step 5: `resolve_arc_classes_in_txn/3` and `class_of_in_txn/2`**

```erlang
resolve_arc_classes_in_txn(Home, SourceNref, TargetNref) ->
	SourceClass = case class_of_in_txn(Home, SourceNref) of
		{ok, SC}  -> SC;
		not_found -> mnesia:abort({source_has_no_class, SourceNref})
	end,
	TargetClass = case class_of_in_txn(Home, TargetNref) of
		{ok, TC}  -> TC;
		not_found -> mnesia:abort({target_has_no_class, TargetNref})
	end,
	{SourceClass, TargetClass}.

class_of_in_txn(Home, InstanceNref) ->
	Rels = mnesia:index_read(graphdb_ns:rel_table(Home), InstanceNref,
		#relationship.source_nref),
	case lists:search(
			fun(R) ->
				R#relationship.characterization =:= ?ARC_INST_TO_CLASS
			end, Rels) of
		{value, #relationship{target_nref = ClassNref}} -> {ok, ClassNref};
		false                                           -> not_found
	end.
```

`resolve_template_in_txn/2` is unchanged — it only calls
`graphdb_class:default_template_in_txn/1`, which is environment-only by
design (Task confirms no edit needed; do not touch).

- [ ] **Step 6: `build_connection_rows` and `write_connection_arcs`**

```erlang
%%-----------------------------------------------------------------------------
%% build_connection_rows(Home, S, C, T, R, TemplateNref, {FwdAVPs, RevAVPs})
%%   -> [{RelsTable, #relationship{}}]
%%-----------------------------------------------------------------------------
build_connection_rows(Home, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	IdPair = case Home of
		environment -> rel_id_server:get_id_pair();
		_           -> graphdb_project:next_rel_id_pair(Home)
	end,
	build_connection_rows(Home, IdPair, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, AVPSpec).

%% Pure builder: no allocation. The caller supplies the rel-id pair.
build_connection_rows(Home, {Id1, Id2}, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, {FwdAVPs, RevAVPs}) ->
	RelsTab = graphdb_ns:rel_table(Home),
	TemplateAVP = #{attribute => ?ARC_TEMPLATE, value => TemplateNref},
	Fwd = #relationship{
		id = Id1, kind = connection,
		source_nref = SourceNref,
		characterization = CharNref,
		target_nref = TargetNref,
		reciprocal = ReciprocalNref,
		avps = [TemplateAVP | FwdAVPs]
	},
	Rev = #relationship{
		id = Id2, kind = connection,
		source_nref = TargetNref,
		characterization = ReciprocalNref,
		target_nref = SourceNref,
		reciprocal = CharNref,
		avps = [TemplateAVP | RevAVPs]
	},
	[{RelsTab, Fwd}, {RelsTab, Rev}].

%%-----------------------------------------------------------------------------
%% write_connection_arcs(Home, S, C, T, R, TemplateNref, {FwdAVPs, RevAVPs}) ->
%%     ok | {error, term()}
%%-----------------------------------------------------------------------------
write_connection_arcs(Home, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	Rows = build_connection_rows(Home, SourceNref, CharNref, TargetNref,
								 ReciprocalNref, TemplateNref, AVPSpec),
	Txn = fun() ->
		lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					  Rows)
	end,
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

Both connection rows use the SAME `RelsTab` (`SourceNref`/`TargetNref` are
always both-project or both-environment for a connection arc between two
instances of the same home — connection rules never cross project
boundaries per SP1's proxy-indirection contract, and this module never
builds a connection row between an instance and an environment node).

Grep after this step: `grep -n "rel_id_server:get_id_pair" apps/graphdb/src/graphdb_instance.erl`
should show exactly the two call sites above (inside `do_add_relationship`
via `Home` branch already gone — recheck: `do_add_relationship` now branches
directly, `build_connection_rows/7` branches too) plus the two remaining in
`mandatory_rows`'s caller chain, which Task 6 removes. `mandatory_rows/4`
itself calls `build_connection_rows/6` (the OLD arity) at present — Task 6
updates that call site since it lives in the connection-RESOLVE code path,
not the write-primitive code path this task covers.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T5: add_relationship write primitives take Home"
```

---

## Task 6: `graphdb_instance` — connection-RESOLVE (composition-firing's mandatory/auto connections) and `validate_target`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes: `build_connection_rows/8` (Task 5).
- Produces: `resolve_connections/2` (unchanged signature — reads `Project`
  out of `Ctx`), `mandatory_rows/5` (was `/4`, gains `Project`),
  `validate_target/4` (was `/3`, gains `Project`), `partition_targets/4`
  (was `/3`, gains `Project`), `split_valid/4` (was `/3`, gains `Project`).

This is entirely inside the `create_instance` cascade, so every site here
takes a concrete `Project` (never `environment`) — extracted once from
`Ctx` at `resolve_nodes/3` and threaded down.

- [ ] **Step 1: `resolve_nodes/3` extracts `Project` and threads it into `resolve_rules/4`**

`resolve_nodes/3` itself is unchanged (it already receives `Ctx`); the
change is in what it passes downstream. Update `resolve_rules/4`'s
`connect_targets` calls and `mandatory_rows`/`validate_target` call sites:

```erlang
resolve_rules([], _SourceNref, _Ctx, Acc) ->
	{ok, Acc};
resolve_rules([{Rule, Deploy, Spec} | Rest], SourceNref, Ctx, Acc) ->
	Mode = maps:get(mode, Deploy, mandatory),
	case Mode of
		propose ->
			Acc1 = add_conn_outcome(Acc, Rule, Deploy,
				conn_outcome_base(SourceNref, Spec, proposed)),
			resolve_rules(Rest, SourceNref, Ctx, Acc1);
		_ ->
			Resolver = maps:get(resolver, Ctx),
			case Resolver(conn_context(Rule, Deploy, Spec, SourceNref, Ctx)) of
				defer ->
					Status = case Mode of
								 mandatory -> required;
								 auto      -> not_connected
							 end,
					Acc1 = add_conn_outcome(Acc, Rule, Deploy,
						conn_outcome_base(SourceNref, Spec, Status)),
					resolve_rules(Rest, SourceNref, Ctx, Acc1);
				{connect, List} ->
					connect_targets(Mode, List, Rule, Deploy, Spec, SourceNref,
									Rest, Ctx, Acc)
			end
	end.
```

(Unchanged — shown for context. `Ctx` already carries `project`; the
functions it calls are what change.)

- [ ] **Step 2: `connect_targets/9` passes `Project` (from `Ctx`) into `partition_targets`/`split_valid`/`mandatory_rows`**

```erlang
connect_targets(mandatory, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx,
		{Rows, Auto, Rep}) ->
	Project = maps:get(project, Ctx),
	TClass = maps:get(target_class, Spec),
	case partition_targets(List, TClass, SourceNref, Project) of
		{error, Reason} ->
			{error, {invalid_connection_target, Reason},
			 conn_fail({invalid_connection_target, Reason}, Rule, Spec, Rep)};
		{ok, Valid} ->
			{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case length(Valid) < Min of
				true ->
					Reason = {mandatory_connection_unsatisfied, Rule#node.nref},
					{error, Reason, conn_fail(Reason, Rule, Spec, Rep)};
				false ->
					ToWrite = cap(Valid, Max),
					Template = maps:get(template, Deploy),
					{NewRows, NewOuts} =
						mandatory_rows(ToWrite, SourceNref, Spec, Template,
							Project),
					Rep1 = lists:foldl(
						fun(O, R) -> add_outcome(R, Rule, Deploy, O) end,
						Rep, NewOuts),
					resolve_rules(Rest, SourceNref, Ctx,
								  {Rows ++ NewRows, Auto, Rep1})
			end
	end;

connect_targets(auto, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx,
		{Rows, Auto, Rep}) ->
	Project = maps:get(project, Ctx),
	TClass = maps:get(target_class, Spec),
	{Valid, Invalid} = split_valid(List, TClass, SourceNref, Project),
	{_Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	ToConnect = cap(Valid, Max),
	Char = maps:get(characterization, Spec),
	Rep1 = lists:foldl(
		fun({_T, Reason}, R) ->
			add_outcome(R, Rule, Deploy,
				#{source => SourceNref, index => 1, status => failed,
				  reason => Reason, characterization => Char,
				  target_class => TClass})
		end, Rep, Invalid),
	AutoEntry = #{rule => Rule, deploy => Deploy, spec => Spec,
				  source => SourceNref, template => maps:get(template, Deploy),
				  targets => ToConnect, project => Project},
	resolve_rules(Rest, SourceNref, Ctx, {Rows, Auto ++ [AutoEntry], Rep1}).
```

Note the `auto` branch's `AutoEntry` map gains a `project` key — the
post-commit auto-connection writer (`fire_connections/1`, unchanged in this
task, reads `AutoEntry` maps built here) needs it to build its own
connection rows later. Verify `fire_connections/1`'s existing body pulls
`Project` out of each `AutoEntry` when it calls `write_connection_arcs/7` —
grep `fire_connections` and confirm; if it currently calls
`write_connection_arcs` positionally, update that one call site to pass
`maps:get(project, AutoEntry)` as the new leading `Home` argument.

- [ ] **Step 3: `mandatory_rows/5`, `validate_target/4`, `partition_targets/4`, `split_valid/4`**

```erlang
mandatory_rows(Targets, SourceNref, Spec, Template, Project) ->
	Char   = maps:get(characterization, Spec),
	Recip  = maps:get(reciprocal, Spec),
	TClass = maps:get(target_class, Spec),
	{Rows, Outs, _} = lists:foldl(
		fun(T, {RAcc, OAcc, I}) ->
			TNref = target_nref(T),
			Rows0 = build_connection_rows(Project, SourceNref, Char, TNref,
										  Recip, Template, target_avps(T)),
			Out = #{source => SourceNref, index => I, status => connected,
					target => TNref, characterization => Char,
					target_class => TClass},
			{RAcc ++ Rows0, OAcc ++ [Out], I + 1}
		end, {[], [], 1}, Targets),
	{Rows, Outs}.

validate_target(Target, TargetClass, _SourceNref, Project) ->
	Nref = target_nref(Target),
	case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
		[#node{kind = instance, classes = Classes}] ->
			case lists:any(
					fun(C) -> graphdb_class:class_in_ancestry(TargetClass, C) end,
					Classes) of
				true  -> ok;
				false -> {error, {target_class_mismatch, Nref, TargetClass}}
			end;
		[#node{}] -> {error, {target_not_an_instance, Nref}};
		[]        -> {error, {target_not_found, Nref}}
	end.

partition_targets([], _TClass, _SourceNref, _Project) ->
	{ok, []};
partition_targets([T | Rest], TClass, SourceNref, Project) ->
	case validate_target(T, TClass, SourceNref, Project) of
		ok ->
			case partition_targets(Rest, TClass, SourceNref, Project) of
				{ok, Vs}         -> {ok, [T | Vs]};
				{error, _} = Err -> Err
			end;
		{error, Reason} ->
			{error, Reason}
	end.

split_valid(List, TClass, SourceNref, Project) ->
	lists:foldr(
		fun(T, {Vs, Is}) ->
			case validate_target(T, TClass, SourceNref, Project) of
				ok              -> {[T | Vs], Is};
				{error, Reason} -> {Vs, [{T, Reason} | Is]}
			end
		end, {[], []}, List).
```

`build_connection_rows(Project, SourceNref, ...)` above calls the Task 5
`/7` head (`Home` = `Project` here — a concrete project handle satisfies the
`Home` type).

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T6: connection RESOLVE (mandatory/auto) routes through Project"
```

---

## Task 7: `graphdb_instance` — remove/update relationship primitives take `Home`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes: Task 5's `graphdb_ns:rel_table/1` usage pattern.
- Produces: `resolve_forward_connection/5` (was `/4`, gains leading `Home`),
  `remove_relationship_in_txn/5` (was `/4`), `update_relationship_avps_in_txn/6`
  (was `/5`), `update_relationship_both_in_txn/7` (was `/6`),
  `do_update_relationship/6` (was `/5`), `do_update_both/7` (was `/6`).

- [ ] **Step 1: `resolve_forward_connection/5`**

```erlang
resolve_forward_connection(Home, SourceNref, CharNref, TargetNref, TemplateSpec) ->
	Rows = mnesia:index_read(graphdb_ns:rel_table(Home), SourceNref,
		#relationship.source_nref),
	Matches = [R || R <- Rows,
		R#relationship.kind =:= connection,
		R#relationship.characterization =:= CharNref,
		R#relationship.target_nref =:= TargetNref,
		template_matches(R, TemplateSpec)],
	case Matches of
		[]        -> not_found;
		[Row]     -> {ok, Row};
		Many      -> {ambiguous, [template_of(R) || R <- Many]}
	end.
```

`template_matches/2` and `template_of/1` are unchanged (operate on an
already-read record).

- [ ] **Step 2: `remove_relationship_in_txn/5`**

```erlang
remove_relationship_in_txn(Home, SourceNref, CharNref, TargetNref, TemplateSpec) ->
	case resolve_forward_connection(Home, SourceNref, CharNref, TargetNref,
			TemplateSpec) of
		not_found ->
			mnesia:abort(relationship_not_found);
		{ambiguous, Templates} ->
			mnesia:abort({ambiguous_relationship, Templates});
		{ok, Fwd} ->
			Recip = Fwd#relationship.reciprocal,
			Tmpl  = template_of(Fwd),
			case resolve_forward_connection(Home, TargetNref, Recip, SourceNref,
					Tmpl) of
				{ok, Rev} ->
					RelsTab = graphdb_ns:rel_table(Home),
					ok = mnesia:delete_object(RelsTab, Fwd, write),
					ok = mnesia:delete_object(RelsTab, Rev, write);
				_ ->
					mnesia:abort({dangling_half_edge, Fwd#relationship.id})
			end
	end.
```

- [ ] **Step 3: `update_relationship_avps_in_txn/6`**

```erlang
update_relationship_avps_in_txn(Home, SourceNref, CharNref, TargetNref,
		TemplateSpec, Updates) ->
	case has_template_update(Updates) of
		true ->
			mnesia:abort({protected_relationship_avp, ?ARC_TEMPLATE});
		false ->
			case resolve_forward_connection(Home, SourceNref, CharNref,
					TargetNref, TemplateSpec) of
				not_found ->
					mnesia:abort(relationship_not_found);
				{ambiguous, Templates} ->
					mnesia:abort({ambiguous_relationship, Templates});
				{ok, Row} ->
					New = graphdb_mgr:apply_avp_updates(
						Row#relationship.avps, Updates),
					mnesia:write(graphdb_ns:rel_table(Home),
						Row#relationship{avps = New}, write)
			end
	end.
```

- [ ] **Step 4: `do_update_relationship/6` and public `update_relationship/5,6`**

```erlang
do_update_relationship(Home, SourceNref, CharNref, TargetNref, TemplateSpec,
		Updates) ->
	case graphdb_mgr:validate_avp_updates(Updates) of
		ok ->
			txn_ok(fun() ->
				update_relationship_avps_in_txn(Home, SourceNref, CharNref,
					TargetNref, TemplateSpec, Updates)
			end);
		{error, _} = Err ->
			Err
	end.
```

(Task 3 already updated the public `update_relationship/5,6` heads to call
`do_update_relationship(P, ...)` — this step is the body those heads call.)

- [ ] **Step 5: `update_relationship_both_in_txn/7` and `do_update_both/7`**

```erlang
update_relationship_both_in_txn(Home, SourceNref, CharNref, TargetNref,
		TemplateSpec, FwdUpdates, RevUpdates) ->
	case resolve_forward_connection(Home, SourceNref, CharNref, TargetNref,
			TemplateSpec) of
		not_found ->
			mnesia:abort(relationship_not_found);
		{ambiguous, Templates} ->
			mnesia:abort({ambiguous_relationship, Templates});
		{ok, Fwd} ->
			Recip = Fwd#relationship.reciprocal,
			Tmpl  = template_of(Fwd),
			case resolve_forward_connection(Home, TargetNref, Recip, SourceNref,
					Tmpl) of
				{ok, _Rev} ->
					ok = update_relationship_avps_in_txn(Home, SourceNref,
						CharNref, TargetNref, Tmpl, FwdUpdates),
					ok = update_relationship_avps_in_txn(Home, TargetNref,
						Recip, SourceNref, Tmpl, RevUpdates);
				_ ->
					mnesia:abort({dangling_half_edge, Fwd#relationship.id})
			end
	end.

do_update_both(Home, SourceNref, CharNref, TargetNref, TemplateSpec, Fwd, Rev) ->
	case {graphdb_mgr:validate_avp_updates(Fwd),
		  graphdb_mgr:validate_avp_updates(Rev)} of
		{ok, ok} ->
			txn_ok(fun() ->
				update_relationship_both_in_txn(Home, SourceNref, CharNref,
					TargetNref, TemplateSpec, Fwd, Rev)
			end);
		{{error, _} = Err, _} -> Err;
		{_, {error, _} = Err} -> Err
	end.
```

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T7: remove/update relationship primitives take Home"
```

---

## Task 8: `graphdb_instance` — instance reads gain `Project`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Produces: `get_instance/2`, `children/2`, `compositional_ancestors/2`,
  `class_of/2`, `class_memberships/2`, `resolve_value/3` (each gains a
  leading `Project`; the reads have no environment-only use case so, unlike
  Task 5-7, these take a concrete `Project`, not `Home`).

- [ ] **Step 1: Public API heads**

```erlang
get_instance(Project, Nref) ->
	gen_server:call(?MODULE, {get_instance, Project, Nref}).

children(Project, Nref) ->
	gen_server:call(?MODULE, {children, Project, Nref}).

compositional_ancestors(Project, Nref) ->
	gen_server:call(?MODULE, {compositional_ancestors, Project, Nref}).

class_of(Project, InstanceNref) ->
	gen_server:call(?MODULE, {class_of, Project, InstanceNref}).

class_memberships(Project, InstanceNref) ->
	gen_server:call(?MODULE, {class_memberships, Project, InstanceNref}).

resolve_value(Project, InstanceNref, AttrNref) ->
	gen_server:call(?MODULE, {resolve_value, Project, InstanceNref, AttrNref}).
```

- [ ] **Step 2: `handle_call` clauses**

```erlang
handle_call({get_instance, Project, Nref}, _From, State) ->
	{reply, do_get_instance(Project, Nref), State};

handle_call({children, Project, Nref}, _From, State) ->
	{reply, do_children(Project, Nref), State};

handle_call({compositional_ancestors, Project, Nref}, _From, State) ->
	{reply, do_compositional_ancestors(Project, Nref), State};

handle_call({class_of, Project, Nref}, _From, State) ->
	{reply, do_class_of(Project, Nref), State};

handle_call({class_memberships, Project, Nref}, _From, State) ->
	{reply, do_class_memberships(Project, Nref), State};

handle_call({resolve_value, Project, InstNref, AttrNref}, _From, State) ->
	{reply, do_resolve_value(Project, InstNref, AttrNref), State};
```

- [ ] **Step 3: `do_get_instance/2`, `do_children/2`, `do_compositional_ancestors/2` + `do_walk_ancestors/3`, `downward_children_by_arc/4`**

```erlang
do_get_instance(Project, Nref) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
		[#node{kind = instance} = Node] -> {ok, Node};
		[_Other]                        -> {error, not_an_instance};
		[]                              -> {error, not_found}
	end.

do_children(Project, Nref) ->
	F = fun() ->
		Children = downward_children_by_arc(Project, Nref, ?ARC_INST_CHILD,
			composition),
		[N || N <- Children, N#node.kind =:= instance]
	end,
	graphdb_mgr:transaction(F).

do_compositional_ancestors(Project, Nref) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
		[#node{kind = instance, parents = Parents}] ->
			do_walk_ancestors(Project, head_parent(Parents), []);
		[_] ->
			{error, not_an_instance};
		[] ->
			{error, not_found}
	end.

do_walk_ancestors(_Project, undefined, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors(Project, Nref, Acc) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
		[#node{kind = instance, parents = Parents} = Node] ->
			do_walk_ancestors(Project, head_parent(Parents), [Node | Acc]);
		[_] ->
			{ok, lists:reverse(Acc)};
		[] ->
			{ok, lists:reverse(Acc)}
	end.

downward_children_by_arc(Project, ParentNref, ChildArc, RelKind) ->
	Arcs = mnesia:index_read(graphdb_ns:rel_table(Project), ParentNref,
		#relationship.source_nref),
	Nrefs = [A#relationship.target_nref || A <- Arcs,
		A#relationship.kind =:= RelKind,
		A#relationship.characterization =:= ChildArc],
	lists:flatmap(fun(N) -> mnesia:read(graphdb_ns:node_table(Project), N) end,
		Nrefs).
```

- [ ] **Step 4: `do_class_of/2`, `do_class_memberships/2` (unchanged body, gains `Project` passthrough), `do_resolve_value/3` + its helpers**

```erlang
do_class_of(Project, InstanceNref) ->
	F = fun() ->
		Rels = mnesia:index_read(graphdb_ns:rel_table(Project), InstanceNref,
			#relationship.source_nref),
		lists:search(
			fun(R) ->
				R#relationship.characterization =:= ?ARC_INST_TO_CLASS
			end, Rels)
	end,
	case graphdb_mgr:transaction(F) of
		{ok, {value, #relationship{target_nref = ClassNref}}} ->
			{ok, ClassNref};
		{ok, false}     -> not_found;
		{error, Reason} -> {error, Reason}
	end.

do_class_memberships(Project, InstanceNref) ->
	case do_get_instance(Project, InstanceNref) of
		{ok, #node{classes = Classes}} -> {ok, Classes};
		{error, _} = Err               -> Err
	end.

do_resolve_value(Project, InstNref, AttrNref) ->
	case do_get_instance(Project, InstNref) of
		{ok, Node} ->
			case find_avp_value(Node#node.attribute_value_pairs, AttrNref) of
				{ok, V} ->
					{ok, V, local};
				not_found ->
					resolve_value_priority_2_and_below(Project, Node, AttrNref)
			end;
		{error, _} = Err ->
			Err
	end.
```

`resolve_value_priority_2_and_below/3` names whatever internal continuation
`do_resolve_value/2` currently falls through to after the local-AVP check —
**read the current function body from `apps/graphdb/src/graphdb_instance.erl`
starting at `do_resolve_value/2` (around line 2001) before writing this
step**, since only the excerpt above (through the Priority-1 local check)
was captured verbatim during planning; preserve every subsequent priority
branch's logic exactly, threading `Project` into the two helpers below in
place of the bare `mnesia:dirty_read(nodes, ...)` calls they make.

```erlang
resolve_from_ancestors(_Project, undefined, _AttrNref) ->
	not_found;
resolve_from_ancestors(Project, ParentNref, AttrNref) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), ParentNref) of
		[#node{kind = instance, parents = GrandParents,
				attribute_value_pairs = AVPs}] ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V}   -> {ok, V, ParentNref};
				not_found -> resolve_from_ancestors(Project,
								head_parent(GrandParents), AttrNref)
			end;
		[_] ->
			not_found;
		[] ->
			not_found
	end.

resolve_from_connected(Project, InstNref, AttrNref) ->
	F = fun() ->
		mnesia:index_read(graphdb_ns:rel_table(Project), InstNref,
			#relationship.source_nref)
	end,
	case graphdb_mgr:transaction(F) of
		{ok, Rels} ->
			TargetNrefs = lists:usort(
				[R#relationship.target_nref
					|| R <- Rels, R#relationship.kind =:= connection]),
			search_targets(Project, TargetNrefs, AttrNref);
		{error, _} ->
			not_found
	end.

search_targets(_Project, [], _AttrNref) ->
	not_found;
search_targets(Project, [Nref | Rest], AttrNref) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V}   -> {ok, V, Nref};
				not_found -> search_targets(Project, Rest, AttrNref)
			end;
		_ ->
			search_targets(Project, Rest, AttrNref)
	end.
```

Priority 2 (`graphdb_class:search_class_taxonomy/2`) is unchanged — it takes
a class nref and reads only environment class nodes, no `Project` needed.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T8: instance reads (get_instance/children/ancestors/class_of/resolve_value) take Project"
```

---

## Task 9: `graphdb_instance` — `add_class_membership` routes through `Project`

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Produces: `do_add_class_membership/5` (was `/4`, gains leading `Project`),
  `do_write_class_membership/3` (was `/2`).

- [ ] **Step 1: `handle_call`**

```erlang
handle_call({add_class_membership, Project, InstanceNref, ClassNref}, _From,
		#state{instantiable_nref = InstAttr, retired_nref = RetAttr} = State) ->
	{reply, do_add_class_membership(Project, InstanceNref, ClassNref, InstAttr,
		RetAttr), State};
```

- [ ] **Step 2: `do_add_class_membership/5` and `do_write_class_membership/3`**

```erlang
do_add_class_membership(Project, InstanceNref, ClassNref, InstAttr, RetAttr) ->
	case do_get_instance(Project, InstanceNref) of
		{ok, _} ->
			case do_validate_class(ClassNref, InstAttr, RetAttr) of
				ok               -> do_write_class_membership(Project,
									InstanceNref, ClassNref);
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.

do_write_class_membership(Project, InstanceNref, ClassNref) ->
	{Id1, Id2} = graphdb_project:next_rel_id_pair(Project),
	NodesTab = graphdb_ns:node_table(Project),
	RelsTab  = graphdb_ns:rel_table(Project),
	Txn = fun() ->
		[#node{kind = instance, classes = Classes} = Node] =
			mnesia:read(NodesTab, InstanceNref),
		case lists:member(ClassNref, Classes) of
			true ->
				already_exists;
			false ->
				I2C = #relationship{
					id = Id1, kind = instantiation,
					source_nref = InstanceNref,
					characterization = ?ARC_INST_TO_CLASS,
					target_nref = ClassNref,
					reciprocal = ?ARC_CLASS_TO_INST,
					avps = []
				},
				C2I = #relationship{
					id = Id2, kind = instantiation,
					source_nref = ClassNref,
					characterization = ?ARC_CLASS_TO_INST,
					target_nref = InstanceNref,
					reciprocal = ?ARC_INST_TO_CLASS,
					avps = []
				},
				Updated = Node#node{classes = Classes ++ [ClassNref]},
				ok = mnesia:write(NodesTab, Updated, write),
				ok = mnesia:write(RelsTab, I2C, write),
				ok = mnesia:write(RelsTab, C2I, write),
				ok
		end
	end,
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{error, _} = Err     -> Err
	end.
```

(`I2C`/`C2I` both go to `RelsTab` — same co-location exception documented in
Task 4, Step 4 for `instance_records/5`.)

- [ ] **Step 3: Verify the module compiles end-to-end and its own EUnit-in-source helpers still resolve**

Run: `./rebar3 compile --app=graphdb` (or the whole umbrella).
Expected: `graphdb_instance.erl` compiles cleanly. This is the first point
since Task 3 where the module is expected to be internally consistent —
resolve any remaining arity mismatches now by grepping for the old arities:

```bash
grep -n "with_session\|open_session\|session_project\|require_session" apps/graphdb/src/graphdb_instance.erl
```

Expected: no matches (all renamed in Tasks 3-9).

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "SP2 T9: add_class_membership routes through Project; module compiles end-to-end"
```

---

## Task 10: `graphdb_mgr` — `Project`-taking twins of `get_node`, `retire_node`, `unretire_node`, `update_node_avps`, `delete_node`

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl`

**Interfaces:**
- Consumes: `graphdb_ns:node_table/1` (Task 1), `graphdb_project:require_project/1`
  (Task 2).
- Produces: `get_node/2`, `retire_node/2`, `unretire_node/2`,
  `update_node_avps/3`, `delete_node/2`. The existing `/1` (and `/2` for
  `update_node_avps`) forms are UNCHANGED — they stay environment-only,
  same behaviour as today. This closes the collision gap identified during
  planning (approved by the user): before this task, calling e.g.
  `update_node_avps(5, AVPs)` for what the caller means as "project
  instance 5" would silently edit the environment's nref-5 node instead.

Unlike `retire_node/1`'s existing `Nref < ?NREF_START` permanent-tier guard,
the new `/2` forms have **no** tier guard — per the design, a project's
allocator has no permanent tier at all (§4: "Project: allocator starts at
1 — no pre-assigned nrefs, no bootstrap file, no floor needed"), so every
project nref is always mutable.

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_mgr_SUITE.erl` (exact placement: alongside
the existing `retire_node`/`update_node_avps` test groups; add to `all/0`
and the test `-export`):

```erlang
get_node_2_reads_project_instance(_Config) ->
	Project = proj(),
	{ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
		widget_class(), root_instance(Project)),
	{ok, #node{nref = Nref, kind = instance}} =
		graphdb_mgr:get_node(Project, Nref).

get_node_2_does_not_leak_into_environment_table(_Config) ->
	Project = proj(),
	%% Project instance nref 1 must not resolve to the environment's nref 1
	%% (Root, a category node).
	{ok, 1, _Report} = graphdb_instance:create_instance(Project, "First",
		widget_class(), root_instance(Project)),
	{ok, #node{kind = instance}} = graphdb_mgr:get_node(Project, 1),
	{ok, #node{kind = category}} = graphdb_mgr:get_node(?NREF_ROOT).

retire_node_2_retires_a_project_instance(_Config) ->
	Project = proj(),
	{ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
		widget_class(), root_instance(Project)),
	ok = graphdb_mgr:retire_node(Project, Nref),
	{ok, Node} = graphdb_mgr:get_node(Project, Nref),
	?assert(graphdb_mgr:has_true_avp(Node)).

update_node_avps_3_edits_a_project_instance(_Config) ->
	Project = proj(),
	{ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
		widget_class(), root_instance(Project)),
	Colour = ensure_colour_attribute(),
	ok = graphdb_mgr:update_node_avps(Project, Nref,
		[#{attribute => Colour, value => "blue"}]),
	{ok, #node{attribute_value_pairs = AVPs}} =
		graphdb_mgr:get_node(Project, Nref),
	?assertEqual({ok, "blue"}, find_avp(AVPs, Colour)).

delete_node_2_reports_not_implemented(_Config) ->
	Project = proj(),
	{ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
		widget_class(), root_instance(Project)),
	?assertEqual({error, not_implemented}, graphdb_mgr:delete_node(Project, Nref)).
```

Note: `widget_class/0`, `root_instance/1`, `ensure_colour_attribute/0`,
`find_avp/2` are placeholders for whatever helper names
`graphdb_mgr_SUITE.erl` already uses for "create a throwaway class" /
"create a throwaway project-root instance" / "look up an AVP by attribute
nref" — **read the existing test bodies in that suite before writing
these** (the CT suite already has instance-creation tests exercising this
exact setup for other purposes; reuse its established helpers rather than
inventing new ones, per this codebase's convention of one helper per
concern reused across a suite's test cases).

- [ ] **Step 2: Run to verify these fail**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_mgr_SUITE`
Expected: undef errors for `get_node/2`, `retire_node/2`,
`update_node_avps/3`, `delete_node/2` (once `proj()` exists — see Task 12;
if Task 12 hasn't landed yet in your execution order, stub `proj()` locally
in this suite first by copying Task 12's helper, then let Task 12 remove
the duplicate).

- [ ] **Step 3: Add the exports and public heads**

```erlang
-export([
		start_link/0,
		%% Read operations
		get_node/1,
		get_node/2,
		get_relationships/1,
		get_relationships/2,
		%% Write operations (delegate to workers)
		create_attribute/3,
		create_class/2,
		create_instance/4,
		add_relationship/5,
		delete_node/1,
		delete_node/2,
		retire_node/1,
		retire_node/2,
		unretire_node/1,
		unretire_node/2,
		update_node_avps/2,
		update_node_avps/3,
		%% Batch write (tier-3 entry point)
		mutate/1,
		mutate/2,
		%% Tier-1 in-txn write primitive (composed by mutate/1,2)
		update_node_avps_in_txn/4,
		%% Transaction helper (write-path seam)
		transaction/1,
		%% Cache invariant audit / repair
		verify_caches/0,
		rebuild_caches/0
		]).
```

(`update_node_avps_in_txn/3` becomes `/4` — Step 5 below. `mutate/2` is
Task 11.)

```erlang
%%-----------------------------------------------------------------------------
%% get_node(Project, Nref) -> {ok, #node{}} | {error, not_found | term()}
%%
%% Reads a single node from Project's own nodes table. Unlike get_node/1,
%% no retired-marker check -- SP1/SP2 have not extended the retired-read
%% guard to the project write path; project reads return the raw node.
%%-----------------------------------------------------------------------------
get_node(Project, Nref) ->
	gen_server:call(?MODULE, {get_node, Project, Nref}).

%%-----------------------------------------------------------------------------
%% delete_node(Project, Nref) -> ok | {error, term()}
%% Project-scoped twin of delete_node/1. Actual deletion not yet implemented.
%%-----------------------------------------------------------------------------
delete_node(Project, Nref) ->
	gen_server:call(?MODULE, {delete_node, Project, Nref}).

%%-----------------------------------------------------------------------------
%% retire_node(Project, Nref) -> ok | {error, Reason}
%% unretire_node(Project, Nref) -> ok | {error, Reason}
%%
%% Project-scoped twins. No permanent-tier guard: a project's allocator has
%% no permanent tier (design §4) -- every project nref is mutable.
%%-----------------------------------------------------------------------------
retire_node(Project, Nref) ->
	gen_server:call(?MODULE, {retire_node, Project, Nref}).

unretire_node(Project, Nref) ->
	gen_server:call(?MODULE, {unretire_node, Project, Nref}).

%%-----------------------------------------------------------------------------
%% update_node_avps(Project, Nref, AVPs) -> ok | {error, term()}
%% Project-scoped twin of update_node_avps/2.
%%-----------------------------------------------------------------------------
-spec update_node_avps(map(), integer(), [map()]) -> ok | {error, term()}.
update_node_avps(Project, Nref, AVPs) ->
	case validate_avp_updates(AVPs) of
		ok ->
			gen_server:call(?MODULE, {update_node_avps, Project, Nref, AVPs});
		{error, _} = Err ->
			Err
	end.
```

- [ ] **Step 4: `handle_call` clauses**

```erlang
handle_call({get_node, Project, Nref}, _From, State) ->
	{reply, do_get_node(Project, Nref), State};

handle_call({retire_node, Project, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Project, Nref, true, State0),
	{reply, Reply, State};
handle_call({unretire_node, Project, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Project, Nref, false, State0),
	{reply, Reply, State};

handle_call({delete_node, Project, Nref}, _From, State) ->
	case check_category_guard(Project, Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			{reply, {error, not_implemented}, State}
	end;

handle_call({update_node_avps, Project, Nref, AVPs}, _From, State) ->
	case check_category_guard(Project, Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			{Reply, State1} = do_update_node_avps(Project, Nref, AVPs, State),
			{reply, Reply, State1}
	end;
```

These are NEW clauses added alongside the existing `{get_node, Nref}`,
`{retire_node, Nref}`, `{unretire_node, Nref}`, `{delete_node, Nref}`,
`{update_node_avps, Nref, AVPs}` clauses (which stay byte-for-byte
unchanged — do not touch them).

- [ ] **Step 5: Internal helpers gain `Home` overloads**

```erlang
%%-----------------------------------------------------------------------------
%% do_get_node(Home, Nref) -> {ok, #node{}} | {error, not_found}
%%-----------------------------------------------------------------------------
do_get_node(Home, Nref) ->
	case mnesia:dirty_read(graphdb_ns:node_table(Home), Nref) of
		[Node] -> {ok, Node};
		[]     -> {error, not_found}
	end.
```

Existing `do_get_node/1` stays; add this `/2` clause alongside it (do not
collapse them — `do_get_node/1` is called from `check_category_guard/1`,
`handle_call({get_node, Nref}, ...)`, `set_retired/3`'s existing arity, and
`ensure_retired_nref` is unrelated; keep both arities distinct rather than
threading `environment` through every existing call site).

```erlang
%%-----------------------------------------------------------------------------
%% check_category_guard(Home, Nref) -> ok | {error, ...}
%%-----------------------------------------------------------------------------
check_category_guard(Home, Nref) ->
	case do_get_node(Home, Nref) of
		{ok, #node{kind = category}} ->
			{error, category_nodes_are_immutable};
		{ok, _} ->
			ok;
		{error, _} = Err ->
			Err
	end.

%%-----------------------------------------------------------------------------
%% set_retired(Project, Nref, Bool, State) -> {ok | {error, Reason}, State'}
%% No permanent-tier guard for a project (see moduledoc above retire_node/2).
%%-----------------------------------------------------------------------------
set_retired(Project, Nref, Bool, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> set_retired_(Project, Nref, Bool, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.

set_retired_(Home, Nref, Bool, RetAttr) ->
	NodesTab = graphdb_ns:node_table(Home),
	case mnesia:read(NodesTab, Nref, write) of
		[]     -> mnesia:abort(not_found);
		[Node] ->
			AVPs0 = Node#node.attribute_value_pairs,
			AVPs1 = set_marker(AVPs0, RetAttr, Bool),
			mnesia:write(NodesTab,
				Node#node{attribute_value_pairs = AVPs1}, write)
	end.

%%-----------------------------------------------------------------------------
%% do_update_node_avps(Project, Nref, AVPs, State) -> {ok | {error, Reason}, State'}
%% No permanent-tier guard for a project.
%%-----------------------------------------------------------------------------
do_update_node_avps(Project, Nref, AVPs, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> update_node_avps_in_txn(Project, Nref, AVPs, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.
```

**IMPORTANT — this changes `set_retired_/3` and `update_node_avps_in_txn/3`'s
existing arity**, both of which are already exported / called elsewhere
(`update_node_avps_in_txn/3` is in the module's export list and is a
documented "Tier-1 in-txn write primitive composed by mutate/1"). Rename the
EXISTING environment-only 3-arg/3-arg forms to also take `Home`, and update
their two existing call sites (`set_retired/3`'s body, and
`do_update_node_avps/3`'s body) to pass the literal atom `environment`:

```erlang
%%-----------------------------------------------------------------------------
%% set_retired(Nref, Bool, State) -> {ok | {error, Reason}, State'}    (env-only)
%%-----------------------------------------------------------------------------
set_retired(Nref, _Bool, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
set_retired(Nref, Bool, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> set_retired_(environment, Nref, Bool, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.
```

```erlang
%%-----------------------------------------------------------------------------
%% do_update_node_avps(Nref, AVPs, State) -> {ok | {error, Reason}, State'}    (env-only)
%%-----------------------------------------------------------------------------
do_update_node_avps(Nref, _AVPs, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
do_update_node_avps(Nref, AVPs, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> update_node_avps_in_txn(environment, Nref, AVPs, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.
```

```erlang
%%-----------------------------------------------------------------------------
%% update_node_avps_in_txn(Home, Nref, AVPs, RetAttr) -> ok
%%-----------------------------------------------------------------------------
update_node_avps_in_txn(Home, Nref, AVPs, RetAttr) ->
	NodesTab = graphdb_ns:node_table(Home),
	case mnesia:read(NodesTab, Nref, write) of
		[] ->
			mnesia:abort(not_found);
		[Node] ->
			ok = guard_retired_marker(AVPs, RetAttr),
			ok = guard_instance_only(Node#node.attribute_value_pairs, AVPs),
			ok = guard_attribute_existence(AVPs),
			New = apply_avp_updates(Node#node.attribute_value_pairs, AVPs),
			mnesia:write(NodesTab, Node#node{attribute_value_pairs = New}, write)
	end.
```

`guard_attribute_existence/1` is unchanged — it validates AVP `attribute`
nrefs against the environment attribute library regardless of which node's
AVPs are being edited (attribute nrefs are always environment). Do not
thread `Home` into it.

Update the export list entry from `update_node_avps_in_txn/3` to
`update_node_avps_in_txn/4` (already reflected in Step 3's export block
above) and grep for any other caller of the old arity:

```bash
grep -rn "update_node_avps_in_txn\|set_retired_(" apps/graphdb/src/ apps/graphdb/test/
```

Fix every remaining `/3`-arity call site found (there should be none left
after this task and Task 11).

- [ ] **Step 6: Run to verify tests pass**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_mgr_SUITE`
Expected: PASS on the five new tests (full suite may still fail until
Task 12 fixes `proj()`/`sess()` — note and continue if so).

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "SP2 T10: get_node/retire_node/unretire_node/update_node_avps/delete_node gain Project-taking twins"
```

---

## Task 11: `graphdb_mgr` — `mutate/2`

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl`
- Modify: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_instance:add_relationship_in_txn/10`,
  `remove_relationship_in_txn/5`, `update_relationship_avps_in_txn/6`,
  `update_relationship_both_in_txn/7` (Tasks 5, 7); `update_node_avps_in_txn/4`,
  `set_retired_/4` (Task 10).
- Produces: `mutate/2 :: (Project, [Mutation]) -> {ok, [term()]} | {error,
  term()}`. `mutate/1`'s existing behaviour and grammar are UNCHANGED —
  internally it now delegates to a `Home`-parameterised implementation with
  `Home = environment`.

- [ ] **Step 1: Write the failing test**

Add to `graphdb_mgr_SUITE.erl`:

```erlang
mutate_2_batches_within_one_project(_Config) ->
	Project = proj(),
	{ok, Root, _} = graphdb_instance:create_instance(Project, "Root",
		widget_class(), root_instance(Project)),
	{ok, A, _} = graphdb_instance:create_instance(Project, "A", widget_class(),
		Root),
	{ok, B, _} = graphdb_instance:create_instance(Project, "B", widget_class(),
		Root),
	{Char, Recip} = connects_to_attrs(),
	{ok, [ok]} = graphdb_mgr:mutate(Project,
		[{add_relationship, A, Char, B, Recip}]),
	{ok, #node{}} = graphdb_mgr:get_node(Project, A).

mutate_1_still_rejects_permanent_tier(_Config) ->
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:mutate([{retire_node, ?NREF_ROOT}])).
```

(`connects_to_attrs/0` — reuse whatever existing helper the suite already
has for a reciprocal connection-attribute pair, or add one following the
pattern of the suite's existing `add_relationship` tests.)

- [ ] **Step 2: Run to verify it fails**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_mgr_SUITE`
Expected: undef `graphdb_mgr:mutate/2`.

- [ ] **Step 3: Add `mutate/2` and thread `Home` through the batch pipeline**

```erlang
%%-----------------------------------------------------------------------------
%% mutate(Project, [Mutation]) -> {ok, [term()]} | {error, term()}
%%
%% Project-scoped twin of mutate/1: applies the same mutation grammar, but
%% resolves Home = Project instead of environment, so add_relationship /
%% remove_relationship / update_relationship(_both) / update_node_avps /
%% retire_node / unretire_node all touch Project's own tables. A batch may
%% still mix environment and project references (an add_relationship whose
%% Char/Recip are environment attribute nrefs, as always) but spans at most
%% one project plus the environment (design §7).
%%-----------------------------------------------------------------------------
-spec mutate(map(), [tuple()]) -> {ok, [term()]} | {error, term()}.
mutate(Project, Mutations) ->
	do_mutate(Project, Mutations).
```

Rename the existing `mutate/1` body to delegate:

```erlang
-spec mutate([tuple()]) -> {ok, [term()]} | {error, term()}.
mutate(Mutations) ->
	do_mutate(environment, Mutations).

do_mutate(Home, Mutations) ->
	case validate_mutations(Mutations) of
		ok               -> run_mutations(Home, Mutations);
		{error, _} = Err -> Err
	end.
```

`validate_mutations/1` and `validate_mutation/1` are UNCHANGED (static,
no table access — the permanent-tier guard in `tier_guard/1` stays
environment-tier-shaped deliberately: a `mutate/2` batch's `retire_node`
target could be either an environment nref, still subject to the tier
guard, or a project nref, which per Task 10 has no tier at all).

Add a `tier_guard/2` overload used only from the `Home`-aware path, and have
`prepare/2`'s `retire_node`/`unretire_node`/`update_node_avps` arms carry
`Home` forward for `dispatch/3` to use — the guard itself stays
`Nref`-shaped since it is pure client-side validation, unchanged from
`validate_mutation/1`'s existing call. Do not add a `Home`-aware tier guard;
`validate_mutation/1` remains as-is (this is intentional: `retire_node`
inside a `mutate/2` batch on a genuinely environment-tier nref should still
be blocked by the exact same guard that blocks it in `mutate/1`, and a
project nref is never `< ?NREF_START` by construction since project
allocators start at 1 and the guard only ever fires for small nrefs that
also happen to be valid project nrefs — this is a known, accepted rough
edge: **a project's retire_node/unretire_node mutation for project nref 1
through 999999 will incorrectly hit `tier_guard/1`'s `Nref < ?NREF_START`
check and be rejected as `permanent_node_immutable`.** Flag this explicitly
in code review — see the note below).

**Stop and re-read**: this is a real bug the mechanical thread-through
would introduce silently. `tier_guard/1` in `validate_mutation/1` fires for
ANY `Nref < ?NREF_START` regardless of `Home` — which is wrong for a project
nref (no permanent tier exists for projects). Fix `validate_mutation/1`'s
three call sites (`retire_node`, `unretire_node`, `update_node_avps`) to
carry `Home` into the guard:

```erlang
validate_mutation(Home, {retire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Home, Nref);
validate_mutation(Home, {unretire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Home, Nref);
validate_mutation(Home, {update_node_avps, Nref, AVPs}) when is_integer(Nref) ->
	case validate_avp_updates(AVPs) of
		ok               -> tier_guard(Home, Nref);
		{error, _} = Err -> Err
	end;
%% ... every other clause of validate_mutation/1 gains a leading Home
%% parameter it ignores (it's a pure shape check, unaffected by Home) ...
validate_mutation(_Home, M) ->
	{error, {bad_mutation, M}}.

tier_guard(Home, Nref) when Home =/= environment -> ok;  %% projects: no permanent tier
tier_guard(environment, Nref) when Nref >= ?NREF_START -> ok;
tier_guard(environment, _Nref)                         -> {error, permanent_node_immutable}.
```

Rename `validate_mutations/1` → `validate_mutations/2` accordingly (threads
`Home` through its fold), and update `do_mutate/2`:

```erlang
do_mutate(Home, Mutations) ->
	case validate_mutations(Home, Mutations) of
		ok               -> run_mutations(Home, Mutations);
		{error, _} = Err -> Err
	end.

validate_mutations(_Home, []) ->
	ok;
validate_mutations(Home, [M | Rest]) ->
	case validate_mutation(Home, M) of
		ok               -> validate_mutations(Home, Rest);
		{error, _} = Err -> Err
	end.
```

Now `run_mutations/2`, `prepare/2`, and `dispatch/4`:

```erlang
run_mutations(_Home, []) ->
	{ok, []};
run_mutations(Home, Mutations) ->
	{ok, #{target_kind := TkAttr, retired := RetAttr}} =
		graphdb_attr:seeded_nrefs(),
	Prepared = [prepare(Home, M) || M <- Mutations],
	graphdb_mgr:transaction(fun() ->
		[dispatch(Home, P, TkAttr, RetAttr) || P <- Prepared]
	end).

prepare(Home, {add_relationship, S, C, T, R}) ->
	{add_relationship, alloc_rel_id_pair(Home), S, C, T, R, default, {[], []}};
prepare(Home, {add_relationship, S, C, T, R, Template}) ->
	{add_relationship, alloc_rel_id_pair(Home), S, C, T, R, Template, {[], []}};
prepare(Home, {add_relationship, S, C, T, R, Template, AVPSpec}) ->
	{add_relationship, alloc_rel_id_pair(Home), S, C, T, R, Template, AVPSpec};
prepare(_Home, {retire_node, _Nref} = M) ->
	M;
prepare(_Home, {unretire_node, _Nref} = M) ->
	M;
prepare(_Home, {update_node_avps, _Nref, _AVPs} = M) ->
	M;
prepare(_Home, {remove_relationship, _S, _C, _T} = M) ->
	M;
prepare(_Home, {remove_relationship, _S, _C, _T, _Template} = M) ->
	M;
prepare(_Home, {update_relationship, _S, _C, _T, _U} = M) ->
	M;
prepare(_Home, {update_relationship, _S, _C, _T, _Template, _U} = M) ->
	M;
prepare(_Home, {update_relationship_both, _S, _C, _T, _Pair} = M) ->
	M;
prepare(_Home, {update_relationship_both, _S, _C, _T, _Template, _Pair} = M) ->
	M.

%% Duplicated 2-clause Home-dispatch helper (same YAGNI precedent as
%% is_retired/2's per-module duplication) -- graphdb_instance has its own
%% copy inline in do_add_relationship/8 (Task 5).
alloc_rel_id_pair(environment) -> rel_id_server:get_id_pair();
alloc_rel_id_pair(Project)     -> graphdb_project:next_rel_id_pair(Project).

dispatch(Home, {add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec},
		TkAttr, RetAttr) ->
	graphdb_instance:add_relationship_in_txn(Home, IdPair, S, C, T, R,
		TemplateSpec, AVPSpec, TkAttr, RetAttr);
dispatch(Home, {retire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Home, Nref, true, RetAttr);
dispatch(Home, {unretire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Home, Nref, false, RetAttr);
dispatch(Home, {update_node_avps, Nref, AVPs}, _TkAttr, RetAttr) ->
	update_node_avps_in_txn(Home, Nref, AVPs, RetAttr);
dispatch(Home, {remove_relationship, S, C, T}, _TkAttr, _RetAttr) ->
	graphdb_instance:remove_relationship_in_txn(Home, S, C, T, any);
dispatch(Home, {remove_relationship, S, C, T, Template}, _TkAttr, _RetAttr) ->
	graphdb_instance:remove_relationship_in_txn(Home, S, C, T, Template);
dispatch(Home, {update_relationship, S, C, T, U}, _TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_avps_in_txn(Home, S, C, T, any, U);
dispatch(Home, {update_relationship, S, C, T, Template, U}, _TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_avps_in_txn(Home, S, C, T, Template, U);
dispatch(Home, {update_relationship_both, S, C, T, {Fwd, Rev}}, _TkAttr,
		_RetAttr) ->
	graphdb_instance:update_relationship_both_in_txn(Home, S, C, T, any, Fwd,
		Rev);
dispatch(Home, {update_relationship_both, S, C, T, Template, {Fwd, Rev}},
		_TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_both_in_txn(Home, S, C, T, Template,
		Fwd, Rev).
```

`dispatch/3`'s call sites (both inside `run_mutations/2`) already updated
above to `dispatch/4` (leading `Home`).

`update_node_avps_in_txn/3` (test-only export) — remove from the
`-ifdef(TEST)` export block if present; it does not exist as a `/3` anymore
after Task 10 renamed it to `/4`. Grep to confirm:

```bash
grep -n "update_node_avps_in_txn/3\|check_category_guard/1" apps/graphdb/src/graphdb_mgr.erl
```

- [ ] **Step 4: Run to verify tests pass**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_mgr_SUITE`
Run: `./rebar3 eunit --app=graphdb` (the `-ifdef(TEST)` exports changed
arity; confirm any EUnit test in `graphdb_mgr` that called
`validate_mutation/1` or `tier_guard/1` directly is updated to the new
`/2` arity — grep `apps/graphdb/test/graphdb_mgr_tests.erl` if it exists).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "SP2 T11: mutate/2 -- batch entry point takes a Project; fixes tier_guard for project nrefs"
```

---

## Task 12: `graphdb_query` — session gains a `Project`, reads resolve `Home` per nref

**Files:**
- Modify: `apps/graphdb/src/graphdb_query.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_ns:node_table/1`, `rel_table/1` (Task 1).
- Produces: `new_session/1 :: (Project) -> Session` (session map gains a
  `project` key); `session_read_node/2` and `session_read_arcs/4` behaviour
  changes internally (same public signature) to resolve `Home` per nref via
  a new `resolve_home/2` instead of assuming the environment table.

**Preserve `graphdb_query.erl`'s existing space-indentation style
throughout this task** — do not introduce tabs into this file.

**Routing rule for this task (read before writing code):** every
`session_read_node`/`session_read_arcs` call in this module is a
**bare-nref, no-characterization-context** read (`#q_get_node{}`,
`#q_describe{}`, `#q_find_path{}`'s endpoints, and every arc-discovered
nref during BFS/`#q_instances_of{}` traversal) — the query language's
records carry no `target_kind`/`characterization` alongside the nref, unlike
`graphdb_instance`'s connection-arc primitives. So this task cannot reuse
`graphdb_ns:target_namespace/2` directly (it needs a `TargetKind` this
module never has in hand). Instead: **when the session is bound to a
`Project`, try the project's table first, falling back to environment.**
This is deliberately intent-following, not exhaustive-and-arbitrary: a query
session opened against a project is evidence the caller means that
project's nrefs first; environment nrefs (bootstrap scaffold, attributes,
classes) are the fallback. If a key genuinely exists in BOTH tables — e.g. a
tiny project has grown an instance whose nref equals a low environment
scaffold nref — that is a real ambiguity the project's copy resolves in
the project's favor, and it is logged (not silently swallowed) so the
collision is visible to whoever operates the system. Flag this design
choice explicitly to the user in code review; it is the one place in SP2
where "try both, pick a winner" was chosen over the home-relative
determinism used everywhere else, because the query language's entry points
give no characterization context to determine Home outright.

- [ ] **Step 1: Write the failing tests**

Add to `apps/graphdb/test/graphdb_query_SUITE.erl` (2 spaces indentation,
matching this file's own style — confirm by reading a few existing test
bodies in the file before writing):

```erlang
new_session_1_binds_a_project(_Config) ->
    Project = proj(),
    Session = graphdb_query:new_session(Project),
    ?assertEqual(Project, maps:get(project, Session)).

q_get_node_reads_a_project_instance(_Config) ->
    Project = proj(),
    {ok, Nref, _Report} = graphdb_instance:create_instance(Project, "Widget",
        widget_class(), root_instance(Project)),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := Nref, kind := instance}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = Nref}, Session).

q_get_node_still_reads_environment_when_project_bound(_Config) ->
    Project = proj(),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := ?NREF_ROOT, kind := category}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = ?NREF_ROOT}, Session).

resolve_home_prefers_project_and_logs_on_collision(_Config) ->
    Project = proj(),
    %% Project instance nref 1 collides in KEY (not identity) with the
    %% environment's Root (nref 1) -- resolve_home must return the
    %% project's copy, not silently return environment's.
    {ok, 1, _Report} = graphdb_instance:create_instance(Project, "First",
        widget_class(), root_instance(Project)),
    Session = graphdb_query:new_session(Project),
    {ok, #{nref := 1, kind := instance}, _Session1} =
        graphdb_query:execute_query(#q_get_node{nref = 1}, Session).
```

(`widget_class/0`, `root_instance/1`, `proj/0` — reuse this suite's existing
helper conventions, matching whatever the current `sess()`-based tests
already use for setup, per Task 15's `proj()` rename.)

- [ ] **Step 2: Run to verify these fail**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_query_SUITE`
Expected: undef `graphdb_query:new_session/1`.

- [ ] **Step 3: `new_session/1`**

```erlang
new_session(Project) ->
    #{snapshot_at => os:timestamp(),
      cache       => #{},
      project     => Project}.
```

(`new_session/0` and `refresh/1` are unchanged — `refresh/1` already
preserves unknown keys since it only sets `snapshot_at`/`cache` via `:=`
on an existing map, so a `project`-bearing session survives a refresh
unchanged. Confirm this by reading `refresh/1`'s current body — it uses
`Session#{snapshot_at := ..., cache := ...}`, which is key-preserving for
`project`.)

- [ ] **Step 4: `resolve_home/2`, `session_read_node/2`, `session_read_arcs/4`, `read_arcs/4`**

```erlang
%%---------------------------------------------------------------------
%% resolve_home(Session, Nref) -> environment | Project
%%
%% Determines which store an Nref belongs to when no relationship context
%% is available (see the moduledoc note on this task in the plan / the
%% module's own comment block once written). Tries the session's bound
%% Project first (if any); a genuine ambiguity (the key exists in BOTH
%% tables) is logged, and the project's copy wins on the theory that a
%% session opened against a project is evidence of caller intent.
%%---------------------------------------------------------------------
resolve_home(#{project := Project}, Nref) when Project =/= undefined ->
    case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
        [_] ->
            case mnesia:dirty_read(nodes, Nref) of
                [_] ->
                    logger:warning(
                        "graphdb_query: nref ~p exists in both project ~p "
                        "and the environment -- resolving to the project",
                        [Nref, maps:get(anchor, Project)]);
                [] ->
                    ok
            end,
            Project;
        [] ->
            environment
    end;
resolve_home(_Session, _Nref) ->
    environment.

%%---------------------------------------------------------------------
%% session_read_node(Session, Nref) -> {Node | not_found, Session1}
%%---------------------------------------------------------------------
session_read_node(#{cache := Cache} = Session, Nref) ->
    case maps:get({node, Nref}, Cache, miss) of
        miss ->
            Home = resolve_home(Session, Nref),
            case mnesia:dirty_read(graphdb_ns:node_table(Home), Nref) of
                [Node] ->
                    Cache1 = Cache#{{node, Nref} => Node},
                    {Node, Session#{cache := Cache1}};
                [] ->
                    {not_found, Session}
            end;
        Node ->
            {Node, Session}
    end.

%%---------------------------------------------------------------------
%% session_read_arcs(Session, Nref, Direction, KindFilter)
%%     -> {[#relationship{}], Session1}
%%---------------------------------------------------------------------
session_read_arcs(#{cache := Cache} = Session, Nref, Dir, Kinds) ->
    Key = {arcs, Nref, Dir, Kinds},
    case maps:get(Key, Cache, miss) of
        miss ->
            Home = resolve_home(Session, Nref),
            Arcs = read_arcs(Home, Nref, Dir, Kinds),
            Cache1 = Cache#{Key => Arcs},
            {Arcs, Session#{cache := Cache1}};
        Cached ->
            {Cached, Session}
    end.

read_arcs(Home, Nref, outgoing, Kinds) ->
    Raw = mnesia:dirty_index_read(graphdb_ns:rel_table(Home), Nref,
                                  #relationship.source_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Home, Nref, incoming, Kinds) ->
    Raw = mnesia:dirty_index_read(graphdb_ns:rel_table(Home), Nref,
                                  #relationship.target_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Home, Nref, both, Kinds) ->
    read_arcs(Home, Nref, outgoing, Kinds) ++ read_arcs(Home, Nref, incoming, Kinds).
```

`filter_kinds/2` is unchanged.

Note `resolve_home/2`'s first clause guards `Project =/= undefined` — this
matters because `new_session/0` (no project) does NOT set a `project` key
at all, so the first clause's map pattern `#{project := Project}` simply
won't match for an env-only session and falls through to the catch-all
`environment` clause. The `=/= undefined` guard is defensive for a future
caller that explicitly sets `project => undefined`; keep it for robustness
but it is not load-bearing against `new_session/0` today.

- [ ] **Step 5: Run to verify tests pass**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_query_SUITE`
Expected: PASS (once Task 15's `proj()` helper lands — coordinate ordering
with that task, or stub `proj()` locally here first as noted in Task 10).

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_query.erl apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "SP2 T12: graphdb_query session binds a Project; reads resolve Home per nref"
```

---

## Task 13: `graphdb_rules` — scope-tag documentation and test-placeholder polish

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

**Interfaces:** none — this is a comment/prose and test-fixture-realism
task. No function signature changes; `{project, _}` already pattern-matches
any second element, including a real `Project` map, so this task changes
nothing at runtime.

- [ ] **Step 1: Update the moduledoc comments**

`graphdb_rules.erl` has 8 comment lines matching `{project, _}` (confirmed
via `grep -n "{project," apps/graphdb/src/graphdb_rules.erl`, lines 176,
206, 224, 233, 246, 266, 287, 296 as of this plan's writing — re-grep before
editing, since Tasks 1-12 do not touch this file and line numbers should be
stable, but confirm). For each, change the prose from `{project, _}` to
`{project, Project}` (`Project` = a `graphdb_project` handle, per SP2), e.g.:

```erlang
%% Scope environment reads the shared ontology; {project, Project} -> not_found.
```

Do not touch the `handle_call` pattern clauses themselves (lines ~478-555,
all matching `{..., {project, _}, ...}`) — `_` already matches a `Project`
map correctly; there is no behavioural reason to rename the bound variable
in a wildcard match, and doing so would be pure churn against a stub path.

- [ ] **Step 2: Give the test suite's dummy scope tuples a realistic shape**

In `apps/graphdb/test/graphdb_rules_SUITE.erl`, the stub-path tests
currently use placeholder second elements (`{project, 1}`, `{project,
p1}`). Replace with a synthetic-but-shaped `Project` map so the test reads
as "a project scope", not "an arbitrary term the stub ignores":

```erlang
-define(DUMMY_PROJECT, #{anchor => 1, nodes => nodes_1,
                          rels => relationships_1, counters => counters_1}).
```

Then replace each of the 6 occurrences (`{project, 1}` → `{project,
?DUMMY_PROJECT}`, `{project, p1}` → `{project, ?DUMMY_PROJECT}`) at the
lines found by `grep -n "{project," apps/graphdb/test/graphdb_rules_SUITE.erl`.

- [ ] **Step 3: Run to verify no regression**

Run: `./rebar3 ct --app=graphdb --suite=graphdb_rules_SUITE`
Expected: PASS, unchanged pass count (these are stub-path assertions; the
shape change does not alter any assertion's expected value).

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "SP2 T13: graphdb_rules scope-tag docs + test fixtures name Project, not a placeholder"
```

---

## Task 14: Test suite migration — `sess()` → `proj()`, delta assertions, `invalid_session` → `invalid_project`

**Files:**
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_mgr_SUITE.erl`
- Modify: `apps/graphdb/test/graphdb_query_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_project:register_project/1`, `open/1` (Task 2).

This task is what makes Tasks 3-12's suites actually compile and run (they
were written assuming `proj()` already existed). If you executed the tasks
in order and stubbed `proj()` locally per the notes in Tasks 10 and 12, this
task consolidates those stubs into one canonical helper per suite and
removes the duplicates.

- [ ] **Step 1: Replace each suite's `sess()` helper with `proj()`**

In all three files, the existing helper (shown here for
`graphdb_instance_SUITE.erl`; the other two are structurally identical):

```erlang
%%---------------------------------------------------------------------
%% proj() -> Project
%%
%% SP2 test helper: returns a project handle, memoised per test-case
%% process. Registers a project under Projects (nref 5) on first use and
%% opens it; subsequent calls in the same process reuse it.
%%---------------------------------------------------------------------
proj() ->
	case get(sp2_project) of
		undefined ->
			{ok, P} = graphdb_project:register_project("SP2 test project"),
			{ok, Project} = graphdb_project:open(P),
			put(sp2_project, Project),
			Project;
		Project ->
			Project
	end.
```

(`graphdb_query_SUITE.erl` uses space indentation — write this helper with
spaces there, matching that file's style, not tabs.)

Grep-replace every call site: `grep -rln "sess()" apps/graphdb/test/*.erl`
and change `sess()` → `proj()` at each. Do NOT touch
`graphdb_project_SUITE.erl` (it never had a `sess()` helper — Task 2 already
wrote its tests directly against `register_project/1`/`open/1`).

- [ ] **Step 2: `invalid_session` → `invalid_project`**

In `graphdb_instance_SUITE.erl`, at the 5 code sites found by
`grep -n "invalid_session" apps/graphdb/test/graphdb_instance_SUITE.erl`
(lines 572, 2471, 2478, 2483, 2488 as of this plan's writing — re-grep to
confirm before editing), change `{error, invalid_session}` →
`{error, invalid_project}`, and update the one comment at line 567
similarly.

- [ ] **Step 3: `graphdb_instance_SUITE` delta-assertion table moves**

Search for table-size delta assertions measuring `nodes`/`relationships`
directly:

```bash
grep -n "mnesia:table_info(nodes\|mnesia:table_info(relationships\|ets:info(nodes\|ets:info(relationships" apps/graphdb/test/graphdb_instance_SUITE.erl
```

For each match, the pre/post counts must read the ACTIVE test's project
tables (`graphdb_ns:node_table(proj())` / `graphdb_ns:rel_table(proj())`),
not the literal `nodes`/`relationships` atoms — those now only ever hold
environment data, so a project-instance-creation delta assertion against
them would always see zero change and silently stop testing anything.

Also apply the pre-warm fix SP1 needed for the same table-creation-inside-
measurement-window hazard (per the design's §10 and the SP1 precedent
recorded in `TASKS.md`): call `proj()` once in `init_per_testcase/2` (or at
the top of each affected test case, before the "before" measurement) so
`register_project/1`'s table-creation write doesn't land inside the
measured window.

- [ ] **Step 4: Nref-value assertion review**

```bash
grep -n "?assertEqual(1000000\|?assertEqual(100000[1-9]\|nref = 1000000" apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_mgr_SUITE.erl apps/graphdb/test/graphdb_query_SUITE.erl
```

Any test asserting an exact instance nref in the old runtime tier
(`>= 1000000`) now sees project nrefs starting at 1 instead. Update each to
assert the new small integer (typically `1`, `2`, `3`, ... for the first
few instances created by that test case's `proj()`), reasoning from the
test's own creation order rather than guessing.

- [ ] **Step 5: Run the full graphdb suite**

Run: `./rebar3 eunit --app=graphdb`
Run: `./rebar3 ct --app=graphdb` (or `make test-ct-parallel`)
Expected: full PASS, all 13 CT suites + EUnit, zero failures, zero
warnings. This is the first point in the plan where the entire `graphdb`
app is expected to be green end-to-end.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_mgr_SUITE.erl apps/graphdb/test/graphdb_query_SUITE.erl
git commit -m "SP2 T14: sess()->proj(), invalid_session->invalid_project, delta assertions and nref values moved to project tables"
```

---

## Task 15: Documentation — `graphdb/CLAUDE.md`, `docs/Architecture.md`, `TASKS.md`

**Files:**
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `docs/Architecture.md` (only if it currently describes the SP1
  single-store state in a way SP2 contradicts — read its current Mnesia
  schema / multi-database section before editing; per the top-level
  CLAUDE.md's own rule, only touch it for a schema/supervision/API-contract
  change, all three of which apply here)
- Modify: `TASKS.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: `apps/graphdb/CLAUDE.md`**

Update the "Reference & namespace model (SP1)" section (or rename it to
cover SP1+SP2 together) to reflect:
- `graphdb_ns:namespace_of/2`, `target_namespace/2` (arity-2, home-relative).
- `graphdb_project:register_project/1` now also creates the project's three
  physical tables; `open/1` replaces `open_session/1`; `require_project/1`
  replaces `require_session/1`.
- The project write path's first argument is `Project`, not `Session`
  (rename throughout the existing bullet list:
  `create_instance`/`add_relationship`/`remove_relationship`/
  `update_relationship`(`_both`)/`add_class_membership`).
  Add: instance reads (`get_instance`/`children`/`compositional_ancestors`/
  `resolve_value`) now also take `Project` — no longer namespace-agnostic.
- `graphdb_mgr`: `get_node/2`, `retire_node/2`, `unretire_node/2`,
  `update_node_avps/3`, `delete_node/2`, `mutate/2` — new Project-taking
  twins; the `/1` (and `/2` for `update_node_avps`) forms stay
  environment-only.
- `graphdb_query`: `new_session/1` binds a `Project`; reads resolve `Home`
  per nref.
- Update the "Cross-database nref resolution" paragraph to describe
  home-relative routing (mirroring the amended parent design's §3), not
  the old "target_kind AVP" single-field description.

- [ ] **Step 2: `docs/Architecture.md`**

If it documents the Mnesia schema as "one `nodes`/`relationships` pair,"
add the per-project table set (`nodes_<A>`/`relationships_<A>`/
`counters_<A>`) as a peer storage unit, matching this plan's File Structure
table. Keep it at architectural altitude — table naming convention and
ownership, not per-function signatures.

- [ ] **Step 3: `TASKS.md`**

In the `## Multi-project sessions` section:
- Move the "Physical project store (SP2)" bullet from "DESIGNED, not yet
  implemented" to "IMPLEMENTED", pointing at this plan's file and
  summarizing the shipped surface (mirror the style of the SP1 bullet
  immediately above it in the same file).
- Add a note recording the scope addition beyond the original spec: the
  `retire_node`/`unretire_node`/`update_node_avps`/`delete_node`
  Project-taking twins (Task 10), since these were not in the original
  design's API table and their absence would have been a live nref-collision
  hazard post-SP2.
- Update the "SP2+ — turning project scope on" intro paragraph, since SP2 is
  no longer future work.

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/CLAUDE.md docs/Architecture.md TASKS.md
git commit -m "SP2 T15: documentation reflects the shipped physical project store"
```

---

## Post-plan verification checklist (run once, after Task 15)

- [ ] `./rebar3 compile` — clean, zero warnings, whole umbrella.
- [ ] `./rebar3 eunit` — full pass, whole umbrella.
- [ ] `./rebar3 ct` (or `make test-ct-parallel`) — full pass, all suites.
- [ ] `grep -rn "open_session\|session_project\|require_session\|with_session\|invalid_session" apps/graphdb/src apps/graphdb/test` — zero matches (confirms the Session→Project rename is complete, not partial).
- [ ] `grep -rn "graphdb_ns:namespace_of(" apps/graphdb/src apps/graphdb/test | grep -v "/2)"` — zero matches (confirms no stray arity-1 call survived).
- [ ] Manually create two projects in a shell (`make shell` →
      `application:start(nref), application:start(database).` then
      `{ok, P1} = graphdb_project:register_project("A").`,
      `{ok, P2} = graphdb_project:register_project("B").`,
      `{ok, Proj1} = graphdb_project:open(P1).`,
      `{ok, Proj2} = graphdb_project:open(P2).`,
      `graphdb_instance:create_instance(Proj1, "X", SomeClass, RootOfProj1).`,
      `graphdb_instance:create_instance(Proj2, "Y", SomeClass, RootOfProj2).`)
      and confirm both land at nref 1 in their own tables
      (`mnesia:dirty_read(nodes_P1, 1)` vs `mnesia:dirty_read(nodes_P2, 1)`
      return different, correct nodes) — this is the design's stated goal
      (§2) made concrete.
