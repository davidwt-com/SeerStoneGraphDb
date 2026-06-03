# F4 Phase A — `graphdb_rules` Rule Engine (Data Model) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `graphdb_rules` stub with the Phase A data model: a runtime-seeded rule meta-ontology, a scope-aware create/retrieve API for composition and connection rules, and full validation — no rule-firing engine yet.

**Architecture:** A rule is a `kind = instance` node whose class membership is one of two seeded meta-classes (`CompositionRule`, `ConnectionRule`) under an abstract `Rule` root. Rule *content* lives in the instance node's AVPs; rule *deployment* (`mode`, `multiplicity`, `Template`) lives on an `applies_to`/`applied_by` connection-arc pair from the owning class to the rule instance. `graphdb_rules` writes each rule in a single Mnesia transaction and seeds its scaffold idempotently at `init/1`.

**Tech Stack:** Erlang/OTP 28, Mnesia (`disc_copies`), rebar3 (`./rebar3`), Common Test.

**Authoritative design:** `docs/designs/f4-graphdb-rules-design.md` (Phase A = §§1–8; decisions D1–D15; P1 RESOLVED).

---

## Architecture Notes (read before Task 1)

**Idempotent seeding — deviation from design §3.1 (decided 2026-06-02).**
The design's §3.1 seed list shows `graphdb_attr:create_literal_attribute/3`
and `graphdb_class:create_class/3` calls. Those public creators are **not
find-first** — calling them on every boot would create duplicate nodes and
fail `seeds_rule_meta_ontology_idempotent`. The established precedent
(`graphdb_language:init/1`) is to roll **local** idempotent ensure-helpers.
This plan follows that precedent:

- Literal attributes (the `Rule Literals` sub-group and its 6 children) are
  seeded with a local `ensure_seed/2` helper copied from
  `graphdb_language:ensure_literal_seed/2` — a plain `kind = attribute` node
  + taxonomy arc pair (chars `?ARC_ATTR_CHILD` / `?ARC_ATTR_PARENT`). This
  matches how `graphdb_attr` seeds its own `Attribute Literals` children and
  how `graphdb_language` seeds `base_language` / `project_language`. The
  per-literal value-type column in §3.1 (integer/atom/term) is informational
  only — Phase A enforces `mode`/`multiplicity` directly in
  `graphdb_rules` validation, not via a `literal_type` AVP, so the seeds are
  plain like every other seed and receive `attribute_type => literal` via the
  shared retro-stamp.
- The `applies_to` / `applied_by` relationship-attribute pair is seeded
  idempotently by checking `graphdb_attr:find_attribute_by_name/2` first,
  then calling `graphdb_attr:create_relationship_attribute_pair/4` only when
  absent.
- The three meta-classes are seeded with a local `ensure_meta_class/3` that
  checks a local `find_subclass_by_name/2` first, then calls
  `graphdb_class:create_class/3` only when absent.
- After seeding its literals, `init/1` calls
  `graphdb_attr:retro_stamp_attribute_types()` (exactly as
  `graphdb_language:init/1` does at its end) so the new Rule literals carry
  the `attribute_type` AVP.

**Supervisor reorder (design §3.3).** `graphdb_rules` currently sits at
position 4 in `graphdb_sup` (`graphdb_sup.erl:229`). It must move to **last**
so `graphdb_attr:*` and `graphdb_class:create_class` are available when its
`init/1` runs. The CT suite starts workers manually in dependency order, so
the reorder is *not* exercised by the rules suite. `graphdb_bootstrap_SUITE`
boots the full supervised tree — Task 1 runs it to confirm the reorder
doesn't break real-app startup now that `graphdb_rules:init/1` does real work.

**Write shape per rule (design §4.2).** Each `create_*_rule` allocates all
nrefs/ids *outside* the transaction, then in one transaction writes:

1. the rule instance node (`kind = instance`, `classes = [MetaClassNref]`,
   `parents = []`, content AVPs);
2. the instance↔class membership pair (chars `?ARC_INST_TO_CLASS` /
   `?ARC_CLASS_TO_INST`, `kind = instantiation`);
3. the `applies_to` / `applied_by` connection pair (`kind = connection`)
   between owning class and rule instance, the forward (`applies_to`) row
   carrying the Template + `mode` + `multiplicity` AVPs.

**seeded_nrefs/0 — 12 keys (design §3.2).** Keep these names byte-identical
across the state record, the `seeded_nrefs` handler, and every test:

```
rule, composition_rule, connection_rule,
applies_to, applied_by, rule_literals_group,
child_class_nref_attr, target_class_nref_attr, template_nref_attr,
characterization_nref_attr, mode_attr, multiplicity_attr
```

**Content-vs-deployment AVP split (design D6) — do not drift:**

| AVP                      | Lives on              | Attribute key (state field)     |
|--------------------------|-----------------------|---------------------------------|
| instance name            | rule node             | `?NAME_ATTR_INSTANCE` (20)      |
| `child_class_nref`       | CompositionRule node  | `child_class_nref_attr`         |
| `characterization_nref`  | ConnectionRule node   | `characterization_nref_attr`    |
| `target_class_nref`      | ConnectionRule node   | `target_class_nref_attr`        |
| `template_nref` (opt.)   | rule node             | `template_nref_attr`            |
| `Template` (index 0)     | `applies_to` arc      | `?ARC_TEMPLATE` (31)            |
| `mode`                   | `applies_to` arc      | `mode_attr`                     |
| `multiplicity`           | `applies_to` arc      | `multiplicity_attr`             |

---

## File Structure

- **Modify:** `apps/graphdb/src/graphdb_rules.erl` — replace the stub with the
  full Phase A worker (state, seeding, create, retrieve, validation, helpers).
- **Modify:** `apps/graphdb/src/graphdb_sup.erl:226-235` — move `graphdb_rules`
  childspec to last.
- **Create:** `apps/graphdb/test/graphdb_rules_SUITE.erl` — the CT suite
  (~30 cases across `seeding`, `composition`, `connection`, `validation`,
  `retrieval`, `scope`, `complex_scenarios`, `cache_audit`).
- **Modify (Task 8 docs):** `apps/graphdb/CLAUDE.md`, root `CLAUDE.md`,
  `ARCHITECTURE.md`, `TASKS.md`, `docs/diagrams/ontology-tree.md`.

All new code follows project conventions: 2008 SeerStone + 2026 David W.
Thomas copyright + SPDX `GPL-2.0-or-later`; revision block; NYI/UEM macros;
explicit `-export`; `-include("graphdb_nrefs.hrl")`. **The `node` and
`relationship` records are NOT in a shared header — every worker and every CT
suite defines them inline.** `graphdb_rules.erl` and `graphdb_rules_SUITE.erl`
must each define them inline, copied verbatim from `graphdb_instance.erl:78-94`:

```erlang
-record(node, {
    nref,                   %% integer() -- primary key
    kind,                   %% category | attribute | class | instance | template
    parents = [],           %% [integer()] -- cache of parent arcs (composition/taxonomy)
    classes = [],           %% [integer()] -- cache of instantiation arcs (instances only)
    attribute_value_pairs   %% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
    id,                     %% integer() -- primary key
    kind,                   %% taxonomy | composition | connection | instantiation
    source_nref,            %% integer() -- arc origin
    characterization,       %% integer() -- arc label (an attribute nref)
    target_nref,            %% integer() -- arc target
    reciprocal,             %% integer() -- arc label as seen from target back
    avps                    %% [#{attribute => Nref, value => term()}]
}).
```

---

## Task 1: Module scaffold, idempotent seeding, supervisor reorder

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl` (full rewrite of the stub)
- Modify: `apps/graphdb/src/graphdb_sup.erl:226-235`
- Create: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Create the CT suite with the seeding group (failing tests)**

Create `apps/graphdb/test/graphdb_rules_SUITE.erl`. Mirror the scaffolding of
`graphdb_instance_SUITE.erl` (`init_per_suite`, `setup_isolated_env`,
`init_per_testcase`, `end_per_testcase`, `verify_cache_invariant`) — copy
those helpers verbatim, change the scratch-dir prefix to `"rules_"`, and add
`graphdb_language`, `graphdb_query`, and `graphdb_rules` to the manual worker
start list in `init_per_testcase` (rules last), with matching `gen_server:stop`
calls in `end_per_testcase`.

```erlang
-module(graphdb_rules_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("graphdb/include/graphdb_nrefs.hrl").

%% Records are defined inline in every suite (no shared header) — copy
%% verbatim from graphdb_instance_SUITE.erl:24-40.
-record(node, {nref, kind, parents = [], classes = [],
               attribute_value_pairs}).
-record(relationship, {id, kind, source_nref, characterization,
                       target_nref, reciprocal, avps}).

-export([suite/0, all/0, groups/0,
         init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    %% seeding
    seeds_rule_meta_ontology_idempotent/1,
    seeds_rule_literals_subgroup/1,
    seeds_literal_attributes_under_rule_literals/1,
    seeds_applies_to_pair/1,
    seeded_nrefs_returns_all_twelve/1
]).

suite() -> [{timetrap, {seconds, 30}}].

all() -> [{group, seeding}].

groups() ->
    [{seeding, [], [
        seeds_rule_meta_ontology_idempotent,
        seeds_rule_literals_subgroup,
        seeds_literal_attributes_under_rule_literals,
        seeds_applies_to_pair,
        seeded_nrefs_returns_all_twelve
    ]}].

%% --- copy init_per_suite/setup_isolated_env/init_per_testcase/
%%     end_per_testcase/verify_cache_invariant from graphdb_instance_SUITE,
%%     starting workers in this order in init_per_testcase: rel_id_server,
%%     graphdb_nref (set_permanent_phase first), graphdb_mgr, graphdb_attr,
%%     graphdb_class, graphdb_instance, graphdb_language, graphdb_query,
%%     graphdb_rules. ---

seeds_rule_meta_ontology_idempotent(_Config) ->
    {ok, S1} = graphdb_rules:seeded_nrefs(),
    Rule  = maps:get(rule, S1),
    Comp  = maps:get(composition_rule, S1),
    Conn  = maps:get(connection_rule, S1),
    ?assert(is_integer(Rule)),
    %% Rule is abstract (L9): is_instantiable/1 = false
    ?assertEqual(false, graphdb_class:is_instantiable(Rule)),
    %% Comp/Conn are instantiable subclasses of Rule
    ?assertEqual(true, graphdb_class:is_instantiable(Comp)),
    ?assertEqual(true, graphdb_class:is_instantiable(Conn)),
    {ok, Subs} = graphdb_class:subclasses(Rule),
    ?assert(lists:member(Comp, Subs)),
    ?assert(lists:member(Conn, Subs)),
    %% Re-running init is a no-op: restart the worker, nrefs unchanged
    ok = gen_server:stop(graphdb_rules),
    {ok, _} = graphdb_rules:start_link(),
    {ok, S2} = graphdb_rules:seeded_nrefs(),
    ?assertEqual(S1, S2).

seeds_rule_literals_subgroup(_Config) ->
    {ok, S} = graphdb_rules:seeded_nrefs(),
    Grp = maps:get(rule_literals_group, S),
    {ok, #node{parents = Parents, kind = attribute}} =
        node_read(Grp),
    ?assert(lists:member(?NREF_LITERALS, Parents)).

seeds_literal_attributes_under_rule_literals(_Config) ->
    {ok, S} = graphdb_rules:seeded_nrefs(),
    Grp = maps:get(rule_literals_group, S),
    Keys = [child_class_nref_attr, target_class_nref_attr, template_nref_attr,
            characterization_nref_attr, mode_attr, multiplicity_attr],
    lists:foreach(fun(K) ->
        Nref = maps:get(K, S),
        {ok, #node{parents = Parents, kind = attribute}} = node_read(Nref),
        ?assert(lists:member(Grp, Parents))
    end, Keys).

seeds_applies_to_pair(_Config) ->
    {ok, S} = graphdb_rules:seeded_nrefs(),
    AppliesTo = maps:get(applies_to, S),
    AppliedBy = maps:get(applied_by, S),
    {ok, #node{parents = P1, kind = attribute}} = node_read(AppliesTo),
    {ok, #node{parents = P2, kind = attribute}} = node_read(AppliedBy),
    ?assert(lists:member(?NREF_INST_REL_ATTRS, P1)),
    ?assert(lists:member(?NREF_INST_REL_ATTRS, P2)).

seeded_nrefs_returns_all_twelve(_Config) ->
    {ok, S} = graphdb_rules:seeded_nrefs(),
    Expected = [rule, composition_rule, connection_rule,
                applies_to, applied_by, rule_literals_group,
                child_class_nref_attr, target_class_nref_attr,
                template_nref_attr, characterization_nref_attr,
                mode_attr, multiplicity_attr],
    lists:foreach(fun(K) -> ?assert(maps:is_key(K, S)) end, Expected),
    ?assertEqual(length(Expected), maps:size(S)).

%% Local test helper: dirty-read a node record.
node_read(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [N] -> {ok, N};
        []  -> not_found
    end.
```

- [ ] **Step 2: Run the seeding group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group seeding`
Expected: FAIL — `graphdb_rules:seeded_nrefs/0` is undefined (stub only exports
`start_link/0`), and `init/1` seeds nothing.

- [ ] **Step 3: Rewrite `graphdb_rules.erl` — header, exports, state, init, seeding helpers**

Replace the body of `apps/graphdb/src/graphdb_rules.erl` below the existing
copyright/revision/macro block. Keep the existing header block; bump the
revision history with a "Rev A — F4 Phase A" entry. Add includes and the new
exports, state record, `init/1`, the `seeded_nrefs` handler, and the seeding
helpers. (Create/retrieve handlers come in later tasks; for now `handle_call`
falls through to `?UEM` for any non-`seeded_nrefs` request.)

```erlang
-include("graphdb_nrefs.hrl").

%% node/relationship records are defined inline in every worker (no shared
%% header) — copied verbatim from graphdb_instance.erl:78-94.
-record(node, {
    nref, kind, parents = [], classes = [], attribute_value_pairs
}).
-record(relationship, {
    id, kind, source_nref, characterization, target_nref, reciprocal, avps
}).

-export([
    start_link/0,
    seeded_nrefs/0
]).

-export([
    init/1, handle_call/3, handle_cast/2,
    handle_info/2, terminate/2, code_change/3
]).

-record(state, {
    rule_nref,
    composition_rule_nref,
    connection_rule_nref,
    applies_to_nref,
    applied_by_nref,
    rule_literals_group_nref,
    child_class_nref_attr,
    target_class_nref_attr,
    template_nref_attr,
    characterization_nref_attr,
    mode_attr,
    multiplicity_attr
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

seeded_nrefs() ->
    gen_server:call(?MODULE, seeded_nrefs).

init([]) ->
    try
        RuleLitGrp = ensure_seed("Rule Literals", ?NREF_LITERALS),
        ChildClassAttr = ensure_seed("child_class_nref",      RuleLitGrp),
        TargetClassAttr = ensure_seed("target_class_nref",    RuleLitGrp),
        TemplateAttr   = ensure_seed("template_nref",         RuleLitGrp),
        CharAttr       = ensure_seed("characterization_nref", RuleLitGrp),
        ModeAttr       = ensure_seed("mode",                  RuleLitGrp),
        MultAttr       = ensure_seed("multiplicity",          RuleLitGrp),
        {AppliesTo, AppliedBy} =
            ensure_rel_attr_pair("applies_to", "applied_by",
                                 instance, ?NREF_INST_REL_ATTRS),
        InstAttr = instantiable_marker_nref(),
        RuleNref = ensure_meta_class("Rule", ?NREF_CLASSES,
                       [#{attribute => InstAttr, value => false}]),
        CompNref = ensure_meta_class("CompositionRule", RuleNref, []),
        ConnNref = ensure_meta_class("ConnectionRule",  RuleNref, []),
        ok = graphdb_attr:retro_stamp_attribute_types(),
        logger:info("graphdb_rules: started (rule=~p, composition_rule=~p, "
            "connection_rule=~p, applies_to=~p, applied_by=~p, "
            "rule_literals_group=~p)",
            [RuleNref, CompNref, ConnNref, AppliesTo, AppliedBy, RuleLitGrp]),
        {ok, #state{
            rule_nref                  = RuleNref,
            composition_rule_nref      = CompNref,
            connection_rule_nref       = ConnNref,
            applies_to_nref            = AppliesTo,
            applied_by_nref            = AppliedBy,
            rule_literals_group_nref   = RuleLitGrp,
            child_class_nref_attr      = ChildClassAttr,
            target_class_nref_attr     = TargetClassAttr,
            template_nref_attr         = TemplateAttr,
            characterization_nref_attr = CharAttr,
            mode_attr                  = ModeAttr,
            multiplicity_attr          = MultAttr
        }}
    catch
        throw:{error, Reason} ->
            logger:error("graphdb_rules: init failed: ~p", [Reason]),
            {stop, {init_failed, Reason}};
        _Class:Reason:Stack ->
            logger:error("graphdb_rules: init crashed: ~p ~p",
                [Reason, Stack]),
            {stop, {init_failed, Reason}}
    end.

handle_call(seeded_nrefs, _From, State) ->
    {reply, {ok, #{
        rule                       => State#state.rule_nref,
        composition_rule           => State#state.composition_rule_nref,
        connection_rule            => State#state.connection_rule_nref,
        applies_to                 => State#state.applies_to_nref,
        applied_by                 => State#state.applied_by_nref,
        rule_literals_group        => State#state.rule_literals_group_nref,
        child_class_nref_attr      => State#state.child_class_nref_attr,
        target_class_nref_attr     => State#state.target_class_nref_attr,
        template_nref_attr         => State#state.template_nref_attr,
        characterization_nref_attr => State#state.characterization_nref_attr,
        mode_attr                  => State#state.mode_attr,
        multiplicity_attr          => State#state.multiplicity_attr
    }}, State};
handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Message, State) ->
    ?UEM(handle_cast, {Message, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%---------------------------------------------------------------------
%% Seeding helpers (idempotent — see plan Architecture Notes)
%%---------------------------------------------------------------------

%% ensure_seed(Name, ParentNref) -> Nref
%% Plain attribute child of ParentNref (taxonomy arc pair). Copied from
%% graphdb_language:ensure_literal_seed/2.
ensure_seed(Name, ParentNref) ->
    case graphdb_attr:find_attribute_by_name(ParentNref, Name) of
        {ok, Nref} -> Nref;
        not_found ->
            Nref = graphdb_nref:get_next(),
            NameAVP = #{attribute => ?NAME_ATTR_ATTRIBUTE, value => Name},
            Node = #node{nref = Nref, kind = attribute,
                         parents = [ParentNref],
                         attribute_value_pairs = [NameAVP]},
            {Id1, Id2} = rel_id_server:get_id_pair(),
            P2C = #relationship{id = Id1, kind = taxonomy,
                source_nref = ParentNref, characterization = ?ARC_ATTR_CHILD,
                target_nref = Nref, reciprocal = ?ARC_ATTR_PARENT, avps = []},
            C2P = #relationship{id = Id2, kind = taxonomy,
                source_nref = Nref, characterization = ?ARC_ATTR_PARENT,
                target_nref = ParentNref, reciprocal = ?ARC_ATTR_CHILD,
                avps = []},
            F = fun() ->
                ok = mnesia:write(nodes, Node, write),
                ok = mnesia:write(relationships, P2C, write),
                ok = mnesia:write(relationships, C2P, write)
            end,
            case mnesia:transaction(F) of
                {atomic, ok}      -> Nref;
                {aborted, Reason} -> throw({error, Reason})
            end
    end.

%% ensure_rel_attr_pair/4 -> {AppliesToNref, AppliedByNref}
ensure_rel_attr_pair(Name, RecipName, TargetKind, ParentNref) ->
    case graphdb_attr:find_attribute_by_name(ParentNref, Name) of
        {ok, FwdNref} ->
            {ok, RevNref} = graphdb_attr:find_attribute_by_name(ParentNref,
                                                                RecipName),
            {FwdNref, RevNref};
        not_found ->
            case graphdb_attr:create_relationship_attribute_pair(
                     Name, RecipName, TargetKind, ParentNref) of
                {ok, {FwdNref, RevNref}} -> {FwdNref, RevNref};
                {error, Reason}          -> throw({error, Reason})
            end
    end.

%% ensure_meta_class/3 -> ClassNref (find-first, else create_class/3)
ensure_meta_class(Name, ParentNref, AVPs) ->
    case find_subclass_by_name(ParentNref, Name) of
        {ok, Nref} -> Nref;
        not_found ->
            case graphdb_class:create_class(Name, ParentNref, AVPs) of
                {ok, Nref}      -> Nref;
                {error, Reason} -> throw({error, Reason})
            end
    end.

%% find_subclass_by_name/2 -> {ok, Nref} | not_found
%% Taxonomy children of ParentNref whose class-name AVP matches Name.
find_subclass_by_name(ParentNref, Name) ->
    F = fun() ->
        Arcs = mnesia:index_read(relationships, ParentNref,
                                 #relationship.source_nref),
        Nrefs = [A#relationship.target_nref || A <- Arcs,
                 A#relationship.kind == taxonomy,
                 A#relationship.characterization == ?ARC_CLS_CHILD],
        Nodes = lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, Nrefs),
        lists:search(fun(N) -> class_has_name(N, Name) end, Nodes)
    end,
    case mnesia:transaction(F) of
        {atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
        {atomic, false}                       -> not_found;
        {aborted, Reason}                     -> throw({error, Reason})
    end.

class_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
    lists:any(fun
        (#{attribute := ?NAME_ATTR_CLASS, value := V}) -> V == Name;
        (_) -> false
    end, AVPs).

%% instantiable_marker_nref/0 -> InstAttrNref
%% Reads the seeded `instantiable` marker nref from graphdb_attr (L9).
instantiable_marker_nref() ->
    {ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
    InstAttr.
```

- [ ] **Step 4: Move `graphdb_rules` to the last childspec in `graphdb_sup.erl`**

In `apps/graphdb/src/graphdb_sup.erl:226-235`, renumber so `graphdb_rules` is
last. Replace the block with:

```erlang
	{ok, ChSpecN} = childspec(graphdb_nref),
	{ok, ChSpec0} = childspec(rel_id_server),
	{ok, ChSpec1} = childspec(graphdb_mgr),
	{ok, ChSpec2} = childspec(graphdb_attr),
	{ok, ChSpec3} = childspec(graphdb_class),
	{ok, ChSpec4} = childspec(graphdb_instance),
	{ok, ChSpec5} = childspec(graphdb_language),
	{ok, ChSpec6} = childspec(graphdb_query),
	{ok, ChSpec7} = childspec(graphdb_rules),
	{ok, {SupFlags, [ChSpecN, ChSpec0, ChSpec1, ChSpec2, ChSpec3, ChSpec4, ChSpec5, ChSpec6, ChSpec7]}};
```

- [ ] **Step 5: Compile and run the seeding group + the bootstrap suite**

Run: `./rebar3 compile`
Expected: clean, zero warnings.

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group seeding`
Expected: PASS (5 cases).

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_bootstrap_SUITE`
Expected: PASS — confirms the supervisor reorder did not break full-tree boot
with `graphdb_rules:init/1` now doing real seeding work.

- [ ] **Step 6: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/src/graphdb_sup.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: graphdb_rules seeding + meta-ontology + sup reorder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `create_composition_rule` (happy path)

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add the `composition` group and its tests (failing)**

Add to `-export` and `groups/0` a `composition` group, and add `{group,
composition}` to `all/0`. Add these test bodies. They use a small local setup
helper `make_class(Name)` that creates a domain class under `?NREF_CLASSES`
and returns its nref.

```erlang
%% in groups/0:
{composition, [], [
    creates_composition_rule_minimal,
    creates_composition_rule_with_template,
    applies_to_arc_pair_written,
    instance_to_class_membership_written,
    avps_present_and_correct
]}

make_class(Name) ->
    {ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES),
    Nref.

creates_composition_rule_minimal(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "car-has-engine", Parent, Child, mandatory, 1),
    ?assert(is_integer(RuleNref)),
    {ok, #node{kind = instance, classes = Classes}} = node_read2(RuleNref),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    ?assertEqual([maps:get(composition_rule, S)], Classes).

creates_composition_rule_with_template(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Wheel"),
    {ok, DT} = graphdb_class:default_template(Parent),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "car-has-wheel", Parent, Child, auto, 4, DT),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    TemplateAttr = maps:get(template_nref_attr, S),
    {ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
    ?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

applies_to_arc_pair_written(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "car-has-engine", Parent, Child, mandatory, 1),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    AppliesTo = maps:get(applies_to, S),
    AppliedBy = maps:get(applied_by, S),
    ModeAttr  = maps:get(mode_attr, S),
    MultAttr  = maps:get(multiplicity_attr, S),
    {ok, DT}  = graphdb_class:default_template(Parent),
    Fwd = read_arc(Parent, AppliesTo, RuleNref),
    Rev = read_arc(RuleNref, AppliedBy, Parent),
    ?assertEqual(connection, Fwd#relationship.kind),
    ?assertEqual(connection, Rev#relationship.kind),
    FAVPs = Fwd#relationship.avps,
    ?assert(lists:member(#{attribute => ?ARC_TEMPLATE, value => DT}, FAVPs)),
    ?assert(lists:member(#{attribute => ModeAttr, value => mandatory}, FAVPs)),
    ?assert(lists:member(#{attribute => MultAttr, value => 1}, FAVPs)).

instance_to_class_membership_written(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "car-has-engine", Parent, Child, mandatory, 1),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    Comp = maps:get(composition_rule, S),
    I2C = read_arc(RuleNref, ?ARC_INST_TO_CLASS, Comp),
    C2I = read_arc(Comp, ?ARC_CLASS_TO_INST, RuleNref),
    ?assertEqual(instantiation, I2C#relationship.kind),
    ?assertEqual(instantiation, C2I#relationship.kind).

avps_present_and_correct(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    {ok, RuleNref} = graphdb_rules:create_composition_rule(
        environment, "car-has-engine", Parent, Child, mandatory, 1),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    ChildAttr = maps:get(child_class_nref_attr, S),
    {ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
    ?assert(lists:member(#{attribute => ?NAME_ATTR_INSTANCE,
                           value => "car-has-engine"}, AVPs)),
    ?assert(lists:member(#{attribute => ChildAttr, value => Child}, AVPs)),
    %% no deployment AVPs leaked onto the node
    ModeAttr = maps:get(mode_attr, S),
    ?assertNot(lists:any(fun(#{attribute := A}) -> A == ModeAttr end, AVPs)).

%% helpers
node_read2(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [N] -> {ok, N};
        []  -> not_found
    end.

read_arc(Source, Char, Target) ->
    Arcs = mnesia:dirty_index_read(relationships, Source,
                                   #relationship.source_nref),
    [Arc] = [A || A <- Arcs,
             A#relationship.characterization == Char,
             A#relationship.target_nref == Target],
    Arc.
```

- [ ] **Step 2: Run the composition group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group composition`
Expected: FAIL — `graphdb_rules:create_composition_rule/6,7` undefined.

- [ ] **Step 3: Implement `create_composition_rule/6,7` + the shared write path**

Add to `-export`: `create_composition_rule/6`, `create_composition_rule/7`.
Add the public functions, the `handle_call` clauses, and the shared writer.

```erlang
create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult) ->
    create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
                            undefined).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
                        TemplateNref) ->
    gen_server:call(?MODULE,
        {create_composition_rule, Scope, Name, ParentClass, ChildClass,
         Mode, Mult, TemplateNref}).

%% handle_call clause (place above the seeded_nrefs clause is fine; order
%% only matters for the catch-all ?UEM clause, which must stay last):
handle_call({create_composition_rule, environment, Name, ParentClass,
             ChildClass, Mode, Mult, TemplateNref}, _From, State) ->
    ContentAVPs = [#{attribute => State#state.child_class_nref_attr,
                     value => ChildClass}
                   | optional_template_avp(TemplateNref, State)],
    Reply = do_create_rule(State#state.composition_rule_nref, Name,
                ParentClass, ContentAVPs, Mode, Mult, State),
    {reply, Reply, State};
handle_call({create_composition_rule, {project, _}, _, _, _, _, _, _},
            _From, State) ->
    {reply, {error, project_rules_not_yet_supported}, State};

%% shared writer — used by both rule kinds
%% (Validation is added in Task 4; for now it writes directly.)
do_create_rule(MetaClassNref, Name, OwningClass, ContentAVPs, Mode, Mult,
               State) ->
    {ok, DefaultTemplate} = graphdb_class:default_template(OwningClass),
    RuleNref = graphdb_nref:get_next(),
    {MembId1, MembId2} = rel_id_server:get_id_pair(),
    {ConnId1, ConnId2} = rel_id_server:get_id_pair(),
    NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
    Node = #node{nref = RuleNref, kind = instance, parents = [],
                 classes = [MetaClassNref],
                 attribute_value_pairs = [NameAVP | ContentAVPs]},
    I2C = #relationship{id = MembId1, kind = instantiation,
        source_nref = RuleNref, characterization = ?ARC_INST_TO_CLASS,
        target_nref = MetaClassNref, reciprocal = ?ARC_CLASS_TO_INST,
        avps = []},
    C2I = #relationship{id = MembId2, kind = instantiation,
        source_nref = MetaClassNref, characterization = ?ARC_CLASS_TO_INST,
        target_nref = RuleNref, reciprocal = ?ARC_INST_TO_CLASS, avps = []},
    DeployAVPs = [#{attribute => ?ARC_TEMPLATE, value => DefaultTemplate},
                  #{attribute => State#state.mode_attr, value => Mode},
                  #{attribute => State#state.multiplicity_attr, value => Mult}],
    AppliesTo = #relationship{id = ConnId1, kind = connection,
        source_nref = OwningClass, characterization = State#state.applies_to_nref,
        target_nref = RuleNref, reciprocal = State#state.applied_by_nref,
        avps = DeployAVPs},
    AppliedBy = #relationship{id = ConnId2, kind = connection,
        source_nref = RuleNref, characterization = State#state.applied_by_nref,
        target_nref = OwningClass, reciprocal = State#state.applies_to_nref,
        avps = []},
    Txn = fun() ->
        ok = mnesia:write(nodes, Node, write),
        ok = mnesia:write(relationships, I2C, write),
        ok = mnesia:write(relationships, C2I, write),
        ok = mnesia:write(relationships, AppliesTo, write),
        ok = mnesia:write(relationships, AppliedBy, write)
    end,
    case mnesia:transaction(Txn) of
        {atomic, ok}      -> {ok, RuleNref};
        {aborted, Reason} -> {error, Reason}
    end.

optional_template_avp(undefined, _State) -> [];
optional_template_avp(TemplateNref, State) ->
    [#{attribute => State#state.template_nref_attr, value => TemplateNref}].
```

- [ ] **Step 4: Run the composition group to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group composition`
Expected: PASS (5 cases).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: create_composition_rule + shared rule writer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `create_connection_rule` (happy path)

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add the `connection` group and its tests (failing)**

Add `{group, connection}` to `all/0`, the group to `groups/0`, and the exports.
The connection rule needs a relationship-attribute characterization; create one
with `graphdb_attr:create_relationship_attribute_pair/3`.

```erlang
{connection, [], [
    creates_connection_rule_minimal,
    creates_connection_rule_with_template,
    instance_to_class_membership_to_connection_rule
]}

make_rel_char(Name, Recip) ->
    {ok, {Fwd, _Rev}} =
        graphdb_attr:create_relationship_attribute_pair(Name, Recip, class),
    Fwd.

creates_connection_rule_minimal(_Config) ->
    Source = make_class("Order"),
    Target = make_class("Customer"),
    Char   = make_rel_char("placed_by", "placed"),
    {ok, RuleNref} = graphdb_rules:create_connection_rule(
        environment, "order-placed-by-customer", Source, Char, Target,
        mandatory, 1),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    CharAttr   = maps:get(characterization_nref_attr, S),
    TargetAttr = maps:get(target_class_nref_attr, S),
    {ok, #node{kind = instance, classes = Classes,
               attribute_value_pairs = AVPs}} = node_read2(RuleNref),
    ?assertEqual([maps:get(connection_rule, S)], Classes),
    ?assert(lists:member(#{attribute => CharAttr, value => Char}, AVPs)),
    ?assert(lists:member(#{attribute => TargetAttr, value => Target}, AVPs)).

creates_connection_rule_with_template(_Config) ->
    Source = make_class("Order"),
    Target = make_class("Customer"),
    Char   = make_rel_char("placed_by", "placed"),
    {ok, DT} = graphdb_class:default_template(Source),
    {ok, RuleNref} = graphdb_rules:create_connection_rule(
        environment, "order-placed-by-customer", Source, Char, Target,
        propose, unbounded, DT),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    TemplateAttr = maps:get(template_nref_attr, S),
    {ok, #node{attribute_value_pairs = AVPs}} = node_read2(RuleNref),
    ?assert(lists:member(#{attribute => TemplateAttr, value => DT}, AVPs)).

instance_to_class_membership_to_connection_rule(_Config) ->
    Source = make_class("Order"),
    Target = make_class("Customer"),
    Char   = make_rel_char("placed_by", "placed"),
    {ok, RuleNref} = graphdb_rules:create_connection_rule(
        environment, "order-placed-by-customer", Source, Char, Target,
        mandatory, 1),
    {ok, S} = graphdb_rules:seeded_nrefs(),
    Conn = maps:get(connection_rule, S),
    I2C = read_arc(RuleNref, ?ARC_INST_TO_CLASS, Conn),
    ?assertEqual(instantiation, I2C#relationship.kind).
```

- [ ] **Step 2: Run the connection group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group connection`
Expected: FAIL — `create_connection_rule/7,8` undefined.

- [ ] **Step 3: Implement `create_connection_rule/7,8`**

Add to `-export`: `create_connection_rule/7`, `create_connection_rule/8`.

```erlang
create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
                       Mult) ->
    create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
                           Mult, undefined).

create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
                       Mult, TemplateNref) ->
    gen_server:call(?MODULE,
        {create_connection_rule, Scope, Name, SourceClass, Char, TargetClass,
         Mode, Mult, TemplateNref}).

handle_call({create_connection_rule, environment, Name, SourceClass, Char,
             TargetClass, Mode, Mult, TemplateNref}, _From, State) ->
    ContentAVPs = [#{attribute => State#state.characterization_nref_attr,
                     value => Char},
                   #{attribute => State#state.target_class_nref_attr,
                     value => TargetClass}
                   | optional_template_avp(TemplateNref, State)],
    Reply = do_create_rule(State#state.connection_rule_nref, Name,
                SourceClass, ContentAVPs, Mode, Mult, State),
    {reply, Reply, State};
handle_call({create_connection_rule, {project, _}, _, _, _, _, _, _, _},
            _From, State) ->
    {reply, {error, project_rules_not_yet_supported}, State};
```

- [ ] **Step 4: Run the connection group to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group connection`
Expected: PASS (3 cases).

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: create_connection_rule

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Validation

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add the `validation` group and its tests (failing)**

Add `{group, validation}` to `all/0`, the group, and exports. Each test
asserts the specific error atom AND that nothing was written (compare
`nodes`-table size before/after via `table_size(nodes)`).

```erlang
{validation, [], [
    class_not_found_rejected,
    not_a_class_rejected,
    abstract_owning_class_rejected,
    referenced_class_not_found_rejected,
    referenced_not_a_class_rejected,
    characterization_not_found_rejected,
    not_a_relationship_attribute_rejected,
    template_not_found_rejected,
    not_a_template_rejected,
    invalid_mode_rejected,
    invalid_multiplicity_rejected,
    failed_validation_consumes_no_nref
]}

table_size(Tab) -> mnesia:table_info(Tab, size).

%% An abstract owning class (L9 instantiable=false) has no default template
%% to scope the applies_to arc, so it must be rejected — not badmatch in
%% do_create_rule. make_abstract_class/1 stamps the instantiable=false marker.
make_abstract_class(Name) ->
    {ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
    {ok, Nref} = graphdb_class:create_class(Name, ?NREF_CLASSES,
                     [#{attribute => InstAttr, value => false}]),
    Nref.

abstract_owning_class_rejected(_Config) ->
    Abstract = make_abstract_class("AbstractCar"),
    Child    = make_class("Engine"),
    Before   = table_size(nodes),
    ?assertEqual({error, owning_class_has_no_default_template},
        graphdb_rules:create_composition_rule(
            environment, "x", Abstract, Child, mandatory, 1)),
    ?assertEqual(Before, table_size(nodes)).

class_not_found_rejected(_Config) ->
    Child = make_class("Engine"),
    Before = table_size(nodes),
    ?assertEqual({error, class_not_found},
        graphdb_rules:create_composition_rule(
            environment, "x", 999999, Child, mandatory, 1)),
    ?assertEqual(Before, table_size(nodes)).

not_a_class_rejected(_Config) ->
    Child = make_class("Engine"),
    %% nref 6 (Names) is an attribute, not a class
    ?assertEqual({error, not_a_class},
        graphdb_rules:create_composition_rule(
            environment, "x", ?NREF_NAMES, Child, mandatory, 1)).

referenced_class_not_found_rejected(_Config) ->
    Parent = make_class("Car"),
    ?assertEqual({error, referenced_class_not_found},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, 999999, mandatory, 1)).

referenced_not_a_class_rejected(_Config) ->
    Parent = make_class("Car"),
    ?assertEqual({error, referenced_not_a_class},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, ?NREF_NAMES, mandatory, 1)).

characterization_not_found_rejected(_Config) ->
    Source = make_class("Order"),
    Target = make_class("Customer"),
    ?assertEqual({error, characterization_not_found},
        graphdb_rules:create_connection_rule(
            environment, "x", Source, 999999, Target, mandatory, 1)).

not_a_relationship_attribute_rejected(_Config) ->
    Source = make_class("Order"),
    Target = make_class("Customer"),
    %% a literal attribute, not a relationship attribute
    {ok, Lit} = graphdb_attr:create_literal_attribute("weight", integer),
    ?assertEqual({error, not_a_relationship_attribute},
        graphdb_rules:create_connection_rule(
            environment, "x", Source, Lit, Target, mandatory, 1)).

template_not_found_rejected(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    ?assertEqual({error, template_not_found},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, mandatory, 1, 999999)).

not_a_template_rejected(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    %% Child is a class, not a template
    ?assertEqual({error, not_a_template},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, mandatory, 1, Child)).

invalid_mode_rejected(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    ?assertEqual({error, invalid_mode},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, bogus, 1)).

invalid_multiplicity_rejected(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    ?assertEqual({error, invalid_multiplicity},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, mandatory, 0)),
    ?assertEqual({error, invalid_multiplicity},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, mandatory, "lots")).

failed_validation_consumes_no_nref(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    %% graphdb_nref has no peek API (only get_next/0); assert no node was
    %% written, which proves the write path never ran and consumed no nref.
    Before = table_size(nodes),
    ?assertEqual({error, invalid_mode},
        graphdb_rules:create_composition_rule(
            environment, "x", Parent, Child, bogus, 1)),
    ?assertEqual(Before, table_size(nodes)).
```

Validation runs entirely *before* `do_create_rule` allocates any nref, so a
rejected create writes nothing — the table-size assertion is the contract.

- [ ] **Step 2: Run the validation group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group validation`
Expected: FAIL — rules are written (or crash) because no validation runs yet.

- [ ] **Step 3: Add a validation front-end to both create paths**

Validate *before* allocating any nref. Add `validate_common/5` and route both
`handle_call` create clauses through it. `mode`/`multiplicity` are validated
first (pure), then class/reference/template lookups via `mnesia:dirty_read`.
Use `graphdb_attr:attribute_type_of/1` to confirm a characterization is a
relationship attribute.

**Also harden `do_create_rule/7` (defense-in-depth).** Task 2 wrote it with a
hard match `{ok, DefaultTemplate} = graphdb_class:default_template(OwningClass)`.
`validate_owning_class/1` now rejects an owning class with no default template
*before* the writer runs, so the writer never sees `not_found` in practice —
but change the hard match to a `case` so a future caller path can't badmatch:

```erlang
do_create_rule(MetaClassNref, Name, OwningClass, ContentAVPs, Mode, Mult,
               State) ->
    case graphdb_class:default_template(OwningClass) of
        not_found ->
            {error, owning_class_has_no_default_template};
        {ok, DefaultTemplate} ->
            %% ... unchanged body: allocate nrefs/ids, build records,
            %%     write node + 29/30 pair + applies_to/applied_by pair ...
    end.
```

```erlang
%% Composition create clause becomes:
handle_call({create_composition_rule, environment, Name, ParentClass,
             ChildClass, Mode, Mult, TemplateNref}, _From, State) ->
    Reply = case validate_composition(ParentClass, ChildClass, Mode, Mult,
                                      TemplateNref) of
        ok ->
            ContentAVPs = [#{attribute => State#state.child_class_nref_attr,
                             value => ChildClass}
                           | optional_template_avp(TemplateNref, State)],
            do_create_rule(State#state.composition_rule_nref, Name,
                ParentClass, ContentAVPs, Mode, Mult, State);
        {error, _} = Err -> Err
    end,
    {reply, Reply, State};

%% Connection create clause becomes:
handle_call({create_connection_rule, environment, Name, SourceClass, Char,
             TargetClass, Mode, Mult, TemplateNref}, _From, State) ->
    Reply = case validate_connection(SourceClass, Char, TargetClass, Mode,
                                     Mult, TemplateNref) of
        ok ->
            ContentAVPs = [#{attribute => State#state.characterization_nref_attr,
                             value => Char},
                           #{attribute => State#state.target_class_nref_attr,
                             value => TargetClass}
                           | optional_template_avp(TemplateNref, State)],
            do_create_rule(State#state.connection_rule_nref, Name,
                SourceClass, ContentAVPs, Mode, Mult, State);
        {error, _} = Err -> Err
    end,
    {reply, Reply, State};

%% --- validators ---
validate_composition(ParentClass, ChildClass, Mode, Mult, TemplateNref) ->
    chain([
        fun() -> validate_mode(Mode) end,
        fun() -> validate_multiplicity(Mult) end,
        fun() -> validate_owning_class(ParentClass) end,
        fun() -> validate_referenced_class(ChildClass) end,
        fun() -> validate_template(TemplateNref) end
    ]).

validate_connection(SourceClass, Char, TargetClass, Mode, Mult, TemplateNref) ->
    chain([
        fun() -> validate_mode(Mode) end,
        fun() -> validate_multiplicity(Mult) end,
        fun() -> validate_owning_class(SourceClass) end,
        fun() -> validate_referenced_class(TargetClass) end,
        fun() -> validate_characterization(Char) end,
        fun() -> validate_template(TemplateNref) end
    ]).

%% Run validators in order; first error wins.
chain([]) -> ok;
chain([F | Rest]) ->
    case F() of
        ok               -> chain(Rest);
        {error, _} = Err -> Err
    end.

validate_mode(M) when M == mandatory; M == auto; M == propose -> ok;
validate_mode(_) -> {error, invalid_mode}.

validate_multiplicity(unbounded) -> ok;
validate_multiplicity(N) when is_integer(N), N >= 1 -> ok;
validate_multiplicity(_) -> {error, invalid_multiplicity}.

validate_owning_class(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = class}] ->
            %% The applies_to arc stamps the owning class's default template
            %% (deployment AVP index 0). An abstract class (L9 marker) or a
            %% class whose default was deleted ("forced disambiguation") has
            %% none — reject rather than let do_create_rule badmatch.
            case graphdb_class:default_template(Nref) of
                {ok, _}   -> ok;
                not_found -> {error, owning_class_has_no_default_template}
            end;
        [#node{}]             -> {error, not_a_class};
        []                    -> {error, class_not_found}
    end.

validate_referenced_class(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = class}] -> ok;
        [#node{}]             -> {error, referenced_not_a_class};
        []                    -> {error, referenced_class_not_found}
    end.

validate_characterization(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [] -> {error, characterization_not_found};
        [#node{}] ->
            case graphdb_attr:attribute_type_of(Nref) of
                {ok, relationship} -> ok;
                _                  -> {error, not_a_relationship_attribute}
            end
    end.

validate_template(undefined) -> ok;
validate_template(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = template}] -> ok;
        [#node{}]                -> {error, not_a_template};
        []                       -> {error, template_not_found}
    end.
```

- [ ] **Step 4: Run the validation group + the prior groups to verify all pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group validation`
Expected: PASS (12 cases — the original 11 plus `abstract_owning_class_rejected`).

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS — seeding + composition + connection + validation all green.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: rule-creation validation catalog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Retrieval

**Files:**
- Modify: `apps/graphdb/src/graphdb_rules.erl`
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add the `retrieval` group and its tests (failing)**

```erlang
{retrieval, [], [
    rules_for_class_returns_all_kinds,
    composition_rules_for_class_filters_by_kind,
    connection_rules_for_class_filters_by_kind,
    get_rule_returns_full_record,
    get_rule_not_found,
    list_rules_returns_all
]}

rules_for_class_returns_all_kinds(_Config) ->
    Car   = make_class("Car"),
    Eng   = make_class("Engine"),
    Maker = make_class("Manufacturer"),
    Char  = make_rel_char("made_by", "makes"),
    {ok, R1} = graphdb_rules:create_composition_rule(
        environment, "has-engine", Car, Eng, mandatory, 1),
    {ok, R2} = graphdb_rules:create_connection_rule(
        environment, "made-by", Car, Char, Maker, mandatory, 1),
    {ok, Rules} = graphdb_rules:rules_for_class(environment, Car),
    Nrefs = [N#node.nref || N <- Rules],
    ?assertEqual(lists:sort([R1, R2]), lists:sort(Nrefs)).

composition_rules_for_class_filters_by_kind(_Config) ->
    Car   = make_class("Car"),
    Eng   = make_class("Engine"),
    Maker = make_class("Manufacturer"),
    Char  = make_rel_char("made_by", "makes"),
    {ok, R1} = graphdb_rules:create_composition_rule(
        environment, "has-engine", Car, Eng, mandatory, 1),
    {ok, _R2} = graphdb_rules:create_connection_rule(
        environment, "made-by", Car, Char, Maker, mandatory, 1),
    {ok, Comp} = graphdb_rules:composition_rules_for_class(environment, Car),
    ?assertEqual([R1], [N#node.nref || N <- Comp]).

connection_rules_for_class_filters_by_kind(_Config) ->
    Car   = make_class("Car"),
    Eng   = make_class("Engine"),
    Maker = make_class("Manufacturer"),
    Char  = make_rel_char("made_by", "makes"),
    {ok, _R1} = graphdb_rules:create_composition_rule(
        environment, "has-engine", Car, Eng, mandatory, 1),
    {ok, R2} = graphdb_rules:create_connection_rule(
        environment, "made-by", Car, Char, Maker, mandatory, 1),
    {ok, Conn} = graphdb_rules:connection_rules_for_class(environment, Car),
    ?assertEqual([R2], [N#node.nref || N <- Conn]).

get_rule_returns_full_record(_Config) ->
    Car = make_class("Car"),
    Eng = make_class("Engine"),
    {ok, R} = graphdb_rules:create_composition_rule(
        environment, "has-engine", Car, Eng, mandatory, 1),
    {ok, #node{nref = R, kind = instance}} =
        graphdb_rules:get_rule(environment, R).

get_rule_not_found(_Config) ->
    ?assertEqual(not_found, graphdb_rules:get_rule(environment, 999999)).

list_rules_returns_all(_Config) ->
    Car = make_class("Car"),
    Eng = make_class("Engine"),
    Bike = make_class("Bike"),
    Whl  = make_class("Wheel"),
    {ok, R1} = graphdb_rules:create_composition_rule(
        environment, "car-engine", Car, Eng, mandatory, 1),
    {ok, R2} = graphdb_rules:create_composition_rule(
        environment, "bike-wheel", Bike, Whl, mandatory, 2),
    {ok, All} = graphdb_rules:list_rules(environment),
    Nrefs = [N#node.nref || N <- All],
    ?assert(lists:member(R1, Nrefs)),
    ?assert(lists:member(R2, Nrefs)).
```

- [ ] **Step 2: Run the retrieval group to verify it fails**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group retrieval`
Expected: FAIL — retrieval functions undefined.

- [ ] **Step 3: Implement retrieval**

Add to `-export`: `get_rule/2`, `rules_for_class/2`,
`composition_rules_for_class/2`, `connection_rules_for_class/2`, `list_rules/1`.

```erlang
get_rule(Scope, RuleNref) ->
    gen_server:call(?MODULE, {get_rule, Scope, RuleNref}).

rules_for_class(Scope, ClassNref) ->
    gen_server:call(?MODULE, {rules_for_class, Scope, ClassNref}).

composition_rules_for_class(Scope, ClassNref) ->
    gen_server:call(?MODULE, {rules_for_class_kind, Scope, ClassNref,
                              composition_rule}).

connection_rules_for_class(Scope, ClassNref) ->
    gen_server:call(?MODULE, {rules_for_class_kind, Scope, ClassNref,
                              connection_rule}).

list_rules(Scope) ->
    gen_server:call(?MODULE, {list_rules, Scope}).

%% --- handlers ---
handle_call({get_rule, environment, RuleNref}, _From, State) ->
    Reply = case mnesia:dirty_read(nodes, RuleNref) of
        [#node{kind = instance} = N] ->
            case is_rule_instance(N, State) of
                true  -> {ok, N};
                false -> not_found
            end;
        _ -> not_found
    end,
    {reply, Reply, State};
handle_call({get_rule, {project, _}, _}, _From, State) ->
    {reply, not_found, State};

handle_call({rules_for_class, environment, ClassNref}, _From, State) ->
    {reply, {ok, attached_rules(ClassNref, State)}, State};
handle_call({rules_for_class, {project, _}, _}, _From, State) ->
    {reply, {ok, []}, State};

handle_call({rules_for_class_kind, environment, ClassNref, MetaKey}, _From,
            State) ->
    MetaNref = meta_nref(MetaKey, State),
    Filtered = [N || N <- attached_rules(ClassNref, State),
                lists:member(MetaNref, N#node.classes)],
    {reply, {ok, Filtered}, State};
handle_call({rules_for_class_kind, {project, _}, _, _}, _From, State) ->
    {reply, {ok, []}, State};

handle_call({list_rules, environment}, _From, State) ->
    Metas = [State#state.composition_rule_nref,
             State#state.connection_rule_nref],
    All = lists:flatmap(fun(Meta) -> instances_of(Meta) end, Metas),
    {reply, {ok, All}, State};
handle_call({list_rules, {project, _}}, _From, State) ->
    {reply, {ok, []}, State};

%% --- read helpers ---
%% Rules attached to ClassNref = applies_to connection targets.
attached_rules(ClassNref, State) ->
    AppliesTo = State#state.applies_to_nref,
    Arcs = mnesia:dirty_index_read(relationships, ClassNref,
                                   #relationship.source_nref),
    RuleNrefs = [A#relationship.target_nref || A <- Arcs,
                 A#relationship.kind == connection,
                 A#relationship.characterization == AppliesTo],
    lists:flatmap(fun(N) -> mnesia:dirty_read(nodes, N) end, RuleNrefs).

%% Instances of a meta-class = class->instance (char 30) targets.
instances_of(MetaNref) ->
    Arcs = mnesia:dirty_index_read(relationships, MetaNref,
                                   #relationship.source_nref),
    Nrefs = [A#relationship.target_nref || A <- Arcs,
             A#relationship.kind == instantiation,
             A#relationship.characterization == ?ARC_CLASS_TO_INST],
    lists:flatmap(fun(N) -> mnesia:dirty_read(nodes, N) end, Nrefs).

is_rule_instance(#node{classes = Classes}, State) ->
    lists:member(State#state.composition_rule_nref, Classes)
        orelse lists:member(State#state.connection_rule_nref, Classes).

meta_nref(composition_rule, State) -> State#state.composition_rule_nref;
meta_nref(connection_rule,  State) -> State#state.connection_rule_nref.
```

- [ ] **Step 4: Run the retrieval group + whole suite to verify all pass**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group retrieval`
Expected: PASS (6 cases).

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/graphdb/src/graphdb_rules.erl apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: rule retrieval API

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Scope handling

**Files:**
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

All `{project, _}` branches were implemented in Tasks 2–5. This task adds the
explicit scope tests that lock the contract.

- [ ] **Step 1: Add the `scope` group and its tests (failing or passing)**

```erlang
{scope, [], [
    project_scope_rejected_on_create,
    project_scope_returns_empty_on_retrieve
]}

project_scope_rejected_on_create(_Config) ->
    Parent = make_class("Car"),
    Child  = make_class("Engine"),
    ?assertEqual({error, project_rules_not_yet_supported},
        graphdb_rules:create_composition_rule(
            {project, 1}, "x", Parent, Child, mandatory, 1)),
    Source = make_class("Order"),
    Target = make_class("Customer"),
    Char   = make_rel_char("placed_by", "placed"),
    ?assertEqual({error, project_rules_not_yet_supported},
        graphdb_rules:create_connection_rule(
            {project, 1}, "x", Source, Char, Target, mandatory, 1)).

project_scope_returns_empty_on_retrieve(_Config) ->
    Car = make_class("Car"),
    ?assertEqual({ok, []},
        graphdb_rules:rules_for_class({project, 1}, Car)),
    ?assertEqual({ok, []},
        graphdb_rules:composition_rules_for_class({project, 1}, Car)),
    ?assertEqual({ok, []}, graphdb_rules:list_rules({project, 1})),
    ?assertEqual(not_found, graphdb_rules:get_rule({project, 1}, 999999)).
```

- [ ] **Step 2: Run the scope group to verify it passes**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group scope`
Expected: PASS (2 cases) — the `{project, _}` branches already exist.

- [ ] **Step 3: Commit**

```bash
git add apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: scope-acceptance tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Complex scenarios + cache audit

**Files:**
- Modify: `apps/graphdb/test/graphdb_rules_SUITE.erl`

- [ ] **Step 1: Add `complex_scenarios` and `cache_audit` groups (failing or passing)**

These are integration tests over the API built in Tasks 2–5; no new production
code is expected. If one fails, fix the production code under TDD.

```erlang
{complex_scenarios, [], [
    mixed_rules_on_one_class,
    rule_isolation_across_class_taxonomy,
    duplicate_child_class_with_different_modes
]},
{cache_audit, [], [
    verify_caches_passes_after_rule_creation
]}

mixed_rules_on_one_class(_Config) ->
    Car   = make_class("Car"),
    Eng   = make_class("Engine"),
    Whl   = make_class("Wheel"),
    Sun   = make_class("Sunroof"),
    Maker = make_class("Manufacturer"),
    Deal  = make_class("Dealer"),
    MadeBy = make_rel_char("made_by", "makes"),
    SoldBy = make_rel_char("sold_by", "sells"),
    {ok, DT} = graphdb_class:default_template(Car),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "engine", Car, Eng, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "wheels", Car, Whl, auto, 4, DT),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "sunroof", Car, Sun, propose, 1),
    {ok, _} = graphdb_rules:create_connection_rule(
        environment, "made-by", Car, MadeBy, Maker, mandatory, 1, DT),
    {ok, _} = graphdb_rules:create_connection_rule(
        environment, "sold-by", Car, SoldBy, Deal, propose, unbounded),
    {ok, All}  = graphdb_rules:rules_for_class(environment, Car),
    {ok, Comp} = graphdb_rules:composition_rules_for_class(environment, Car),
    {ok, Conn} = graphdb_rules:connection_rules_for_class(environment, Car),
    ?assertEqual(5, length(All)),
    ?assertEqual(3, length(Comp)),
    ?assertEqual(2, length(Conn)),
    %% five applies_to arcs out of Car
    {ok, S} = graphdb_rules:seeded_nrefs(),
    AppliesTo = maps:get(applies_to, S),
    Arcs = mnesia:dirty_index_read(relationships, Car,
                                   #relationship.source_nref),
    Applies = [A || A <- Arcs, A#relationship.kind == connection,
               A#relationship.characterization == AppliesTo],
    ?assertEqual(5, length(Applies)),
    ?assertEqual(ok, graphdb_mgr:verify_caches()).

rule_isolation_across_class_taxonomy(_Config) ->
    Vehicle = make_class("Vehicle"),
    {ok, Car} = graphdb_class:create_class("Car", Vehicle),
    {ok, Sports} = graphdb_class:create_class("SportsCar", Car),
    Eng   = make_class("Engine"),
    Wheel = make_class("SteeringWheel"),
    Spoil = make_class("Spoiler"),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "v-engine", Vehicle, Eng, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "c-wheel", Car, Wheel, mandatory, 1),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "s-spoiler", Sports, Spoil, auto, 1),
    {ok, RV} = graphdb_rules:rules_for_class(environment, Vehicle),
    {ok, RC} = graphdb_rules:rules_for_class(environment, Car),
    {ok, RS} = graphdb_rules:rules_for_class(environment, Sports),
    ?assertEqual(1, length(RV)),
    ?assertEqual(1, length(RC)),
    ?assertEqual(1, length(RS)).

duplicate_child_class_with_different_modes(_Config) ->
    Cell = make_class("Cell"),
    Nuc  = make_class("Nucleus"),
    {ok, R1} = graphdb_rules:create_composition_rule(
        environment, "nuc-mandatory", Cell, Nuc, mandatory, 1),
    {ok, R2} = graphdb_rules:create_composition_rule(
        environment, "nuc-propose", Cell, Nuc, propose, 1),
    ?assertNotEqual(R1, R2),
    {ok, Rules} = graphdb_rules:composition_rules_for_class(environment, Cell),
    ?assertEqual(2, length(Rules)).

verify_caches_passes_after_rule_creation(_Config) ->
    Car = make_class("Car"),
    Eng = make_class("Engine"),
    {ok, _} = graphdb_rules:create_composition_rule(
        environment, "engine", Car, Eng, mandatory, 1),
    ?assertEqual(ok, graphdb_mgr:verify_caches()).
```

Add both groups to `all/0`.

- [ ] **Step 2: Run the new groups**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group complex_scenarios`
Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE --group cache_audit`
Expected: PASS. If `verify_caches/0` fails, the rule node's `parents`/`classes`
caches disagree with the arcs — rule nodes must have `parents = []` and
`classes = [MetaClassNref]`, and the `applies_to` arcs must be `kind =
connection` (ignored by the audit). Fix under TDD if red.

- [ ] **Step 3: Run the full suite**

Run: `./rebar3 ct --suite apps/graphdb/test/graphdb_rules_SUITE`
Expected: PASS — all ~30 cases.

- [ ] **Step 4: Commit**

```bash
git add apps/graphdb/test/graphdb_rules_SUITE.erl
git commit -m "F4 Phase A: complex-scenario + cache-audit integration tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Documentation

**Files:**
- Modify: `apps/graphdb/CLAUDE.md`
- Modify: `CLAUDE.md` (root)
- Modify: `ARCHITECTURE.md`
- Modify: `TASKS.md`
- Modify: `docs/diagrams/ontology-tree.md`

- [ ] **Step 1: Get the authoritative full-project test counts**

Run: `./rebar3 ct`  → record the total CT count.
Run: `./rebar3 eunit` → record the total EUnit count (unchanged; F4 Phase A
adds no EUnit).
Compute the new total for the ARCHITECTURE.md status line.

- [ ] **Step 2: Update `apps/graphdb/CLAUDE.md`**

- Change the `graphdb_rules.erl` row in the Files table from
  "Graph rules gen_server (stub)" to
  "Graph rules gen_server (implemented — F4 Phase A: rule meta-ontology + create/retrieve API)".
- Replace the `graphdb_rules` "Graph Rules" worker subsection's stub API list
  with the Phase A API: `create_composition_rule/6,7`,
  `create_connection_rule/7,8`, `get_rule/2`, `rules_for_class/2`,
  `composition_rules_for_class/2`, `connection_rules_for_class/2`,
  `list_rules/1`, `seeded_nrefs/0`. Note: at bootstrap it seeds the
  `Rule Literals` sub-group (nref 7) with 6 literal attrs, the
  `applies_to`/`applied_by` pair (nref 16), and the `Rule` (abstract) /
  `CompositionRule` / `ConnectionRule` meta-class chain under nref 3.
- Update the "NYI Status" line: remove "graphdb_rules is the only remaining
  empty gen_server stub" — there are now **no** stub workers.

- [ ] **Step 3: Update root `CLAUDE.md`**

- In the OTP supervision tree block, move `graphdb_rules` to the end of the
  `graphdb_sup` children and change its annotation from
  "gen_server — stub, implementation pending" to
  "gen_server — implemented: F4 Phase A rule meta-ontology + create/retrieve".
- In "Known Incomplete Areas (NYI)", remove `graphdb_rules` from the stub list
  (it is no longer a stub; Phase B–F engine work remains, tracked in TASKS.md).

- [ ] **Step 4: Update `ARCHITECTURE.md`**

- Change the `graphdb_rules` status-table row from "Stub" to
  "Implemented — F4 Phase A: rule meta-ontology, applies_to attachment, scope-aware create/retrieve".
- Update the Tests status line to the new totals from Step 1.
- Add a short "Rules (F4 Phase A)" subsection at architectural altitude: rules
  are instances of seeded meta-classes; content AVPs on the rule node,
  deployment AVPs (`mode`, `multiplicity`, `Template`) on the
  `applies_to`/`applied_by` connection arc; direct-attachment retrieval only
  (taxonomy-walking `effective_rules_for_class/2` is Phase B).

- [ ] **Step 5: Update `TASKS.md`**

- Mark F4 **Phase A** RESOLVED (dated), keeping Phases B–F listed as
  outstanding. Add L6 to Engineering Hygiene if the design says so and it is
  not already present.

- [ ] **Step 6: Update `docs/diagrams/ontology-tree.md`**

Add to the Mermaid environment tree:
- under Literals (nref 7): a `Rule Literals` sub-group node with its 6 literal
  children (`child_class_nref`, `target_class_nref`, `template_nref`,
  `characterization_nref`, `mode`, `multiplicity`);
- under Instance Relationships (nref 16): the `applies_to` / `applied_by` pair;
- under Classes (nref 3): the `Rule` (abstract) → `CompositionRule`,
  `ConnectionRule` meta-class subtree.

Match the existing node-class styling (`:::attr`, `:::class`) and edge style
already used in the file.

- [ ] **Step 7: Run the full project test suite once more**

Run: `./rebar3 ct && ./rebar3 eunit`
Expected: all green; counts match what you wrote into ARCHITECTURE.md.

- [ ] **Step 8: Commit**

```bash
git add apps/graphdb/CLAUDE.md CLAUDE.md ARCHITECTURE.md TASKS.md docs/diagrams/ontology-tree.md
git commit -m "F4 Phase A: docs — rules engine data model, API, ontology tree, TASKS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review Checklist (run before declaring the plan done / after execution)

1. **Spec coverage:** every Phase A deliverable in design §1.1 maps to a task —
   meta-ontology (T1), non-instantiable Rule root via L9 marker (T1),
   AVP schemas (T2/T3/T4), attachment mechanism (T2), public API (T2/T3/T5),
   validation catalog 12 atoms incl. owning_class_has_no_default_template
   (T4), CT coverage (T1–T7), supervisor reorder
   (T1).
2. **`seeded_nrefs/0` 12 keys** identical in: state record (T1), handler (T1),
   `seeded_nrefs_returns_all_twelve` (T1), and every retrieval/creation test
   that reads them.
3. **Content-vs-deployment AVP split** (table in Architecture Notes): node AVPs
   = name + `child_class_nref`/`characterization_nref`+`target_class_nref` +
   optional `template_nref`; arc AVPs = `?ARC_TEMPLATE` + `mode` +
   `multiplicity`. `avps_present_and_correct` (T2) asserts no deployment AVP
   leaks onto the node.
4. **Idempotency:** `seeds_rule_meta_ontology_idempotent` (T1) restarts the
   worker and asserts `seeded_nrefs/0` is unchanged.
5. **Records inline (resolved):** there is no shared record header; the
   `node`/`relationship` records are defined inline in both `graphdb_rules.erl`
   and the suite, copied from `graphdb_instance.erl:78-94` /
   `graphdb_instance_SUITE.erl:24-40`.
6. **`graphdb_nref` has no peek API (resolved):** only `get_next/0` exists;
   `failed_validation_consumes_no_nref` asserts via `nodes` table size.
