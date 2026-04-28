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
%% Description: graphdb_class manages the taxonomic ("is a") hierarchy.
%%				Creates class nodes, manages qualifying characteristics,
%%				and provides class-level attribute inheritance.  Class
%%				nodes live in the Mnesia `nodes` table with kind=class.
%%				Top-level classes are direct children of the Classes
%%				category (nref 3); subclasses are children of other
%%				class nodes.
%%
%%				On first startup, graphdb_class seeds a
%%				"qualifying_characteristic" literal attribute under the
%%				Literals subtree (nref 7).  This attribute is used to
%%				mark which attributes are qualifying characteristics of
%%				a class.  Subsequent startups detect the existing seed
%%				by name and cache its nref in the gen_server state.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: taxonomic hierarchy over Mnesia.  Provides
%% create_class/2, add_qualifying_characteristic/2, get_class/1,
%% subclasses/1, ancestors/1, inherited_attributes/1.
%% Seeds qualifying_characteristic at init.
%%---------------------------------------------------------------------
-module(graphdb_class).
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
%% Classes category — top-level organisational anchor for all classes.
-define(CLASSES_CATEGORY, 3).

%% NameAttrNref for class-kind nodes.
-define(NAME_ATTR_FOR_CLASS, 19).

%% Compositional arc labels for class children of class parents.
-define(CLASS_CHILD_ARC,  26).  %% Child/ClassRel  -- parent -> child
-define(CLASS_PARENT_ARC, 25).  %% Parent/ClassRel -- child  -> parent

%% Literals subtree — parent for seeded literal attributes.
-define(PARENT_LITERALS, 7).

%% NameAttrNref for attribute-kind nodes (used when seeding).
-define(NAME_ATTR_FOR_ATTRIBUTE, 18).

%% Compositional arc labels for attribute children (used when seeding).
-define(ATTR_CHILD_ARC,  24).
-define(ATTR_PARENT_ARC, 23).


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
	qc_attr_nref			%% integer() -- seeded qualifying_characteristic attribute
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
		create_class/2,
		add_qualifying_characteristic/2,
		%% Lookups
		get_class/1,
		subclasses/1,
		ancestors/1,
		%% Inheritance
		inherited_attributes/1,
		%% Seeded nref accessor
		qc_attr_nref/0
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
		is_valid_parent_kind/1,
		collect_qc_nrefs/2
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% create_class(Name, ParentClassNref) -> {ok, Nref} | {error, term()}
%%
%% Creates a new class node in the ontology.  ParentClassNref
%% is either the Classes category (nref 3) for top-level classes or
%% another class node's nref for subclasses.  Writes the node record and
%% a compositional parent/child arc pair atomically.
%%-----------------------------------------------------------------------------
create_class(Name, ParentClassNref) ->
	gen_server:call(?MODULE, {create_class, Name, ParentClassNref}).


%%-----------------------------------------------------------------------------
%% add_qualifying_characteristic(ClassNref, AttrNref) -> ok | {error, term()}
%%
%% Adds an attribute as a qualifying characteristic of the class.
%% Validates that ClassNref is a class node and AttrNref is an attribute
%% node.  Idempotent: adding the same QC twice is a no-op.
%%-----------------------------------------------------------------------------
add_qualifying_characteristic(ClassNref, AttrNref) ->
	gen_server:call(?MODULE, {add_qualifying_characteristic, ClassNref, AttrNref}).


%%-----------------------------------------------------------------------------
%% get_class(Nref) -> {ok, #node{}} | {error, not_found | not_a_class | term()}
%%
%% Returns the class node identified by Nref.  Only nodes of
%% kind=class are returned; any other kind yields {error, not_a_class}.
%%-----------------------------------------------------------------------------
get_class(Nref) ->
	gen_server:call(?MODULE, {get_class, Nref}).


%%-----------------------------------------------------------------------------
%% subclasses(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct subclasses (class-kind children) of the given
%% class node.
%%-----------------------------------------------------------------------------
subclasses(ClassNref) ->
	gen_server:call(?MODULE, {subclasses, ClassNref}).


%%-----------------------------------------------------------------------------
%% ancestors(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns the ancestor chain of the given class, starting from its
%% immediate parent class up to (but not including) the Classes
%% category.  Returns an empty list for top-level classes.
%%-----------------------------------------------------------------------------
ancestors(ClassNref) ->
	gen_server:call(?MODULE, {ancestors, ClassNref}).


%%-----------------------------------------------------------------------------
%% inherited_attributes(ClassNref) -> {ok, [integer()]} | {error, term()}
%%
%% Returns the list of qualifying-characteristic attribute nrefs that
%% apply to this class, including those inherited from ancestor classes.
%% Local QCs appear first; ancestor QCs are appended in nearest-first
%% order with duplicates removed (local takes priority).
%%-----------------------------------------------------------------------------
inherited_attributes(ClassNref) ->
	gen_server:call(?MODULE, {inherited_attributes, ClassNref}).


%%-----------------------------------------------------------------------------
%% qc_attr_nref() -> {ok, integer()}
%%
%% Returns the nref of the seeded qualifying_characteristic attribute.
%% Primarily intended for other graphdb workers and integration tests.
%%-----------------------------------------------------------------------------
qc_attr_nref() ->
	gen_server:call(?MODULE, qc_attr_nref).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init/1
%%
%% Seeds the qualifying_characteristic literal attribute under the
%% Literals subtree (nref 7) and caches its nref in state.  Idempotent:
%% on restart, detects the existing seed by name and reuses its nref.
%%-----------------------------------------------------------------------------
init([]) ->
	try
		QcNref = ensure_seed("qualifying_characteristic"),
		logger:info("graphdb_class: started (qc_attr=~p)", [QcNref]),
		{ok, #state{qc_attr_nref = QcNref}}
	catch
		throw:{error, Reason} ->
			logger:error("graphdb_class: seeding failed: ~p", [Reason]),
			{stop, {seed_failed, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_class, Name, ParentClassNref}, _From, State) ->
	{reply, do_create_class(Name, ParentClassNref), State};

handle_call({add_qualifying_characteristic, ClassNref, AttrNref}, _From,
		#state{qc_attr_nref = QcAttr} = State) ->
	{reply, do_add_qc(ClassNref, AttrNref, QcAttr), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Lookups
%%-----------------------------------------------------------------------------
handle_call({get_class, Nref}, _From, State) ->
	{reply, do_get_class(Nref), State};

handle_call({subclasses, ClassNref}, _From, State) ->
	{reply, do_subclasses(ClassNref), State};

handle_call({ancestors, ClassNref}, _From, State) ->
	{reply, do_ancestors(ClassNref), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Inheritance
%%-----------------------------------------------------------------------------
handle_call({inherited_attributes, ClassNref}, _From,
		#state{qc_attr_nref = QcAttr} = State) ->
	{reply, do_inherited_attributes(ClassNref, QcAttr), State};

handle_call(qc_attr_nref, _From, #state{qc_attr_nref = QcAttr} = State) ->
	{reply, {ok, QcAttr}, State};

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
%% is_valid_parent_kind(Kind) -> boolean()
%%
%% Returns true if Kind is acceptable as a class node's parent.
%% Category (the Classes anchor) and class (superclass) are valid.
%%-----------------------------------------------------------------------------
is_valid_parent_kind(category) -> true;
is_valid_parent_kind(class)    -> true;
is_valid_parent_kind(_)        -> false.


%%-----------------------------------------------------------------------------
%% collect_qc_nrefs(AVPs, QcAttrNref) -> [integer()]
%%
%% Extracts qualifying-characteristic attribute nrefs from an AVP list.
%%-----------------------------------------------------------------------------
collect_qc_nrefs(AVPs, QcAttr) ->
	[V || #{attribute := A, value := V} <- AVPs, A =:= QcAttr].


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
			case do_create_seed_attribute(Name) of
				{ok, Nref}       -> Nref;
				{error, Reason}  -> throw({error, Reason})
			end
	end.


%%-----------------------------------------------------------------------------
%% find_attribute_by_name(ParentNref, Name) -> {ok, Nref} | not_found
%%
%% Finds an attribute-kind child of ParentNref whose name AVP matches
%% Name.  Uses the parent index for O(1) lookup.
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
%% do_create_seed_attribute(Name) -> {ok, Nref} | {error, term()}
%%
%% Creates a literal attribute node under the Literals subtree (nref 7)
%% with only the name AVP.  Used for seeding the qualifying_characteristic
%% attribute.  Writes node + compositional arc pair atomically.
%%
%% All nref_server:get_nref/0 calls are issued OUTSIDE the Mnesia
%% transaction to avoid side-effects on transaction retry.
%%-----------------------------------------------------------------------------
do_create_seed_attribute(Name) ->
	Nref = nref_server:get_nref(),
	NameAVP = #{attribute => ?NAME_ATTR_FOR_ATTRIBUTE, value => Name},
	Node = #node{
		nref = Nref,
		kind = attribute,
		parent = ?PARENT_LITERALS,
		attribute_value_pairs = [NameAVP]
	},
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	P2C = #relationship{
		id = Id1,
		source_nref = ?PARENT_LITERALS,
		characterization = ?ATTR_CHILD_ARC,
		target_nref = Nref,
		reciprocal = ?ATTR_PARENT_ARC,
		avps = []
	},
	C2P = #relationship{
		id = Id2,
		source_nref = Nref,
		characterization = ?ATTR_PARENT_ARC,
		target_nref = ?PARENT_LITERALS,
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
%% do_create_class(Name, ParentClassNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Validates the parent, allocates an nref, builds the class node
%% record with the name AVP, allocates two relationship ids for the
%% compositional parent/child arc pair, and writes all three rows in
%% a single Mnesia transaction.
%%-----------------------------------------------------------------------------
do_create_class(Name, ParentClassNref) ->
	case do_validate_parent(ParentClassNref) of
		ok ->
			Nref = nref_server:get_nref(),
			NameAVP = #{attribute => ?NAME_ATTR_FOR_CLASS, value => Name},
			Node = #node{
				nref = Nref,
				kind = class,
				parent = ParentClassNref,
				attribute_value_pairs = [NameAVP]
			},
			Id1 = nref_server:get_nref(),
			Id2 = nref_server:get_nref(),
			P2C = #relationship{
				id = Id1,
				source_nref = ParentClassNref,
				characterization = ?CLASS_CHILD_ARC,
				target_nref = Nref,
				reciprocal = ?CLASS_PARENT_ARC,
				avps = []
			},
			C2P = #relationship{
				id = Id2,
				source_nref = Nref,
				characterization = ?CLASS_PARENT_ARC,
				target_nref = ParentClassNref,
				reciprocal = ?CLASS_CHILD_ARC,
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
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% do_validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Validates that ParentNref is either the Classes category (nref 3) or
%% an existing class node.
%%-----------------------------------------------------------------------------
do_validate_parent(?CLASSES_CATEGORY) ->
	ok;
do_validate_parent(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = Kind}]} ->
			case is_valid_parent_kind(Kind) of
				true  -> ok;
				false -> {error, {invalid_parent_kind, Kind}}
			end;
		{atomic, []}                     -> {error, parent_not_found};
		{aborted, Reason}                -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_add_qc(ClassNref, AttrNref, QcAttr) -> ok | {error, term()}
%%
%% Adds the qualifying-characteristic AVP to the class node.  Validates
%% both ClassNref (must be class) and AttrNref (must be attribute).
%% Idempotent: if the QC already exists, returns ok.
%%-----------------------------------------------------------------------------
do_add_qc(ClassNref, AttrNref, QcAttr) ->
	Txn = fun() ->
		case mnesia:read(nodes, ClassNref) of
			[#node{kind = class, attribute_value_pairs = AVPs} = Node] ->
				case mnesia:read(nodes, AttrNref) of
					[#node{kind = attribute}] ->
						Already = lists:any(fun
							(#{attribute := A, value := V}) ->
								A =:= QcAttr andalso V =:= AttrNref;
							(_) -> false
						end, AVPs),
						case Already of
							true ->
								already_exists;
							false ->
								NewAVP = #{attribute => QcAttr, value => AttrNref},
								Updated = Node#node{
									attribute_value_pairs = AVPs ++ [NewAVP]
								},
								ok = mnesia:write(nodes, Updated, write),
								ok
						end;
					[#node{}] ->
						{error, {not_an_attribute, AttrNref}};
					[] ->
						{error, {attribute_not_found, AttrNref}}
				end;
			[#node{kind = Kind}] ->
				{error, {not_a_class, Kind}};
			[] ->
				{error, not_found}
		end
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}             -> ok;
		{atomic, already_exists} -> ok;
		{atomic, {error, _} = E} -> E;
		{aborted, Reason}        -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_get_class(Nref) ->
%%     {ok, #node{}} | {error, not_found | not_a_class | term()}
%%-----------------------------------------------------------------------------
do_get_class(Nref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = class} = Node]} -> {ok, Node};
		{atomic, [_Other]}                     -> {error, not_a_class};
		{atomic, []}                           -> {error, not_found};
		{aborted, Reason}                      -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_subclasses(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Returns all direct child nodes of kind=class under ClassNref.
%%-----------------------------------------------------------------------------
do_subclasses(ClassNref) ->
	F = fun() ->
		Children = mnesia:index_read(nodes, ClassNref, #node.parent),
		[N || N <- Children, N#node.kind =:= class]
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_ancestors(ClassNref) -> {ok, [#node{}]} | {error, term()}
%%
%% Walks the parent chain starting from ClassNref's parent.  Stops at
%% the Classes category (nref 3) or at a non-class node.  Returns
%% the list of ancestor class nodes in nearest-first order.
%%-----------------------------------------------------------------------------
do_ancestors(ClassNref) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, ClassNref) end) of
		{atomic, [#node{kind = class, parent = Parent}]} ->
			do_walk_ancestors(Parent, []);
		{atomic, [_]} ->
			{error, not_a_class};
		{atomic, []} ->
			{error, not_found};
		{aborted, Reason} ->
			{error, Reason}
	end.

do_walk_ancestors(?CLASSES_CATEGORY, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors(undefined, Acc) ->
	{ok, lists:reverse(Acc)};
do_walk_ancestors(Nref, Acc) ->
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [#node{kind = class, parent = Parent} = Node]} ->
			do_walk_ancestors(Parent, [Node | Acc]);
		{atomic, [_]} ->
			{ok, lists:reverse(Acc)};
		{atomic, []} ->
			{ok, lists:reverse(Acc)};
		{aborted, Reason} ->
			{error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% do_inherited_attributes(ClassNref, QcAttr) ->
%%     {ok, [integer()]} | {error, term()}
%%
%% Collects qualifying-characteristic attribute nrefs from the class
%% and all its ancestors.  Local QCs appear first; ancestor QCs are
%% appended in nearest-first order with duplicates removed.
%%-----------------------------------------------------------------------------
do_inherited_attributes(ClassNref, QcAttr) ->
	case do_get_class(ClassNref) of
		{ok, Node} ->
			case do_ancestors(ClassNref) of
				{ok, Ancestors} ->
					AllNodes = [Node | Ancestors],
					QcNrefs = collect_all_qcs(AllNodes, QcAttr),
					{ok, QcNrefs};
				{error, _} = Err ->
					Err
			end;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% collect_all_qcs(Nodes, QcAttr) -> [integer()]
%%
%% Collects QC nrefs from a list of nodes, deduplicating in list order
%% (earlier entries take priority).
%%-----------------------------------------------------------------------------
collect_all_qcs(Nodes, QcAttr) ->
	lists:foldl(fun(#node{attribute_value_pairs = AVPs}, Acc) ->
		Qcs = collect_qc_nrefs(AVPs, QcAttr),
		lists:foldl(fun(Q, A) ->
			case lists:member(Q, A) of
				true  -> A;
				false -> A ++ [Q]
			end
		end, Acc, Qcs)
	end, [], Nodes).
