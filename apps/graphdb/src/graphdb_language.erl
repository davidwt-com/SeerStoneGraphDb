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
-define(ATTR_PARENT_ARC, 23).   %% Parent/AttrRel -- taxonomy
-define(ATTR_CHILD_ARC,  24).   %% Child/AttrRel  -- taxonomy
-define(CLASS_CHILD_ARC, 26).   %% Child/ClassRel -- taxonomy
-define(INST_PARENT_ARC, 27).   %% Parent/InstRel
-define(INST_CHILD_ARC,  28).   %% Child/InstRel
-define(CLASS_MEMBERSHIP_ARC,    29).
-define(INSTANCE_MEMBERSHIP_ARC, 30).


%%---------------------------------------------------------------------
%% Suppress warnings for pure helpers only used under TEST
%%---------------------------------------------------------------------
-compile({nowarn_unused_function, [overlay_table_name/2, do_make_chain/3]}).

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
    lookup_language_nref/1,
    set_labels/3,
    resolve_label/4,
    make_chain/1,
    project_language/1,
    register_translation_hook/1,
    unregister_translation_hook/1,
    fire_translation_hooks/2
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

lookup_language_nref(Code) ->
    gen_server:call(?MODULE, {lookup_language_nref, Code}).

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

fire_translation_hooks(Nref, AVPs) ->
    gen_server:call(?MODULE, {fire_translation_hooks, Nref, AVPs}).


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
            {stop, {init_failed, Reason}};
        _Class:Reason:Stack ->
            logger:error("graphdb_language: init crashed: ~p ~p",
                [Reason, Stack]),
            {stop, {init_failed, Reason}}
    end.

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
				reciprocal     = ?ATTR_PARENT_ARC,
				avps           = []
			},
			C2P = #relationship{
				id             = Id2,
				kind           = taxonomy,
				source_nref    = Nref,
				characterization = ?ATTR_PARENT_ARC,
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
				{atomic, ok}      -> Nref;
				{aborted, Reason} -> throw({error, Reason})
			end
	end.


%%---------------------------------------------------------------------
%% ensure_overlay_table(TableName) -> ok
%%
%% Creates a disc_copies Mnesia table for language_node records if it
%% does not already exist.
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
%% Scans all instances of the lang_human class to rebuild in-memory maps.
%%---------------------------------------------------------------------
build_lang_maps(LangCodeNref, BaseLangNref, LangHumanNref) ->
	F = fun() ->
		Arcs = mnesia:index_read(relationships, LangHumanNref,
			#relationship.source_nref),
		InstNrefs = [A#relationship.target_nref || A <- Arcs,
			A#relationship.kind          =:= instantiation,
			A#relationship.characterization =:= ?INSTANCE_MEMBERSHIP_ARC],
		Nodes = lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, InstNrefs),
		{CM, NC} = lists:foldl(fun
			(#node{nref = Nref, attribute_value_pairs = AVPs}, {C, N}) ->
				case avp_value(LangCodeNref, AVPs) of
					not_found -> {C, N};
					Code -> {C#{Code => Nref}, N#{Nref => Code}}
				end
		end, {#{}, #{}}, Nodes),
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
