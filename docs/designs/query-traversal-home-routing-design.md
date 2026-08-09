<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Query Traversal — Home Routing for Arc-Discovered Nrefs — Design

## Goal

Close the SP2 defect in which `graphdb_query`'s bounded BFS silently returns
the wrong answer under a project-bound session. `#q_find_path{}` returns
`{ok, no_path}` for a path that exists, because mid-traversal it re-guesses
which store each frontier node lives in and crosses into the project's tables
by accident.

Filed in `TASKS.md` → *Multi-project sessions* and analysed at length in
[PR #53 comment 5212210271](https://github.com/davidwt-com/SeerStoneGraphDb/pull/53#issuecomment-5212210271).

## The defect

`resolve_home/2` (`graphdb_query.erl:357`) resolves a bare nref by trying the
session's bound project first and falling back to the environment. That is
correct and deliberate for **entry points** — `#q_get_node{}`, `#q_get_arcs{}`,
`#q_describe{}`, and `#q_find_path{}`'s two endpoints — where the query
language genuinely has no characterization context to route on.

`session_read_arcs/4` (`:416`) and `is_scaffold_node/2` (`:943`) apply that
same guess to **arc-discovered** nrefs, re-deciding Home for every node BFS
reaches.

Reproduced — two runtime-tier environment attributes whose only route runs
through bootstrap nref 6 (`Names`):

```
A1 = 1000003, A2 = 1000004        (neither is shadowed)
#q_find_path{from = A1, to = A2, max_depth = 4, arc_kinds = [taxonomy]}

environment session        => {ok, [A1 -23-> 6, 6 -24-> A2]}
project, 1 instance        => {ok, [A1 -23-> 6, 6 -24-> A2]}
project, 21 instances      => {ok, no_path}          <-- silently wrong
```

Step by step under the 21-instance project: BFS reaches `6` legitimately (the
environment arc `A1 -23-> 6` is read from the environment's `relationships`).
Expanding `6`, `session_read_arcs/4` calls `resolve_home/2`, which finds a
*project instance* also numbered 6 and returns the project handle. The walk
then reads `relationships_<Anchor>` for source 6, finds no `taxonomy` arcs
there, and the frontier empties.

Because project allocators start at 1, **any project with ≥6 instances shadows
nref 6** and ≥35 shadows the whole bootstrap scaffold. This is the steady state
of a real project, not a contrived setup. No error is raised; the only signal
is a collision warning in the log.

> **Correction to the fix direction recorded in the PR comment and in
> `TASKS.md`.** Both say arc-discovered nrefs should route via
> `graphdb_ns:target_namespace/2` on the arc's `target_kind`. That does not
> work. Bootstrap arc labels 21–30 carry **no `target_kind` AVP** —
> `bootstrap.terms:122-131` creates all ten with `[]`, and `graphdb_attr:init/1`
> retro-stamps only `attribute_type`. `graphdb_instance:check_target_kind/3`
> already has an explicit "no target_kind AVP — legacy; skip the check" arm for
> exactly this. Only runtime-created pairs
> (`graphdb_attr:create_relationship_attribute_pair/4`) carry it. Arcs 23/24 are
> the attribute-taxonomy labels — the decisive hops in the repro — so a
> `target_kind` lookup returns `not_found` precisely where routing matters most.
> This design routes on `#relationship.kind` instead. `TASKS.md` is corrected in
> the same commit as this document.

### A second failure the PR comment missed

Fixing the store lookup alone is not sufficient. BFS's traversal state is keyed
by bare nref:

- `Visited` is `#{integer() => true}` (`:913`, `:918`), so project-6 and
  environment-6 collapse into one entry and visiting either suppresses the
  other.
- The target test is `case T of To` (`:910`), comparing bare integers. With
  `to = 6` under a shadowing project, a walk that reaches *environment*-6
  reports `{found, Path}` for a path that claims to have reached the *project
  instance* — a fabricated result, arguably worse than the filed `no_path`.

Both are addressed here as Half B.

## Scope

**In scope — the shadowing defect only:**

- **Half A** — arc-discovered nrefs resolve Home deterministically from the arc
  they arrived on, never by guessing.
- **Half B** — BFS frontier, visited set, and target comparison become
  Home-qualified.

**Out of scope, filed as follow-ups:**

- **Membership traversal.** BFS at an environment-homed node reads only the
  environment relationship table, so an environment class still cannot reach
  its project instances across arc 30 (`?ARC_CLASS_TO_INST`), whose rows live
  in the *project's* table despite an environment source.
  `#q_instances_of{}` keeps its `session_read_arcs_home/5` special case.
- **`target_kind` backfill** onto arc labels 21–30, which would let
  `graphdb_instance:check_target_kind/3` drop its permissive legacy arm.
- **`#q_get_arcs{}` / `#q_describe{}`** keep entry-point guessing, by design.

## What does not change

`resolve_home/2`, `session_read_arcs/4`, and `session_read_node/2` are
**untouched**. They serve genuine entry points, and their intent-following
behaviour is documented, deliberate, and covered by
`resolve_home_prefers_project_and_logs_on_collision`. Item 4 of the PR comment
("keep `resolve_home/2`'s contract unchanged") is satisfied by not modifying
them at all.

Exactly one caller changes: `bfs_step/5:893` switches from
`session_read_arcs/4` to the existing `session_read_arcs_home/5` (`:443`),
passing a Home the traversal already knows. That function's 5-tuple cache key
`{arcs, Home, Nref, Dir, Kinds}` was built during the SP2 T14 follow-up
specifically so it cannot collide with `session_read_arcs/4`'s 4-tuple key; it
accepts this second caller unmodified.

## Half A — deterministic Home from the arc

New pure function in `graphdb_ns`, beside `namespace_of/2`:

```erlang
%% arc_target_namespace(Home, ArcKind, Characterization) -> environment | Home
%%
%% Home is the store the arc row was READ from.  Total over the four
%% #relationship.kind values; both fields are present on every row.
arc_target_namespace(_Home, taxonomy,      _C) -> environment;
arc_target_namespace( Home, composition,   _C) -> Home;
arc_target_namespace( Home, connection,    _C) -> Home;
arc_target_namespace(_Home, instantiation, ?ARC_INST_TO_CLASS) -> environment;
arc_target_namespace( Home, instantiation, ?ARC_CLASS_TO_INST) -> Home;
arc_target_namespace( Home, Kind, Char) ->
    logger:warning("graphdb_ns: unroutable arc kind ~p (char ~p) -- "
                   "defaulting to same store ~p", [Kind, Char, Home]),
    Home.
```

Justification per clause:

| `kind` | Target store | Why |
| --- | --- | --- |
| `taxonomy` | `environment` | Class and attribute refinement; projects hold only instances, so a taxonomy arc never targets a project node. |
| `composition` | `Home` | Home-relative: category and class composition are environment↔environment; instance composition is project↔project. |
| `connection` | `Home` | Connections are instance↔instance within one store. |
| `instantiation` + char 29 | `environment` | The instance→class direction; classes always live in the environment. |
| `instantiation` + char 30 | `Home` | The class→instance direction; the row lives in the project and targets a project instance. |

This is the arc-row analogue of a rule `graphdb_ns` already states for the
`parents` cache: `namespace_of(_Home, taxonomy_parent) -> environment` and
`namespace_of(Home, compositional_parent) -> Home`. The 29/30 pair — the
"explicit exception" the PR comment anticipated as a modelling problem — turns
out to be two pattern-match clauses, because the *direction* of the membership
pair is exactly what the characterization encodes.

`graphdb_ns` gains `graphdb_nrefs.hrl` for the two `?ARC_*` macros. It stays
pure: no module dependencies.

The catch-all clause exists because `graphdb_query` is a singleton gen_server.
A `function_clause` on one malformed `kind` value would kill the query server
for every session; degrading to same-store (today's behaviour for that row)
with a logged warning is the same trade review wave C made for
`label_chain/1`.

### `is_scaffold_node` needs no policy decision

Item 3 of the PR comment asked what scaffold-ness should mean under a
project-bound session. With Home resolved deterministically the question
dissolves: `is_scaffold_node/2` becomes `is_scaffold_node(Home, Nref)`, reading
`graphdb_ns:node_table(Home)`. A project-homed node reads from the project's
table, finds `kind = instance`, and yields `false` — the right answer, reached
structurally rather than by special case.

## Half B — Home-qualified traversal state

One normalized notion of "which store", used for visited keys, continuation
state, and the public result alike:

```erlang
-type home_id() :: environment | {project, integer()}.

home_id(environment)         -> environment;
home_id(#{anchor := Anchor}) -> {project, Anchor}.
```

`home_id/1` deliberately does **not** carry the full `Project` handle: that
handle holds physical table atoms (`nodes_<A>`, `relationships_<A>`,
`counters_<A>`) which have no business inside continuation state or query
results. `home_of_id/2` maps a `home_id()` back to a real Home for
`graphdb_ns:node_table/1` / `rel_table/1`.

Entry points resolve once; Home is then carried, never re-derived:

```erlang
dispatch(#q_find_path{from = From, to = To, max_depth = D, arc_kinds = Kinds},
         Session) ->
    FromId = home_id(resolve_home(Session, From)),   %% entry point: guess is right
    ToId   = home_id(resolve_home(Session, To)),
    bfs(maps:get(snapshot_at, Session), {ToId, To}, D, D, Kinds,
        #{{FromId, From} => true},        %% visited  :: #{{home_id(), nref()} => true}
        [{FromId, From, []}],             %% frontier :: [{home_id(), nref(), path()}]
        Session);
```

`expand_arcs/8` becomes `/10`, gaining the source's `home_id()` and full Home:

```erlang
TargetHome = graphdb_ns:arc_target_namespace(FromHome, K, C),
TargetId   = home_id(TargetHome),
Key        = {TargetId, T},
...
case Key of
    ToKey -> {Acc, V, {found, NewPath}, S};
    _ ->
        case maps:is_key(Key, V) orelse is_scaffold_node(TargetHome, T) of
```

`bfs_step/5` correspondingly resolves `Home = home_of_id(S, HomeId)` and calls
`session_read_arcs_home(S, Home, Nref, outgoing, Kinds)`.

Three defects die together: the arc table is the one the arc actually lives in;
`{project, A}`-6 and `environment`-6 are distinct visited entries; and reaching
project-6 when the target is environment-6 no longer reports a false `found`.

### Continuation record

`graphdb_query.hrl`'s `#cont_path{}` field types change:

```erlang
target   :: {home_id(), integer()},                  %% was integer()
visited  :: #{{home_id(), integer()} => true},       %% was #{integer() => true}
frontier :: [{home_id(), integer(), [map()]}]        %% was [{integer(), [map()]}]
```

The record is opaque to callers — only `resume/2` reads it — so this is an
internal shape change, not an API break.

## Result shape

An edge gains a `home` key **iff** the target's Home differs from the Home the
arc row was read from:

```erlang
Edge = case TargetId =:= FromId of
           true  -> Edge0;
           false -> Edge0#{home => TargetId}
       end,
```

The value is a `home_id()` — `environment` or `{project, Anchor}` — never the
raw handle.

Because each edge's `from` is the previous edge's `to`, a consumer reconstructs
the full Home sequence by carrying the last disclosed value forward: an absent
`home` key means "same store as the previous hop", and the first edge's store is
the one the caller named in `from`.

Under this scope the only crossing reachable is project→environment via arc 29
(a project instance's outgoing membership row targets an environment class), so
`environment` is the only value emitted today. The `{project, _}` form is
reserved for when membership traversal lands.

> This shape varies by content, which is harder to pattern-match than a key
> that is always present. The rule above is stated precisely so the variation
> stays predictable, and the alternative — emitting `home` on every edge —
> would have churned every existing `find_path` assertion for information that
> is constant on environment-only paths.

## Error handling

Two singleton-crash hazards, both handled the way review wave C handled
`label_chain/1` — degrade and log rather than `function_clause` inside a
gen_server that every session shares:

1. **`arc_target_namespace/3`** — logged catch-all returning `Home`
   (conservative same-store), shown above.
2. **`home_of_id/2`** — would `function_clause` on a continuation carrying
   `{project, A}` for a project the session is not bound to. Rather than crash
   mid-BFS, `resume/2` validates the continuation's Home ids against the
   session up front and returns `{error, session_project_mismatch}`.
   Unreachable today (a session's project cannot change, and `snapshot_at`
   already guards refresh), but the singleton is exactly where "unreachable"
   should not be load-bearing.

## Testing

Test-driven: every test written first and shown failing **for the right
reason** before the fix lands.

| ID | Test | Asserts |
| --- | --- | --- |
| T1 | The filed invariant | One environment-only taxonomy path returns **identically** under an environment session, a 1-instance project session, and a ≥6-instance project session. Today the third returns `{ok, no_path}`. |
| T2 | False `found` | `from` = environment attribute, `to` = 6, project has ≥6 instances. Pre-fix the bare-nref target test reports a bogus path; post-fix `{environment, 6}` ≠ `{{project, A}, 6}` and `no_path` is correct. |
| T3 | Visited collision | A hop through environment-6 is not suppressed by having already visited project-6. |
| T4 | `arc_target_namespace/3` | EUnit in `graphdb_ns_tests.erl`: all four `kind` values, both instantiation directions, and the logged catch-all. |
| T5 | Result shape | Environment-only path carries no `home` key on any edge; a project→environment crossing via arc 29 carries `home => environment` on exactly that edge. `home_id/1` unit-tested against a project handle for the `{project, Anchor}` form. |
| T6 | Continuation round-trip | A depth-bounded partial in a project-bound session, resumed via `resume/2`, matches an unbounded run — proving the new frontier/visited shapes survive `#cont_path{}`. |
| T7 | Non-regression | `resolve_home_prefers_project_and_logs_on_collision` and the whole existing `q6_find_path` group stay green **unmodified** — the executable proof that entry-point behaviour is untouched. |

T1–T3 and T5–T7 land in `graphdb_query_SUITE.erl` (space-indented — the
documented 0-tab exception; it must stay at 0 tabs). T4 lands in
`graphdb_ns_tests.erl`.

**Caveat carried forward:** T2 and T3 are reasoned-constructible but unbuilt at
design time. If either proves unreachable under this scope, the implementation
plan must say so explicitly rather than substitute a weaker test.

Verification gate: `./rebar3 compile` clean, `./rebar3 xref` clean,
`make test-ct-parallel` and `./rebar3 eunit` green, zero warnings.

## Delivery

Own branch off `develop`, own PR — deliberately not folded into PR #53, so a
change to BFS traversal semantics and a public result shape gets an isolated
diff and its own review rather than being lost inside a 23-file branch.
