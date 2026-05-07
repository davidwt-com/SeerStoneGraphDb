%%---------------------------------------------------------------------
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of
%% SeerStone, Inc.
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
%% Provides create_instance/3, add_relationship/4, get_instance/1,
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
%% Bootstrap nref constants
%%---------------------------------------------------------------------
%% NameAttrNref for instance-kind nodes.
-define(NAME_ATTR_FOR_INSTANCE, 20).

%% Compositional arc labels for instance children of instance parents.
-define(INST_CHILD_ARC,  28).  %% Child/InstRel  -- parent -> child
-define(INST_PARENT_ARC, 27).  %% Parent/InstRel -- child  -> parent

%% Instance-to-class membership arc labels.
-define(CLASS_MEMBERSHIP_ARC,    29).  %% instance -> class
-define(INSTANCE_MEMBERSHIP_ARC, 30).  %% class -> instance

%% Bootstrap-seeded `Template` relationship-AVP marker attribute (nref 31).
%% Required on every Connection arc; its value is the nref of the template
%% node defining the semantic context for the connection.
-define(TEMPLATE_AVP_NREF, 31).


%%---------------------------------------------------------------------
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() -- primary key
	kind,					%% category | attribute | class | instance | template
	parent,					%% integer() | undefined (undefined = root only)
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
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		%% Creators
		create_instance/3,
		add_relationship/4,
		add_relationship/5,
		%% Lookups
		get_instance/1,
		children/1,
		compositional_ancestors/1,
		class_of/1,
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
		find_avp_value/2
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_instance(Name, ClassNref, ParentNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Creates a new instance node.  Atomically writes:
%%   - the node record (kind=instance, parent=ParentNref)
%%   - instance→class membership arc pair (char=29/30)
%%   - compositional parent→child arc pair (char=28/27)
%%-----------------------------------------------------------------------------
create_instance(Name, ClassNref, ParentNref) ->
	gen_server:call(?MODULE, {create_instance, Name, ClassNref, ParentNref}).


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
			ReciprocalNref, default}).


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
			ReciprocalNref, TemplateNref}).


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
%% the instance has no class membership arc.
%%-----------------------------------------------------------------------------
class_of(InstanceNref) ->
	gen_server:call(?MODULE, {class_of, InstanceNref}).


%%-----------------------------------------------------------------------------
%% resolve_value(InstanceNref, AttrNref) ->
%%     {ok, Value} | not_found | {error, term()}
%%
%% Full inheritance resolution following priority order:
%%   1. Local values (highest)
%%   2. Class-level bound values
%%   3. Compositional ancestors (unbroken chain upward)
%%   4. Directly connected nodes (one level deep; lowest)
%%-----------------------------------------------------------------------------
resolve_value(InstanceNref, AttrNref) ->
	gen_server:call(?MODULE, {resolve_value, InstanceNref, AttrNref}).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

init([]) ->
	logger:info("graphdb_instance: started"),
	{ok, []}.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_instance, Name, ClassNref, ParentNref}, _From, State) ->
	{reply, do_create_instance(Name, ClassNref, ParentNref), State};

handle_call({add_relationship, S, C, T, R, TemplateSpec}, _From, State) ->
	{reply, do_add_relationship(S, C, T, R, TemplateSpec), State};

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
%%-----------------------------------------------------------------------------
find_avp_value(AVPs, AttrNref) ->
	case lists:search(
		fun(#{attribute := A}) -> A =:= AttrNref; (_) -> false end,
		AVPs)
	of
		{value, #{value := V}} -> {ok, V};
		false                  -> not_found
	end.


%%-----------------------------------------------------------------------------
%% do_create_instance(Name, ClassNref, ParentNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Validates the class (must be kind=class) and parent (must exist),
%% allocates nrefs outside the Mnesia transaction, then atomically
%% writes the node record, membership arcs, and compositional arcs.
%%-----------------------------------------------------------------------------
do_create_instance(Name, ClassNref, ParentNref) ->
	case do_validate_class(ClassNref) of
		ok ->
			case do_validate_parent(ParentNref) of
				ok ->
					do_write_instance(Name, ClassNref, ParentNref);
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.

do_write_instance(Name, ClassNref, ParentNref) ->
	%% Allocate all nrefs OUTSIDE the Mnesia transaction
	Nref = nref_server:get_nref(),
	MembId1 = nref_server:get_nref(),
	MembId2 = nref_server:get_nref(),
	CompId1 = nref_server:get_nref(),
	CompId2 = nref_server:get_nref(),
	NameAVP = #{attribute => ?NAME_ATTR_FOR_INSTANCE, value => Name},
	Node = #node{
		nref = Nref,
		kind = instance,
		parent = ParentNref,
		attribute_value_pairs = [NameAVP]
	},
	%% Instance -> Class (char=29, reciprocal=30)
	I2C = #relationship{
		id = MembId1,
		kind = instantiation,
		source_nref = Nref,
		characterization = ?CLASS_MEMBERSHIP_ARC,
		target_nref = ClassNref,
		reciprocal = ?INSTANCE_MEMBERSHIP_ARC,
		avps = []
	},
	%% Class -> Instance (char=30, reciprocal=29)
	C2I = #relationship{
		id = MembId2,
		kind = instantiation,
		source_nref = ClassNref,
		characterization = ?INSTANCE_MEMBERSHIP_ARC,
		target_nref = Nref,
		reciprocal = ?CLASS_MEMBERSHIP_ARC,
		avps = []
	},
	%% Parent -> Child (char=28, reciprocal=27)
	P2C = #relationship{
		id = CompId1,
		kind = composition,
		source_nref = ParentNref,
		characterization = ?INST_CHILD_ARC,
		target_nref = Nref,
		reciprocal = ?INST_PARENT_ARC,
		avps = []
	},
	%% Child -> Parent (char=27, reciprocal=28)
	C2P = #relationship{
		id = CompId2,
		kind = composition,
		source_nref = Nref,
		characterization = ?INST_PARENT_ARC,
		target_nref = ParentNref,
		reciprocal = ?INST_CHILD_ARC,
		avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, I2C, write),
		ok = mnesia:write(relationships, C2I, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, Nref};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_validate_class(ClassNref) -> ok | {error, term()}
%%-----------------------------------------------------------------------------
do_validate_class(ClassNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, ClassNref) end) of
		{atomic, [#node{kind = class}]} -> ok;
		{atomic, [#node{kind = Kind}]}  -> {error, {not_a_class, Kind}};
		{atomic, []}                    -> {error, class_not_found};
		{aborted, Reason}               -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Validates that ParentNref references an existing node.
%%-----------------------------------------------------------------------------
do_validate_parent(ParentNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, ParentNref) end) of
		{atomic, [_Node]} -> ok;
		{atomic, []}      -> {error, parent_not_found};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
%%                     TemplateSpec) -> ok | {error, term()}
%%
%% TemplateSpec is either the atom `default` (look up source's class
%% default template) or an integer template nref.  Validates the
%% template's class is in the source's or target's class taxonomic
%% ancestry, then atomically writes the two directed connection rows
%% with the Template AVP stamped on each.
%%-----------------------------------------------------------------------------
do_add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateSpec) ->
	case resolve_arc_classes(SourceNref, TargetNref) of
		{ok, SourceClass, TargetClass} ->
			case resolve_template(TemplateSpec, SourceClass) of
				{ok, TemplateNref} ->
					case validate_template_scope(TemplateNref,
							SourceClass, TargetClass) of
						ok ->
							write_connection_arcs(SourceNref, CharNref,
								TargetNref, ReciprocalNref, TemplateNref);
						{error, _} = Err -> Err
					end;
				{error, _} = Err -> Err
			end;
		{error, _} = Err -> Err
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
		{ok, #node{parent = TmplClass}} ->
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
%% write_connection_arcs(S, C, T, R, TemplateNref) -> ok | {error, term()}
%%-----------------------------------------------------------------------------
write_connection_arcs(SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref) ->
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	TemplateAVP = #{attribute => ?TEMPLATE_AVP_NREF, value => TemplateNref},
	Fwd = #relationship{
		id = Id1, kind = connection,
		source_nref = SourceNref,
		characterization = CharNref,
		target_nref = TargetNref,
		reciprocal = ReciprocalNref,
		avps = [TemplateAVP]
	},
	Rev = #relationship{
		id = Id2, kind = connection,
		source_nref = TargetNref,
		characterization = ReciprocalNref,
		target_nref = SourceNref,
		reciprocal = CharNref,
		avps = [TemplateAVP]
	},
	Txn = fun() ->
		ok = mnesia:write(relationships, Fwd, write),
		ok = mnesia:write(relationships, Rev, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
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
				R#relationship.characterization =:= ?CLASS_MEMBERSHIP_ARC
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
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = instance} = Node]} -> {ok, Node};
		{atomic, [_Other]}                        -> {error, not_an_instance};
		{atomic, []}                              -> {error, not_found};
		{aborted, Reason}                         -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_children(Nref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct instance-kind children of the given node.
%%-----------------------------------------------------------------------------
do_children(Nref) ->
	F = fun() ->
		Children = mnesia:index_read(nodes, Nref, #node.parent),
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
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = instance, parent = Parent}]} ->
			do_walk_ancestors(Parent, []);
		{atomic, [_]} ->
			{error, not_an_instance};
		{atomic, []} ->
			{error, not_found};
		{aborted, Reason} ->
			{error, Reason}
	end.

do_walk_ancestors(undefined, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors(Nref, Acc) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = instance, parent = Parent} = Node]} ->
			do_walk_ancestors(Parent, [Node | Acc]);
		{atomic, [_]} ->
			%% Hit a non-instance node (e.g., category anchor) — stop
			{ok, lists:reverse(Acc)};
		{atomic, []} ->
			{ok, lists:reverse(Acc)};
		{aborted, Reason} ->
			{error, Reason}
	end.


%%=============================================================================
%% Inheritance Resolution
%%=============================================================================

%%-----------------------------------------------------------------------------
%% do_resolve_value(InstNref, AttrNref) ->
%%     {ok, Value} | not_found | {error, term()}
%%
%% Full four-level inheritance resolution.
%%-----------------------------------------------------------------------------
do_resolve_value(InstNref, AttrNref) ->
	case do_get_instance(InstNref) of
		{ok, Node} ->
			%% Priority 1: Local values
			case find_avp_value(Node#node.attribute_value_pairs, AttrNref) of
				{ok, _} = Found ->
					Found;
				not_found ->
					%% Priority 2: Class-level bound values
					case resolve_from_class(InstNref, AttrNref) of
						{ok, _} = Found ->
							Found;
						not_found ->
							%% Priority 3: Compositional ancestors
							case resolve_from_ancestors(
									Node#node.parent, AttrNref) of
								{ok, _} = Found ->
									Found;
								not_found ->
									%% Priority 4: Directly connected nodes
									resolve_from_connected(
										InstNref, AttrNref);
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
%%     {ok, Value} | not_found
%%
%% Finds the instance's class via the membership arc (char=29), then
%% searches the class node and every taxonomy ancestor (nearest-first)
%% for an AVP matching AttrNref.  Returns the first match.
%%-----------------------------------------------------------------------------
resolve_from_class(InstNref, AttrNref) ->
	case do_class_of(InstNref) of
		{ok, ClassNref} ->
			search_class_chain(ClassNref, AttrNref);
		_ ->
			not_found
	end.

search_class_chain(ClassNref, AttrNref) ->
	case graphdb_class:get_class(ClassNref) of
		{ok, ClassNode} ->
			case find_avp_value(ClassNode#node.attribute_value_pairs,
					AttrNref) of
				{ok, _} = Found ->
					Found;
				not_found ->
					search_taxonomy_ancestors(ClassNref, AttrNref)
			end;
		_ ->
			not_found
	end.

search_taxonomy_ancestors(ClassNref, AttrNref) ->
	case graphdb_class:ancestors(ClassNref) of
		{ok, Ancestors} ->
			search_avp_chain(Ancestors, AttrNref);
		_ ->
			not_found
	end.

search_avp_chain([], _AttrNref) ->
	not_found;
search_avp_chain([#node{attribute_value_pairs = AVPs} | Rest], AttrNref) ->
	case find_avp_value(AVPs, AttrNref) of
		{ok, _} = Found -> Found;
		not_found       -> search_avp_chain(Rest, AttrNref)
	end.


%%-----------------------------------------------------------------------------
%% resolve_from_ancestors(ParentNref, AttrNref) ->
%%     {ok, Value} | not_found | {error, term()}
%%
%% Walks up the compositional parent chain, checking each instance
%% ancestor's AVPs.  Stops at a non-instance or missing node.
%%-----------------------------------------------------------------------------
resolve_from_ancestors(undefined, _AttrNref) ->
	not_found;
resolve_from_ancestors(ParentNref, AttrNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, ParentNref) end) of
		{atomic, [#node{kind = instance, parent = GrandParent,
				attribute_value_pairs = AVPs}]} ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, _} = Found -> Found;
				not_found       -> resolve_from_ancestors(GrandParent, AttrNref)
			end;
		{atomic, [_]} ->
			not_found;
		{atomic, []} ->
			not_found;
		{aborted, Reason} ->
			{error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% resolve_from_connected(InstNref, AttrNref) ->
%%     {ok, Value} | not_found
%%
%% Checks all directly connected nodes (one level deep).  Only
%% kind=connection arcs are considered; instantiation (membership) and
%% composition (parent/child) arcs are excluded — those targets are
%% already covered by Priorities 2 and 3.
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
%% search_targets(Nrefs, AttrNref) -> {ok, Value} | not_found
%%
%% Checks each target node's AVPs for the attribute.  Returns the
%% first match.
%%-----------------------------------------------------------------------------
search_targets([], _AttrNref) ->
	not_found;
search_targets([Nref | Rest], AttrNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{attribute_value_pairs = AVPs}]} ->
			case find_avp_value(AVPs, AttrNref) of
				{ok, _} = Found -> Found;
				not_found       -> search_targets(Rest, AttrNref)
			end;
		_ ->
			search_targets(Rest, AttrNref)
	end.
