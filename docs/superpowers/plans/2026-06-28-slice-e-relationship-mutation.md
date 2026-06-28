# Slice E — Relationship Mutation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `remove_relationship` and `update_relationship` (AVP-only) to the connection-arc write-path, composing into `mutate/1`.

**Architecture:** Connection-arcs only — the exact mirror of `add_relationship`, so no `parents`/`classes` cache work. New tier-1 in-transaction primitives in `graphdb_instance` (allocation-free, state-free), tier-2 public wrappers as plain functions owning one `graphdb_mgr:transaction/1`, and three new `graphdb_mgr:mutate/1` grammar kinds. Reuses slice B's exported `validate_avp_updates/1` + `apply_avp_updates/2` unchanged.

**Tech Stack:** Erlang/OTP 28.5, Mnesia, rebar3 3.27 (repo-local `./rebar3`), Common Test + EUnit.

## Global Constraints

- **Source uses HARD TABS** for indentation — every `.erl` edit must use tabs, never spaces.
- **Module header / NYI-UEM macros / explicit `-export`** convention is preserved (see `CLAUDE.md`); never `-compile(export_all)`.
- **Write-path transaction seam** (3-tier): tier-1 `_in_txn` primitives use bare Mnesia, signal failure via `mnesia:abort/1`, never open their own transaction; tier-2 owns one `graphdb_mgr:transaction/1`; tier-3 (`mutate/1`) composes tier-1 directly, never tier-2.
- **LOAD-BEARING INVARIANT:** never call a `gen_server` (incl. `rel_id_server`, `graphdb_attr`, `graphdb_class`) inside an Mnesia transaction fun. (These primitives need no such calls — they are allocation-free.)
- **Connection-arcs only.** Do NOT touch `parents`/`classes` caches; do NOT build kind-agnostic arc removal.
- **`?ARC_TEMPLATE`** (nref 31) is the protected scope AVP at index 0 of each connection row's `avps`; it must never be edited or deleted through `update_relationship`.
- Invoke rebar3 as plain `./rebar3 ...` (kerl PATH is preset).
- Run `graphdb_mgr:verify_caches/0` in `end_per_testcase` (the suite already does); it must stay `ok` — connection mutation leaves caches untouched.
- Design reference: `docs/designs/slice-e-relationship-mutation-design.md`.

---

### Task 1: `remove_relationship` (tier-1 primitive + shared resolver + tier-2)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl` (add exports + functions near `add_relationship`/`add_relationship_in_txn`, ~line 130 exports, ~line 1236 primitives)
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

**Interfaces:**
- Consumes: `find_avp_value/2` (graphdb_instance, already exported), `graphdb_mgr:transaction/1`, `?ARC_TEMPLATE` (graphdb_nrefs.hrl), `#relationship{}` record.
- Produces:
  - `resolve_forward_connection(S, C, T, TemplateSpec) -> {ok, #relationship{}} | not_found | {ambiguous, [TemplateNref]}` — in-txn, `TemplateSpec :: any | integer()`.
  - `template_of(#relationship{}) -> integer() | undefined`.
  - `remove_relationship_in_txn(S, C, T, TemplateSpec) -> ok` (aborts on failure).
  - `remove_relationship/3 (S,C,T) -> ok | {error, Reason}`; `remove_relationship/4 (S,C,T,TemplateNref) -> ok | {error, Reason}`.

- [ ] **Step 1: Write the failing CT cases**

Add to the exported test list and the `all/0`/groups list (mirroring the `add_relationship_*` entries near lines 74 and 221), then add the bodies. Place a small helper at the end of the suite if not already present.

```erlang
%% --- add to -export list ---
	remove_relationship_basic/1,
	remove_relationship_not_found/1,
	remove_relationship_ambiguous/1,
	remove_relationship_disambiguate_by_template/1,
	remove_relationship_dangling_half_edge/1,

%% --- test bodies ---

%% Setup helper: class, default template, two instances, a reciprocal
%% arc-label pair, and one connection edge A--Char-->B.  Returns the nrefs.
re_setup() ->
	{ok, ClassNref}   = graphdb_class:create_class("Org", 3),
	{ok, DefaultTmpl} = graphdb_class:default_template(ClassNref),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	#{class => ClassNref, tmpl => DefaultTmpl, a => A, b => B,
	  char => Char, recip => Recip}.

%% count forward connection rows A--Char-->B
re_count(A, Char, B) ->
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	length([R || R <- Rows,
		R#relationship.kind =:= connection,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B]).

remove_relationship_basic(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	?assertEqual(1, re_count(A, Char, B)),
	?assertEqual(1, re_count(B, Recip, A)),
	ok = graphdb_instance:remove_relationship(A, Char, B),
	?assertEqual(0, re_count(A, Char, B)),
	?assertEqual(0, re_count(B, Recip, A)).

remove_relationship_not_found(_Config) ->
	#{a := A, b := B, char := Char} = re_setup(),
	?assertEqual({error, relationship_not_found},
		graphdb_instance:remove_relationship(A, Char, B)).

remove_relationship_ambiguous(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip, class := Class} = re_setup(),
	{ok, DefaultTmpl} = graphdb_class:default_template(Class),
	{ok, AltTmpl}     = graphdb_class:add_template(Class, "social"),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, AltTmpl),
	?assertMatch({error, {ambiguous_relationship, [_, _]}},
		graphdb_instance:remove_relationship(A, Char, B)).

remove_relationship_disambiguate_by_template(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip, class := Class} = re_setup(),
	{ok, DefaultTmpl} = graphdb_class:default_template(Class),
	{ok, AltTmpl}     = graphdb_class:add_template(Class, "social"),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, DefaultTmpl),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip, AltTmpl),
	ok = graphdb_instance:remove_relationship(A, Char, B, DefaultTmpl),
	%% one edge (the AltTmpl one) remains in each direction
	?assertEqual(1, re_count(A, Char, B)),
	?assertEqual(1, re_count(B, Recip, A)).

remove_relationship_dangling_half_edge(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	%% manually delete the reverse row, leaving a half-edge
	{atomic, ok} = mnesia:transaction(fun() ->
		Rows = mnesia:index_read(relationships, B, #relationship.source_nref),
		[Rev] = [R || R <- Rows,
			R#relationship.characterization =:= Recip,
			R#relationship.target_nref =:= A],
		mnesia:delete_object(relationships, Rev, write)
	end),
	?assertMatch({error, {dangling_half_edge, _}},
		graphdb_instance:remove_relationship(A, Char, B)),
	%% the forward row is NOT deleted — rollback left it intact
	?assertEqual(1, re_count(A, Char, B)).
```

- [ ] **Step 2: Run the cases to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=remove_relationship_basic`
Expected: FAIL — `remove_relationship/3` undefined.

- [ ] **Step 3: Add exports**

In the `-export([...])` block of `graphdb_instance.erl` (near line 118-130), add:

```erlang
		remove_relationship/3,
		remove_relationship/4,
		remove_relationship_in_txn/4,
		resolve_forward_connection/4,
```

- [ ] **Step 4: Implement the shared resolver, `template_of`, the tier-1 primitive, and the tier-2 wrappers**

Add after `add_relationship_in_txn/9` (after ~line 1236), using HARD TABS:

```erlang
%%-----------------------------------------------------------------------------
%% resolve_forward_connection(SourceNref, CharNref, TargetNref, TemplateSpec)
%%   -> {ok, #relationship{}} | not_found | {ambiguous, [TemplateNref]}
%%
%% Tier-1 in-transaction helper.  Finds the directed connection row(s) whose
%% (source, characterization, target) match, narrowed by TemplateSpec
%% (`any` = ignore template; an integer = match that template AVP).  Classifies
%% none / exactly-one / many; the ambiguous case carries each matching row's
%% template so a /3 caller can re-issue as /4.  Reads only; never aborts.
%%-----------------------------------------------------------------------------
resolve_forward_connection(SourceNref, CharNref, TargetNref, TemplateSpec) ->
	Rows = mnesia:index_read(relationships, SourceNref,
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

template_matches(_Row, any) ->
	true;
template_matches(Row, TemplateNref) ->
	template_of(Row) =:= TemplateNref.

%% The Template AVP rides at index 0 of a connection row's avps.
template_of(#relationship{avps = AVPs}) ->
	case find_avp_value(AVPs, ?ARC_TEMPLATE) of
		{ok, V}   -> V;
		not_found -> undefined
	end.

%%-----------------------------------------------------------------------------
%% remove_relationship_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec)
%%   -> ok    (aborts the enclosing transaction on any failure)
%%
%% Tier-1 primitive.  Must run inside an active mnesia transaction; never opens
%% its own.  Resolves the forward row (relationship_not_found /
%% {ambiguous_relationship, Templates}), locates its symmetric partner
%% (T, R, S) under the same concrete template, and deletes both rows.  A
%% missing partner is an integrity violation -- aborts {dangling_half_edge, Id}
%% rather than deleting a half-edge.  Used by remove_relationship/3,4 (tier-2)
%% and graphdb_mgr:mutate/1 (tier-3).
%%-----------------------------------------------------------------------------
remove_relationship_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec) ->
	case resolve_forward_connection(SourceNref, CharNref, TargetNref,
			TemplateSpec) of
		not_found ->
			mnesia:abort(relationship_not_found);
		{ambiguous, Templates} ->
			mnesia:abort({ambiguous_relationship, Templates});
		{ok, Fwd} ->
			Recip = Fwd#relationship.reciprocal,
			Tmpl  = template_of(Fwd),
			case resolve_forward_connection(TargetNref, Recip, SourceNref,
					Tmpl) of
				{ok, Rev} ->
					ok = mnesia:delete_object(relationships, Fwd, write),
					ok = mnesia:delete_object(relationships, Rev, write);
				_ ->
					mnesia:abort({dangling_half_edge, Fwd#relationship.id})
			end
	end.

%%-----------------------------------------------------------------------------
%% remove_relationship(SourceNref, CharNref, TargetNref) -> ok | {error, term()}
%% remove_relationship(SourceNref, CharNref, TargetNref, TemplateNref)
%%   -> ok | {error, term()}
%%
%% Tier-2 public API: deletes both directed rows of a logical connection edge
%% atomically.  /3 ignores template (ambiguous if two templates match); /4
%% narrows by an explicit template.  Plain functions owning one
%% graphdb_mgr:transaction/1 in the caller's process (no gen_server state).
%%-----------------------------------------------------------------------------
remove_relationship(SourceNref, CharNref, TargetNref) ->
	txn_ok(fun() ->
		remove_relationship_in_txn(SourceNref, CharNref, TargetNref, any)
	end).

remove_relationship(SourceNref, CharNref, TargetNref, TemplateNref)
		when is_integer(TemplateNref) ->
	txn_ok(fun() ->
		remove_relationship_in_txn(SourceNref, CharNref, TargetNref,
			TemplateNref)
	end).

%% Run an in-txn primitive in one transaction; normalise {ok, _} -> ok.
txn_ok(Fun) ->
	case graphdb_mgr:transaction(Fun) of
		{ok, _}          -> ok;
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 5: Compile and run the cases to verify they pass**

Run: `./rebar3 compile && ./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --group=<group containing the new cases>`
(or per-case `--case=remove_relationship_basic` etc.)
Expected: PASS, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "Slice E: remove_relationship (tier-1 primitive + tier-2)"
```

---

### Task 2: `update_relationship` single-direction (tier-1 primitive + tier-2)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl` (CT) and `apps/graphdb/test/graphdb_instance_tests.erl` (EUnit, pure)

**Interfaces:**
- Consumes: `resolve_forward_connection/4`, `template_of/1`, `txn_ok/1` (Task 1); `graphdb_mgr:validate_avp_updates/1`, `graphdb_mgr:apply_avp_updates/2`; `?ARC_TEMPLATE`.
- Produces:
  - `has_template_update([map()]) -> boolean()` (pure; exported for EUnit).
  - `update_relationship_avps_in_txn(S, C, T, TemplateSpec, Updates) -> ok` (aborts on failure).
  - `update_relationship/4 (S,C,T,Updates) -> ok | {error, Reason}`; `update_relationship/5 (S,C,T,TemplateNref,Updates) -> ok | {error, Reason}`.

- [ ] **Step 1: Write the failing pure EUnit test**

In `apps/graphdb/test/graphdb_instance_tests.erl` (add `-include_lib("graphdb/include/graphdb_nrefs.hrl").` if absent):

```erlang
has_template_update_true_test() ->
	?assert(graphdb_instance:has_template_update(
		[#{attribute => ?ARC_TEMPLATE, value => 7}])).

has_template_update_false_test() ->
	?assertNot(graphdb_instance:has_template_update(
		[#{attribute => 9999, value => "x"}, #{attribute => 8888}])).
```

- [ ] **Step 2: Write the failing CT cases**

Add to the `-export` list and `all/0`, then bodies (reuse `re_setup/0`, `re_count/3` from Task 1):

```erlang
%% --- exports ---
	update_relationship_single_direction/1,
	update_relationship_reverse_direction/1,
	update_relationship_protects_template/1,
	update_relationship_not_found/1,

%% helper: fetch the single forward row's avps
re_avps(A, Char, B) ->
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	[R] = [X || X <- Rows,
		X#relationship.kind =:= connection,
		X#relationship.characterization =:= Char,
		X#relationship.target_nref =:= B],
	R#relationship.avps.

update_relationship_single_direction(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	ok = graphdb_instance:update_relationship(A, Char, B,
		[#{attribute => Note, value => "fwd"}]),
	?assert(lists:member(#{attribute => Note, value => "fwd"},
		re_avps(A, Char, B))),
	%% reverse row untouched (proves independence)
	?assertNot(lists:member(#{attribute => Note, value => "fwd"},
		re_avps(B, Recip, A))).

update_relationship_reverse_direction(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	%% name the reverse direction from the other endpoint: (T, R, S)
	ok = graphdb_instance:update_relationship(B, Recip, A,
		[#{attribute => Note, value => "rev"}]),
	?assert(lists:member(#{attribute => Note, value => "rev"},
		re_avps(B, Recip, A))),
	?assertNot(lists:member(#{attribute => Note, value => "rev"},
		re_avps(A, Char, B))).

update_relationship_protects_template(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	?assertEqual({error, {protected_relationship_avp, ?ARC_TEMPLATE}},
		graphdb_instance:update_relationship(A, Char, B,
			[#{attribute => ?ARC_TEMPLATE, value => 7}])).

update_relationship_not_found(_Config) ->
	#{a := A, b := B, char := Char} = re_setup(),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	?assertEqual({error, relationship_not_found},
		graphdb_instance:update_relationship(A, Char, B,
			[#{attribute => Note, value => "x"}])).
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./rebar3 eunit --module=graphdb_instance_tests` and `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=update_relationship_single_direction`
Expected: FAIL — functions undefined.

- [ ] **Step 4: Add exports**

```erlang
		update_relationship/4,
		update_relationship/5,
		update_relationship_avps_in_txn/5,
		has_template_update/1,
```

- [ ] **Step 5: Implement the primitive and tier-2 wrappers**

Add after `remove_relationship_in_txn/4`, HARD TABS:

```erlang
%%-----------------------------------------------------------------------------
%% update_relationship_avps_in_txn(S, C, T, TemplateSpec, Updates) -> ok
%%   (aborts the enclosing transaction on any failure)
%%
%% Tier-1 primitive: edits the AVPs of the SINGLE directed connection row named
%% by (S, C, T) (narrowed by TemplateSpec).  Reuses slice B's pure
%% apply_avp_updates/2 (merge/upsert/delete).  The ?ARC_TEMPLATE scope AVP is
%% protected -- any update targeting it aborts.  Same not-found / ambiguity
%% arms as remove.  The Template AVP at index 0 survives because no update may
%% reference it.
%%-----------------------------------------------------------------------------
update_relationship_avps_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec,
		Updates) ->
	case has_template_update(Updates) of
		true ->
			mnesia:abort({protected_relationship_avp, ?ARC_TEMPLATE});
		false ->
			case resolve_forward_connection(SourceNref, CharNref, TargetNref,
					TemplateSpec) of
				not_found ->
					mnesia:abort(relationship_not_found);
				{ambiguous, Templates} ->
					mnesia:abort({ambiguous_relationship, Templates});
				{ok, Row} ->
					New = graphdb_mgr:apply_avp_updates(
						Row#relationship.avps, Updates),
					mnesia:write(relationships,
						Row#relationship{avps = New}, write)
			end
	end.

%% True iff any update map targets the protected ?ARC_TEMPLATE scope AVP.
has_template_update(Updates) ->
	lists:any(fun(#{attribute := A}) -> A =:= ?ARC_TEMPLATE end, Updates).

%%-----------------------------------------------------------------------------
%% update_relationship(S, C, T, Updates) -> ok | {error, term()}
%% update_relationship(S, C, T, TemplateNref, Updates) -> ok | {error, term()}
%%
%% Tier-2 public API: AVP-only edit of the single directed row named by
%% (S, C, T).  Validates the update grammar client-side (slice B), then owns
%% one transaction.
%%-----------------------------------------------------------------------------
update_relationship(SourceNref, CharNref, TargetNref, Updates) ->
	do_update_relationship(SourceNref, CharNref, TargetNref, any, Updates).

update_relationship(SourceNref, CharNref, TargetNref, TemplateNref, Updates)
		when is_integer(TemplateNref) ->
	do_update_relationship(SourceNref, CharNref, TargetNref, TemplateNref,
		Updates).

do_update_relationship(SourceNref, CharNref, TargetNref, TemplateSpec,
		Updates) ->
	case graphdb_mgr:validate_avp_updates(Updates) of
		ok ->
			txn_ok(fun() ->
				update_relationship_avps_in_txn(SourceNref, CharNref,
					TargetNref, TemplateSpec, Updates)
			end);
		{error, _} = Err ->
			Err
	end.
```

- [ ] **Step 6: Compile and run the tests to verify they pass**

Run: `./rebar3 compile && ./rebar3 eunit --module=graphdb_instance_tests && ./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=update_relationship_single_direction`
Expected: PASS, 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl apps/graphdb/test/graphdb_instance_tests.erl
git commit -m "Slice E: update_relationship single-direction AVP edit"
```

---

### Task 3: `update_relationship_both` (in-txn composite + tier-2)

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`
- Test: `apps/graphdb/test/graphdb_instance_SUITE.erl`

**Interfaces:**
- Consumes: `resolve_forward_connection/4`, `template_of/1`, `update_relationship_avps_in_txn/5`, `txn_ok/1`, `graphdb_mgr:validate_avp_updates/1`.
- Produces:
  - `update_relationship_both_in_txn(S, C, T, TemplateSpec, FwdUpdates, RevUpdates) -> ok` (aborts on failure) — the single source of the bidirectional composition, reused by tier-3.
  - `update_relationship_both/4 (S,C,T,{Fwd,Rev}) -> ok | {error, Reason}`; `update_relationship_both/5 (S,C,T,TemplateNref,{Fwd,Rev}) -> ok | {error, Reason}`.

- [ ] **Step 1: Write the failing CT case**

```erlang
%% --- exports ---
	update_relationship_both_directions/1,

update_relationship_both_directions(_Config) ->
	#{a := A, b := B, char := Char, recip := Recip} = re_setup(),
	{ok, FAttr} = graphdb_attr:create_literal_attribute("fwd_meta", string),
	{ok, RAttr} = graphdb_attr:create_literal_attribute("rev_meta", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	ok = graphdb_instance:update_relationship_both(A, Char, B,
		{[#{attribute => FAttr, value => "F"}],
		 [#{attribute => RAttr, value => "R"}]}),
	FwdAVPs = re_avps(A, Char, B),
	RevAVPs = re_avps(B, Recip, A),
	?assert(lists:member(#{attribute => FAttr, value => "F"}, FwdAVPs)),
	?assertNot(lists:member(#{attribute => RAttr, value => "R"}, FwdAVPs)),
	?assert(lists:member(#{attribute => RAttr, value => "R"}, RevAVPs)),
	?assertNot(lists:member(#{attribute => FAttr, value => "F"}, RevAVPs)).
```

- [ ] **Step 2: Run to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=update_relationship_both_directions`
Expected: FAIL — `update_relationship_both/4` undefined.

- [ ] **Step 3: Add exports**

```erlang
		update_relationship_both/4,
		update_relationship_both/5,
		update_relationship_both_in_txn/6,
```

- [ ] **Step 4: Implement the composite and tier-2 wrappers**

Add after `do_update_relationship/5`, HARD TABS:

```erlang
%%-----------------------------------------------------------------------------
%% update_relationship_both_in_txn(S, C, T, TemplateSpec, FwdUpdates,
%%   RevUpdates) -> ok    (aborts the enclosing transaction on any failure)
%%
%% Tier-1 composite: resolves the forward row to discover the reciprocal label
%% and the concrete template, then edits both directed rows -- FwdUpdates on
%% (S, C, T), RevUpdates on (T, R, S) -- EACH through the single-edge primitive
%% (update_relationship_avps_in_txn/5).  Reused by the tier-2 wrappers and by
%% graphdb_mgr:mutate/1.  The two directions' updates are independent.
%%-----------------------------------------------------------------------------
update_relationship_both_in_txn(SourceNref, CharNref, TargetNref, TemplateSpec,
		FwdUpdates, RevUpdates) ->
	case resolve_forward_connection(SourceNref, CharNref, TargetNref,
			TemplateSpec) of
		not_found ->
			mnesia:abort(relationship_not_found);
		{ambiguous, Templates} ->
			mnesia:abort({ambiguous_relationship, Templates});
		{ok, Fwd} ->
			Recip = Fwd#relationship.reciprocal,
			Tmpl  = template_of(Fwd),
			ok = update_relationship_avps_in_txn(SourceNref, CharNref,
				TargetNref, Tmpl, FwdUpdates),
			ok = update_relationship_avps_in_txn(TargetNref, Recip,
				SourceNref, Tmpl, RevUpdates)
	end.

%%-----------------------------------------------------------------------------
%% update_relationship_both(S, C, T, {FwdUpdates, RevUpdates})
%%   -> ok | {error, term()}
%% update_relationship_both(S, C, T, TemplateNref, {FwdUpdates, RevUpdates})
%%   -> ok | {error, term()}
%%
%% Tier-2 convenience: edits both directions of one logical edge in a single
%% transaction.  The two update lists are independent (forward need not mirror
%% reverse).  Both lists are validated client-side (slice B grammar).
%%-----------------------------------------------------------------------------
update_relationship_both(SourceNref, CharNref, TargetNref, {Fwd, Rev}) ->
	do_update_both(SourceNref, CharNref, TargetNref, any, Fwd, Rev).

update_relationship_both(SourceNref, CharNref, TargetNref, TemplateNref,
		{Fwd, Rev}) when is_integer(TemplateNref) ->
	do_update_both(SourceNref, CharNref, TargetNref, TemplateNref, Fwd, Rev).

do_update_both(SourceNref, CharNref, TargetNref, TemplateSpec, Fwd, Rev) ->
	case {graphdb_mgr:validate_avp_updates(Fwd),
		  graphdb_mgr:validate_avp_updates(Rev)} of
		{ok, ok} ->
			txn_ok(fun() ->
				update_relationship_both_in_txn(SourceNref, CharNref,
					TargetNref, TemplateSpec, Fwd, Rev)
			end);
		{{error, _} = Err, _} -> Err;
		{_, {error, _} = Err} -> Err
	end.
```

- [ ] **Step 5: Compile and run to verify it passes**

Run: `./rebar3 compile && ./rebar3 ct --suite=apps/graphdb/test/graphdb_instance_SUITE --case=update_relationship_both_directions`
Expected: PASS, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "Slice E: update_relationship_both bidirectional convenience"
```

---

### Task 4: `mutate/1` grammar — remove/update/update_both kinds

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (`validate_mutation/1` ~line 366-382, `prepare/1` ~line 408-422, `dispatch/3` ~line 427-436, and the `mutate/1` doc comment ~line 323-329)
- Test: `apps/graphdb/test/graphdb_mgr_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_instance:remove_relationship_in_txn/4`, `update_relationship_avps_in_txn/5`, `update_relationship_both_in_txn/6`; `validate_avp_updates/1` (graphdb_mgr, in scope).
- Produces: three new `mutate/1` grammar kinds (each with/without template):
  - `{remove_relationship, S, C, T}` / `{remove_relationship, S, C, T, Template}`
  - `{update_relationship, S, C, T, Updates}` / `{update_relationship, S, C, T, Template, Updates}`
  - `{update_relationship_both, S, C, T, {Fwd, Rev}}` / `{update_relationship_both, S, C, T, Template, {Fwd, Rev}}`

- [ ] **Step 1: Write the failing CT cases**

Add to `graphdb_mgr_SUITE.erl` (mirror the existing `mutate_*` cases' setup — they create instances + a reciprocal pair like the instance suite):

```erlang
%% --- exports ---
	mutate_remove_relationship/1,
	mutate_update_relationship/1,
	mutate_mixed_rollback/1,

mutate_remove_relationship(_Config) ->
	{ok, Class}   = graphdb_class:create_class("Org", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", Class, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", Class, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	{ok, [ok]} = graphdb_mgr:mutate([{remove_relationship, A, Char, B}]),
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	?assertEqual([], [R || R <- Rows,
		R#relationship.kind =:= connection,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B]),
	ok = graphdb_mgr:verify_caches().

mutate_update_relationship(_Config) ->
	{ok, Class}   = graphdb_class:create_class("Org", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", Class, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", Class, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	{ok, Note} = graphdb_attr:create_literal_attribute("note", string),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	{ok, [ok, ok]} = graphdb_mgr:mutate([
		{update_relationship, A, Char, B, [#{attribute => Note, value => "f"}]},
		{update_relationship_both, A, Char, B,
			{[#{attribute => Note, value => "F"}],
			 [#{attribute => Note, value => "R"}]}}]),
	ok = graphdb_mgr:verify_caches().

mutate_mixed_rollback(_Config) ->
	{ok, Class}   = graphdb_class:create_class("Org", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", Class, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", Class, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	ok = graphdb_instance:add_relationship(A, Char, B, Recip),
	%% second mutation removes a non-existent edge -> whole batch rolls back
	{error, relationship_not_found} = graphdb_mgr:mutate([
		{remove_relationship, A, Char, B},
		{remove_relationship, A, Char, B}]),
	{atomic, Rows} = mnesia:transaction(fun() ->
		mnesia:index_read(relationships, A, #relationship.source_nref)
	end),
	%% the first remove was rolled back -- the edge is still present
	?assertEqual(1, length([R || R <- Rows,
		R#relationship.kind =:= connection,
		R#relationship.characterization =:= Char,
		R#relationship.target_nref =:= B])),
	ok = graphdb_mgr:verify_caches().
```

- [ ] **Step 2: Run to verify they fail**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --case=mutate_remove_relationship`
Expected: FAIL — `mutate` returns `{error, {bad_mutation, ...}}`.

- [ ] **Step 3: Add `validate_mutation/1` clauses**

Insert BEFORE the catch-all `validate_mutation(M) -> {error, {bad_mutation, M}}` clause (~line 381), HARD TABS:

```erlang
validate_mutation({remove_relationship, _S, _C, _T}) ->
	ok;
validate_mutation({remove_relationship, _S, _C, _T, _Template}) ->
	ok;
validate_mutation({update_relationship, _S, _C, _T, Updates}) ->
	validate_avp_updates(Updates);
validate_mutation({update_relationship, _S, _C, _T, _Template, Updates}) ->
	validate_avp_updates(Updates);
validate_mutation({update_relationship_both, _S, _C, _T, {Fwd, Rev}}) ->
	validate_both_avp_updates(Fwd, Rev);
validate_mutation({update_relationship_both, _S, _C, _T, _Template,
		{Fwd, Rev}}) ->
	validate_both_avp_updates(Fwd, Rev);
```

And add the helper near `tier_guard/1`:

```erlang
validate_both_avp_updates(Fwd, Rev) ->
	case validate_avp_updates(Fwd) of
		ok               -> validate_avp_updates(Rev);
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 4: Add `prepare/1` clauses**

These mutations need no resources (no rel-id allocation, no seeded nrefs). Insert before the end of the `prepare/1` clauses (~line 422):

```erlang
prepare({remove_relationship, _S, _C, _T} = M) ->
	M;
prepare({remove_relationship, _S, _C, _T, _Template} = M) ->
	M;
prepare({update_relationship, _S, _C, _T, _U} = M) ->
	M;
prepare({update_relationship, _S, _C, _T, _Template, _U} = M) ->
	M;
prepare({update_relationship_both, _S, _C, _T, _Pair} = M) ->
	M;
prepare({update_relationship_both, _S, _C, _T, _Template, _Pair} = M) ->
	M;
```

- [ ] **Step 5: Add `dispatch/3` clauses**

Insert before the end of the `dispatch/3` clauses (~line 436), HARD TABS:

```erlang
dispatch({remove_relationship, S, C, T}, _TkAttr, _RetAttr) ->
	graphdb_instance:remove_relationship_in_txn(S, C, T, any);
dispatch({remove_relationship, S, C, T, Template}, _TkAttr, _RetAttr) ->
	graphdb_instance:remove_relationship_in_txn(S, C, T, Template);
dispatch({update_relationship, S, C, T, U}, _TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_avps_in_txn(S, C, T, any, U);
dispatch({update_relationship, S, C, T, Template, U}, _TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_avps_in_txn(S, C, T, Template, U);
dispatch({update_relationship_both, S, C, T, {Fwd, Rev}}, _TkAttr, _RetAttr) ->
	graphdb_instance:update_relationship_both_in_txn(S, C, T, any, Fwd, Rev);
dispatch({update_relationship_both, S, C, T, Template, {Fwd, Rev}}, _TkAttr,
		_RetAttr) ->
	graphdb_instance:update_relationship_both_in_txn(S, C, T, Template, Fwd,
		Rev);
```

- [ ] **Step 6: Update the `mutate/1` doc comment**

In the grammar list (~line 323-329), add the three kinds so the comment stays the authoritative grammar reference:

```erlang
%%   {remove_relationship, S, C, T}                        remove edge (any template)
%%   {remove_relationship, S, C, T, Template}              remove edge (explicit template)
%%   {update_relationship, S, C, T, Updates}               edit one direction's AVPs
%%   {update_relationship, S, C, T, Template, Updates}     + explicit template
%%   {update_relationship_both, S, C, T, {Fwd, Rev}}       edit both directions' AVPs
%%   {update_relationship_both, S, C, T, Template, {Fwd, Rev}}  + explicit template
```

- [ ] **Step 7: Compile and run the cases to verify they pass**

Run: `./rebar3 compile && ./rebar3 ct --suite=apps/graphdb/test/graphdb_mgr_SUITE --case=mutate_remove_relationship`
(repeat for `mutate_update_relationship`, `mutate_mixed_rollback`)
Expected: PASS, 0 warnings.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/test/graphdb_mgr_SUITE.erl
git commit -m "Slice E: mutate/1 grammar for remove/update relationship"
```

---

### Task 5: Full suite, docs, and TASKS.md

**Files:**
- Modify: `docs/Architecture.md` (relationship write-path API), `apps/graphdb/CLAUDE.md` (`graphdb_instance` + `graphdb_mgr` worker tables), `TASKS.md` (mark slice E IMPLEMENTED, keep the deferred + `add_parent`/`add_child`/`remove_parent`/`remove_child` follow-up).
- (The design doc and the TASKS.md slice-E rewrite from brainstorming are already committed-or-staged; this task lands the doc updates that reflect shipped code.)

- [ ] **Step 1: Run the full suite**

Run: `make test-ct-parallel && ./rebar3 eunit`
Expected: all green (prior 488 CT + 133 EUnit, plus the ~14 new CT + 2 new EUnit cases), 0 compile warnings.

- [ ] **Step 2: Update `docs/Architecture.md`**

In the relationship/write-path section, document that `graphdb_instance` now exposes `remove_relationship/3,4`, `update_relationship/4,5`, `update_relationship_both/4,5` (connection-arcs only; AVP edits are per-directed-row; remove is logical-edge-level), and that `graphdb_mgr:mutate/1` carries the three new kinds. Keep it at architectural altitude.

- [ ] **Step 3: Update `apps/graphdb/CLAUDE.md`**

In the `graphdb_instance` bullet list add the three public APIs with one-line contracts (mirroring the `add_relationship` bullet's style). In the `graphdb_mgr` `mutate/1` bullet, extend the grammar list with the three new kinds.

- [ ] **Step 4: Update `TASKS.md`**

Mark the slice E section IMPLEMENTED (point at the design + this plan, summarise the shipped API and the edge-level/row-level contract), and leave the `add_parent` / `add_child` / `remove_parent` / `remove_child` follow-up and the structural-rewiring / rel-id-keyed deferrals in place.

- [ ] **Step 5: Commit**

```bash
git add docs/Architecture.md apps/graphdb/CLAUDE.md TASKS.md
git commit -m "Slice E: docs + TASKS for relationship mutation"
```

---

## Self-Review

**Spec coverage:**

| Spec section                                   | Task |
|------------------------------------------------|------|
| Connection-only scope, no cache work           | All (CT asserts `verify_caches/0` clean) |
| Edge identity + ambiguity contract (`/3`,`/4`) | Task 1 (`resolve_forward_connection/4`, ambiguity + disambiguate cases) |
| remove = both rows; dangling-half-edge abort   | Task 1 |
| update = one directed row; reverse via `(T,R,S)`| Task 2 |
| `?ARC_TEMPLATE` protected                       | Task 2 (`has_template_update/1`, CT + EUnit) |
| not-found / ambiguity arms on update            | Task 2 |
| `*_both`, two independent `{Fwd,Rev}` lists, one primitive | Task 3 |
| `mutate/1` three new kinds + rollback           | Task 4 |
| reuse slice-B `validate_avp_updates/1` + `apply_avp_updates/2` | Tasks 2-4 |
| docs / TASKS / follow-ups                       | Task 5 |

Deferred items (structural rewiring, rel-id-keyed form, `add_parent`/`add_child`/`remove_parent`/`remove_child`) are intentionally **not** tasks — they are recorded in `TASKS.md`.

**Placeholder scan:** none — every code/test step shows complete code and exact commands.

**Type consistency:** `resolve_forward_connection/4` returns `{ok, #relationship{}} | not_found | {ambiguous, [integer()]}` and is consumed identically in Tasks 1-3; `template_of/1`, `txn_ok/1`, `has_template_update/1`, the three `_in_txn` primitives, and the public arities are named consistently across producing/consuming tasks and the `dispatch/3` clauses.
