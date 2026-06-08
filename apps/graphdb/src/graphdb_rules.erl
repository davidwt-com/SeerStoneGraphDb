%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_rules manages graph database rules.
%%				graphdb_rules is responsible for storing, evaluating,
%%				and enforcing rules applied to graph operations.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: June 2026 Author: David W. Thomas (david@davidwt.com)
%% F4 Phase A: rule meta-ontology seeding (Rule / CompositionRule /
%% ConnectionRule), Rule Literals sub-group, applies_to/applied_by
%% relationship-attribute pair, and seeded_nrefs/0.  Idempotent init/1
%% mirrors graphdb_language.  Rule create/retrieve/validation land in
%% later F4 Phase A tasks.
%%---------------------------------------------------------------------
-module(graphdb_rules).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
-modified('Date: June 2026').
-modified_by('david@davidwt.com').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
-include("graphdb_nrefs.hrl").

%% node/relationship records are defined inline in every worker (no shared
%% header) -- copied verbatim from graphdb_instance.erl.
-record(node, {
	nref,					%% integer() -- primary key
	kind,					%% category | attribute | class | instance | template
	parents = [],			%% [integer()] -- cache of parent arcs
	classes = [],			%% [integer()] -- cache of instantiation arcs
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() -- primary key
	kind,					%% taxonomy | composition | connection | instantiation
	source_nref,			%% integer() -- arc origin
	characterization,		%% integer() -- arc label (an attribute nref)
	target_nref,			%% integer() -- arc target
	reciprocal,				%% integer() -- arc label as seen from target back
	avps					%% [#{attribute => Nref, value => term()}]
}).

%%---------------------------------------------------------------------
%% Macro Functions
%%---------------------------------------------------------------------
%% NYI - Not Yet Implemented
%%	F = {fun,{Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun,{Arg1,Arg2,...}}
%%	X = Message
%%---------------------------------------------------------------------
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		seeded_nrefs/0,
		create_composition_rule/6,
		create_composition_rule/7,
		create_connection_rule/7,
		create_connection_rule/8,
		get_rule/2,
		rules_for_class/2,
		composition_rules_for_class/2,
		connection_rules_for_class/2,
		effective_rules_for_class/2,
		list_rules/1
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------
-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).


%%---------------------------------------------------------------------
%% State
%%---------------------------------------------------------------------
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
	multiplicity_attr,
	name_pattern_attr
}).


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%-----------------------------------------------------------------------------
%% seeded_nrefs() -> {ok, #{rule => integer(), ...}}
%%
%% Returns the twelve nrefs this worker seeded/located at init/1, keyed
%% by stable atom names shared with the design and the test suite.
%%-----------------------------------------------------------------------------
seeded_nrefs() ->
	gen_server:call(?MODULE, seeded_nrefs).

%%-----------------------------------------------------------------------------
%% create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult)
%% create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
%%                         TemplateNref)
%%     -> {ok, RuleNref} | {error, term()}
%%
%% Creates a composition rule: a kind=instance node whose class membership
%% is the seeded CompositionRule meta-class.  Rule content (child_class_nref,
%% optional template_nref) lives on the node; rule deployment (Template,
%% mode, multiplicity) lives on the applies_to connection arc from the
%% owning (parent) class to the rule instance.  Scope environment writes to
%% the shared ontology; {project, _} is not yet supported.
%%-----------------------------------------------------------------------------
create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult) ->
	create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
							undefined).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
						TemplateNref) ->
	gen_server:call(?MODULE,
		{create_composition_rule, Scope, Name, ParentClass, ChildClass,
		 Mode, Mult, TemplateNref}).

%%-----------------------------------------------------------------------------
%% create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
%%                        Mult)
%% create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
%%                        Mult, TemplateNref)
%%     -> {ok, RuleNref} | {error, term()}
%%
%% Creates a connection rule: a kind=instance node whose class membership is
%% the seeded ConnectionRule meta-class.  Rule content (characterization_nref,
%% target_class_nref, optional template_nref) lives on the node; rule
%% deployment (Template, mode, multiplicity) lives on the applies_to
%% connection arc from the owning (source) class to the rule instance.  Scope
%% environment writes to the shared ontology; {project, _} is not yet
%% supported.
%%-----------------------------------------------------------------------------
create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
					   Mult) ->
	create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
						   Mult, undefined).

create_connection_rule(Scope, Name, SourceClass, Char, TargetClass, Mode,
					   Mult, TemplateNref) ->
	gen_server:call(?MODULE,
		{create_connection_rule, Scope, Name, SourceClass, Char, TargetClass,
		 Mode, Mult, TemplateNref}).

%%-----------------------------------------------------------------------------
%% get_rule(Scope, RuleNref) -> {ok, #node{}} | not_found
%%
%% Returns the full rule instance node iff RuleNref names a kind=instance
%% node whose class membership includes CompositionRule or ConnectionRule.
%% Scope environment reads the shared ontology; {project, _} -> not_found.
%%-----------------------------------------------------------------------------
get_rule(Scope, RuleNref) ->
	gen_server:call(?MODULE, {get_rule, Scope, RuleNref}).

%%-----------------------------------------------------------------------------
%% rules_for_class(Scope, ClassNref) -> {ok, [#node{}]}
%%
%% All rules (both kinds) attached to ClassNref -- i.e. the targets of the
%% applies_to connection arcs out of ClassNref.  {project, _} -> {ok, []}.
%% DIRECT attachments only: rules attached to ClassNref's taxonomy
%% ancestors are NOT included.  Ancestor-walking (effective_rules_for_class)
%% is a Phase B addition.
%%-----------------------------------------------------------------------------
rules_for_class(Scope, ClassNref) ->
	gen_server:call(?MODULE, {rules_for_class, Scope, ClassNref}).

%%-----------------------------------------------------------------------------
%% composition_rules_for_class(Scope, ClassNref) -> {ok, [#node{}]}
%% connection_rules_for_class(Scope, ClassNref)  -> {ok, [#node{}]}
%%
%% Attached rules of ClassNref filtered to the CompositionRule (resp.
%% ConnectionRule) meta-class.  {project, _} -> {ok, []}.
%%-----------------------------------------------------------------------------
composition_rules_for_class(Scope, ClassNref) ->
	gen_server:call(?MODULE, {rules_for_class_kind, Scope, ClassNref,
							  composition_rule}).

connection_rules_for_class(Scope, ClassNref) ->
	gen_server:call(?MODULE, {rules_for_class_kind, Scope, ClassNref,
							  connection_rule}).

%%-----------------------------------------------------------------------------
%% effective_rules_for_class(Scope, ClassNref) ->
%%     {ok, [{AncestorNref :: integer(),
%%            [{RuleNode :: #node{}, Deployment :: map()}]}]}
%%
%% Every rule attached to ClassNref AND to each of its taxonomy ancestors,
%% grouped by the class it is attached to, nearest-first (ClassNref itself
%% first), each rule paired with that attachment's deployment map
%% (#{mode, multiplicity, template}).  Both rule kinds are returned; callers
%% filter inline.  Levels contributing no rules are omitted.
%% {project, _} -> {ok, []}.
%%
%% Does NOT resolve override/shadow/conflict -- every level's rules are
%% present.  Resolution is the firing engine's job (Phase B2/B5).
%%-----------------------------------------------------------------------------
effective_rules_for_class(Scope, ClassNref) ->
	gen_server:call(?MODULE, {effective_rules_for_class, Scope, ClassNref}).

%%-----------------------------------------------------------------------------
%% list_rules(Scope) -> {ok, [#node{}]}
%%
%% Every rule instance in the ontology: the instances of both meta-classes.
%% {project, _} -> {ok, []}.
%%-----------------------------------------------------------------------------
list_rules(Scope) ->
	gen_server:call(?MODULE, {list_rules, Scope}).


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

init([]) ->
	try
		RuleLitGrp     = ensure_seed("Rule Literals",         ?NREF_LITERALS),
		ChildClassAttr = ensure_seed("child_class_nref",      RuleLitGrp),
		TargetClassAttr= ensure_seed("target_class_nref",     RuleLitGrp),
		TemplateAttr   = ensure_seed("template_nref",         RuleLitGrp),
		CharAttr       = ensure_seed("characterization_nref", RuleLitGrp),
		ModeAttr       = ensure_seed("mode",                  RuleLitGrp),
		MultAttr       = ensure_seed("multiplicity",          RuleLitGrp),
		NamePatternAttr= ensure_seed("name_pattern",          RuleLitGrp),
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
			multiplicity_attr          = MultAttr,
			name_pattern_attr          = NamePatternAttr
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
		multiplicity_attr          => State#state.multiplicity_attr,
		name_pattern               => State#state.name_pattern_attr
	}}, State};
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
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_composition_rule, {project, _}, _, _, _, _, _, _},
			_From, State) ->
	{reply, {error, project_rules_not_yet_supported}, State};
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
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_connection_rule, {project, _}, _, _, _, _, _, _, _},
			_From, State) ->
	{reply, {error, project_rules_not_yet_supported}, State};
handle_call({get_rule, environment, RuleNref}, _From, State) ->
	Reply = case mnesia:dirty_read(nodes, RuleNref) of
		[#node{kind = instance} = N] ->
			case is_rule_instance(N, State) of
				true  -> {ok, N};
				false -> not_found
			end;
		_ ->
			not_found
	end,
	{reply, Reply, State};
handle_call({get_rule, {project, _}, _}, _From, State) ->
	{reply, not_found, State};
handle_call({rules_for_class, environment, ClassNref}, _From, State) ->
	{reply, {ok, attached_rules(ClassNref, State)}, State};
handle_call({rules_for_class, {project, _}, _}, _From, State) ->
	{reply, {ok, []}, State};
handle_call({effective_rules_for_class, environment, ClassNref}, _From, State) ->
	{reply, {ok, effective_rules(ClassNref, State)}, State};
handle_call({effective_rules_for_class, {project, _}, _}, _From, State) ->
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
	{ok, State}.


%%---------------------------------------------------------------------
%% Seeding helpers (idempotent -- see F4 Phase A plan Architecture Notes)
%%---------------------------------------------------------------------

%% ensure_seed(Name, ParentNref) -> Nref
%% Plain attribute child of ParentNref (taxonomy arc pair).  Find-first
%% via the public graphdb_attr:find_attribute_by_name/2; otherwise writes
%% the node + arc pair in one transaction.  Mirrors
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
%% Find-first on the forward name; otherwise create the reciprocal pair
%% via the public graphdb_attr API.
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
				 A#relationship.kind =:= taxonomy,
				 A#relationship.characterization =:= ?ARC_CLS_CHILD],
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
		(#{attribute := ?NAME_ATTR_CLASS, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).

%% instantiable_marker_nref/0 -> InstAttrNref
%% Reads the seeded `instantiable' marker nref from graphdb_attr (L9).
instantiable_marker_nref() ->
	{ok, #{instantiable := InstAttr}} = graphdb_attr:seeded_nrefs(),
	InstAttr.


%%---------------------------------------------------------------------
%% Validation (runs BEFORE do_create_rule allocates any nref)
%%---------------------------------------------------------------------
%% Validators run in order, first error wins.  mode/multiplicity are
%% validated first (pure), then the class/reference/characterization/
%% template lookups via mnesia:dirty_read.  A rejected create writes
%% nothing -- validation never reaches the writer's nref allocation.

%% validate_composition(ParentClass, ChildClass, Mode, Mult, TemplateNref)
%%     -> ok | {error, atom()}
validate_composition(ParentClass, ChildClass, Mode, Mult, TemplateNref) ->
	chain([
		fun() -> validate_mode(Mode) end,
		fun() -> validate_multiplicity(Mult) end,
		fun() -> validate_owning_class(ParentClass) end,
		fun() -> validate_referenced_class(ChildClass) end,
		fun() -> validate_template(TemplateNref) end
	]).

%% validate_connection(SourceClass, Char, TargetClass, Mode, Mult,
%%                     TemplateNref) -> ok | {error, atom()}
validate_connection(SourceClass, Char, TargetClass, Mode, Mult, TemplateNref) ->
	chain([
		fun() -> validate_mode(Mode) end,
		fun() -> validate_multiplicity(Mult) end,
		fun() -> validate_owning_class(SourceClass) end,
		fun() -> validate_referenced_class(TargetClass) end,
		fun() -> validate_characterization(Char) end,
		fun() -> validate_template(TemplateNref) end
	]).

%% chain(Funs) -> ok | {error, term()}
%% Runs each zero-arg validator in order; first error wins.
chain([]) ->
	ok;
chain([F | Rest]) ->
	case F() of
		ok               -> chain(Rest);
		{error, _} = Err -> Err
	end.

validate_mode(M) when M =:= mandatory; M =:= auto; M =:= propose ->
	ok;
validate_mode(_) ->
	{error, invalid_mode}.

validate_multiplicity(unbounded) ->
	ok;
validate_multiplicity(N) when is_integer(N), N >= 1 ->
	ok;
validate_multiplicity(_) ->
	{error, invalid_multiplicity}.

%% validate_owning_class(Nref) -> ok | {error, atom()}
%% The owning class must exist, be a class, and have a default template --
%% the applies_to arc stamps the default template as deployment AVP index 0.
%% An abstract class (L9 instantiable=false) or a class whose default
%% template was deleted ("forced disambiguation") has none; reject cleanly
%% rather than let do_create_rule badmatch.
validate_owning_class(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = class}] ->
			case graphdb_class:default_template(Nref) of
				{ok, _}   -> ok;
				not_found -> {error, owning_class_has_no_default_template}
			end;
		[#node{}] ->
			{error, not_a_class};
		[] ->
			{error, class_not_found}
	end.

%% validate_referenced_class(Nref) -> ok | {error, atom()}
validate_referenced_class(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = class}] -> ok;
		[#node{}]             -> {error, referenced_not_a_class};
		[]                    -> {error, referenced_class_not_found}
	end.

%% validate_characterization(Nref) -> ok | {error, atom()}
%% The characterization must exist and be a relationship attribute.
validate_characterization(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[] ->
			{error, characterization_not_found};
		[#node{}] ->
			case graphdb_attr:attribute_type_of(Nref) of
				{ok, relationship} -> ok;
				_                  -> {error, not_a_relationship_attribute}
			end
	end.

%% validate_template(TemplateNref) -> ok | {error, atom()}
%% undefined means "no explicit template"; otherwise the nref must be a
%% kind=template node.
validate_template(undefined) ->
	ok;
validate_template(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = template}] -> ok;
		[#node{}]                -> {error, not_a_template};
		[]                       -> {error, template_not_found}
	end.


%%---------------------------------------------------------------------
%% Rule write path (shared by composition and connection rules)
%%---------------------------------------------------------------------

%% do_create_rule(MetaClassNref, Name, OwningClass, ContentAVPs, Mode, Mult,
%%                State) -> {ok, RuleNref} | {error, term()}
%%
%% Allocates all nrefs/ids OUTSIDE the transaction, then writes -- in one
%% transaction -- the rule instance node, the instance<->class membership
%% arc pair (chars 29/30), and the applies_to/applied_by connection arc
%% pair.  Rule content lives on the node; rule deployment (Template, mode,
%% multiplicity) lives on the forward applies_to arc only.
%% (Validation is added in a later F4 Phase A task; for now it writes
%% directly.)
do_create_rule(MetaClassNref, Name, OwningClass, ContentAVPs, Mode, Mult,
			   State) ->
	%% Defense-in-depth: validate_owning_class/1 already rejects an owning
	%% class with no default template before this writer runs, so the
	%% not_found branch is unreachable in practice -- but a `case` keeps a
	%% future caller path from badmatching here.
	case graphdb_class:default_template(OwningClass) of
		not_found ->
			{error, owning_class_has_no_default_template};
		{ok, DefaultTemplate} ->
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
				target_nref = RuleNref, reciprocal = ?ARC_INST_TO_CLASS,
				avps = []},
			DeployAVPs = [#{attribute => ?ARC_TEMPLATE, value => DefaultTemplate},
						  #{attribute => State#state.mode_attr, value => Mode},
						  #{attribute => State#state.multiplicity_attr,
							value => Mult}],
			AppliesTo = #relationship{id = ConnId1, kind = connection,
				source_nref = OwningClass,
				characterization = State#state.applies_to_nref,
				target_nref = RuleNref, reciprocal = State#state.applied_by_nref,
				avps = DeployAVPs},
			AppliedBy = #relationship{id = ConnId2, kind = connection,
				source_nref = RuleNref,
				characterization = State#state.applied_by_nref,
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
			end
	end.

%% optional_template_avp(TemplateNref, State) -> [AVP] | []
%% The optional template_nref content AVP on the rule node.
optional_template_avp(undefined, _State) -> [];
optional_template_avp(TemplateNref, State) ->
	[#{attribute => State#state.template_nref_attr, value => TemplateNref}].


%%---------------------------------------------------------------------
%% Rule read path (retrieval -- dirty, read-only)
%%---------------------------------------------------------------------

%% applies_to_arcs(ClassNref, State) -> [#relationship{}]
%% The forward applies_to connection arcs out of ClassNref -- one per rule
%% attached directly to the class.  Shared by attached_rules/2 (bare nodes)
%% and attached_rules_with_deployment/2 (nodes + deployment map).
applies_to_arcs(ClassNref, State) ->
	AppliesTo = State#state.applies_to_nref,
	Arcs = mnesia:dirty_index_read(relationships, ClassNref,
								   #relationship.source_nref),
	[A || A <- Arcs,
	 A#relationship.kind =:= connection,
	 A#relationship.characterization =:= AppliesTo].

%% attached_rules(ClassNref, State) -> [#node{}]
%% Rules attached directly to ClassNref: the targets of its applies_to arcs.
attached_rules(ClassNref, State) ->
	RuleNrefs = [A#relationship.target_nref
				 || A <- applies_to_arcs(ClassNref, State)],
	lists:flatmap(fun(N) -> mnesia:dirty_read(nodes, N) end, RuleNrefs).

%% effective_rules(ClassNref, State) -> [{LevelNref, [{#node{}, map()}]}]
%% Self-first, nearest-first taxonomy gather: the class itself followed by its
%% ancestors (graphdb_class:ancestors/1 order).  Each level carries the rules
%% attached directly to it, paired with that attachment's deployment.  Levels
%% with no attached rules are dropped (B1-D7).  Resolves nothing (B1-D1).
effective_rules(ClassNref, State) ->
	Chain = [ClassNref | ancestor_nrefs(ClassNref)],
	[{Level, Pairs}
	 || Level <- Chain,
		Pairs <- [attached_rules_with_deployment(Level, State)],
		Pairs =/= []].

%% ancestor_nrefs(ClassNref) -> [integer()]
%% The taxonomy ancestors of ClassNref, nearest-first, via the canonical
%% graphdb_class:ancestors/1 walk.  A bad starting class (unknown nref or a
%% non-class node) makes ancestors/1 return {error, _}; B1 maps that to an
%% empty ancestor set (B1-D6).  The direct-attachment read on a bad nref is
%% likewise empty, so the overall effective result is {ok, []}.
ancestor_nrefs(ClassNref) ->
	case graphdb_class:ancestors(ClassNref) of
		{ok, Nodes} -> [N#node.nref || N <- Nodes];
		{error, _}  -> []
	end.

%% attached_rules_with_deployment(ClassNref, State) -> [{#node{}, map()}]
%% Deployment-preserving sibling of attached_rules/2: each rule attached
%% directly to ClassNref paired with the deployment map decoded from its
%% applies_to arc.
attached_rules_with_deployment(ClassNref, State) ->
	[ {RuleNode, decode_deployment(Arc#relationship.avps, State)}
	  || Arc <- applies_to_arcs(ClassNref, State),
		 RuleNode <- mnesia:dirty_read(nodes, Arc#relationship.target_nref) ].

%% decode_deployment(AVPs, State) -> map()
%% Decodes an applies_to arc's deployment AVPs into the symbolic Deployment map
%% #{mode, multiplicity, template}.  A key whose AVP is absent is omitted
%% (B1-D2).  The `template' key reads the arc Template scope marker
%% (?ARC_TEMPLATE, attr 31) -- NOT the template_nref content literal on the
%% rule node.
decode_deployment(AVPs, State) ->
	Pairs = [{mode,         State#state.mode_attr},
			 {multiplicity, State#state.multiplicity_attr},
			 {template,     ?ARC_TEMPLATE}],
	lists:foldl(fun({Key, AttrNref}, Acc) ->
		case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
			{value, #{value := V}} -> Acc#{Key => V};
			false                  -> Acc
		end
	end, #{}, Pairs).

%% instances_of(MetaNref) -> [#node{}]
%% Instances of a meta-class are the class->instance (char 30) targets.
instances_of(MetaNref) ->
	Arcs = mnesia:dirty_index_read(relationships, MetaNref,
								   #relationship.source_nref),
	Nrefs = [A#relationship.target_nref || A <- Arcs,
			 A#relationship.kind =:= instantiation,
			 A#relationship.characterization =:= ?ARC_CLASS_TO_INST],
	lists:flatmap(fun(N) -> mnesia:dirty_read(nodes, N) end, Nrefs).

%% is_rule_instance(#node{}, State) -> boolean()
%% True iff the node's class membership includes either meta-class.
is_rule_instance(#node{classes = Classes}, State) ->
	lists:member(State#state.composition_rule_nref, Classes)
		orelse lists:member(State#state.connection_rule_nref, Classes).

%% meta_nref(MetaKey, State) -> integer()
meta_nref(composition_rule, State) -> State#state.composition_rule_nref;
meta_nref(connection_rule,  State) -> State#state.connection_rule_nref.
