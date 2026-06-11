%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_instance manages graph node and edge instances.
%%				graphdb_instance is responsible for the creation, storage,
%%				retrieval, and deletion of individual graph nodes and edges.
%%				Graph nodes are identified by Nrefs (globally unique integers)
%%				allocated by the nref application.
%%
%%				Instance nodes live in the Mnesia `nodes` table with
%%				kind=instance.  Each instance has a class (taxonomic
%%				parent via membership arcs 29/30) and a compositional
%%				parent ("part of" via arcs 27/28).  The compositional
%%				parent is stored in the node record's `parent` field
%%				for O(1) tree traversal.
%%
%%				Attribute value inheritance follows four priority levels:
%%				1. Local values (highest)
%%				2. Class-level bound values
%%				3. Compositional ancestors (unbroken chain upward)
%%				4. Directly connected nodes (one level deep; lowest)
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: compositional hierarchy over Mnesia.
%% Provides create_instance/3,4, add_relationship/4, get_instance/1,
%% children/1, compositional_ancestors/1, resolve_value/2.
%%---------------------------------------------------------------------
-module(graphdb_instance).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: April 2026').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
-include_lib("graphdb/include/graphdb_nrefs.hrl").

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
%% Constants
%%---------------------------------------------------------------------
%% Rules live in the shared ontology; project-scoped rules are not yet
%% supported (B1/B2).  Firing always consults environment-scope rules.
-define(RULE_SCOPE, environment).

%%---------------------------------------------------------------------
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() -- primary key
	kind,					%% category | attribute | class | instance | template
	parents = [],			%% [integer()] -- cache of parent arcs (composition/taxonomy)
	classes = [],			%% [integer()] -- cache of instantiation arcs (instances only)
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

-record(state, {
	target_kind_avp_nref,	%% integer() -- nref of the seeded `target_kind`
							%% literal-attribute, cached from graphdb_attr
							%% at init time and used by add_relationship
							%% validation (M3).
	instantiable_nref		%% integer() -- seeded `instantiable` marker (L9)
}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		%% Creators
		create_instance/3,
		create_instance/4,
		add_relationship/4,
		add_relationship/5,
		add_relationship/6,
		add_class_membership/2,
		%% Lookups
		get_instance/1,
		children/1,
		compositional_ancestors/1,
		class_of/1,
		class_memberships/1,
		%% Inheritance
		resolve_value/2
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
%% Test-only exports
%%---------------------------------------------------------------------
-ifdef(TEST).
-export([
		find_avp_value/2,
		add_outcome/4,
		merge_reports/2,
		report_not_attempted/2,
		summarize/1
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_instance(Name, ClassNref, ParentNref) ->
%%     {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%%
%% Creates a new instance node and fires any applicable composition rules.
%% Atomically writes the root + mandatory subtree in one Mnesia transaction.
%% Returns {ok, Nref, Report} on success (Report is [] when no rules apply).
%% Pre-PLAN validation errors return 2-tuple {error, Reason} (no report).
%% Firing errors return 3-tuple {error, Reason, Report}.
%%   - the node record (kind=instance, parent=ParentNref)
%%   - instance→class membership arc pair (char=29/30)
%%   - compositional parent→child arc pair (char=28/27)
%%-----------------------------------------------------------------------------
create_instance(Name, ClassNref, ParentNref) ->
	create_instance(Name, ClassNref, ParentNref, fun report_only/1).

%%-----------------------------------------------------------------------------
%% create_instance(Name, ClassNref, ParentNref, Resolver) ->
%%     {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%%
%% As /3, but threads a connection Resolver (B4).  /3 uses the built-in
%% report_only resolver (defer-all): every connection rule surfaces as a report
%% outcome and nothing is connected.
%%-----------------------------------------------------------------------------
create_instance(Name, ClassNref, ParentNref, Resolver)
		when is_function(Resolver, 1) ->
	gen_server:call(?MODULE,
		{create_instance, Name, ClassNref, ParentNref, Resolver}).

%% report_only(ConnContext) -> defer   (the built-in /3 resolver, B4-D2)
report_only(_Ctx) -> defer.


%%-----------------------------------------------------------------------------
%% add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref) ->
%%     ok | {error, term()}
%%
%% Convenience form: looks up the source instance's class default
%% template and uses it as the Connection arc's template scope.
%% Equivalent to:
%%
%%   add_relationship(S, C, T, R, default_template_of_source_class)
%%
%% Returns {error, no_default_template} if the source's class has had
%% its default template removed; the caller must then use /5 to provide
%% an explicit template.
%%-----------------------------------------------------------------------------
add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref) ->
	gen_server:call(?MODULE,
		{add_relationship, SourceNref, CharNref, TargetNref,
			ReciprocalNref, default, {[], []}}).


%%-----------------------------------------------------------------------------
%% add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
%%                  TemplateNref) -> ok | {error, term()}
%%
%% Writes two directed relationship rows atomically (one per direction)
%% with kind=connection.  The Template AVP (#{attribute => 31, value =>
%% TemplateNref}) is stamped on both rows.
%%
%% Validates that TemplateNref resolves to a node with kind=template
%% whose parent class is in the taxonomic ancestry of the source's
%% class or the target's class.
%%-----------------------------------------------------------------------------
add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref) when is_integer(TemplateNref) ->
	gen_server:call(?MODULE,
		{add_relationship, SourceNref, CharNref, TargetNref,
			ReciprocalNref, TemplateNref, {[], []}}).


%%-----------------------------------------------------------------------------
%% add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
%%                  TemplateNref, {FwdAVPs, RevAVPs}) -> ok | {error, term()}
%%
%% Full form (M5): callers can stamp per-direction metadata AVPs on the
%% two connection rows.  AVPs are asymmetric -- forward and reverse are
%% specified independently, since §5 says metadata such as provenance,
%% confidence, weights, and validity windows is per-direction.
%%
%% The Template AVP (#{attribute => 31, value => TemplateNref}) is
%% prepended to each direction's user-supplied AVP list.
%%-----------------------------------------------------------------------------
add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, {FwdAVPs, RevAVPs} = AVPSpec)
		when is_integer(TemplateNref), is_list(FwdAVPs), is_list(RevAVPs) ->
	gen_server:call(?MODULE,
		{add_relationship, SourceNref, CharNref, TargetNref,
			ReciprocalNref, TemplateNref, AVPSpec}).


%%-----------------------------------------------------------------------------
%% get_instance(Nref) -> {ok, #node{}} | {error, not_found | not_an_instance}
%%-----------------------------------------------------------------------------
get_instance(Nref) ->
	gen_server:call(?MODULE, {get_instance, Nref}).


%%-----------------------------------------------------------------------------
%% children(Nref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct instance-kind children of the given node (uses
%% Mnesia index on parent).
%%-----------------------------------------------------------------------------
children(Nref) ->
	gen_server:call(?MODULE, {children, Nref}).


%%-----------------------------------------------------------------------------
%% compositional_ancestors(Nref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns the ancestor chain of the given instance, starting from its
%% immediate parent up through the compositional hierarchy.  Stops at
%% a non-instance node or the end of the chain.  Returns nearest-first.
%%-----------------------------------------------------------------------------
compositional_ancestors(Nref) ->
	gen_server:call(?MODULE, {compositional_ancestors, Nref}).


%%-----------------------------------------------------------------------------
%% class_of(InstanceNref) ->
%%     {ok, ClassNref} | not_found | {error, term()}
%%
%% Resolves the class membership of an instance via the membership arc
%% (characterization=29).  Returns the class nref, or `not_found` if
%% the instance has no class membership arc.  When an instance belongs
%% to multiple classes (see `class_memberships/1`), returns whichever
%% Mnesia surfaces first; callers needing the full set must use
%% `class_memberships/1`.
%%-----------------------------------------------------------------------------
class_of(InstanceNref) ->
	gen_server:call(?MODULE, {class_of, InstanceNref}).


%%-----------------------------------------------------------------------------
%% class_memberships(InstanceNref) ->
%%     {ok, [ClassNref]} | {error, term()}
%%
%% Returns every class the instance belongs to.  Read from the
%% `node.classes` cache (kept consistent with the 29-characterized
%% outgoing arcs by the cache invariant — see `graphdb_mgr:verify_caches/0`).
%%-----------------------------------------------------------------------------
class_memberships(InstanceNref) ->
	gen_server:call(?MODULE, {class_memberships, InstanceNref}).


%%-----------------------------------------------------------------------------
%% add_class_membership(InstanceNref, ClassNref) -> ok | {error, term()}
%%
%% Adds an additional class membership to an existing instance.
%% Atomically writes a second 29/30 instantiation arc pair AND appends
%% ClassNref to the instance's `classes` cache.  Idempotent: re-adding
%% a class already present returns ok without writing.  Validates that
%% the subject is an instance and the target is a class.
%%-----------------------------------------------------------------------------
add_class_membership(InstanceNref, ClassNref) ->
	gen_server:call(?MODULE,
		{add_class_membership, InstanceNref, ClassNref}).


%%-----------------------------------------------------------------------------
%% resolve_value(InstanceNref, AttrNref) ->
%%     {ok, Value, Source} | not_found | {error, term()}
%%
%% Full inheritance resolution following priority order:
%%   1. Local values (highest)        -> Source = local
%%   2. Class-level bound values      -> Source = {class,         ClassNref}
%%   3. Compositional ancestors       -> Source = {compositional, AncNref}
%%   4. Directly connected nodes      -> Source = {connected,     NodeNref}
%%
%% Source identifies where in the inheritance chain the resolved value
%% was found.  For Priority 2, ClassNref is the class node that actually
%% held the AVP (may be a taxonomy ancestor of one of the instance's
%% direct class memberships).  For Priority 3, AncNref is the
%% compositional-ancestor instance node.  For Priority 4, NodeNref is
%% the directly-connected node (one level deep).
%%-----------------------------------------------------------------------------
resolve_value(InstanceNref, AttrNref) ->
	gen_server:call(?MODULE, {resolve_value, InstanceNref, AttrNref}).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

init([]) ->
	logger:info("graphdb_instance: started"),
	%% Cache the seeded `target_kind` literal-attribute nref from
	%% graphdb_attr.  Used by add_relationship validation (M3) to check
	%% that an arc's target node has the kind declared on the
	%% characterization.  Also cache `instantiable` (L9) to check at
	%% create_instance time that the class is not marked non-instantiable.
	%% graphdb_attr is started before graphdb_instance by graphdb_sup,
	%% so this call is safe at init time.
	{ok, #{target_kind := TkAttr, instantiable := InstAttr}} =
		graphdb_attr:seeded_nrefs(),
	{ok, #state{target_kind_avp_nref = TkAttr,
				instantiable_nref = InstAttr}}.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_instance, Name, ClassNref, ParentNref, Resolver}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	Ctx = #{inst_attr => InstAttr, on_path => [], resolver => Resolver,
			root_parent => ParentNref, root_source => undefined},
	{reply, do_create_instance(Name, ClassNref, ParentNref, Ctx), State};

handle_call({add_relationship, S, C, T, R, TemplateSpec, AVPSpec},
		_From, State) ->
	{reply,
		do_add_relationship(S, C, T, R, TemplateSpec, AVPSpec, State),
		State};

handle_call({add_class_membership, InstanceNref, ClassNref}, _From,
		#state{instantiable_nref = InstAttr} = State) ->
	{reply, do_add_class_membership(InstanceNref, ClassNref, InstAttr),
		State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Lookups
%%-----------------------------------------------------------------------------
handle_call({get_instance, Nref}, _From, State) ->
	{reply, do_get_instance(Nref), State};

handle_call({children, Nref}, _From, State) ->
	{reply, do_children(Nref), State};

handle_call({compositional_ancestors, Nref}, _From, State) ->
	{reply, do_compositional_ancestors(Nref), State};

handle_call({class_of, Nref}, _From, State) ->
	{reply, do_class_of(Nref), State};

handle_call({class_memberships, Nref}, _From, State) ->
	{reply, do_class_memberships(Nref), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Inheritance
%%-----------------------------------------------------------------------------
handle_call({resolve_value, InstNref, AttrNref}, _From, State) ->
	{reply, do_resolve_value(InstNref, AttrNref), State};

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


%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% find_avp_value(AVPs, AttrNref) -> {ok, Value} | not_found
%%
%% Searches an attribute-value pair list for the first entry matching
%% the given attribute nref.  Returns its value or not_found.
%%
%% An entry with value => undefined is treated as not_found — it is a
%% schema declaration (QC declared but unbound at this level), not a
%% resolved value.
%%-----------------------------------------------------------------------------
find_avp_value([], _AttrNref) ->
	not_found;
find_avp_value([#{attribute := A, value := V} | _], A) when V =/= undefined ->
	{ok, V};
find_avp_value([#{attribute := A} | _], A) ->
	%% value is undefined — QC declaration only, not a bound value.
	%% Stopping here is correct: AVP lists have no duplicate attribute keys
	%% (enforced by do_add_qc's idempotency guard), so no further match exists.
	not_found;
find_avp_value([_ | Rest], AttrNref) ->
	find_avp_value(Rest, AttrNref).


%%-----------------------------------------------------------------------------
%% do_create_instance(Name, ClassNref, ParentNref, Ctx)
%%     -> {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%%
%% The unifying internal entry (B2-D2): every cascade level flows through
%% here, never the gen_server API (that would deadlock).  Ctx carries
%% inst_attr, on_path (the class path for the on-path cycle guard), resolver,
%% and the stable root_parent / root_source anchors (B4-D2a).  Validates the
%% class (must be kind=class and instantiable) and parent (must exist);
%% pre-PLAN errors return a 2-tuple {error, Reason} (no report).  Post-PLAN
%% paths return 3-tuples.
%%-----------------------------------------------------------------------------
do_create_instance(Name, ClassNref, ParentNref, Ctx) ->
	InstAttr = maps:get(inst_attr, Ctx),
	case do_validate_class(ClassNref, InstAttr) of
		ok ->
			case do_validate_parent(ParentNref) of
				ok ->
					fire_create(Name, ClassNref, ParentNref, Ctx);
				{error, _} = Err ->
					Err            %% pre-PLAN root error: 2-tuple (no report)
			end;
		{error, _} = Err ->
			Err                    %% pre-PLAN root error: 2-tuple (no report)
	end.

%%-----------------------------------------------------------------------------
%% fire_create(Name, ClassNref, ParentNref, Ctx)
%%     -> {ok, Nref, report()} | {error, Reason, report()}
%%
%% PLAN → EXECUTE → POST-COMMIT (B2-D1/D2/D3).  Calls graphdb_rules for the
%% abstract plan tree, then executes the mandatory subtree atomically, then
%% fires auto children best-effort post-commit.
%%-----------------------------------------------------------------------------
fire_create(Name, ClassNref, ParentNref, Ctx) ->
	case graphdb_rules:plan_composition_firing(?RULE_SCOPE, ClassNref) of
		{ok, PlanTree} ->
			case execute(Name, ClassNref, ParentNref, Ctx, PlanTree) of
				{ok, RootNref, MandOutcomes, InstPlan, AutoConnPlan} ->
					Ctx1 = bind_root_source(Ctx, RootNref),
					AutoReport     = fire_auto(InstPlan, Ctx1),
					ProposeReport  = fire_propose(InstPlan,
									 maps:get(on_path, Ctx1)),
					ConnAutoReport = fire_connections(AutoConnPlan),
					Merged = merge_reports(
						merge_reports(
							merge_reports(MandOutcomes, AutoReport),
							ProposeReport),
						ConnAutoReport),
					{ok, RootNref, Merged};
				{error, R, Report} ->
					{error, R, Report}
			end;
		{error, R, Failure} ->
			{error, R, report_not_attempted(R, Failure)}
	end.

%%-----------------------------------------------------------------------------
%% bind_root_source(Ctx, RootNref) -> Ctx'
%%
%% At the top level root_source is undefined -> bind it to the freshly
%% allocated root nref; for a threaded descendant it is already set and
%% kept unchanged (B4-D2a).
%%-----------------------------------------------------------------------------
bind_root_source(Ctx, RootNref) ->
	case maps:get(root_source, Ctx) of
		undefined -> Ctx#{root_source => RootNref};
		_         -> Ctx
	end.

%%-----------------------------------------------------------------------------
%% execute(RootName, RootClass, RootParent, Ctx, PlanTree)
%%     -> {ok, RootNref, MandOutcomes, InstPlan, AutoConnPlan}
%%      | {error, Reason, report()}
%%
%% Allocates every node's nrefs/ids OUTSIDE the transaction, RESOLVEs the
%% connection rules for the mandatory subtree (B4), then writes the root, the
%% whole mandatory composition subtree, and any committed mandatory connection
%% rows in ONE Mnesia transaction.  Returns the InstPlan plus the AutoConnPlan
%% (the post-commit auto-connection write list — empty in this task).
%%-----------------------------------------------------------------------------
execute(RootName, _RootClass, RootParent, Ctx, PlanTree) ->
	%% Annotate the plan tree with allocated nrefs (root uses caller's Name).
	InstPlan = allocate_plan(PlanTree#{name => RootName}),
	{Writes, CompOutcomes} = plan_writes(InstPlan, RootParent),
	RootNref = maps:get(nref, InstPlan),
	Ctx1 = bind_root_source(Ctx, RootNref),
	case resolve_connections(InstPlan, Ctx1) of
		{ok, MandRows, AutoConnPlan, ConnReport} ->
			Txn = fun() ->
				lists:foreach(
					fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					Writes ++ MandRows)
			end,
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
		{error, Reason, ConnReport} ->
			%% Mandatory-connection shortfall in RESOLVE: nothing written (we
			%% never entered the txn).  Composition subtree becomes
			%% not_attempted; the connection culprit/siblings are in ConnReport.
			CompNA = report_not_attempted(Reason,
				#{plan_so_far => InstPlan, culprit => undefined}),
			{error, Reason, merge_reports(CompNA, ConnReport)}
	end.

%%=============================================================================
%% Connection Firing -- RESOLVE (B4)
%%=============================================================================

%%-----------------------------------------------------------------------------
%% resolve_connections(InstPlan, Ctx)
%%   -> {ok, MandRows, AutoConnPlan, ConnReport}
%%    | {error, Reason, ConnReport}
%%
%% Walks the instantiated plan tree (root + mandatory composition descendants)
%% pre-order; for each instance consults its effective connection rules.  In this
%% task only the defer/propose branches are implemented (no writes); later tasks
%% add the {connect, List} mandatory/auto branches.
%%-----------------------------------------------------------------------------
resolve_connections(InstPlan, Ctx) ->
	Nodes = flatten_plan(InstPlan),
	resolve_nodes(Nodes, Ctx, {[], [], []}).

%% flatten_plan(InstPlanNode) -> [{Nref, ClassNref}]  (root first, pre-order)
flatten_plan(#{nref := N, class := C, mandatory_children := Kids}) ->
	[{N, C} | lists:flatmap(fun flatten_plan/1, Kids)].

%% resolve_nodes(Nodes, Ctx, {MandRows, AutoPlan, Report})
%% Rows/Auto/Report all accumulate in forward order (the connect branches
%% append), so no reversal is needed; Mnesia write order within the txn is
%% irrelevant.
resolve_nodes([], _Ctx, {Rows, Auto, Rep}) ->
	{ok, Rows, Auto, Rep};
resolve_nodes([{SourceNref, Class} | Rest], Ctx, Acc) ->
	{ok, ConnRules} =
		graphdb_rules:effective_connection_rules(?RULE_SCOPE, Class),
	case resolve_rules(ConnRules, SourceNref, Ctx, Acc) of
		{ok, Acc1}          -> resolve_nodes(Rest, Ctx, Acc1);
		{error, _, _} = Err -> Err
	end.

%% resolve_rules(Rules, SourceNref, Ctx, Acc) -> {ok, Acc'} | {error, R, Report}
%% Acc = {MandRows, AutoPlan, Report}.  First-failure-aborts (mirrors plan_rules).
resolve_rules([], _SourceNref, _Ctx, Acc) ->
	{ok, Acc};
resolve_rules([{Rule, Deploy, Spec} | Rest], SourceNref, Ctx, Acc) ->
	Mode = maps:get(mode, Deploy, mandatory),
	case Mode of
		propose ->
			%% propose connection rules are advisory: surface `proposed`, never
			%% consult the resolver, never connect (mirrors B3 propose).
			Acc1 = add_conn_outcome(Acc, Rule, Deploy,
				conn_outcome_base(SourceNref, Spec, proposed)),
			resolve_rules(Rest, SourceNref, Ctx, Acc1);
		_ ->
			Resolver = maps:get(resolver, Ctx),
			case Resolver(conn_context(Rule, Deploy, Spec, SourceNref, Ctx)) of
				defer ->
					Status = case Mode of
								 mandatory -> required;
								 auto      -> not_connected
							 end,
					Acc1 = add_conn_outcome(Acc, Rule, Deploy,
						conn_outcome_base(SourceNref, Spec, Status)),
					resolve_rules(Rest, SourceNref, Ctx, Acc1);
				{connect, List} ->
					connect_targets(Mode, List, Rule, Deploy, Spec, SourceNref,
									Rest, Ctx, Acc)
			end
	end.

%%-----------------------------------------------------------------------------
%% connect_targets(Mode, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx, Acc)
%%   -> {ok, Acc'} | {error, Reason, Report}
%%
%% Validates the resolver-returned targets, applies the {Min, Max} range, and
%% routes by mode.  In B4 Task 5 only `mandatory` is implemented (validate +
%% abort, build root-txn rows, tentative `connected` outcomes); `auto` is added
%% in a later task.
%%-----------------------------------------------------------------------------
connect_targets(mandatory, List, Rule, Deploy, Spec, SourceNref, Rest, Ctx,
		{Rows, Auto, Rep}) ->
	TClass = maps:get(target_class, Spec),
	case partition_targets(List, TClass, SourceNref) of
		{error, Reason} ->
			%% an invalid target on a committed mandatory rule aborts the create
			{error, {invalid_connection_target, Reason},
			 conn_fail({invalid_connection_target, Reason}, Rule, Spec, Rep)};
		{ok, Valid} ->
			{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case length(Valid) < Min of
				true ->
					Reason = {mandatory_connection_unsatisfied, Rule#node.nref},
					{error, Reason, conn_fail(Reason, Rule, Spec, Rep)};
				false ->
					ToWrite = cap(Valid, Max),
					Template = maps:get(template, Deploy),
					{NewRows, NewOuts} =
						mandatory_rows(ToWrite, SourceNref, Spec, Template),
					Rep1 = lists:foldl(
						fun(O, R) -> add_outcome(R, Rule, Deploy, O) end,
						Rep, NewOuts),
					resolve_rules(Rest, SourceNref, Ctx,
								  {Rows ++ NewRows, Auto, Rep1})
			end
	end.

%% partition_targets(List, TargetClass, SourceNref) -> {ok, [Target]} | {error, R}
%% For a MANDATORY rule: the first invalid target aborts with its reason; an
%% all-valid list returns the (order-preserved) valid targets.
partition_targets([], _TClass, _SourceNref) ->
	{ok, []};
partition_targets([T | Rest], TClass, SourceNref) ->
	case validate_target(T, TClass, SourceNref) of
		ok ->
			case partition_targets(Rest, TClass, SourceNref) of
				{ok, Vs}         -> {ok, [T | Vs]};
				{error, _} = Err -> Err
			end;
		{error, Reason} ->
			{error, Reason}
	end.

%% cap(List, Max) -> List'  (truncate to at most Max; unbounded keeps all)
cap(List, unbounded) -> List;
cap(List, Max)       -> lists:sublist(List, Max).

%% mandatory_rows(Targets, SourceNref, Spec, Template) -> {Rows, Outcomes}
%% Builds the connection rows for each target plus a (tentative) `connected`
%% outcome indexed 1..N.  Outcomes are returned to the report only on commit.
mandatory_rows(Targets, SourceNref, Spec, Template) ->
	Char   = maps:get(characterization, Spec),
	Recip  = maps:get(reciprocal, Spec),
	TClass = maps:get(target_class, Spec),
	{Rows, Outs, _} = lists:foldl(
		fun(T, {RAcc, OAcc, I}) ->
			TNref = target_nref(T),
			Rows0 = build_connection_rows(SourceNref, Char, TNref, Recip,
										  Template, target_avps(T)),
			Out = #{source => SourceNref, index => I, status => connected,
					target => TNref, characterization => Char,
					target_class => TClass},
			{RAcc ++ Rows0, OAcc ++ [Out], I + 1}
		end, {[], [], 1}, Targets),
	{Rows, Outs}.

%% conn_fail(Reason, CulpritRule, Spec, RepAcc) -> Report
%% Mandatory-connection abort report: every already-emitted connection outcome
%% becomes not_attempted; the culprit gets one `failed` carrying its connection
%% keys (so the rollback cause is discriminable by rule kind, B4-D7).
conn_fail(Reason, CulpritRule, Spec, RepAcc) ->
	NA = [ RR#{outcomes => [#{index => 1, status => not_attempted}
							|| _ <- Os]}
		   || #{outcomes := Os} = RR <- RepAcc ],
	add_outcome(NA, CulpritRule, #{},
		#{index => 1, status => failed, reason => Reason,
		  characterization => maps:get(characterization, Spec),
		  target_class => maps:get(target_class, Spec)}).

%%-----------------------------------------------------------------------------
%% validate_target(Target, TargetClass, SourceNref) -> ok | {error, Reason}
%%
%% Target is a bare nref or {Nref, {Fwd, Rev}}.  Valid iff the nref exists, is a
%% kind=instance node, and is an instance of TargetClass or a subclass of it.
%% No self-check is needed: the source is uncommitted at RESOLVE, so a readable
%% instance is necessarily distinct from it (B4-D6).
%%-----------------------------------------------------------------------------
validate_target(Target, TargetClass, _SourceNref) ->
	Nref = target_nref(Target),
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = instance, classes = Classes}] ->
			case lists:any(
					fun(C) -> graphdb_class:class_in_ancestry(TargetClass, C) end,
					Classes) of
				true  -> ok;
				false -> {error, {target_class_mismatch, Nref, TargetClass}}
			end;
		[#node{}] -> {error, {target_not_an_instance, Nref}};
		[]        -> {error, {target_not_found, Nref}}
	end.

%% target_nref(Target) -> integer()
target_nref(Nref) when is_integer(Nref)             -> Nref;
target_nref({Nref, {_F, _R}}) when is_integer(Nref) -> Nref.

%% target_avps(Target) -> {FwdAVPs, RevAVPs}
target_avps(Nref) when is_integer(Nref) -> {[], []};
target_avps({_Nref, {Fwd, Rev}})        -> {Fwd, Rev}.

%% conn_context(Rule, Deploy, Spec, SourceNref, Ctx) -> ConnContext (B4-D2/D2a)
conn_context(Rule, Deploy, Spec, SourceNref, Ctx) ->
	#{rule             => Rule,
	  characterization => maps:get(characterization, Spec),
	  reciprocal       => maps:get(reciprocal, Spec),
	  target_class     => maps:get(target_class, Spec),
	  mode             => maps:get(mode, Deploy, mandatory),
	  multiplicity     => maps:get(multiplicity, Deploy, {1, 1}),
	  source           => SourceNref,
	  root_parent      => maps:get(root_parent, Ctx),
	  root_source      => maps:get(root_source, Ctx)}.

%% conn_outcome_base(SourceNref, Spec, Status) -> connection_outcome()
%% The shared shape for non-connect outcomes (required/not_connected/proposed):
%% index 1, no target.
conn_outcome_base(SourceNref, Spec, Status) ->
	#{source => SourceNref, index => 1, status => Status,
	  characterization => maps:get(characterization, Spec),
	  target_class => maps:get(target_class, Spec)}.

%% add_conn_outcome({Rows, Auto, Rep}, Rule, Deploy, Outcome) -> Acc'
add_conn_outcome({Rows, Auto, Rep}, Rule, Deploy, Outcome) ->
	{Rows, Auto, add_outcome(Rep, Rule, Deploy, Outcome)}.

%%-----------------------------------------------------------------------------
%% fire_connections(AutoConnPlan) -> report()
%%
%% POST-COMMIT best-effort writer for `auto` connections (B4).  Empty until a
%% later B4 task; an empty plan yields an empty report.
%%-----------------------------------------------------------------------------
fire_connections([]) ->
	[].

%%-----------------------------------------------------------------------------
%% allocate_plan(PlanNode) -> InstPlanNode (same tree + nref per node)
%%
%% Depth-first pre-order walk: allocates one nref per node OUTSIDE the
%% Mnesia transaction.
%%-----------------------------------------------------------------------------
allocate_plan(#{mandatory_children := Kids} = Node) ->
	Nref = graphdb_nref:get_next(),
	Node#{nref => Nref,
		  mandatory_children => [allocate_plan(K) || K <- Kids]}.

%%-----------------------------------------------------------------------------
%% plan_writes(InstPlan, RootParent) -> {Writes, Outcomes}
%%
%% Pre-order DFS over the instantiated plan tree.  The root emits only its
%% own five records.  Each mandated descendant emits its records plus one
%% `fired` outcome under its rule, indexed 1..N within that rule.
%%-----------------------------------------------------------------------------
plan_writes(#{nref := RootNref, class := Class, name := Name,
			  mandatory_children := Kids}, RootParent) ->
	Acc0 = {instance_records(RootNref, Class, Name, RootParent), []},
	write_children(Kids, RootNref, Acc0).

%%-----------------------------------------------------------------------------
%% write_children(Siblings, OwnerNref, {Writes, Outcomes}) -> {Writes, Outcomes}
%%
%% Numbers siblings within their mandating rule (1-based), emits each
%% child's records + fired outcome (with real `deploy` map), then recurses
%% into the child's own mandatory children.
%%-----------------------------------------------------------------------------
write_children(Siblings, OwnerNref, Acc) ->
	{_Counts, Result} =
		lists:foldl(
			fun(#{nref := CNref, class := CClass, name := CName,
				  rule := Rule, deploy := Deploy,
				  mandatory_children := GKids}, {Counts, {W, O}}) ->
				Idx = maps:get(rule_key(Rule), Counts, 0) + 1,
				W1 = W ++ instance_records(CNref, CClass, CName, OwnerNref),
				O1 = add_outcome(O, Rule, Deploy,
						#{owner => OwnerNref, index => Idx,
						  status => fired, child => CNref}),
				{W2, O2} = write_children(GKids, CNref, {W1, O1}),
				{Counts#{rule_key(Rule) => Idx}, {W2, O2}}
			end, {#{}, Acc}, Siblings),
	Result.

rule_key(#node{nref = N}) -> N.

%%-----------------------------------------------------------------------------
%% instance_records(Nref, ClassNref, Name, ParentNref) -> [{Tab, Rec}]
%%
%% Builds the five Mnesia records for one instance node.  Rel-IDs are
%% allocated here (outside the transaction by the allocate_plan caller
%% chain; this function is called from plan_writes/write_children which
%% are invoked in execute/5 before the transaction).
%%-----------------------------------------------------------------------------
instance_records(Nref, ClassNref, Name, ParentNref) ->
	{MembId1, MembId2} = rel_id_server:get_id_pair(),
	{CompId1, CompId2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	Node = #node{nref = Nref, kind = instance, parents = [ParentNref],
				 classes = [ClassNref], attribute_value_pairs = [NameAVP]},
	%% Instance -> Class (char=29, reciprocal=30)
	I2C = #relationship{id = MembId1, kind = instantiation, source_nref = Nref,
		characterization = ?ARC_INST_TO_CLASS, target_nref = ClassNref,
		reciprocal = ?ARC_CLASS_TO_INST, avps = []},
	%% Class -> Instance (char=30, reciprocal=29)
	C2I = #relationship{id = MembId2, kind = instantiation,
		source_nref = ClassNref, characterization = ?ARC_CLASS_TO_INST,
		target_nref = Nref, reciprocal = ?ARC_INST_TO_CLASS, avps = []},
	%% Parent -> Child (char=28, reciprocal=27)
	P2C = #relationship{id = CompId1, kind = composition,
		source_nref = ParentNref, characterization = ?ARC_INST_CHILD,
		target_nref = Nref, reciprocal = ?ARC_INST_PARENT, avps = []},
	%% Child -> Parent (char=27, reciprocal=28)
	C2P = #relationship{id = CompId2, kind = composition, source_nref = Nref,
		characterization = ?ARC_INST_PARENT, target_nref = ParentNref,
		reciprocal = ?ARC_INST_CHILD, avps = []},
	[{nodes, Node}, {relationships, I2C}, {relationships, C2I},
	 {relationships, P2C}, {relationships, C2P}].

%%-----------------------------------------------------------------------------
%% fire_auto(InstPlan, Ctx) -> report()
%%
%% POST-COMMIT best-effort auto firing.  Walks the instantiated plan tree and
%% fires each node's auto rules by recursing do_create_instance/4 (never the
%% gen_server API — self-call deadlock).  Pushes the node's class onto Ctx's
%% on_path as the walk descends.  Merges sub-reports additively.  Failures are
%% recorded in the report but do not abort the root instance.
%%-----------------------------------------------------------------------------
fire_auto(#{nref := Nref, class := Class, auto_rules := Autos,
			mandatory_children := Kids}, Ctx) ->
	Ctx1 = push_on_path(Ctx, Class),
	Here = lists:foldl(
		fun({RuleNode, Deploy}, Acc) ->
			fire_one_auto(RuleNode, Deploy, Nref, Ctx1, Acc)
		end, [], Autos),
	lists:foldl(
		fun(Child, Acc) -> merge_reports(Acc, fire_auto(Child, Ctx1)) end,
		Here, Kids).

%%-----------------------------------------------------------------------------
%% push_on_path(Ctx, ClassNref) -> Ctx' with ClassNref prepended to on_path
%%-----------------------------------------------------------------------------
push_on_path(Ctx, ClassNref) ->
	Ctx#{on_path => [ClassNref | maps:get(on_path, Ctx)]}.

%%-----------------------------------------------------------------------------
%% fire_one_auto(RuleNode, Deploy, OwnerNref, Ctx, Acc) -> report()
%%
%% Check order: instantiable, then the vertical-cycle cut, then expansion.
%% mints Min children post-commit (B-prep).  Ctx's on_path already carries the
%% owner's class (pushed by fire_auto).
%%-----------------------------------------------------------------------------
fire_one_auto(RuleNode, Deploy, OwnerNref, Ctx, Acc) ->
	ChildClass = graphdb_rules:rule_child_class(RuleNode),
	case graphdb_class:is_instantiable(ChildClass) of
		false ->
			add_outcome(Acc, RuleNode, Deploy,
				#{owner => OwnerNref, index => 1, status => failed,
				  reason => {class_not_instantiable, ChildClass}});
		_ ->        %% true (or {error,_} -> treated as fireable; create reports)
			{Min, _Max} = maps:get(multiplicity, Deploy, {1, 1}),
			case lists:member(ChildClass, maps:get(on_path, Ctx)) of
				true  -> Acc;       %% vertical cycle cut (B2-D5)
				false -> fire_auto_children(RuleNode, Deploy, ChildClass,
									Min, 1, OwnerNref, Ctx, Acc)
			end
	end.

%%-----------------------------------------------------------------------------
%% fire_auto_children — expand multiplicity, recursing do_create_instance/4.
%%
%% Ctx is threaded UNCHANGED: the owner's class is already on Ctx's on_path
%% (pushed by fire_auto); the child's own do_create_instance -> fire_create ->
%% fire_auto pushes the child's class.  Do not push it twice.
%%-----------------------------------------------------------------------------
fire_auto_children(_RuleNode, _Deploy, _ChildClass, Mult, I, _Owner, _Ctx,
				   Acc) when I > Mult ->
	Acc;
fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I, OwnerNref, Ctx,
				   Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Mult),
	Acc2 = case do_create_instance(Name, ChildClass, OwnerNref, Ctx) of
		{ok, ChildNref, SubReport} ->
			A1 = add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => fired,
					  child => ChildNref}),
			merge_reports(A1, SubReport);
		{error, R, SubReport} ->
			A1 = add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => failed,
					  reason => R}),
			merge_reports(A1, SubReport);
		{error, R} ->        %% pre-PLAN 2-tuple (bad class/parent)
			add_outcome(Acc, RuleNode, Deploy,
					#{owner => OwnerNref, index => I, status => failed,
					  reason => R})
	end,
	fire_auto_children(RuleNode, Deploy, ChildClass, Mult, I + 1, OwnerNref,
					   Ctx, Acc2).

%%-----------------------------------------------------------------------------
%% fire_propose(InstPlan, OnPath) -> report()
%%
%% POST-COMMIT, side-effect-free (B3).  Walks the instantiated plan tree
%% (root + mandatory descendants) and surfaces each node's propose_rules as
%% `proposed` outcomes.  Materialises NOTHING — a proposal is a suggestion the
%% caller may accept by calling create_instance/3 for the proposed_class
%% itself (which then fires that child's own rules).  Auto children are not in
%% InstPlan; their propose rules surface via their own do_create_instance
%% sub-report.  Mirrors fire_auto/2's traversal.
%%
%% B3 OI-B3-5 (shallow): no recursion into proposed children — nothing is
%% created, so there is nothing to recurse into.  A future propose-with-options
%% feature may supersede this.
%%-----------------------------------------------------------------------------
fire_propose(#{nref := Nref, class := Class, propose_rules := Props,
			   mandatory_children := Kids}, OnPath) ->
	OnPath1 = [Class | OnPath],
	Here = lists:foldl(
		fun({RuleNode, Deploy}, Acc) ->
			fire_one_propose(RuleNode, Deploy, Nref, OnPath1, Acc)
		end, [], Props),
	lists:foldl(
		fun(Child, Acc) -> merge_reports(Acc, fire_propose(Child, OnPath1)) end,
		Here, Kids).

%%-----------------------------------------------------------------------------
%% fire_one_propose(RuleNode, Deploy, OwnerNref, OnPath1, Acc) -> report()
%%
%% Emits `proposed` outcome(s) for one propose rule.  No instantiability
%% guard (B3 design §3.2): a proposal creates nothing, so an abstract target
%% cannot break anything; the caller validates on accept.
%%-----------------------------------------------------------------------------
fire_one_propose(RuleNode, Deploy, OwnerNref, OnPath1, Acc) ->
	ChildClass = graphdb_rules:rule_child_class(RuleNode),
	%% B3 OI-B3-2: on-path cycle cut — do not propose a class already on the
	%% root->here path (mirrors B2-D5).  Supersedable by propose-with-options.
	case lists:member(ChildClass, OnPath1) of
		true ->
			Acc;
		false ->
			%% B-prep: propose surfaces Min proposed outcomes, each carrying
			%% max => Max so the report keeps the open-ended ceiling (Max may
			%% be `unbounded').  Generalises the old index=unbounded sentinel.
			{Min, Max} = maps:get(multiplicity, Deploy, {1, 1}),
			propose_children(RuleNode, Deploy, ChildClass, Min, Max, 1,
							 OwnerNref, Acc)
	end.

%%-----------------------------------------------------------------------------
%% propose_children(RuleNode, Deploy, ChildClass, Count, Max, I, OwnerNref, Acc)
%%   -> report()
%% Emits one `proposed' outcome per index 1..Count (Count = Min), each carrying
%% max => Max (Max may be `unbounded').
%%-----------------------------------------------------------------------------
propose_children(_RuleNode, _Deploy, _ChildClass, Count, _Max, I, _OwnerNref, Acc)
		when I > Count ->
	Acc;
propose_children(RuleNode, Deploy, ChildClass, Count, Max, I, OwnerNref, Acc) ->
	Name = graphdb_rules:rule_child_name(RuleNode, ChildClass, I, Count),
	Acc1 = add_outcome(Acc, RuleNode, Deploy,
		#{owner => OwnerNref, index => I, status => proposed,
		  proposed_class => ChildClass, name => Name, max => Max}),
	propose_children(RuleNode, Deploy, ChildClass, Count, Max, I + 1, OwnerNref,
					 Acc1).


%%-----------------------------------------------------------------------------
%% do_validate_class(ClassNref, InstAttr) -> ok | {error, term()}
%%
%% Validates that ClassNref is an existing kind=class node and is not
%% marked non-instantiable (instantiable => false AVP under InstAttr).
%% Absence of the marker is permissive — only classes explicitly stamped
%% with `instantiable => false` are blocked.
%%-----------------------------------------------------------------------------
do_validate_class(ClassNref, InstAttr) ->
	case mnesia:dirty_read(nodes, ClassNref) of
		[#node{kind = class, attribute_value_pairs = AVPs}] ->
			case is_marked_non_instantiable(AVPs, InstAttr) of
				true  -> {error, {class_not_instantiable, ClassNref}};
				false -> ok
			end;
		[#node{kind = Kind}] -> {error, {not_a_class, Kind}};
		[]                   -> {error, class_not_found}
	end.

%% is_marked_non_instantiable(AVPs, InstAttr) -> boolean()
%%
%% Returns true only when the AVP list contains an entry
%% #{attribute => InstAttr, value => false}.  Absence = permissive.
%% The duplication of this helper in graphdb_class is intentional — the
%% two workers do not share a module, and L9 deliberately does NOT
%% introduce a shared util module for one small predicate (YAGNI).
is_marked_non_instantiable(AVPs, InstAttr) ->
	lists:any(fun
		(#{attribute := A, value := false}) when A =:= InstAttr -> true;
		(_) -> false
	end, AVPs).


%%-----------------------------------------------------------------------------
%% do_validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Validates that ParentNref references an existing node.
%%-----------------------------------------------------------------------------
do_validate_parent(ParentNref) ->
	case mnesia:dirty_read(nodes, ParentNref) of
		[_Node] -> ok;
		[]      -> {error, parent_not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
%%                     TemplateSpec, State) -> ok | {error, term()}
%%
%% TemplateSpec is either the atom `default` (look up source's class
%% default template) or an integer template nref.  M3 validation
%% (existence + arc-label kind + target_kind agreement) runs first,
%% then class lookup, template resolution, scope check, and the
%% two-row write of the connection arcs with the Template AVP stamped
%% on each.
%%-----------------------------------------------------------------------------
do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateSpec, AVPSpec, State) ->
	TkAttr = State#state.target_kind_avp_nref,
	case validate_arc_endpoints(SourceNref, CharNref, TargetNref,
			ReciprocalNref, TkAttr) of
		ok ->
			case resolve_arc_classes(SourceNref, TargetNref) of
				{ok, SourceClass, TargetClass} ->
					case resolve_template(TemplateSpec, SourceClass) of
						{ok, TemplateNref} ->
							case validate_template_scope(TemplateNref,
									SourceClass, TargetClass) of
								ok ->
									write_connection_arcs(SourceNref,
										CharNref, TargetNref,
										ReciprocalNref, TemplateNref,
										AVPSpec);
								{error, _} = Err -> Err
							end;
						{error, _} = Err -> Err
					end;
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% validate_arc_endpoints(Source, Char, Target, Reciprocal, TkAttr) ->
%%     ok | {error, term()}
%%
%% M3 validation.  Reads all four nodes inside one mnesia transaction
%% and rejects:
%%   - missing source / target / characterization / reciprocal
%%   - characterization or reciprocal that is not kind=attribute
%%   - target whose kind disagrees with the characterization's
%%     `target_kind` AVP (the value stored under attribute=TkAttr)
%%-----------------------------------------------------------------------------
validate_arc_endpoints(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TkAttr) ->
	F = fun() ->
		Source = mnesia:read(nodes, SourceNref),
		Target = mnesia:read(nodes, TargetNref),
		Char   = mnesia:read(nodes, CharNref),
		Recip  = mnesia:read(nodes, ReciprocalNref),
		{Source, Target, Char, Recip}
	end,
	case mnesia:transaction(F) of
		{atomic, {[], _, _, _}} ->
			{error, {source_not_found, SourceNref}};
		{atomic, {_, [], _, _}} ->
			{error, {target_not_found, TargetNref}};
		{atomic, {_, _, [], _}} ->
			{error, {characterization_not_found, CharNref}};
		{atomic, {_, _, _, []}} ->
			{error, {reciprocal_not_found, ReciprocalNref}};
		{atomic, {[_], [#node{kind = TKind}], [#node{kind = CKind} = CharNode],
				[#node{kind = RKind}]}} ->
			case {CKind, RKind} of
				{attribute, attribute} ->
					check_target_kind(CharNode, TKind, TkAttr);
				{attribute, _} ->
					{error, {reciprocal_not_an_attribute, ReciprocalNref,
						RKind}};
				{_, _} ->
					{error, {characterization_not_an_attribute, CharNref,
						CKind}}
			end;
		{aborted, Reason} ->
			{error, Reason}
	end.

check_target_kind(#node{attribute_value_pairs = AVPs}, ActualKind, TkAttr) ->
	case find_avp_value(AVPs, TkAttr) of
		not_found ->
			%% No target_kind AVP on the arc-label -- legacy or relationship-
			%% type bucket node; skip the kind check.
			ok;
		{ok, ActualKind} ->
			ok;
		{ok, ExpectedKind} ->
			{error, {target_kind_mismatch, ExpectedKind, ActualKind}}
	end.


%%-----------------------------------------------------------------------------
%% resolve_arc_classes(SourceNref, TargetNref) ->
%%     {ok, SourceClass, TargetClass} | {error, term()}
%%-----------------------------------------------------------------------------
resolve_arc_classes(SourceNref, TargetNref) ->
	case do_class_of(SourceNref) of
		{ok, SourceClass} ->
			case do_class_of(TargetNref) of
				{ok, TargetClass}  -> {ok, SourceClass, TargetClass};
				not_found          -> {error, {target_has_no_class, TargetNref}};
				{error, _} = Err   -> Err
			end;
		not_found            -> {error, {source_has_no_class, SourceNref}};
		{error, _} = Err     -> Err
	end.


%%-----------------------------------------------------------------------------
%% resolve_template(TemplateSpec, SourceClass) ->
%%     {ok, TemplateNref} | {error, term()}
%%-----------------------------------------------------------------------------
resolve_template(default, SourceClass) ->
	case graphdb_class:default_template(SourceClass) of
		{ok, Nref}        -> {ok, Nref};
		not_found         -> {error, no_default_template};
		{error, _} = Err  -> Err
	end;
resolve_template(TemplateNref, _SourceClass) when is_integer(TemplateNref) ->
	{ok, TemplateNref}.


%%-----------------------------------------------------------------------------
%% validate_template_scope(TemplateNref, SourceClass, TargetClass) ->
%%     ok | {error, term()}
%%
%% Confirms TemplateNref resolves to a kind=template node whose parent
%% class is in SourceClass's or TargetClass's taxonomic ancestry.
%%-----------------------------------------------------------------------------
validate_template_scope(TemplateNref, SourceClass, TargetClass) ->
	case graphdb_class:get_template(TemplateNref) of
		{ok, #node{parents = TmplParents}} ->
			TmplClass = head_parent(TmplParents),
			InSource = graphdb_class:class_in_ancestry(TmplClass, SourceClass),
			InTarget = graphdb_class:class_in_ancestry(TmplClass, TargetClass),
			case InSource orelse InTarget of
				true  -> ok;
				false -> {error, {template_class_not_in_ancestry,
					TemplateNref, TmplClass, SourceClass, TargetClass}}
			end;
		{error, Reason} ->
			{error, {invalid_template, TemplateNref, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% build_connection_rows(S, C, T, R, TemplateNref, {FwdAVPs, RevAVPs})
%%   -> [{relationships, #relationship{}}]
%%
%% Builds the two directed connection rows (Template AVP at index 0).  Rel-ids
%% are allocated here, OUTSIDE any transaction (L10).  No write -- the caller
%% decides which transaction the rows land in (B4 mandatory connections ride the
%% composition root txn; auto connections are written post-commit).
%%-----------------------------------------------------------------------------
build_connection_rows(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, {FwdAVPs, RevAVPs}) ->
	{Id1, Id2} = rel_id_server:get_id_pair(),
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

%% write_connection_arcs(S, C, T, R, TemplateNref, {FwdAVPs, RevAVPs}) ->
%%     ok | {error, term()}
%%
%% Builds the two connection rows and writes them in their OWN transaction.
%% Used by add_relationship/4,5,6 and by the post-commit auto-connection pass.
%%-----------------------------------------------------------------------------
write_connection_arcs(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	Rows = build_connection_rows(SourceNref, CharNref, TargetNref,
								 ReciprocalNref, TemplateNref, AVPSpec),
	Txn = fun() ->
		lists:foreach(fun({Tab, Rec}) -> ok = mnesia:write(Tab, Rec, write) end,
					  Rows)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_add_class_membership(InstanceNref, ClassNref, InstAttr) ->
%%     ok | {error, term()}
%%
%% Validates the subject (must be an instance) and the target (must be
%% a class and instantiable), then atomically writes the 29/30 arc pair
%% and appends ClassNref to the instance's classes cache.  Idempotent.
%%-----------------------------------------------------------------------------
do_add_class_membership(InstanceNref, ClassNref, InstAttr) ->
	case do_get_instance(InstanceNref) of
		{ok, _} ->
			case do_validate_class(ClassNref, InstAttr) of
				ok               -> do_write_class_membership(InstanceNref,
									ClassNref);
				{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.

do_write_class_membership(InstanceNref, ClassNref) ->
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Txn = fun() ->
		[#node{kind = instance, classes = Classes} = Node] =
			mnesia:read(nodes, InstanceNref),
		case lists:member(ClassNref, Classes) of
			true ->
				already_exists;
			false ->
				I2C = #relationship{
					id = Id1, kind = instantiation,
					source_nref = InstanceNref,
					characterization = ?ARC_INST_TO_CLASS,
					target_nref = ClassNref,
					reciprocal = ?ARC_CLASS_TO_INST,
					avps = []
				},
				C2I = #relationship{
					id = Id2, kind = instantiation,
					source_nref = ClassNref,
					characterization = ?ARC_CLASS_TO_INST,
					target_nref = InstanceNref,
					reciprocal = ?ARC_INST_TO_CLASS,
					avps = []
				},
				Updated = Node#node{classes = Classes ++ [ClassNref]},
				ok = mnesia:write(nodes, Updated, write),
				ok = mnesia:write(relationships, I2C, write),
				ok = mnesia:write(relationships, C2I, write),
				ok
		end
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{aborted, Reason}        -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_class_memberships(InstanceNref) ->
%%     {ok, [ClassNref]} | {error, term()}
%%
%% Reads the instance's `classes` cache (authoritative-equivalent to the
%% 29-characterized outgoing arcs by the cache invariant).
%%-----------------------------------------------------------------------------
do_class_memberships(InstanceNref) ->
	case do_get_instance(InstanceNref) of
		{ok, #node{classes = Classes}} -> {ok, Classes};
		{error, _} = Err               -> Err
	end.


%%-----------------------------------------------------------------------------
%% do_class_of(InstanceNref) ->
%%     {ok, ClassNref} | not_found | {error, term()}
%%-----------------------------------------------------------------------------
do_class_of(InstanceNref) ->
	F = fun() ->
		Rels = mnesia:index_read(relationships, InstanceNref,
			#relationship.source_nref),
		lists:search(
			fun(R) ->
				R#relationship.characterization =:= ?ARC_INST_TO_CLASS
			end, Rels)
	end,
	case mnesia:transaction(F) of
		{atomic, {value, #relationship{target_nref = ClassNref}}} ->
			{ok, ClassNref};
		{atomic, false}   -> not_found;
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_get_instance(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_an_instance | term()}
%%-----------------------------------------------------------------------------
do_get_instance(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = instance} = Node] -> {ok, Node};
		[_Other]                        -> {error, not_an_instance};
		[]                              -> {error, not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_children(Nref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct instance-kind children of the given node.
%%-----------------------------------------------------------------------------
do_children(Nref) ->
	F = fun() ->
		Children = downward_children_by_arc(Nref, ?ARC_INST_CHILD,
			composition),
		[N || N <- Children, N#node.kind =:= instance]
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_compositional_ancestors(Nref) -> {ok, [#node{}]} | {error, term()}
%%
%% Walks the parent chain from the instance's parent.  Collects only
%% instance-kind ancestors.  Stops at a non-instance node or missing
%% node.  Returns nearest-first order.
%%-----------------------------------------------------------------------------
do_compositional_ancestors(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = instance, parents = Parents}] ->
			do_walk_ancestors(head_parent(Parents), []);
		[_] ->
			{error, not_an_instance};
		[] ->
			{error, not_found}
	end.

do_walk_ancestors(undefined, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors(Nref, Acc) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{kind = instance, parents = Parents} = Node] ->
			do_walk_ancestors(head_parent(Parents), [Node | Acc]);
		[_] ->
			%% Hit a non-instance node (e.g., category anchor) — stop
			{ok, lists:reverse(Acc)};
		[] ->
			{ok, lists:reverse(Acc)}
	end.


%%=============================================================================
%% Inheritance Resolution
%%=============================================================================

%%-----------------------------------------------------------------------------
%% do_resolve_value(InstNref, AttrNref) ->
%%     {ok, Value, Source} | not_found | {error, term()}
%%
%% Full four-level inheritance resolution.  Source identifies the
%% priority level where the value was found:
%%   - `local`                  (Priority 1)
%%   - `{class,         Nref}`  (Priority 2, the class node that held it)
%%   - `{compositional, Nref}`  (Priority 3, the ancestor instance)
%%   - `{connected,     Nref}`  (Priority 4, the directly-connected node)
%%-----------------------------------------------------------------------------
do_resolve_value(InstNref, AttrNref) ->
	case do_get_instance(InstNref) of
		{ok, Node} ->
			%% Priority 1: Local values
			case find_avp_value(Node#node.attribute_value_pairs, AttrNref) of
				{ok, V} ->
					{ok, V, local};
				not_found ->
					%% Priority 2: Class-level bound values
					case resolve_from_class(InstNref, AttrNref) of
						{ok, V, ClassNref} ->
							{ok, V, {class, ClassNref}};
						not_found ->
							%% Priority 3: Compositional ancestors
							case resolve_from_ancestors(
									head_parent(Node#node.parents),
									AttrNref) of
								{ok, V, AncNref} ->
									{ok, V, {compositional, AncNref}};
								not_found ->
									%% Priority 4: Directly connected nodes
									case resolve_from_connected(
										InstNref, AttrNref) of
										{ok, V, ConnNref} ->
											{ok, V, {connected, ConnNref}};
										not_found ->
											not_found
									end;
								{error, _} = Err ->
									Err
							end;
						{error, _} = Err ->
							Err
					end
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% resolve_from_class(InstNref, AttrNref) ->
%%     {ok, Value, ClassNref} | not_found |
%%     {error, {ambiguous_class_value, AttrNref, [{ClassNref, Value}]}}
%%
%% Reads every class membership and, for each one, walks the class node
%% plus its taxonomy ancestors (nearest-first) for an AVP match.
%%
%% - 0 hits across all memberships -> not_found (caller falls through
%%   to Priority 3).
%% - All hits agree on a single distinct value -> {ok, Value, ClassNref}.
%%   ClassNref is the class node where the value was actually found (may
%%   be a taxonomy ancestor of one of the instance's direct class
%%   memberships).  When multiple memberships yield the same value, the
%%   first hit's class is reported.
%% - Two or more distinct values -> {error, {ambiguous_class_value,
%%   AttrNref, [{ClassNref, Value}]}}, where ClassNref is the class
%%   where the value was actually found.
%%-----------------------------------------------------------------------------
resolve_from_class(InstNref, AttrNref) ->
	case do_class_memberships(InstNref) of
		{ok, []} ->
			not_found;
		{ok, Classes} ->
			Hits = collect_class_hits(Classes, AttrNref),
			classify_class_hits(Hits, AttrNref);
		_ ->
			not_found
	end.

collect_class_hits(Classes, AttrNref) ->
	lists:foldr(
		fun(ClassNref, Acc) ->
			case search_class_taxonomy(ClassNref, AttrNref) of
				{ok, FoundClass, Value} -> [{FoundClass, Value} | Acc];
				not_found               -> Acc
			end
		end, [], Classes).

classify_class_hits([], _AttrNref) ->
	not_found;
classify_class_hits([{ClassNref, Value}], _AttrNref) ->
	{ok, Value, ClassNref};
classify_class_hits([{ClassNref, _} | _] = Hits, AttrNref) ->
	case lists:usort([V || {_, V} <- Hits]) of
		[Value] -> {ok, Value, ClassNref};
		_       -> {error, {ambiguous_class_value, AttrNref, Hits}}
	end.

%% Walks ClassNref and its taxonomy ancestors (nearest-first), returning
%% the first AVP match together with the class nref where it was found.
search_class_taxonomy(ClassNref, AttrNref) ->
	case graphdb_class:get_class(ClassNref) of
		{ok, #node{attribute_value_pairs = AVPs}} ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V} ->
					{ok, ClassNref, V};
				not_found ->
					case graphdb_class:ancestors(ClassNref) of
						{ok, Ancestors} ->
							search_first_in_ancestors(Ancestors, AttrNref);
						_ ->
							not_found
					end
			end;
		_ ->
			not_found
	end.

search_first_in_ancestors([], _AttrNref) ->
	not_found;
search_first_in_ancestors(
		[#node{nref = N, attribute_value_pairs = AVPs} | Rest], AttrNref) ->
	case find_avp_value(AVPs, AttrNref) of
		{ok, V}   -> {ok, N, V};
		not_found -> search_first_in_ancestors(Rest, AttrNref)
	end.


%%-----------------------------------------------------------------------------
%% resolve_from_ancestors(ParentNref, AttrNref) ->
%%     {ok, Value, AncestorNref} | not_found | {error, term()}
%%
%% Walks up the compositional parent chain, checking each instance
%% ancestor's AVPs.  Stops at a non-instance or missing node.  When a
%% match is found, returns the nref of the ancestor instance that held
%% the value.
%%-----------------------------------------------------------------------------
resolve_from_ancestors(undefined, _AttrNref) ->
	not_found;
resolve_from_ancestors(ParentNref, AttrNref) ->
	case mnesia:dirty_read(nodes, ParentNref) of
		[#node{kind = instance, parents = GrandParents,
				attribute_value_pairs = AVPs}] ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V}   -> {ok, V, ParentNref};
				not_found -> resolve_from_ancestors(
								head_parent(GrandParents), AttrNref)
			end;
		[_] ->
			not_found;
		[] ->
			not_found
	end.


%%-----------------------------------------------------------------------------
%% head_parent(Parents) -> integer() | undefined
%%
%% Returns the first parent in the cache list, or `undefined` for root
%% nodes (empty parents list).  Used by single-chain ancestor walks; H3
%% will introduce multi-parent walks that traverse the full list.
%%-----------------------------------------------------------------------------
head_parent([])      -> undefined;
head_parent([P | _]) -> P.


%%-----------------------------------------------------------------------------
%% downward_children_by_arc(ParentNref, ChildArc, RelKind) -> [#node{}]
%%
%% Replaces the retired #node.parent secondary index.  Reads outgoing
%% arcs from ParentNref of the given Kind/characterization and
%% dereferences each target nref to a node record.  Must run inside an
%% active mnesia transaction.
%%-----------------------------------------------------------------------------
downward_children_by_arc(ParentNref, ChildArc, RelKind) ->
	Arcs = mnesia:index_read(relationships, ParentNref,
		#relationship.source_nref),
	Nrefs = [A#relationship.target_nref || A <- Arcs,
		A#relationship.kind =:= RelKind,
		A#relationship.characterization =:= ChildArc],
	lists:flatmap(fun(N) -> mnesia:read(nodes, N) end, Nrefs).


%%-----------------------------------------------------------------------------
%% resolve_from_connected(InstNref, AttrNref) ->
%%     {ok, Value, NodeNref} | not_found
%%
%% Checks all directly connected nodes (one level deep).  Only
%% kind=connection arcs are considered; instantiation (membership) and
%% composition (parent/child) arcs are excluded — those targets are
%% already covered by Priorities 2 and 3.  Returns the nref of the
%% connected node that held the AVP; the caller wraps it as
%% {connected, NodeNref} for the Source tag.
%%-----------------------------------------------------------------------------
resolve_from_connected(InstNref, AttrNref) ->
	F = fun() ->
		mnesia:index_read(relationships, InstNref,
			#relationship.source_nref)
	end,
	case mnesia:transaction(F) of
		{atomic, Rels} ->
			TargetNrefs = lists:usort(
				[R#relationship.target_nref
					|| R <- Rels, R#relationship.kind =:= connection]),
			search_targets(TargetNrefs, AttrNref);
		{aborted, _} ->
			not_found
	end.


%%-----------------------------------------------------------------------------
%% search_targets(Nrefs, AttrNref) ->
%%     {ok, Value, NodeNref} | not_found
%%
%% Checks each target node's AVPs for the attribute.  Returns the
%% first match together with the nref of the node that held the value.
%%-----------------------------------------------------------------------------
search_targets([], _AttrNref) ->
	not_found;
search_targets([Nref | Rest], AttrNref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[#node{attribute_value_pairs = AVPs}] ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, V}   -> {ok, V, Nref};
				not_found -> search_targets(Rest, AttrNref)
			end;
		_ ->
			search_targets(Rest, AttrNref)
	end.


%%=============================================================================
%% Firing Report Helpers (B2-D6)
%%=============================================================================

%% summarize/1 is exported in TEST builds and available for external callers
%% but not referenced in non-TEST production paths — suppress the warning.
-compile({nowarn_unused_function, [summarize/1]}).

%%-----------------------------------------------------------------------------
%% add_outcome(Report, RuleNode, Deployment, Outcome) -> Report'
%%
%% Appends Outcome under RuleNode's rule_report (preserving rule order),
%% creating the rule_report if this rule is not yet present.
%%-----------------------------------------------------------------------------
add_outcome(Report, #node{nref = RuleNref} = RuleNode, Deployment, Outcome) ->
	case lists:any(fun(#{rule := RN}) ->
						RN#node.nref =:= RuleNref end, Report) of
		true ->
			[ append_if(RR, RuleNref, Outcome) || RR <- Report ];
		false ->
			Report ++ [#{rule => RuleNode, deployment => Deployment,
						 outcomes => [Outcome]}]
	end.

append_if(#{rule := RN, outcomes := Os} = RR, RuleNref, Outcome) ->
	case RN#node.nref =:= RuleNref of
		true  -> RR#{outcomes => Os ++ [Outcome]};
		false -> RR
	end.


%%-----------------------------------------------------------------------------
%% merge_reports(R1, R2) -> Report   (union by rule nref)
%%-----------------------------------------------------------------------------
merge_reports(R1, R2) ->
	lists:foldl(
		fun(#{rule := RuleNode, deployment := Dep, outcomes := Outs}, Acc) ->
			lists:foldl(
				fun(O, A) -> add_outcome(A, RuleNode, Dep, O) end, Acc, Outs)
		end, R1, R2).


%%-----------------------------------------------------------------------------
%% report_not_attempted(Reason, Failure) -> Report
%%
%% Failure = #{plan_so_far => PlanNode, culprit => #node{} | undefined}.
%% Every mandated child in plan_so_far becomes a not_attempted outcome under
%% its mandating rule; the culprit (if any) becomes one failed outcome.
%%-----------------------------------------------------------------------------
report_not_attempted(Reason, #{plan_so_far := Plan, culprit := Culprit}) ->
	Base = walk_not_attempted(Plan, []),
	case Culprit of
		undefined ->
			Base;
		#node{} ->
			Dep = #{},      %% deployment not carried on the error path
			add_outcome(Base, Culprit, Dep,
						#{index => 1, status => failed, reason => Reason})
	end.

walk_not_attempted(#{mandatory_children := Kids}, Acc0) ->
	lists:foldl(
		fun(#{rule := Rule} = Child, Acc) ->
			Acc1 = add_outcome(Acc, Rule, #{},
								#{index => 1, status => not_attempted}),
			walk_not_attempted(Child, Acc1)         %% recurse deeper
		end, Acc0, Kids).


%%-----------------------------------------------------------------------------
%% summarize(Report) -> #{fired => N, failed => M, not_attempted => K,
%%                        proposed => P, connected => C, required => Rq,
%%                        not_connected => Nc}
%%-----------------------------------------------------------------------------
summarize(Report) ->
	Outs = [O || #{outcomes := Os} <- Report, O <- Os],
	Count = fun(S) -> length([1 || #{status := X} <- Outs, X =:= S]) end,
	#{fired => Count(fired), failed => Count(failed),
	  not_attempted => Count(not_attempted), proposed => Count(proposed),
	  connected => Count(connected), required => Count(required),
	  not_connected => Count(not_connected)}.
