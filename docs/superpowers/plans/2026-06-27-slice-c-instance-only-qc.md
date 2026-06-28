<!--
Copyright (c) 2026 David W. Thomas
SPDX-License-Identifier: GPL-2.0-or-later
-->

# Slice C — Instance-Only Qualifying Characteristics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a class declare a qualifying characteristic (QC) as
*instance-only* — relevant to the class but illegal to bind a value at the
class level — and reject every class-level value-bind on a marked attribute.

**Architecture:** The marker is a boolean key `instance_only => true`
colocated on the class node's QC AVP map. It is set by a new
`add_qualifying_characteristic/3` (or in a `create_class/3` initial AVP
list) and enforced at three class-level value-binding gates:
`bind_qc_value/3`, `create_class/3`, and `update_node_avps/2` (the last
covers `mutate/1` for free, since both compose `update_node_avps_in_txn/3`).
Enforcement is local to the class node being written — no cross-node or
inheritance walk. Three deferred follow-ons (template attribute list,
template-bound variant values, inherited enforcement) are recorded in
`TASKS.md`.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (repo-local `./rebar3`),
Mnesia, Common Test, EUnit.

**Design:** `docs/designs/slice-c-instance-only-qc-design.md`

## Global Constraints

- **Hard tabs** for all indentation in every `apps/graphdb/` source and test
  file. Never spaces.
- **Error shape** is the bare reason `{error, {instance_only_attribute,
  AttrNref}}` at all three gates. Reject-path tests assert the **full
  tuple**, never just the tag.
- The marker is **never** settable through `update_node_avps`/`mutate`: slice
  B's `validate_avp_updates/1` already rejects any update map whose key-set
  is not exactly `[attribute]` or `[attribute, value]`, so an
  `instance_only` key in an update map is rejected as an extra key. Do not
  loosen `validate_avp_updates/1`.
- Build: `./rebar3 compile` (plain, no `source ~/.bashrc &&` prefix).
- Run EUnit: `./rebar3 eunit --module <module>`.
- Run one CT suite: `./rebar3 ct --suite apps/graphdb/test/<suite>`.
- Pure EUnit-tested helpers are exported under the `-ifdef(TEST).` block,
  not the public export list (match the existing convention in each module).
- Commit message trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF
  ```

---

## File Structure

| File                                          | Change                                                                 |
|-----------------------------------------------|------------------------------------------------------------------------|
| `apps/graphdb/src/graphdb_class.erl`          | `is_instance_only/1`, `validate_instance_only_avps/1`, `is_qc_instance_only/2`; `add_qualifying_characteristic/3` + `do_add_qc/3` + `new_qc_avp/2`; gates in `do_create_class` and `do_bind_qc_value` |
| `apps/graphdb/src/graphdb_mgr.erl`            | `check_instance_only/2` (pure) + `guard_instance_only/2`; wire into `update_node_avps_in_txn/3` |
| `apps/graphdb/test/graphdb_class_tests.erl`   | EUnit for `is_instance_only/1`, `validate_instance_only_avps/1`         |
| `apps/graphdb/test/graphdb_class_SUITE.erl`   | CT for `add_qualifying_characteristic/3`, `create_class/3` gate, `bind_qc_value/3` gate |
| `apps/graphdb/test/graphdb_mgr_tests.erl`     | EUnit for `check_instance_only/2`                                       |
| `apps/graphdb/test/graphdb_mgr_SUITE.erl`     | CT for `update_node_avps`/`mutate` gate                                 |
| `TASKS.md`                                     | Mark instance-only enforcement IMPLEMENTED; carve out 3 deferred items |
| `apps/graphdb/CLAUDE.md`                       | Add `add_qualifying_characteristic/3` to the class API list            |

No `docs/Architecture.md` change (it documents no QC-binding contract —
verified) and no `docs/diagrams/ontology-tree.md` change (slice C seeds no
new nodes).

---

### Task 1: Pure predicates in `graphdb_class`

Two pure helpers, no behaviour wiring yet. They feed Tasks 3, 4, and 5.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (add helpers near
  `collect_qc_avps/1` ~line 1182; add both to the `-ifdef(TEST).` export
  block at lines 154-158)
- Test: `apps/graphdb/test/graphdb_class_tests.erl`

**Interfaces:**
- Produces:
  - `is_instance_only(QcMap :: map()) -> boolean()` — true iff the map
    carries `instance_only => true`.
  - `validate_instance_only_avps(AVPs :: [map()]) -> ok | {error,
    {instance_only_attribute, integer()}}` — rejects the first entry that is
    both `instance_only => true` and `value =/= undefined`.

- [ ] **Step 1: Write the failing EUnit tests**

Append to `apps/graphdb/test/graphdb_class_tests.erl`:

```erlang
%%=============================================================================
%% is_instance_only/1 tests
%%=============================================================================

is_instance_only_true_test() ->
	?assert(graphdb_class:is_instance_only(
		#{attribute => 42, value => undefined, instance_only => true})).

is_instance_only_absent_key_test() ->
	?assertNot(graphdb_class:is_instance_only(
		#{attribute => 42, value => undefined})).

is_instance_only_false_value_test() ->
	?assertNot(graphdb_class:is_instance_only(
		#{attribute => 42, value => undefined, instance_only => false})).

%%=============================================================================
%% validate_instance_only_avps/1 tests
%%=============================================================================

validate_instance_only_avps_empty_test() ->
	?assertEqual(ok, graphdb_class:validate_instance_only_avps([])).

validate_instance_only_avps_unbound_ok_test() ->
	%% instance_only declared but unbound is legal at the class level.
	?assertEqual(ok, graphdb_class:validate_instance_only_avps(
		[#{attribute => 42, value => undefined, instance_only => true}])).

validate_instance_only_avps_non_flagged_value_ok_test() ->
	%% A normal class-bound value is legal.
	?assertEqual(ok, graphdb_class:validate_instance_only_avps(
		[#{attribute => 42, value => "red"}])).

validate_instance_only_avps_rejects_flagged_value_test() ->
	?assertEqual({error, {instance_only_attribute, 42}},
		graphdb_class:validate_instance_only_avps(
			[#{attribute => 42, value => "red", instance_only => true}])).
```

- [ ] **Step 2: Run them, verify failure**

Run: `./rebar3 eunit --module graphdb_class_tests`
Expected: FAIL — `is_instance_only/1` / `validate_instance_only_avps/1`
undefined (function not exported / does not exist).

- [ ] **Step 3: Add the helpers and exports**

In `apps/graphdb/src/graphdb_class.erl`, extend the `-ifdef(TEST).` export
block (currently lines 154-158):

```erlang
-ifdef(TEST).
-export([
		is_valid_parent_kind/1,
		collect_qc_avps/1,
		is_instance_only/1,
		validate_instance_only_avps/1
		]).
-endif.
```

Add the two functions in the internal-functions region (next to
`collect_qc_avps/1`):

```erlang
%%-----------------------------------------------------------------------------
%% is_instance_only(QcMap) -> boolean()
%%
%% True iff a qualifying-characteristic AVP map carries the
%% `instance_only => true` marker. Pure; consumed by the bind_qc_value
%% and create_class enforcement gates.
%%-----------------------------------------------------------------------------
is_instance_only(#{instance_only := true}) -> true;
is_instance_only(_)                        -> false.


%%-----------------------------------------------------------------------------
%% validate_instance_only_avps(AVPs) ->
%%     ok | {error, {instance_only_attribute, integer()}}
%%
%% Rejects an initial create_class AVP list in which any entry is both
%% marked `instance_only => true` AND carries a concrete (non-undefined)
%% value. An instance-only QC declared unbound (value => undefined) is
%% accepted. Pure; returns the first offending attribute nref.
%%-----------------------------------------------------------------------------
validate_instance_only_avps(AVPs) ->
	case [A || #{attribute := A, value := V} = E <- AVPs,
		V =/= undefined, is_instance_only(E)] of
		[]      -> ok;
		[A | _] -> {error, {instance_only_attribute, A}}
	end.
```

- [ ] **Step 4: Run the tests, verify pass**

Run: `./rebar3 eunit --module graphdb_class_tests`
Expected: PASS (all, including the pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_tests.erl
git commit -m "Slice C: instance-only QC pure predicates"
```

---

### Task 2: `add_qualifying_characteristic/3` — set the marker

Adds the flag-setting API. The existing `/2` stays the unflagged declare and
is refactored to delegate to a new `/3` internal worker.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (public export ~line 114;
  public fn ~line 233; `handle_call` ~line 371; `do_add_qc` ~line 977)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `add_qualifying_characteristic(ClassNref, AttrNref, Opts :: map()) -> ok
    | {error, term()}` — `Opts = #{instance_only => true}` stamps the
    marker; any other `Opts` behaves like `/2`.
  - Stored marked QC shape on the class node:
    `#{attribute => AttrNref, value => undefined, instance_only => true}`.

**Idempotency contract (load-bearing — do not "fix"):** `do_add_qc` returns
`already_exists -> ok` when ANY entry for `AttrNref` already exists. So
calling `/3` with `instance_only` on an already-declared, **unflagged** QC is
a silent no-op — it does **not** upgrade the existing entry. This is
deliberate and consistent with the existing `/2` idempotency contract;
Step 1 includes a test pinning it.

- [ ] **Step 1: Write the failing CT tests**

In `apps/graphdb/test/graphdb_class_SUITE.erl`, add these clause names to
the test list in both the `-export([...])` testcase block (~lines 61-110)
and the corresponding `groups()` list (~lines 153-204), beside the existing
`bind_qc_value_*` entries:

```
		add_qc_3_stamps_instance_only_marker,
		add_qc_3_idempotent_does_not_upgrade,
```

Add the test bodies (place them beside `bind_qc_value_basic`; follow its
setup idiom — call `graphdb_class:start_link()` at the top, `init_per_testcase`
brings up the rest):

```erlang
%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic/3 with #{instance_only => true} stamps the
%% marker onto the class node's QC AVP.
%%-----------------------------------------------------------------------------
add_qc_3_stamps_instance_only_marker(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
	{ok, AttrN} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN,
		#{instance_only => true}),
	{ok, Node} = graphdb_class:get_class(Veh),
	?assert(lists:member(
		#{attribute => AttrN, value => undefined, instance_only => true},
		Node#node.attribute_value_pairs)).

%%-----------------------------------------------------------------------------
%% Idempotency: /3 with instance_only on an already-declared UNFLAGGED QC is
%% a no-op — it returns ok but does NOT upgrade the stored entry.
%%-----------------------------------------------------------------------------
add_qc_3_idempotent_does_not_upgrade(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
	{ok, AttrN} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN),
	ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN,
		#{instance_only => true}),
	{ok, Node} = graphdb_class:get_class(Veh),
	%% The original unflagged entry is preserved; no marked variant appears.
	?assert(lists:member(#{attribute => AttrN, value => undefined},
		Node#node.attribute_value_pairs)),
	?assertNot(lists:member(
		#{attribute => AttrN, value => undefined, instance_only => true},
		Node#node.attribute_value_pairs)).
```

- [ ] **Step 2: Run them, verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: FAIL — `add_qualifying_characteristic/3` undefined.

- [ ] **Step 3: Add export, public fn, handler, and `/3` worker**

In the public `-export([...])` list, add `add_qualifying_characteristic/3`
beside the `/2`:

```erlang
		add_qualifying_characteristic/2,
		add_qualifying_characteristic/3,
```

Add the public function after the existing `/2` clause (~line 233):

```erlang
add_qualifying_characteristic(ClassNref, AttrNref, Opts) when is_map(Opts) ->
	gen_server:call(?MODULE,
		{add_qualifying_characteristic, ClassNref, AttrNref, Opts}).
```

Add the `handle_call` clause after the existing `/2` clause (~line 371):

```erlang
handle_call({add_qualifying_characteristic, ClassNref, AttrNref, Opts}, _From,
		State) ->
	{reply, do_add_qc(ClassNref, AttrNref, Opts), State};
```

Refactor `do_add_qc/2` (~line 977) to delegate to a new `/3`, and add
`new_qc_avp/2`:

```erlang
do_add_qc(ClassNref, AttrNref) ->
	do_add_qc(ClassNref, AttrNref, #{}).

do_add_qc(ClassNref, AttrNref, Opts) ->
	Txn = fun() ->
		case mnesia:read(nodes, ClassNref) of
			[#node{kind = class, attribute_value_pairs = AVPs} = Node] ->
				case mnesia:read(nodes, AttrNref) of
					[#node{kind = attribute}] ->
						Already = lists:any(fun(#{attribute := A}) -> A =:= AttrNref;
									   (_)              -> false
									end, AVPs),
						case Already of
							true ->
								already_exists;
							false ->
								NewAVP = new_qc_avp(AttrNref, Opts),
								Updated = Node#node{
									attribute_value_pairs = AVPs ++ [NewAVP]
								},
								ok = mnesia:write(nodes, Updated, write),
								ok
						end;
					[#node{}] ->
						{error, {not_an_attribute, AttrNref}};
					[] ->
						{error, {attribute_not_found, AttrNref}}
				end;
			[#node{kind = Kind}] ->
				{error, {not_a_class, Kind}};
			[] ->
				{error, not_found}
		end
	end,
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{ok, {error, _} = E} -> E;
		{error, Reason}      -> {error, Reason}
	end.

%%-----------------------------------------------------------------------------
%% new_qc_avp(AttrNref, Opts) -> map()
%%
%% Builds the QC AVP for a fresh declaration. `instance_only => true` in
%% Opts stamps the marker onto the canonical declared-unbound shape;
%% otherwise the plain declared-unbound shape is returned.
%%-----------------------------------------------------------------------------
new_qc_avp(AttrNref, Opts) ->
	Base = #{attribute => AttrNref, value => undefined},
	case maps:get(instance_only, Opts, false) of
		true  -> Base#{instance_only => true};
		false -> Base
	end.
```

- [ ] **Step 4: Run the new CT tests, verify pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS (including the two new tests).

- [ ] **Step 5: Refactor regression — existing class tests stay green**

Confirms the `/2 → /3` collapse is behaviour-preserving (empty `Opts`
produces exactly `#{attribute => A, value => undefined}`, no
`instance_only` key).

Run: `./rebar3 eunit --module graphdb_class_tests`
Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS, both, with no regressions.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "Slice C: add_qualifying_characteristic/3 stamps instance-only marker"
```

---

### Task 3: `create_class/3` enforcement gate

Reject an initial AVP list carrying an `instance_only => true` entry with a
concrete value.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (`do_create_class/4` ~line 471)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

**Interfaces:**
- Consumes: `validate_instance_only_avps/1` (Task 1).
- Produces: `create_class/3` returns `{error, {instance_only_attribute,
  AttrNref}}` when an initial AVP is instance-only with a concrete value.

- [ ] **Step 1: Write the failing CT tests**

Add the names to the testcase `-export` block and `groups()` list (beside
`create_class_3_writes_avps`):

```
		create_class_3_rejects_instance_only_with_value,
		create_class_3_accepts_instance_only_unbound,
```

Add the bodies beside `create_class_3_writes_avps`:

```erlang
%%-----------------------------------------------------------------------------
%% create_class/3 rejects an initial AVP that is instance_only AND bound.
%%-----------------------------------------------------------------------------
create_class_3_rejects_instance_only_with_value(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AttrN} = graphdb_attr:create_literal_attribute("serial", string),
	Bad = #{attribute => AttrN, value => "SN-1", instance_only => true},
	?assertEqual({error, {instance_only_attribute, AttrN}},
		graphdb_class:create_class("Bad", 3, [Bad])).

%%-----------------------------------------------------------------------------
%% create_class/3 accepts an instance_only QC declared unbound.
%%-----------------------------------------------------------------------------
create_class_3_accepts_instance_only_unbound(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, AttrN} = graphdb_attr:create_literal_attribute("serial", string),
	Good = #{attribute => AttrN, value => undefined, instance_only => true},
	{ok, ClassNref} = graphdb_class:create_class("Good", 3, [Good]),
	{ok, Node} = graphdb_class:get_class(ClassNref),
	?assert(lists:member(Good, Node#node.attribute_value_pairs)).
```

- [ ] **Step 2: Run them, verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: FAIL — the reject test gets `{ok, _}` instead of the error tuple.

- [ ] **Step 3: Wire the gate into `do_create_class`**

Wrap the existing body of `do_create_class/4` (~line 471) so the AVP
validation runs first:

```erlang
do_create_class(Name, ParentClassNref, AVPs, InstAttr) ->
	case validate_instance_only_avps(AVPs) of
		{error, _} = Err ->
			Err;
		ok ->
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
					case graphdb_mgr:transaction(Txn) of
						{ok, _Writes}    -> {ok, ClassNref};
						{error, _} = Err -> Err
					end;
				{error, _} = Err ->
					Err
			end
	end.
```

(Only the outer `case validate_instance_only_avps(AVPs) of ... ok ->` wrap
and its closing `end` are new; the inner body is unchanged from the current
`do_validate_parent` arm.)

- [ ] **Step 4: Run the CT tests, verify pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS (both new tests, plus the existing `create_class_3_*` tests).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "Slice C: create_class/3 rejects bound instance-only QC"
```

---

### Task 4: `bind_qc_value/3` enforcement gate

Reject a class-level value bind on a QC marked instance-only.

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl` (`do_bind_qc_value/3`
  ~line 1025; add `is_qc_instance_only/2` helper)
- Test: `apps/graphdb/test/graphdb_class_SUITE.erl`

**Interfaces:**
- Consumes: `is_instance_only/1` (Task 1), `add_qualifying_characteristic/3`
  (Task 2).
- Produces: `bind_qc_value/3` returns `{error, {instance_only_attribute,
  AttrNref}}` when the target QC is marked instance-only.

The happy path on a non-marked QC is already covered by the existing
`bind_qc_value_basic` test — no new happy-path test is needed.

- [ ] **Step 1: Write the failing CT test**

Add the name to the testcase `-export` block and `groups()` list (beside
`bind_qc_value_basic`):

```
		bind_qc_value_rejects_instance_only,
```

Add the body beside `bind_qc_value_basic`:

```erlang
%%-----------------------------------------------------------------------------
%% bind_qc_value/3 refuses to bind a value on an instance-only QC, and the
%% transaction abort leaves the QC unbound.
%%-----------------------------------------------------------------------------
bind_qc_value_rejects_instance_only(_Config) ->
	{ok, _} = graphdb_class:start_link(),
	{ok, Veh}   = graphdb_class:create_class("Vehicle", ?NREF_CLASSES),
	{ok, AttrN} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(Veh, AttrN,
		#{instance_only => true}),
	?assertEqual({error, {instance_only_attribute, AttrN}},
		graphdb_class:bind_qc_value(Veh, AttrN, "SN-1")),
	%% Abort rolled back the write: the QC is still declared, still unbound.
	{ok, QCs} = graphdb_class:inherited_qcs(Veh),
	?assert(lists:member({AttrN, undefined}, QCs)).
```

- [ ] **Step 2: Run it, verify failure**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: FAIL — `bind_qc_value/3` binds the value and returns `ok`.

- [ ] **Step 3: Add the guard to `do_bind_qc_value`**

In `do_bind_qc_value/3` (~line 1025), replace the `true ->` arm of the
`case Declared of` with an instance-only check:

```erlang
					case Declared of
						false ->
							mnesia:abort(qc_not_declared);
						true ->
							case is_qc_instance_only(AVPs, AttrNref) of
								true ->
									mnesia:abort(
										{instance_only_attribute, AttrNref});
								false ->
									NewAVPs = update_qc_value(AVPs, AttrNref,
										Value),
									mnesia:write(nodes,
										N#node{attribute_value_pairs = NewAVPs},
										write)
							end
					end;
```

Add the helper next to `update_qc_value/3` (~line 1058):

```erlang
%%-----------------------------------------------------------------------------
%% is_qc_instance_only(AVPs, AttrNref) -> boolean()
%%
%% True iff the QC entry for AttrNref in AVPs carries the instance_only
%% marker. Caller has already verified AttrNref is present.
%%-----------------------------------------------------------------------------
is_qc_instance_only(AVPs, AttrNref) ->
	lists:any(fun(#{attribute := A} = E) when A =:= AttrNref ->
				 is_instance_only(E);
			 (_) -> false
		  end, AVPs).
```

(`do_bind_qc_value/3` already maps `{error, _} = Err -> Err`, and
`graphdb_mgr:transaction/1` maps `{aborted, R} -> {error, R}`, so the abort
surfaces as `{error, {instance_only_attribute, AttrNref}}`.)

- [ ] **Step 4: Run the CT tests, verify pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE`
Expected: PASS (new reject test plus existing `bind_qc_value_*`).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_class.erl apps/graphdb/test/graphdb_class_SUITE.erl
git commit -m "Slice C: bind_qc_value/3 rejects instance-only QC"
```

---

### Task 5: `update_node_avps` / `mutate` enforcement gate

Reject a value-bearing update targeting a stored entry marked instance-only.
Both the tier-2 solo path (`update_node_avps/2`) and the tier-3 batch path
(`mutate/1`) compose `update_node_avps_in_txn/3`, so guarding it once covers
both.

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (`update_node_avps_in_txn/3`
  ~line 752; add `check_instance_only/2` + `guard_instance_only/2`; export
  `check_instance_only/2` in the `-ifdef(TEST).` block at lines 149-155)
- Test: `apps/graphdb/test/graphdb_mgr_tests.erl` (EUnit),
  `apps/graphdb/test/graphdb_mgr_SUITE.erl` (CT)

**Interfaces:**
- Consumes: the stored marker shape from Task 2.
- Produces: `update_node_avps/2` and `mutate/1` return / abort with
  `{error, {instance_only_attribute, AttrNref}}` on a value-bearing update
  to a marked stored entry.
  - `check_instance_only(StoredAVPs :: [map()], Updates :: [map()]) -> ok |
    {error, {instance_only_attribute, integer()}}` (pure).

A value-bearing update is any update map carrying a `value` key — **including
`value => undefined`** — because slice B's `upsert_avp/3` rebuilds the entry
as `#{attribute => A, value => V}` and would silently strip the marker. A
delete (no `value` key) is permitted: removing the QC entirely is not a bind.

- [ ] **Step 1: Write the failing EUnit tests**

Append to `apps/graphdb/test/graphdb_mgr_tests.erl`:

```erlang
%% check_instance_only/2 tests (pure)

check_instance_only_rejects_value_bearing_test() ->
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42, value => "SN-1"}],
	?assertEqual({error, {instance_only_attribute, 42}},
		graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_rejects_undefined_value_test() ->
	%% value => undefined still carries a `value` key -> still a bind attempt.
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42, value => undefined}],
	?assertEqual({error, {instance_only_attribute, 42}},
		graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_allows_delete_test() ->
	Stored = [#{attribute => 42, value => undefined, instance_only => true}],
	Updates = [#{attribute => 42}],
	?assertEqual(ok, graphdb_mgr:check_instance_only(Stored, Updates)).

check_instance_only_allows_non_marked_test() ->
	Stored = [#{attribute => 42, value => undefined}],
	Updates = [#{attribute => 42, value => "red"}],
	?assertEqual(ok, graphdb_mgr:check_instance_only(Stored, Updates)).
```

- [ ] **Step 2: Run them, verify failure**

Run: `./rebar3 eunit --module graphdb_mgr_tests`
Expected: FAIL — `check_instance_only/2` undefined.

- [ ] **Step 3: Add the predicate, guard, export, and wiring**

Extend the `-ifdef(TEST).` export block (lines 149-155) to add
`check_instance_only/2`:

```erlang
-ifdef(TEST).
-export([
		validate_avp_updates/1,
		apply_avp_updates/2,
		check_instance_only/2
		]).
-endif.
```

Add the predicate and guard near `guard_attribute_existence/1` (~line 773):

```erlang
%%-----------------------------------------------------------------------------
%% check_instance_only(StoredAVPs, Updates) ->
%%     ok | {error, {instance_only_attribute, integer()}}
%%
%% Pure. A value-bearing update (one carrying a `value` key, including
%% value => undefined) targeting a stored entry marked
%% `instance_only => true` is rejected. Deletes (no `value` key) and
%% updates to non-marked attributes pass. Returns the first offender.
%%-----------------------------------------------------------------------------
check_instance_only(StoredAVPs, Updates) ->
	Marked = [A || #{attribute := A} = E <- StoredAVPs,
		maps:get(instance_only, E, false) =:= true],
	ValueBearing = [A || #{attribute := A} = M <- Updates,
		maps:is_key(value, M)],
	case [A || A <- ValueBearing, lists:member(A, Marked)] of
		[]      -> ok;
		[A | _] -> {error, {instance_only_attribute, A}}
	end.

%% In-txn guard: aborts on the first instance-only violation.
guard_instance_only(StoredAVPs, Updates) ->
	case check_instance_only(StoredAVPs, Updates) of
		ok                                        -> ok;
		{error, {instance_only_attribute, _} = R} -> mnesia:abort(R)
	end.
```

Wire the guard into `update_node_avps_in_txn/3` (~line 752), reusing the
already-read `Node`:

```erlang
update_node_avps_in_txn(Nref, AVPs, RetAttr) ->
	case mnesia:read(nodes, Nref, write) of
		[] ->
			mnesia:abort(not_found);
		[Node] ->
			ok = guard_retired_marker(AVPs, RetAttr),
			ok = guard_instance_only(Node#node.attribute_value_pairs, AVPs),
			ok = guard_attribute_existence(AVPs),
			New = apply_avp_updates(Node#node.attribute_value_pairs, AVPs),
			mnesia:write(nodes, Node#node{attribute_value_pairs = New}, write)
	end.
```

- [ ] **Step 4: Run the EUnit tests, verify pass**

Run: `./rebar3 eunit --module graphdb_mgr_tests`
Expected: PASS.

- [ ] **Step 5: Write the failing CT tests**

In `apps/graphdb/test/graphdb_mgr_SUITE.erl`, add the three names to the
testcase `-export` block (~lines 116-127) and the `groups()` list
(~lines 212-228), beside the existing `update_node_avps_*` entries:

```
		update_node_avps_rejects_instance_only,
		update_node_avps_delete_instance_only_ok,
		mutate_rejects_instance_only,
```

**Critical:** also add all three names to the worker-starting
`init_per_testcase/2` guard list (the `when TC =:= ... ` chain at
~lines 273-312) so the suite starts `graphdb_class`/`graphdb_attr`/etc. for
them. Append them to that `;`-separated guard.

Add the bodies (follow the `mutate_single_update_node_avps` idiom):

```erlang
%%-----------------------------------------------------------------------------
%% update_node_avps/2 rejects a value-bearing update to a class node's
%% instance-only QC, and rolls the write back.
%%-----------------------------------------------------------------------------
update_node_avps_rejects_instance_only(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IOClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual({error, {instance_only_attribute, Attr}},
		graphdb_mgr:update_node_avps(ClassNref,
			[#{attribute => Attr, value => "SN-1"}])),
	%% Rollback: the QC stays declared-unbound, marker intact.
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:member(
		#{attribute => Attr, value => undefined, instance_only => true}, AVPs)).

%%-----------------------------------------------------------------------------
%% update_node_avps/2 permits DELETING an instance-only QC (no `value` key).
%%-----------------------------------------------------------------------------
update_node_avps_delete_instance_only_ok(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IODelClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual(ok,
		graphdb_mgr:update_node_avps(ClassNref, [#{attribute => Attr}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assertNot(lists:any(fun(#{attribute := A}) -> A =:= Attr;
				(_) -> false end, AVPs)).

%%-----------------------------------------------------------------------------
%% mutate/1 inherits the instance-only guard via update_node_avps_in_txn.
%%-----------------------------------------------------------------------------
mutate_rejects_instance_only(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("IOMutClass", 3),
	{ok, Attr} = graphdb_attr:create_literal_attribute("serial", string),
	ok = graphdb_class:add_qualifying_characteristic(ClassNref, Attr,
		#{instance_only => true}),
	?assertEqual({error, {instance_only_attribute, Attr}},
		graphdb_mgr:mutate([{update_node_avps, ClassNref,
			[#{attribute => Attr, value => "SN-1"}]}])),
	[#node{attribute_value_pairs = AVPs}] = mnesia:dirty_read(nodes, ClassNref),
	?assert(lists:member(
		#{attribute => Attr, value => undefined, instance_only => true}, AVPs)).
```

- [ ] **Step 6: Run the CT tests, verify failure then pass**

Run (after Step 5, before Step 3's wiring would have been done — but since
Step 3 is already in, expect PASS here):
`./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS (the three new tests plus all existing `update_node_avps_*`
and `mutate_*`). If you author Step 5 before Step 3, the new tests FAIL
first (writes succeed) — that is the TDD red.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_tests.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "Slice C: update_node_avps/mutate reject instance-only value bind"
```

---

### Task 6: Documentation

Record the deferred follow-ons in `TASKS.md` (an explicit pre-PR
requirement), mark the implemented enforcement, and add the new API to the
graphdb app guide.

**Files:**
- Modify: `TASKS.md` (slice C section, ~lines 284-306)
- Modify: `apps/graphdb/CLAUDE.md` (class API list)

- [ ] **Step 1: Rewrite the `TASKS.md` slice C section**

Replace the section starting `### Template attribute list and instance-only
enforcement (slice C, depends on slice B)` (~line 284) through its final
paragraph (ending `...stays `undefined` at every class level.`, ~line 306)
with:

```markdown
### Instance-only qualifying characteristics (slice C) — IMPLEMENTED

A class QC may be marked `instance_only => true`: the attribute is relevant
to instances, but binding a value at the class level is a category error.
Set via `graphdb_class:add_qualifying_characteristic/3` (`#{instance_only =>
true}`) or a `create_class/3` initial AVP. Enforced at three class-level
value-binding gates — `bind_qc_value/3`, `create_class/3`, and
`update_node_avps/2` (the last covers `mutate/1`, both composing
`update_node_avps_in_txn/3`) — each returning `{error,
{instance_only_attribute, AttrNref}}`. Enforcement is local to the class
node written. Design `docs/designs/slice-c-instance-only-qc-design.md`.

**Deferred follow-ons (from slice C):**

- **Template attribute list** — per-template subset/relevance scoping of
  class attributes (`TheKnowledgeNetwork.md` §7). A template currently
  carries only a name and its compositional arc into the owning class; there
  is no per-template list of which attributes it scopes. This is the
  per-class, per-template axis: the same attribute may be class-bindable in
  one class's template and instance-only in another's.
- **Template-bound (variant) values** — templates carrying override values
  stamped into instances at instantiation (e.g. a later custom-colour phone
  variant whose colour is fixed in a template, not on the base class).
- **Inherited instance-only enforcement (C2)** — close the subclass-redeclare
  bypass: a subclass can re-declare a parent's instance-only QC *without* the
  flag via `add_qualifying_characteristic/2`, then bind a value. Local gates
  do not consult the inherited QC set because `collect_qc_avps/1` flattens
  each QC to `{AttrNref, Value}`, dropping the marker. Closing it means
  carrying the flag through `collect_qc_avps/1` / `inherited_qcs/1` and
  having all three gates consult the effective (local + ancestor) QC set.
```

- [ ] **Step 2: Add the new API to `apps/graphdb/CLAUDE.md`**

In the `### graphdb_class — Taxonomic Hierarchy` API list, replace the
`add_qualifying_characteristic/2` line with:

```markdown
- `add_qualifying_characteristic/2,3` (class_nref, attribute_nref [, opts]) — the `/3` form takes an options map; `#{instance_only => true}` marks the QC instance-only (binding a class-level value for it is rejected at `bind_qc_value/3`, `create_class/3`, and `update_node_avps/2`)
```

- [ ] **Step 3: Verify the docs render and reference real paths**

Run: `grep -n "instance-only\|instance_only\|add_qualifying_characteristic/3" TASKS.md apps/graphdb/CLAUDE.md`
Expected: the new lines appear; the design-doc path resolves
(`ls docs/designs/slice-c-instance-only-qc-design.md`).

- [ ] **Step 4: Commit**

```bash
git add TASKS.md apps/graphdb/CLAUDE.md
git commit -m "Slice C: docs — mark enforcement implemented, record deferred follow-ons"
```

---

## Final Verification

After all tasks, run the full graphdb test set and confirm zero warnings:

Run: `./rebar3 compile`
Expected: clean, no warnings.

Run: `./rebar3 eunit --module graphdb_class_tests --module graphdb_mgr_tests`
Expected: PASS.

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE --suite apps/graphdb/test/graphdb_mgr_SUITE`
Expected: PASS, including the per-testcase `verify_caches/0` invariant.

Optionally run the fast full CT fan-out: `make test-ct-parallel`.

---

## Self-Review Notes

- **Spec coverage:** marker representation (Task 1 + 2), setting via `/3` and
  `create_class/3` (Task 2 + 3), three enforcement gates (Tasks 3/4/5),
  local-only C1 inheritance (no inherited walk added — by omission),
  deferred-items recording (Task 6), EUnit + CT shape (every task). All
  design sections map to a task.
- **Error shape:** every reject path returns the full tuple `{error,
  {instance_only_attribute, AttrNref}}`; every reject-path test asserts the
  full tuple.
- **Marker cannot enter via update maps:** unchanged slice-B
  `validate_avp_updates/1` rejects the `instance_only` extra key — no code
  needed, stated in Global Constraints.
- **Type consistency:** `is_instance_only/1`, `validate_instance_only_avps/1`,
  `is_qc_instance_only/2`, `new_qc_avp/2`, `check_instance_only/2`,
  `guard_instance_only/2` — names used consistently across tasks.
