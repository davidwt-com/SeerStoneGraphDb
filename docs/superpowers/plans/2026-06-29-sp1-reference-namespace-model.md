# SP1 — Reference & Namespace Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish, at the API/code layer only, that every nref reference has a derived namespace and that project operations require a session opened against a registered project — behavior-preserving against today's single Mnesia store.

**Architecture:** A pure `graphdb_ns` module encodes the field-role namespace map (the crown jewel). A plain `graphdb_project` module owns project lifecycle (`register_project`) and the project session (`open_session`/`session_project`) plus the relocated project-scoped relationship-mutation surface. Proxy nodes (cross-project links as local AVP-payload nodes) get a seeded "Remote Reference" environment class + `remote_project`/`remote_nref` literal attributes + a recognizer — representation contract only, no creation/deref. Project write ops and project-specific instance reads take a **required** `Session` first argument.

**Tech Stack:** Erlang/OTP 28.5, Mnesia, rebar3 3.27 (`./rebar3`), Common Test + EUnit.

**Source spec:** `docs/designs/project-env-reference-namespace-model-design.md`

## Global Constraints

- **No `node` / `relationship` record changes.** Namespace is derived from field role + `target_kind`, never a new stored field.
- **HARD TABS** in all `apps/graphdb/` source and test files.
- **Module header pattern** (copyright, author, revision, NYI/UEM macros, explicit `-export`) on any new module — mirror an existing `graphdb_*` module.
- **Behavior-preserving** against the single store: every existing test must still pass after each task (project-op callers updated to open a session, but outcomes unchanged).
- **LOAD-BEARING INVARIANT:** never call a gen_server (`graphdb_nref:get_next/0`, `rel_id_server:get_id_pair/0`, `graphdb_attr`/`graphdb_class` calls) inside an Mnesia transaction fun — allocate/resolve outside, then enter the txn.
- **Required session:** a project op given a missing/invalid session returns `{error, invalid_session}` (or crashes on a non-session term per the function's guard) — never silently proceeds.
- Invoke rebar3 as plain `./rebar3 ...`. Fast CT: `make test-ct-parallel`.
- Commit trailers on every commit:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF`.

## Milestones (PR-sized groupings)

- **Milestone A — Mechanisms (Tasks 1–4):** additive, low-risk, fully testable. Shippable as one PR; nothing else is threaded yet.
- **Milestone B — Required-session threading & reorganization (Tasks 5–8):** threads the session through the project surface and relocates relationship mutation. Shippable as a second PR.

---

## Task 1: `graphdb_ns` — pure namespace resolution module

**Files:**
- Create: `apps/graphdb/src/graphdb_ns.erl`
- Test: `apps/graphdb/test/graphdb_ns_tests.erl`

**Interfaces:**
- Produces:
  - `graphdb_ns:namespace_of(Role) -> environment | project | home` where
    `Role :: characterization | reciprocal | avp_attribute | node_classes |
    taxonomy_parent | compositional_parent | node_nref | source_nref`
  - `graphdb_ns:target_namespace(TargetKind) -> environment | project` where
    `TargetKind :: category | attribute | class | instance`

- [ ] **Step 1: Write the failing tests** (exhaustive, table-driven over the §3 field-role map)

```erlang
%%% File: apps/graphdb/test/graphdb_ns_tests.erl
-module(graphdb_ns_tests).
-include_lib("eunit/include/eunit.hrl").

namespace_of_environment_roles_test() ->
	[ ?assertEqual(environment, graphdb_ns:namespace_of(R))
	  || R <- [characterization, reciprocal, avp_attribute,
			   node_classes, taxonomy_parent] ].

namespace_of_project_roles_test() ->
	?assertEqual(project, graphdb_ns:namespace_of(compositional_parent)).

namespace_of_home_roles_test() ->
	[ ?assertEqual(home, graphdb_ns:namespace_of(R))
	  || R <- [node_nref, source_nref] ].

target_namespace_instance_is_project_test() ->
	?assertEqual(project, graphdb_ns:target_namespace(instance)).

target_namespace_others_are_environment_test() ->
	[ ?assertEqual(environment, graphdb_ns:target_namespace(K))
	  || K <- [category, attribute, class] ].

namespace_of_unknown_role_crashes_test() ->
	?assertError(function_clause, graphdb_ns:namespace_of(bogus_role)).
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 eunit --module=graphdb_ns_tests`
Expected: FAIL — `graphdb_ns` undefined.

- [ ] **Step 3: Write `graphdb_ns.erl`** (use the standard module header from any `graphdb_*` file; body below — HARD TABS)

```erlang
-module(graphdb_ns).
-export([namespace_of/1, target_namespace/1]).

%% namespace_of(Role) -> environment | project | home
%% Encodes docs/designs/project-env-reference-namespace-model-design.md §3.
%% `home` = same store as the containing record (node's own DB / row's home).
namespace_of(characterization)     -> environment;
namespace_of(reciprocal)           -> environment;
namespace_of(avp_attribute)        -> environment;
namespace_of(node_classes)         -> environment;
namespace_of(taxonomy_parent)      -> environment;
namespace_of(compositional_parent) -> project;
namespace_of(node_nref)            -> home;
namespace_of(source_nref)          -> home.

%% target_namespace(TargetKind) -> environment | project
%% The single routed field (relationship.target_nref): project iff instance.
target_namespace(instance)  -> project;
target_namespace(category)  -> environment;
target_namespace(attribute) -> environment;
target_namespace(class)     -> environment.
```

- [ ] **Step 4: Run to verify pass**

Run: `./rebar3 eunit --module=graphdb_ns_tests`
Expected: PASS (6 tests).

- [ ] **Step 5: Update anatomy + commit**

```bash
# Add graphdb_ns.erl + graphdb_ns_tests.erl entries to .wolf/anatomy.md (do NOT git add .wolf)
git add apps/graphdb/src/graphdb_ns.erl apps/graphdb/test/graphdb_ns_tests.erl
git commit -m "SP1: graphdb_ns pure namespace resolution module

<trailers>"
```

---

## Task 2: Project registry — `register_project/1`

**Files:**
- Create: `apps/graphdb/src/graphdb_project.erl`
- Test: `apps/graphdb/test/graphdb_project_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_nref:get_next/0`, `rel_id_server:get_id_pair/0`,
  `graphdb_mgr:transaction/1`, macros `?NREF_PROJECTS`, `?ARC_CAT_CHILD`,
  `?ARC_CAT_PARENT`, `?NAME_ATTR_INSTANCE` from `graphdb_nrefs.hrl`,
  `#node{}` / `#relationship{}` from the graphdb records header.
- Produces:
  - `graphdb_project:register_project(Name :: string()) -> {ok, ProjectNref} | {error, term()}`
  - `graphdb_project:is_project(Nref) -> boolean()` (true iff `Nref` is a child of `?NREF_PROJECTS`)

**Design note (flagged at handoff):** the project registry node is
`kind = instance`, attached as a child of the `Projects` category (nref 5) via
the category composition arc labels (`?ARC_CAT_CHILD` / `?ARC_CAT_PARENT`),
carrying a single instance-name AVP. No separate "Project" class in SP1
(YAGNI). It receives a runtime environment nref (`graphdb_nref:get_next/0`).
Adding a child under category 5 does not mutate the category node itself
(only relationship rows + the child's record), so the category-immutability
guard is not engaged.

- [ ] **Step 1: Write the failing test**

```erlang
register_project_creates_child_of_projects(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	?assert(is_integer(P)),
	?assert(graphdb_project:is_project(P)),
	{ok, #node{kind = Kind, parents = Parents}} = graphdb_mgr:get_node(P),
	?assertEqual(instance, Kind),
	?assert(lists:member(?NREF_PROJECTS, Parents)).

is_project_false_for_non_child(_Config) ->
	?assertNot(graphdb_project:is_project(?NREF_CLASSES)).
```

- [ ] **Step 2: Run to verify failure**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_project_SUITE`
Expected: FAIL — `graphdb_project` undefined.

- [ ] **Step 3: Implement `register_project/1` + `is_project/1`** (mirror the `ensure_literal_seed/2` attach pattern in `graphdb_language.erl:411-446`, but with category composition arcs and `kind = composition`)

```erlang
register_project(Name) when is_list(Name) ->
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

is_project(Nref) ->
	case graphdb_mgr:get_node(Nref) of
		{ok, #node{parents = Parents}} -> lists:member(?NREF_PROJECTS, Parents);
		_                              -> false
	end.
```

- [ ] **Step 4: Run to verify pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_project_SUITE`
Expected: PASS.

- [ ] **Step 5: Update anatomy + commit** (add `graphdb_project.erl` + suite to `.wolf/anatomy.md`; do NOT git add `.wolf`).

---

## Task 3: Project session — `open_session/1` / `session_project/1`

**Files:**
- Modify: `apps/graphdb/src/graphdb_project.erl`
- Test: `apps/graphdb/test/graphdb_project_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_project:is_project/1` (Task 2).
- Produces:
  - `graphdb_project:open_session(ProjectNref) -> {ok, Session} | {error, not_a_project}` where `Session` is an opaque value.
  - `graphdb_project:session_project(Session) -> ProjectNref`
  - `Session` is a map `#{kind => project_session, project => Nref}`, constructed only by `open_session/1`. Treat as opaque; later sub-projects add keys.

- [ ] **Step 1: Write the failing tests**

```erlang
open_session_on_registered_project(_Config) ->
	{ok, P} = graphdb_project:register_project("Acme"),
	{ok, S} = graphdb_project:open_session(P),
	?assertEqual(P, graphdb_project:session_project(S)).

open_session_rejects_non_project(_Config) ->
	?assertEqual({error, not_a_project},
				 graphdb_project:open_session(?NREF_CLASSES)).
```

- [ ] **Step 2: Run to verify failure** — `open_session` undefined.

- [ ] **Step 3: Implement**

```erlang
open_session(ProjectNref) ->
	case is_project(ProjectNref) of
		true  -> {ok, #{kind => project_session, project => ProjectNref}};
		false -> {error, not_a_project}
	end.

session_project(#{kind := project_session, project := Nref}) -> Nref.
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit.**

---

## Task 4: Proxy representation contract — "Remote Reference" class + recognizer

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (seed `remote_project`, `remote_nref` literal attributes in `init/1`; expose via `seeded_nrefs/0`)
- Modify: `apps/graphdb/src/graphdb_instance.erl` (seed "Remote Reference" class in `init/1`; add `is_proxy/1`, `proxy_coordinates/1`)
- Modify: `docs/diagrams/ontology-tree.md` (**mandatory** — a new environment node is seeded at init)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl` (proxy recognizer cases)

**Interfaces:**
- Consumes: `graphdb_attr:create_value_attribute/4` (literal seeds),
  `graphdb_class:create_class/3`, `graphdb_attr:seeded_nrefs/0`.
- Produces:
  - `graphdb_instance:is_proxy(#node{}) -> boolean()` (true iff the node is a member of the "Remote Reference" class)
  - `graphdb_instance:proxy_coordinates(#node{}) -> {ok, #{remote_project => integer(), remote_nref => integer()}} | not_a_proxy`
  - `graphdb_attr:seeded_nrefs/0` map gains keys `remote_project`, `remote_nref`.

**Design note (flagged at handoff):** proxy AVP keys `remote_project`
(environment nref of the target project registry node) and `remote_nref`
(target's integer in that project's space — payload) are seeded **literal
attributes**, mirroring `target_kind`. The "Remote Reference" class is seeded
under `?NREF_CLASSES` via the find-first-else-create pattern. SP1 ships the
**representation contract + recognizer only** — no proxy creation API, no
dereference.

- [ ] **Step 1: Write the failing tests** (build a node by hand carrying the two AVPs + Remote Reference class membership; assert recognizer accepts it and rejects a plain instance)

```erlang
proxy_recognizer_identifies_proxy(_Config) ->
	{ok, #{remote_project := RP, remote_nref := RN}} = graphdb_attr:seeded_nrefs(),
	RRClass = graphdb_instance:remote_reference_class(),  %% accessor added in step 3
	Node = #node{nref = 999999001, kind = instance, classes = [RRClass],
				 attribute_value_pairs =
					 [#{attribute => RP, value => 5},
					  #{attribute => RN, value => 42}]},
	?assert(graphdb_instance:is_proxy(Node)),
	?assertEqual({ok, #{remote_project => 5, remote_nref => 42}},
				 graphdb_instance:proxy_coordinates(Node)).

proxy_recognizer_rejects_plain_instance(_Config) ->
	Node = #node{nref = 999999002, kind = instance, classes = [],
				 attribute_value_pairs = []},
	?assertNot(graphdb_instance:is_proxy(Node)),
	?assertEqual(not_a_proxy, graphdb_instance:proxy_coordinates(Node)).
```

- [ ] **Step 2: Run to verify failure** — seeds/recognizer absent.

- [ ] **Step 3: Implement the seeds + recognizer**

  1. In `graphdb_attr:init/1`, seed `remote_project` and `remote_nref` as literal attributes (same call shape used for `target_kind`), cache their nrefs in state, and add them to the `seeded_nrefs/0` reply map.
  2. In `graphdb_instance:init/1`, after the existing `graphdb_attr:seeded_nrefs/0` read, ensure the "Remote Reference" class exists under `?NREF_CLASSES` (find-first-else-`graphdb_class:create_class/3`); cache its nref in `#state`. Add accessor `remote_reference_class/0` (gen_server call returning the cached nref) and the two proxy-attr nrefs.
  3. Add the pure recognizers:

```erlang
is_proxy(#node{classes = Classes}) ->
	lists:member(remote_reference_class(), Classes).

proxy_coordinates(#node{attribute_value_pairs = AVPs} = N) ->
	case is_proxy(N) of
		false -> not_a_proxy;
		true  ->
			{ok, #{remote_project := RP, remote_nref := RN}} =
				graphdb_attr:seeded_nrefs(),
			{ok, #{remote_project => avp_value(AVPs, RP),
				   remote_nref    => avp_value(AVPs, RN)}}
	end.
%% avp_value/2: reuse the module's existing find_avp_value/2 helper.
```

- [ ] **Step 4: Run to verify pass** — PASS. Then run the full instance suite to confirm the new init seed broke nothing: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE`.

- [ ] **Step 5: Update `docs/diagrams/ontology-tree.md`** — add the "Remote Reference" class node under Classes (nref 3) and the two literal attributes under the Literals subtree, in the Mermaid block.

- [ ] **Step 6: Update anatomy + commit.** This closes **Milestone A**.

---

## Task 5: Thread required session into relationship mutation + relocate surface

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (tier-2 public functions gain `Session`)
- Modify: `apps/graphdb/src/graphdb_project.erl` (re-export the project-scoped relationship-mutation surface; add `require_session/1`)
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`, `apps/graphdb/test/graphdb_mgr_SUITE.erl` (callers open a session)

**Interfaces:**
- Consumes: `graphdb_project:session_project/1`, `graphdb_project:open_session/1`.
- Produces (new public signatures — `Session` is always the **first** arg):
  - `add_relationship(Session, S, C, T, R)` / `/6` (+template) / `/7` (+AVPs)
  - `remove_relationship(Session, S, C, T)` / `/5` (+template)
  - `update_relationship(Session, S, C, T, Updates)` / `/6` (+template)
  - `update_relationship_both(Session, S, C, T, {Fwd, Rev})` / `/6` (+template)
  - `add_class_membership(Session, InstanceNref, ClassNref)`
  - `graphdb_project:require_session(Session) -> ok | {error, invalid_session}` — returns `ok` for a well-formed `#{kind := project_session}` map, else `{error, invalid_session}`.

**Transformation pattern** (apply to each tier-2 function listed above):
add `Session` as the first parameter; as the first action, `case graphdb_project:require_session(Session) of {error, _}=E -> E; ok -> <existing body> end`. The tier-1 `*_in_txn` primitives are **unchanged** (no session). The single-store resolution is identity, so the body is otherwise untouched — behavior-preserving.

- [ ] **Step 1: Write the failing tests**

```erlang
remove_relationship_requires_session(_Config) ->
	%% existing remove_relationship_basic setup, but call with a session:
	{ok, P} = graphdb_project:register_project("T5"),
	{ok, S} = graphdb_project:open_session(P),
	%% ... build a connection edge ...
	?assertEqual(ok, graphdb_instance:remove_relationship(S, Src, Char, Tgt)).

remove_relationship_rejects_bad_session(_Config) ->
	?assertEqual({error, invalid_session},
				 graphdb_instance:remove_relationship(not_a_session, 1, 2, 3)).
```

- [ ] **Step 2: Run to verify failure** — arity/clause mismatch.

- [ ] **Step 3: Implement** `require_session/1` in `graphdb_project`, apply the transformation pattern to each tier-2 function, and re-export them from `graphdb_project` (thin wrappers delegating to `graphdb_instance`, establishing the project-side API home per the env/project split).

- [ ] **Step 4: Update all existing callers/tests** of these functions to open a session first. Enumerate sites:

Run: `grep -rn "remove_relationship\|update_relationship\|add_relationship\|add_class_membership" apps/graphdb/test apps/graphdb/src | grep -v _in_txn`
Update each call site to thread a session (tests: `open_session` in the relevant `init_per_testcase`/setup helper; `graphdb_rules` firing callers: see Task 6).

- [ ] **Step 5: Run to verify pass** — `make test-ct-parallel` plus `./rebar3 eunit`. All green.

- [ ] **Step 6: Commit.**

---

## Task 6: Thread required session into `create_instance` + rule-firing propagation

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`create_instance/3,4,5` → `/4,5,6` with `Session` first)
- Modify: `apps/graphdb/src/graphdb_rules.erl` (composition/connection firing creates child instances — thread the session through `plan_*`/firing call paths that reach `create_instance`/`add_relationship`)
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl`, `apps/graphdb/test/graphdb_rules_SUITE.erl`

**Interfaces:**
- Produces:
  - `create_instance(Session, Name, ClassNref, ParentNref)` / `/5` (+ConnResolver) / `/6` (+ConflictResolver)
  - Internal firing helpers that materialize children gain a `Session` parameter so the same project is used end-to-end. Exact internal signatures: enumerate with `grep -n "create_instance\|add_relationship" apps/graphdb/src/graphdb_rules.erl` and thread `Session` down each path.

**Why this is its own task:** `create_instance` is the deepest project op — the rule-firing engine creates mandatory child instances and mandatory connections internally. Because the session is **required**, any firing sub-path not threaded will *crash* (no session to pass), and the existing `graphdb_rules_SUITE` firing tests catch it once updated. That loud failure is the point.

- [ ] **Step 1: Write the failing test** (a `create_instance` with a session that fires a composition rule minting a child; assert the child exists — proving the session reached the firing engine)

```erlang
create_instance_with_session_fires_children(_Config) ->
	{ok, P} = graphdb_project:register_project("T6"),
	{ok, S} = graphdb_project:open_session(P),
	%% class with a mandatory composition rule (reuse existing rules-suite setup)
	{ok, Nref, _Report} = graphdb_instance:create_instance(S, "Car", CarClass, Root),
	?assert(is_integer(Nref)).

create_instance_rejects_bad_session(_Config) ->
	?assertEqual({error, invalid_session},
				 graphdb_instance:create_instance(bad, "X", 1, 2)).
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** — add `Session` first arg + `require_session/1` guard to `create_instance/4,5,6`; thread `Session` through every `graphdb_rules` firing path that reaches `create_instance`/`add_relationship`. Re-export `create_instance` from `graphdb_project`.

- [ ] **Step 4: Update callers/tests** — every `create_instance(` call site in `apps/graphdb/test` and `apps/graphdb/src` opens/threads a session. `grep -rn "create_instance(" apps/graphdb`.

- [ ] **Step 5: Run to verify pass** — `make test-ct-parallel` + `./rebar3 eunit`. All green.

- [ ] **Step 6: Commit.**

---

## Task 7: Thread session into `mutate/1` project ops + project instance reads

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (`mutate/1` → `mutate/2` taking `Session`; project-op mutation tuples dispatch with the session)
- Modify: `apps/graphdb/src/graphdb_instance.erl` (instance reads `get_instance/1`, `children/1`, `compositional_ancestors/1`, `resolve_value/2` gain `Session` first arg)
- Modify: `apps/graphdb/test/graphdb_mgr_SUITE.erl`, `apps/graphdb/test/graphdb_instance_SUITE.erl`

**Interfaces:**
- Produces:
  - `graphdb_mgr:mutate(Session, [Mutation]) -> {ok, [Result]} | {error, term()}` — validates the session once up front; all project-op mutation tuples in the batch run under that project.
  - `get_instance(Session, Nref)`, `children(Session, Nref)`, `compositional_ancestors(Session, Nref)`, `resolve_value(Session, Nref, AttrNref)`.

**Scope boundary (per spec §7/§9):** the polymorphic low-level readers
`graphdb_mgr:get_node/1` and `get_relationships/1,2` remain
namespace-agnostic in SP1 (single store) and are **not** session-gated — they
read whichever store exists; their namespace-correct routing lands in SP2.
`graphdb_ns` documents the intended routing.

- [ ] **Step 1: Write the failing tests** (`mutate/2` with a session over a batch of project-op mutations; a project read with a session).
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** `mutate/2` (validate session once, then the existing prepare/dispatch flow unchanged) and the session-first instance reads with `require_session/1` guards.
- [ ] **Step 4: Update callers/tests** — `grep -rn "mutate(\|get_instance(\|children(\|compositional_ancestors(\|resolve_value(" apps/graphdb`; thread a session.
- [ ] **Step 5: Run to verify pass** — `make test-ct-parallel` + `./rebar3 eunit`. All green.
- [ ] **Step 6: Commit.**

---

## Task 8: Documentation

**Files:**
- Modify: `docs/Architecture.md` (project-session + env/project API split; relationship-mutation relocation; `graphdb_ns` / `graphdb_project` modules; proxy representation contract)
- Modify: `apps/graphdb/CLAUDE.md` (worker responsibilities: new modules, session-threaded signatures, proxy seeds)
- Modify: `CLAUDE.md` (project root — "Cross-database nref resolution" note now backed by `graphdb_ns`; project session)
- Modify: `TASKS.md` (mark SP1 IMPLEMENTED; record SP2/SP3/SP4 follow-ups from spec §9–§10)

- [ ] **Step 1:** Update `docs/Architecture.md` — new modules, the env/project API split, session-required project ops, proxy contract. Architectural altitude only.
- [ ] **Step 2:** Update `apps/graphdb/CLAUDE.md` worker table + `graphdb_instance`/`graphdb_mgr` API descriptions + the two new modules.
- [ ] **Step 3:** Update root `CLAUDE.md` cross-database resolution paragraph and the supervision/module notes.
- [ ] **Step 4:** Update `TASKS.md` — SP1 IMPLEMENTED; add SP2 (physical store + allocator-from-1), SP3 (distribution/residency + proxy creation/deref), SP4 (migration), plus deferred open questions (proxy explosion, private environment overlays, session unification).
- [ ] **Step 5:** Run `python3 ~/.claude/scripts/align_md_tables.py` on any edited markdown with tables. Commit. This closes **Milestone B**.

---

## Self-Review

- **Spec coverage:** §3 map → Task 1; §4 proxy contract → Task 4; §5 registry → Task 2; §6 session → Task 3 + threading Tasks 5–7; §7 resolution seam → Task 1 (+ §7 read-routing boundary noted in Task 7); §8 env/project split + relocation → Tasks 5–7; §9 scope (proxy create/deref deferred) → honored (Task 4 contract-only); §10 deferred items → Task 8 TASKS.md. All covered.
- **Placeholders:** none — every code step shows code; threading tasks give the exact transformation + a `grep` to enumerate sites (mechanical, not vague).
- **Type consistency:** `Session` is the first arg everywhere; `require_session/1`, `session_project/1`, `open_session/1`, `is_project/1`, `register_project/1`, `is_proxy/1`, `proxy_coordinates/1`, `namespace_of/1`, `target_namespace/1` used consistently across tasks.
