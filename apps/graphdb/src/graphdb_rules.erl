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
%% Rule meta-ontology seeding (Rule / CompositionRule /
%% ConnectionRule), Rule Literals sub-group, applies_to/applied_by
%% relationship-attribute pair, and seeded_nrefs/0.  Idempotent init/1
%% mirrors graphdb_language.  Rule create/retrieve/validation land in
%% later tasks.
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
		create_composition_rule/8,
		create_connection_rule/8,
		create_connection_rule/9,
		get_rule/2,
		rules_for_class/2,
		composition_rules_for_class/2,
		connection_rules_for_class/2,
		effective_rules_for_class/2,
		effective_connection_rules/2,
		list_rules/1,
		plan_composition_firing/2,
		plan_composition_firing/3,
		default_conflict_resolver/0,
		rule_child_class/1,
		rule_child_name/4
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
	reciprocal_nref_attr,
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
%% Returns the thirteen nrefs this worker seeded/located at init/1, keyed
%% by stable atom names shared with the design and the test suite.
%%-----------------------------------------------------------------------------
seeded_nrefs() ->
	gen_server:call(?MODULE, seeded_nrefs).

%%-----------------------------------------------------------------------------
%% create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult)
%% create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
%%                         TemplateNref)
%% create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
%%                         TemplateNref, Opts)
%%     -> {ok, RuleNref} | {error, term()}
%%
%% Opts :: #{name_pattern => string()} — optional keys; unknown keys ignored.
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
							undefined, #{}).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
						TemplateNref) ->
	create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
							TemplateNref, #{}).

create_composition_rule(Scope, Name, ParentClass, ChildClass, Mode, Mult,
						TemplateNref, Opts) when is_map(Opts) ->
	gen_server:call(?MODULE,
		{create_composition_rule, Scope, Name, ParentClass, ChildClass,
		 Mode, Mult, TemplateNref, Opts}).

%%-----------------------------------------------------------------------------
%% create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
%%                        Mode, Mult)
%% create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
%%                        Mode, Mult, TemplateNref)
%%     -> {ok, RuleNref} | {error, term()}
%%
%% Creates a connection rule: a kind=instance node whose class membership is
%% the seeded ConnectionRule meta-class.  Rule content (characterization_nref,
%% reciprocal_nref, target_class_nref, optional template_nref) lives on the
%% node; rule deployment (Template, mode, multiplicity) lives on the applies_to
%% connection arc from the owning (source) class to the rule instance.  Recip is
%% the reverse arc label: the arc as seen from the target back.  Scope
%% environment writes to the shared ontology; {project, _} is not supported.
%%-----------------------------------------------------------------------------
create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
					   Mode, Mult) ->
	create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
						   Mode, Mult, undefined).

create_connection_rule(Scope, Name, SourceClass, Char, Recip, TargetClass,
					   Mode, Mult, TemplateNref) ->
	gen_server:call(?MODULE,
		{create_connection_rule, Scope, Name, SourceClass, Char, Recip,
		 TargetClass, Mode, Mult, TemplateNref}).

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
%% is a later-phase addition.
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
%% present.  Resolution is the firing engine's job.
%%-----------------------------------------------------------------------------
effective_rules_for_class(Scope, ClassNref) ->
	gen_server:call(?MODULE, {effective_rules_for_class, Scope, ClassNref}).

%%-----------------------------------------------------------------------------
%% effective_connection_rules(Scope, ClassNref) ->
%%     {ok, [{RuleNode :: #node{}, Deployment :: map(),
%%            ConnSpec :: #{characterization := integer(),
%%                          reciprocal := integer(),
%%                          target_class := integer()}}]}
%%
%% The effective rules of ClassNref (self + taxonomy ancestors, nearest-first)
%% filtered to the ConnectionRule meta-class, each paired with its applies_to
%% deployment and a ConnSpec decoded from the rule node's content AVPs.  The
%% connection-firing engine consumes this during create_instance.  Additive -- a
%% rule reached from two ancestors appears twice (precedence is a later phase).
%% {project, _} -> {ok, []}.
%%-----------------------------------------------------------------------------
effective_connection_rules(Scope, ClassNref) ->
	gen_server:call(?MODULE, {effective_connection_rules, Scope, ClassNref}).

%%-----------------------------------------------------------------------------
%% list_rules(Scope) -> {ok, [#node{}]}
%%
%% Every rule instance in the ontology: the instances of both meta-classes.
%% {project, _} -> {ok, []}.
%%-----------------------------------------------------------------------------
list_rules(Scope) ->
	gen_server:call(?MODULE, {list_rules, Scope}).

%%-----------------------------------------------------------------------------
%% plan_composition_firing(Scope, ClassNref) ->
%%     {ok, PlanNode} | {error, Reason, #{plan_so_far => PlanNode, culprit => #node{} | undefined}}
%%
%% Pure read: walks the effective mandatory composition rules for ClassNref
%% (environment scope) and builds an abstract plan tree of the instance subtree
%% that would be created.  No nrefs are allocated.  The returned PlanNode is a
%% map with:
%%   class              -- ClassNref (root of this plan node)
%%   name               -- string() child name, or `undefined' for the top level
%%   rule               -- #node{} rule that generated this node, or the atom
%%                         `root' for the top level (the requested instance)
%%   deploy             -- deployment map #{mode, multiplicity, template}, or
%%                         `undefined' for the root
%%   mandatory_children -- [PlanNode] recursive sub-tree for mandatory rules
%%   auto_rules         -- [{#node{}, Deployment}] auto rules attached here
%%                         (not expanded further)
%%
%% Error reasons:
%%   {class_not_instantiable, ChildClassNref} --
%%       a mandatory rule's child_class is abstract
%%
%% Scope {project, _} returns a leaf plan immediately (no rule lookup).
%%-----------------------------------------------------------------------------
plan_composition_firing(Scope, ClassNref) ->
	gen_server:call(?MODULE, {plan_composition_firing, Scope, ClassNref}).

%%-----------------------------------------------------------------------------
%% plan_composition_firing(Scope, ClassNref, ConflictResolver) ->
%%     {ok, PlanNode} | {error, Reason, #{plan_so_far, culprit}}
%%
%% As /2, but applies ConflictResolver to each cascade level's composition pairs
%% before planning.  /2 is preserved as the additive (unresolved) public read.
%%-----------------------------------------------------------------------------
plan_composition_firing(Scope, ClassNref, ConflictResolver) ->
	gen_server:call(?MODULE,
		{plan_composition_firing, Scope, ClassNref, ConflictResolver}).

%%-----------------------------------------------------------------------------
%% default_conflict_resolver() -> fun((ConflictContext) -> [Pair])
%%
%% The built-in B5 conflict resolver.  Called in the CALLER's process (e.g. from
%% graphdb_instance:create_instance/3,4), where seeded_nrefs/0 is safe.  Returns
%% ONE closure that bakes in the seed nrefs it needs and dispatches on the
%% context `kind'.  The closure is deadlock-safe in either the graphdb_rules or
%% graphdb_instance process: it touches only in-memory #node AVPs, the
%% relationships table (dirty), and graphdb_class (a different gen_server).
%%
%% ConflictContext :: #{kind := composition | connection,
%%                      rules := [Pair], class_nref := integer()}
%%   kind = composition -> Pair = {RuleNode, Deploy}
%%   kind = connection  -> Pair = {RuleNode, Deploy, ConnSpec}
%%
%% Bakes in the seed nrefs it needs (read ONCE here, in the caller's process)
%% and returns a closure dispatching on the context `kind'.  Connection
%% resolution is a pass-through until Task 4.
%%-----------------------------------------------------------------------------
default_conflict_resolver() ->
	{ok, Seeds} = seeded_nrefs(),
	ChildAttr = maps:get(child_class_nref_attr, Seeds),
	TplAttr   = maps:get(template_nref_attr, Seeds),
	AppliedBy = maps:get(applied_by, Seeds),
	fun(Ctx) -> resolve_conflicts(Ctx, ChildAttr, TplAttr, AppliedBy) end.

%%-----------------------------------------------------------------------------
%% rule_child_class(RuleNode :: #node{}) -> integer() | undefined
%%
%% Reads the child_class_nref content AVP from a composition rule node.
%% Called from graphdb_instance (cross-process), so uses the public
%% seeded_nrefs/0 to learn the attribute nref.
%%-----------------------------------------------------------------------------
rule_child_class(RuleNode) ->
	{ok, Seeds} = seeded_nrefs(),
	content_avp_value(RuleNode, maps:get(child_class_nref_attr, Seeds)).

%%-----------------------------------------------------------------------------
%% rule_child_name(RuleNode, ChildClass, I, Mult) -> string()
%%
%% Derives the child instance name for the I-th instance (1-based) of
%% ChildClass created by RuleNode.  Uses the name_pattern content AVP when
%% present; falls back to "ClassName" (mult=1) or "ClassName N" (mult>1).
%% Called from graphdb_instance (cross-process), so uses the public
%% seeded_nrefs/0 to learn the attribute nref.
%%-----------------------------------------------------------------------------
rule_child_name(RuleNode, ChildClass, I, Mult) ->
	{ok, Seeds} = seeded_nrefs(),
	resolve_child_name_pub(RuleNode, ChildClass, I, Mult,
						   maps:get(name_pattern, Seeds)).


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
		ReciprocalAttr = ensure_seed("reciprocal_nref",       RuleLitGrp),
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
			reciprocal_nref_attr       = ReciprocalAttr,
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
		reciprocal_nref_attr       => State#state.reciprocal_nref_attr,
		mode_attr                  => State#state.mode_attr,
		multiplicity_attr          => State#state.multiplicity_attr,
		name_pattern               => State#state.name_pattern_attr
	}}, State};
handle_call({create_composition_rule, environment, Name, ParentClass,
			 ChildClass, Mode, Mult, TemplateNref, Opts}, _From, State) ->
	Reply = case validate_composition(ParentClass, ChildClass, Mode, Mult,
									  TemplateNref) of
		ok ->
			ContentAVPs = [#{attribute => State#state.child_class_nref_attr,
							 value => ChildClass}
						   | optional_template_avp(TemplateNref, State)]
						  ++ optional_name_pattern_avp(Opts, State),
			do_create_rule(State#state.composition_rule_nref, Name,
				ParentClass, ContentAVPs, Mode, Mult, State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_composition_rule, {project, _}, _, _, _, _, _, _, _},
			_From, State) ->
	{reply, {error, project_rules_not_yet_supported}, State};
handle_call({create_connection_rule, environment, Name, SourceClass, Char,
			 Recip, TargetClass, Mode, Mult, TemplateNref}, _From, State) ->
	Reply = case validate_connection(SourceClass, Char, Recip, TargetClass,
									 Mode, Mult, TemplateNref) of
		ok ->
			ContentAVPs = [#{attribute => State#state.characterization_nref_attr,
							 value => Char},
						   #{attribute => State#state.reciprocal_nref_attr,
							 value => Recip},
						   #{attribute => State#state.target_class_nref_attr,
							 value => TargetClass}
						   | optional_template_avp(TemplateNref, State)],
			do_create_rule(State#state.connection_rule_nref, Name,
				SourceClass, ContentAVPs, Mode, Mult, State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};
handle_call({create_connection_rule, {project, _}, _, _, _, _, _, _, _, _},
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
handle_call({effective_connection_rules, environment, ClassNref}, _From, State) ->
	{reply, {ok, connection_specs(ClassNref, State)}, State};
handle_call({effective_connection_rules, {project, _}, _}, _From, State) ->
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
handle_call({plan_composition_firing, environment, ClassNref}, _From, State) ->
	%% /2 is the additive, UNRESOLVED public read (B1 contract).  It must stay
	%% identity forever — do NOT route it through default_conflict_resolver/0,
	%% which becomes the real precedence algorithm in B5 Tasks 2-4.
	Identity = fun(#{rules := R}) -> R end,
	Reply = plan_node(ClassNref, root, undefined, undefined, [], State, Identity),
	{reply, Reply, State};
handle_call({plan_composition_firing, {project, _}, ClassNref}, _From, State) ->
	{reply, {ok, leaf_plan(ClassNref, root, undefined, undefined)}, State};
handle_call({plan_composition_firing, environment, ClassNref, Resolver},
			_From, State) ->
	Reply = plan_node(ClassNref, root, undefined, undefined, [], State, Resolver),
	{reply, Reply, State};
handle_call({plan_composition_firing, {project, _}, ClassNref, _Resolver},
			_From, State) ->
	{reply, {ok, leaf_plan(ClassNref, root, undefined, undefined)}, State};
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
%% Seeding helpers (idempotent -- see the rules-engine design)
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
%% Reads the seeded `instantiable' marker nref from graphdb_attr.
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

%% validate_connection(SourceClass, Char, Recip, TargetClass, Mode, Mult,
%%                     TemplateNref) -> ok | {error, atom()}
validate_connection(SourceClass, Char, Recip, TargetClass, Mode, Mult,
					TemplateNref) ->
	chain([
		fun() -> validate_mode(Mode) end,
		fun() -> validate_multiplicity(Mult) end,
		fun() -> validate_owning_class(SourceClass) end,
		fun() -> validate_referenced_class(TargetClass) end,
		fun() -> validate_characterization(Char) end,
		fun() -> validate_reciprocal(Recip) end,
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

validate_multiplicity({Min, Max})
		when is_integer(Min), Min >= 0,
			 is_integer(Max), Max >= 1, Max >= Min ->
	ok;
validate_multiplicity({Min, unbounded})
		when is_integer(Min), Min >= 0 ->
	ok;
validate_multiplicity(_) ->
	{error, invalid_multiplicity}.

%% validate_owning_class(Nref) -> ok | {error, atom()}
%% The owning class must exist, be a class, and have a default template --
%% the applies_to arc stamps the default template as deployment AVP index 0.
%% An abstract class (instantiable=false) or a class whose default
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

%% validate_reciprocal(Nref) -> ok | {error, atom()}
%% The reciprocal must exist and be a relationship attribute.
validate_reciprocal(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[] ->
			{error, reciprocal_not_found};
		[#node{}] ->
			case graphdb_attr:attribute_type_of(Nref) of
				{ok, relationship} -> ok;
				_                  -> {error, reciprocal_not_a_relationship_attribute}
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
%% (Validation is added in a later task; for now it writes
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

%% optional_name_pattern_avp(Opts, State) -> [AVP] | []
%% The optional name_pattern content AVP on the rule node.
optional_name_pattern_avp(Opts, State) ->
	case maps:get(name_pattern, Opts, undefined) of
		undefined -> [];
		Pattern   -> [#{attribute => State#state.name_pattern_attr,
						value => Pattern}]
	end.


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
%% with no attached rules are dropped.  Resolves nothing.
effective_rules(ClassNref, State) ->
	Chain = [ClassNref | ancestor_nrefs(ClassNref)],
	[{Level, Pairs}
	 || Level <- Chain,
		Pairs <- [attached_rules_with_deployment(Level, State)],
		Pairs =/= []].

%% ancestor_nrefs(ClassNref) -> [integer()]
%% The taxonomy ancestors of ClassNref, nearest-first, via the canonical
%% graphdb_class:ancestors/1 walk.  A bad starting class (unknown nref or a
%% non-class node) makes ancestors/1 return {error, _}; this maps that to an
%% empty ancestor set.  The direct-attachment read on a bad nref is
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
%%.  The `template' key reads the arc Template scope marker
%% (?ARC_TEMPLATE, attr 31) -- NOT the template_nref content literal on the
%% rule node.  'multiplicity' is a {Min, Max} range; the fold copies
%% it verbatim.
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


%%---------------------------------------------------------------------
%% Plan path (pure read)
%%---------------------------------------------------------------------
%% plan_composition_firing/2 runs inside the gen_server process.  It calls
%% effective_rules/2 (the internal state-passing helper) directly -- calling
%% the public effective_rules_for_class/2 from within the gen_server would
%% deadlock on the gen_server:call.

%% leaf_plan(ClassNref, Rule, Deploy, Name) -> PlanNode
%% Deploy is the deployment map of the rule that mandated this node
%% (`undefined` for the root).  Carried so the report's `deployment` field
%% is the real #{mode, multiplicity, template}.
leaf_plan(ClassNref, Rule, Deploy, Name) ->
	#{class => ClassNref, name => Name, rule => Rule, deploy => Deploy,
	  mandatory_children => [], auto_rules => [], propose_rules => []}.

%% plan_node(ClassNref, Rule, Deploy, Name, OnPath, State, Resolver)
%%   -> {ok, PlanNode} | {error, Reason, #{plan_so_far, culprit}}
%% Recursively expands the mandatory cascade for ClassNref.  OnPath is the
%% class path root->here (cycle guard).  Rule/Deploy describe the
%% composition rule that mandated this node (`root`/`undefined` for the
%% requested instance).  Resolver is the B5 conflict resolver, applied to this
%% level's composition pairs before planning.
plan_node(ClassNref, Rule, Deploy, Name, OnPath, State, Resolver) ->
	OnPath1 = [ClassNref | OnPath],
	CompRules0 = composition_pairs(ClassNref, State),
	CompRules = Resolver(#{kind => composition, rules => CompRules0,
						   class_nref => ClassNref}),
	plan_rules(CompRules, OnPath1, State, Resolver,
			   leaf_plan(ClassNref, Rule, Deploy, Name)).

%% composition_pairs(ClassNref, State) -> [{#node{}, Deployment}]
%% Effective rules (self + taxonomy ancestors, nearest-first) filtered to the
%% CompositionRule meta-class.  Flattened across levels, preserving order.
composition_pairs(ClassNref, State) ->
	[ {RuleNode, Deploy}
	  || {_Level, Pairs} <- effective_rules(ClassNref, State),
		 {RuleNode, Deploy} <- Pairs,
		 is_composition_rule(RuleNode, State) ].

%% is_composition_rule(Node, State) -> boolean()
is_composition_rule(#node{classes = Classes}, State) ->
	lists:member(State#state.composition_rule_nref, Classes).

%% connection_specs(ClassNref, State) -> [{#node{}, Deployment, ConnSpec}]
%% Effective rules (self + ancestors, nearest-first) filtered to ConnectionRule,
%% each paired with its deployment and decoded content spec.  Order preserved.
connection_specs(ClassNref, State) ->
	[ {RuleNode, Deploy, connection_spec(RuleNode, State)}
	  || {_Level, Pairs} <- effective_rules(ClassNref, State),
		 {RuleNode, Deploy} <- Pairs,
		 is_connection_rule(RuleNode, State) ].

%% is_connection_rule(Node, State) -> boolean()
is_connection_rule(#node{classes = Classes}, State) ->
	lists:member(State#state.connection_rule_nref, Classes).

%% connection_spec(RuleNode, State) -> #{characterization, reciprocal, target_class}
connection_spec(RuleNode, State) ->
	#{characterization =>
		  content_avp_value(RuleNode, State#state.characterization_nref_attr),
	  reciprocal =>
		  content_avp_value(RuleNode, State#state.reciprocal_nref_attr),
	  target_class =>
		  content_avp_value(RuleNode, State#state.target_class_nref_attr)}.

%%---------------------------------------------------------------------
%% B5 conflict resolution (default resolver body)
%%---------------------------------------------------------------------
%% resolve_conflicts(Ctx, ChildAttr, TplAttr, AppliedBy) -> [Pair]
%% Ctx = #{kind, rules, class_nref}.  Pure over the seed nrefs + graphdb_class +
%% the relationships table; no graphdb_rules gen_server call (deadlock-safe in
%% either process).

resolve_conflicts(#{kind := composition, rules := Pairs}, ChildAttr, TplAttr,
				  AppliedBy) ->
	Items = [comp_item(P, ChildAttr, TplAttr, AppliedBy) || P <- Pairs],
	Groups = assign_groups(Items, composition),
	lists:flatmap(fun(G) -> resolve_group(G, composition) end, Groups);
resolve_conflicts(#{kind := connection, rules := Specs}, _ChildAttr, _TplAttr,
				  _AppliedBy) ->
	%% Additive pass-through until Task 4 implements connection resolution.
	Specs.

%% comp_item({RuleNode, Deploy}, ChildAttr, TplAttr, AppliedBy) -> item()
%% item() = #{pair, ref, char, mode, min, max, owner, real_tpl}
comp_item({RuleNode, Deploy} = Pair, ChildAttr, _TplAttr, AppliedBy) ->
	{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
	#{pair  => Pair,
	  ref   => content_avp_value(RuleNode, ChildAttr),
	  char  => undefined,
	  mode  => maps:get(mode, Deploy, mandatory),
	  min   => Min,
	  max   => Max,
	  owner => owning_class(RuleNode, AppliedBy),
	  real_tpl => false}.

%% owning_class(RuleNode, AppliedBy) -> integer() | undefined
%% Re-derives the rule's owning class from its applied_by arc (source=Rule,
%% char=applied_by -> target=owning class).  See do_create_rule/7.
owning_class(#node{nref = RuleNref}, AppliedBy) ->
	Arcs = mnesia:dirty_index_read(relationships, RuleNref,
								   #relationship.source_nref),
	case [A#relationship.target_nref || A <- Arcs,
		  A#relationship.characterization =:= AppliedBy] of
		[Owner | _] -> Owner;
		[]          -> undefined
	end.

%% assign_groups(Items, Kind) -> [[item()]]
%% Walks nearest-first; each item joins the first group whose head (anchor =
%% nearest member) it matches, else starts a new group.  Groups preserve
%% nearest-first member order; group list preserves creation order.
assign_groups(Items, Kind) ->
	lists:foldl(fun(Item, Groups) ->
		case find_group(Item, Groups, Kind, 1) of
			{Idx, _G} -> append_to_group(Idx, Item, Groups);
			none      -> Groups ++ [[Item]]
		end
	end, [], Items).

find_group(_Item, [], _Kind, _Idx) ->
	none;
find_group(Item, [G | Rest], Kind, Idx) ->
	case same_conflict(Kind, hd(G), Item) of
		true  -> {Idx, G};
		false -> find_group(Item, Rest, Kind, Idx + 1)
	end.

append_to_group(Idx, Item, Groups) ->
	{Before, [G | After]} = lists:split(Idx - 1, Groups),
	Before ++ [G ++ [Item]] ++ After.

%% same_conflict(Kind, Anchor, Item) -> boolean()
%% The anchor (nearest member) must be same-or-descendant of the candidate.
%% class_in_ancestry(FartherRef, NearerRef): ANCESTOR first, DESCENDANT second
%% (arg-order hazard -- B4 has a canary for the same call).  FartherRef =
%% candidate's ref, NearerRef = anchor's ref.
same_conflict(composition, Anchor, Item) ->
	graphdb_class:class_in_ancestry(maps:get(ref, Item), maps:get(ref, Anchor));
same_conflict(connection, Anchor, Item) ->
	maps:get(char, Anchor) =:= maps:get(char, Item)
		andalso graphdb_class:class_in_ancestry(maps:get(ref, Item),
												maps:get(ref, Anchor)).

%% resolve_group(Group, Kind) -> [Pair]
%% Winner = highest mode-priority among the nearest-level prefix; losers are
%% dropped (their Max merges) unless both winner and loser are real-templated,
%% in which case the loser is re-emitted as an independent propose (B5-D4).
resolve_group(Group, Kind) ->
	OwnerHd = maps:get(owner, hd(Group)),
	%% Nearest-level prefix assumes a distinct owning class per taxonomic
	%% distance (linear chain).  An equidistant multi-parent diamond would
	%% resolve by graphdb_class:ancestors/1 ordering -- see TASKS.md F4 B5
	%% follow-up.
	NearestLevel = lists:takewhile(
		fun(I) -> maps:get(owner, I) =:= OwnerHd end, Group),
	Winner = pick_winner(NearestLevel),
	Losers = Group -- [Winner],
	{Demoted, Dropped} = lists:partition(
		fun(L) -> maps:get(real_tpl, Winner) andalso maps:get(real_tpl, L) end,
		Losers),
	MergedMax = lists:foldl(
		fun(I, Acc) -> merge_max(Acc, maps:get(max, I)) end,
		maps:get(max, Winner), Dropped),
	WinnerOut = rebuild(Winner, Kind, {maps:get(min, Winner), MergedMax},
						keep_mode),
	DemotedOuts = [ rebuild(D, Kind, {maps:get(min, D), maps:get(max, D)},
							propose) || D <- Demoted ],
	[WinnerOut | DemotedOuts].

%% pick_winner([item()]) -> item()
%% Highest mode priority; ties keep the earliest (arc order).
pick_winner([H | T]) ->
	lists:foldl(fun(C, Best) ->
		case priority(maps:get(mode, C)) > priority(maps:get(mode, Best)) of
			true  -> C;
			false -> Best
		end
	end, H, T).

priority(mandatory) -> 3;
priority(auto)      -> 2;
priority(propose)   -> 1;
priority(_)         -> 0.

%% merge_max(MaxA, MaxB) -> Max  (unbounded dominates)
merge_max(unbounded, _) -> unbounded;
merge_max(_, unbounded) -> unbounded;
merge_max(A, B)         -> max(A, B).

%% rebuild(item(), Kind, {Min, Max}, keep_mode | propose) -> Pair
rebuild(Item, composition, Mult, ModeSpec) ->
	{RuleNode, Deploy} = maps:get(pair, Item),
	{RuleNode, set_mode(Deploy#{multiplicity => Mult}, ModeSpec)};
rebuild(Item, connection, Mult, ModeSpec) ->
	{Rule, Deploy, Spec} = maps:get(pair, Item),
	{Rule, set_mode(Deploy#{multiplicity => Mult}, ModeSpec), Spec}.

set_mode(Deploy, keep_mode) -> Deploy;
set_mode(Deploy, propose)   -> Deploy#{mode => propose}.

%% plan_rules(Pairs, OnPath1, State, Resolver, Acc)
%%   -> {ok, PlanNode} | {error, R, Failure}
%% First-failure-aborts: a mandatory violation stops planning.
plan_rules([], _OnPath1, _State, _Resolver, Acc) ->
	{ok, Acc};
plan_rules([{RuleNode, Deploy} | Rest], OnPath1, State, Resolver, Acc) ->
	case maps:get(mode, Deploy, undefined) of
		auto ->
			Autos = maps:get(auto_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Resolver,
					   Acc#{auto_rules => Autos});
		propose ->
			%% Accumulate (composition firing dropped these).  Mirrors the `auto` clause;
			%% graphdb_instance:fire_propose/2 expands multiplicity post-commit
			%% and emits `proposed` outcomes.  Unexpanded here, like auto_rules.
			Proposes = maps:get(propose_rules, Acc) ++ [{RuleNode, Deploy}],
			plan_rules(Rest, OnPath1, State, Resolver,
					   Acc#{propose_rules => Proposes});
		mandatory ->
			case plan_mandatory(RuleNode, Deploy, OnPath1, State, Resolver, Acc) of
				{ok, Acc1}          -> plan_rules(Rest, OnPath1, State, Resolver, Acc1);
				{error, _, _} = Err -> Err                  %% first-failure abort
			end;
		_ ->
			plan_rules(Rest, OnPath1, State, Resolver, Acc)
	end.

%% plan_mandatory(RuleNode, Deploy, OnPath1, State, Resolver, Acc)
%%   -> {ok, Acc'} | {error, Reason, #{plan_so_far, culprit}}
plan_mandatory(RuleNode, Deploy, OnPath1, State, Resolver, Acc) ->
	ChildClass = content_avp_value(RuleNode,
								   State#state.child_class_nref_attr),
	case lists:member(ChildClass, OnPath1) of
		true ->
			{ok, Acc};                  %% zero-level cut: self-nest, no fire
		false ->
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case graphdb_class:is_instantiable(ChildClass) of
				true ->
					expand_children(RuleNode, Deploy, ChildClass, Min, 1,
									OnPath1, State, Resolver, Acc);
				false ->
					fail({class_not_instantiable, ChildClass},
						 RuleNode, Acc);
				{error, Reason} ->
					fail({child_class_invalid, ChildClass, Reason},
						 RuleNode, Acc)
			end
	end.

%% fail(Reason, CulpritRule, Acc) -> {error, Reason, Detail}
fail(Reason, CulpritRule, Acc) ->
	{error, Reason, #{plan_so_far => Acc, culprit => CulpritRule}}.

%% expand_children(RuleNode, Deploy, ChildClass, Mult, I, OnPath1, State,
%%                 Resolver, Acc)
%%   -> {ok, Acc'} | {error, R, Failure}
expand_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _OnPath1, _State,
				_Resolver, Acc) when I > Mult ->
	{ok, Acc};
expand_children(RuleNode, Deploy, ChildClass, Mult, I, OnPath1, State, Resolver,
				Acc) ->
	Name = resolve_child_name(RuleNode, ChildClass, I, Mult, State),
	case plan_node(ChildClass, RuleNode, Deploy, Name, OnPath1, State, Resolver) of
		{ok, ChildPlan} ->
			Kids = maps:get(mandatory_children, Acc) ++ [ChildPlan],
			expand_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OnPath1,
							State, Resolver, Acc#{mandatory_children => Kids});
		{error, R, Failure} ->
			%% Nested failure: rewrite plan_so_far to THIS level's Acc (parent
			%% with completed siblings; failing branch dropped), keep the leaf
			%% culprit.  (composition-firing design §3.1 trace.)
			{error, R, Failure#{plan_so_far => Acc}}
	end.

%% resolve_child_name(RuleNode, ChildClass, I, Mult, State) -> string()
resolve_child_name(RuleNode, ChildClass, I, Mult, State) ->
	resolve_child_name_pub(RuleNode, ChildClass, I, Mult,
						   State#state.name_pattern_attr).

%% resolve_child_name_pub(RuleNode, ChildClass, I, Mult, NamePatternAttr)
%%   -> string()
%% State-free name resolver so graphdb_instance can reuse it post-commit for
%% auto children (via the rule_child_name/4 export below).
resolve_child_name_pub(RuleNode, ChildClass, I, Mult, NamePatternAttr) ->
	case content_avp_lookup(RuleNode, NamePatternAttr) of
		{ok, Pattern} ->
			lists:flatten(string:replace(Pattern, "{i}",
										 integer_to_list(I), all));
		not_found ->
			fallback_name(ChildClass, I, Mult)
	end.

%% fallback_name(ChildClass, I, Mult) -> string()
%% mult=1 -> plain class name; mult>1 -> "ClassName N".
fallback_name(ChildClass, _I, 1) ->
	class_name(ChildClass);
fallback_name(ChildClass, I, _Mult) ->
	class_name(ChildClass) ++ " " ++ integer_to_list(I).

%% class_name(ClassNref) -> string()  (the class-name AVP, or a safe default)
class_name(ClassNref) ->
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case avp_lookup(AVPs, ?NAME_ATTR_CLASS) of
				{ok, N}   -> N;
				not_found -> "instance"
			end;
		_ ->
			"instance"
	end.

%% content_avp_value(RuleNode, AttrNref) -> term() | undefined
content_avp_value(#node{attribute_value_pairs = AVPs}, AttrNref) ->
	case avp_lookup(AVPs, AttrNref) of
		{ok, V}   -> V;
		not_found -> undefined
	end.

%% content_avp_lookup(RuleNode, AttrNref) -> {ok, term()} | not_found
content_avp_lookup(#node{attribute_value_pairs = AVPs}, AttrNref) ->
	avp_lookup(AVPs, AttrNref).

%% avp_lookup(AVPs, AttrNref) -> {ok, Value} | not_found
avp_lookup(AVPs, AttrNref) ->
	case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
		{value, #{value := V}} -> {ok, V};
		false                  -> not_found
	end.
