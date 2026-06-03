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
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%
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
		create_connection_rule/8
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
	multiplicity_attr
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
		source_nref = OwningClass,
		characterization = State#state.applies_to_nref,
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

%% optional_template_avp(TemplateNref, State) -> [AVP] | []
%% The optional template_nref content AVP on the rule node.
optional_template_avp(undefined, _State) -> [];
optional_template_avp(TemplateNref, State) ->
	[#{attribute => State#state.template_nref_attr, value => TemplateNref}].
