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
%% Description: graphdb_attr manages the environment attribute library.
%%				Creates and retrieves name attributes, literal
%%				attributes, relationship attributes (arc labels), and
%%				relationship-type groupings.  Attribute nodes live in
%%				the Mnesia `nodes` table with kind=attribute and a
%%				compositional parent in the attribute library tree.
%%
%%				On first startup, graphdb_attr seeds three runtime
%%				literal attributes under the `Literals` subtree (nref
%%				7): `literal_type`, `target_kind`, and
%%				`relationship_avp`.  Subsequent startups detect the
%%				existing seeds by name and cache their nrefs in the
%%				gen_server state.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: attribute library over Mnesia.  Provides
%% create_name_attribute/1, create_literal_attribute/2,
%% create_relationship_attribute/3, create_relationship_type/1,
%% get_attribute/1, list_attributes/0, list_relationship_types/0.
%% Seeds literal_type, target_kind, and relationship_avp at init.
%%---------------------------------------------------------------------
-module(graphdb_attr).
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
%% Parents in the attribute library tree.
-define(PARENT_NAMES,         6).  %% Names subtree
-define(PARENT_LITERALS,      7).  %% Literals subtree
-define(PARENT_RELATIONSHIPS, 8).  %% Relationships subtree

%% NameAttrNref for attribute-kind nodes (self-ref in bootstrap).
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).

%% Compositional arc labels for attribute children of attribute parents
%% (self-referential arc labels 23 and 24 from bootstrap).
-define(ATTR_CHILD_ARC,  24).  %% Child/AttrRel  -- parent -> child
-define(ATTR_PARENT_ARC, 23).  %% Parent/AttrRel -- child  -> parent


%%---------------------------------------------------------------------
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() -- primary key
	kind,					%% category | attribute | class | instance
	parent,					%% integer() | undefined (undefined = root only)
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() -- primary key
	source_nref,			%% integer() -- arc origin
	characterization,		%% integer() -- arc label (an attribute nref)
	target_nref,			%% integer() -- arc target
	reciprocal,				%% integer() -- arc label as seen from target back
	avps					%% [#{attribute => Nref, value => term()}]
}).

-record(state, {
	literal_type_nref,		%% integer() -- seeded literal attribute
	target_kind_nref,		%% integer() -- seeded literal attribute
	relationship_avp_nref	%% integer() -- seeded literal attribute
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
		create_name_attribute/1,
		create_literal_attribute/2,
		create_relationship_attribute/3,
		create_relationship_type/1,
		%% Lookups
		get_attribute/1,
		list_attributes/0,
		list_relationship_types/0,
		%% Seeded nref accessors
		seeded_nrefs/0
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
		valid_target_kind/1,
		find_attribute_by_name/2
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_name_attribute(Name) -> {ok, Nref} | {error, term()}
%%
%% Creates a new name attribute node under the `Names` subtree (nref 6).
%% A name attribute is an attribute-kind node whose value is a human-
%% readable name.
%%-----------------------------------------------------------------------------
create_name_attribute(Name) ->
	gen_server:call(?MODULE, {create_name_attribute, Name}).


%%-----------------------------------------------------------------------------
%% create_literal_attribute(Name, Type) -> {ok, Nref} | {error, term()}
%%
%% Creates a new literal attribute node under the `Literals` subtree
%% (nref 7).  The Type argument is stored as an AVP keyed by the
%% seeded `literal_type` attribute.
%%-----------------------------------------------------------------------------
create_literal_attribute(Name, Type) ->
	gen_server:call(?MODULE, {create_literal_attribute, Name, Type}).


%%-----------------------------------------------------------------------------
%% create_relationship_attribute(Name, ReciprocalName, TargetKind) ->
%%     {ok, {Nref, ReciprocalNref}} | {error, term()}
%%
%% Creates a reciprocal pair of arc label attribute nodes under the
%% `Relationships` subtree (nref 8).  TargetKind is one of
%% category | attribute | class | instance and is stored as an AVP
%% keyed by the seeded `target_kind` attribute on both nodes.  The
%% query engine uses this annotation to route target lookups between
%% the ontology and project (instance space).
%%-----------------------------------------------------------------------------
create_relationship_attribute(Name, ReciprocalName, TargetKind) ->
	case valid_target_kind(TargetKind) of
		true ->
			gen_server:call(?MODULE,
				{create_relationship_attribute, Name, ReciprocalName, TargetKind});
		false ->
			{error, {invalid_target_kind, TargetKind}}
	end.


%%-----------------------------------------------------------------------------
%% create_relationship_type(Name) -> {ok, Nref} | {error, term()}
%%
%% Creates a relationship-type grouping node as a direct child of the
%% `Relationships` subtree (nref 8).  Subsequent arc labels may be
%% placed under this grouping by a future /2 variant.
%%-----------------------------------------------------------------------------
create_relationship_type(Name) ->
	gen_server:call(?MODULE, {create_relationship_type, Name}).


%%-----------------------------------------------------------------------------
%% get_attribute(Nref) -> {ok, #node{}} | {error, not_found | term()}
%%
%% Returns the attribute node identified by Nref.  Only nodes of
%% kind=attribute are returned; any other kind yields
%% {error, not_an_attribute}.
%%-----------------------------------------------------------------------------
get_attribute(Nref) ->
	gen_server:call(?MODULE, {get_attribute, Nref}).


%%-----------------------------------------------------------------------------
%% list_attributes() -> {ok, [#node{}]} | {error, term()}
%%
%% Returns every node with kind=attribute currently in the Mnesia
%% `nodes` table.  Includes bootstrap attributes and any runtime
%% additions.
%%-----------------------------------------------------------------------------
list_attributes() ->
	gen_server:call(?MODULE, list_attributes).


%%-----------------------------------------------------------------------------
%% list_relationship_types() -> {ok, [#node{}]} | {error, term()}
%%
%% Returns every attribute node whose compositional parent is the
%% `Relationships` subtree (nref 8).  Includes the four bootstrap
%% buckets (nrefs 13-16) as well as any runtime additions.
%%-----------------------------------------------------------------------------
list_relationship_types() ->
	gen_server:call(?MODULE, list_relationship_types).


%%-----------------------------------------------------------------------------
%% seeded_nrefs() -> {ok, #{literal_type => integer(),
%%                          target_kind => integer(),
%%                          relationship_avp => integer()}}
%%
%% Returns the nrefs of the three seeded runtime literal attributes.
%% Primarily intended for other graphdb workers and integration tests.
%%-----------------------------------------------------------------------------
seeded_nrefs() ->
	gen_server:call(?MODULE, seeded_nrefs).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init/1
%%
%% Ensures the three seeded literal attributes exist in the
%% ontology and caches their nrefs in state.  Idempotent:
%% on restart, detects the existing seeds by name under the Literals
%% subtree and reuses their nrefs.
%%-----------------------------------------------------------------------------
init([]) ->
	try
		State = #state{
			literal_type_nref     = ensure_seed("literal_type"),
			target_kind_nref      = ensure_seed("target_kind"),
			relationship_avp_nref = ensure_seed("relationship_avp")
		},
		logger:info("graphdb_attr: started (literal_type=~p, target_kind=~p, "
			"relationship_avp=~p)",
			[State#state.literal_type_nref, State#state.target_kind_nref,
			 State#state.relationship_avp_nref]),
		{ok, State}
	catch
		throw:{error, Reason} ->
			logger:error("graphdb_attr: seeding failed: ~p", [Reason]),
			{stop, {seed_failed, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_name_attribute, Name}, _From, State) ->
	Reply = do_create_attribute(Name, ?PARENT_NAMES, []),
	{reply, Reply, State};

handle_call({create_literal_attribute, Name, Type}, _From,
		#state{literal_type_nref = TypeAttr} = State) ->
	Extra = [#{attribute => TypeAttr, value => Type}],
	Reply = do_create_attribute(Name, ?PARENT_LITERALS, Extra),
	{reply, Reply, State};

handle_call({create_relationship_attribute, Name, ReciprocalName, TargetKind},
		_From, #state{target_kind_nref = TkAttr} = State) ->
	Extra = [#{attribute => TkAttr, value => TargetKind}],
	case do_create_attribute(Name, ?PARENT_RELATIONSHIPS, Extra) of
		{ok, FwdNref} ->
			case do_create_attribute(ReciprocalName, ?PARENT_RELATIONSHIPS, Extra) of
				{ok, RevNref} -> {reply, {ok, {FwdNref, RevNref}}, State};
				{error, _} = Err -> {reply, Err, State}
			end;
		{error, _} = Err ->
			{reply, Err, State}
	end;

handle_call({create_relationship_type, Name}, _From, State) ->
	Reply = do_create_attribute(Name, ?PARENT_RELATIONSHIPS, []),
	{reply, Reply, State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Lookups
%%-----------------------------------------------------------------------------
handle_call({get_attribute, Nref}, _From, State) ->
	{reply, do_get_attribute(Nref), State};

handle_call(list_attributes, _From, State) ->
	{reply, do_list_attributes(), State};

handle_call(list_relationship_types, _From, State) ->
	{reply, do_list_children(?PARENT_RELATIONSHIPS), State};

handle_call(seeded_nrefs, _From, State) ->
	Reply = {ok, #{
		literal_type     => State#state.literal_type_nref,
		target_kind      => State#state.target_kind_nref,
		relationship_avp => State#state.relationship_avp_nref
	}},
	{reply, Reply, State};

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
%% valid_target_kind(TargetKind) -> boolean()
%%-----------------------------------------------------------------------------
valid_target_kind(category)  -> true;
valid_target_kind(attribute) -> true;
valid_target_kind(class)     -> true;
valid_target_kind(instance)  -> true;
valid_target_kind(_)         -> false.


%%-----------------------------------------------------------------------------
%% ensure_seed(Name) -> Nref
%%
%% Looks up an existing literal attribute by name under the Literals
%% subtree; if not found, creates it (node + compositional arc pair).
%% Throws {error, Reason} on failure.
%%-----------------------------------------------------------------------------
ensure_seed(Name) ->
	case find_attribute_by_name(?PARENT_LITERALS, Name) of
		{ok, Nref} ->
			Nref;
		not_found ->
			case do_create_attribute(Name, ?PARENT_LITERALS, []) of
				{ok, Nref}       -> Nref;
				{error, Reason}  -> throw({error, Reason})
			end
	end.


%%-----------------------------------------------------------------------------
%% find_attribute_by_name(ParentNref, Name) -> {ok, Nref} | not_found
%%
%% Finds an attribute-kind child of ParentNref whose name AVP matches
%% Name.  Uses the parent index for O(1) lookup.  Returns the first
%% match; duplicate names are not expected in a well-formed library.
%%-----------------------------------------------------------------------------
find_attribute_by_name(ParentNref, Name) ->
	F = fun() ->
		Children = mnesia:index_read(nodes, ParentNref, #node.parent),
		lists:search(fun(N) -> node_has_name(N, Name) end, Children)
	end,
	case mnesia:transaction(F) of
		{atomic, {value, #node{nref = Nref}}} -> {ok, Nref};
		{atomic, false}                       -> not_found;
		{aborted, Reason}                     -> throw({error, Reason})
	end.


%%-----------------------------------------------------------------------------
%% node_has_name(Node, Name) -> boolean()
%%-----------------------------------------------------------------------------
node_has_name(#node{attribute_value_pairs = AVPs}, Name) ->
	lists:any(fun
		(#{attribute := ?NAME_ATTR_FOR_ATTRIBUTE, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).


%%-----------------------------------------------------------------------------
%% do_create_attribute(Name, ParentNref, ExtraAVPs) ->
%%     {ok, Nref} | {error, term()}
%%
%% Allocates an nref, builds the attribute node record with the name
%% AVP plus any extras, allocates two relationship ids for the
%% compositional parent/child arc pair, and writes all three rows in
%% a single Mnesia transaction.
%%
%% All nref_server:get_nref/0 calls are issued OUTSIDE the Mnesia
%% transaction to avoid side-effects on transaction retry.
%%-----------------------------------------------------------------------------
do_create_attribute(Name, ParentNref, ExtraAVPs) ->
	Nref = nref_server:get_nref(),
	NameAVP = #{attribute => ?NAME_ATTR_FOR_ATTRIBUTE, value => Name},
	Node = #node{
		nref = Nref,
		kind = attribute,
		parent = ParentNref,
		attribute_value_pairs = [NameAVP | ExtraAVPs]
	},
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	P2C = #relationship{
		id = Id1,
		source_nref = ParentNref,
		characterization = ?ATTR_CHILD_ARC,
		target_nref = Nref,
		reciprocal = ?ATTR_PARENT_ARC,
		avps = []
	},
	C2P = #relationship{
		id = Id2,
		source_nref = Nref,
		characterization = ?ATTR_PARENT_ARC,
		target_nref = ParentNref,
		reciprocal = ?ATTR_CHILD_ARC,
		avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, Nref};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_get_attribute(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_an_attribute | term()}
%%-----------------------------------------------------------------------------
do_get_attribute(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = attribute} = Node]} -> {ok, Node};
		{atomic, [_Other]}                         -> {error, not_an_attribute};
		{atomic, []}                               -> {error, not_found};
		{aborted, Reason}                          -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_list_attributes() -> {ok, [#node{}]} | {error, term()}
%%-----------------------------------------------------------------------------
do_list_attributes() ->
	F = fun() ->
		mnesia:match_object(nodes, #node{_ = '_', kind = attribute}, read)
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_list_children(ParentNref) -> {ok, [#node{}]} | {error, term()}
%%-----------------------------------------------------------------------------
do_list_children(ParentNref) ->
	F = fun() ->
		mnesia:index_read(nodes, ParentNref, #node.parent)
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.
