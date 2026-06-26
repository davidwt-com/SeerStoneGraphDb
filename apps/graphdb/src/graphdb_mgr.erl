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

-record(state, {
	retired_nref			%% integer() | undefined -- seeded `retired`
							%% marker nref; lazily fetched from graphdb_attr
							%% on first use (graphdb_attr starts after mgr)
}).


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
		retire_node/1,
		unretire_node/1,
		update_node_avps/2,
		%% Batch write (tier-3 entry point)
		mutate/1,
		%% Tier-1 in-txn write primitive (composed by mutate/1)
		update_node_avps_in_txn/3,
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
		check_category_guard/1,
		validate_avp_updates/1,
		apply_avp_updates/2
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
%% retire_node(Nref) -> ok | {error, Reason}
%% Soft-retires a runtime node (sets the boolean `retired` marker AVP).
%% Idempotent. Refuses the permanent tier (Nref < ?NREF_START).
%%-----------------------------------------------------------------------------
retire_node(Nref) ->
	gen_server:call(?MODULE, {retire_node, Nref}).

%% unretire_node(Nref) -> ok | {error, Reason}
%% Clears the `retired` marker. Idempotent.
unretire_node(Nref) ->
	gen_server:call(?MODULE, {unretire_node, Nref}).


%%-----------------------------------------------------------------------------
%% update_node_avps(Nref, AVPs) -> ok | {error, term()}
%%
%% Merges a list of attribute-value-pair updates into a node's AVP list,
%% atomically. Each update map upserts (replace-in-place-or-append) when it
%% carries a `value` key, or deletes that attribute when it does not.
%% Well-formedness is validated client-side before the gen_server:call.
%% Rejects category nodes ({error, category_nodes_are_immutable}) and the
%% permanent tier ({error, permanent_node_immutable}).
%%-----------------------------------------------------------------------------
-spec update_node_avps(integer(), [map()]) -> ok | {error, term()}.
update_node_avps(Nref, AVPs) ->
	case validate_avp_updates(AVPs) of
		ok ->
			gen_server:call(?MODULE, {update_node_avps, Nref, AVPs});
		{error, _} = Err ->
			Err
	end.


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
%% mutate([Mutation]) -> {ok, [Result]} | {error, Reason}
%%
%% Tier-3 batch write entry point: applies an ordered list of mutations
%% ATOMICALLY in one graphdb_mgr:transaction/1, composing the write-path
%% seam's tier-1 primitives directly. All commit or none do.
%%
%% Mutation grammar (tagged tuples mirroring the public arities):
%%   {add_relationship, S, C, T, R}                       default template, no AVPs
%%   {add_relationship, S, C, T, R, Template}             explicit template nref
%%   {add_relationship, S, C, T, R, Template, {Fwd, Rev}} + per-direction AVPs
%%   {retire_node,      Nref}
%%   {unretire_node,    Nref}
%%   {update_node_avps, Nref, AVPs}                        merge/upsert AVP list
%%
%% Returns {ok, [Result]} -- one native success value per mutation in list
%% order (every op returns `ok` today, so {ok, [ok, ok, ...]}) -- or the bare
%% {error, Reason} of the first aborting mutation with the whole batch rolled
%% back. mutate([]) -> {ok, []} (no transaction opened).
%%
%% Three phases: (1) static validation -- tuple shape + the permanent-tier
%% guard, no DB, no allocation; (2) a resource pre-pass OUTSIDE the
%% transaction -- resolve the seeded attr nrefs once and allocate one rel-id
%% pair per add_relationship (gen_server calls); (3) one transaction folding
%% the prepared list in order, dispatching each to a tier-1 in-txn primitive.
%%
%% Plain function, not a gen_server:call -- mnesia:transaction/1 runs in the
%% calling process and phase 2 calls OTHER gen_servers, so routing mutate
%% through graphdb_mgr would needlessly serialise batches.
%% See docs/designs/batch-mutate-design.md.
%%-----------------------------------------------------------------------------
-spec mutate([tuple()]) -> {ok, [term()]} | {error, term()}.
mutate(Mutations) ->
	case validate_mutations(Mutations) of
		ok               -> run_mutations(Mutations);
		{error, _} = Err -> Err
	end.

%% Phase 1: static validation. No DB access, no allocation. A malformed term
%% -> {error, {bad_mutation, M}}; a permanent-tier retire/unretire ->
%% {error, permanent_node_immutable} (the same static guard set_retired/3
%% applies in the solo path).
validate_mutations([]) ->
	ok;
validate_mutations([M | Rest]) ->
	case validate_mutation(M) of
		ok               -> validate_mutations(Rest);
		{error, _} = Err -> Err
	end.

validate_mutation({add_relationship, _S, _C, _T, _R}) ->
	ok;
validate_mutation({add_relationship, _S, _C, _T, _R, _Template}) ->
	ok;
validate_mutation({add_relationship, _S, _C, _T, _R, _Template, {_Fwd, _Rev}}) ->
	ok;
validate_mutation({retire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Nref);
validate_mutation({unretire_node, Nref}) when is_integer(Nref) ->
	tier_guard(Nref);
validate_mutation({update_node_avps, Nref, AVPs}) when is_integer(Nref) ->
	case validate_avp_updates(AVPs) of
		ok               -> tier_guard(Nref);
		{error, _} = Err -> Err
	end;
validate_mutation(M) ->
	{error, {bad_mutation, M}}.

tier_guard(Nref) when Nref >= ?NREF_START -> ok;
tier_guard(_Nref)                         -> {error, permanent_node_immutable}.

%% Phases 2 + 3. Precondition: Mutations already passed validate_mutations/1.
%% Empty batch short-circuits with no transaction.
run_mutations([]) ->
	{ok, []};
run_mutations(Mutations) ->
	%% Phase 2 (outside the transaction): resolve the seeded attr nrefs once,
	%% and allocate one rel-id pair per add_relationship.
	{ok, #{target_kind := TkAttr, retired := RetAttr}} =
		graphdb_attr:seeded_nrefs(),
	Prepared = [prepare(M) || M <- Mutations],
	%% Phase 3: one transaction folding the prepared list in order.
	graphdb_mgr:transaction(fun() ->
		[dispatch(P, TkAttr, RetAttr) || P <- Prepared]
	end).

%% Phase 2 per-mutation prep. Allocates one rel-id pair per add_relationship
%% via rel_id_server (a gen_server call -- MUST stay outside the transaction)
%% and normalises each add_relationship to the explicit
%% (TemplateSpec, AVPSpec) form. retire/unretire need no resources.
%% Prepared add_relationship shape:
%%   {add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec}
prepare({add_relationship, S, C, T, R}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		default, {[], []}};
prepare({add_relationship, S, C, T, R, Template}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		Template, {[], []}};
prepare({add_relationship, S, C, T, R, Template, AVPSpec}) ->
	{add_relationship, rel_id_server:get_id_pair(), S, C, T, R,
		Template, AVPSpec};
prepare({retire_node, _Nref} = M) ->
	M;
prepare({unretire_node, _Nref} = M) ->
	M;
prepare({update_node_avps, _Nref, _AVPs} = M) ->
	M.

%% Phase 3 dispatch. Runs INSIDE the transaction: no gen_server calls, no
%% transaction/1, no rel-id allocation here (all done in phase 2). Each
%% tier-1 primitive returns ok or calls mnesia:abort/1.
dispatch({add_relationship, IdPair, S, C, T, R, TemplateSpec, AVPSpec},
		TkAttr, RetAttr) ->
	graphdb_instance:add_relationship_in_txn(IdPair, S, C, T, R, TemplateSpec,
		AVPSpec, TkAttr, RetAttr);
dispatch({retire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Nref, true, RetAttr);
dispatch({unretire_node, Nref}, _TkAttr, RetAttr) ->
	set_retired_(Nref, false, RetAttr);
dispatch({update_node_avps, Nref, AVPs}, _TkAttr, RetAttr) ->
	update_node_avps_in_txn(Nref, AVPs, RetAttr).


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
	case graphdb_mgr:transaction(Txn) of
		{ok, []}            -> ok;
		{ok, Mismatches}    -> {error, Mismatches};
		{error, _} = Err    -> Err
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
	case graphdb_mgr:transaction(Txn) of
		{ok, ok}         -> ok;
		{error, _} = Err -> Err
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
handle_call({get_node, Nref}, _From, State0) ->
	case do_get_node(Nref) of
		{ok, Node} ->
			{Reply, State} = case has_true_avp(Node) of
				false ->
					{{ok, Node}, State0};
				true ->
					{RetAttr, State1} = ensure_retired_nref(State0),
					R = case is_retired_avp_present(Node, RetAttr) of
						true  -> {error, retired};
						false -> {ok, Node}
					end,
					{R, State1}
			end,
			{reply, Reply, State};
		{error, _} = Err ->
			{reply, Err, State0}
	end;

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

handle_call({retire_node, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Nref, true, State0),
	{reply, Reply, State};
handle_call({unretire_node, Nref}, _From, State0) ->
	{Reply, State} = set_retired(Nref, false, State0),
	{reply, Reply, State};

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

handle_call({update_node_avps, Nref, AVPs}, _From, State) ->
	case check_category_guard(Nref) of
		{error, _} = Err ->
			{reply, Err, State};
		ok ->
			{Reply, State1} = do_update_node_avps(Nref, AVPs, State),
			{reply, Reply, State1}
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
	graphdb_mgr:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.source_nref)
	end);
do_get_relationships(Nref, incoming) ->
	graphdb_mgr:transaction(fun() ->
		mnesia:index_read(relationships, Nref, #relationship.target_nref)
	end);
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
%% set_retired(Nref, Bool, State) -> {ok | {error, Reason}, State'}
%%
%% Tier-2 wrapper. Static arithmetic guard refuses the whole permanent tier
%% (Nref < ?NREF_START); otherwise lazily resolves the seeded `retired`
%% nref (caching it in State) and runs the tier-1 primitive through the
%% transaction seam. Returns the possibly-updated State so the cache sticks.
%%-----------------------------------------------------------------------------
set_retired(Nref, _Bool, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
set_retired(Nref, Bool, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> set_retired_(Nref, Bool, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.

%%-----------------------------------------------------------------------------
%% ensure_retired_nref(State) -> {RetAttr, State'}
%%
%% Lazily fetches the seeded `retired` nref from graphdb_attr the first
%% time it is needed and caches it in State. graphdb_attr is started after
%% graphdb_mgr, so this cannot be done at init/1.
%%-----------------------------------------------------------------------------
ensure_retired_nref(#state{retired_nref = undefined} = State) ->
	{ok, #{retired := RetAttr}} = graphdb_attr:seeded_nrefs(),
	{RetAttr, State#state{retired_nref = RetAttr}};
ensure_retired_nref(#state{retired_nref = RetAttr} = State) ->
	{RetAttr, State}.

%%-----------------------------------------------------------------------------
%% set_retired_(Nref, Bool, RetAttr) -> ok
%% Tier-1 primitive. Must run inside an active mnesia transaction. Reads the
%% node under a write lock, rewrites its AVP list so the `retired` marker
%% reflects Bool, writes it back. Aborts with not_found if absent.
%%-----------------------------------------------------------------------------
set_retired_(Nref, Bool, RetAttr) ->
	case mnesia:read(nodes, Nref, write) of
		[]     -> mnesia:abort(not_found);
		[Node] ->
			AVPs0 = Node#node.attribute_value_pairs,
			AVPs1 = set_marker(AVPs0, RetAttr, Bool),
			mnesia:write(nodes,
				Node#node{attribute_value_pairs = AVPs1}, write)
	end.

%%-----------------------------------------------------------------------------
%% do_update_node_avps(Nref, AVPs, State) -> {ok | {error, Reason}, State'}
%%
%% Tier-2 body. Static permanent-tier guard refuses the whole permanent tier
%% (Nref < ?NREF_START); otherwise lazily resolves the seeded `retired` nref
%% (caching it in State) and runs the tier-1 primitive through the
%% transaction seam. Returns the possibly-updated State so the cache sticks.
%% Precondition: AVPs already passed validate_avp_updates/1 (client-side) and
%% Nref passed check_category_guard/1.
%%-----------------------------------------------------------------------------
do_update_node_avps(Nref, _AVPs, State) when Nref < ?NREF_START ->
	{{error, permanent_node_immutable}, State};
do_update_node_avps(Nref, AVPs, State0) ->
	{RetAttr, State} = ensure_retired_nref(State0),
	Reply = case graphdb_mgr:transaction(
				fun() -> update_node_avps_in_txn(Nref, AVPs, RetAttr) end) of
		{ok, ok}     -> ok;
		{error, _}=E -> E
	end,
	{Reply, State}.

%%-----------------------------------------------------------------------------
%% update_node_avps_in_txn(Nref, AVPs, RetAttr) -> ok
%% Tier-1 primitive. Must run inside an active mnesia transaction. Reads the
%% node under a write lock; aborts not_found if absent. Aborts use_retire_api
%% if any update targets the seeded `retired` attribute. Aborts
%% {unknown_attribute, A} if any UPSERT references a non-attribute node.
%% Applies the merge and writes the node back. RetAttr is resolved by the
%% caller OUTSIDE the transaction (load-bearing: no gen_server call in-txn).
%%-----------------------------------------------------------------------------
update_node_avps_in_txn(Nref, AVPs, RetAttr) ->
	case mnesia:read(nodes, Nref, write) of
		[] ->
			mnesia:abort(not_found);
		[Node] ->
			ok = guard_retired_marker(AVPs, RetAttr),
			ok = guard_attribute_existence(AVPs),
			New = apply_avp_updates(Node#node.attribute_value_pairs, AVPs),
			mnesia:write(nodes, Node#node{attribute_value_pairs = New}, write)
	end.

%% Abort if any update (upsert or delete) targets the seeded `retired` attr.
guard_retired_marker(AVPs, RetAttr) ->
	case lists:any(fun(#{attribute := A}) -> A =:= RetAttr end, AVPs) of
		true  -> mnesia:abort(use_retire_api);
		false -> ok
	end.

%% Abort if any UPSERT references a node that is not an existing attribute
%% node. Deletes (no `value` key) are skipped -- removing a reference does
%% not require the attribute to still exist.
guard_attribute_existence(AVPs) ->
	Upserts = [A || #{attribute := A} = M <- AVPs, maps:is_key(value, M)],
	lists:foreach(fun(A) ->
		case mnesia:read(nodes, A, read) of
			[#node{kind = attribute}] -> ok;
			_                         -> mnesia:abort({unknown_attribute, A})
		end
	end, Upserts),
	ok.

%%-----------------------------------------------------------------------------
%% set_marker(AVPs, RetAttr, Bool) -> AVPs'
%% Removes any existing `retired` AVP; if Bool is true, appends a fresh
%% #{attribute => RetAttr, value => true}. Setting false leaves it removed.
%%-----------------------------------------------------------------------------
set_marker(AVPs, RetAttr, Bool) ->
	Stripped = [P || P <- AVPs, not is_retired_avp(P, RetAttr)],
	case Bool of
		true  -> Stripped ++ [#{attribute => RetAttr, value => true}];
		false -> Stripped
	end.

is_retired_avp(#{attribute := A}, RetAttr) -> A =:= RetAttr;
is_retired_avp(_, _)                       -> false.

%%-----------------------------------------------------------------------------
%% has_true_avp(Node) -> boolean()
%% Quick pre-filter: true iff the node has any AVP with value => true.
%% Used by the get_node handle_call to short-circuit the ensure_retired_nref
%% lookup on ordinary (non-retired) reads, keeping get_node callable without
%% graphdb_attr running (e.g. read_ops tests that start only graphdb_mgr).
%%-----------------------------------------------------------------------------
has_true_avp(#node{attribute_value_pairs = AVPs}) ->
	lists:any(fun
		(#{value := true}) -> true;
		(_)                -> false
	end, AVPs).

%%-----------------------------------------------------------------------------
%% is_retired_avp_present(Node, RetAttr) -> boolean()
%% True iff Node carries the `retired` boolean marker AVP
%% (attribute=RetAttr, value=true).
%%-----------------------------------------------------------------------------
is_retired_avp_present(#node{attribute_value_pairs = AVPs}, RetAttr) ->
	lists:any(fun(#{attribute := A, value := true}) when A =:= RetAttr -> true;
				 (_) -> false
			  end, AVPs).


%%-----------------------------------------------------------------------------
%% validate_avp_updates(AVPs) -> ok | {error, {invalid_avp, term()}}
%% Pure, client-side. AVPs must be a list whose every element is a map whose
%% key set is exactly [attribute] (delete) or [attribute, value] (upsert),
%% with an integer attribute. Anything else is {invalid_avp, Offender}.
%%-----------------------------------------------------------------------------
validate_avp_updates(AVPs) when is_list(AVPs) ->
	validate_avp_updates_(AVPs);
validate_avp_updates(Other) ->
	{error, {invalid_avp, Other}}.

validate_avp_updates_([]) ->
	ok;
validate_avp_updates_([M | Rest]) ->
	case valid_avp_update(M) of
		true  -> validate_avp_updates_(Rest);
		false -> {error, {invalid_avp, M}}
	end.

valid_avp_update(#{attribute := A} = M) when is_integer(A) ->
	case lists:sort(maps:keys(M)) of
		[attribute]        -> true;   %% delete
		[attribute, value] -> true;   %% upsert
		_                  -> false
	end;
valid_avp_update(_) ->
	false.

%%-----------------------------------------------------------------------------
%% apply_avp_updates(Existing, Updates) -> NewAVPs
%% Pure. Folds each update over the AVP list, left-to-right:
%%   - update map WITH a `value` key  -> upsert: replace the matching entry
%%     in place if present, else append the new entry to the tail
%%   - update map WITHOUT a `value` key -> delete that attribute (no-op if
%%     absent)
%% Precondition: Updates already passed validate_avp_updates/1.
%%-----------------------------------------------------------------------------
apply_avp_updates(Existing, Updates) ->
	lists:foldl(fun apply_one_avp_update/2, Existing, Updates).

apply_one_avp_update(#{attribute := A} = Update, AVPs) ->
	case maps:is_key(value, Update) of
		true  -> upsert_avp(AVPs, A, maps:get(value, Update));
		false -> delete_avp(AVPs, A)
	end.

%% Replace the entry for A in place if present, else append to the tail.
upsert_avp(AVPs, A, V) ->
	New = #{attribute => A, value => V},
	case lists:any(fun(P) -> is_avp_for(P, A) end, AVPs) of
		true ->
			[case is_avp_for(P, A) of true -> New; false -> P end
				|| P <- AVPs];
		false ->
			AVPs ++ [New]
	end.

delete_avp(AVPs, A) ->
	[P || P <- AVPs, not is_avp_for(P, A)].

is_avp_for(#{attribute := A}, A) -> true;
is_avp_for(_, _)                 -> false.


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
