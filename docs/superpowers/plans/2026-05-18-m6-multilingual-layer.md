# M6: Multilingual Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `graphdb_language` as a full gen_server: language concept nodes, per-language Mnesia overlay tables, label resolver, dialect chain builder, project default language API, and translation hooks.

**Architecture:** The environment database stores English strings directly on `#node{}` records as the terminal fallback. Per-language overlay tables (`language_en`, `language_de`, `language_en_gb`, etc.) shadow individual AVPs at render time. Project overlays use per-project tables: `language_en_<anchor_nref>`. A language chain `[atom()]` is walked left-to-right; the first hit wins; the `en` sentinel bypasses the overlay table and reads the environment node directly. Language and dialect concept nodes are `kind=instance`; dialect nodes carry a `base_language` AVP referencing the base language nref.

**M6-I (write-path integration) is OUT OF SCOPE** — it depends on L4 (wire graphdb_mgr write-side), which is not yet implemented. Steps M6-A through M6-H and M6-J are the full scope of this plan.

**Tech Stack:** Erlang/OTP 27, rebar3 3.24, Mnesia `disc_copies`, Common Test, EUnit

---

## File Map

| File                                               | Action   | Responsibility                                        |
|----------------------------------------------------|----------|-------------------------------------------------------|
| `apps/graphdb/src/graphdb_language.erl`            | Rewrite  | Full gen_server — all M6 functionality                |
| `apps/graphdb/test/graphdb_language_tests.erl`     | Create   | EUnit — pure function tests (overlay_table_name, do_make_chain) |
| `apps/graphdb/test/graphdb_language_SUITE.erl`     | Create   | CT integration tests — all Mnesia-backed behaviour    |
| `TASKS.md`                                         | Modify   | Mark M6 RESOLVED; add R5, R6, R8, R10 Decision Log entries |
| `.wolf/cerebrum.md`                                | Modify   | Add R5, R6, R8, R10 to Decision Log; update Key Learnings |

---

## Architecture Decisions Locked In

**R1** (RESOLVED): Per-project overlay tables. `resolve_label/4` signature:
`(Nref, AttrNref, Chain, Scope) :: Scope = environment | {project, AnchorNref}`.
Environment tables: `language_<code>`. Project tables: `language_<code>_<anchor_nref>`.

**R2** (RESOLVED): Dialect insertion check is `Base not in (Output ++ Remaining)`.

**R3** (RESOLVED): All language nodes are `kind=instance`.

**R4** (RESOLVED): `project_language` seeded by `graphdb_language:init/1`, not `graphdb_attr:init/1`.

**R5** (to document): Environment stores English strings directly — departure from §15 strict reading. Rationale: English is the environment language; the overlay model makes it the zero-overhead fallback without double-lookup.

**R6** (to document): `mnesia:create_table/2` called synchronously during `register_language/2` / `register_dialect/3`. Single-node only for this release; gen_server serialisation prevents concurrent registration from the same node; timeout = default.

**R8** (to document): `?ENV_LANGUAGE_CODE` macro = `en` (hardcoded atom constant in `graphdb_language`). `seeded_nrefs/0` includes `env_language_code => en` alongside attr nrefs.

**R10** (to document): Locale codes are atoms using underscore-lowercase convention (`en_gb`, `pt_br`) departing from BCP 47 (`en-GB`) for Erlang atom ergonomics. Documented choice.

---

## Startup dependencies

`graphdb_language` starts after `graphdb_mgr`, `graphdb_attr`, and `graphdb_class` (bootstrap must be loaded, `lang_code` and `lang_human` nodes must exist). These workers are already started before `graphdb_language` in `graphdb_sup`.

---

## Task 1: Pure functions + EUnit skeleton

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Create: `apps/graphdb/test/graphdb_language_tests.erl`

These two functions have zero Mnesia dependency and can be written and green-tested before any gen_server state work.

### Step 1.1: Write the failing EUnit tests

- [ ] Create `apps/graphdb/test/graphdb_language_tests.erl`:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
-module(graphdb_language_tests).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% overlay_table_name/2
%%--------------------------------------------------------------------

overlay_table_name_env_test() ->
    ?assertEqual(language_en,    graphdb_language:overlay_table_name(en, environment)),
    ?assertEqual(language_de,    graphdb_language:overlay_table_name(de, environment)),
    ?assertEqual(language_en_gb, graphdb_language:overlay_table_name(en_gb, environment)).

overlay_table_name_project_test() ->
    ?assertEqual(language_en_42,    graphdb_language:overlay_table_name(en, {project, 42})),
    ?assertEqual(language_de_1000,  graphdb_language:overlay_table_name(de, {project, 1000})),
    ?assertEqual(language_en_gb_7,  graphdb_language:overlay_table_name(en_gb, {project, 7})).

%%--------------------------------------------------------------------
%% do_make_chain/3
%%   DialectMap :: #{Code :: atom() => Base :: atom()}
%%   (absent key = not a dialect)
%%--------------------------------------------------------------------

make_chain_empty_test() ->
    ?assertEqual([], graphdb_language:do_make_chain([], [], #{})).

make_chain_no_dialects_test() ->
    %% No dialects registered — output = input
    ?assertEqual([de, fr], graphdb_language:do_make_chain([de, fr], [], #{})).

make_chain_dialect_base_absent_test() ->
    %% [de, en_gb, fr] → [de, en_gb, en, fr]  (en absent from full chain)
    DMap = #{en_gb => en},
    ?assertEqual([de, en_gb, en, fr],
        graphdb_language:do_make_chain([de, en_gb, fr], [], DMap)).

make_chain_dialect_base_in_remaining_test() ->
    %% [en_gb, en, fr] → [en_gb, en, fr]  (en already in remaining)
    DMap = #{en_gb => en},
    ?assertEqual([en_gb, en, fr],
        graphdb_language:do_make_chain([en_gb, en, fr], [], DMap)).

make_chain_multiple_dialects_single_base_test() ->
    %% [en_gb, en_us] → [en_gb, en, en_us]
    %% After en_gb: en not in [en_gb, en_us] → insert. Now full chain = [en_gb, en, en_us].
    %% After en_us: en in [en_gb, en, en_us] → skip.
    DMap = #{en_gb => en, en_us => en},
    ?assertEqual([en_gb, en, en_us],
        graphdb_language:do_make_chain([en_gb, en_us], [], DMap)).

make_chain_base_already_present_test() ->
    %% [pt_br, pt, de] → [pt_br, pt, de]  (pt already present in remaining)
    DMap = #{pt_br => pt},
    ?assertEqual([pt_br, pt, de],
        graphdb_language:do_make_chain([pt_br, pt, de], [], DMap)).

make_chain_base_inserted_test() ->
    %% [pt_br, de] → [pt_br, pt, de]  (pt absent from full chain)
    DMap = #{pt_br => pt},
    ?assertEqual([pt_br, pt, de],
        graphdb_language:do_make_chain([pt_br, de], [], DMap)).

-endif.
```

### Step 1.2: Run tests — expect failure (function not exported)

- [ ] Run:

```sh
cd /c/dev/SeerStoneGraphDb
./rebar3 eunit --app=graphdb --module=graphdb_language_tests
```

Expected: compile errors or undefined function errors.

### Step 1.3: Implement `overlay_table_name/2` and `do_make_chain/3`

- [ ] Replace the body of `apps/graphdb/src/graphdb_language.erl` with the full stub below (retaining Dallas's header):

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_language provides the multilingual label
%%              overlay layer and the session chain helper.
%%              It is responsible for language concept node management,
%%              per-language Mnesia overlay tables, label resolution,
%%              and translation agent hooks.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026 Author: David W. Thomas
%% M6 multilingual layer implementation.
%%---------------------------------------------------------------------
-module(graphdb_language).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
-modified('Date: May 2026').
-modified_by('david@davidwt.com').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------

%%---------------------------------------------------------------------
%% Macro Functions
%%---------------------------------------------------------------------
-define(NYI(F), (begin
                    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
                    exit(nyi)
                 end)).
-define(UEM(F, X), (begin
                    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
                    exit(uem)
                 end)).

%% The declared base language of the environment database.
%% Hard-coded; changing this requires a full data migration.
-define(ENV_LANGUAGE_CODE, en).

%% Bootstrap nrefs
-define(PARENT_LITERALS, 7).    %% Literals subtree
-define(PARENT_CLASSES,  3).    %% Classes root
-define(HUMAN_LANGS,    32).    %% Human Languages category
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).
-define(NAME_ATTR_FOR_CLASS,     19).
-define(NAME_ATTR_FOR_INSTANCE,  20).
-define(ATTR_CHILD_ARC,  24).   %% Child/AttrRel  -- taxonomy
-define(CLASS_CHILD_ARC, 26).   %% Child/ClassRel -- taxonomy
-define(INST_PARENT_ARC, 27).   %% Parent/InstRel
-define(INST_CHILD_ARC,  28).   %% Child/InstRel
-define(CLASS_MEMBERSHIP_ARC,    29).
-define(INSTANCE_MEMBERSHIP_ARC, 30).


%%---------------------------------------------------------------------
%% Records
%%---------------------------------------------------------------------
-record(node, {
    nref,
    kind,
    parents       = [],
    classes       = [],
    attribute_value_pairs
}).

-record(relationship, {
    id,
    kind,
    source_nref,
    characterization,
    target_nref,
    reciprocal,
    avps
}).

-record(language_node, {
    nref,   %% integer() — same keyspace as environment nodes
    avps    %% [#{attribute => AttrNref, value => Value}]
             %%   — only AVPs that shadow the environment node
}).

-record(state, {
    lang_code_nref,           %% attr nref for lang_code (bootstrap-labeled, found by name)
    lang_human_nref,          %% class nref for Human Language (bootstrap-labeled, found by name)
    base_language_nref,       %% literal attr nref seeded at init
    project_language_nref,    %% literal attr nref seeded at init
    hooks         = [],       %% [fun()] registered translation hooks
    lang_code_map = #{},      %% Code :: atom() => Nref :: integer()
    dialect_map   = #{}       %% Code :: atom() => BaseCode :: atom()
}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
-export([
    start_link/0
    ]).

-export([
    seeded_nrefs/0,
    register_language/2,
    register_dialect/3,
    set_labels/3,
    resolve_label/4,
    make_chain/1,
    project_language/1,
    register_translation_hook/1,
    unregister_translation_hook/1
    ]).

-ifdef(TEST).
-export([
    overlay_table_name/2,
    do_make_chain/3
    ]).
-endif.

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
    ]).


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

seeded_nrefs() ->
    gen_server:call(?MODULE, seeded_nrefs).

register_language(Code, Name) ->
    gen_server:call(?MODULE, {register_language, Code, Name}).

register_dialect(Code, Name, BaseCode) ->
    gen_server:call(?MODULE, {register_dialect, Code, Name, BaseCode}).

set_labels(Nref, Code, AVPs) ->
    gen_server:call(?MODULE, {set_labels, Nref, Code, AVPs}).

resolve_label(Nref, AttrNref, Chain, Scope) ->
    gen_server:call(?MODULE, {resolve_label, Nref, AttrNref, Chain, Scope}).

make_chain(Codes) ->
    gen_server:call(?MODULE, {make_chain, Codes}).

project_language(ProjectRootNref) ->
    gen_server:call(?MODULE, {project_language, ProjectRootNref}).

register_translation_hook(Fun) ->
    gen_server:call(?MODULE, {register_translation_hook, Fun}).

unregister_translation_hook(Fun) ->
    gen_server:call(?MODULE, {unregister_translation_hook, Fun}).


%%---------------------------------------------------------------------
%% Pure helper functions (exported under TEST for EUnit)
%%---------------------------------------------------------------------

%% overlay_table_name(Code, Scope) -> atom()
%%   environment     → language_en
%%   {project, N}    → language_en_42
overlay_table_name(Code, environment) ->
    list_to_atom("language_" ++ atom_to_list(Code));
overlay_table_name(Code, {project, AnchorNref}) ->
    list_to_atom("language_" ++ atom_to_list(Code) ++ "_"
        ++ integer_to_list(AnchorNref)).

%% do_make_chain(ValidCodes, Output, DialectMap) -> [atom()]
%%   DialectMap :: #{DialectCode :: atom() => BaseCode :: atom()}
%%   (absent key = not a dialect)
%%
%% Pure inner loop for make_chain/1.  Applies the dialect
%% auto-insertion rule: after emitting a dialect code, insert its base
%% immediately unless the base appears anywhere in Output ++ Remaining.
do_make_chain([], Output, _DMap) ->
    Output;
do_make_chain([Code | Rest], Output, DMap) ->
    NewOut = Output ++ [Code],
    case maps:get(Code, DMap, not_dialect) of
        not_dialect ->
            do_make_chain(Rest, NewOut, DMap);
        Base ->
            Full = NewOut ++ Rest,
            case lists:member(Base, Full) of
                true  -> do_make_chain(Rest, NewOut, DMap);
                false -> do_make_chain(Rest, NewOut ++ [Base], DMap)
            end
    end.


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

init([]) ->
    ?NYI(init),
    {ok, #state{}}.

handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Message, State) ->
    ?UEM(handle_cast, {Message, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    ?NYI(code_change),
    {ok, State}.
```

### Step 1.4: Run EUnit — expect green

- [ ] Run:

```sh
./rebar3 eunit --app=graphdb --module=graphdb_language_tests
```

Expected: 9 tests pass.

### Step 1.5: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_tests.erl
git commit -m "M6-A/H: language_node record, overlay_table_name, do_make_chain (pure, EUnit green)"
```

---

## Task 2: `init/1` — state seeding

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`

`init/1` must: find `lang_code` attr nref and `lang_human` class nref (both bootstrap-labeled, allocated at load time ≥ 100000); seed `base_language` and `project_language` literal attributes; create `language_en` table; build `lang_code_map` and `dialect_map` from existing nodes; expose all via `seeded_nrefs/0`.

CT tests for this live in Task 9.

### Step 2.1: Replace `init/1` and add private helpers

- [ ] In `apps/graphdb/src/graphdb_language.erl`, replace the `init/1` callback and add the private section below `code_change/3`. The full functions to add/replace:

**Replace `init/1`:**

```erlang
init([]) ->
    try
        LangCodeNref         = find_literal_by_name("lang_code"),
        LangHumanNref        = find_class_by_name(?PARENT_CLASSES, "Human Language"),
        BaseLangNref         = ensure_literal_seed("base_language"),
        ProjectLangNref      = ensure_literal_seed("project_language"),
        ok = ensure_overlay_table(language_en),
        {LangCodeMap, DialectMap} =
            build_lang_maps(LangCodeNref, BaseLangNref, LangHumanNref),
        logger:info("graphdb_language: started "
            "(lang_code=~p, lang_human=~p, base_language=~p, "
            "project_language=~p, registered=~p)",
            [LangCodeNref, LangHumanNref, BaseLangNref, ProjectLangNref,
             maps:size(LangCodeMap)]),
        {ok, #state{
            lang_code_nref        = LangCodeNref,
            lang_human_nref       = LangHumanNref,
            base_language_nref    = BaseLangNref,
            project_language_nref = ProjectLangNref,
            lang_code_map         = LangCodeMap,
            dialect_map           = DialectMap
        }}
    catch
        throw:{error, Reason} ->
            logger:error("graphdb_language: init failed: ~p", [Reason]),
            {stop, {init_failed, Reason}}
    end.
```

**Add `seeded_nrefs` handle_call clause** (replace the catch-all temporarily):

```erlang
handle_call(seeded_nrefs, _From,
        #state{lang_code_nref        = LC,
               base_language_nref    = BL,
               project_language_nref = PL} = State) ->
    {reply, {ok, #{lang_code          => LC,
                   base_language      => BL,
                   project_language   => PL,
                   env_language_code  => ?ENV_LANGUAGE_CODE}}, State};

handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.
```

**Add private helpers after `code_change/3`:**

```erlang
%%=====================================================================
%% Private Helper Functions
%%=====================================================================

%%---------------------------------------------------------------------
%% find_literal_by_name(Name) -> Nref
%%
%% Finds an attribute-kind child of the Literals subtree (7) by name.
%% Throws {error, Reason} if not found (bootstrap requirement).
%%---------------------------------------------------------------------
find_literal_by_name(Name) ->
    case graphdb_attr:find_attribute_by_name(?PARENT_LITERALS, Name) of
        {ok, Nref} -> Nref;
        not_found  -> throw({error, {literal_not_found, Name}})
    end.


%%---------------------------------------------------------------------
%% find_class_by_name(ParentNref, Name) -> Nref
%%
%% Finds a class-kind child of ParentNref whose class-name AVP matches
%% Name.  Runs a Mnesia transaction.
%% Throws {error, Reason} if not found.
%%---------------------------------------------------------------------
find_class_by_name(ParentNref, Name) ->
    F = fun() ->
        Children = downward_children_by_arc(ParentNref, ?CLASS_CHILD_ARC,
            taxonomy),
        lists:search(fun(N) -> class_has_name(N, Name) end, Children)
    end,
    case mnesia:transaction(F) of
        {atomic, {value, #node{nref = Nref}}} -> Nref;
        {atomic, false} -> throw({error, {class_not_found, Name}});
        {aborted, R}    -> throw({error, R})
    end.


%%---------------------------------------------------------------------
%% ensure_literal_seed(Name) -> Nref
%%
%% Same pattern as graphdb_attr:ensure_seed/1 — looks up a literal
%% attribute by name under Literals (7); creates it if absent.
%%---------------------------------------------------------------------
ensure_literal_seed(Name) ->
    case graphdb_attr:find_attribute_by_name(?PARENT_LITERALS, Name) of
        {ok, Nref} ->
            Nref;
        not_found ->
            Nref = nref_server:get_nref(),
            NameAVP = #{attribute => ?NAME_ATTR_FOR_ATTRIBUTE, value => Name},
            Node = #node{
                nref = Nref,
                kind = attribute,
                parents = [?PARENT_LITERALS],
                attribute_value_pairs = [NameAVP]
            },
            Id1 = nref_server:get_nref(),
            Id2 = nref_server:get_nref(),
            P2C = #relationship{
                id             = Id1,
                kind           = taxonomy,
                source_nref    = ?PARENT_LITERALS,
                characterization = ?ATTR_CHILD_ARC,
                target_nref    = Nref,
                reciprocal     = ?ATTR_CHILD_ARC - 1,
                avps           = []
            },
            C2P = #relationship{
                id             = Id2,
                kind           = taxonomy,
                source_nref    = Nref,
                characterization = ?ATTR_CHILD_ARC - 1,
                target_nref    = ?PARENT_LITERALS,
                reciprocal     = ?ATTR_CHILD_ARC,
                avps           = []
            },
            F = fun() ->
                ok = mnesia:write(nodes, Node, write),
                ok = mnesia:write(relationships, P2C, write),
                ok = mnesia:write(relationships, C2P, write)
            end,
            case mnesia:transaction(F) of
                {atomic, ok}     -> Nref;
                {aborted, Reason} -> throw({error, Reason})
            end
    end.


%%---------------------------------------------------------------------
%% ensure_overlay_table(TableName) -> ok
%%
%% Creates a disc_copies Mnesia table for language_node records if it
%% does not already exist.  Synchronous — blocks until the schema
%% change is committed on this node.
%%---------------------------------------------------------------------
ensure_overlay_table(TableName) ->
    case mnesia:create_table(TableName, [
            {attributes, record_info(fields, language_node)},
            {record_name, language_node},
            {disc_copies, [node()]}]) of
        {atomic, ok}                       -> ok;
        {aborted, {already_exists, _}}     -> ok;
        {aborted, Reason}                  -> throw({error, Reason})
    end.


%%---------------------------------------------------------------------
%% build_lang_maps(LangCodeNref, BaseLangNref, LangHumanNref)
%%     -> {LangCodeMap, DialectMap}
%%
%% Scans all instance children of the lang_human class via the
%% INSTANCE_MEMBERSHIP_ARC (30) to rebuild the in-memory maps from
%% persisted data.  Two-pass: first build Code<->Nref index, then
%% resolve BaseCode atoms for dialects.
%%---------------------------------------------------------------------
build_lang_maps(LangCodeNref, BaseLangNref, LangHumanNref) ->
    F = fun() ->
        %% All instances of the lang_human class
        Arcs = mnesia:index_read(relationships, LangHumanNref,
            #relationship.source_nref),
        InstNrefs = [A#relationship.target_nref || A <- Arcs,
            A#relationship.kind          =:= instantiation,
            A#relationship.characterization =:= ?INSTANCE_MEMBERSHIP_ARC],
        Nodes = lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, InstNrefs),
        %% Pass 1: Code -> Nref and Nref -> Code
        {CM, NC} = lists:foldl(fun
            (#node{nref = Nref, attribute_value_pairs = AVPs}, {C, N}) ->
                case avp_value(LangCodeNref, AVPs) of
                    not_found -> {C, N};
                    Code -> {C#{Code => Nref}, N#{Nref => Code}}
                end
        end, {#{}, #{}}, Nodes),
        %% Pass 2: dialect Code -> BaseCode
        DM = lists:foldl(fun
            (#node{nref = Nref, attribute_value_pairs = AVPs}, D) ->
                case avp_value(BaseLangNref, AVPs) of
                    not_found -> D;
                    BaseNref ->
                        MyCode   = maps:get(Nref, NC, undefined),
                        BaseCode = maps:get(BaseNref, NC, undefined),
                        case {MyCode, BaseCode} of
                            {undefined, _} -> D;
                            {_, undefined} -> D;
                            {C, B}         -> D#{C => B}
                        end
                end
        end, #{}, Nodes),
        {CM, DM}
    end,
    case mnesia:transaction(F) of
        {atomic, {CM, DM}} -> {CM, DM};
        {aborted, Reason}  -> throw({error, {build_lang_maps_failed, Reason}})
    end.


%%---------------------------------------------------------------------
%% downward_children_by_arc(ParentNref, ChildArc, RelKind) -> [#node{}]
%%
%% Must run inside an active mnesia transaction.
%%---------------------------------------------------------------------
downward_children_by_arc(ParentNref, ChildArc, RelKind) ->
    Arcs = mnesia:index_read(relationships, ParentNref,
        #relationship.source_nref),
    Nrefs = [A#relationship.target_nref || A <- Arcs,
        A#relationship.kind           =:= RelKind,
        A#relationship.characterization =:= ChildArc],
    lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, Nrefs).


%%---------------------------------------------------------------------
%% avp_value(AttrNref, AVPs) -> Value | not_found
%%---------------------------------------------------------------------
avp_value(AttrNref, AVPs) ->
    case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
        {value, #{value := V}} -> V;
        false                  -> not_found
    end.


%%---------------------------------------------------------------------
%% class_has_name(Node, Name) -> boolean()
%%---------------------------------------------------------------------
class_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
    lists:any(fun
        (#{attribute := ?NAME_ATTR_FOR_CLASS, value := V}) -> V =:= Name;
        (_) -> false
    end, AVPs).
```

**Note on arc numbers in `ensure_literal_seed`:** The arc label for Parent/AttrRel is nref 23. `?ATTR_CHILD_ARC - 1` evaluates to 23 at compile time since `?ATTR_CHILD_ARC = 24`. This avoids a separate macro while keeping the numbers transparent. If this feels too clever, replace with `-define(ATTR_PARENT_ARC, 23).` and a corresponding `-define(ATTR_CHILD_ARC, 24).`.

### Step 2.2: Compile — check for errors

- [ ] Run:

```sh
./rebar3 compile
```

Expected: zero errors, zero warnings. Fix any before continuing.

### Step 2.3: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl
git commit -m "M6-B: graphdb_language init/1 — seed base_language, project_language; build lang maps"
```

---

## Task 3: CT suite skeleton + `seeded_nrefs` test

**Files:**
- Create: `apps/graphdb/test/graphdb_language_SUITE.erl`

### Step 3.1: Create the CT suite with init boilerplate

- [ ] Create `apps/graphdb/test/graphdb_language_SUITE.erl`:

```erlang
%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: (completion of Dallas Noyes's design)
%% Created: May 2026
%% Description: Common Test integration suite for graphdb_language.
%%              Each test case gets its own isolated temp directory
%%              with a fresh Mnesia database and nref allocator.
%%              graphdb_mgr is started first to load the bootstrap
%%              scaffold; graphdb_attr and graphdb_class are started
%%              next; graphdb_language is then exercised.
%%---------------------------------------------------------------------
-module(graphdb_language_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-record(node, {
    nref,
    kind,
    parents       = [],
    classes       = [],
    attribute_value_pairs
}).

-record(relationship, {
    id,
    kind,
    source_nref,
    characterization,
    target_nref,
    reciprocal,
    avps
}).

-record(language_node, {
    nref,
    avps
}).

-define(DIR_PREFIX, "lang_").

%%---------------------------------------------------------------------
%% Common Test callbacks
%%---------------------------------------------------------------------
-export([
    all/0,
    groups/0,
    suite/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%%---------------------------------------------------------------------
%% Test cases
%%---------------------------------------------------------------------
-export([
    %% Seeding
    seeded_nrefs_present/1,
    seeded_nrefs_above_floor/1,
    language_en_table_created/1,
    %% Registration
    register_language_creates_concept_node/1,
    register_language_idempotent/1,
    register_dialect_creates_concept_node/1,
    register_dialect_base_not_found/1,
    %% Overlay write
    set_labels_writes_avp/1,
    set_labels_merges_avps/1,
    set_labels_unregistered_code_error/1,
    %% Label resolution
    resolve_label_from_environment_fallback/1,
    resolve_label_from_overlay/1,
    resolve_label_chain_priority/1,
    resolve_label_en_sentinel/1,
    resolve_label_dialect_hit/1,
    resolve_label_dialect_fallback/1,
    resolve_label_not_found/1,
    %% make_chain integration
    make_chain_drops_unknown_codes/1,
    make_chain_dialect_insertion/1,
    %% Project language
    project_language_avp_roundtrip/1,
    project_language_not_found/1,
    %% Translation hooks
    translation_hook_called_after_registration/1,
    translation_hook_crash_does_not_fail_caller/1,
    translation_hook_unregister/1
]).

suite() -> [{timetrap, {seconds, 60}}].

all() ->
    [{group, seeding},
     {group, registration},
     {group, overlay_write},
     {group, label_resolution},
     {group, make_chain},
     {group, project_language},
     {group, translation_hooks}].

groups() ->
    [{seeding,          [], [seeded_nrefs_present, seeded_nrefs_above_floor,
                             language_en_table_created]},
     {registration,     [], [register_language_creates_concept_node,
                             register_language_idempotent,
                             register_dialect_creates_concept_node,
                             register_dialect_base_not_found]},
     {overlay_write,    [], [set_labels_writes_avp, set_labels_merges_avps,
                             set_labels_unregistered_code_error]},
     {label_resolution, [], [resolve_label_from_environment_fallback,
                             resolve_label_from_overlay,
                             resolve_label_chain_priority,
                             resolve_label_en_sentinel,
                             resolve_label_dialect_hit,
                             resolve_label_dialect_fallback,
                             resolve_label_not_found]},
     {make_chain,       [], [make_chain_drops_unknown_codes,
                             make_chain_dialect_insertion]},
     {project_language, [], [project_language_avp_roundtrip,
                             project_language_not_found]},
     {translation_hooks,[], [translation_hook_called_after_registration,
                             translation_hook_crash_does_not_fail_caller,
                             translation_hook_unregister]}].


%%---------------------------------------------------------------------
%% Suite setup
%%---------------------------------------------------------------------
init_per_suite(Config) ->
    {ok, OrigCwd} = file:get_cwd(),
    ok = ensure_loaded(graphdb),
    PrivDir = code:priv_dir(graphdb),
    BootstrapFile = filename:join(PrivDir, "bootstrap.terms"),
    true = filelib:is_file(BootstrapFile),
    [{orig_cwd, OrigCwd}, {bootstrap_file, BootstrapFile} | Config].

end_per_suite(_Config) ->
    ok.

ensure_loaded(App) ->
    case application:load(App) of
        ok                            -> ok;
        {error, {already_loaded, _}}  -> ok
    end.


%%---------------------------------------------------------------------
%% Per-testcase setup/teardown
%%---------------------------------------------------------------------
init_per_testcase(_TC, Config) ->
    Config1    = setup_isolated_env(Config),
    BootFile   = proplists:get_value(bootstrap_file, Config),
    application:set_env(seerstone_graph_db, bootstrap_file, BootFile),
    {ok, _}   = graphdb_mgr:start_link(),
    {ok, _}   = graphdb_attr:start_link(),
    {ok, _}   = graphdb_class:start_link(),
    Config1.

end_per_testcase(TC, Config) ->
    verify_cache_invariant(TC),
    catch gen_server:stop(graphdb_language),
    catch gen_server:stop(graphdb_class),
    catch gen_server:stop(graphdb_attr),
    catch gen_server:stop(graphdb_mgr),
    catch application:stop(nref),
    catch mnesia:stop(),
    catch dets:close(nref_server),
    catch dets:close(nref_allocator),
    OrigCwd = proplists:get_value(orig_cwd, Config),
    ok = file:set_cwd(OrigCwd),
    TmpDir = proplists:get_value(tmp_dir, Config),
    delete_dir_recursive(TmpDir),
    application:unset_env(seerstone_graph_db, bootstrap_file),
    application:unset_env(mnesia, dir),
    ok.

setup_isolated_env(Config) ->
    OrigCwd = proplists:get_value(orig_cwd, Config),
    Unique  = integer_to_list(erlang:unique_integer([positive, monotonic])),
    TmpDir  = filename:join([OrigCwd, "_build", "test", "ct_scratch",
                             ?DIR_PREFIX ++ Unique]),
    MnesiaDir = filename:join(TmpDir, "mnesia"),
    ok = filelib:ensure_dir(filename:join(MnesiaDir, "x")),
    ok = file:set_cwd(TmpDir),
    application:set_env(mnesia, dir, MnesiaDir),
    {ok, _} = application:ensure_all_started(nref),
    [{tmp_dir, TmpDir}, {mnesia_dir, MnesiaDir} | Config].

verify_cache_invariant(TC) ->
    case mnesia:system_info(is_running) of
        yes ->
            case graphdb_mgr:verify_caches() of
                ok -> ok;
                {error, Mismatches} ->
                    ct:pal("Cache invariant failed in ~p:~n~p",
                        [TC, Mismatches]),
                    ct:fail({cache_invariant_failed, TC, Mismatches})
            end;
        _ -> ok
    end.

delete_dir_recursive(Dir) ->
    %% Safety guard: absolute path, under ct_scratch/, matches prefix
    IsAbsolute = filename:pathtype(Dir) =:= absolute,
    HasScratch = string:find(Dir, "_build/test/ct_scratch/") =/= nomatch,
    HasPrefix  = string:find(filename:basename(Dir), ?DIR_PREFIX) =:= filename:basename(Dir),
    case IsAbsolute andalso HasScratch andalso HasPrefix of
        true  -> os:cmd("rm -rf \"" ++ Dir ++ "\""), ok;
        false -> ct:fail({unsafe_delete, Dir})
    end.


%%=====================================================================
%% Seeding Tests
%%=====================================================================

seeded_nrefs_present(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{lang_code         := LC,
           base_language     := BL,
           project_language  := PL,
           env_language_code := en}} = graphdb_language:seeded_nrefs(),
    ?assert(is_integer(LC)),
    ?assert(is_integer(BL)),
    ?assert(is_integer(PL)).

seeded_nrefs_above_floor(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, #{lang_code := LC, base_language := BL,
           project_language := PL}} = graphdb_language:seeded_nrefs(),
    ?assert(LC >= 100000),
    ?assert(BL >= 100000),
    ?assert(PL >= 100000).

language_en_table_created(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Tables = mnesia:system_info(tables),
    ?assert(lists:member(language_en, Tables)).
```

### Step 3.2: Run the seeding CT group — expect failures (init NYI)

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=seeding 2>&1 | tail -20
```

Expected: `init/1` exits with `nyi` → all three cases fail.

### Step 3.3: Run after Task 2 changes

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=seeding
```

Expected: 3/3 pass.

### Step 3.4: Commit

- [ ] Run:

```sh
git add apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-B: CT suite skeleton + seeding group (green)"
```

---

## Task 4: Language and dialect registration (M6-D)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`

### Step 4.1: Write the registration CT tests (add to existing SUITE)

- [ ] Add the registration test implementations to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% Registration Tests
%%=====================================================================

register_language_creates_concept_node(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, DeNref} = graphdb_language:register_language(de, "German"),
    %% Concept node exists in nodes table
    [#node{kind = instance, attribute_value_pairs = AVPs}] =
        mnesia:dirty_read(nodes, DeNref),
    %% lang_code AVP = de
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    de = proplists:get_value(value,
        [maps:to_list(A) || A <- AVPs, maps:get(attribute, A) =:= LCAttr],
        not_found),
    %% Overlay table created
    ?assert(lists:member(language_de, mnesia:system_info(tables))).

register_language_idempotent(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, Nref1} = graphdb_language:register_language(de, "German"),
    %% Second call returns already_registered
    {error, already_registered} = graphdb_language:register_language(de, "German"),
    %% Only one concept node exists
    1 = length(mnesia:dirty_match_object(nodes,
        #node{nref = '_', kind = instance, parents = '_',
              classes = '_', attribute_value_pairs = '_'}))
        - length([ok || N <- mnesia:dirty_all_keys(nodes), N =:= 10000]),
    _ = Nref1,
    ok.

register_dialect_creates_concept_node(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _EnNref}  = graphdb_language:register_language(en, "English"),
    {ok, GbNref}   = graphdb_language:register_dialect(en_gb, "British English", en),
    %% Concept node exists
    [#node{kind = instance, attribute_value_pairs = AVPs}] =
        mnesia:dirty_read(nodes, GbNref),
    %% base_language AVP references en concept nref
    {ok, #{base_language := BLAttr}} = graphdb_language:seeded_nrefs(),
    {ok, EnNref} = graphdb_language:lookup_language_nref(en),
    {value, #{value := EnNref}} =
        lists:search(fun(#{attribute := A}) -> A =:= BLAttr end, AVPs),
    %% Overlay table created
    ?assert(lists:member(language_en_gb, mnesia:system_info(tables))).

register_dialect_base_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {error, base_not_found} =
        graphdb_language:register_dialect(en_gb, "British English", en).
```

**Note:** `lookup_language_nref/1` is a small public helper needed by the registration test and dialect chain logic. Add it to the exports and implement it (Task 4.2 below).

### Step 4.2: Implement registration in `graphdb_language.erl`

- [ ] Add to the exports:

```erlang
-export([
    ...
    lookup_language_nref/1,
    ...
]).
```

- [ ] Add `handle_call` clauses for registration (insert before the catch-all):

```erlang
handle_call({register_language, Code, _Name}, _From,
        #state{lang_code_map = CM} = State)
        when is_map_key(Code, CM) ->
    {reply, {error, already_registered}, State};

handle_call({register_language, Code, Name}, _From, State) ->
    case do_register_language(Code, Name, State) of
        {ok, Nref, NewState} -> {reply, {ok, Nref}, NewState};
        {error, _} = Err     -> {reply, Err, State}
    end;

handle_call({register_dialect, Code, _Name, _BaseCode}, _From,
        #state{lang_code_map = CM} = State)
        when is_map_key(Code, CM) ->
    {reply, {error, already_registered}, State};

handle_call({register_dialect, Code, Name, BaseCode}, _From, State) ->
    case do_register_dialect(Code, Name, BaseCode, State) of
        {ok, Nref, NewState} -> {reply, {ok, Nref}, NewState};
        {error, _} = Err     -> {reply, Err, State}
    end;

handle_call({lookup_language_nref, Code}, _From,
        #state{lang_code_map = CM} = State) ->
    Reply = case maps:get(Code, CM, not_found) of
        not_found -> {error, not_found};
        Nref      -> {ok, Nref}
    end,
    {reply, Reply, State};
```

- [ ] Add corresponding public function:

```erlang
lookup_language_nref(Code) ->
    gen_server:call(?MODULE, {lookup_language_nref, Code}).
```

- [ ] Add private implementation helpers after the existing helpers:

```erlang
%%---------------------------------------------------------------------
%% do_register_language(Code, Name, State) ->
%%     {ok, Nref, NewState} | {error, Reason}
%%
%% Creates a language instance node under Human Languages (nref 32)
%% with kind=instance, parents=[] (no compositional parent, same as
%% English nref 10000 in bootstrap), and class membership arc pair to
%% lang_human.  Creates the language overlay table.
%%---------------------------------------------------------------------
do_register_language(Code, Name, State) ->
    #state{lang_code_nref  = LCAttr,
           lang_human_nref = LHNref} = State,
    Nref = nref_server:get_nref(),
    NameAVP = #{attribute => ?NAME_ATTR_FOR_INSTANCE, value => Name},
    CodeAVP = #{attribute => LCAttr,                 value => Code},
    Node = #node{
        nref                  = Nref,
        kind                  = instance,
        parents               = [],
        classes               = [LHNref],
        attribute_value_pairs = [NameAVP, CodeAVP]
    },
    ArcId1 = nref_server:get_nref(),
    ArcId2 = nref_server:get_nref(),
    I2C = #relationship{
        id             = ArcId1,
        kind           = instantiation,
        source_nref    = Nref,
        characterization = ?CLASS_MEMBERSHIP_ARC,
        target_nref    = LHNref,
        reciprocal     = ?INSTANCE_MEMBERSHIP_ARC,
        avps           = []
    },
    C2I = #relationship{
        id             = ArcId2,
        kind           = instantiation,
        source_nref    = LHNref,
        characterization = ?INSTANCE_MEMBERSHIP_ARC,
        target_nref    = Nref,
        reciprocal     = ?CLASS_MEMBERSHIP_ARC,
        avps           = []
    },
    F = fun() ->
        ok = mnesia:write(nodes, Node, write),
        ok = mnesia:write(relationships, I2C, write),
        ok = mnesia:write(relationships, C2I, write)
    end,
    case mnesia:transaction(F) of
        {aborted, Reason} ->
            {error, Reason};
        {atomic, ok} ->
            ok = ensure_overlay_table(
                overlay_table_name(Code, environment)),
            NewState = State#state{
                lang_code_map = maps:put(Code, Nref,
                    State#state.lang_code_map)
            },
            {ok, Nref, NewState}
    end.


%%---------------------------------------------------------------------
%% do_register_dialect(Code, Name, BaseCode, State) ->
%%     {ok, Nref, NewState} | {error, Reason}
%%
%% Same as do_register_language/3 plus stamps a base_language AVP
%% referencing the base concept nref.
%%---------------------------------------------------------------------
do_register_dialect(Code, Name, BaseCode, State) ->
    #state{lang_code_map       = CM,
           base_language_nref  = BLAttr} = State,
    case maps:get(BaseCode, CM, not_found) of
        not_found ->
            {error, base_not_found};
        BaseNref ->
            #state{lang_code_nref  = LCAttr,
                   lang_human_nref = LHNref} = State,
            Nref = nref_server:get_nref(),
            NameAVP = #{attribute => ?NAME_ATTR_FOR_INSTANCE, value => Name},
            CodeAVP = #{attribute => LCAttr,  value => Code},
            BaseAVP = #{attribute => BLAttr,  value => BaseNref},
            Node = #node{
                nref                  = Nref,
                kind                  = instance,
                parents               = [],
                classes               = [LHNref],
                attribute_value_pairs = [NameAVP, CodeAVP, BaseAVP]
            },
            ArcId1 = nref_server:get_nref(),
            ArcId2 = nref_server:get_nref(),
            I2C = #relationship{
                id             = ArcId1,
                kind           = instantiation,
                source_nref    = Nref,
                characterization = ?CLASS_MEMBERSHIP_ARC,
                target_nref    = LHNref,
                reciprocal     = ?INSTANCE_MEMBERSHIP_ARC,
                avps           = []
            },
            C2I = #relationship{
                id             = ArcId2,
                kind           = instantiation,
                source_nref    = LHNref,
                characterization = ?INSTANCE_MEMBERSHIP_ARC,
                target_nref    = Nref,
                reciprocal     = ?CLASS_MEMBERSHIP_ARC,
                avps           = []
            },
            F = fun() ->
                ok = mnesia:write(nodes, Node, write),
                ok = mnesia:write(relationships, I2C, write),
                ok = mnesia:write(relationships, C2I, write)
            end,
            case mnesia:transaction(F) of
                {aborted, Reason} ->
                    {error, Reason};
                {atomic, ok} ->
                    ok = ensure_overlay_table(
                        overlay_table_name(Code, environment)),
                    NewState = State#state{
                        lang_code_map = maps:put(Code, Nref, CM),
                        dialect_map   = maps:put(Code, BaseCode,
                                            State#state.dialect_map)
                    },
                    {ok, Nref, NewState}
            end
    end.
```

### Step 4.3: Run registration CT group

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=registration
```

Expected: 4/4 pass. Fix any failures before continuing.

### Step 4.4: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-D: register_language/2, register_dialect/3 (CT green)"
```

---

## Task 5: Overlay write — `set_labels/3` (M6-E)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

### Step 5.1: Write overlay_write CT tests

- [ ] Add to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% Overlay Write Tests
%%=====================================================================

set_labels_writes_avp(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, #{lang_code := LCAttr}} = graphdb_language:seeded_nrefs(),
    %% Write a German label for English nref 10000
    DeAVP = #{attribute => LCAttr, value => "Englisch"},
    ok = graphdb_language:set_labels(10000, de, [DeAVP]),
    %% Read it back directly from the Mnesia table
    [#language_node{avps = AVPs}] =
        mnesia:dirty_read(language_de, 10000),
    {value, #{value := "Englisch"}} =
        lists:search(fun(#{attribute := A}) -> A =:= LCAttr end, AVPs).

set_labels_merges_avps(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, #{lang_code := LCAttr, base_language := BLAttr}} =
        graphdb_language:seeded_nrefs(),
    AVP1 = #{attribute => LCAttr, value => "Englisch"},
    AVP2 = #{attribute => BLAttr, value => test_sentinel},
    ok = graphdb_language:set_labels(10000, de, [AVP1]),
    ok = graphdb_language:set_labels(10000, de, [AVP2]),
    %% Both AVPs present after two writes
    [#language_node{avps = AVPs}] =
        mnesia:dirty_read(language_de, 10000),
    2 = length(AVPs).

set_labels_unregistered_code_error(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {error, unregistered_language} =
        graphdb_language:set_labels(10000, xx, []).
```

### Step 5.2: Run overlay_write group — expect failures

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=overlay_write 2>&1 | tail -10
```

Expected: all fail (`?UEM` on handle_call).

### Step 5.3: Implement `set_labels/3`

- [ ] Add `handle_call` clause in `graphdb_language.erl`:

```erlang
handle_call({set_labels, _Nref, Code, _AVPs}, _From,
        #state{lang_code_map = CM} = State)
        when not is_map_key(Code, CM) ->
    {reply, {error, unregistered_language}, State};

handle_call({set_labels, Nref, Code, NewAVPs}, _From, State) ->
    Table = overlay_table_name(Code, environment),
    F = fun() ->
        Existing = case mnesia:read(Table, Nref) of
            [#language_node{avps = OldAVPs}] -> OldAVPs;
            []                               -> []
        end,
        %% Merge: new AVPs overwrite matching attrs; old AVPs for
        %% other attrs are preserved.
        NewAttrs = [maps:get(attribute, A) || A <- NewAVPs],
        Kept = [A || A <- Existing,
                     not lists:member(maps:get(attribute, A), NewAttrs)],
        Merged = Kept ++ NewAVPs,
        mnesia:write(Table,
            #language_node{nref = Nref, avps = Merged}, write)
    end,
    case mnesia:transaction(F) of
        {atomic, ok}      -> {reply, ok, State};
        {aborted, Reason} -> {reply, {error, Reason}, State}
    end;
```

### Step 5.4: Run overlay_write group — expect green

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=overlay_write
```

Expected: 3/3 pass.

### Step 5.5: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-E: set_labels/3 merge semantics (CT green)"
```

---

## Task 6: Label resolver — `resolve_label/4` (M6-C)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

### Step 6.1: Write label_resolution CT tests

- [ ] Add to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% Label Resolution Tests
%%=====================================================================

%% Helper: convenient AVP builder
avp(A, V) -> #{attribute => A, value => V}.

resolve_label_from_environment_fallback(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% English is nref 10000; name AVP attr = 20; value is "English"
    %% Chain contains en sentinel → reads environment node directly.
    {ok, #{lang_code := _}} = graphdb_language:seeded_nrefs(),
    {ok, "English"} =
        graphdb_language:resolve_label(10000, 20, [en], environment).

resolve_label_from_overlay(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    ok = graphdb_language:set_labels(10000, de, [avp(20, "Englisch")]),
    {ok, "Englisch"} =
        graphdb_language:resolve_label(10000, 20, [de], environment).

resolve_label_chain_priority(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    ok = graphdb_language:set_labels(10000, de, [avp(20, "Englisch")]),
    ok = graphdb_language:set_labels(10000, fr, [avp(20, "Anglais")]),
    %% de appears first — de wins
    {ok, "Englisch"} =
        graphdb_language:resolve_label(10000, 20, [de, fr], environment).

resolve_label_en_sentinel(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% en sentinel skips language_en table and reads environment node
    %% Verify language_en table is NOT consulted by writing a wrong value there
    %% and confirming the environment node value is returned
    ok = mnesia:dirty_write(language_en,
        #{nref => 10000, avps => [avp(20, "WRONG")]}),
    {ok, "English"} =
        graphdb_language:resolve_label(10000, 20, [en], environment).

resolve_label_dialect_hit(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(en, "English"),
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    ok = graphdb_language:set_labels(10000, en_gb, [avp(20, "English (UK)")]),
    {ok, "English (UK)"} =
        graphdb_language:resolve_label(10000, 20, [en_gb, en], environment).

resolve_label_dialect_fallback(_Config) ->
    %% [en_gb, en, fr]: en_gb miss → en sentinel → environment (fr skipped)
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(en, "English"),
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    ok = graphdb_language:set_labels(10000, fr, [avp(20, "Anglais")]),
    %% en_gb has no overlay → fall through; en sentinel → env node
    {ok, "English"} =
        graphdb_language:resolve_label(10000, 20, [en_gb, en, fr], environment).

resolve_label_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% AttrNref 99999 does not exist on nref 10000
    not_found =
        graphdb_language:resolve_label(10000, 99999, [en], environment).
```

### Step 6.2: Run label_resolution group — expect failures

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=label_resolution 2>&1 | tail -10
```

Expected: `?UEM` failures.

### Step 6.3: Implement `resolve_label/4`

- [ ] Add `handle_call` clause:

```erlang
handle_call({resolve_label, Nref, AttrNref, Chain, Scope}, _From, State) ->
    Reply = do_resolve_label(Nref, AttrNref, Chain, Scope),
    {reply, Reply, State};
```

- [ ] Add private implementation:

```erlang
%%---------------------------------------------------------------------
%% do_resolve_label(Nref, AttrNref, Chain, Scope) -> {ok, Value} | not_found
%%
%% Walks the language chain left-to-right.  For each code:
%%   - If code = ?ENV_LANGUAGE_CODE and Scope = environment: skip
%%     overlay table; fall directly to terminal node read.
%%   - Otherwise: read overlay table for this scope; if a record exists
%%     and contains AttrNref, return the value.
%% If chain is exhausted, read from terminal node.
%%---------------------------------------------------------------------
do_resolve_label(Nref, AttrNref, Chain, Scope) ->
    do_resolve_chain(Nref, AttrNref, Chain, Scope).

do_resolve_chain(Nref, AttrNref, [], Scope) ->
    read_terminal(Nref, AttrNref, Scope);
do_resolve_chain(Nref, AttrNref, [?ENV_LANGUAGE_CODE | _Rest], environment) ->
    read_terminal(Nref, AttrNref, environment);
do_resolve_chain(Nref, AttrNref, [Code | Rest], Scope) ->
    Table = overlay_table_name(Code, Scope),
    case mnesia:dirty_read(Table, Nref) of
        [#language_node{avps = AVPs}] ->
            case avp_value(AttrNref, AVPs) of
                not_found -> do_resolve_chain(Nref, AttrNref, Rest, Scope);
                Value     -> {ok, Value}
            end;
        [] ->
            do_resolve_chain(Nref, AttrNref, Rest, Scope)
    end.

read_terminal(Nref, AttrNref, _Scope) ->
    %% For now, always reads from the environment nodes table.
    %% Project-scope terminal reads (from a project nodes table) are a
    %% future extension requiring explicit table routing (M6-I / L4).
    case mnesia:dirty_read(nodes, Nref) of
        [#node{attribute_value_pairs = AVPs}] ->
            case avp_value(AttrNref, AVPs) of
                not_found -> not_found;
                Value     -> {ok, Value}
            end;
        [] ->
            not_found
    end.
```

**Note on `resolve_label_en_sentinel` test:** The test writes a `language_node` map directly via `mnesia:dirty_write`. The `language_node` record must be available — it is defined in the SUITE's `-record` block and the table stores tuples with `record_name = language_node`. The test writes with a map `#{nref => ..., avps => ...}` which will NOT match a record pattern read. Fix the test to use the actual record:

```erlang
resolve_label_en_sentinel(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% Write a wrong value into language_en — if the sentinel fires
    %% correctly it should be ignored.
    WrongRec = #language_node{nref = 10000, avps = [avp(20, "WRONG")]},
    ok = mnesia:dirty_write(language_en, WrongRec),
    {ok, "English"} =
        graphdb_language:resolve_label(10000, 20, [en], environment).
```

### Step 6.4: Run label_resolution group — expect green

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=label_resolution
```

Expected: 7/7 pass.

### Step 6.5: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-C: resolve_label/4 — chain walk, en sentinel, overlay tables (CT green)"
```

---

## Task 7: `make_chain/1` integration (M6-H)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

### Step 7.1: Write make_chain CT tests

- [ ] Add to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% make_chain Integration Tests
%%=====================================================================

make_chain_drops_unknown_codes(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    %% xx is not registered
    [de] = graphdb_language:make_chain([de, xx]).

make_chain_dialect_insertion(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(en, "English"),
    {ok, _} = graphdb_language:register_dialect(en_gb, "British English", en),
    {ok, _} = graphdb_language:register_language(fr, "French"),
    %% [de not registered, en_gb, fr] → en_gb valid, fr valid
    %% en_gb is dialect of en; en absent → inserted
    [en_gb, en, fr] = graphdb_language:make_chain([de, en_gb, fr]).
```

### Step 7.2: Run make_chain group — expect failures

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=make_chain 2>&1 | tail -10
```

Expected: `?UEM` failures.

### Step 7.3: Implement `make_chain/1` handle_call

- [ ] Add `handle_call` clause:

```erlang
handle_call({make_chain, Codes}, _From,
        #state{lang_code_map = CM, dialect_map = DM} = State) ->
    ValidCodes = [C || C <- Codes, maps:is_key(C, CM)],
    Dropped = length(Codes) - length(ValidCodes),
    case Dropped > 0 of
        true  -> logger:warning("graphdb_language:make_chain dropped ~p unknown codes",
                     [Dropped]);
        false -> ok
    end,
    Chain = do_make_chain(ValidCodes, [], DM),
    {reply, Chain, State};
```

### Step 7.4: Run make_chain group — expect green

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=make_chain
```

Expected: 2/2 pass.

### Step 7.5: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-H: make_chain/1 — drops unknown codes, dialect insertion (CT green)"
```

---

## Task 8: Project language (M6-G)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

### Step 8.1: Write project_language CT tests

- [ ] Add to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% Project Language Tests
%%=====================================================================

project_language_avp_roundtrip(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    {ok, _} = graphdb_language:register_language(de, "German"),
    {ok, DeNref}  = graphdb_language:lookup_language_nref(de),
    {ok, #{project_language := PLAttr}} = graphdb_language:seeded_nrefs(),
    %% Write project_language AVP onto a fictitious project root nref
    ProjectRoot = 10000,  %% reuse English nref for simplicity
    F = fun() ->
        [#node{attribute_value_pairs = AVPs} = N] =
            mnesia:read(nodes, ProjectRoot),
        Updated = N#node{
            attribute_value_pairs =
                [#{attribute => PLAttr, value => DeNref} | AVPs]
        },
        mnesia:write(nodes, Updated, write)
    end,
    {atomic, ok} = mnesia:transaction(F),
    {ok, de} = graphdb_language:project_language(ProjectRoot).

project_language_not_found(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    %% Nref 10000 has no project_language AVP yet
    not_found = graphdb_language:project_language(10000).
```

### Step 8.2: Run project_language group — expect failures

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=project_language 2>&1 | tail -10
```

Expected: `?UEM` failures.

### Step 8.3: Implement `project_language/1`

- [ ] Add `handle_call` clause:

```erlang
handle_call({project_language, ProjectRootNref}, _From,
        #state{project_language_nref = PLAttr,
               lang_code_nref        = LCAttr} = State) ->
    Reply = do_project_language(ProjectRootNref, PLAttr, LCAttr),
    {reply, Reply, State};
```

- [ ] Add private implementation:

```erlang
%%---------------------------------------------------------------------
%% do_project_language(ProjectRootNref, PLAttr, LCAttr) ->
%%     {ok, Code :: atom()} | not_found
%%
%% Reads the project_language AVP from the project root node.
%% That AVP's value is a language concept Nref.  Dereferences that
%% nref to read the lang_code AVP and returns the code atom.
%%---------------------------------------------------------------------
do_project_language(ProjectRootNref, PLAttr, LCAttr) ->
    F = fun() ->
        case mnesia:read(nodes, ProjectRootNref) of
            [#node{attribute_value_pairs = AVPs}] ->
                case avp_value(PLAttr, AVPs) of
                    not_found ->
                        not_found;
                    LangNref ->
                        case mnesia:read(nodes, LangNref) of
                            [#node{attribute_value_pairs = LangAVPs}] ->
                                avp_value(LCAttr, LangAVPs);
                            [] ->
                                not_found
                        end
                end;
            [] ->
                not_found
        end
    end,
    case mnesia:transaction(F) of
        {atomic, not_found} -> not_found;
        {atomic, Code}      -> {ok, Code};
        {aborted, Reason}   -> {error, Reason}
    end.
```

### Step 8.4: Run project_language group — expect green

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=project_language
```

Expected: 2/2 pass.

### Step 8.5: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-G: project_language/1 — reads project_language AVP, dereferences lang_code (CT green)"
```

---

## Task 9: Translation hooks (M6-F)

**Files:**
- Modify: `apps/graphdb/src/graphdb_language.erl`
- Modify: `apps/graphdb/test/graphdb_language_SUITE.erl`

Hooks are fired post-commit on node creation events. For M6, the hook infrastructure is wired and tested in isolation. The integration with actual node creation (M6-I) is deferred.

### Step 9.1: Write translation_hooks CT tests

- [ ] Add to `graphdb_language_SUITE.erl`:

```erlang
%%=====================================================================
%% Translation Hook Tests
%%=====================================================================

translation_hook_called_after_registration(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Self = self(),
    Hook = fun(Nref, AVPs) -> Self ! {hook_fired, Nref, AVPs} end,
    ok = graphdb_language:register_translation_hook(Hook),
    %% Fire hook manually to verify the mechanism
    graphdb_language:fire_translation_hooks(99, [#{attribute => 20, value => "Test"}]),
    receive
        {hook_fired, 99, _AVPs} -> ok
    after 1000 ->
        ct:fail(hook_not_fired)
    end.

translation_hook_crash_does_not_fail_caller(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    CrashHook = fun(_Nref, _AVPs) -> error(deliberate_crash) end,
    ok = graphdb_language:register_translation_hook(CrashHook),
    %% Firing a crashing hook must not raise in the caller
    ok = graphdb_language:fire_translation_hooks(99, []).

translation_hook_unregister(_Config) ->
    {ok, _} = graphdb_language:start_link(),
    Self = self(),
    Hook = fun(Nref, _AVPs) -> Self ! {hook_fired, Nref} end,
    ok = graphdb_language:register_translation_hook(Hook),
    ok = graphdb_language:unregister_translation_hook(Hook),
    graphdb_language:fire_translation_hooks(99, []),
    receive
        {hook_fired, _} -> ct:fail(hook_should_be_unregistered)
    after 200 ->
        ok
    end.
```

### Step 9.2: Add `fire_translation_hooks/2` to exports

- [ ] In `graphdb_language.erl` exports, add:

```erlang
fire_translation_hooks/2
```

- [ ] Add public function:

```erlang
fire_translation_hooks(Nref, AVPs) ->
    gen_server:call(?MODULE, {fire_translation_hooks, Nref, AVPs}).
```

### Step 9.3: Run translation_hooks group — expect failures

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=translation_hooks 2>&1 | tail -10
```

Expected: `?UEM` failures.

### Step 9.4: Implement translation hooks

- [ ] Add `handle_call` clauses:

```erlang
handle_call({register_translation_hook, Fun}, _From,
        #state{hooks = Hooks} = State) ->
    {reply, ok, State#state{hooks = Hooks ++ [Fun]}};

handle_call({unregister_translation_hook, Fun}, _From,
        #state{hooks = Hooks} = State) ->
    NewHooks = [H || H <- Hooks, H =/= Fun],
    {reply, ok, State#state{hooks = NewHooks}};

handle_call({fire_translation_hooks, Nref, AVPs}, _From,
        #state{hooks = Hooks} = State) ->
    spawn_hooks(Hooks, Nref, AVPs),
    {reply, ok, State};
```

- [ ] Add private implementation:

```erlang
%%---------------------------------------------------------------------
%% spawn_hooks(Hooks, Nref, AVPs) -> ok
%%
%% Each hook is called in a freshly spawned process.  Exceptions are
%% caught and logged; they never propagate to the caller and never
%% crash this gen_server.  Hooks must not re-enter graphdb_language
%% synchronously — doing so will deadlock.
%%---------------------------------------------------------------------
spawn_hooks(Hooks, Nref, AVPs) ->
    lists:foreach(fun(Hook) ->
        proc_lib:spawn(fun() ->
            try
                Hook(Nref, AVPs)
            catch
                Class:Reason ->
                    logger:warning(
                        "graphdb_language: translation hook raised ~p:~p",
                        [Class, Reason])
            end
        end)
    end, Hooks).
```

### Step 9.5: Run translation_hooks group — expect green

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE --group=translation_hooks
```

Expected: 3/3 pass.

### Step 9.6: Run full CT suite

- [ ] Run:

```sh
./rebar3 ct --suite=graphdb_language_SUITE
```

Expected: all groups pass.

### Step 9.7: Run full EUnit suite

- [ ] Run:

```sh
./rebar3 eunit --app=graphdb
```

Expected: all EUnit tests pass (no regressions).

### Step 9.8: Commit

- [ ] Run:

```sh
git add apps/graphdb/src/graphdb_language.erl \
        apps/graphdb/test/graphdb_language_SUITE.erl
git commit -m "M6-F: translation hooks — spawned, crash-safe, unregister (CT green)"
```

---

## Task 10: Full suite run + regression check

### Step 10.1: Run all tests

- [ ] Run:

```sh
./rebar3 ct && ./rebar3 eunit
```

Expected: all CT and EUnit tests pass. Fix any regressions before continuing.

### Step 10.2: Compile clean

- [ ] Run:

```sh
./rebar3 compile
```

Expected: zero warnings, zero errors.

---

## Task 11: Documentation — Decision Log entries + TASKS.md close-out

**Files:**
- Modify: `TASKS.md`
- Modify: `.wolf/cerebrum.md`

### Step 11.1: Add R5, R6, R8, R10 to TASKS.md Decision Log

- [ ] In `TASKS.md` under the Architecture Review — Open Issues section, replace the four "should fix" entries with RESOLVED markers and add them to the Decision Log. Specifically, find the R5 section and replace each `**R5.** ...`, `**R6.** ...`, `**R8.** ...`, `**R10.** ...` entry with:

```markdown
**R5. RESOLVED** — Environment stores English strings directly on
`#node{}` records. This is a documented departure from §15 strict
reading ("concepts stored language-neutrally"). Rationale: English is
the environment's base language; the overlay model makes the
environment node the zero-overhead terminal fallback with no
double-lookup penalty. The design is `en`-first by declaration, not by
accident. See Decision Log.

**R6. RESOLVED** — `mnesia:create_table/2` is called synchronously
during `register_language/2` and `register_dialect/3`. Single-node
deployment; gen_server serialisation prevents concurrent registration
from the same node. Default Mnesia timeout applies. Multi-node schema
synchronisation is a future concern. See Decision Log.

**R8. RESOLVED** — `?ENV_LANGUAGE_CODE` is a compile-time atom
constant (`en`) in `graphdb_language.erl`. `seeded_nrefs/0` includes
`env_language_code => en` alongside the attr nrefs so callers can read
it programmatically without hardcoding `en`. See Decision Log.

**R10. RESOLVED** — Locale codes use `en_gb` convention (atom,
underscore, all-lowercase) departing from IETF BCP 47 (`en-GB`).
Rationale: Erlang atoms are case-sensitive and hyphen is not a valid
unquoted atom character. The underscore-lowercase convention is idiomatic
Erlang. See Decision Log.
```

- [ ] In the `## Decision Log` section of `.wolf/cerebrum.md`, add the four new entries:

```
- [2026-05-18] **R5 resolved — §15 departure documented**: Environment stores
  English strings directly on `#node{}` records. Departure from §15 strict
  reading is intentional: English is the environment language; overlay model
  makes env node the zero-overhead terminal fallback. Not a bug — documented
  design decision.

- [2026-05-18] **R6 resolved — Mnesia table creation spec**: `mnesia:create_table/2`
  called synchronously during `register_language/register_dialect`. Gen_server
  serialises concurrent calls from same node. Default timeout. Multi-node schema
  sync is a future concern.

- [2026-05-18] **R8 resolved — environment language declaration**: `?ENV_LANGUAGE_CODE`
  macro = `en` (hardcoded atom constant in `graphdb_language`). `seeded_nrefs/0`
  returns `env_language_code => en` so callers don't hardcode `en`. Changing this
  would require a full data migration.

- [2026-05-18] **R10 resolved — locale code format**: `en_gb` atom convention
  (underscore-lowercase) vs IETF BCP 47 (`en-GB`). Chosen for Erlang atom
  ergonomics: hyphens are not valid in unquoted atoms. Documented choice.
```

- [ ] Mark M6 as RESOLVED in `TASKS.md` F2 section header and mark M6-I as explicitly deferred with a cross-reference to L4.

### Step 11.2: Run alignment script on modified markdown files

- [ ] Run:

```sh
python3 ~/.claude/scripts/align_md_tables.py TASKS.md
```

### Step 11.3: Commit documentation

- [ ] Run:

```sh
git add TASKS.md .wolf/cerebrum.md
git commit -m "M6: mark RESOLVED; document R5, R6, R8, R10 decision rationales"
```

---

## Task 12: Final verification + branch push

### Step 12.1: Run full suite one last time

- [ ] Run:

```sh
./rebar3 ct && ./rebar3 eunit
```

Expected: all tests pass.

### Step 12.2: Check git status

- [ ] Run:

```sh
git log --oneline -8
git status
```

Expected: clean working tree; at least 8 commits since branch start.

### Step 12.3: Push to develop

- [ ] Run:

```sh
git push origin develop
```

---

## Self-Review Checklist

**Spec coverage:**

| M6 sub-task | Task in this plan                             |
|-------------|-----------------------------------------------|
| M6-A        | Task 1 (`language_node` record), Task 2 (`language_en` table) |
| M6-B        | Task 2 (init seeding, `seeded_nrefs/0`)       |
| M6-C        | Task 6 (`resolve_label/4`)                    |
| M6-D        | Task 4 (`register_language`, `register_dialect`) |
| M6-E        | Task 5 (`set_labels/3`)                       |
| M6-F        | Task 9 (translation hooks)                    |
| M6-G        | Task 8 (`project_language/1`)                 |
| M6-H        | Task 1 (`do_make_chain/3`), Task 7 (`make_chain/1`) |
| M6-I        | **DEFERRED** — depends on L4                  |
| M6-J        | Tests in Tasks 3–9                            |

**R1–R4 all RESOLVED** before any code in this plan.
**R5, R6, R8, R10 documented** in Task 11.
**Translation hooks spawned** (`proc_lib:spawn/1`), not inline (R7).
**State cache updated after Mnesia commit**, not before.
**`parents=[]` for language instance nodes** — same as English nref 10000 in bootstrap; no compositional arcs.
**`seeded_nrefs/0` includes `env_language_code => en`** (R8 / `?ENV_LANGUAGE_CODE` macro).
**`ATTR_PARENT_ARC = 23`** in `ensure_literal_seed` — note the comment in Task 2.3 about `?ATTR_CHILD_ARC - 1 = 23` being correct but adding a named macro is cleaner; implementer should add `-define(ATTR_PARENT_ARC, 23).` before writing the function.
