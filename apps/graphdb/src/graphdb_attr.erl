%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_attr manages the environment attribute library.
%%				Creates and retrieves name attributes, literal
%%				attributes, relationship attributes (arc labels), and
%%				relationship-type groupings.  Attribute nodes live in
%%				the Mnesia `nodes` table with kind=attribute and a
%%				taxonomic parent in the attribute library tree (parent
%%				arcs in the attribute subtree are kind=taxonomy --
%%				refinement of kind, not part-whole).
%%
%%				On first startup, graphdb_attr seeds five runtime
%%				literal attributes under the `Literals` subtree (nref
%%				7): `literal_type`, `target_kind`, `relationship_avp`,
%%				`attribute_type`, and `instantiable`.  Subsequent
%%				startups detect the existing seeds by name and cache
%%				their nrefs in the gen_server state.
%%
%%				`attribute_type` is stamped as an AVP on every
%%				attribute node (value :: name | literal | relationship)
%%				so the type is read directly from the node rather than
%%				inferred by walking the parent chain.  Bootstrap
%%				attribute nodes are retro-stamped at init/1 time
%%				based on their position under the Names (6) / Literals
%%				(7) / Relationships (8) subtree.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Initial implementation: attribute library over Mnesia.  Provides
%% create_name_attribute/1, create_literal_attribute/2,
%% create_relationship_attribute_pair/3, create_relationship_type/1,
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
	attribute_literals_group_nref,	%% integer() -- Attribute Literals sub-group
	literal_type_nref,				%% integer() -- seeded literal attribute
	target_kind_nref,				%% integer() -- seeded literal attribute
	relationship_avp_nref,			%% integer() -- seeded literal attribute
	attribute_type_nref,			%% integer() -- seeded literal attribute
	instantiable_nref				%% integer() -- seeded marker literal attribute
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
		create_value_attribute/4,
		create_name_attribute/1,
		create_name_attribute/2,
		create_literal_attribute/2,
		create_literal_attribute/3,
		create_relationship_attribute_pair/3,
		create_relationship_attribute_pair/4,
		create_relationship_type/1,
		create_relationship_type/2,
		%% Lookups
		get_attribute/1,
		list_attributes/0,
		list_relationship_types/0,
		attribute_type_of/1,
		%% Seeded nref accessors
		seeded_nrefs/0,
		%% Cross-worker stamping
		retro_stamp_attribute_types/0
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
%% create_value_attribute(Name, AttrType, TypeArgs, ParentNref) ->
%%     {ok, Nref} | {error, term()}
%%
%% Canonical single-node attribute creator.  AttrType is one of
%% name | literal | relationship.  TypeArgs is interpreted per AttrType:
%% [] for name and relationship; [LiteralType] for literal (the literal
%% value-type atom, stamped under the seeded `literal_type` attribute).
%% ParentNref must name an existing kind=attribute node.
%%-----------------------------------------------------------------------------
create_value_attribute(Name, AttrType, TypeArgs, ParentNref) ->
	gen_server:call(?MODULE,
		{create_value_attribute, Name, AttrType, TypeArgs, ParentNref}).

%%-----------------------------------------------------------------------------
%% create_name_attribute(Name)            -> default parent ?NREF_NAMES (6)
%% create_name_attribute(Name, ParentNref)
%%-----------------------------------------------------------------------------
create_name_attribute(Name) ->
	create_value_attribute(Name, name, [], ?NREF_NAMES).

create_name_attribute(Name, ParentNref) ->
	create_value_attribute(Name, name, [], ParentNref).

%%-----------------------------------------------------------------------------
%% create_literal_attribute(Name, Type)             -> default ?NREF_LITERALS (7)
%% create_literal_attribute(Name, Type, ParentNref)
%%-----------------------------------------------------------------------------
create_literal_attribute(Name, Type) ->
	create_value_attribute(Name, literal, [Type], ?NREF_LITERALS).

create_literal_attribute(Name, Type, ParentNref) ->
	create_value_attribute(Name, literal, [Type], ParentNref).


%%-----------------------------------------------------------------------------
%% create_relationship_attribute_pair(Name, ReciprocalName, TargetKind) ->
%%     {ok, {Nref, ReciprocalNref}} | {error, term()}
%%
%% Creates a reciprocal pair of arc label attribute nodes under the
%% `Relationships` subtree (nref 8).  Delegates to /4 with the
%% default parent.
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair(Name, ReciprocalName, TargetKind) ->
	create_relationship_attribute_pair(Name, ReciprocalName, TargetKind,
		?NREF_RELATIONSHIPS).

%%-----------------------------------------------------------------------------
%% create_relationship_attribute_pair(Name, ReciprocalName, TargetKind,
%%                                    ParentNref) ->
%%     {ok, {Nref, ReciprocalNref}} | {error, term()}
%%
%% As /3 but files both arc-label nodes under ParentNref.  ParentNref
%% must name an existing kind=attribute node (validated server-side);
%% typically one of the Relationships sub-buckets (13-16) or the
%% Relationships root (8).
%%-----------------------------------------------------------------------------
create_relationship_attribute_pair(Name, ReciprocalName, TargetKind, ParentNref) ->
	case valid_target_kind(TargetKind) of
		true ->
			gen_server:call(?MODULE,
				{create_relationship_attribute_pair, Name, ReciprocalName,
					TargetKind, ParentNref});
		false ->
			{error, {invalid_target_kind, TargetKind}}
	end.


%%-----------------------------------------------------------------------------
%% create_relationship_type(Name)            -> default ?NREF_RELATIONSHIPS (8)
%% create_relationship_type(Name, ParentNref) -- grouping/bucket node
%%-----------------------------------------------------------------------------
create_relationship_type(Name) ->
	create_value_attribute(Name, relationship, [], ?NREF_RELATIONSHIPS).

create_relationship_type(Name, ParentNref) ->
	create_value_attribute(Name, relationship, [], ParentNref).


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
%% Returns every attribute node whose taxonomic parent is the
%% `Relationships` subtree (nref 8).  Includes the four bootstrap
%% buckets (nrefs 13-16) as well as any runtime additions.
%%-----------------------------------------------------------------------------
list_relationship_types() ->
	gen_server:call(?MODULE, list_relationship_types).


%%-----------------------------------------------------------------------------
%% attribute_type_of(Nref) ->
%%     {ok, name | literal | relationship}
%%   | {error, not_found | not_an_attribute | no_attribute_type | term()}
%%
%% Reads the `attribute_type` AVP from an attribute node and returns
%% the kind directly -- no parent-chain walk.  Stamped on every
%% attribute by graphdb_attr at creation; bootstrap attribute nodes
%% are retro-stamped at init/1.
%%-----------------------------------------------------------------------------
attribute_type_of(Nref) ->
	gen_server:call(?MODULE, {attribute_type_of, Nref}).


%%-----------------------------------------------------------------------------
%% seeded_nrefs() -> {ok, #{attribute_literals_group => integer(),
%%                          literal_type             => integer(),
%%                          target_kind              => integer(),
%%                          relationship_avp         => integer(),
%%                          attribute_type           => integer(),
%%                          instantiable             => integer()}}
%%
%% Returns the nrefs of the Attribute Literals sub-group and the five
%% seeded runtime literal attributes.  Primarily intended for other
%% graphdb workers and integration tests.
%%-----------------------------------------------------------------------------
seeded_nrefs() ->
	gen_server:call(?MODULE, seeded_nrefs).


%%-----------------------------------------------------------------------------
%% retro_stamp_attribute_types() -> ok | {error, term()}
%%
%% Re-runs `retro_stamp_bootstrap_attribute_types/1` against the
%% currently-cached `attribute_type` literal-attribute nref.  Other
%% workers (graphdb_language, future graphdb_rules) call this after
%% their own `init/1` seeds attribute-kind nodes so the new nodes
%% receive the `attribute_type` AVP.
%%-----------------------------------------------------------------------------
retro_stamp_attribute_types() ->
	gen_server:call(?MODULE, retro_stamp_attribute_types).


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
		AttrLitNref = ensure_seed("Attribute Literals", ?NREF_LITERALS),
		State = #state{
			attribute_literals_group_nref = AttrLitNref,
			literal_type_nref     = ensure_seed("literal_type", AttrLitNref),
			target_kind_nref      = ensure_seed("target_kind", AttrLitNref),
			relationship_avp_nref = ensure_seed("relationship_avp", AttrLitNref),
			attribute_type_nref   = ensure_seed("attribute_type", AttrLitNref),
			instantiable_nref     = ensure_seed("instantiable", AttrLitNref)
		},
		ok = ensure_template_avp_marker(State#state.relationship_avp_nref),
		ok = retro_stamp_bootstrap_attribute_types(
			State#state.attribute_type_nref),
		logger:info("graphdb_attr: started (attribute_literals_group=~p, "
			"literal_type=~p, target_kind=~p, relationship_avp=~p, "
			"attribute_type=~p, instantiable=~p)",
			[AttrLitNref, State#state.literal_type_nref,
			 State#state.target_kind_nref, State#state.relationship_avp_nref,
			 State#state.attribute_type_nref, State#state.instantiable_nref]),
		{ok, State}
	catch
		throw:{error, Reason} ->
			logger:error("graphdb_attr: seeding failed: ~p", [Reason]),
			{stop, {seed_failed, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Creators
%%-----------------------------------------------------------------------------
handle_call({create_value_attribute, Name, AttrType, TypeArgs, ParentNref},
		_From, State) ->
	Reply = case validate_parent(ParentNref) of
		ok ->
			do_create_value_attribute(Name, AttrType, TypeArgs, ParentNref,
				State);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};

handle_call({create_relationship_attribute_pair, Name, ReciprocalName,
		TargetKind, ParentNref},
		_From, #state{target_kind_nref = TkAttr} = State) ->
	Reply = case validate_parent(ParentNref) of
		ok ->
			Extra = [#{attribute => TkAttr, value => TargetKind},
					 attr_type_avp(relationship, State)],
			do_create_relationship_attribute_pair(Name, ReciprocalName, Extra,
				ParentNref);
		{error, _} = Err ->
			Err
	end,
	{reply, Reply, State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Lookups
%%-----------------------------------------------------------------------------
handle_call({get_attribute, Nref}, _From, State) ->
	{reply, do_get_attribute(Nref), State};

handle_call(list_attributes, _From, State) ->
	{reply, do_list_attributes(), State};

handle_call(list_relationship_types, _From, State) ->
	{reply, do_list_children(?NREF_RELATIONSHIPS), State};

handle_call({attribute_type_of, Nref}, _From,
		#state{attribute_type_nref = AtAttr} = State) ->
	{reply, do_attribute_type_of(Nref, AtAttr), State};

handle_call(seeded_nrefs, _From, State) ->
	Reply = {ok, #{
		attribute_literals_group => State#state.attribute_literals_group_nref,
		literal_type     => State#state.literal_type_nref,
		target_kind      => State#state.target_kind_nref,
		relationship_avp => State#state.relationship_avp_nref,
		attribute_type   => State#state.attribute_type_nref,
		instantiable     => State#state.instantiable_nref
	}},
	{reply, Reply, State};

handle_call(retro_stamp_attribute_types, _From,
		#state{attribute_type_nref = AtAttr} = State) ->
	ok = retro_stamp_bootstrap_attribute_types(AtAttr),
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
%% ensure_seed(Name, ParentNref) -> Nref
%%
%% Looks up an existing attribute by name under ParentNref; if not
%% found, creates it (node + taxonomy arc pair).  Throws {error, Reason}
%% on failure.  Caller chooses the parent -- typically a sub-group node
%% under Literals (7) or the Literals root itself.
%%-----------------------------------------------------------------------------
ensure_seed(Name, ParentNref) ->
	case find_attribute_by_name(ParentNref, Name) of
		{ok, Nref} ->
			Nref;
		not_found ->
			case do_create_attribute(Name, ParentNref, []) of
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
		Children = downward_children_by_arc(ParentNref, ?ARC_ATTR_CHILD,
			taxonomy),
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
		(#{attribute := ?NAME_ATTR_ATTRIBUTE, value := V}) -> V =:= Name;
		(_) -> false
	end, AVPs).


%%-----------------------------------------------------------------------------
%% do_create_attribute(Name, ParentNref, ExtraAVPs) ->
%%     {ok, Nref} | {error, term()}
%%
%% Allocates an nref, builds the attribute node record with the name
%% AVP plus any extras, allocates two relationship ids for the
%% taxonomy parent/child arc pair, and writes all three rows in a
%% single Mnesia transaction.
%%
%% All nref_server:get_nref/0 (node nrefs) and rel_id_server:get_id/0
%% (relationship IDs) calls are issued OUTSIDE the Mnesia transaction
%% to avoid side-effects on transaction retry.
%%-----------------------------------------------------------------------------
do_create_attribute(Name, ParentNref, ExtraAVPs) ->
	Nref = graphdb_nref:get_next(),
	NameAVP = #{attribute => ?NAME_ATTR_ATTRIBUTE, value => Name},
	Node = #node{
		nref = Nref,
		kind = attribute,
		parents = [ParentNref],
		attribute_value_pairs = [NameAVP | ExtraAVPs]
	},
	{Id1, Id2} = rel_id_server:get_id_pair(),
	P2C = #relationship{
		id = Id1,
		kind = taxonomy,
		source_nref = ParentNref,
		characterization = ?ARC_ATTR_CHILD,
		target_nref = Nref,
		reciprocal = ?ARC_ATTR_PARENT,
		avps = []
	},
	C2P = #relationship{
		id = Id2,
		kind = taxonomy,
		source_nref = Nref,
		characterization = ?ARC_ATTR_PARENT,
		target_nref = ParentNref,
		reciprocal = ?ARC_ATTR_CHILD,
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
%% do_create_value_attribute(Name, AttrType, TypeArgs, ParentNref, State) ->
%%     {ok, Nref} | {error, term()}
%%
%% Builds the attribute_type AVP (and, for literals, the literal_type
%% AVP) from gen_server state, then writes one attribute node + taxonomy
%% arc pair via do_create_attribute/3.  Clause heads enforce the
%% TypeArgs contract: [] for name|relationship, [LiteralType] for
%% literal.  Malformed args / unknown types are rejected without a write.
%%-----------------------------------------------------------------------------
do_create_value_attribute(Name, name, [], ParentNref, State) ->
	Extra = [attr_type_avp(name, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(Name, relationship, [], ParentNref, State) ->
	Extra = [attr_type_avp(relationship, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(Name, literal, [LiteralType], ParentNref,
		#state{literal_type_nref = LtAttr} = State) ->
	Extra = [#{attribute => LtAttr, value => LiteralType},
			 attr_type_avp(literal, State)],
	do_create_attribute(Name, ParentNref, Extra);
do_create_value_attribute(_Name, AttrType, TypeArgs, _ParentNref, _State)
		when AttrType =:= name; AttrType =:= literal;
			 AttrType =:= relationship ->
	{error, {bad_type_args, AttrType, TypeArgs}};
do_create_value_attribute(_Name, AttrType, _TypeArgs, _ParentNref, _State) ->
	{error, {bad_attribute_type, AttrType}}.


%%-----------------------------------------------------------------------------
%% do_create_relationship_attribute_pair(FwdName, RevName, ExtraAVPs,
%%                                        ParentNref) ->
%%     {ok, {FwdNref, RevNref}} | {error, term()}
%%
%% Atomically creates a reciprocal pair of arc-label attribute nodes
%% under ParentNref.  Both nodes plus all four taxonomy arc rows
%% (parent->child + child->parent for each direction) are written
%% inside a single Mnesia transaction so a mid-pair abort cannot leave
%% the database with an orphan half-pair.
%%-----------------------------------------------------------------------------
do_create_relationship_attribute_pair(FwdName, RevName, ExtraAVPs, ParentNref) ->
	FwdNref = graphdb_nref:get_next(),
	RevNref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	{Id3, Id4} = rel_id_server:get_id_pair(),
	FwdAVPs = [#{attribute => ?NAME_ATTR_ATTRIBUTE, value => FwdName}
		| ExtraAVPs],
	RevAVPs = [#{attribute => ?NAME_ATTR_ATTRIBUTE, value => RevName}
		| ExtraAVPs],
	FwdNode = #node{
		nref = FwdNref,
		kind = attribute,
		parents = [ParentNref],
		attribute_value_pairs = FwdAVPs
	},
	RevNode = #node{
		nref = RevNref,
		kind = attribute,
		parents = [ParentNref],
		attribute_value_pairs = RevAVPs
	},
	FwdP2C = #relationship{
		id = Id1, kind = taxonomy,
		source_nref = ParentNref, characterization = ?ARC_ATTR_CHILD,
		target_nref = FwdNref, reciprocal = ?ARC_ATTR_PARENT, avps = []
	},
	FwdC2P = #relationship{
		id = Id2, kind = taxonomy,
		source_nref = FwdNref, characterization = ?ARC_ATTR_PARENT,
		target_nref = ParentNref, reciprocal = ?ARC_ATTR_CHILD, avps = []
	},
	RevP2C = #relationship{
		id = Id3, kind = taxonomy,
		source_nref = ParentNref, characterization = ?ARC_ATTR_CHILD,
		target_nref = RevNref, reciprocal = ?ARC_ATTR_PARENT, avps = []
	},
	RevC2P = #relationship{
		id = Id4, kind = taxonomy,
		source_nref = RevNref, characterization = ?ARC_ATTR_PARENT,
		target_nref = ParentNref, reciprocal = ?ARC_ATTR_CHILD, avps = []
	},
	Txn = fun() ->
		ok = mnesia:write(nodes, FwdNode, write),
		ok = mnesia:write(nodes, RevNode, write),
		ok = mnesia:write(relationships, FwdP2C, write),
		ok = mnesia:write(relationships, FwdC2P, write),
		ok = mnesia:write(relationships, RevP2C, write),
		ok = mnesia:write(relationships, RevC2P, write)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> {ok, {FwdNref, RevNref}};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% validate_parent(ParentNref) -> ok | {error, term()}
%%
%% Confirms ParentNref names an existing kind=attribute node.  Run
%% inside the gen_server before any write so a bad parent consumes no
%% nref or relationship id.  Subtree membership is intentionally NOT
%% checked -- any attribute-kind parent is accepted, keeping the
%% creator decoupled from the scaffold's exact shape.
%%-----------------------------------------------------------------------------
validate_parent(ParentNref) ->
	case mnesia:dirty_read(nodes, ParentNref) of
		[#node{kind = attribute}] -> ok;
		[#node{kind = K}]         -> {error, {parent_not_attribute, K}};
		[]                        -> {error, {parent_not_found, ParentNref}}
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
		downward_children_by_arc(ParentNref, ?ARC_ATTR_CHILD, taxonomy)
	end,
	case mnesia:transaction(F) of
		{atomic, Nodes}   -> {ok, Nodes};
		{aborted, Reason} -> {error, Reason}
	end.


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
%% attr_type_avp(Kind, State) -> #{attribute := integer(), value := atom()}
%%
%% Builds the `attribute_type` AVP map keyed by the seeded
%% attribute_type literal-attribute nref carried in gen_server state.
%% Kind is one of: name | literal | relationship.
%%-----------------------------------------------------------------------------
attr_type_avp(Kind, #state{attribute_type_nref = AtAttr})
		when Kind =:= name; Kind =:= literal; Kind =:= relationship ->
	#{attribute => AtAttr, value => Kind}.


%%-----------------------------------------------------------------------------
%% do_attribute_type_of(Nref, AtAttrNref) ->
%%     {ok, name | literal | relationship}
%%   | {error, not_found | not_an_attribute | no_attribute_type | term()}
%%-----------------------------------------------------------------------------
do_attribute_type_of(Nref, AtAttrNref) ->
	F = fun() -> mnesia:read(nodes, Nref) end,
	case mnesia:transaction(F) of
		{atomic, [#node{kind = attribute, attribute_value_pairs = AVPs}]} ->
			case find_attribute_type_value(AtAttrNref, AVPs) of
				{ok, Kind}  -> {ok, Kind};
				not_found   -> {error, no_attribute_type}
			end;
		{atomic, [_Other]} -> {error, not_an_attribute};
		{atomic, []}       -> {error, not_found};
		{aborted, Reason}  -> {error, Reason}
	end.

find_attribute_type_value(_AtAttrNref, []) ->
	not_found;
find_attribute_type_value(AtAttrNref,
		[#{attribute := AtAttrNref, value := V} | _]) ->
	{ok, V};
find_attribute_type_value(AtAttrNref, [_ | Rest]) ->
	find_attribute_type_value(AtAttrNref, Rest).


%%-----------------------------------------------------------------------------
%% retro_stamp_bootstrap_attribute_types(AtAttrNref) -> ok
%%
%% Idempotently stamps `#{attribute => AtAttrNref, value => Kind}` on
%% every attribute-kind node missing this AVP.  Kind is determined by
%% walking the parents cache up to one of the three top-level subtrees:
%%   nref  6  Names         -> name
%%   nref  7  Literals      -> literal
%%   nref  8  Relationships -> relationship
%% Nodes 6, 7, 8 themselves are special-cased to their own kind.  Nodes
%% that cannot be classified (no path to 6/7/8) are skipped silently.
%%
%% Mirrors `ensure_template_avp_marker/1`: bootstrap.terms cannot include
%% the AVP because the keying attribute itself is seeded at runtime, so
%% the stamp must be applied post-seed.
%%-----------------------------------------------------------------------------
retro_stamp_bootstrap_attribute_types(AtAttrNref) ->
	Txn = fun() ->
		Attrs = mnesia:match_object(nodes,
			#node{_ = '_', kind = attribute}, read),
		lists:foreach(
			fun(N) -> stamp_attribute_type_if_missing(N, AtAttrNref) end,
			Attrs)
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{atomic, _Other}  -> ok;
		{aborted, Reason} -> throw({error, Reason})
	end.

stamp_attribute_type_if_missing(#node{nref = Nref,
		attribute_value_pairs = AVPs} = Node, AtAttrNref) ->
	case has_attribute_type_avp(AVPs, AtAttrNref) of
		true ->
			ok;
		false ->
			case classify_attribute_node(Nref, []) of
				undefined ->
					ok;
				Kind ->
					NewAVP = #{attribute => AtAttrNref, value => Kind},
					Updated = Node#node{
						attribute_value_pairs = AVPs ++ [NewAVP]
					},
					ok = mnesia:write(nodes, Updated, write)
			end
	end.

has_attribute_type_avp(AVPs, AtAttrNref) ->
	lists:any(fun
		(#{attribute := A}) -> A =:= AtAttrNref;
		(_) -> false
	end, AVPs).

%% classify_attribute_node(Nref, Visited) -> name | literal | relationship | undefined
%%
%% Walks the parents cache to determine which top-level attribute
%% subtree (6/7/8) the node belongs to.  Must run inside a Mnesia
%% transaction.  Visited list guards against cycles in malformed data.
classify_attribute_node(?NREF_NAMES,         _Visited) -> name;
classify_attribute_node(?NREF_LITERALS,      _Visited) -> literal;
classify_attribute_node(?NREF_RELATIONSHIPS, _Visited) -> relationship;
classify_attribute_node(Nref, Visited) ->
	case lists:member(Nref, Visited) of
		true ->
			undefined;
		false ->
			case mnesia:read(nodes, Nref) of
				[#node{parents = []}]      -> undefined;
				[#node{parents = [P | _]}] ->
					classify_attribute_node(P, [Nref | Visited]);
				[]                         -> undefined
			end
	end.


%%-----------------------------------------------------------------------------
%% ensure_template_avp_marker(RelAvpAttrNref) -> ok
%%
%% Idempotently stamps `#{attribute => RelAvpAttrNref, value => true}` on
%% the bootstrap-seeded `Template` attribute node (nref 31).  This marks
%% the Template AVP as a relationship-AVP, distinguishing it from
%% literal/name attributes.  bootstrap.terms cannot include this AVP
%% because the flag-attribute itself (`relationship_avp`) is seeded at
%% runtime, so the nref is unknown until init/1.
%%-----------------------------------------------------------------------------
ensure_template_avp_marker(RelAvpAttrNref) ->
	Txn = fun() ->
		case mnesia:read(nodes, ?ARC_TEMPLATE) of
			[#node{attribute_value_pairs = AVPs} = Node] ->
				Already = lists:any(fun
					(#{attribute := A, value := true}) -> A =:= RelAvpAttrNref;
					(_) -> false
				end, AVPs),
				case Already of
					true ->
						ok;
					false ->
						NewAVP = #{attribute => RelAvpAttrNref, value => true},
						Updated = Node#node{
							attribute_value_pairs = AVPs ++ [NewAVP]
						},
						ok = mnesia:write(nodes, Updated, write)
				end;
			[] ->
				throw({error, {template_avp_node_missing, ?ARC_TEMPLATE}})
		end
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> throw({error, Reason})
	end.
