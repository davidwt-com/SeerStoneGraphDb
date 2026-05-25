# L7 — Literals Subtree Restructuring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Partition the `Literals` subtree (nref 7) by owning subsystem so each worker seeds its literal attributes under a dedicated sub-group, unblocking F4 Phase A (Rule Literals).

**Architecture:** Adds two attribute-kind sub-group nodes under nref 7 — `Attribute Literals` (seeded by `graphdb_attr:init/1`) and `Language Literals` (seeded by `graphdb_language:init/1`). Existing runtime-seeded literal attributes (`target_kind`, `relationship_avp`, `attribute_type`, `literal_type`, `base_language`, `project_language`) reparent under their owning worker's sub-group. Backward-compatible API: `graphdb_attr:create_literal_attribute/3` arity added; existing /2 form delegates to /3 with `?NREF_LITERALS` as the default parent. **No migration code** — clean-slate seeding only (no live env to preserve).

**Tech Stack:** Erlang/OTP 28.5, rebar3 3.27.0, Mnesia (disc_copies), Common Test, EUnit.

**Spec source:** `docs/designs/f4-graphdb-rules-design.md` §1 prerequisite and §3.1 seed-list pattern.

---

## File Structure

| File                                                  | Role                                                                                                                             |
|-------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `apps/graphdb/src/graphdb_attr.erl`                   | Owner: adds `create_literal_attribute/3`; seeds `Attribute Literals` sub-group; reparents own seeds; exposes sub-group nref via `seeded_nrefs/0` |
| `apps/graphdb/src/graphdb_language.erl`               | Consumer: seeds `Language Literals` sub-group; reparents own seeds (`base_language`, `project_language`); exposes sub-group nref |
| `apps/graphdb/test/graphdb_attr_SUITE.erl`            | Adds CT cases for `Attribute Literals` sub-group existence + reparenting verification                                            |
| `apps/graphdb/test/graphdb_language_SUITE.erl`        | Adds CT cases for `Language Literals` sub-group existence + reparenting verification                                             |
| `CLAUDE.md` (root)                                    | Worker responsibility text adjusted to mention sub-groups (small)                                                                |
| `apps/graphdb/CLAUDE.md`                              | Worker descriptions adjusted (small)                                                                                              |
| `TASKS.md`                                            | New L7 Engineering Hygiene entry, marked RESOLVED on land                                                                         |

Total expected: ~70 lines of source change, ~6 new CT cases, ~4 doc edits.

---

## Task 1: Add `create_literal_attribute/3` arity to graphdb_attr

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (export list, public function, gen_server handle_call)
- Test: `apps/graphdb/test/graphdb_attr_SUITE.erl` (new test case)

- [ ] **Step 1: Write the failing test**

Add to `graphdb_attr_SUITE.erl` in the `literals` test group:

```erlang
create_literal_attribute_under_custom_parent(_Config) ->
    {ok, _} = graphdb_attr:start_link(),
    %% Create a sub-group under Literals (7), then a literal attr under it.
    {ok, SubgroupNref} = graphdb_attr:create_literal_attribute(
        "test_subgroup", group, ?NREF_LITERALS),
    {ok, ChildNref} = graphdb_attr:create_literal_attribute(
        "test_child", integer, SubgroupNref),
    {ok, Child} = graphdb_attr:get_attribute(ChildNref),
    ?assertEqual([SubgroupNref], Child#node.parents).
```

Add `create_literal_attribute_under_custom_parent` to the `literals` group case list at the top of the file (around line ~70).

- [ ] **Step 2: Run test to verify it fails**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=create_literal_attribute_under_custom_parent`

Expected: FAIL with `undef` error — `graphdb_attr:create_literal_attribute/3` does not exist yet.

- [ ] **Step 3: Add `create_literal_attribute/3` to the export list**

In `apps/graphdb/src/graphdb_attr.erl`, find the `-export([...])` block that currently exports `create_literal_attribute/2` (around line 121). Change to:

```erlang
    create_literal_attribute/2,
    create_literal_attribute/3,
```

- [ ] **Step 4: Implement `create_literal_attribute/3` and delegate /2 to it**

Replace the existing `create_literal_attribute/2` definition (lines ~182-183) with:

```erlang
%%-----------------------------------------------------------------------------
%% create_literal_attribute(Name, Type) -> {ok, Nref} | {error, term()}
%%
%% Creates a new literal attribute node under the `Literals` subtree
%% (nref 7).  Equivalent to create_literal_attribute(Name, Type, ?NREF_LITERALS).
%%-----------------------------------------------------------------------------
create_literal_attribute(Name, Type) ->
    create_literal_attribute(Name, Type, ?NREF_LITERALS).

%%-----------------------------------------------------------------------------
%% create_literal_attribute(Name, Type, ParentNref) -> {ok, Nref} | {error, term()}
%%
%% Creates a new literal attribute node under ParentNref.  ParentNref
%% must be an attribute-kind node within the Literals subtree (or
%% ?NREF_LITERALS itself); the caller is responsible for that
%% invariant.  The Type argument is stored as an AVP keyed by the
%% seeded `literal_type` attribute.
%%-----------------------------------------------------------------------------
create_literal_attribute(Name, Type, ParentNref) ->
    gen_server:call(?MODULE,
        {create_literal_attribute, Name, Type, ParentNref}).
```

- [ ] **Step 5: Update the gen_server handle_call clause**

Replace the existing 3-element `{create_literal_attribute, Name, Type}` clause (around line 322-327) with the 4-element form:

```erlang
handle_call({create_literal_attribute, Name, Type, ParentNref}, _From,
        #state{literal_type_nref = TypeAttr} = State) ->
    Extra = [#{attribute => TypeAttr, value => Type},
             attr_type_avp(literal, State)],
    Reply = do_create_attribute(Name, ParentNref, Extra),
    {reply, Reply, State};
```

- [ ] **Step 6: Update graphdb_mgr's L4 routing to use /3 explicitly**

Find `apps/graphdb/src/graphdb_mgr.erl` and locate the `create_attribute` routing that calls `graphdb_attr:create_literal_attribute/2`. Verify the call site is `create_literal_attribute(Name, Type)` — leave it as /2 (it implicitly delegates to /3). No change required if the existing call site uses /2; only verify no caller still uses the old 3-element gen_server message form.

```bash
grep -rn "create_literal_attribute" /c/dev/SeerStoneGraphDb/apps/graphdb/src/
```

Confirm no source file uses the old gen_server message tuple `{create_literal_attribute, Name, Type}` (3-element). The only call sites should be `graphdb_attr:create_literal_attribute(Name, Type)` or `graphdb_attr:create_literal_attribute(Name, Type, Parent)` via the public API.

- [ ] **Step 7: Run test to verify it passes**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=create_literal_attribute_under_custom_parent`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "$(cat <<'EOF'
L7 Task 1: add create_literal_attribute/3 with explicit parent

Adds /3 arity so workers can seed literal attributes under their own
sub-group within the Literals subtree.  /2 delegates to /3 with
?NREF_LITERALS as the default parent, preserving the existing
public API for graphdb_mgr's L4 routing and any other /2 callers.

The new gen_server message is a 4-tuple; old callers are removed by
the /2 delegation.

+1 CT case under the literals group.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Refactor `ensure_seed` to accept a parent and seed `Attribute Literals`

**Files:**
- Modify: `apps/graphdb/src/graphdb_attr.erl` (record, init/1, ensure_seed, seeded_nrefs)

- [ ] **Step 1: Find the state record definition**

```bash
grep -n "^-record(state\|^state(" /c/dev/SeerStoneGraphDb/apps/graphdb/src/graphdb_attr.erl
```

Locate the `-record(state, {...})` definition in graphdb_attr.erl. Add a new field `attribute_literals_group_nref` to the record. The exact existing record will look something like:

```erlang
-record(state, {
    literal_type_nref,
    target_kind_nref,
    relationship_avp_nref,
    attribute_type_nref
}).
```

Update to:

```erlang
-record(state, {
    attribute_literals_group_nref,
    literal_type_nref,
    target_kind_nref,
    relationship_avp_nref,
    attribute_type_nref
}).
```

- [ ] **Step 2: Update `ensure_seed/1` → `ensure_seed/2` taking ParentNref**

Replace the existing `ensure_seed/1` definition (around line 408-417) with:

```erlang
%%-----------------------------------------------------------------------------
%% ensure_seed(Name, ParentNref) -> Nref
%%
%% Looks up an existing attribute by name under ParentNref; if not
%% found, creates it (node + taxonomy arc pair).  Throws {error, Reason}
%% on failure.  Caller chooses the parent — typically a sub-group node
%% under Literals (7) or the Literals root itself.
%%-----------------------------------------------------------------------------
ensure_seed(Name, ParentNref) ->
    case find_attribute_by_name(ParentNref, Name) of
        {ok, Nref} ->
            Nref;
        not_found ->
            case do_create_attribute(Name, ParentNref, []) of
                {ok, Nref}       -> Nref;
                {error, Reason}  -> throw({error, Reason})
            end
    end.
```

- [ ] **Step 3: Update `init/1` to seed `Attribute Literals` sub-group first, then reparent existing seeds**

Replace the existing `init/1` body (around line 290-311) with:

```erlang
init([]) ->
    try
        AttrLitNref = ensure_seed("Attribute Literals", ?NREF_LITERALS),
        State = #state{
            attribute_literals_group_nref = AttrLitNref,
            literal_type_nref     = ensure_seed("literal_type", AttrLitNref),
            target_kind_nref      = ensure_seed("target_kind", AttrLitNref),
            relationship_avp_nref = ensure_seed("relationship_avp", AttrLitNref),
            attribute_type_nref   = ensure_seed("attribute_type", AttrLitNref)
        },
        ok = ensure_template_avp_marker(State#state.relationship_avp_nref),
        ok = retro_stamp_bootstrap_attribute_types(
            State#state.attribute_type_nref),
        logger:info("graphdb_attr: started (attribute_literals_group=~p, "
            "literal_type=~p, target_kind=~p, relationship_avp=~p, "
            "attribute_type=~p)",
            [AttrLitNref, State#state.literal_type_nref,
             State#state.target_kind_nref, State#state.relationship_avp_nref,
             State#state.attribute_type_nref]),
        {ok, State}
    catch
        throw:{error, Reason} ->
            logger:error("graphdb_attr: seeding failed: ~p", [Reason]),
            {stop, {seed_failed, Reason}}
    end.
```

- [ ] **Step 4: Update `seeded_nrefs` handle_call to expose the new sub-group nref**

Replace the existing `seeded_nrefs` handle_call clause (around line 358-365) with:

```erlang
handle_call(seeded_nrefs, _From, State) ->
    Reply = {ok, #{
        attribute_literals_group => State#state.attribute_literals_group_nref,
        literal_type     => State#state.literal_type_nref,
        target_kind      => State#state.target_kind_nref,
        relationship_avp => State#state.relationship_avp_nref,
        attribute_type   => State#state.attribute_type_nref
    }},
    {reply, Reply, State};
```

- [ ] **Step 5: Compile and run the existing graphdb_attr_SUITE to find what breaks**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE`

Expected: The new test case from Task 1 passes; existing tests may pass or may need updating. If any test fails with "expected parent ?NREF_LITERALS but got ?NREF_ATTRIBUTE_LITERALS_GROUP" or similar, those failures will be addressed in Task 4. **Note any failing test names** for Task 4.

If the suite compiles and reports test outcomes (passes or fails), continue. If it fails to compile, fix the compile errors first.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_attr.erl
git commit -m "$(cat <<'EOF'
L7 Task 2: seed Attribute Literals sub-group; reparent attr seeds

ensure_seed/1 -> ensure_seed/2 taking ParentNref. init/1 seeds the
new Attribute Literals sub-group under Literals (7) first, then
seeds literal_type, target_kind, relationship_avp, attribute_type
as children of that sub-group.  attribute_literals_group_nref
field added to #state{} and exposed via seeded_nrefs/0.

retro_stamp_bootstrap_attribute_types is unchanged -- it walks
parents up to nref 7, so the new sub-group depth is transparent.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add CT cases asserting the Attribute Literals sub-group shape

**Files:**
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add two new test cases to `graphdb_attr_SUITE.erl`. Pick a sensible group (e.g., the existing `seeding` or `literals` group, or create a new `subgroups` group). The case list at the top of the file needs both new names added.

```erlang
seeds_attribute_literals_subgroup(_Config) ->
    {ok, _} = graphdb_attr:start_link(),
    {ok, #{attribute_literals_group := AttrLitNref}} =
        graphdb_attr:seeded_nrefs(),
    ?assert(is_integer(AttrLitNref)),
    ?assert(AttrLitNref >= 100000),
    {ok, Node} = graphdb_attr:get_attribute(AttrLitNref),
    ?assertEqual(attribute, Node#node.kind),
    ?assertEqual([?NREF_LITERALS], Node#node.parents).

reparents_attr_literal_seeds_under_subgroup(_Config) ->
    {ok, _} = graphdb_attr:start_link(),
    {ok, #{attribute_literals_group := AttrLitNref,
           literal_type             := Lt,
           target_kind              := Tk,
           relationship_avp         := Ra,
           attribute_type           := At}} = graphdb_attr:seeded_nrefs(),
    lists:foreach(
        fun(Nref) ->
            {ok, Node} = graphdb_attr:get_attribute(Nref),
            ?assertEqual([AttrLitNref], Node#node.parents)
        end,
        [Lt, Tk, Ra, At]).
```

Add both case names to the `seeding` group case list (or whichever group you placed them in).

- [ ] **Step 2: Run tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=seeds_attribute_literals_subgroup`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE --case=reparents_attr_literal_seeds_under_subgroup`

Expected: BOTH PASS (Task 2's implementation already established the structure these tests verify).

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "$(cat <<'EOF'
L7 Task 3: CT cases for Attribute Literals sub-group + reparenting

Two CT cases:
- seeds_attribute_literals_subgroup verifies the sub-group attribute
  node exists and is a direct child of nref 7.
- reparents_attr_literal_seeds_under_subgroup verifies literal_type,
  target_kind, relationship_avp, attribute_type all have the
  sub-group as their direct parent.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update any existing graphdb_attr CT cases that assert old parent

**Files:**
- Modify: `apps/graphdb/test/graphdb_attr_SUITE.erl`

- [ ] **Step 1: Search for assertions on old parent nref**

```bash
grep -n "NREF_LITERALS\|7," /c/dev/SeerStoneGraphDb/apps/graphdb/test/graphdb_attr_SUITE.erl | grep -i "parent\|assertEqual"
```

Review every hit. Any test that asserts a literal attr (literal_type, target_kind, relationship_avp, attribute_type) has `parents = [?NREF_LITERALS]` is now wrong — its parent is the sub-group nref.

If Task 2's commit caused any test in `graphdb_attr_SUITE` to fail (noted in Task 2 Step 5), those are the ones to fix here.

- [ ] **Step 2: Update each broken assertion to use the sub-group nref**

For each failing case, change patterns like:
```erlang
?assertEqual([?NREF_LITERALS], Node#node.parents)
```
to:
```erlang
{ok, #{attribute_literals_group := AttrLitNref}} = graphdb_attr:seeded_nrefs(),
?assertEqual([AttrLitNref], Node#node.parents)
```

If a test was asserting that a SEEDED nref (not a user-created one) has parent nref 7, that test should change as above. If a test creates a literal attr via `create_literal_attribute/2` and asserts its parent is nref 7, leave it alone — /2 still defaults to nref 7.

- [ ] **Step 3: Run the full graphdb_attr_SUITE**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_attr_SUITE`

Expected: All cases pass.

- [ ] **Step 4: Commit (only if changes were needed)**

If Step 2 made no changes (no existing test asserted the old parent), this task is a no-op — skip Step 4. Otherwise:

```bash
git add apps/graphdb/test/graphdb_attr_SUITE.erl
git commit -m "$(cat <<'EOF'
L7 Task 4: update graphdb_attr CT cases for sub-group parent

Existing assertions of parents=[?NREF_LITERALS] on seeded literal
attrs updated to use the new Attribute Literals sub-group nref.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Seed `Language Literals` sub-group in graphdb_language

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl` (state record, init/1, ensure_literal_seed, seeded_nrefs)

- [ ] **Step 1: Add `language_literals_group_nref` to state record**

```bash
grep -n "^-record(state" /c/dev/SeerStoneGraphDb/apps/graphdb/src/graphdb_language.erl
```

Add the new field to the `-record(state, {...})` definition. The existing record around line 85-95 looks like:

```erlang
-record(state, {
    lang_code_nref,
    lang_human_nref,
    base_language_nref,
    project_language_nref,
    env_language_code,
    registered,
    translation_hooks
}).
```

Update to:

```erlang
-record(state, {
    lang_code_nref,
    lang_human_nref,
    language_literals_group_nref,
    base_language_nref,
    project_language_nref,
    env_language_code,
    registered,
    translation_hooks
}).
```

- [ ] **Step 2: Update `ensure_literal_seed/1` → `ensure_literal_seed/2` taking ParentNref**

Replace the existing `ensure_literal_seed/1` definition (around line 400-435) with:

```erlang
%%---------------------------------------------------------------------
%% ensure_literal_seed(Name, ParentNref) -> Nref
%%
%% Looks up an attribute by name under ParentNref; creates a
%% literal-kind attribute node if absent.  Mirrors
%% graphdb_attr:ensure_seed/2 but inlined here so graphdb_language
%% does not have to call into graphdb_attr's internal API during its
%% own init.
%%---------------------------------------------------------------------
ensure_literal_seed(Name, ParentNref) ->
    case graphdb_attr:find_attribute_by_name(ParentNref, Name) of
        {ok, Nref} ->
            Nref;
        not_found ->
            Nref = nref_server:get_nref(),
            NameAVP = #{attribute => ?NAME_ATTR_ATTRIBUTE, value => Name},
            Node = #node{
                nref = Nref,
                kind = attribute,
                parents = [ParentNref],
                attribute_value_pairs = [NameAVP]
            },
            {Id1, Id2} = rel_id_server:get_id_pair(),
            P2C = #relationship{
                id             = Id1,
                kind           = taxonomy,
                source_nref    = ParentNref,
                characterization = ?ARC_ATTR_CHILD,
                target_nref    = Nref,
                reciprocal     = ?ARC_ATTR_PARENT,
                avps           = []
            },
            C2P = #relationship{
                id             = Id2,
                kind           = taxonomy,
                source_nref    = Nref,
                characterization = ?ARC_ATTR_PARENT,
                target_nref    = ParentNref,
                reciprocal     = ?ARC_ATTR_CHILD,
                avps           = []
            },
            F = fun() ->
                mnesia:write(nodes, Node, write),
                mnesia:write(relationships, P2C, write),
                mnesia:write(relationships, C2P, write)
            end,
            case mnesia:transaction(F) of
                {atomic, ok}  -> Nref;
                {aborted, R}  -> throw({error, R})
            end
    end.
```

(The body of the existing `ensure_literal_seed/1` already does these mnesia writes — you're keeping that logic and substituting `ParentNref` everywhere it currently has `?NREF_LITERALS`. Verify the full original body before replacing.)

- [ ] **Step 3: Update `init/1` to seed `Language Literals` sub-group first**

Find the current `init/1` body (around line 219-245). Locate the calls:

```erlang
BaseLangNref         = ensure_literal_seed("base_language"),
ProjectLangNref      = ensure_literal_seed("project_language"),
```

Insert a new line above them to seed the sub-group, then update both calls to use the sub-group as parent:

```erlang
LangLitNref          = ensure_literal_seed("Language Literals", ?NREF_LITERALS),
BaseLangNref         = ensure_literal_seed("base_language",     LangLitNref),
ProjectLangNref      = ensure_literal_seed("project_language",  LangLitNref),
```

In the `#state{...}` construction within init/1, add the new field:

```erlang
{ok, State#state{
    base_language_nref           = BaseLangNref,
    project_language_nref        = ProjectLangNref,
    language_literals_group_nref = LangLitNref,
    ...
```

(Preserve the existing field assignments; just add the new field.)

Also update the `logger:info` call's format string and argument list to include the new sub-group nref for diagnostic visibility:

```erlang
logger:info("graphdb_language: started "
    "(lang_code=~p, lang_human=~p, language_literals_group=~p, "
    "base_language=~p, project_language=~p, registered=~p)",
    [LcNref, LhNref, LangLitNref, BaseLangNref, ProjectLangNref, Registered]),
```

- [ ] **Step 4: Update `seeded_nrefs` handle_call to expose the new field**

Find the `handle_call(seeded_nrefs, ...)` clause (around line 251-258). Update its returned map to include the new key:

```erlang
handle_call(seeded_nrefs, _From,
        #state{lang_code_nref               = LC,
               lang_human_nref              = LH,
               language_literals_group_nref = LL,
               base_language_nref           = BL,
               project_language_nref        = PL,
               env_language_code            = ELC} = State) ->
    Reply = {ok, #{
        lang_code                => LC,
        lang_human               => LH,
        language_literals_group  => LL,
        base_language            => BL,
        project_language         => PL,
        env_language_code        => ELC
    }},
    {reply, Reply, State};
```

(If the existing map shape differs in field names — adapt accordingly. The point is to add a `language_literals_group => LL` key.)

- [ ] **Step 5: Compile and run the existing graphdb_language_SUITE**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_language_SUITE`

Expected: Compiles cleanly. Existing tests may pass or fail. **Note any failures** for Task 7.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_language.erl
git commit -m "$(cat <<'EOF'
L7 Task 5: seed Language Literals sub-group; reparent lang seeds

ensure_literal_seed/1 -> /2 taking ParentNref. init/1 seeds the
new Language Literals sub-group under Literals (7) first, then
seeds base_language and project_language as children of that
sub-group. language_literals_group_nref field added to #state{}
and exposed via seeded_nrefs/0.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add CT cases for Language Literals sub-group

**Files:**
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

- [ ] **Step 1: Write the failing tests**

Add two new CT cases to `graphdb_language_SUITE.erl`. Choose a suitable group (the existing `seeding` group is appropriate):

```erlang
seeds_language_literals_subgroup(_Config) ->
    {ok, #{language_literals_group := LangLitNref}} =
        graphdb_language:seeded_nrefs(),
    ?assert(is_integer(LangLitNref)),
    ?assert(LangLitNref >= 100000),
    {ok, Node} = graphdb_attr:get_attribute(LangLitNref),
    ?assertEqual(attribute, Node#node.kind),
    ?assertEqual([?NREF_LITERALS], Node#node.parents).

reparents_language_literal_seeds_under_subgroup(_Config) ->
    {ok, #{language_literals_group := LangLitNref,
           base_language           := BL,
           project_language        := PL}} =
        graphdb_language:seeded_nrefs(),
    {ok, BLNode} = graphdb_attr:get_attribute(BL),
    {ok, PLNode} = graphdb_attr:get_attribute(PL),
    ?assertEqual([LangLitNref], BLNode#node.parents),
    ?assertEqual([LangLitNref], PLNode#node.parents).
```

Add both case names to the `seeding` group case list (or whichever group you placed them in).

- [ ] **Step 2: Run tests to verify they pass**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_language_SUITE --case=seeds_language_literals_subgroup`
Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_language_SUITE --case=reparents_language_literal_seeds_under_subgroup`

Expected: BOTH PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "$(cat <<'EOF'
L7 Task 6: CT cases for Language Literals sub-group + reparenting

Two CT cases mirroring the Attribute Literals coverage:
- seeds_language_literals_subgroup verifies the sub-group attribute
  node exists and is a direct child of nref 7.
- reparents_language_literal_seeds_under_subgroup verifies
  base_language and project_language have the sub-group as parent.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update any existing graphdb_language CT cases that assert old parent

**Files:**
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

- [ ] **Step 1: Search for assertions on old parent nref**

```bash
grep -n "NREF_LITERALS\|7," /c/dev/SeerStoneGraphDb/apps/graphdb/test/graphdb_language_SUITE.erl | grep -i "parent\|assertEqual"
```

Review every hit. Any test asserting `base_language` or `project_language` has `parents = [?NREF_LITERALS]` is now wrong.

Failing tests noted in Task 5 Step 5 are the candidates here.

- [ ] **Step 2: Update each broken assertion to use the sub-group nref**

For each, change patterns like:
```erlang
?assertEqual([?NREF_LITERALS], Node#node.parents)
```
to:
```erlang
{ok, #{language_literals_group := LangLitNref}} = graphdb_language:seeded_nrefs(),
?assertEqual([LangLitNref], Node#node.parents)
```

- [ ] **Step 3: Run the full graphdb_language_SUITE**

Run: `./rebar3 ct --suite=apps/graphdb/test/graphdb_language_SUITE`

Expected: All cases pass.

- [ ] **Step 4: Commit (only if changes were needed)**

```bash
git add apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "$(cat <<'EOF'
L7 Task 7: update graphdb_language CT cases for sub-group parent

Existing assertions of parents=[?NREF_LITERALS] on base_language /
project_language seeds updated to use the new Language Literals
sub-group nref.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Documentation updates and TASKS.md L7 entry

**Files:**
- Modify: `TASKS.md`
- Modify: `CLAUDE.md` (root) — Bootstrap Nref Quick-Reference section may need an informational note
- Modify: `apps/graphdb/CLAUDE.md` — worker descriptions

- [ ] **Step 1: Add L7 entry to TASKS.md Engineering Hygiene section, marked RESOLVED**

Open `TASKS.md` and locate the Engineering Hygiene section. After the existing L5 entry, add:

```markdown
---

### L7. Literals subtree restructuring — **RESOLVED** (2026-05-25)

Literals subtree (nref 7) partitioned by owning subsystem so each
worker seeds its literal attributes under a dedicated sub-group:

- `Attribute Literals` — seeded by `graphdb_attr:init/1` (contains
  `literal_type`, `target_kind`, `relationship_avp`, `attribute_type`)
- `Language Literals` — seeded by `graphdb_language:init/1` (contains
  `base_language`, `project_language`)
- `Rule Literals` — seeded by `graphdb_rules:init/1` once F4 Phase A
  lands

`graphdb_attr:create_literal_attribute/3` arity added so callers can
specify a parent nref. `/2` retained as a delegating shim defaulting
to nref 7.

Clean-slate seeding; no runtime migration code.
```

- [ ] **Step 2: Update apps/graphdb/CLAUDE.md worker descriptions**

In `apps/graphdb/CLAUDE.md`, find the `graphdb_attr` section. Update the bootstrap line to mention the sub-group:

Old:
```
At bootstrap: seeds the `target_kind` literal attribute into the `Literals` subtree (nref 7) and the `relationship_avp` flag attribute
```

New:
```
At bootstrap: seeds the `Attribute Literals` sub-group under the `Literals` subtree (nref 7), then seeds `literal_type`, `target_kind`, `relationship_avp`, and `attribute_type` literal attributes as children of that sub-group. Also stamps the `relationship_avp` marker AVP on the bootstrap Template node and retro-stamps `attribute_type` AVPs across the Attributes subtree.
```

Similarly, update the `graphdb_language` section to mention `Language Literals` sub-group seeding alongside `base_language` and `project_language`.

- [ ] **Step 3: Update root CLAUDE.md if it carries a Literals-subtree shape diagram**

```bash
grep -n "Literals\|literal_type\|target_kind" /c/dev/SeerStoneGraphDb/CLAUDE.md
```

If the root `CLAUDE.md` describes the structure of nref 7 explicitly (e.g., enumerating its runtime-seeded children), add a one-line note about the sub-groups. The Bootstrap Nref Quick-Reference table itself does not need updating — the sub-groups are runtime seeds, not bootstrap nodes.

- [ ] **Step 4: Commit**

```bash
git add TASKS.md apps/graphdb/CLAUDE.md CLAUDE.md
git commit -m "$(cat <<'EOF'
L7 Task 8: TASKS.md L7 entry RESOLVED + doc refresh

Engineering Hygiene L7 added to TASKS.md and marked RESOLVED
(landed in this PR). apps/graphdb/CLAUDE.md worker descriptions
updated to mention the Attribute Literals and Language Literals
sub-groups.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Full-suite verification

**Files:** none modified

- [ ] **Step 1: Run the full test suite**

Run: `./rebar3 ct`

Expected: All CT suites pass. Test count should be **268 CT + 103 EUnit = 371** (was 267 + 103 = 370 before L7; +4 new CT cases minus any restructured cases — net change ~+4).

Actual delta depends on whether any old assertions were removed during Task 4 / Task 7 cleanup.

- [ ] **Step 2: Run EUnit**

Run: `./rebar3 eunit`

Expected: All 103 EUnit tests pass (none touched by L7).

- [ ] **Step 3: Verify no new compile warnings**

Run: `./rebar3 compile`

Expected: Compiles clean. Zero warnings. If new warnings appear, fix them before continuing.

- [ ] **Step 4: Verify the cache invariant**

The CT suites already run `graphdb_mgr:verify_caches/0 = ok` in their `end_per_testcase`. If the full CT run in Step 1 passed, the cache invariant is verified.

If desired, run an explicit check from the shell:

Run: `./rebar3 shell --apps seerstone --eval "application:start(nref), application:start(database), application:start(seerstone), {ok, ok} = {ok, graphdb_mgr:verify_caches()}, halt()."`

Expected: clean exit, no errors.

- [ ] **Step 5: Confirm the new structure with a one-shot inspection**

From the shell:

Run: `./rebar3 shell --apps seerstone --eval "application:start(nref), application:start(database), application:start(seerstone), {ok, AttrSeeds} = graphdb_attr:seeded_nrefs(), {ok, LangSeeds} = graphdb_language:seeded_nrefs(), io:format(\"~p~n~p~n\", [AttrSeeds, LangSeeds]), halt()."`

Expected output includes:
- A map with `attribute_literals_group` key pointing to an integer >= 100000
- A map with `language_literals_group` key pointing to an integer >= 100000
- Both `>=` lower-tier numerically (existing seeds were created first; sub-groups higher).

Actually, since the sub-groups are seeded FIRST in init/1 (Task 2 / Task 5), the sub-group nref will be LOWER than the literal-attr nrefs in fresh deployments. Existing deployments — n/a, clean slate per user instruction.

- [ ] **Step 6: No commit (verification only)**

If Steps 1-5 all pass, the L7 implementation is complete. Move to PR opening (outside this plan).

---

## Self-Review

**Spec coverage:** Each design-doc requirement maps to a task:

| Spec (F4 design §1 prerequisite)                                            | Task    |
|------------------------------------------------------------------------------|---------|
| Add `create_literal_attribute/3` arity                                       | Task 1  |
| Seed `Attribute Literals` sub-group; reparent attr seeds under it            | Tasks 2-4 |
| Seed `Language Literals` sub-group; reparent language seeds under it         | Tasks 5-7 |
| No runtime migration code                                                    | All tasks (clean-slate only) |
| Update documentation                                                          | Task 8  |
| Full-suite verification + cache invariant                                    | Task 9  |

**Placeholder scan:** No "TBD", no "implement later", no abstract instructions. Every code block contains the actual snippet to write.

**Type consistency:** Sub-group field names consistent across tasks:
- graphdb_attr: `attribute_literals_group_nref` (state field), `attribute_literals_group` (seeded_nrefs map key)
- graphdb_language: `language_literals_group_nref` (state field), `language_literals_group` (seeded_nrefs map key)

Function arities consistent: `ensure_seed/2`, `ensure_literal_seed/2`, `create_literal_attribute/3`.

**Open risks:**
- Existing graphdb_attr_SUITE and graphdb_language_SUITE may have more assertions on parents than the targeted grep can find (e.g., if a literal attr's nref is hardcoded somewhere). Tasks 4 and 7 are designed to surface these by running the full suite — any unexpected failure is investigated there.
- The `retro_stamp_bootstrap_attribute_types` logic walks parents up to nref 6/7/8 — the new sub-group depth (one extra step) is handled by the existing recursive walk; no code change needed.
