# Atomic `add_relationship` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `graphdb_instance:do_add_relationship/7`'s five separate transactions into one, spending PR 1's tier-1 primitives, while preserving every observable behaviour.

**Architecture:** Convert the four single-use phase helpers (`validate_arc_endpoints`, `resolve_arc_classes`, `resolve_template`, `validate_template_scope`) in place to in-transaction helpers that signal failure via `mnesia:abort/1`; add a private `class_of_in_txn/1` twin (the gen-server `do_class_of/1` keeps its own txn for its public caller); split `build_connection_rows` so the rel-id pair is allocated up-front outside the transaction; rewrite `do_add_relationship/7` to run validate → resolve classes → resolve template → validate scope → write inside one `graphdb_mgr:transaction/1` fun.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (repo-local `./rebar3`), Mnesia, Common Test.

## Global Constraints

- Design contract: `docs/designs/atomic-add-relationship-design.md`. Read it first.
- **Behaviour-preserving.** No existing test is modified. The entire existing `add_relationship` suite must pass unchanged — that is the behaviour-preservation proof.
- **No atomicity/race test.** The collapse buys TOCTOU isolation (a race); it has no deterministic CT test and none will be written. New tests are exactly the two error-atom characterization tests.
- **Byte-identical Reason terms.** `source_has_no_class`/`target_has_no_class` convert from `{error, _}` returns to `mnesia:abort/1` with the same Reason terms: `{source_has_no_class, SourceNref}`, `{target_has_no_class, TargetNref}`.
- **Phase order preserved** inside the single fun: validate endpoints → resolve classes → resolve template → validate scope → write. An input violating multiple constraints must report the same first error.
- **Allocate the rel-id pair OUTSIDE the transaction.** `rel_id_server:get_id_pair()` is a gen_server call and must never run inside an mnesia transaction fun. A validation abort orphans one id pair — accepted under the allocate-outside-transaction doctrine.
- **`graphdb_mgr:transaction/1` wrap shape:** the fun returns `ok` on success → `{ok, ok}` → map to `ok`; an abort → `{error, Reason}` → return verbatim. Public contract `add_relationship/4,5,6 -> ok | {error, term()}` is unchanged.
- **Hard tabs.** `apps/graphdb/src/graphdb_instance.erl` and `apps/graphdb/test/graphdb_instance_SUITE.erl` use hard tabs for indentation. Match them.
- **Macros already in scope** in `graphdb_instance.erl`: `?ARC_INST_TO_CLASS` (instance→class membership char), `?ARC_TEMPLATE` (Template AVP attr 31). No new includes.
- **Test runner:** single suite — `scripts/test-ct-parallel.sh instance`; full — `make test-ct-parallel` then `./rebar3 eunit`. Invoke `./rebar3` directly (PATH/kerl preset; no `source ~/.bashrc` prefix).

---

### Task 1: Characterization tests for the two uncovered class-resolution atoms

Lock the `source_has_no_class` / `target_has_no_class` contract with tests **before** the refactor. Both atoms are already returned by the current code, so these tests pass immediately against `HEAD`; they then form part of the green net the collapse must preserve.

**Files:**
- Modify (test): `apps/graphdb/test/graphdb_instance_SUITE.erl`

**Interfaces:**
- Consumes: `graphdb_class:create_class/2`, `graphdb_instance:create_instance/3`, `graphdb_attr:create_relationship_attribute_pair/3`, `graphdb_instance:add_relationship/4`.
- Produces: two new CT cases — `add_relationship_rejects_source_has_no_class/1`, `add_relationship_rejects_target_has_no_class/1`.

**Why a class node serves as the "node with no class":** `validate_arc_endpoints` does **not** check the source's/target's `kind`; it only requires the node to exist, be un-retired, and (for the target) match the characterization's `target_kind` AVP. A freshly-created class node satisfies that, yet has no instance→class (`?ARC_INST_TO_CLASS`) outgoing arc, so `do_class_of` on it returns `not_found`. For the target case, a characterization whose `target_kind = class` lets a class node pass endpoint validation as the target.

- [ ] **Step 1: Add the two cases to the `-export` list and the test group**

In the `-export([...])` block near the other `add_relationship_*` entries (around line 74-91), add:

```erlang
	add_relationship_rejects_source_has_no_class/1,
	add_relationship_rejects_target_has_no_class/1,
```

In `groups()` where the `add_relationship_*` cases are listed (around line 219-236), add the two names alongside the existing `add_relationship_rejects_*` cases:

```erlang
			add_relationship_rejects_source_has_no_class,
			add_relationship_rejects_target_has_no_class,
```

- [ ] **Step 2: Write the two test functions**

Add after `add_relationship_rejects_target_kind_mismatch/1` (around line 862), matching the file's hard-tab indentation and comment style:

```erlang
%%-----------------------------------------------------------------------------
%% source that exists and passes endpoint validation but has no instance->class
%% membership arc is rejected.  A class node is such a node: validate_arc_endpoints
%% does not constrain the source's kind, and a class has no ?ARC_INST_TO_CLASS arc.
%%-----------------------------------------------------------------------------
add_relationship_rejects_source_has_no_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {source_has_no_class, ClassNref}},
		graphdb_instance:add_relationship(ClassNref, Char, B, Recip)).

%%-----------------------------------------------------------------------------
%% target that exists and passes endpoint validation but has no instance->class
%% membership arc is rejected.  Char's target_kind=class lets a class node pass
%% endpoint validation as the target; the class has no ?ARC_INST_TO_CLASS arc.
%%-----------------------------------------------------------------------------
add_relationship_rejects_target_has_no_class(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, {Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Has", "HeldBy", class),
	?assertEqual({error, {target_has_no_class, ClassNref}},
		graphdb_instance:add_relationship(A, Char, ClassNref, Recip)).
```

- [ ] **Step 3: Run the two new cases — verify they PASS against current code**

Run: `scripts/test-ct-parallel.sh instance`

Expected: PASS. The two new cases pass against `HEAD` (the atoms are already returned by today's `resolve_arc_classes`). This confirms the contract the refactor must preserve. If either FAILS, the test setup is wrong (e.g. endpoint validation rejected the class node first) — fix the test, do not touch source.

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "test(add_relationship): cover source/target_has_no_class atoms

Characterization tests for the two previously-uncovered class-resolution
error atoms, locked in before the atomic-collapse refactor.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

### Task 2: Collapse `do_add_relationship/7` into a single transaction

Convert the four phase helpers in place to in-txn helpers, add `class_of_in_txn/1`, split `build_connection_rows`, and rewrite `do_add_relationship/7`. All tests (existing + Task 1's two new ones) stay green.

**Files:**
- Modify: `apps/graphdb/src/graphdb_instance.erl`

**Interfaces:**
- Consumes (from PR 1, `graphdb_class`): `default_template_in_txn/1 -> {ok, Nref} | not_found`; `get_template_in_txn/1 -> {ok, #node{}} | {error, not_a_template | not_found}`; `class_in_ancestry_in_txn/2 -> boolean()`.
- Consumes (existing, unchanged): `head_parent/1`, `check_target_kind/3`, `first_retired/2`, `rel_id_server:get_id_pair/0`, `graphdb_mgr:transaction/1`.
- Produces (private, this module): `class_of_in_txn/1 -> {ok, ClassNref} | not_found`; `validate_arc_endpoints_in_txn/6 -> ok` (aborts on violation); `resolve_arc_classes_in_txn/2 -> {SourceClass, TargetClass}` (aborts); `resolve_template_in_txn/2 -> TemplateNref` (aborts); `validate_template_scope_in_txn/3 -> ok` (aborts); `build_connection_rows/7({Id1,Id2}, S, C, T, R, TemplateNref, AVPSpec) -> [{relationships, #relationship{}}]`.
- Unchanged for B4 callers: `build_connection_rows/6` (now allocates then delegates to `/7`), `write_connection_arcs/6`, `do_class_of/1`.

- [ ] **Step 1: Run the full suite first — confirm the green baseline**

Run: `scripts/test-ct-parallel.sh instance`

Expected: PASS (includes Task 1's two new cases). This is the baseline the refactor must keep green. Note the case count.

- [ ] **Step 2: Add `class_of_in_txn/1` next to `do_class_of/1`**

`do_class_of/1` lives around line 1482 and has a public caller (`handle_call({class_of, Nref}, …)` ~line 425) — leave it untouched. Add the in-txn twin immediately after `do_class_of/1`:

```erlang
%%-----------------------------------------------------------------------------
%% class_of_in_txn(InstanceNref) -> {ok, ClassNref} | not_found
%%
%% Tier-1 in-transaction twin of do_class_of/1.  Assumes it runs inside an
%% active mnesia activity; uses a bare index_read.  do_class_of/1 keeps its
%% own transaction for its public class_of caller.
%%-----------------------------------------------------------------------------
class_of_in_txn(InstanceNref) ->
	Rels = mnesia:index_read(relationships, InstanceNref,
		#relationship.source_nref),
	case lists:search(
			fun(R) ->
				R#relationship.characterization =:= ?ARC_INST_TO_CLASS
			end, Rels) of
		{value, #relationship{target_nref = ClassNref}} -> {ok, ClassNref};
		false                                           -> not_found
	end.
```

- [ ] **Step 3: Replace `validate_arc_endpoints/6` with `validate_arc_endpoints_in_txn/6`**

Replace the whole `validate_arc_endpoints/6` definition (its head comment may stay or be updated; the body is the change) — drop the `F = fun() ... end` wrapper and the trailing `graphdb_mgr:transaction(F)` case; the body becomes the function body directly, returning `ok` on success and aborting otherwise:

```erlang
%%-----------------------------------------------------------------------------
%% validate_arc_endpoints_in_txn(Source, Char, Target, Reciprocal, TkAttr,
%%     RetAttr) -> ok    (aborts the enclosing transaction on any violation)
%%
%% In-transaction endpoint validation.  Assumes it runs inside an active mnesia
%% activity; reads the four nodes with bare mnesia:read and signals every
%% violation via mnesia:abort/1 (same Reason terms as the prior own-txn form).
%%-----------------------------------------------------------------------------
validate_arc_endpoints_in_txn(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TkAttr, RetAttr) ->
	Source = mnesia:read(nodes, SourceNref),
	Target = mnesia:read(nodes, TargetNref),
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

Leave `first_retired/2`, `is_retired/2`, `check_target_kind/3`, and `find_avp_value/2` exactly as they are.

- [ ] **Step 4: Replace `resolve_arc_classes/2` with `resolve_arc_classes_in_txn/2`**

Replace the whole `resolve_arc_classes/2` definition with:

```erlang
%%-----------------------------------------------------------------------------
%% resolve_arc_classes_in_txn(SourceNref, TargetNref) ->
%%     {SourceClass, TargetClass}    (aborts on a missing class)
%%
%% In-transaction class resolution.  class_of_in_txn returns only {ok,_} |
%% not_found inside a txn (a read error aborts the txn directly), so the
%% no-class arms abort with the same Reason terms the prior form returned.
%%-----------------------------------------------------------------------------
resolve_arc_classes_in_txn(SourceNref, TargetNref) ->
	SourceClass = case class_of_in_txn(SourceNref) of
		{ok, SC}  -> SC;
		not_found -> mnesia:abort({source_has_no_class, SourceNref})
	end,
	TargetClass = case class_of_in_txn(TargetNref) of
		{ok, TC}  -> TC;
		not_found -> mnesia:abort({target_has_no_class, TargetNref})
	end,
	{SourceClass, TargetClass}.
```

- [ ] **Step 5: Replace `resolve_template/2` with `resolve_template_in_txn/2`**

Replace both clauses of `resolve_template/2` with:

```erlang
%%-----------------------------------------------------------------------------
%% resolve_template_in_txn(TemplateSpec, SourceClass) -> TemplateNref
%%     (aborts no_default_template when `default' is requested but absent)
%%-----------------------------------------------------------------------------
resolve_template_in_txn(default, SourceClass) ->
	case graphdb_class:default_template_in_txn(SourceClass) of
		{ok, Nref} -> Nref;
		not_found  -> mnesia:abort(no_default_template)
	end;
resolve_template_in_txn(TemplateNref, _SourceClass)
		when is_integer(TemplateNref) ->
	TemplateNref.
```

- [ ] **Step 6: Replace `validate_template_scope/3` with `validate_template_scope_in_txn/3`**

Replace the whole `validate_template_scope/3` definition with:

```erlang
%%-----------------------------------------------------------------------------
%% validate_template_scope_in_txn(TemplateNref, SourceClass, TargetClass) -> ok
%%     (aborts invalid_template / template_class_not_in_ancestry)
%%
%% Confirms TemplateNref resolves to a kind=template node whose parent class is
%% in SourceClass's or TargetClass's taxonomic ancestry.  The nested Reason in
%% {invalid_template, _, Reason} is byte-identical to the gen-server get_template
%% form: get_template_in_txn returns the same {error, not_a_template|not_found}.
%%-----------------------------------------------------------------------------
validate_template_scope_in_txn(TemplateNref, SourceClass, TargetClass) ->
	case graphdb_class:get_template_in_txn(TemplateNref) of
		{ok, #node{parents = TmplParents}} ->
			TmplClass = head_parent(TmplParents),
			InSource = graphdb_class:class_in_ancestry_in_txn(TmplClass,
				SourceClass),
			InTarget = graphdb_class:class_in_ancestry_in_txn(TmplClass,
				TargetClass),
			case InSource orelse InTarget of
				true  -> ok;
				false -> mnesia:abort({template_class_not_in_ancestry,
					TemplateNref, TmplClass, SourceClass, TargetClass})
			end;
		{error, Reason} ->
			mnesia:abort({invalid_template, TemplateNref, Reason})
	end.
```

- [ ] **Step 7: Split `build_connection_rows` into `/6` (allocates) + `/7` (pure)**

Replace the existing `build_connection_rows/6` definition (around line 1362) with these two definitions. The `/6` form now only allocates and delegates; the `/7` form is the pure builder taking a pre-allocated id pair:

```erlang
build_connection_rows(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	IdPair = rel_id_server:get_id_pair(),
	build_connection_rows(IdPair, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, AVPSpec).

%% build_connection_rows({Id1, Id2}, S, C, T, R, TemplateNref, {FwdAVPs,RevAVPs})
%%   -> [{relationships, #relationship{}}]
%%
%% Pure builder: no allocation.  The caller supplies the rel-id pair (allocated
%% up-front, outside any transaction) so the rows can be built inside a caller's
%% transaction.  Template AVP rides index 0 of each direction.
build_connection_rows({Id1, Id2}, SourceNref, CharNref, TargetNref,
		ReciprocalNref, TemplateNref, {FwdAVPs, RevAVPs}) ->
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
	[{relationships, Fwd}, {relationships, Rev}].
```

Leave the existing `build_connection_rows/6` head comment (the one describing the no-write contract) in place above the `/6` clause, or fold it into these comments — do not duplicate it. Leave `write_connection_arcs/6` unchanged: it still calls `build_connection_rows/6` and is still used by the B4 auto post-commit pass.

- [ ] **Step 8: Rewrite `do_add_relationship/7` as one transaction**

Replace the whole `do_add_relationship/7` definition (around line 1188) with:

```erlang
do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateSpec, AVPSpec, State) ->
	TkAttr  = State#state.target_kind_avp_nref,
	RetAttr = State#state.retired_nref,
	%% Allocate the rel-id pair up-front, OUTSIDE the transaction: get_id_pair
	%% is a gen_server call and must never run inside an mnesia fun.  A
	%% validation abort below orphans this pair -- harmless (allocate-outside-
	%% transaction doctrine).
	IdPair = rel_id_server:get_id_pair(),
	Txn = fun() ->
		ok = validate_arc_endpoints_in_txn(SourceNref, CharNref, TargetNref,
			ReciprocalNref, TkAttr, RetAttr),
		{SourceClass, TargetClass} =
			resolve_arc_classes_in_txn(SourceNref, TargetNref),
		TemplateNref = resolve_template_in_txn(TemplateSpec, SourceClass),
		ok = validate_template_scope_in_txn(TemplateNref, SourceClass,
			TargetClass),
		Rows = build_connection_rows(IdPair, SourceNref, CharNref, TargetNref,
			ReciprocalNref, TemplateNref, AVPSpec),
		lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
			Rows)
	end,
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

Update the `do_add_relationship/7` head comment so it describes the single-transaction flow (validate → resolve classes → resolve template → scope → write, all in one txn; id pair allocated up-front).

- [ ] **Step 9: Compile — verify clean, zero warnings**

Run: `./rebar3 compile`

Expected: clean compile, **zero warnings**. In particular, no "function … is unused" warnings (the four old phase helpers were renamed, not duplicated; `class_of_in_txn/1` is used by `resolve_arc_classes_in_txn/2`). If a warning appears, fix the cause before proceeding.

- [ ] **Step 10: Run the instance suite — verify all green**

Run: `scripts/test-ct-parallel.sh instance`

Expected: PASS, same case count as Step 1's baseline. Every existing `add_relationship_*` case plus Task 1's two new cases pass unchanged. This is the behaviour-preservation proof.

- [ ] **Step 11: Run the full CT + EUnit suites — verify no cross-suite regression**

`write_connection_arcs/6` and the B4 connection-firing path call `build_connection_rows`; confirm nothing regressed.

Run: `make test-ct-parallel` then `./rebar3 eunit`

Expected: all green, zero warnings.

- [ ] **Step 12: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "feat(add_relationship): collapse into a single transaction

Validate endpoints, resolve class/template scope, and write the two
directed rows in one graphdb_mgr:transaction/1 (TOCTOU-isolated). Convert
the four single-use phase helpers in place to in-txn (abort-based) form;
add private class_of_in_txn/1 (do_class_of/1 keeps its own txn for its
public caller); split build_connection_rows into /6 (allocates) + /7
(pure) so the rel-id pair is allocated up-front outside the txn. Spends
PR 1's tier-1 primitives. Behaviour-preserving.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

### Task 3: Documentation

Mark the follow-up implemented, record the deferred convergence task, and note the single-transaction behaviour in the worker doc.

**Files:**
- Modify: `TASKS.md`
- Modify: `apps/graphdb/CLAUDE.md`

- [ ] **Step 1: Update the `add_relationship` follow-up bullet in `TASKS.md`**

Replace the **Atomic `add_relationship`** bullet (around line 136-144) with the implemented form:

```markdown
- **Atomic `add_relationship`** — IMPLEMENTED. `do_add_relationship/7`'s five
  separate transactions (validate endpoints → resolve classes → resolve
  template → validate scope → write) are collapsed into one
  `graphdb_mgr:transaction/1` (TOCTOU isolation). The four single-use phase
  helpers were converted in place to in-txn (abort-based) form; a private
  `class_of_in_txn/1` was added (`do_class_of/1` keeps its own txn for its
  public caller); `build_connection_rows` was split into `/6` (allocates) +
  `/7` (pure) so the rel-id pair is allocated up-front outside the
  transaction. Behaviour-preserving; existing `add_relationship` suite
  unchanged, +2 new instance CT cases (`source_has_no_class` /
  `target_has_no_class`). Design
  `docs/designs/atomic-add-relationship-design.md`; plan
  `docs/superpowers/plans/2026-06-21-atomic-add-relationship.md`.
```

- [ ] **Step 2: Add the deferred convergence task to `TASKS.md`**

Immediately after the **Batch `mutate([Mutation])`** bullet (around line 145), add a new tracked follow-up:

```markdown
- **Converge default-template name search** — `graphdb_class` carries two
  copies of the default-template name-search walk: the gen-server
  `do_find_template_by_name/2` (own txn) and the tier-1
  `default_template_in_txn/1` (PR 1). The gen-server `default_template/1` path
  is already transactional, so `do_default_template/1` could be rewritten to
  wrap a txn and call `default_template_in_txn/1`, removing the duplication.
  Deliberately deferred (the duplication is sanctioned project precedent);
  a future cleanup, not blocking anything.
```

- [ ] **Step 3: Note single-transaction behaviour in `apps/graphdb/CLAUDE.md`**

Find the `add_relationship/4` bullet in the `graphdb_instance` API section:

```markdown
- `add_relationship/4` (source_nref, characterization_nref, target_nref, reciprocal_nref) — writes two directed rows atomically; IDs allocated via `get_nref()`
```

Replace it with:

```markdown
- `add_relationship/4,5,6` (source_nref, characterization_nref, target_nref, reciprocal_nref [, template_nref [, {FwdAVPs, RevAVPs}]]) — validates endpoints, resolves source/target class and template scope, and writes the two directed `kind=connection` rows in a **single** `graphdb_mgr:transaction/1` (TOCTOU-isolated). The rel-id pair is allocated up-front (outside the transaction) via `rel_id_server:get_id_pair/0`. `/4` uses the source class's default template; `/5` takes an explicit template nref; `/6` adds per-direction AVPs.
```

- [ ] **Step 4: Confirm `docs/Architecture.md` needs no change**

The public contract (signatures and return shapes of `add_relationship/4,5,6`) is unchanged; the collapse is an internal transaction-count change already covered by the documented three-tier seam. **Do not edit `docs/Architecture.md`.**

- [ ] **Step 5: Commit**

```bash
git add TASKS.md apps/graphdb/CLAUDE.md
git commit -m "docs(add_relationship): record atomic collapse + deferred convergence

Mark the Atomic add_relationship follow-up implemented; add the deferred
default-template name-search convergence task; note add_relationship's
single-transaction behaviour in the graphdb worker doc.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EWukKCbrN8GybaScJGU2kF"
```

---

## Notes for the executor

- The collapse fixes no bug (only the final phase writes today). It buys TOCTOU isolation, a race with no deterministic test. **Do not write an atomicity test.** The behaviour-preservation proof is the existing suite passing unchanged plus Task 1's two characterization tests.
- The four converted phase helpers are single-use (grep-confirmed: each appears only at its definition and the one call site in `do_add_relationship/7`), so converting them in place leaves no dead code and no second caller to break. `do_class_of/1` is the sole exception — it has a public `handle_call` caller — hence the add-don't-rewrap twin.
- Reason-term fidelity is the one correctness risk: keep the abort terms byte-identical to the prior returns, and preserve phase order.
