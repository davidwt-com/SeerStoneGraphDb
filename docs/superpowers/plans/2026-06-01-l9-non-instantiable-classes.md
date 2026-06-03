# L9 — Non-Instantiable (Abstract) Classes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a class be designated non-instantiable (abstract) so the
instantiation engine refuses to create instances of it, and an abstract
class is born without a default template.

**Architecture:** A seeded boolean marker literal attribute
(`instantiable`) lives in the `Attribute Literals` sub-group, owned by
`graphdb_attr`. An abstract class carries `#{attribute => InstNref,
value => false}` in its node AVP list. `graphdb_class:create_class/3`
takes an initial AVP list and skips the default template when the marker
is present. `graphdb_instance:create_instance/3` reads the marker and
refuses. The marker nref is cached at each consumer's `init/1` from
`graphdb_attr:seeded_nrefs/0` (the existing `target_kind` pattern).

**Tech Stack:** Erlang/OTP 28, rebar3 3.27 (invoke `./rebar3`), Mnesia,
Common Test. Hard-TAB indentation. NYI/UEM macros + module header
conventions per `apps/graphdb/CLAUDE.md`.

**Design spec:** `docs/designs/l9-non-instantiable-classes-design.md`

**Conventions for every task:**
- Run a single CT case with:
  `./rebar3 ct --suite=apps/graphdb/test/<SUITE> --case=<case>`
- Run a whole suite with:
  `./rebar3 ct --suite=apps/graphdb/test/<SUITE>`
- Indent with hard TABs to match surrounding code.
- Commit messages end with the project trailer
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Do **not** seed any abstract class here — that is F4 Phase A. L9 only
  delivers the mechanism.

---

## Task 1: Seed the `instantiable` marker (`graphdb_attr`)

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (`#state` record;
  `init/1`; `seeded_nrefs` handler)
- Test: `apps/graphdb/test/graphdb_attr_SUITE.erl`

- [ ] **Step 1: Write the failing test**

In `graphdb_attr_SUITE.erl`, add the case to the `-export` list (Seeding
section) and to the `{seeding, [], [...]}` group, then add the body. Use
the existing `seeds_attribute_literals_subgroup/1` as the template.

```erlang
%% in -export([...]) under %% Seeding
	seeds_instantiable_marker/1,
```

```erlang
%% in groups(), append to the {seeding, [], [...]} list:
			seeds_instantiable_marker
```

```erlang
%%-----------------------------------------------------------------------------
%% After init, `instantiable` is seeded as an attribute-kind node named
%% "instantiable" under the Attribute Literals sub-group, exposed via
%% seeded_nrefs/0, in the permanent tier, carrying an attribute_type AVP.
%%-----------------------------------------------------------------------------
seeds_instantiable_marker(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{instantiable := InstNref,
		   attribute_literals_group := AttrLitNref}} =
		graphdb_attr:seeded_nrefs(),
	?assert(is_integer(InstNref)),
	?assert(InstNref > ?NREF_ENGLISH andalso InstNref < ?NREF_START),
	{ok, Node} = graphdb_attr:get_attribute(InstNref),
	?assertEqual(attribute, Node#node.kind),
	?assertEqual([AttrLitNref], Node#node.parents),
	?assert(lists:member(#{attribute => ?NAME_ATTR_ATTRIBUTE,
		value => "instantiable"}, Node#node.attribute_value_pairs)).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=seeds_instantiable_marker`
Expected: FAIL — `seeded_nrefs/0` returns a map without the
`instantiable` key (a `{badmatch, ...}` / `{badkey, instantiable}`).

- [ ] **Step 3: Add the `instantiable_nref` state field**

In `apps/graphdb/src/graphdb_attr.erl`, extend the `#state` record:

```erlang
-record(state, {
	attribute_literals_group_nref,	%% integer() -- Attribute Literals sub-group
	literal_type_nref,				%% integer() -- seeded literal attribute
	target_kind_nref,				%% integer() -- seeded literal attribute
	relationship_avp_nref,			%% integer() -- seeded literal attribute
	attribute_type_nref,			%% integer() -- seeded literal attribute (M8)
	instantiable_nref				%% integer() -- seeded marker literal attribute (L9)
}).
```

- [ ] **Step 4: Seed it in `init/1`**

In `init/1`, add the seed line to the `#state{}` construction (after
`attribute_type_nref`):

```erlang
		State = #state{
			attribute_literals_group_nref = AttrLitNref,
			literal_type_nref     = ensure_seed("literal_type", AttrLitNref),
			target_kind_nref      = ensure_seed("target_kind", AttrLitNref),
			relationship_avp_nref = ensure_seed("relationship_avp", AttrLitNref),
			attribute_type_nref   = ensure_seed("attribute_type", AttrLitNref),
			instantiable_nref     = ensure_seed("instantiable", AttrLitNref)
		},
```

(The existing `retro_stamp_bootstrap_attribute_types/1` call already
stamps `attribute_type` across the Attributes subtree, which now
includes this seed — no extra work.) Also extend the `logger:info`
seed-summary line to mention `instantiable=~p` if you wish (optional,
non-functional).

- [ ] **Step 5: Expose it from `seeded_nrefs`**

In the `handle_call(seeded_nrefs, ...)` clause, add the key:

```erlang
handle_call(seeded_nrefs, _From, State) ->
	Reply = {ok, #{
		attribute_literals_group => State#state.attribute_literals_group_nref,
		literal_type     => State#state.literal_type_nref,
		target_kind      => State#state.target_kind_nref,
		relationship_avp => State#state.relationship_avp_nref,
		attribute_type   => State#state.attribute_type_nref,
		instantiable     => State#state.instantiable_nref
	}},
	{reply, Reply, State};
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=seeds_instantiable_marker`
Expected: PASS.

- [ ] **Step 7: Run the whole attr suite (idempotency regression)**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE`
Expected: PASS — in particular `seeds_idempotent_on_restart` still
passes, proving the new seed reuses its nref across a restart (no node
count growth).

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "L9: seed instantiable marker literal attribute (graphdb_attr)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `create_class/3` AVP passthrough (`graphdb_class`)

Generalizes class creation to carry initial AVPs. No abstract behavior
yet — the default template is still always created. (Abstract handling
is Task 3.)

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (`create_class/2,3`
  export + clauses; `handle_call`; `do_create_class`)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add two cases to `graphdb_class_SUITE.erl` (export + a group — put them
in the same group `create_class_auto_creates_default_template` lives in;
find it in `groups()` and append the two names).

```erlang
%% in -export([...])
	create_class_3_default_avps_empty/1,
	create_class_3_writes_avps/1,
```

```erlang
%%-----------------------------------------------------------------------------
%% create_class/2 and create_class/3 with [] produce identical structure:
%% a class node plus its default template.
%%-----------------------------------------------------------------------------
create_class_3_default_avps_empty(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, C2} = graphdb_class:create_class("Two", 3),
	{ok, C3} = graphdb_class:create_class("Three", 3, []),
	?assertMatch({ok, _}, graphdb_class:default_template(C2)),
	?assertMatch({ok, _}, graphdb_class:default_template(C3)).

%%-----------------------------------------------------------------------------
%% AVPs passed to create_class/3 are written onto the class node verbatim,
%% after the class-name AVP.
%%-----------------------------------------------------------------------------
create_class_3_writes_avps(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, LtNref} = graphdb_attr:create_literal_attribute("note", term),
	Extra = #{attribute => LtNref, value => "hello"},
	{ok, ClassNref} = graphdb_class:create_class("Tagged", 3, [Extra]),
	{ok, Node} = graphdb_class:get_class(ClassNref),
	?assert(lists:member(#{attribute => ?NAME_ATTR_CLASS, value => "Tagged"},
		Node#node.attribute_value_pairs)),
	?assert(lists:member(Extra, Node#node.attribute_value_pairs)).
```

Note: `graphdb_class_SUITE` `init_per_testcase` already starts
`graphdb_attr` (and `graphdb_mgr`, `rel_id_server`, `graphdb_nref`), so
the cases above only start `graphdb_class` themselves — do **not** call
`graphdb_attr:start_link()` inside a case (it would return
`{error, {already_started, _}}` and badmatch).

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=create_class_3_writes_avps`
Expected: FAIL — `create_class/3` is undefined (`undef`).

- [ ] **Step 3: Add the `/3` arity (export + clauses)**

In `apps/graphdb/src/graphdb_class.erl`, change the export
`create_class/2,` to:

```erlang
		create_class/2,
		create_class/3,
```

Replace the `create_class/2` function with a wrapper plus the `/3`:

```erlang
create_class(Name, ParentClassNref) ->
	create_class(Name, ParentClassNref, []).

create_class(Name, ParentClassNref, AVPs) when is_list(AVPs) ->
	gen_server:call(?MODULE, {create_class, Name, ParentClassNref, AVPs}).
```

- [ ] **Step 4: Thread AVPs through `handle_call` and `do_create_class`**

Change the `handle_call` clause:

```erlang
handle_call({create_class, Name, ParentClassNref, AVPs}, _From, State) ->
	{reply, do_create_class(Name, ParentClassNref, AVPs), State};
```

Change `do_create_class/2` to `do_create_class/3` and prepend the
class-name AVP to the supplied AVPs on the class node. Locate the
`ClassNode = #node{...}` construction inside `do_create_class` and change
its `attribute_value_pairs`:

```erlang
do_create_class(Name, ParentClassNref, AVPs) ->
	case do_validate_parent(ParentClassNref) of
		ok ->
			%% ... existing nref/id allocation unchanged ...
			ClassNameAVP    = #{attribute => ?NAME_ATTR_CLASS, value => Name},
			%% ... TemplateNameAVP unchanged ...
			ClassNode = #node{
				nref = ClassNref,
				kind = class,
				parents = [ParentClassNref],
				attribute_value_pairs = [ClassNameAVP | AVPs]
			},
			%% ... rest of the function (arcs, template, txn) unchanged ...
```

Leave the default-template writes exactly as they are for now.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=create_class_3_writes_avps`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=create_class_3_default_avps_empty`
Expected: PASS for both.

- [ ] **Step 6: Run the whole class suite (regression)**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS — all 181 existing `create_class/2` call sites still
work via the wrapper.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "L9: create_class/3 takes an initial AVP list

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Abstract-class handling (`graphdb_class`)

Cache the marker nref at init; skip the default template when a class is
created with `instantiable => false`; add `is_instantiable/1`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (`#state`; `init/1`;
  `do_create_class`; new `is_instantiable/1` + export + handle_call)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add three cases (export + group, alongside the template tests):

```erlang
%% in -export([...])
	create_abstract_class_skips_default_template/1,
	instantiable_class_keeps_default_template/1,
	is_instantiable_true_false/1,
```

```erlang
%%-----------------------------------------------------------------------------
%% A class created with instantiable=>false has NO default template.
%%-----------------------------------------------------------------------------
create_abstract_class_skips_default_template(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	Marker = #{attribute => Inst, value => false},
	{ok, ClassNref} = graphdb_class:create_class("Abstract", 3, [Marker]),
	?assertEqual(not_found, graphdb_class:default_template(ClassNref)),
	?assertEqual({ok, []}, graphdb_class:templates_for_class(ClassNref)).

%%-----------------------------------------------------------------------------
%% A class created without the marker still gets its default template.
%%-----------------------------------------------------------------------------
instantiable_class_keeps_default_template(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, ClassNref} = graphdb_class:create_class("Concrete", 3),
	?assertMatch({ok, _}, graphdb_class:default_template(ClassNref)).

%%-----------------------------------------------------------------------------
%% is_instantiable/1: true for ordinary classes, false for marked ones.
%%-----------------------------------------------------------------------------
is_instantiable_true_false(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	{ok, Ordinary} = graphdb_class:create_class("Ord", 3),
	{ok, Abstract} = graphdb_class:create_class("Abs", 3,
		[#{attribute => Inst, value => false}]),
	?assertEqual(true,  graphdb_class:is_instantiable(Ordinary)),
	?assertEqual(false, graphdb_class:is_instantiable(Abstract)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=create_abstract_class_skips_default_template`
Expected: FAIL — the default template IS created (so
`default_template/1` returns `{ok, _}`, not `not_found`).
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=is_instantiable_true_false`
Expected: FAIL — `is_instantiable/1` is `undef`.

- [ ] **Step 3: Cache the marker nref at init**

Change the `#state` record and `init/1`:

```erlang
-record(state, {
	instantiable_nref	%% integer() -- seeded `instantiable` marker, cached
						%% from graphdb_attr at init (L9)
}).
```

```erlang
init([]) ->
	%% graphdb_attr is started before graphdb_class by graphdb_sup, so
	%% seeded_nrefs/0 is answerable here.
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	logger:info("graphdb_class: started (instantiable=~p)", [InstAttr]),
	{ok, #state{instantiable_nref = InstAttr}}.
```

- [ ] **Step 4: Make the template conditional in `do_create_class`**

Thread the cached nref from `handle_call` and skip the template writes
when the marker is present with value `false`. Update the handle_call
clause and `do_create_class`:

```erlang
handle_call({create_class, Name, ParentClassNref, AVPs}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	{reply, do_create_class(Name, ParentClassNref, AVPs, InstAttr), State};
```

```erlang
do_create_class(Name, ParentClassNref, AVPs, InstAttr) ->
	case do_validate_parent(ParentClassNref) of
		ok ->
			ClassNref        = graphdb_nref:get_next(),
			{TaxId1, TaxId2} = rel_id_server:get_id_pair(),
			ClassNameAVP = #{attribute => ?NAME_ATTR_CLASS, value => Name},
			ClassNode = #node{
				nref = ClassNref,
				kind = class,
				parents = [ParentClassNref],
				attribute_value_pairs = [ClassNameAVP | AVPs]
			},
			TaxP2C = #relationship{
				id = TaxId1, kind = taxonomy,
				source_nref = ParentClassNref,
				characterization = ?ARC_CLS_CHILD,
				target_nref = ClassNref,
				reciprocal = ?ARC_CLS_PARENT,
				avps = []
			},
			TaxC2P = #relationship{
				id = TaxId2, kind = taxonomy,
				source_nref = ClassNref,
				characterization = ?ARC_CLS_PARENT,
				target_nref = ParentClassNref,
				reciprocal = ?ARC_CLS_CHILD,
				avps = []
			},
			TemplateRows = template_rows(ClassNref, AVPs, InstAttr),
			Txn = fun() ->
				ok = mnesia:write(nodes, ClassNode, write),
				ok = mnesia:write(relationships, TaxP2C, write),
				ok = mnesia:write(relationships, TaxC2P, write),
				[ ok = mnesia:write(T, R, write) || {T, R} <- TemplateRows ]
			end,
			case mnesia:transaction(Txn) of
				{atomic, _}       -> {ok, ClassNref};
				{aborted, Reason} -> {error, Reason}
			end;
		{error, _} = Err ->
			Err
	end.

%% template_rows(ClassNref, AVPs, InstAttr) -> [{Table, Record}]
%% Returns the default-template node + class<->template composition arc
%% pair, or [] when the class is marked non-instantiable.
template_rows(ClassNref, AVPs, InstAttr) ->
	case is_marked_non_instantiable(AVPs, InstAttr) of
		true  -> [];
		false ->
			TemplateNref               = graphdb_nref:get_next(),
			{TmplCompId1, TmplCompId2} = rel_id_server:get_id_pair(),
			TemplateNameAVP = #{attribute => ?NAME_ATTR_CLASS,
				value => ?DEFAULT_TEMPLATE_NAME},
			TemplateNode = #node{
				nref = TemplateNref,
				kind = template,
				parents = [ClassNref],
				attribute_value_pairs = [TemplateNameAVP]
			},
			TmplP2C = #relationship{
				id = TmplCompId1, kind = composition,
				source_nref = ClassNref,
				characterization = ?ARC_CLS_CHILD,
				target_nref = TemplateNref,
				reciprocal = ?ARC_CLS_PARENT,
				avps = []
			},
			TmplC2P = #relationship{
				id = TmplCompId2, kind = composition,
				source_nref = TemplateNref,
				characterization = ?ARC_CLS_PARENT,
				target_nref = ClassNref,
				reciprocal = ?ARC_CLS_CHILD,
				avps = []
			},
			[{nodes, TemplateNode},
			 {relationships, TmplP2C},
			 {relationships, TmplC2P}]
	end.

%% is_marked_non_instantiable(AVPs, InstAttr) -> boolean()
is_marked_non_instantiable(AVPs, InstAttr) ->
	lists:any(fun
		(#{attribute := A, value := false}) when A =:= InstAttr -> true;
		(_) -> false
	end, AVPs).
```

This refactor replaces the `do_create_class/3` body written in Task 2
(it becomes `/4`, gaining `InstAttr`). The template node + arc nrefs are
still allocated outside the transaction (`template_rows/3` runs before
the `Txn` fun is built). Note the transaction match changed to
`{atomic, _}` because the body now returns the list-comprehension result
rather than `ok`.

- [ ] **Step 5: Add `is_instantiable/1`**

Add to the export list (Lookups section):

```erlang
		is_instantiable/1,
```

Add the public function (near the other lookups) and a `handle_call`
clause:

```erlang
%% is_instantiable(ClassNref) -> boolean() | {error, term()}
%% false iff the class carries an instantiable=>false marker AVP.
is_instantiable(ClassNref) ->
	gen_server:call(?MODULE, {is_instantiable, ClassNref}).
```

```erlang
handle_call({is_instantiable, ClassNref}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	Reply = case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, attribute_value_pairs = AVPs}] ->
			not is_marked_non_instantiable(AVPs, InstAttr);
		[#node{kind = Kind}] -> {error, {not_a_class, Kind}};
		[]                   -> {error, class_not_found}
	end,
	{reply, Reply, State};
```

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=create_abstract_class_skips_default_template`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=instantiable_class_keeps_default_template`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE --case=is_instantiable_true_false`
Expected: PASS for all three.

- [ ] **Step 7: Run the whole class suite (regression)**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS — including the existing
`create_class_auto_creates_default_template`,
`default_template_returns_default`, and
`default_template_not_found_after_delete`, and the
`end_per_testcase` cache-invariant assertion.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "L9: abstract classes skip the default template; is_instantiable/1

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Refuse instantiation of abstract classes (`graphdb_instance`)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (`#state`; `init/1`;
  `handle_call` create_instance; `do_create_instance`;
  `do_validate_class`)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add two cases to `graphdb_instance_SUITE.erl` (export + a group — put
them with the other `create_instance` error cases).

```erlang
%% in -export([...])
	create_instance_refused_for_abstract_class/1,
	create_instance_allowed_for_unmarked_class/1,
```

```erlang
%%-----------------------------------------------------------------------------
%% Instantiating a class marked instantiable=>false is refused, and no
%% rows are written.
%%-----------------------------------------------------------------------------
create_instance_refused_for_abstract_class(_Config) ->
	{ok, #{instantiable := Inst}} = graphdb_attr:seeded_nrefs(),
	{ok, ClassNref} = graphdb_class:create_class("Meta", 3,
		[#{attribute => Inst, value => false}]),
	Before = mnesia:table_info(nodes, size),
	?assertEqual({error, {class_not_instantiable, ClassNref}},
		graphdb_instance:create_instance("Nope", ClassNref, 5)),
	?assertEqual(Before, mnesia:table_info(nodes, size)).

%%-----------------------------------------------------------------------------
%% Ordinary classes still instantiate normally.
%%-----------------------------------------------------------------------------
create_instance_allowed_for_unmarked_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Plain", 3),
	?assertMatch({ok, _},
		graphdb_instance:create_instance("Inst1", ClassNref, 5)).
```

(`graphdb_attr`, `graphdb_class`, `graphdb_instance` are all started by
the suite's `init_per_testcase` — do not start them inside the cases.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=create_instance_refused_for_abstract_class`
Expected: FAIL — the instance is created (`{ok, _}`) instead of
`{error, {class_not_instantiable, _}}`, and the node count grows.

- [ ] **Step 3: Cache the marker nref at init**

Extend the `#state` record and `init/1`:

```erlang
-record(state, {
	target_kind_avp_nref,	%% integer() -- seeded `target_kind` (M3)
	instantiable_nref		%% integer() -- seeded `instantiable` marker (L9)
}).
```

```erlang
init([]) ->
	logger:info("graphdb_instance: started"),
	{ok, #{target_kind := TkAttr, instantiable := InstAttr}} =
		graphdb_attr:seeded_nrefs(),
	{ok, #state{target_kind_avp_nref = TkAttr,
				instantiable_nref = InstAttr}}.
```

- [ ] **Step 4: Thread the nref into the validation path**

Change the create_instance `handle_call` clause to pass the cached nref,
and thread it through `do_create_instance` into `do_validate_class`:

```erlang
handle_call({create_instance, Name, ClassNref, ParentNref}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	{reply, do_create_instance(Name, ClassNref, ParentNref, InstAttr),
		State};
```

```erlang
do_create_instance(Name, ClassNref, ParentNref, InstAttr) ->
	case do_validate_class(ClassNref, InstAttr) of
		ok ->
			case do_validate_parent(ParentNref) of
				ok ->
					do_write_instance(Name, ClassNref, ParentNref);
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.
```

```erlang
do_validate_class(ClassNref, InstAttr) ->
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, attribute_value_pairs = AVPs}] ->
			case is_marked_non_instantiable(AVPs, InstAttr) of
				true  -> {error, {class_not_instantiable, ClassNref}};
				false -> ok
			end;
		[#node{kind = Kind}] -> {error, {not_a_class, Kind}};
		[]                   -> {error, class_not_found}
	end.

%% is_marked_non_instantiable(AVPs, InstAttr) -> boolean()
is_marked_non_instantiable(AVPs, InstAttr) ->
	lists:any(fun
		(#{attribute := A, value := false}) when A =:= InstAttr -> true;
		(_) -> false
	end, AVPs).
```

Remove the old `do_validate_class/1` definition (it is replaced by `/2`).

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=create_instance_refused_for_abstract_class`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=create_instance_allowed_for_unmarked_class`
Expected: PASS for both.

- [ ] **Step 6: Run the whole instance suite (regression)**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE`
Expected: PASS — existing `{not_a_class, _}` / `class_not_found` /
`parent_not_found` cases still pass; cache invariant holds.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "L9: refuse create_instance for non-instantiable classes

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Documentation

No code; documentation only. Follow the markdown table-alignment rule
(`python3 ~/.claude/scripts/align_md_tables.py FILE` on any file whose
tables you touch).

**Files:**
- Modify: `the-knowledge-network.md` (§7)
- Modify: `ARCHITECTURE.md`
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `docs/diagrams/ontology-tree.md`
- Modify: `TASKS.md`
- Modify: `docs/designs/f4-graphdb-rules-design.md`

- [ ] **Step 1: `the-knowledge-network.md` §7 — conceptual passage**

Append to §7 (Templates) the **concept-only** passage (no mechanism — no
marker/attribute names, no functions). Use exactly the text from the L9
spec §5:

> **Abstract classes.** Not every class is meant to have instances. Some
> classes exist purely as organizing abstractions — points in the
> taxonomy that gather and define the more specific classes beneath them
> but are never themselves made concrete. Such a class may be designated
> *non-instantiable*: the model declines to instantiate it and directs
> the modeler to one of its specializations instead. This is permissive
> by default — a class is instantiable unless explicitly designated
> otherwise — so a newly-encountered thing may be placed under a general
> class before it has been fully classified. Having no instances, an
> abstract class engages no connections, and therefore defines no
> template.

- [ ] **Step 2: `ARCHITECTURE.md` — API contract notes**

In the `graphdb_class` section, note `create_class/3` (initial AVP list)
and `is_instantiable/1`. In the `graphdb_instance` section, note that
`create_instance` returns `{error, {class_not_instantiable, ClassNref}}`
for a class marked non-instantiable. Keep it at architectural altitude
(no implementation internals).

- [ ] **Step 3: `apps/graphdb/CLAUDE.md` — worker details**

- `graphdb_attr`: add `instantiable` to the seeded `Attribute Literals`
  list.
- `graphdb_class`: list `create_class/2,3` and `is_instantiable/1`.
- `graphdb_instance`: note the `class_not_instantiable` rejection in
  `create_instance`.

- [ ] **Step 4: `docs/diagrams/ontology-tree.md` — new seed**

Add `instantiable` as a child under the `Attribute Literals` sub-group
(nref 7 subtree), alongside `literal_type`, `target_kind`,
`relationship_avp`, `attribute_type`. Update the Mermaid block.

- [ ] **Step 5: `TASKS.md` — L9 entry**

Add an L9 entry (Engineering Hygiene / prerequisite series) describing
the non-instantiable-class marker, and mark it RESOLVED with the commit
range. Cross-reference F4 D15.

- [ ] **Step 6: `docs/designs/f4-graphdb-rules-design.md` — D15 note**

In D15 (and §3's side-effect note), add: "Mechanism delivered by L9
(`docs/designs/l9-non-instantiable-classes-design.md`) — landed as a
prerequisite. F4 Phase A seeds the `Rule` root via
`create_class("Rule", ?NREF_CLASSES, [#{attribute => InstantiableNref,
value => false}])`." Re-run the table-alignment script if any table
changed.

- [ ] **Step 7: Final full-suite run**

Run: `./rebar3 ct --dir apps/graphdb/test` and `./rebar3 eunit`
Expected: all green. Record the new totals (CT count is +8 over the
pre-L9 baseline: 1 attr + 2+3 class + 2 instance).

- [ ] **Step 8: Commit**

```bash
git add the-knowledge-network.md ARCHITECTURE.md apps/graphdb/CLAUDE.md docs/diagrams/ontology-tree.md TASKS.md docs/designs/f4-graphdb-rules-design.md
git commit -m "L9: docs — abstract-class concept, API contracts, ontology tree, TASKS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the Implementer

- **Single source for `is_marked_non_instantiable/2`.** It appears in
  both `graphdb_class` and `graphdb_instance` (Tasks 3 and 4) because the
  workers do not share a module. This duplication is intentional and
  small; do **not** introduce a shared module for it in L9 (YAGNI). If a
  shared graphdb util module already exists, prefer it.
- **Permissive default.** Only `value => false` blocks. Absence of the
  marker, or `value => true`, means instantiable. The scan matches
  `value => false` specifically.
- **Do not seed an abstract class.** L9 ships the mechanism; the `Rule`
  root is F4 Phase A's responsibility (Task 5 step 6 only documents the
  call F4 will make).
- **Cache invariant.** L9 adds no new arc kinds; abstract classes still
  have their taxonomy parent/child arcs, so `verify_caches/0` is
  unaffected. Every suite already asserts it in `end_per_testcase`.
