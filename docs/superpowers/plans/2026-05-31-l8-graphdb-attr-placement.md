<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# L8 — Generalize `graphdb_attr` Attribute Placement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ParentNref` a first-class argument on every `graphdb_attr`
attribute creator, validate that parent, and rename
`create_relationship_attribute` → `create_relationship_attribute_pair`.

**Architecture:** Two canonical general creators —
`create_value_attribute/4` (single node) and
`create_relationship_attribute_pair/4` (reciprocal pair) — become the real
implementation. The existing named functions become thin wrappers that
pass their conventional default parent (6/7/8), so all current behaviour
and tests are preserved. A shared `validate_parent/1` runs inside the
gen_server before any write. No Mnesia schema change; the two internal
write helpers keep their structure (one gains a `ParentNref` parameter).

**Tech Stack:** Erlang/OTP 28, rebar3 3.27, Mnesia, Common Test, EUnit.

**Design reference:** `docs/designs/l8-graphdb-attr-placement-design.md`.

**Build/test commands (run from project root):**

- Compile: `./rebar3 compile`
- One CT suite: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
- Full CT: `./rebar3 ct`
- Full EUnit: `./rebar3 eunit`

`./rebar3` is the project-local launcher; the kerl OTP 28 PATH is already
set in `.claude/settings.local.json`. Do **not** prefix with
`source ~/.bashrc`.

---

## File Structure

| File                                              | Responsibility / change                                        |
|---------------------------------------------------|----------------------------------------------------------------|
| `apps/graphdb/src/graphdb_attr.erl`               | All API + internal changes (rename, wrappers, validation, general creators) |
| `apps/graphdb/src/graphdb_mgr.erl`                | One delegating call site updated for the rename                 |
| `apps/graphdb/test/graphdb_attr_SUITE.erl`        | New CT cases; call-site rename                                  |
| `apps/graphdb/test/graphdb_instance_SUITE.erl`    | Call-site rename only                                           |
| `apps/graphdb/test/graphdb_query_SUITE.erl`       | Call-site rename only                                           |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`         | Call-site rename only                                           |
| `apps/graphdb/CLAUDE.md`                          | `graphdb_attr` API doc refresh                                  |
| `ARCHITECTURE.md`                                 | `graphdb_attr` worker public-API line                          |
| `TASKS.md`                                        | L8 entry (RESOLVED)                                             |
| `docs/designs/f4-graphdb-rules-design.md`         | §10.1 P1 resolution note                                        |
| `.wolf/memory.md`, `.wolf/anatomy.md`             | OpenWolf bookkeeping                                            |

All scaffold nref / arc macros used below are defined in
`apps/graphdb/include/graphdb_nrefs.hrl` and already included by both the
source module and the test suite:
`?NREF_NAMES`=6, `?NREF_LITERALS`=7, `?NREF_RELATIONSHIPS`=8,
`?NREF_CAT_NAME_ATTRS`=9, `?NREF_INST_REL_ATTRS`=16,
`?NAME_ATTR_ATTRIBUTE`=18, `?ARC_ATTR_PARENT`=23, `?ARC_ATTR_CHILD`=24.

---

## Task 1: Rename `create_relationship_attribute` → `create_relationship_attribute_pair`

Mechanical rename of the public symbol and its one production caller and
all test call sites. No behaviour change. The function still creates a
reciprocal pair under the hardcoded `?NREF_RELATIONSHIPS`; the `/4` parent
arity arrives in Task 2.

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (export, doc, public clause, gen_server message, handle_call)
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (one call site)
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl`, `graphdb_instance_SUITE.erl`, `graphdb_query_SUITE.erl`, `graphdb_mgr_SUITE.erl` (call sites)

- [ ] **Step 1: Rename all qualified call sites with a scoped sed**

The qualified call string `graphdb_attr:create_relationship_attribute(`
appears in `graphdb_mgr.erl` and the four test suites. Replacing the
string ending in `(` is safe: it does **not** match the already-existing
`create_relationship_attribute_pair(` identifiers (those have `_pair`
before the paren) nor the CT case names like
`create_relationship_attribute_delegates` (no paren).

Run:

```bash
grep -rl 'graphdb_attr:create_relationship_attribute(' apps \
  | xargs sed -i 's/graphdb_attr:create_relationship_attribute(/graphdb_attr:create_relationship_attribute_pair(/g'
```

- [ ] **Step 2: Verify no qualified caller of the old name remains**

Run:

```bash
grep -rn 'create_relationship_attribute(' apps/graphdb/src apps/graphdb/test \
  | grep -v 'create_relationship_attribute_pair(' \
  | grep -v 'do_create_relationship_attribute_pair'
```

Expected: only the **unqualified** local definition and gen_server-message
lines inside `apps/graphdb/src/graphdb_attr.erl` (handled next). No
`graphdb_attr:`-qualified hits.

- [ ] **Step 3: Update the export list in `graphdb_attr.erl`**

In the `-export([...])` block (around line 124), change:

```erlang
		create_relationship_attribute/3,
```

to:

```erlang
		create_relationship_attribute_pair/3,
```

Also update the header doc comment near line 40 from
`%% create_relationship_attribute/3, create_relationship_type/1,` to
`%% create_relationship_attribute_pair/3, create_relationship_type/1,`.

- [ ] **Step 4: Rename the public clause and its gen_server message**

Replace the public function (around lines 203-220) — including its doc
banner — with:

```erlang
%%-----------------------------------------------------------------------------
%% create_relationship_attribute_pair(Name, ReciprocalName, TargetKind) ->
%%     {ok, {Nref, ReciprocalNref}} | {error, term()}
%%
%% Creates a reciprocal pair of arc label attribute nodes under the
%% `Relationships` subtree (nref 8).  TargetKind is one of
%% category | attribute | class | instance and is stored as an AVP
%% keyed by the seeded `target_kind` attribute on both nodes.  The
%% query engine uses this annotation to route target lookups between
%% the ontology and project (instance space).
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair(Name, ReciprocalName, TargetKind) ->
	case valid_target_kind(TargetKind) of
		true ->
			gen_server:call(?MODULE,
				{create_relationship_attribute_pair, Name, ReciprocalName,
					TargetKind});
		false ->
			{error, {invalid_target_kind, TargetKind}}
	end.
```

- [ ] **Step 5: Rename the handle_call clause**

Change the handler head (around line 363) from:

```erlang
handle_call({create_relationship_attribute, Name, ReciprocalName, TargetKind},
		_From, #state{target_kind_nref = TkAttr} = State) ->
```

to:

```erlang
handle_call({create_relationship_attribute_pair, Name, ReciprocalName, TargetKind},
		_From, #state{target_kind_nref = TkAttr} = State) ->
```

(The clause body is unchanged in this task.)

- [ ] **Step 6: Compile**

Run: `./rebar3 compile`
Expected: compiles clean, zero warnings.

- [ ] **Step 7: Run the full CT + EUnit suite to confirm no behaviour change**

Run: `./rebar3 ct && ./rebar3 eunit`
Expected: all suites PASS (same counts as before the change). The rename
is behaviour-preserving.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/src/graphdb_mgr.erl \
        apps/graphdb/test/graphdb_attr_SUITE.erl \
        apps/graphdb/test/graphdb_instance_SUITE.erl \
        apps/graphdb/test/graphdb_query_SUITE.erl \
        apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "L8: rename create_relationship_attribute -> _pair"
```

---

## Task 2: Parent argument + validation on the reciprocal-pair creator

Add `create_relationship_attribute_pair/4` (explicit parent), make `/3`
delegate to it with the default parent, parameterize the internal write
helper, and introduce the shared `validate_parent/1`.

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl`
- Test: `apps/graphdb/test/graphdb_attr_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add two CT case functions to `graphdb_attr_SUITE.erl` (place them next to
the existing `create_relationship_attribute_pair_atomic`, around line 451):

```erlang
%%-----------------------------------------------------------------------------
%% create_relationship_attribute_pair/4 files both arc-label nodes under
%% an explicit parent (here Instance Relationships, nref 16) instead of
%% the default Relationships root (nref 8).
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair_under_parent(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	NodesBefore = mnesia:table_info(nodes, size),
	{ok, {FwdNref, RevNref}} =
		graphdb_attr:create_relationship_attribute_pair("AppliesTo", "AppliedBy",
			instance, ?NREF_INST_REL_ATTRS),
	{ok, Fwd} = graphdb_attr:get_attribute(FwdNref),
	{ok, Rev} = graphdb_attr:get_attribute(RevNref),
	?assertEqual([?NREF_INST_REL_ATTRS], Fwd#node.parents),
	?assertEqual([?NREF_INST_REL_ATTRS], Rev#node.parents),
	?assertEqual(NodesBefore + 2, mnesia:table_info(nodes, size)),
	{atomic, Out} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, ?NREF_INST_REL_ATTRS,
			#relationship.source_nref)
	end),
	Inbound = [R || R <- Out,
		R#relationship.characterization =:= ?ARC_ATTR_CHILD,
		lists:member(R#relationship.target_nref, [FwdNref, RevNref])],
	?assertEqual(2, length(Inbound)).

%%-----------------------------------------------------------------------------
%% A bad parent is rejected before any write: nonexistent nref yields
%% parent_not_found; a non-attribute node (category root, nref 1) yields
%% parent_not_attribute.  No nodes or relationships are written.
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair_bad_parent(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	NodesBefore = mnesia:table_info(nodes, size),
	RelsBefore  = mnesia:table_info(relationships, size),
	?assertMatch({error, {parent_not_found, 99999999}},
		graphdb_attr:create_relationship_attribute_pair("A", "B", instance,
			99999999)),
	?assertMatch({error, {parent_not_attribute, category}},
		graphdb_attr:create_relationship_attribute_pair("A", "B", instance,
			?NREF_ROOT)),
	?assertEqual(NodesBefore, mnesia:table_info(nodes, size)),
	?assertEqual(RelsBefore, mnesia:table_info(relationships, size)).
```

Register both cases: add to the `-export([...])` test block (after
`create_relationship_attribute_rejects_bad_kind/1`, around line 74):

```erlang
	create_relationship_attribute_pair_under_parent/1,
	create_relationship_attribute_pair_bad_parent/1,
```

and to the `creators` group list (after
`create_relationship_attribute_rejects_bad_kind`, around line 125):

```erlang
			create_relationship_attribute_pair_under_parent,
			create_relationship_attribute_pair_bad_parent,
```

`?NREF_ROOT` (=1) is defined in `graphdb_nrefs.hrl`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: FAIL — `create_relationship_attribute_pair_under_parent` and
`create_relationship_attribute_pair_bad_parent` error with
`undef` (no `create_relationship_attribute_pair/4`).

- [ ] **Step 3: Add the `/4` clause and delegate `/3` to it**

In `graphdb_attr.erl`, replace the `create_relationship_attribute_pair/3`
public function (from Task 1) with both arities:

```erlang
create_relationship_attribute_pair(Name, ReciprocalName, TargetKind) ->
	create_relationship_attribute_pair(Name, ReciprocalName, TargetKind,
		?NREF_RELATIONSHIPS).

%%-----------------------------------------------------------------------------
%% create_relationship_attribute_pair(Name, ReciprocalName, TargetKind,
%%                                    ParentNref) ->
%%     {ok, {Nref, ReciprocalNref}} | {error, term()}
%%
%% As /3 but files both arc-label nodes under ParentNref.  ParentNref
%% must name an existing kind=attribute node (validated server-side);
%% typically one of the Relationships sub-buckets (13-16) or the
%% Relationships root (8).
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair(Name, ReciprocalName, TargetKind, ParentNref) ->
	case valid_target_kind(TargetKind) of
		true ->
			gen_server:call(?MODULE,
				{create_relationship_attribute_pair, Name, ReciprocalName,
					TargetKind, ParentNref});
		false ->
			{error, {invalid_target_kind, TargetKind}}
	end.
```

Add `create_relationship_attribute_pair/4` to the `-export([...])` block,
beside the `/3` entry:

```erlang
		create_relationship_attribute_pair/3,
		create_relationship_attribute_pair/4,
```

- [ ] **Step 4: Update the handle_call clause to carry parent + validate**

Replace the `{create_relationship_attribute_pair, ...}` handler (from
Task 1) with:

```erlang
handle_call({create_relationship_attribute_pair, Name, ReciprocalName,
		TargetKind, ParentNref},
		_From, #state{target_kind_nref = TkAttr} = State) ->
	Reply = case validate_parent(ParentNref) of
		ok ->
			Extra = [#{attribute => TkAttr, value => TargetKind},
					 attr_type_avp(relationship, State)],
			do_create_relationship_attribute_pair(Name, ReciprocalName, Extra,
				ParentNref);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
```

- [ ] **Step 5: Parameterize the internal pair writer**

Replace the whole `do_create_relationship_attribute_pair/3` function (the
helper hardcodes `?NREF_RELATIONSHIPS` in six places) with the `/4` form:

```erlang
%%-----------------------------------------------------------------------------
%% do_create_relationship_attribute_pair(FwdName, RevName, ExtraAVPs,
%%                                        ParentNref) ->
%%     {ok, {FwdNref, RevNref}} | {error, term()}
%%
%% Atomically creates a reciprocal pair of arc-label attribute nodes
%% under ParentNref.  Both nodes plus all four taxonomy arc rows
%% (parent->child + child->parent for each direction) are written
%% inside a single Mnesia transaction so a mid-pair abort cannot leave
%% the database with an orphan half-pair.
%%-----------------------------------------------------------------------------
do_create_relationship_attribute_pair(FwdName, RevName, ExtraAVPs, ParentNref) ->
	FwdNref = graphdb_nref:get_next(),
	RevNref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	{Id3, Id4} = rel_id_server:get_id_pair(),
	FwdAVPs = [#{attribute => ?NAME_ATTR_ATTRIBUTE, value => FwdName}
		| ExtraAVPs],
	RevAVPs = [#{attribute => ?NAME_ATTR_ATTRIBUTE, value => RevName}
		| ExtraAVPs],
	FwdNode = #node{
		nref = FwdNref,
		kind = attribute,
		parents = [ParentNref],
		attribute_value_pairs = FwdAVPs
	},
	RevNode = #node{
		nref = RevNref,
		kind = attribute,
		parents = [ParentNref],
		attribute_value_pairs = RevAVPs
	},
	FwdP2C = #relationship{
		id = Id1, kind = taxonomy,
		source_nref = ParentNref, characterization = ?ARC_ATTR_CHILD,
		target_nref = FwdNref, reciprocal = ?ARC_ATTR_PARENT, avps = []
	},
	FwdC2P = #relationship{
		id = Id2, kind = taxonomy,
		source_nref = FwdNref, characterization = ?ARC_ATTR_PARENT,
		target_nref = ParentNref, reciprocal = ?ARC_ATTR_CHILD, avps = []
	},
	RevP2C = #relationship{
		id = Id3, kind = taxonomy,
		source_nref = ParentNref, characterization = ?ARC_ATTR_CHILD,
		target_nref = RevNref, reciprocal = ?ARC_ATTR_PARENT, avps = []
	},
	RevC2P = #relationship{
		id = Id4, kind = taxonomy,
		source_nref = RevNref, characterization = ?ARC_ATTR_PARENT,
		target_nref = ParentNref, reciprocal = ?ARC_ATTR_CHILD, avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, FwdNode, write),
		ok = mnesia:write(nodes, RevNode, write),
		ok = mnesia:write(relationships, FwdP2C, write),
		ok = mnesia:write(relationships, FwdC2P, write),
		ok = mnesia:write(relationships, RevP2C, write),
		ok = mnesia:write(relationships, RevC2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, {FwdNref, RevNref}};
		{aborted, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 6: Add the shared `validate_parent/1` helper**

Add this near the other private helpers (e.g. directly after
`do_create_relationship_attribute_pair/4`):

```erlang
%%-----------------------------------------------------------------------------
%% validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Confirms ParentNref names an existing kind=attribute node.  Run
%% inside the gen_server before any write so a bad parent consumes no
%% nref or relationship id.  Subtree membership is intentionally NOT
%% checked -- any attribute-kind parent is accepted, keeping the
%% creator decoupled from the scaffold's exact shape.
%%-----------------------------------------------------------------------------
validate_parent(ParentNref) ->
	case mnesia:dirty_read(nodes, ParentNref) of
		[#node{kind = attribute}] -> ok;
		[#node{kind = K}]         -> {error, {parent_not_attribute, K}};
		[]                        -> {error, {parent_not_found, ParentNref}}
	end.
```

- [ ] **Step 7: Run the suite to verify the new tests pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: PASS, including the two new cases. The existing
`create_relationship_attribute_pair` and
`create_relationship_attribute_pair_atomic` (which call `/3`) still pass —
`/3` now delegates to `/4` with the default parent.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "L8: add create_relationship_attribute_pair/4 + validate_parent"
```

---

## Task 3: General single-node creator `create_value_attribute/4` + wrappers

Introduce the canonical single-node creator and re-point
`create_name_attribute`, `create_literal_attribute`, and
`create_relationship_type` through it. Add the new `/2` parent arities for
name and relationship-type. Collapse the three per-type handle_call
clauses into one.

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl`
- Test: `apps/graphdb/test/graphdb_attr_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add these CT cases to `graphdb_attr_SUITE.erl` (next to the other creator
cases):

```erlang
%%-----------------------------------------------------------------------------
%% create_value_attribute/4 files a single attribute node under an
%% explicit parent and stamps the attribute_type AVP.
%%-----------------------------------------------------------------------------
create_value_attribute_under_parent(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, #{attribute_type := At}} = graphdb_attr:seeded_nrefs(),
	{ok, Nref} =
		graphdb_attr:create_value_attribute("CatName", name, [],
			?NREF_CAT_NAME_ATTRS),
	{ok, Node} = graphdb_attr:get_attribute(Nref),
	?assertEqual([?NREF_CAT_NAME_ATTRS], Node#node.parents),
	?assert(lists:member(#{attribute => ?NAME_ATTR_ATTRIBUTE, value => "CatName"},
		Node#node.attribute_value_pairs)),
	?assert(lists:member(#{attribute => At, value => name},
		Node#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% A literal carries exactly one type arg; name/relationship carry none.
%% Wrong TypeArgs for a known AttrType is bad_type_args; an unknown
%% AttrType is bad_attribute_type.  Neither writes a node.
%%-----------------------------------------------------------------------------
create_value_attribute_bad_args(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	NodesBefore = mnesia:table_info(nodes, size),
	?assertMatch({error, {bad_type_args, name, [junk]}},
		graphdb_attr:create_value_attribute("X", name, [junk], ?NREF_NAMES)),
	?assertMatch({error, {bad_type_args, literal, []}},
		graphdb_attr:create_value_attribute("X", literal, [], ?NREF_LITERALS)),
	?assertMatch({error, {bad_attribute_type, frob}},
		graphdb_attr:create_value_attribute("X", frob, [], ?NREF_NAMES)),
	?assertEqual(NodesBefore, mnesia:table_info(nodes, size)).

%%-----------------------------------------------------------------------------
%% create_name_attribute/2 and create_relationship_type/2 honour an
%% explicit parent; the /1 wrappers still default to 6 and 8.
%%-----------------------------------------------------------------------------
named_wrappers_take_explicit_parent(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, NameNref} =
		graphdb_attr:create_name_attribute("ClsName", ?NREF_CLS_NAME_ATTRS),
	{ok, NameNode} = graphdb_attr:get_attribute(NameNref),
	?assertEqual([?NREF_CLS_NAME_ATTRS], NameNode#node.parents),
	{ok, GrpNref} =
		graphdb_attr:create_relationship_type("Kinship", ?NREF_INST_REL_ATTRS),
	{ok, GrpNode} = graphdb_attr:get_attribute(GrpNref),
	?assertEqual([?NREF_INST_REL_ATTRS], GrpNode#node.parents).

%%-----------------------------------------------------------------------------
%% Back-compat: the original wrappers still default to 6 / 7 / 8.
%%-----------------------------------------------------------------------------
default_wrappers_preserve_parents(_Config) ->
	{ok, _} = graphdb_attr:start_link(),
	{ok, N6} = graphdb_attr:create_name_attribute("Plain"),
	{ok, N7} = graphdb_attr:create_literal_attribute("Mass", kilogram),
	{ok, N8} = graphdb_attr:create_relationship_type("Assoc"),
	{ok, Node6} = graphdb_attr:get_attribute(N6),
	{ok, Node7} = graphdb_attr:get_attribute(N7),
	{ok, Node8} = graphdb_attr:get_attribute(N8),
	?assertEqual([?NREF_NAMES],         Node6#node.parents),
	?assertEqual([?NREF_LITERALS],      Node7#node.parents),
	?assertEqual([?NREF_RELATIONSHIPS], Node8#node.parents).
```

Register the four cases in the test `-export([...])` block and the
`creators` group list (alongside the Task 2 entries):

```erlang
	create_value_attribute_under_parent/1,
	create_value_attribute_bad_args/1,
	named_wrappers_take_explicit_parent/1,
	default_wrappers_preserve_parents/1,
```

```erlang
			create_value_attribute_under_parent,
			create_value_attribute_bad_args,
			named_wrappers_take_explicit_parent,
			default_wrappers_preserve_parents,
```

`?NREF_CLS_NAME_ATTRS` (=11) is defined in `graphdb_nrefs.hrl`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: FAIL — `create_value_attribute/4`, `create_name_attribute/2`,
and `create_relationship_type/2` are undefined (`undef`).

- [ ] **Step 3: Add the general creator and re-point the wrappers**

In `graphdb_attr.erl`, replace the existing `create_name_attribute/1`,
`create_literal_attribute/2`, `create_literal_attribute/3`, and
`create_relationship_type/1` public functions with the wrappers plus the
new general creator and `/2` arities:

```erlang
%%-----------------------------------------------------------------------------
%% create_value_attribute(Name, AttrType, TypeArgs, ParentNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Canonical single-node attribute creator.  AttrType is one of
%% name | literal | relationship.  TypeArgs is interpreted per AttrType:
%% [] for name and relationship; [LiteralType] for literal (the literal
%% value-type atom, stamped under the seeded `literal_type` attribute).
%% ParentNref must name an existing kind=attribute node.
%%-----------------------------------------------------------------------------
create_value_attribute(Name, AttrType, TypeArgs, ParentNref) ->
	gen_server:call(?MODULE,
		{create_value_attribute, Name, AttrType, TypeArgs, ParentNref}).

%%-----------------------------------------------------------------------------
%% create_name_attribute(Name)            -> default parent ?NREF_NAMES (6)
%% create_name_attribute(Name, ParentNref)
%%-----------------------------------------------------------------------------
create_name_attribute(Name) ->
	create_value_attribute(Name, name, [], ?NREF_NAMES).

create_name_attribute(Name, ParentNref) ->
	create_value_attribute(Name, name, [], ParentNref).

%%-----------------------------------------------------------------------------
%% create_literal_attribute(Name, Type)             -> default ?NREF_LITERALS (7)
%% create_literal_attribute(Name, Type, ParentNref)
%%-----------------------------------------------------------------------------
create_literal_attribute(Name, Type) ->
	create_value_attribute(Name, literal, [Type], ?NREF_LITERALS).

create_literal_attribute(Name, Type, ParentNref) ->
	create_value_attribute(Name, literal, [Type], ParentNref).

%%-----------------------------------------------------------------------------
%% create_relationship_type(Name)            -> default ?NREF_RELATIONSHIPS (8)
%% create_relationship_type(Name, ParentNref) -- grouping/bucket node
%%-----------------------------------------------------------------------------
create_relationship_type(Name) ->
	create_value_attribute(Name, relationship, [], ?NREF_RELATIONSHIPS).

create_relationship_type(Name, ParentNref) ->
	create_value_attribute(Name, relationship, [], ParentNref).
```

Update the `-export([...])` block — replace the four old creator entries
with:

```erlang
		create_value_attribute/4,
		create_name_attribute/1,
		create_name_attribute/2,
		create_literal_attribute/2,
		create_literal_attribute/3,
		create_relationship_type/1,
		create_relationship_type/2,
```

(Leave the two `create_relationship_attribute_pair/3,4` export entries from
Task 2 in place.)

- [ ] **Step 4: Replace the three single-node handle_call clauses with one**

Delete the three handlers `{create_name_attribute, Name}`,
`{create_literal_attribute, Name, Type, ParentNref}`, and
`{create_relationship_type, Name}` (around lines 351-374), and add a single
clause:

```erlang
handle_call({create_value_attribute, Name, AttrType, TypeArgs, ParentNref},
		_From, State) ->
	Reply = case validate_parent(ParentNref) of
		ok ->
			do_create_value_attribute(Name, AttrType, TypeArgs, ParentNref,
				State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
```

- [ ] **Step 5: Add the `do_create_value_attribute/5` dispatch helper**

Add near `do_create_attribute/3`:

```erlang
%%-----------------------------------------------------------------------------
%% do_create_value_attribute(Name, AttrType, TypeArgs, ParentNref, State) ->
%%     {ok, Nref} | {error, term()}
%%
%% Builds the attribute_type AVP (and, for literals, the literal_type
%% AVP) from gen_server state, then writes one attribute node + taxonomy
%% arc pair via do_create_attribute/3.  Clause heads enforce the
%% TypeArgs contract: [] for name|relationship, [LiteralType] for
%% literal.  Malformed args / unknown types are rejected without a write.
%%-----------------------------------------------------------------------------
do_create_value_attribute(Name, name, [], ParentNref, State) ->
	Extra = [attr_type_avp(name, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(Name, relationship, [], ParentNref, State) ->
	Extra = [attr_type_avp(relationship, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(Name, literal, [LiteralType], ParentNref,
		#state{literal_type_nref = LtAttr} = State) ->
	Extra = [#{attribute => LtAttr, value => LiteralType},
			 attr_type_avp(literal, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(_Name, AttrType, TypeArgs, _ParentNref, _State)
		when AttrType =:= name; AttrType =:= literal;
			 AttrType =:= relationship ->
	{error, {bad_type_args, AttrType, TypeArgs}};
do_create_value_attribute(_Name, AttrType, _TypeArgs, _ParentNref, _State) ->
	{error, {bad_attribute_type, AttrType}}.
```

- [ ] **Step 6: Run the suite to verify the new tests pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE`
Expected: PASS. The M8 attribute-type cases
(`create_name_stamps_attribute_type`, `create_literal_stamps_attribute_type`,
`create_relationship_type_stamps_attribute_type`, etc.) still pass — the
wrappers route through `do_create_value_attribute/5`, which stamps the
same `attribute_type` AVP.

- [ ] **Step 7: Run the full CT + EUnit suite**

Run: `./rebar3 ct && ./rebar3 eunit`
Expected: all PASS, zero warnings. (The seed path in `init/1` is
unaffected — it uses `ensure_seed/2` → `do_create_attribute/3` directly,
not the public creators.)

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "L8: add create_value_attribute/4 + parent-aware name/literal/rel-type wrappers"
```

---

## Task 4: Documentation + task tracking

No code change. Update the docs the design names and the OpenWolf logs.

**Files:**
- Modify: `apps/graphdb/CLAUDE.md`, `ARCHITECTURE.md`, `TASKS.md`,
  `docs/designs/f4-graphdb-rules-design.md`, `.wolf/anatomy.md`,
  `.wolf/memory.md`

- [ ] **Step 1: Update `apps/graphdb/CLAUDE.md` — `graphdb_attr` API list**

In the `### graphdb_attr — Attribute Library` section, replace the bullet
list of creators with:

```markdown
- `create_value_attribute/4` (name, attr_type, type_args, parent_nref) — canonical single-node creator; `attr_type :: name | literal | relationship`, `type_args` = `[]` for name/relationship, `[LiteralType]` for literal
- `create_name_attribute/1,2` (name [, parent_nref]) — defaults parent to nref 6 (Names)
- `create_literal_attribute/2,3` (name, type [, parent_nref]) — defaults parent to nref 7 (Literals)
- `create_relationship_type/1,2` (name [, parent_nref]) — single-node grouping; defaults parent to nref 8 (Relationships)
- `create_relationship_attribute_pair/3,4` (name, reciprocal_name, target_kind [, parent_nref]) — reciprocal arc-label pair; `target_kind :: category | attribute | class | instance`; defaults parent to nref 8
- All creators validate `parent_nref` (must be an existing `kind=attribute` node)
- `get_attribute/1`, `list_attributes/0`, `list_relationship_types/0`
```

- [ ] **Step 2: Update `ARCHITECTURE.md` — `graphdb_attr` worker line**

Locate the `graphdb_attr` worker description (search the file for
`graphdb_attr`). Add or fold in this sentence so the public-API contract
is current — keep it at architectural altitude, no implementation detail:

```markdown
Every `graphdb_attr` creator takes an explicit, validated `ParentNref`
(must name an existing `kind=attribute` node); the named functions
(`create_name_attribute`, `create_literal_attribute`,
`create_relationship_type`, `create_relationship_attribute_pair`) are thin
wrappers over the canonical `create_value_attribute/4` (single node) and
`create_relationship_attribute_pair/4` (reciprocal pair), defaulting the
parent to the appropriate scaffold subtree (6/7/8) when omitted.
```

If a now-stale `create_relationship_attribute` reference appears anywhere
in the file, rename it to `create_relationship_attribute_pair`.

- [ ] **Step 3: Add the L8 entry to `TASKS.md` (Engineering Hygiene)**

Add, in the Engineering Hygiene section (after the L7 entry):

```markdown
### L8. Generalize `graphdb_attr` attribute placement — **RESOLVED** (2026-05-31)

Parent nref is now a first-class, validated argument on every
`graphdb_attr` creator. Canonical general creators
`create_value_attribute/4` (single node) and
`create_relationship_attribute_pair/4` (reciprocal pair) back thin named
wrappers that preserve the default parents (6/7/8). `validate_parent/1`
rejects a non-existent or non-`attribute` parent before any write.
`create_relationship_attribute` renamed to
`create_relationship_attribute_pair`. Design at
`docs/designs/l8-graphdb-attr-placement-design.md`. Removes the F4 §10.1
P1 placement blocker by construction.
```

- [ ] **Step 4: Annotate F4 §10.1 P1 as unblocked**

In `docs/designs/f4-graphdb-rules-design.md`, append to the P1 **Status:**
paragraph (around line 683):

```markdown
**Update (2026-05-31, L8):** The placement blocker is removed by
construction. `create_relationship_attribute_pair/4` now files the
`applies_to` / `applied_by` pair under any attribute parent, e.g.
`?NREF_INST_REL_ATTRS` (16). The remaining choice of exact parent
(nref 16 vs a Rule sub-bucket) stays a Phase-A seeding decision; the
"would require an API extension" tension is gone.
```

- [ ] **Step 5: Update OpenWolf bookkeeping**

Append one line to `.wolf/memory.md`:

```
| HH:MM | L8 implemented: parent-aware graphdb_attr creators + create_relationship_attribute_pair rename + validate_parent | graphdb_attr.erl, *_SUITE.erl, docs | all green | ~N |
```

`apps/graphdb/src/graphdb_attr.erl` is already in `.wolf/anatomy.md`; no
new files were created, so anatomy.md needs no new entry. If its
description is stale, refresh the `graphdb_attr.erl` line to note the
parent-aware creator API.

- [ ] **Step 6: Final full-suite run**

Run: `./rebar3 compile && ./rebar3 ct && ./rebar3 eunit`
Expected: clean compile (zero warnings), all CT and EUnit PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/CLAUDE.md ARCHITECTURE.md TASKS.md \
        docs/designs/f4-graphdb-rules-design.md .wolf/memory.md .wolf/anatomy.md
git commit -m "L8: docs + TASKS.md (RESOLVED) + F4 P1 unblock note"
```

---

## Definition of Done

- `./rebar3 compile` is warning-free.
- `./rebar3 ct` and `./rebar3 eunit` are fully green, with the new
  `graphdb_attr_SUITE` cases (`create_relationship_attribute_pair_under_parent`,
  `create_relationship_attribute_pair_bad_parent`,
  `create_value_attribute_under_parent`, `create_value_attribute_bad_args`,
  `named_wrappers_take_explicit_parent`, `default_wrappers_preserve_parents`)
  passing.
- `create_relationship_attribute` no longer exists; all callers use
  `create_relationship_attribute_pair`.
- Every `graphdb_attr` creator accepts and validates an explicit
  `ParentNref`; named wrappers preserve the 6/7/8 defaults.
- Docs (`apps/graphdb/CLAUDE.md`, `ARCHITECTURE.md`, `TASKS.md`,
  F4 design §10.1) updated; L8 marked RESOLVED.
