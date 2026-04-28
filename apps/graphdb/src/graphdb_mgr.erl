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
	kind,					%% category | attribute | class | instance
	parent,					%% integer() | undefined (undefined = root only)
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() -- primary key (nref allocated normally)
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
		update_node_avps/2
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
%% 1. Allocate Nref via nref_server:get_nref/0 (outside Mnesia txn)
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
%% create_instance(Name, ClassNref, ParentNref) -> {ok, Nref} | {error, term()}
%%
%% Creates a new instance node.  Atomically writes the node record and
%% the instance-to-class membership relationship pair (arc labels 29/30).
%% Delegates to graphdb_instance (not yet implemented).
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
handle_call({create_attribute, _Name, _ParentNref, _AVPs}, _From, State) ->
	%% Attribute nodes are kind=attribute -- never category, no guard needed.
	%% Delegation to graphdb_attr pending Task 3 implementation.
	{reply, {error, not_implemented}, State};

handle_call({create_class, _Name, _ParentClassNref}, _From, State) ->
	%% Class nodes are kind=class -- never category, no guard needed.
	%% Delegation to graphdb_class pending Task 4 implementation.
	{reply, {error, not_implemented}, State};

handle_call({create_instance, _Name, _ClassNref, _ParentNref}, _From, State) ->
	%% Instance nodes are kind=instance -- never category, no guard needed.
	%% Delegation to graphdb_instance pending Task 5 implementation.
	{reply, {error, not_implemented}, State};

handle_call({add_relationship, _SourceNref, _CharNref, _TargetNref, _ReciprocalNref},
		_From, State) ->
	%% Delegation to graphdb_instance pending Task 5 implementation.
	{reply, {error, not_implemented}, State};

handle_call({delete_node, Nref}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			%% Delegation to appropriate worker pending implementation.
			{reply, {error, not_implemented}, State}
	end;

handle_call({update_node_avps, Nref, _AVPs}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			%% Delegation to appropriate worker pending implementation.
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
	case mnesia:transaction(fun() -> mnesia:read(nodes, Nref) end) of
		{atomic, [Node]}   -> {ok, Node};
		{atomic, []}       -> {error, not_found};
		{aborted, Reason}  -> {error, Reason}
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
