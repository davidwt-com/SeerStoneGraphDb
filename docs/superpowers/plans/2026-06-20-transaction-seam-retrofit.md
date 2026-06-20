# Transaction-Seam Retrofit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every hand-rolled `mnesia:transaction` call site in the graphdb app (40 sites across six workers + the bootstrap loader) through `graphdb_mgr:transaction/1`, so it becomes the single `{atomic,_}`/`{aborted,_}` mapping point — with zero behaviour change.

**Architecture:** Each site's transaction fun is reshaped into a tier-1 primitive (bare mnesia ops; rollback-worthy failures via `mnesia:abort(ExactReason)`) and invoked via `graphdb_mgr:transaction/1`. The wrapper projects `{ok, Value}` to the site's existing public shape and reproduces the site's existing failure contract (return / `throw` / `{reply,...}`). Because `transaction/1`'s `{aborted,Reason} -> {error,Reason}` mapping is byte-identical to the inline mapping, any fun-internal abort/throw Reason is preserved automatically; only the four traps below need deliberate handling.

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27 (repo-local `./rebar3`), Mnesia, Common Test + EUnit.

**Design:** `docs/designs/transaction-seam-retrofit-design.md` (approved).

## Global Constraints

- **Behaviour-preserving.** The existing 537 tests (432 CT + 105 EUnit) are the oracle: they must stay green with **zero test-expectation edits**. Any required edit signals an unintended behaviour change — a defect.
- **Single mapping point.** Only `graphdb_mgr:transaction/1` may pattern-match `{atomic,_}`/`{aborted,_}`. After the plan, `grep -rn "mnesia:transaction" apps/graphdb/src/` returns only `transaction/1`'s own definition (`graphdb_mgr.erl:293`).
- **Call it qualified:** `graphdb_mgr:transaction(Fun)` at every site (matches the existing in-module caller `set_retired/3`), including inside `graphdb_mgr` and `graphdb_bootstrap`.
- **Exact Reason terms.** Relocated aborts (`mnesia:abort(Reason)`) use the *exact* term the site currently returns as `{error, Reason}`.
- **Preserve each site's failure contract.** Three coexist — return `{error,R}`, `throw({error,R})`, and `{reply,{error,R},State}`. Do not normalize them.
- **Trap 1 — non-uniform failure propagation:** reproduce the site's contract (return / throw / reply) exactly.
- **Trap 2 — `{atomic,{error,_}=E} -> E` is NOT an abort:** the fun *returns* `{error,_}` as a committed value (`graphdb_class:832`). Preserve via `{ok,{error,_}=E} -> E`. Never convert it to `mnesia:abort`.
- **Trap 3 — abort-swallow:** `graphdb_class:704` and `graphdb_instance:1760` map a real abort to a domain value (`not_found`). Preserve via `{error,_} -> not_found`.
- **Trap 4 — abort-relocation:** `graphdb_instance:validate_arc_endpoints` moves domain failures inside the fun via `mnesia:abort(ExactReason)`.
- **Whitespace:** match each site's existing indentation. Most graphdb files use **tabs**; `graphdb_language.erl` uses **spaces** at some sites (e.g. line 310). Change only the matched tokens; keep the surrounding indentation byte-for-byte.
- **Headers/copyright unchanged.** Do not touch module headers, `-revision`, NYI/UEM macros, or export lists except where a task explicitly adds a test export.
- **Line numbers drift.** All `file:line` references are anchored to the pre-change tree; after an edit, later line numbers in the *same file* shift. Locate sites by the `case mnesia:transaction` text and the function name, not by absolute line.

**Commands (run from repo root):**
- Compile: `./rebar3 compile` — Expected: `===> Compiling ...` with no warnings/errors.
- One CT suite: `./rebar3 ct --suite apps/graphdb/test/graphdb_<mod>_SUITE` — Expected: `All N tests passed.`
- One EUnit module: `./rebar3 eunit --module graphdb_<mod>_tests` — Expected: `All N tests passed.`
- Full CT (fast): `make test-ct-parallel` — Expected: aggregate `PASS`, exit 0.
- Full EUnit: `./rebar3 eunit` — Expected: `All 105 tests passed.`
- Grep gate: `grep -rn "mnesia:transaction" apps/graphdb/src/` — Expected after plan: one line (`graphdb_mgr.erl:` `transaction/1`).

---

## Task ordering

Tasks are independent (each module's sites are self-contained); ordered simplest-first so the convention is well-practiced before the trickiest site. The grep gate is fully satisfied only after the last task.

1. `graphdb_mgr` + `graphdb_bootstrap`
2. `graphdb_attr`
3. `graphdb_class`
4. `graphdb_language`
5. `graphdb_rules`
6. `graphdb_instance` (includes the abort-relocation trap + the only 2 new tests)
7. Final verification

---

## Task 1: `graphdb_mgr` + `graphdb_bootstrap`

**Files:**
- Modify: `apps/graphdb/src/graphdb_mgr.erl` (`verify_caches/0`, `rebuild_caches/0`, `do_get_relationships/2`)
- Modify: `apps/graphdb/src/graphdb_bootstrap.erl` (2 assertion-form sites)
- Test: existing `graphdb_mgr_SUITE`, `graphdb_bootstrap_SUITE`, `graphdb_bootstrap_tests` (no new tests)

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1` (already exists, `graphdb_mgr.erl:291-296`).
- Produces: nothing new; behaviour-identical functions.

- [ ] **Step 1: Convert `verify_caches/0`**

Replace the `case` (currently `graphdb_mgr.erl:317-321`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, []}          -> ok;
		{atomic, Mismatches}  -> {error, Mismatches};
		{aborted, Reason}     -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, []}            -> ok;
		{ok, Mismatches}    -> {error, Mismatches};
		{error, _} = Err    -> Err
	end.
```

- [ ] **Step 2: Convert `rebuild_caches/0`**

Replace (currently `graphdb_mgr.erl:338-341`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 3: Convert both `do_get_relationships/2` clauses (identity)**

The `outgoing` clause (currently `graphdb_mgr.erl:501-507`) becomes:

```erlang
do_get_relationships(Nref, outgoing) ->
	graphdb_mgr:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.source_nref)
	end);
```

The `incoming` clause (currently `:508-514`) becomes:

```erlang
do_get_relationships(Nref, incoming) ->
	graphdb_mgr:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.target_nref)
	end);
```

(The `both` clause is unchanged — it composes the other two.) `transaction/1` already returns `{ok, Rels}` / `{error, Reason}`, identical to the old mapping.

- [ ] **Step 4: Convert the two `graphdb_bootstrap` assertion sites**

At `graphdb_bootstrap.erl:509` and `:546`, replace each:

```erlang
		{atomic, ok} = mnesia:transaction(fun() ->
```

with:

```erlang
		{ok, ok} = graphdb_mgr:transaction(fun() ->
```

(The fun bodies and the closing `end)` are unchanged. This preserves crash-on-failure: a non-`{ok,ok}` result is a `badmatch`, exactly as before.)

- [ ] **Step 5: Compile**

Run: `./rebar3 compile`
Expected: compiles clean, no warnings.

- [ ] **Step 6: Grep this task's files**

Run: `grep -n "mnesia:transaction" apps/graphdb/src/graphdb_mgr.erl apps/graphdb/src/graphdb_bootstrap.erl`
Expected: a single hit — the `transaction/1` definition in `graphdb_mgr.erl` (the `case mnesia:transaction(Fun) of` line). `graphdb_bootstrap.erl`: no hits.

- [ ] **Step 7: Run the suites**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_mgr_SUITE --suite apps/graphdb/test/graphdb_bootstrap_SUITE`
Then: `./rebar3 eunit --module graphdb_mgr_tests --module graphdb_bootstrap_tests`
Expected: all pass; zero test-file edits made.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_mgr.erl apps/graphdb/src/graphdb_bootstrap.erl
git commit -m "refactor(graphdb_mgr,bootstrap): route txn sites through transaction/1"
```

---

## Task 2: `graphdb_attr` (9 sites)

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl`
- Test: existing `graphdb_attr_SUITE` (no new tests — branches already covered, e.g. `not_an_attribute` at suite line 709)

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1`.
- Produces: behaviour-identical functions.

- [ ] **Step 1: `find_attribute_by_name/2` — projection-in-fun + throw**

Replace the whole `case mnesia:transaction(F) of ... end` tail (currently `:499-503`). Move the `{value,...}`/`false` projection into the fun and re-throw on `{error,_}`:

```erlang
	F = fun() ->
		Children = downward_children_by_arc(ParentNref, ?ARC_ATTR_CHILD,
			taxonomy),
		case lists:search(fun(N) -> node_has_name(N, Name) end, Children) of
			{value, #node{nref = Nref}} -> {ok, Nref};
			false                       -> not_found
		end
	end,
	case graphdb_mgr:transaction(F) of
		{ok, Result}    -> Result;
		{error, Reason} -> throw({error, Reason})
	end.
```

(Replaces the existing `F = fun() ... end,` *and* the `case`. The `lists:search` moves inside the fun.)

- [ ] **Step 2: `do_create_attribute/3` — tagged success**

Replace (currently `:562-565`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, Nref};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> {ok, Nref};
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 3: `do_create_relationship_attribute_pair/4` — tagged success**

Replace (currently `:657-660`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, {FwdNref, RevNref}};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> {ok, {FwdNref, RevNref}};
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 4: `do_get_attribute/1` — projection at wrapper**

Replace (currently `:685-690`):

```erlang
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = attribute} = Node]} -> {ok, Node};
		{atomic, [_Other]}                         -> {error, not_an_attribute};
		{atomic, []}                               -> {error, not_found};
		{aborted, Reason}                          -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{ok, [#node{kind = attribute} = Node]} -> {ok, Node};
		{ok, [_Other]}                         -> {error, not_an_attribute};
		{ok, []}                               -> {error, not_found};
		{error, Reason}                        -> {error, Reason}
	end.
```

- [ ] **Step 5: `do_list_attributes/0` and `do_list_children/1` — identity**

In each (currently `:700-703` and `:713-716`), replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	graphdb_mgr:transaction(F).
```

- [ ] **Step 6: `do_attribute_type_of/2` — projection at wrapper (nested)**

Replace (currently `:755-764`):

```erlang
	case mnesia:transaction(F) of
		{atomic, [#node{kind = attribute, attribute_value_pairs = AVPs}]} ->
			case find_attribute_type_value(AtAttrNref, AVPs) of
				{ok, Kind}  -> {ok, Kind};
				not_found   -> {error, no_attribute_type}
			end;
		{atomic, [_Other]} -> {error, not_an_attribute};
		{atomic, []}       -> {error, not_found};
		{aborted, Reason}  -> {error, Reason}
	end.
```

with (only the four arm heads change):

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, [#node{kind = attribute, attribute_value_pairs = AVPs}]} ->
			case find_attribute_type_value(AtAttrNref, AVPs) of
				{ok, Kind}  -> {ok, Kind};
				not_found   -> {error, no_attribute_type}
			end;
		{ok, [_Other]}  -> {error, not_an_attribute};
		{ok, []}        -> {error, not_found};
		{error, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 7: `retro_stamp_bootstrap_attribute_types/1` — collapse + throw**

Replace (currently `:799-803`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{atomic, _Other}  -> ok;
		{aborted, Reason} -> throw({error, Reason})
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, _}         -> ok;
		{error, Reason} -> throw({error, Reason})
	end.
```

- [ ] **Step 8: `ensure_template_avp_marker/1` — unwrap-ok + throw**

Replace (currently `:883-886`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> throw({error, Reason})
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}        -> ok;
		{error, Reason} -> throw({error, Reason})
	end.
```

(The `throw({error, {template_avp_node_missing, ...}})` *inside* `Txn` is untouched; transaction/1 maps the resulting abort to `{error, Reason}` identically.)

- [ ] **Step 9: Compile + grep + test + commit**

```bash
./rebar3 compile
grep -n "mnesia:transaction" apps/graphdb/src/graphdb_attr.erl   # expect: no hits
./rebar3 ct --suite apps/graphdb/test/graphdb_attr_SUITE
```
Expected: compiles clean; grep empty; CT green; no test edits.

```bash
git add apps/graphdb/src/graphdb_attr.erl
git commit -m "refactor(graphdb_attr): route txn sites through transaction/1"
```

---

## Task 3: `graphdb_class` (8 sites)

**Files:**
- Modify: `apps/graphdb/src/graphdb_class.erl`
- Test: existing `graphdb_class_SUITE`, `graphdb_class_tests` (no new tests — idempotency/`already_exists` branches already covered)

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1`.
- Produces: behaviour-identical functions. **Trap 2** (`:832`) and **Trap 3** (`:704`) live here.

- [ ] **Step 1: `do_create_class` — tagged success (txn value ignored)**

Replace (currently `:499-503`):

```erlang
			case mnesia:transaction(Txn) of
				%% Txn value is [] (abstract) or [ok,ok,ok] (template rows)
				{atomic, _Writes} -> {ok, ClassNref};
				{aborted, Reason} -> {error, Reason}
			end;
```

with:

```erlang
			case graphdb_mgr:transaction(Txn) of
				%% Txn value is [] (abstract) or [ok,ok,ok] (template rows)
				{ok, _Writes}    -> {ok, ClassNref};
				{error, _} = Err -> Err
			end;
```

- [ ] **Step 2: site at `:624` — collapse idempotent**

Replace:

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{aborted, Reason}        -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{error, _} = Err     -> Err
	end.
```

- [ ] **Step 3: `do_create_template`-style site at `:682` — tagged success**

Replace:

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, TemplateNref};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> {ok, TemplateNref};
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 4: `do_find_template_by_name` at `:704` — projection + abort-swallow (Trap 3)**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
		{atomic, false}                       -> not_found;
		{aborted, _}                          -> not_found
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, {value, #node{nref = Nref}}} -> {ok, Nref};
		{ok, false}                       -> not_found;
		{error, _}                        -> not_found
	end.
```

(The `{error, _} -> not_found` preserves the abort-swallow.)

- [ ] **Step 5: identity list sites at `:738` and `:911`**

In each, replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	graphdb_mgr:transaction(F).
```

- [ ] **Step 6: site at `:832` — collapse + fun-returns-`{error,_}` value (Trap 2)**

Replace:

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{atomic, {error, _} = E} -> E;
		{aborted, Reason}        -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{ok, {error, _} = E} -> E;
		{error, Reason}      -> {error, Reason}
	end.
```

(**Trap 2:** the fun's `{error,_}` return rides `{ok, {error,_}}` and is unwrapped — it is NOT converted to `mnesia:abort`, so the partial work in `Txn` still commits exactly as today.)

- [ ] **Step 7: `add_qualifying_characteristic`-style site at `:869` — unwrap-ok**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 8: Compile + grep + test + commit**

```bash
./rebar3 compile
grep -n "mnesia:transaction" apps/graphdb/src/graphdb_class.erl   # expect: no hits
./rebar3 ct --suite apps/graphdb/test/graphdb_class_SUITE
./rebar3 eunit --module graphdb_class_tests
```
Expected: clean; grep empty; green; no test edits.

```bash
git add apps/graphdb/src/graphdb_class.erl
git commit -m "refactor(graphdb_class): route txn sites through transaction/1"
```

---

## Task 4: `graphdb_language` (7 sites)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Test: existing `graphdb_language_SUITE`, `graphdb_language_tests` (no new tests)

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1`.
- Produces: behaviour-identical functions. **Note:** this module indents with **spaces** at some sites (e.g. `:310`). Match the existing indentation at each site.

- [ ] **Step 1: `set_labels` handle_call at `:310` — reply-in-handle_call**

Replace (note 4-space indent and trailing `;`):

```erlang
    case mnesia:transaction(F) of
        {atomic, ok}      -> {reply, ok, State};
        {aborted, Reason} -> {reply, {error, Reason}, State}
    end;
```

with:

```erlang
    case graphdb_mgr:transaction(F) of
        {ok, ok}        -> {reply, ok, State};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
```

- [ ] **Step 2: class-nref lookup at `:395` — projection + throw**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> Nref;
		{atomic, false} -> throw({error, {class_not_found, Name}});
		{aborted, R}    -> throw({error, R})
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, {value, #node{nref = Nref}}} -> Nref;
		{ok, false} -> throw({error, {class_not_found, Name}});
		{error, R}  -> throw({error, R})
	end.
```

- [ ] **Step 3: site at `:447` — tagged success + throw**

Replace:

```erlang
			case mnesia:transaction(F) of
				{atomic, ok}      -> Nref;
				{aborted, Reason} -> throw({error, Reason})
			end
```

with:

```erlang
			case graphdb_mgr:transaction(F) of
				{ok, ok}        -> Nref;
				{error, Reason} -> throw({error, Reason})
			end
```

- [ ] **Step 4: `build_lang_maps` at `:508` — tuple value + throw**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, {CM, DM}} -> {CM, DM};
		{aborted, Reason}  -> throw({error, {build_lang_maps_failed, Reason}})
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, {CM, DM}}  -> {CM, DM};
		{error, Reason} -> throw({error, {build_lang_maps_failed, Reason}})
	end.
```

- [ ] **Step 5: `register_language` at `:629` — side-effects-after**

Replace the arm heads only (the `{atomic, ok}` body — `ensure_overlay_table`, `NewState`, the reply — is unchanged):

```erlang
	case mnesia:transaction(F) of
		{aborted, Reason} ->
			{error, Reason};
		{atomic, ok} ->
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{error, Reason} ->
			{error, Reason};
		{ok, ok} ->
```

- [ ] **Step 6: `register_dialect` at `:692` — side-effects-after**

Same transformation as Step 5, at the `:692` site:

```erlang
			case mnesia:transaction(F) of
				{aborted, Reason} ->
					{error, Reason};
				{atomic, ok} ->
```

becomes:

```erlang
			case graphdb_mgr:transaction(F) of
				{error, Reason} ->
					{error, Reason};
				{ok, ok} ->
```

- [ ] **Step 7: lang-code lookup at `:734` — projection**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, not_found} -> not_found;
		{atomic, Code}      -> {ok, Code};
		{aborted, Reason}   -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, not_found} -> not_found;
		{ok, Code}      -> {ok, Code};
		{error, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 8: Compile + grep + test + commit**

```bash
./rebar3 compile
grep -n "mnesia:transaction" apps/graphdb/src/graphdb_language.erl   # expect: no hits
./rebar3 ct --suite apps/graphdb/test/graphdb_language_SUITE
./rebar3 eunit --module graphdb_language_tests
```
Expected: clean; grep empty; green; no test edits.

```bash
git add apps/graphdb/src/graphdb_language.erl
git commit -m "refactor(graphdb_language): route txn sites through transaction/1"
```

---

## Task 5: `graphdb_rules` (3 sites)

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Test: existing `graphdb_rules_SUITE` (no new tests)

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1`.
- Produces: behaviour-identical functions.

- [ ] **Step 1: seed helper at `:608` — tagged success + throw**

Replace:

```erlang
			case mnesia:transaction(F) of
				{atomic, ok}      -> Nref;
				{aborted, Reason} -> throw({error, Reason})
			end
```

with:

```erlang
			case graphdb_mgr:transaction(F) of
				{ok, ok}        -> Nref;
				{error, Reason} -> throw({error, Reason})
			end
```

- [ ] **Step 2: class-by-name find at `:654` — projection + throw**

Replace:

```erlang
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
		{atomic, false}                       -> not_found;
		{aborted, Reason}                     -> throw({error, Reason})
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, {value, #node{nref = Nref}}} -> {ok, Nref};
		{ok, false}                       -> not_found;
		{error, Reason}                   -> throw({error, Reason})
	end.
```

- [ ] **Step 3: rule-create commit at `:857` — tagged success**

Replace:

```erlang
			case mnesia:transaction(Txn) of
				{atomic, ok}      -> {ok, RuleNref};
				{aborted, Reason} -> {error, Reason}
			end
```

with:

```erlang
			case graphdb_mgr:transaction(Txn) of
				{ok, ok}        -> {ok, RuleNref};
				{error, Reason} -> {error, Reason}
			end
```

- [ ] **Step 4: Compile + grep + test + commit**

```bash
./rebar3 compile
grep -n "mnesia:transaction" apps/graphdb/src/graphdb_rules.erl   # expect: no hits
./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE
```
Expected: clean; grep empty; green; no test edits.

```bash
git add apps/graphdb/src/graphdb_rules.erl
git commit -m "refactor(graphdb_rules): route txn sites through transaction/1"
```

---

## Task 6: `graphdb_instance` (7 sites + the only 2 new tests)

**Files:**
- Modify: `apps/graphdb/test/graphdb_instance_SUITE.erl` (add 2 coverage tests + register them)
- Modify: `apps/graphdb/src/graphdb_instance.erl` (7 conversion sites incl. the abort-relocation trap)
- Test: `graphdb_instance_SUITE`, `graphdb_instance_tests`

**Interfaces:**
- Consumes: `graphdb_mgr:transaction/1`.
- Produces: behaviour-identical functions. **Trap 4** (`validate_arc_endpoints`) and **Trap 3** (`resolve_from_connected`) live here.

**Why tests first:** `validate_arc_endpoints` is reshaped so its domain failures are produced via `mnesia:abort` instead of an outside-the-fun tuple match. Six of its eight error arms are already asserted (`source_not_found`, `target_not_found`, `characterization_not_an_attribute`, `reciprocal_not_an_attribute`, `target_kind_mismatch`, `endpoint_retired`). Two are not: `characterization_not_found` and `reciprocal_not_found`. Lock those two with characterization tests **before** reshaping the function.

- [ ] **Step 1: Write the two coverage tests**

In `apps/graphdb/test/graphdb_instance_SUITE.erl`, add these two functions immediately after `add_relationship_rejects_missing_target/1` (near suite line 794), matching the existing idiom:

```erlang
%%-----------------------------------------------------------------------------
%% missing characterization nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_characterization(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {_Char, Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {characterization_not_found, 99999}},
		graphdb_instance:add_relationship(A, 99999, B, Recip)).

%%-----------------------------------------------------------------------------
%% missing reciprocal nref is rejected.
%%-----------------------------------------------------------------------------
add_relationship_rejects_missing_reciprocal(_Config) ->
	{ok, ClassNref} = graphdb_class:create_class("Thing", 3),
	{ok, A, _} = graphdb_instance:create_instance("A", ClassNref, 5),
	{ok, B, _} = graphdb_instance:create_instance("B", ClassNref, 5),
	{ok, {Char, _Recip}} =
		graphdb_attr:create_relationship_attribute_pair("Knows", "KnownBy", instance),
	?assertEqual({error, {reciprocal_not_found, 99999}},
		graphdb_instance:add_relationship(A, Char, B, 99999)).
```

- [ ] **Step 2: Register the two tests**

Add both to the `-export([...])` block (next to `add_relationship_rejects_missing_target/1`, suite line ~84):

```erlang
	add_relationship_rejects_missing_characterization/1,
	add_relationship_rejects_missing_reciprocal/1,
```

and to the test list returned by the group/`all` near the existing `add_relationship_rejects_*` entries (suite line ~227):

```erlang
			add_relationship_rejects_missing_characterization,
			add_relationship_rejects_missing_reciprocal,
```

- [ ] **Step 3: Run the two new tests against UNCHANGED source — confirm they PASS**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE --case add_relationship_rejects_missing_characterization --case add_relationship_rejects_missing_reciprocal`
Expected: both PASS. (They characterize behaviour the current code already produces; they are the regression net for Step 5.)

- [ ] **Step 4: Commit the coverage tests**

```bash
git add apps/graphdb/test/graphdb_instance_SUITE.erl
git commit -m "test(graphdb_instance): cover add_relationship missing char/reciprocal arms"
```

- [ ] **Step 5: Convert `validate_arc_endpoints/6` — abort-relocation (Trap 4)**

Replace the entire function body (the `F = fun() ... end,` and the trailing `case mnesia:transaction(F) of ... end`, currently `:1231-1270`) with — moving every domain decision inside the fun via `mnesia:abort(ExactReason)`:

```erlang
validate_arc_endpoints(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TkAttr, RetAttr) ->
	F = fun() ->
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
		end
	end,
	case graphdb_mgr:transaction(F) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

Every abort term matches the original `{error, Reason}` term exactly, so the public error contract is unchanged. The fun is read-only → retry-safe.

- [ ] **Step 6: Convert `execute/5` — result-building on both arms**

Replace (currently `:579-588`):

```erlang
			case mnesia:transaction(Txn) of
				{atomic, ok} ->
					{ok, RootNref,
					 merge_reports(CompOutcomes, ConnReport),
					 InstPlan, AutoConnPlan};
				{aborted, R} ->
					{error, R,
					 report_not_attempted(R,
						#{plan_so_far => PlanTree, culprit => undefined})}
			end;
```

with (only the two arm heads change):

```erlang
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
```

- [ ] **Step 7: Convert `write_connection_arcs/6` — unwrap-ok**

Replace (currently `:1394-1397`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
	end.
```

- [ ] **Step 8: Convert `do_write_class_membership/2` — collapse idempotent**

Replace (currently `:1453-1457`):

```erlang
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{aborted, Reason}        -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}             -> ok;
		{ok, already_exists} -> ok;
		{error, _} = Err     -> Err
	end.
```

- [ ] **Step 9: Convert `do_class_of/1` — projection at wrapper**

Replace (currently `:1487-1492`):

```erlang
	case mnesia:transaction(F) of
		{atomic, {value, #relationship{target_nref = ClassNref}}} ->
			{ok, ClassNref};
		{atomic, false}   -> not_found;
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, {value, #relationship{target_nref = ClassNref}}} ->
			{ok, ClassNref};
		{ok, false}     -> not_found;
		{error, Reason} -> {error, Reason}
	end.
```

- [ ] **Step 10: Convert `do_children/1` — identity**

Replace (currently `:1518-1521`):

```erlang
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.
```

with:

```erlang
	graphdb_mgr:transaction(F).
```

- [ ] **Step 11: Convert `resolve_from_connected/2` — side-effects-after + abort-swallow (Trap 3)**

Replace (currently `:1760-1768`):

```erlang
	case mnesia:transaction(F) of
		{atomic, Rels} ->
			TargetNrefs = lists:usort(
				[R#relationship.target_nref
					|| R <- Rels, R#relationship.kind =:= connection]),
			search_targets(TargetNrefs, AttrNref);
		{aborted, _} ->
			not_found
	end.
```

with (only the two arm heads change):

```erlang
	case graphdb_mgr:transaction(F) of
		{ok, Rels} ->
			TargetNrefs = lists:usort(
				[R#relationship.target_nref
					|| R <- Rels, R#relationship.kind =:= connection]),
			search_targets(TargetNrefs, AttrNref);
		{error, _} ->
			not_found
	end.
```

- [ ] **Step 12: Compile + grep**

```bash
./rebar3 compile
grep -n "mnesia:transaction" apps/graphdb/src/graphdb_instance.erl   # expect: no hits
```
Expected: clean compile, no warnings; grep empty.

- [ ] **Step 13: Run the instance suites — including the 2 new tests still green after reshaping**

```bash
./rebar3 ct --suite apps/graphdb/test/graphdb_instance_SUITE
./rebar3 eunit --module graphdb_instance_tests
```
Expected: all pass (the two new tests prove the relocated `characterization_not_found` / `reciprocal_not_found` arms behave identically post-reshape); no edits to existing expectations.

- [ ] **Step 14: Commit**

```bash
git add apps/graphdb/src/graphdb_instance.erl
git commit -m "refactor(graphdb_instance): route txn sites through transaction/1"
```

---

## Task 7: Final verification

**Files:** none modified (verification only).

- [ ] **Step 1: Global grep gate**

Run: `grep -rn "mnesia:transaction" apps/graphdb/src/`
Expected: exactly one line — the `transaction/1` definition in `graphdb_mgr.erl` (`case mnesia:transaction(Fun) of`). Any other hit is an unconverted site.

- [ ] **Step 2: Full compile**

Run: `./rebar3 compile`
Expected: clean, zero warnings.

- [ ] **Step 3: Full test suite (the behaviour oracle)**

```bash
make test-ct-parallel
./rebar3 eunit
```
Expected: CT aggregate PASS (exit 0) at **434 CT** (432 prior + the 2 new instance CT cases); EUnit unchanged at `All 105 tests passed.` (the 2 new tests are CT, not EUnit). Total 434 + 105 = 539. **No existing test expectation was edited** — confirm via `git diff --stat <merge-base>..HEAD` that the only test file touched is `graphdb_instance_SUITE.erl` and only by additions.

- [ ] **Step 4: Update CLAUDE.md / docs if needed**

No `docs/Architecture.md` update required: this is an internal refactor with no schema, supervision-tree, or public-contract change. Confirm no doc edit is needed and note it in the PR description.

---

## Self-review notes (for the executor)

- **Spec coverage:** all 40 inventory sites map to a task step (Task 1: 5; Task 2: 9; Task 3: 8; Task 4: 7; Task 5: 3; Task 6: 7 — total 39 conversion sites + the `transaction/1` definition itself which is left as the single mapping point = 40 `mnesia:transaction` occurrences). The four traps are each flagged at their site (Trap 2 → Task 3 Step 6; Trap 3 → Task 3 Step 4 and Task 6 Step 11; Trap 4 → Task 6 Step 5; Trap 1 → throw sites in Tasks 2/4/5 and the reply site in Task 4 Step 1).
- **Only 2 new tests**, both in Task 6, both with full code; every other task asserts "no test edits".
- **Type/return consistency:** every converted wrapper returns the same public shape as before its conversion (identity sites return `transaction/1`'s `{ok,_}|{error,_}` directly, which equals the old `{ok,_}|{error,_}`).
