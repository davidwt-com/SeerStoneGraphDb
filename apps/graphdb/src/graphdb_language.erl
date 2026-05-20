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
-include_lib("graphdb/include/graphdb_nrefs.hrl").

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
        LangHumanNref        = find_class_by_name(?NREF_CLASSES, "Human Language"),
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
handle_call({resolve_label, Nref, AttrNref, Chain, Scope}, _From, State) ->
    Reply = do_resolve_label(Nref, AttrNref, Chain, Scope),
    {reply, Reply, State};
handle_call({make_chain, Codes}, _From,
        #state{lang_code_map = CM, dialect_map = DM} = State) ->
    ValidCodes = [C || C <- Codes, maps:is_key(C, CM)],
    Dropped = length(Codes) - length(ValidCodes),
    case Dropped > 0 of
        true  -> logger:warning(
                     "graphdb_language:make_chain dropped ~p unknown codes",
                     [Dropped]);
        false -> ok
    end,
    Chain = do_make_chain(ValidCodes, [], DM),
    {reply, Chain, State};
handle_call({project_language, ProjectRootNref}, _From,
        #state{project_language_nref = PLAttr,
               lang_code_nref        = LCAttr} = State) ->
    Reply = do_project_language(ProjectRootNref, PLAttr, LCAttr),
    {reply, Reply, State};
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
	case graphdb_attr:find_attribute_by_name(?NREF_LITERALS, Name) of
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
		Children = downward_children_by_arc(ParentNref, ?ARC_CLS_CHILD,
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
	case graphdb_attr:find_attribute_by_name(?NREF_LITERALS, Name) of
		{ok, Nref} ->
			Nref;
		not_found ->
			Nref = nref_server:get_nref(),
			NameAVP = #{attribute => ?NAME_ATTR_ATTRIBUTE, value => Name},
			Node = #node{
				nref = Nref,
				kind = attribute,
				parents = [?NREF_LITERALS],
				attribute_value_pairs = [NameAVP]
			},
			{Id1, Id2} = rel_id_server:get_id_pair(),
			P2C = #relationship{
				id             = Id1,
				kind           = taxonomy,
				source_nref    = ?NREF_LITERALS,
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
				target_nref    = ?NREF_LITERALS,
				reciprocal     = ?ARC_ATTR_CHILD,
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
			A#relationship.characterization =:= ?ARC_CLASS_TO_INST],
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
		(#{attribute := ?NAME_ATTR_CLASS, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).


%%---------------------------------------------------------------------
%% do_resolve_label(Nref, AttrNref, Chain, Scope) -> {ok, Value} | not_found
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
	case mnesia:dirty_read(nodes, Nref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case avp_value(AttrNref, AVPs) of
				not_found -> not_found;
				Value     -> {ok, Value}
			end;
		[] ->
			not_found
	end.


%%---------------------------------------------------------------------
%% do_register_language(Code, Name, State) ->
%%     {ok, Nref, NewState} | {error, Reason}
%%
%% Creates a language instance node with kind=instance, parents=[],
%% classes=[LangHumanNref] (cache pre-populated).
%% Writes node + class membership arc pair atomically.
%% Creates the language overlay table after the transaction commits.
%% Updates lang_code_map after the overlay table is ready.
%%---------------------------------------------------------------------
do_register_language(Code, Name, State) ->
	#state{lang_code_nref  = LCAttr,
	       lang_human_nref = LHNref} = State,
	Nref              = nref_server:get_nref(),
	{ArcId1, ArcId2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	CodeAVP = #{attribute => LCAttr,                 value => Code},
	Node = #node{
		nref                  = Nref,
		kind                  = instance,
		parents               = [],
		classes               = [LHNref],
		attribute_value_pairs = [NameAVP, CodeAVP]
	},
	I2C = #relationship{
		id               = ArcId1,
		kind             = instantiation,
		source_nref      = Nref,
		characterization = ?ARC_INST_TO_CLASS,
		target_nref      = LHNref,
		reciprocal       = ?ARC_CLASS_TO_INST,
		avps             = []
	},
	C2I = #relationship{
		id               = ArcId2,
		kind             = instantiation,
		source_nref      = LHNref,
		characterization = ?ARC_CLASS_TO_INST,
		target_nref      = Nref,
		reciprocal       = ?ARC_INST_TO_CLASS,
		avps             = []
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
			ok = ensure_overlay_table(overlay_table_name(Code, environment)),
			NewState = State#state{
				lang_code_map = maps:put(Code, Nref, State#state.lang_code_map)
			},
			{ok, Nref, NewState}
	end.


%%---------------------------------------------------------------------
%% do_register_dialect(Code, Name, BaseCode, State) ->
%%     {ok, Nref, NewState} | {error, Reason}
%%
%% Same as do_register_language/3 plus stamps a base_language AVP
%% referencing the base concept nref.  Updates dialect_map on success.
%%---------------------------------------------------------------------
do_register_dialect(Code, Name, BaseCode, State) ->
	#state{lang_code_map      = CM,
	       base_language_nref = BLAttr} = State,
	case maps:get(BaseCode, CM, not_found) of
		not_found ->
			{error, base_not_found};
		BaseNref ->
			#state{lang_code_nref  = LCAttr,
			       lang_human_nref = LHNref} = State,
			Nref              = nref_server:get_nref(),
			{ArcId1, ArcId2} = rel_id_server:get_id_pair(),
			NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
			CodeAVP = #{attribute => LCAttr,  value => Code},
			BaseAVP = #{attribute => BLAttr,  value => BaseNref},
			Node = #node{
				nref                  = Nref,
				kind                  = instance,
				parents               = [],
				classes               = [LHNref],
				attribute_value_pairs = [NameAVP, CodeAVP, BaseAVP]
			},
			I2C = #relationship{
				id               = ArcId1,
				kind             = instantiation,
				source_nref      = Nref,
				characterization = ?ARC_INST_TO_CLASS,
				target_nref      = LHNref,
				reciprocal       = ?ARC_CLASS_TO_INST,
				avps             = []
			},
			C2I = #relationship{
				id               = ArcId2,
				kind             = instantiation,
				source_nref      = LHNref,
				characterization = ?ARC_CLASS_TO_INST,
				target_nref      = Nref,
				reciprocal       = ?ARC_INST_TO_CLASS,
				avps             = []
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


%%---------------------------------------------------------------------
%% do_project_language(ProjectRootNref, PLAttr, LCAttr) ->
%%     {ok, Code :: atom()} | not_found
%%
%% Reads the project_language AVP from the project root node.
%% Dereferences the stored language concept nref to read the lang_code.
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


%%---------------------------------------------------------------------
%% spawn_hooks(Hooks, Nref, AVPs) -> ok
%%
%% Each hook is called in a freshly spawned process.  Crashes are caught
%% and logged; they never propagate to the caller.
%% Hooks must not re-enter graphdb_language synchronously (deadlock).
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
