<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Node Soft-Retire (retire_node / unretire_node) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement reversible soft-retire for runtime graph nodes —
`graphdb_mgr:retire_node/1` + `unretire_node/1` — backed by a boolean
`retired` marker AVP, a hidden direct lookup, and block-new-participation
guards.

**Architecture:** A new seeded boolean literal-attribute `retired` (owned
by `graphdb_attr`, mirroring L9 `instantiable`) is stamped as an AVP on a
node's row to retire it. `graphdb_mgr` gains `retire_node/1` /
`unretire_node/1` (tier-2 wrappers over a tier-1 `set_retired_/3` primitive
run through the existing `graphdb_mgr:transaction/1` seam) and filters
retired nodes out of the public `get_node/1`. `graphdb_instance` refuses a
retired node as a new instance target, parent, or arc endpoint. Nothing is
removed from Mnesia, so no arc or cache is ever orphaned.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (`./rebar3`), Mnesia, Common
Test, EUnit.

**Spec:** `docs/designs/delete-node-soft-retire-design.md`

## Global Constraints

- Build/test with the repo-local `./rebar3` (kerl PATH is preset — no
  `source ~/.bashrc`). Compile must stay **zero-warning**.
- New source/test files start with the project header (copyright block,
  author/created/description, revision history, module attributes,
  NYI/UEM macros where applicable). Match surrounding files.
- Indentation is **tabs**, matching every existing `apps/graphdb` file.
- Explicit `-export([...])` lists only — never `-compile(export_all)`.
- The marker is a **boolean**: `#{attribute => RetiredNref, value => true}`
  means retired; absence means active. Setting active **removes** the AVP
  (no dead `value => false` entries).
- `delete_node/1`, `check_category_guard/1`, and the
  `category_nodes_are_immutable` atom are **left untouched**. Their three
  existing `graphdb_mgr_SUITE` cases must stay green unchanged.
- Permanent-tier guard atom is exactly `permanent_node_immutable`;
  retired-lookup atom is exactly `retired`; participation atoms are exactly
  `{class_retired, ClassNref}`, `{parent_retired, ParentNref}`,
  `{endpoint_retired, Nref}`.
- `?NREF_START`, `?NREF_ENGLISH`, arc-label macros come from
  `apps/graphdb/include/graphdb_nrefs.hrl` (already included by every
  target module).
- `graphdb_mgr` starts **before** `graphdb_attr` (graphdb_sup children 3
  vs 4), so `graphdb_mgr` must fetch the seeded `retired` nref **lazily**
  (on first use), not at `init/1`. `graphdb_instance` starts **after**
  `graphdb_attr`, so it fetches at `init/1` (as it already does for
  `instantiable`).

---

## Task 1: Seed the `retired` marker in graphdb_attr

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (state record ~line 103;
  `init/1` ~line 342; `seeded_nrefs` handle_call ~line 412)
- Test: `apps/graphdb/test/graphdb_attr_SUITE.erl`

**Interfaces:**
- Produces: `graphdb_attr:seeded_nrefs/0` returns a map that now includes
  `retired => integer()` (the nref of the seeded `retired`
  literal-attribute, under the Attribute Literals sub-group, in the
  permanent tier `(?NREF_ENGLISH, ?NREF_START)`).

- [ ] **Step 1: Write the failing test**

Add to `apps/graphdb/test/graphdb_attr_SUITE.erl`: export
`seeds_retired_marker/1`, add it to the same `all/0` group that lists
`seeds_instantiable_marker`, and add this case (mirrors
`seeds_instantiable_marker`):

```erlang
seeds_retired_marker(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{retired := RetNref,
		   attribute_literals_group := AttrLitNref,
		   attribute_type := AtNref}} =
		graphdb_attr:seeded_nrefs(),
	?assert(is_integer(RetNref)),
	?assert(RetNref > ?NREF_ENGLISH andalso RetNref < ?NREF_START),
	{ok, Node} = graphdb_attr:get_attribute(RetNref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual([AttrLitNref], Node#node.parents),
	?assert(lists:member(#{attribute => ?NAME_ATTR_ATTRIBUTE,
		value => "retired"}, Node#node.attribute_value_pairs)),
	?assert(lists:member(#{attribute => AtNref, value => literal},
		Node#node.attribute_value_pairs)).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE --case seeds_retired_marker`
Expected: FAIL — `seeded_nrefs/0` map has no `retired` key (badmatch on the
map pattern).

- [ ] **Step 3: Implement the seed**

In `apps/graphdb/src/graphdb_attr.erl`:

1. Add a field to the `-record(state, {...})` (after `instantiable_nref`):

```erlang
	instantiable_nref,				%% integer() -- seeded marker literal attribute
	retired_nref					%% integer() -- seeded `retired` lifecycle marker
```

2. In `init/1`, add the seed inside the `#state{...}` construction (after
   the `instantiable_nref` line):

```erlang
			instantiable_nref     = ensure_seed("instantiable", AttrLitNref),
			retired_nref          = ensure_seed("retired", AttrLitNref)
```

3. Extend the `init/1` `logger:info` format string and args to include
   `retired=~p` / `State#state.retired_nref` (keep the existing entries).

4. In the `seeded_nrefs` handle_call, add the `retired` entry to the map:

```erlang
		instantiable     => State#state.instantiable_nref,
		retired          => State#state.retired_nref
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: PASS (all cases, including `seeds_retired_marker`).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "feat(graphdb_attr): seed retired lifecycle marker literal-attribute"
```

---

## Task 2: retire_node / unretire_node + tier-1 primitive (graphdb_mgr)

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (exports ~line 103; state
  record line 94; public API near `delete_node/1` ~line 240; handle_calls
  ~line 380)
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_attr:seeded_nrefs/0` (Task 1, `retired` key);
  `graphdb_mgr:transaction/1` (existing seam: `fun(() -> R) -> {ok, R} |
  {error, term()}`).
- Produces:
  - `graphdb_mgr:retire_node(Nref) -> ok | {error, permanent_node_immutable
    | not_found}`
  - `graphdb_mgr:unretire_node(Nref) -> ok | {error,
    permanent_node_immutable | not_found}`
  - both idempotent; both refuse `Nref < ?NREF_START`.

- [ ] **Step 1: Write the failing tests**

In `apps/graphdb/test/graphdb_mgr_SUITE.erl`: export and register (in
`all/0`) four cases, and add them to the **full-stack** `init_per_testcase`
clause (the `when TC =:= ...` list that starts `graphdb_attr` /
`graphdb_class` / `graphdb_instance`) so the lazy `seeded_nrefs/0` fetch and
`create_class/2` work:

```erlang
retire_node_sets_and_clears_marker(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("RetireMe", 3),
	?assert(ClassNref >= ?NREF_START),
	ok = graphdb_mgr:retire_node(ClassNref),
	[#node{attribute_value_pairs = AVPs1}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs1)),
	ok = graphdb_mgr:unretire_node(ClassNref),
	[#node{attribute_value_pairs = AVPs2}] =
		mnesia:dirty_read(nodes, ClassNref),
	?assertEqual(false,
		lists:any(fun(#{value := true}) -> true; (_) -> false end, AVPs2)).

retire_node_is_idempotent(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("RetireIdem", 3),
	ok = graphdb_mgr:retire_node(ClassNref),
	ok = graphdb_mgr:retire_node(ClassNref),
	ok = graphdb_mgr:unretire_node(ClassNref),
	ok = graphdb_mgr:unretire_node(ClassNref).

retire_node_refuses_permanent_tier(_Config) ->
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:retire_node(1)),
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:retire_node(27)),
	?assertEqual({error, permanent_node_immutable},
		graphdb_mgr:unretire_node(27)).

retire_node_not_found(_Config) ->
	BadNref = ?NREF_START + 999999,
	?assertEqual({error, not_found}, graphdb_mgr:retire_node(BadNref)),
	?assertEqual({error, not_found}, graphdb_mgr:unretire_node(BadNref)).
```

Note the suite already defines a local `-record(node, ...)` (top of file)
and includes `graphdb_nrefs.hrl`, so `#node{}`, `?NREF_START` and
`mnesia:dirty_read/2` are available.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --case retire_node_sets_and_clears_marker`
Expected: FAIL — `graphdb_mgr:retire_node/1` is undefined.

- [ ] **Step 3: Implement retire_node / unretire_node**

In `apps/graphdb/src/graphdb_mgr.erl`:

1. Add to the external API `-export([...])` (next to `delete_node/1`):

```erlang
		delete_node/1,
		retire_node/1,
		unretire_node/1,
```

2. Add a field to the (currently empty) state record:

```erlang
-record(state, {
	retired_nref			%% integer() | undefined -- seeded `retired`
							%% marker nref; lazily fetched from graphdb_attr
							%% on first use (graphdb_attr starts after mgr)
}).
```

3. Add the public functions near `delete_node/1`:

```erlang
%% retire_node(Nref) -> ok | {error, Reason}
%% Soft-retires a runtime node (sets the boolean `retired` marker AVP).
%% Idempotent. Refuses the permanent tier (Nref < ?NREF_START).
retire_node(Nref) ->
	gen_server:call(?MODULE, {retire_node, Nref}).

%% unretire_node(Nref) -> ok | {error, Reason}
%% Clears the `retired` marker. Idempotent.
unretire_node(Nref) ->
	gen_server:call(?MODULE, {unretire_node, Nref}).
```

4. Add the handle_calls (next to the existing `{delete_node, Nref}`
   clause):

```erlang
handle_call({retire_node, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Nref, true, State0),
	{reply, Reply, State};
handle_call({unretire_node, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Nref, false, State0),
	{reply, Reply, State};
```

5. Add the wrapper + lazy-cache + tier-1 primitive helpers (place them
   near `do_get_node/1` / `check_category_guard/1`):

```erlang
%%-----------------------------------------------------------------------------
%% set_retired(Nref, Bool, State) -> {ok | {error, Reason}, State'}
%%
%% Tier-2 wrapper. Static arithmetic guard refuses the whole permanent tier
%% (Nref < ?NREF_START); otherwise lazily resolves the seeded `retired`
%% nref (caching it in State) and runs the tier-1 primitive through the
%% transaction seam. Returns the possibly-updated State so the cache sticks.
%%-----------------------------------------------------------------------------
set_retired(Nref, _Bool, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
set_retired(Nref, Bool, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> set_retired_(Nref, Bool, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.

%%-----------------------------------------------------------------------------
%% ensure_retired_nref(State) -> {RetAttr, State'}
%%
%% Lazily fetches the seeded `retired` nref from graphdb_attr the first
%% time it is needed and caches it in State. graphdb_attr is started after
%% graphdb_mgr, so this cannot be done at init/1.
%%-----------------------------------------------------------------------------
ensure_retired_nref(#state{retired_nref = undefined} = State) ->
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	{RetAttr, State#state{retired_nref = RetAttr}};
ensure_retired_nref(#state{retired_nref = RetAttr} = State) ->
	{RetAttr, State}.

%%-----------------------------------------------------------------------------
%% set_retired_(Nref, Bool, RetAttr) -> ok
%% Tier-1 primitive. Must run inside an active mnesia transaction. Reads the
%% node under a write lock, rewrites its AVP list so the `retired` marker
%% reflects Bool, writes it back. Aborts with not_found if absent.
%%-----------------------------------------------------------------------------
set_retired_(Nref, Bool, RetAttr) ->
	case mnesia:read(nodes, Nref, write) of
		[]     -> mnesia:abort(not_found);
		[Node] ->
			AVPs0 = Node#node.attribute_value_pairs,
			AVPs1 = set_marker(AVPs0, RetAttr, Bool),
			mnesia:write(nodes,
				Node#node{attribute_value_pairs = AVPs1}, write)
	end.

%%-----------------------------------------------------------------------------
%% set_marker(AVPs, RetAttr, Bool) -> AVPs'
%% Removes any existing `retired` AVP; if Bool is true, appends a fresh
%% #{attribute => RetAttr, value => true}. Setting false leaves it removed.
%%-----------------------------------------------------------------------------
set_marker(AVPs, RetAttr, Bool) ->
	Stripped = [P || P <- AVPs, not is_retired_avp(P, RetAttr)],
	case Bool of
		true  -> Stripped ++ [#{attribute => RetAttr, value => true}];
		false -> Stripped
	end.

is_retired_avp(#{attribute := A}, RetAttr) -> A =:= RetAttr;
is_retired_avp(_, _)                       -> false.
```

Note `mnesia:read/3` (write lock) and `mnesia:abort/1` may already be
present elsewhere in the file; if `?NREF_START` is not yet referenced in
`graphdb_mgr.erl`, it resolves from the already-included
`graphdb_nrefs.hrl`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS — the four new cases plus all existing cases (the three
`category_guard_*` delete cases unchanged).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "feat(graphdb_mgr): add retire_node/unretire_node soft-retire"
```

---

## Task 3: Hide retired nodes from the public get_node/1

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (`get_node` handle_call ~line
  352; `do_get_node/1` ~line 442)
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

**Interfaces:**
- Consumes: the lazy `ensure_retired_nref/1` cache and `is_retired_avp/2`
  helper from Task 2.
- Produces: public `graphdb_mgr:get_node(Nref)` returns `{error, retired}`
  for a retired node; internal `do_get_node/1` stays raw (returns the row).

- [ ] **Step 1: Write the failing test**

Add to `apps/graphdb/test/graphdb_mgr_SUITE.erl` (export + register in
`all/0` + add to the full-stack `init_per_testcase` clause):

```erlang
get_node_hides_retired(_Config) ->
	{ok, ClassNref} = graphdb_mgr:create_class("HideMe", 3),
	{ok, _} = graphdb_mgr:get_node(ClassNref),
	ok = graphdb_mgr:retire_node(ClassNref),
	?assertEqual({error, retired}, graphdb_mgr:get_node(ClassNref)),
	ok = graphdb_mgr:unretire_node(ClassNref),
	{ok, #node{nref = ClassNref}} = graphdb_mgr:get_node(ClassNref).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --case get_node_hides_retired`
Expected: FAIL — `get_node/1` still returns `{ok, Node}` for the retired
node (the `{error, retired}` assertion fails).

- [ ] **Step 3: Implement the filter**

Replace the `get_node` handle_call so it threads the lazy cache and filters
retired nodes (leave `do_get_node/1` unchanged — it must stay raw):

```erlang
handle_call({get_node, Nref}, _From, State0) ->
	case do_get_node(Nref) of
		{ok, Node} ->
			{RetAttr, State} = ensure_retired_nref(State0),
			Reply = case is_retired_avp_present(Node, RetAttr) of
				true  -> {error, retired};
				false -> {ok, Node}
			end,
			{reply, Reply, State};
		{error, _} = Err ->
			{reply, Err, State0}
	end;
```

Add the small predicate near `is_retired_avp/2`:

```erlang
is_retired_avp_present(#node{attribute_value_pairs = AVPs}, RetAttr) ->
	lists:any(fun(#{attribute := A, value := true}) when A =:= RetAttr -> true;
				 (_) -> false
			  end, AVPs).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS — `get_node_hides_retired` plus all existing cases.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "feat(graphdb_mgr): hide retired nodes from public get_node/1"
```

---

## Task 4: Block-new-participation guards (graphdb_instance)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (state record;
  `init/1` ~line 372; create_instance handle_call ~line 391;
  add_class_membership handle_call ~line 405; `do_create_instance/4`;
  `do_validate_class/2` ~line 1112; `do_validate_parent/1` ~line 1143;
  `do_add_class_membership/3`; `validate_arc_endpoints/5`; `do_add_relationship/7`)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_attr:seeded_nrefs/0` `retired` key (Task 1);
  `graphdb_mgr:retire_node/1` (Task 2).
- Produces: `create_instance` / `add_class_membership` reject a retired
  target class with `{error, {class_retired, ClassNref}}`; `create_instance`
  rejects a retired parent with `{error, {parent_retired, ParentNref}}`;
  `add_relationship` rejects any retired endpoint with `{error,
  {endpoint_retired, Nref}}`.

- [ ] **Step 1: Write the failing tests**

In `apps/graphdb/test/graphdb_instance_SUITE.erl` (export + register in
`all/0`; the suite already starts the full worker stack):

```erlang
create_instance_refuses_retired_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("RetClass", 3),
	ok = graphdb_mgr:retire_node(ClassNref),
	?assertEqual({error, {class_retired, ClassNref}},
		graphdb_instance:create_instance("i", ClassNref, 3)).

add_class_membership_refuses_retired_class(_Config) ->
	{ok, ClassA} = graphdb_class:create_class("MemA", 3),
	{ok, ClassB} = graphdb_class:create_class("MemB", 3),
	{ok, Inst, _} = graphdb_instance:create_instance("m", ClassA, 3),
	ok = graphdb_mgr:retire_node(ClassB),
	?assertEqual({error, {class_retired, ClassB}},
		graphdb_instance:add_class_membership(Inst, ClassB)).

create_instance_refuses_retired_parent(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("PClass", 3),
	{ok, Parent, _} = graphdb_instance:create_instance("p", ClassNref, 3),
	ok = graphdb_mgr:retire_node(Parent),
	?assertEqual({error, {parent_retired, Parent}},
		graphdb_instance:create_instance("child", ClassNref, Parent)).

add_relationship_refuses_retired_endpoint(_Config) ->
	%% Build a valid arc, then retire the target and re-attempt.
	{ok, ClassNref} = graphdb_class:create_class("ArcClass", 3),
	{ok, Src, _}  = graphdb_instance:create_instance("s", ClassNref, 3),
	{ok, Tgt, _}  = graphdb_instance:create_instance("t", ClassNref, 3),
	{ok, Fwd} = graphdb_attr:create_relationship_attribute_pair(
		"Likes", "LikedBy", instance),
	{ok, Rec} = graphdb_attr:get_reciprocal(Fwd),
	ok = graphdb_instance:add_relationship(Src, Fwd, Tgt, Rec),
	ok = graphdb_mgr:retire_node(Tgt),
	{ok, Tgt2, _} = graphdb_instance:create_instance("t2", ClassNref, 3),
	ok = graphdb_mgr:retire_node(Tgt2),
	?assertEqual({error, {endpoint_retired, Tgt2}},
		graphdb_instance:add_relationship(Src, Fwd, Tgt2, Rec)).
```

If the helper names `graphdb_attr:create_relationship_attribute_pair/3`,
`graphdb_attr:get_reciprocal/1`, or `graphdb_instance:add_relationship/4`
differ in this suite's existing tests, mirror whatever the suite's existing
`add_relationship` cases use to construct a valid arc — the assertion of
interest is only the final `{error, {endpoint_retired, Tgt2}}`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case create_instance_refuses_retired_class`
Expected: FAIL — `create_instance` currently succeeds against a retired
class (returns `{ok, _, _}`), so the `{error, {class_retired, _}}`
assertion fails.

- [ ] **Step 3: Implement the guards**

In `apps/graphdb/src/graphdb_instance.erl`:

1. Add `retired_nref` to the state record (after `instantiable_nref`):

```erlang
	instantiable_nref,		%% integer() -- seeded `instantiable` marker
	retired_nref			%% integer() -- seeded `retired` marker
```

2. In `init/1`, fetch `retired` alongside the existing keys:

```erlang
	{ok, #{target_kind := TkAttr, instantiable := InstAttr,
		   retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	{ok, #state{target_kind_avp_nref = TkAttr,
				instantiable_nref = InstAttr,
				retired_nref = RetAttr}}.
```

3. In the `create_instance` handle_call, add `ret_attr` to the Ctx and pull
   it from State:

```erlang
handle_call({create_instance, Name, ClassNref, ParentNref, Resolver,
			 ConflictResolver}, _From,
		#state{instantiable_nref = InstAttr, retired_nref = RetAttr} = State) ->
	Ctx = #{inst_attr => InstAttr, ret_attr => RetAttr, on_path => [],
			resolver => Resolver, conflict_resolver => ConflictResolver,
			root_parent => ParentNref, root_source => undefined},
	{reply, do_create_instance(Name, ClassNref, ParentNref, Ctx), State};
```

4. In `do_create_instance/4`, thread the retired attr into both validators:

```erlang
do_create_instance(Name, ClassNref, ParentNref, Ctx) ->
	InstAttr = maps:get(inst_attr, Ctx),
	RetAttr  = maps:get(ret_attr, Ctx),
	case do_validate_class(ClassNref, InstAttr, RetAttr) of
		ok ->
			case do_validate_parent(ParentNref, RetAttr) of
				ok ->
					fire_create(Name, ClassNref, ParentNref, Ctx);
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.
```

5. Extend `do_validate_class/2` to `do_validate_class/3` (retired check
   first, then the existing instantiable check):

```erlang
do_validate_class(ClassNref, InstAttr, RetAttr) ->
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, attribute_value_pairs = AVPs}] ->
			case is_retired(AVPs, RetAttr) of
				true  -> {error, {class_retired, ClassNref}};
				false ->
					case is_marked_non_instantiable(AVPs, InstAttr) of
						true  -> {error, {class_not_instantiable, ClassNref}};
						false -> ok
					end
			end;
		[#node{kind = Kind}] -> {error, {not_a_class, Kind}};
		[]                   -> {error, class_not_found}
	end.
```

6. Extend `do_validate_parent/1` to `do_validate_parent/2`:

```erlang
do_validate_parent(ParentNref, RetAttr) ->
	case mnesia:dirty_read(nodes, ParentNref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case is_retired(AVPs, RetAttr) of
				true  -> {error, {parent_retired, ParentNref}};
				false -> ok
			end;
		[]      -> {error, parent_not_found}
	end.
```

7. Add the `is_retired/2` predicate next to `is_marked_non_instantiable/2`
   (deliberate small duplication, same YAGNI rationale already documented
   there):

```erlang
%% is_retired(AVPs, RetAttr) -> boolean()
%% True only when AVPs contains #{attribute => RetAttr, value => true}.
is_retired(AVPs, RetAttr) ->
	lists:any(fun
		(#{attribute := A, value := true}) when A =:= RetAttr -> true;
		(_) -> false
	end, AVPs).
```

8. Update `do_add_class_membership/3` to thread `RetAttr` into
   `do_validate_class`, and its handle_call to pass `State#state.retired_nref`:

```erlang
handle_call({add_class_membership, InstanceNref, ClassNref}, _From,
		#state{instantiable_nref = InstAttr, retired_nref = RetAttr} = State) ->
	{reply, do_add_class_membership(InstanceNref, ClassNref, InstAttr, RetAttr),
		State};
```

```erlang
do_add_class_membership(InstanceNref, ClassNref, InstAttr, RetAttr) ->
	case do_get_instance(InstanceNref) of
		{ok, _} ->
			case do_validate_class(ClassNref, InstAttr, RetAttr) of
				ok               -> do_write_class_membership(InstanceNref,
									ClassNref);
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.
```

9. Extend `validate_arc_endpoints/5` to `/6` (add `RetAttr`) and reject a
   retired endpoint. Bind all four resolved nodes' AVP lists in the success
   clause and gate on `first_retired/2` **before** the existing kind checks,
   which are otherwise preserved verbatim (the target kind `TKind` and the
   `check_target_kind(CharNode, TKind, TkAttr)` call are unchanged):

```erlang
validate_arc_endpoints(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TkAttr, RetAttr) ->
	F = fun() ->
		Source = mnesia:read(nodes, SourceNref),
		Target = mnesia:read(nodes, TargetNref),
		Char   = mnesia:read(nodes, CharNref),
		Recip  = mnesia:read(nodes, ReciprocalNref),
		{Source, Target, Char, Recip}
	end,
	case mnesia:transaction(F) of
		{atomic, {[], _, _, _}} ->
			{error, {source_not_found, SourceNref}};
		{atomic, {_, [], _, _}} ->
			{error, {target_not_found, TargetNref}};
		{atomic, {_, _, [], _}} ->
			{error, {characterization_not_found, CharNref}};
		{atomic, {_, _, _, []}} ->
			{error, {reciprocal_not_found, ReciprocalNref}};
		{atomic, {[#node{attribute_value_pairs = SAVPs}],
				  [#node{kind = TKind, attribute_value_pairs = TAVPs}],
				  [#node{kind = CKind, attribute_value_pairs = CAVPs} = CharNode],
				  [#node{kind = RKind, attribute_value_pairs = RAVPs}]}} ->
			case first_retired([{SourceNref, SAVPs}, {TargetNref, TAVPs},
								 {CharNref, CAVPs}, {ReciprocalNref, RAVPs}],
							    RetAttr) of
				{retired, RNref} ->
					{error, {endpoint_retired, RNref}};
				none ->
					case {CKind, RKind} of
						{attribute, attribute} ->
							check_target_kind(CharNode, TKind, TkAttr);
						{attribute, _} ->
							{error, {reciprocal_not_an_attribute,
								ReciprocalNref, RKind}};
						{_, _} ->
							{error, {characterization_not_an_attribute,
								CharNref, CKind}}
					end
			end;
		{aborted, Reason} ->
			{error, Reason}
	end.

%% first_retired([{Nref, AVPs}], RetAttr) -> {retired, Nref} | none
first_retired([], _RetAttr) -> none;
first_retired([{Nref, AVPs} | Rest], RetAttr) ->
	case is_retired(AVPs, RetAttr) of
		true  -> {retired, Nref};
		false -> first_retired(Rest, RetAttr)
	end.
```

10. Update `do_add_relationship/7` to pass `State#state.retired_nref` into
    `validate_arc_endpoints`:

```erlang
	case validate_arc_endpoints(SourceNref, CharNref, TargetNref,
			ReciprocalNref, TkAttr, State#state.retired_nref) of
```

    (`TkAttr` is already bound from `State#state.target_kind_avp_nref` at
    the top of `do_add_relationship/7`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE`
Expected: PASS — the four new guard cases plus all existing instance cases
(the existing `create_instance` / `add_relationship` / membership cases must
remain green, proving the threading didn't break the happy paths).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "feat(graphdb_instance): refuse retired nodes as new participation"
```

---

## Task 5: Documentation and TASKS status

**Files:**
- Modify: `docs/Architecture.md`
- Modify: `docs/diagrams/ontology-tree.md`
- Modify: `TASKS.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `docs/Architecture.md`**

In the `graphdb_mgr` description, note the new read/write contract: public
`get_node/1` returns `{error, retired}` for a retired node; `retire_node/1`
and `unretire_node/1` soft-retire / restore a runtime node via a boolean
`retired` marker AVP (built on `transaction/1`); `delete_node/1` remains
unimplemented and reserved for a future real delete. Keep it at
architectural altitude (a few sentences), matching the file's tone. Add a
one-line note that `graphdb_attr` seeds the `retired` lifecycle marker and
`graphdb_instance` refuses retired nodes as new instance targets/parents/arc
endpoints.

- [ ] **Step 2: Update `docs/diagrams/ontology-tree.md`**

Add a `retired` entry under the **Attribute Literals** sub-group (alongside
`instantiable`, `literal_type`, `target_kind`, `relationship_avp`,
`attribute_type`) in the Mermaid block, matching the existing node style.

- [ ] **Step 3: Mark slice A implemented in `TASKS.md`**

In the "Node deletion (slice A) — DESIGNED" subsection, change the heading
to "— IMPLEMENTED" and add a one-line pointer to the design doc and the
delivered functions (`graphdb_mgr:retire_node/1`, `unretire_node/1`). Leave
the two follow-up tasks (retired rules must not fire; unify permanent-tier
immutability), the project-boundary, and the retired-node-purge entries in
place.

- [ ] **Step 4: Verify the full suite is green and warning-free**

Run: `./rebar3 compile` (expect zero warnings), then
`make test-ct-parallel` and `./rebar3 eunit`
Expected: all CT + EUnit green. The project total grows by 9 CT cases
(1 attr + 4 mgr lifecycle/guard + 1 mgr get_node-filter + ... confirm the
exact count and update any README/MEMORY count only if the repo tracks it
in a checked-in file; do not edit `.wolf/`).

- [ ] **Step 5: Commit**

```bash
git add docs/Architecture.md docs/diagrams/ontology-tree.md TASKS.md
git commit -m "docs: record node soft-retire (retire_node/unretire_node)"
```

---

## Self-Review

**Spec coverage** (`docs/designs/delete-node-soft-retire-design.md`):

- §2 retired marker seeded by graphdb_attr → Task 1. ✓
- §3 retire_node/unretire_node, idempotent, permanent_node_immutable,
  not_found → Task 2. ✓
- §4.1(a) get_node → {error, retired}, do_get_node raw → Task 3. ✓
- §4.1(b) block-new-participation (class target, parent, arc endpoints) →
  Task 4. ✓
- §5 tier-1 `set_retired_/3` + tier-2 wrappers over `transaction/1` →
  Task 2. ✓
- §6 gen_server-call rationale (lazy cache because mgr starts before attr)
  → Task 2 (`ensure_retired_nref/1`). ✓
- §7 tests, including "existing delete-guard cases unchanged" → Tasks 2–4
  (delete_node untouched). ✓
- §8 files touched → Tasks 1–5 cover every row. ✓
- §4.2 deferred items (retired rules still fire; query/traversal
  visibility) → intentionally **not** implemented; tracked in TASKS.md.
  Correct per spec. ✓

**Placeholder scan:** none. Every code step shows complete, runnable code;
Task 4 step 9 preserves the original kind-check (`TKind` /
`check_target_kind`) verbatim and only inserts the `first_retired/2` gate.

**Type/name consistency:** `retired` seeded-map key, `retired_nref` state
field, `is_retired/2` predicate, `permanent_node_immutable` / `retired` /
`{class_retired,_}` / `{parent_retired,_}` / `{endpoint_retired,_}` atoms,
`set_retired/3` / `set_retired_/3` / `set_marker/3` / `ensure_retired_nref/1`
are used consistently across tasks and match the design's §10 decision log.
