%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_mgr is the manager for the graph database.
%%				graphdb_mgr coordinates graph database operations and
%%				acts as the primary interface for the graphdb subsystem.
%%				On startup, triggers the bootstrap loader to initialize
%%				the Mnesia schema and load the bootstrap scaffold.
%%				Enforces the category node immutability constraint.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Startup wiring: bootstrap detection in init/1, public API skeleton,
%% category immutability guard, read operations (get_node/1,
%% get_relationships/1,2).  Write operations delegate to workers
%% (graphdb_attr, graphdb_class, graphdb_instance) -- stubs return
%% {error, not_implemented} until those workers are implemented.
%%---------------------------------------------------------------------
%% Rev B Date: May 2026 Author: (completion of Dallas Noyes's design)
%% Write-side delegation -- create_attribute routes to
%% graphdb_attr by ParentNref subtree; create_class and create_instance
%% delegate directly to graphdb_class and graphdb_instance respectively;
%% add_relationship delegates to graphdb_instance.  delete_node and
%% update_node_avps remain not_implemented (no worker deletion/AVP-update
%% API exists yet).
%%---------------------------------------------------------------------
-module(graphdb_mgr).
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
	id,						%% integer() -- primary key (nref allocated normally)
	kind,					%% taxonomy | composition | connection | instantiation
	source_nref,			%% integer() -- arc origin
	characterization,		%% integer() -- arc label (an attribute nref)
	target_nref,			%% integer() -- arc target
	reciprocal,				%% integer() -- arc label as seen from target back
	avps					%% [#{attribute => Nref, value => term()}]
}).

-record(state, {}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		%% Read operations
		get_node/1,
		get_relationships/1,
		get_relationships/2,
		%% Write operations (delegate to workers)
		create_attribute/3,
		create_class/2,
		create_instance/3,
		add_relationship/4,
		delete_node/1,
		update_node_avps/2,
		%% Transaction helper (write-path seam)
		transaction/1,
		%% Cache invariant audit / repair
		verify_caches/0,
		rebuild_caches/0
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
%% Test-only exports (helpers for EUnit)
%%---------------------------------------------------------------------
-ifdef(TEST).
-export([
		validate_direction/1,
		check_category_guard/1
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% get_node(Nref) -> {ok, #node{}} | {error, not_found | term()}
%%
%% Reads a single node from the Mnesia nodes table by primary key.
%%-----------------------------------------------------------------------------
get_node(Nref) ->
	gen_server:call(?MODULE, {get_node, Nref}).


%%-----------------------------------------------------------------------------
%% get_relationships(Nref) -> {ok, [#relationship{}]} | {error, term()}
%%
%% Returns all outgoing relationships for the given node.
%%-----------------------------------------------------------------------------
get_relationships(Nref) ->
	gen_server:call(?MODULE, {get_relationships, Nref, outgoing}).


%%-----------------------------------------------------------------------------
%% get_relationships(Nref, Direction) -> {ok, [#relationship{}]} | {error, term()}
%%
%% Returns relationships for the given node in the specified direction.
%% Direction :: outgoing | incoming | both
%%-----------------------------------------------------------------------------
get_relationships(Nref, Direction) ->
	case validate_direction(Direction) of
		ok               -> gen_server:call(?MODULE, {get_relationships, Nref, Direction});
		{error, _} = Err -> Err
	end.


%%-----------------------------------------------------------------------------
%% create_attribute(Name, ParentNref, AVPs) -> {ok, Nref} | {error, term()}
%%
%% Creates a new attribute node in the ontology.
%% Delegates to graphdb_attr (not yet implemented).
%%
%% Transaction-like sequencing (when implemented):
%% 1. Allocate Nref via graphdb_nref:get_next/0 (outside Mnesia txn)
%% 2. Delegate to graphdb_attr to write the node record
%% 3. Return {ok, Nref}
%%-----------------------------------------------------------------------------
create_attribute(Name, ParentNref, AVPs) ->
	gen_server:call(?MODULE, {create_attribute, Name, ParentNref, AVPs}).


%%-----------------------------------------------------------------------------
%% create_class(Name, ParentClassNref) -> {ok, Nref} | {error, term()}
%%
%% Creates a new class node in the ontology.
%% Delegates to graphdb_class (not yet implemented).
%%-----------------------------------------------------------------------------
create_class(Name, ParentClassNref) ->
	gen_server:call(?MODULE, {create_class, Name, ParentClassNref}).


%%-----------------------------------------------------------------------------
%% create_instance(Name, ClassNref, ParentNref) ->
%%     {ok, Nref, report()} | {error, Reason, report()} | {error, Reason}
%%
%% Creates a new instance node and fires mandatory composition rules.
%% Delegates to graphdb_instance; propagates the 3-tuple return verbatim.
%%-----------------------------------------------------------------------------
create_instance(Name, ClassNref, ParentNref) ->
	gen_server:call(?MODULE, {create_instance, Name, ClassNref, ParentNref}).


%%-----------------------------------------------------------------------------
%% add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref) ->
%%     {ok, {Id1, Id2}} | {error, term()}
%%
%% Creates a bidirectional relationship (two directed rows).
%% Delegates to graphdb_instance (not yet implemented).
%%-----------------------------------------------------------------------------
add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref) ->
	gen_server:call(?MODULE,
		{add_relationship, SourceNref, CharNref, TargetNref, ReciprocalNref}).


%%-----------------------------------------------------------------------------
%% delete_node(Nref) -> ok | {error, term()}
%%
%% Deletes a node.  Rejects deletion of category nodes with
%% {error, category_nodes_are_immutable}.
%% Actual deletion not yet implemented.
%%-----------------------------------------------------------------------------
delete_node(Nref) ->
	gen_server:call(?MODULE, {delete_node, Nref}).


%%-----------------------------------------------------------------------------
%% update_node_avps(Nref, AVPs) -> ok | {error, term()}
%%
%% Updates the attribute-value pairs of a node.  Rejects updates to
%% category nodes with {error, category_nodes_are_immutable}.
%% Actual update not yet implemented.
%%-----------------------------------------------------------------------------
update_node_avps(Nref, AVPs) ->
	gen_server:call(?MODULE, {update_node_avps, Nref, AVPs}).


%%-----------------------------------------------------------------------------
%% transaction(Fun) -> {ok, Result} | {error, Reason}
%%
%% Runs Fun inside one Mnesia transaction and normalises the result:
%% {atomic, R} -> {ok, R}; {aborted, Reason} -> {error, Reason}.
%%
%% Fun is a tier-1 write-path primitive (or a composition of them): it
%% performs its reads/writes with bare mnesia ops, never opens its own
%% transaction, and signals a domain failure via mnesia:abort/1.  This is
%% the single transaction boundary the write-path seam standardises on;
%% see docs/designs/write-path-transaction-seam-design.md.
%%
%% This is a plain function, not a gen_server:call -- mnesia:transaction/1
%% runs in the calling process, so routing writes through the graphdb_mgr
%% server would needlessly serialise them.
%%-----------------------------------------------------------------------------
-spec transaction(fun(() -> Result)) -> {ok, Result} | {error, term()}.
transaction(Fun) ->
	case mnesia:transaction(Fun) of
		{atomic,  Result} -> {ok, Result};
		{aborted, Reason} -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% verify_caches() -> ok | {error, [{Nref, Field, Expected, Actual}, ...]}
%%
%% Scans every node and compares its hierarchy cache fields (`parents`,
%% `classes`) against the corresponding arcs in the relationships table.
%% Returns ok when every cache matches its arcs; otherwise returns the
%% complete list of mismatches.  Order-insensitive comparison.
%%
%% A failed verify is a fatal error in the "arcs authoritative; lists
%% cached" invariant -- it indicates a write path bug, not correctable
%% drift.  CT suites must call verify_caches/0 after every state-mutating
%% testcase.
%%-----------------------------------------------------------------------------
verify_caches() ->
	Txn = fun() ->
		Nrefs = mnesia:all_keys(nodes),
		lists:flatmap(fun verify_one/1, Nrefs)
	end,
	case mnesia:transaction(Txn) of
		{atomic, []}          -> ok;
		{atomic, Mismatches}  -> {error, Mismatches};
		{aborted, Reason}     -> {error, Reason}
	end.


%%-----------------------------------------------------------------------------
%% rebuild_caches() -> ok | {error, term()}
%%
%% Rewrites every node's `parents` and `classes` cache fields from the
%% authoritative relationships table.  Used as the post-load tail of
%% the bootstrap loader (Option B, H0d) and as a diagnostic repair tool.
%% After a successful rebuild, verify_caches/0 must return ok.
%%-----------------------------------------------------------------------------
rebuild_caches() ->
	Txn = fun() ->
		Nrefs = mnesia:all_keys(nodes),
		lists:foreach(fun rebuild_one/1, Nrefs),
		ok
	end,
	case mnesia:transaction(Txn) of
		{atomic, ok}      -> ok;
		{aborted, Reason} -> {error, Reason}
	end.


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init/1
%%
%% Called by graphdb_sup during startup.  Triggers the bootstrap loader
%% to ensure the Mnesia schema and tables exist and the bootstrap
%% scaffold is loaded.  Idempotent: graphdb_bootstrap:load/0 skips data
%% loading if the nodes table is already populated.
%%-----------------------------------------------------------------------------
init([]) ->
	case graphdb_bootstrap:load() of
		ok ->
			code:delete(graphdb_bootstrap),
			code:purge(graphdb_bootstrap),
			logger:info("graphdb_mgr: started, bootstrap loaded"),
			{ok, #state{}};
		{error, Reason} ->
			logger:error("graphdb_mgr: bootstrap failed: ~p", [Reason]),
			{stop, {bootstrap_failed, Reason}}
	end.


%%-----------------------------------------------------------------------------
%% handle_call/3 -- Read operations
%%-----------------------------------------------------------------------------
handle_call({get_node, Nref}, _From, State) ->
	{reply, do_get_node(Nref), State};

handle_call({get_relationships, Nref, Direction}, _From, State) ->
	{reply, do_get_relationships(Nref, Direction), State};

%%-----------------------------------------------------------------------------
%% handle_call/3 -- Write operations (delegate to workers)
%%-----------------------------------------------------------------------------
handle_call({create_attribute, Name, ParentNref, AVPs}, _From, State) ->
	%% Attribute nodes are kind=attribute -- never category, no guard needed.
	%% Route to the appropriate graphdb_attr function based on ParentNref subtree.
	{reply, do_create_attribute(Name, ParentNref, AVPs), State};

handle_call({create_class, Name, ParentClassNref}, _From, State) ->
	%% Class nodes are kind=class -- never category, no guard needed.
	{reply, graphdb_class:create_class(Name, ParentClassNref), State};

handle_call({create_instance, Name, ClassNref, ParentNref}, _From, State) ->
	%% Instance nodes are kind=instance -- never category, no guard needed.
	{reply, graphdb_instance:create_instance(Name, ClassNref, ParentNref), State};

handle_call({add_relationship, SourceNref, CharNref, TargetNref, ReciprocalNref},
		_From, State) ->
	{reply,
		graphdb_instance:add_relationship(SourceNref, CharNref, TargetNref, ReciprocalNref),
		State};

handle_call({delete_node, Nref}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			%% No worker currently implements node deletion.  The per-template
			%% attribute category enforcement (instance-only, scoped by template)
			%% is a known deferred gap for delete_node and update_node_avps.
			{reply, {error, not_implemented}, State}
	end;

handle_call({update_node_avps, Nref, _AVPs}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			%% No worker currently implements AVP-update operations.  The
			%% instance-only attribute category enforcement (per-template) is a
			%% known deferred gap for update_node_avps and create_class.
			{reply, {error, not_implemented}, State}
	end;

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
%% validate_direction(Direction) -> ok | {error, {invalid_direction, term()}}
%%
%% Validates the relationship query direction parameter.
%%-----------------------------------------------------------------------------
validate_direction(outgoing) -> ok;
validate_direction(incoming) -> ok;
validate_direction(both)     -> ok;
validate_direction(Dir)      -> {error, {invalid_direction, Dir}}.


%%-----------------------------------------------------------------------------
%% do_get_node(Nref) -> {ok, #node{}} | {error, not_found | term()}
%%
%% Reads a node from the Mnesia nodes table.
%%-----------------------------------------------------------------------------
do_get_node(Nref) ->
	case mnesia:dirty_read(nodes, Nref) of
		[Node] -> {ok, Node};
		[]     -> {error, not_found}
	end.


%%-----------------------------------------------------------------------------
%% do_get_relationships(Nref, Direction) ->
%%     {ok, [#relationship{}]} | {error, term()}
%%
%% Queries the Mnesia relationships table by direction:
%%   outgoing -- secondary index on source_nref
%%   incoming -- secondary index on target_nref
%%   both     -- union of outgoing and incoming
%%-----------------------------------------------------------------------------
do_get_relationships(Nref, outgoing) ->
	case mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.source_nref)
	end) of
		{atomic, Rels}     -> {ok, Rels};
		{aborted, Reason}  -> {error, Reason}
	end;
do_get_relationships(Nref, incoming) ->
	case mnesia:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.target_nref)
	end) of
		{atomic, Rels}     -> {ok, Rels};
		{aborted, Reason}  -> {error, Reason}
	end;
do_get_relationships(Nref, both) ->
	case {do_get_relationships(Nref, outgoing),
		  do_get_relationships(Nref, incoming)} of
		{{ok, Out}, {ok, In}} -> {ok, Out ++ In};
		{{error, _} = Err, _} -> Err;
		{_, {error, _} = Err} -> Err
	end.


%%-----------------------------------------------------------------------------
%% check_category_guard(Nref) ->
%%     ok | {error, category_nodes_are_immutable | not_found | term()}
%%
%% Checks whether the node identified by Nref is a category node.
%% Returns {error, category_nodes_are_immutable} if it is; ok otherwise.
%% Returns {error, not_found} if the node does not exist.
%%-----------------------------------------------------------------------------
check_category_guard(Nref) ->
	case do_get_node(Nref) of
		{ok, #node{kind = category}} ->
			{error, category_nodes_are_immutable};
		{ok, _} ->
			ok;
		{error, _} = Err ->
			Err
	end.


%%-----------------------------------------------------------------------------
%% Cache invariant audit / repair helpers
%%
%% Parent arc characterizations across all hierarchies (per BFS bootstrap):
%%   21 -- category compositional parent
%%   23 -- attribute compositional parent
%%   25 -- class    compositional/taxonomic parent
%%   27 -- instance compositional parent
%%
%% Instance-to-class membership (instantiation):
%%   29 -- instance -> class
%%-----------------------------------------------------------------------------
-define(PARENT_ARCS, [?ARC_CAT_PARENT, ?ARC_ATTR_PARENT, ?ARC_CLS_PARENT, ?ARC_INST_PARENT]).

%%-----------------------------------------------------------------------------
%% expected_parents(Nref) -> [integer()]
%%
%% Reads outgoing arcs from Nref of kind composition or taxonomy whose
%% characterization is one of the parent-arc labels, and returns the
%% corresponding target nrefs (the node's parent set).  Must run inside
%% an active mnesia transaction.
%%-----------------------------------------------------------------------------
expected_parents(Nref) ->
	Arcs = mnesia:index_read(relationships, Nref,
		#relationship.source_nref),
	[A#relationship.target_nref || A <- Arcs,
		(A#relationship.kind =:= composition orelse
			A#relationship.kind =:= taxonomy),
		lists:member(A#relationship.characterization, ?PARENT_ARCS)].


%%-----------------------------------------------------------------------------
%% expected_classes(Nref) -> [integer()]
%%
%% Reads outgoing instantiation arcs from Nref (char=29) and returns
%% the corresponding target class nrefs.  Non-instance nodes have no
%% instantiation arcs, so the returned list is naturally empty.  Must
%% run inside an active mnesia transaction.
%%-----------------------------------------------------------------------------
expected_classes(Nref) ->
	Arcs = mnesia:index_read(relationships, Nref,
		#relationship.source_nref),
	[A#relationship.target_nref || A <- Arcs,
		A#relationship.kind =:= instantiation,
		A#relationship.characterization =:= ?ARC_INST_TO_CLASS].


%%-----------------------------------------------------------------------------
%% verify_one(Nref) -> [{Nref, Field, Expected, Actual}]
%%
%% Compares one node's cache fields against its arcs.  Returns a list
%% of zero, one, or two mismatch tuples.  Must run inside an active
%% mnesia transaction.
%%-----------------------------------------------------------------------------
verify_one(Nref) ->
	[Node]   = mnesia:read(nodes, Nref),
	Parents  = lists:sort(expected_parents(Nref)),
	Classes  = lists:sort(expected_classes(Nref)),
	Cached_P = lists:sort(Node#node.parents),
	Cached_C = lists:sort(Node#node.classes),
	P = case Cached_P =:= Parents of
		true  -> [];
		false -> [{Nref, parents, Parents, Node#node.parents}]
	end,
	C = case Cached_C =:= Classes of
		true  -> [];
		false -> [{Nref, classes, Classes, Node#node.classes}]
	end,
	P ++ C.


%%-----------------------------------------------------------------------------
%% rebuild_one(Nref) -> ok
%%
%% Rewrites one node's cache fields from its arcs.  Must run inside an
%% active mnesia transaction.
%%-----------------------------------------------------------------------------
rebuild_one(Nref) ->
	[Node]  = mnesia:read(nodes, Nref),
	Parents = expected_parents(Nref),
	Classes = expected_classes(Nref),
	Updated = Node#node{parents = Parents, classes = Classes},
	ok = mnesia:write(nodes, Updated, write).


%%-----------------------------------------------------------------------------
%% do_create_attribute(Name, ParentNref, AVPs) -> {ok, Nref} | {error, term()}
%%
%% Routes create_attribute to the appropriate graphdb_attr function based
%% on the parent nref's position in the attribute library tree:
%%
%%   Names subtree  (6, 9-12):
%%     create_name_attribute(Name) -> {ok, Nref}
%%
%%   Literals subtree (7):
%%     create_literal_attribute(Name, Type)  where Type = maps:get(type, AVPs, string)
%%
%%   Relationships subtree (8, 13-16):
%%     If AVPs contains both reciprocal_name and target_kind:
%%       create_relationship_attribute_pair(Name, RecipName, TargetKind)
%%         -> {ok, {FwdNref, RevNref}} -- the forward nref is returned
%%     If AVPs contains neither (relationship-type grouping):
%%       create_relationship_type(Name) -> {ok, Nref}
%%     Otherwise:
%%       {error, {missing_avps, [reciprocal_name, target_kind]}}
%%
%%   Anything else:
%%     {error, {unknown_attribute_parent, ParentNref}}
%%
%% AVPs is a plain Erlang map (not a graph AVP list), e.g. #{type => integer}.
%%-----------------------------------------------------------------------------
do_create_attribute(Name, ParentNref, _AVPs)
		when ParentNref =:= 6;
		     ParentNref =:= 9; ParentNref =:= 10;
		     ParentNref =:= 11; ParentNref =:= 12 ->
	graphdb_attr:create_name_attribute(Name);

do_create_attribute(Name, 7, AVPs) ->
	Type = maps:get(type, AVPs, string),
	graphdb_attr:create_literal_attribute(Name, Type);

do_create_attribute(Name, ParentNref, AVPs)
		when ParentNref =:= 8;
		     ParentNref =:= 13; ParentNref =:= 14;
		     ParentNref =:= 15; ParentNref =:= 16 ->
	case {maps:find(reciprocal_name, AVPs), maps:find(target_kind, AVPs)} of
		{{ok, RecipName}, {ok, TargetKind}} ->
			case graphdb_attr:create_relationship_attribute_pair(Name, RecipName, TargetKind) of
				{ok, {FwdNref, _RevNref}} -> {ok, FwdNref};
				{error, _} = Err          -> Err
			end;
		{error, error} ->
			%% Neither key present -- treat as relationship-type grouping
			graphdb_attr:create_relationship_type(Name);
		_ ->
			{error, {missing_avps, [reciprocal_name, target_kind]}}
	end;

do_create_attribute(_Name, ParentNref, _AVPs) ->
	{error, {unknown_attribute_parent, ParentNref}}.
