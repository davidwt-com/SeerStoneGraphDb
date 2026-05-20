%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: graphdb_bootstrap loads the bootstrap scaffold into
%%				the Mnesia graph database on first startup.
%%				Creates the Mnesia schema and tables (nodes,
%%				relationships), reads the bootstrap.terms file,
%%				validates all terms, and writes nodes and relationship
%%				pairs to Mnesia.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial design.
%%---------------------------------------------------------------------
%% Rev A Date: April 2026 Author: (completion of Dallas Noyes's design)
%% Full implementation: Mnesia schema/table creation, bootstrap file
%% loader, node and relationship writers.
%%---------------------------------------------------------------------
-module(graphdb_bootstrap).


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
%% Include Files
%%---------------------------------------------------------------------
-include_lib("graphdb/include/graphdb_nrefs.hrl").

%%---------------------------------------------------------------------
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() — primary key
	kind,					%% category | attribute | class | instance | template
	parents = [],			%% [integer()] — cache of parent arcs (composition/taxonomy)
	classes = [],			%% [integer()] — cache of instantiation arcs (instances only)
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() — primary key (nref allocated normally)
	kind,					%% taxonomy | composition | connection | instantiation
	source_nref,			%% integer() — arc origin
	characterization,		%% integer() — arc label (an attribute nref)
	target_nref,			%% integer() — arc target
	reciprocal,				%% integer() — arc label as seen from target back
	avps					%% [#{attribute => Nref, value => term()}]
}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		load/0
		]).

%%---------------------------------------------------------------------
%% Test-only exports (pure functions for EUnit)
%%---------------------------------------------------------------------
-ifdef(TEST).
-export([
		classify_terms/1,
		sort_nodes_by_kind/1,
		validate/2,
		validate_relationships/1,
		term_to_node/1,
		expand_avps/1,
		kind_order/1,
		collect_labels/2,
		build_symbol_table/2,
		apply_symbol_table/3,
		resolve_node/2,
		resolve_rel/2,
		resolve_nref/2,
		validate_no_unresolved_labels/2
		]).
-endif.


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% load() -> ok | {error, Reason}
%%
%% Creates the Mnesia schema and tables if needed, then loads the
%% bootstrap scaffold from the bootstrap.terms file.  Called by
%% graphdb_mgr:init/1 on first startup.
%%
%% Idempotent: returns ok immediately if the nodes table is already
%% populated.
%%-----------------------------------------------------------------------------
load() ->
	try
		ok = ensure_mnesia(),
		ok = create_tables(),
		ok = wait_for_tables(),
		case mnesia:table_info(nodes, size) of
			0 -> do_load();
			_ -> ok
		end
	catch
		throw:{error, _} = Err -> Err;
		error:Reason:Stack ->
			logger:error("graphdb_bootstrap failed: ~p~n~p", [Reason, Stack]),
			{error, Reason}
	end.


%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% ensure_mnesia() -> ok
%%
%% Ensures a Mnesia schema exists on this node and Mnesia is running.
%% mnesia:create_schema/1 must be called before mnesia:start/0.
%%-----------------------------------------------------------------------------
ensure_mnesia() ->
	case mnesia:system_info(is_running) of
		yes -> ok;
		_ ->
			case mnesia:create_schema([node()]) of
				ok -> ok;
				{error, {_, {already_exists, _}}} -> ok
			end,
			case mnesia:start() of
				ok -> ok;
				{error, {already_started, mnesia}} -> ok
			end
	end,
	ok.


%%-----------------------------------------------------------------------------
%% create_tables() -> ok
%%
%% Creates the nodes and relationships Mnesia tables with disc_copies
%% storage and the required secondary indexes.  Ignores already_exists.
%%
%% Table names are plural (nodes, relationships); record names are
%% singular (node, relationship).  All Mnesia read/write operations
%% must use the explicit table-name form (e.g. mnesia:write/3).
%%-----------------------------------------------------------------------------
create_tables() ->
	NodeList = [node()],
	ok = create_table(nodes, [
		{record_name, node},
		{attributes, record_info(fields, node)},
		{disc_copies, NodeList}
	]),
	ok = create_table(relationships, [
		{record_name, relationship},
		{attributes, record_info(fields, relationship)},
		{disc_copies, NodeList},
		{index, [source_nref, target_nref]}
	]),
	ok.


%%-----------------------------------------------------------------------------
%% create_table(Name, Opts) -> ok
%%-----------------------------------------------------------------------------
create_table(Name, Opts) ->
	case mnesia:create_table(Name, Opts) of
		{atomic, ok} -> ok;
		{aborted, {already_exists, Name}} -> ok;
		{aborted, Reason} ->
			throw({error, {create_table_failed, Name, Reason}})
	end.


%%-----------------------------------------------------------------------------
%% wait_for_tables() -> ok
%%-----------------------------------------------------------------------------
wait_for_tables() ->
	case mnesia:wait_for_tables([nodes, relationships], 30000) of
		ok -> ok;
		{timeout, Tables} ->
			throw({error, {table_load_timeout, Tables}});
		{error, Reason} ->
			throw({error, {table_wait_failed, Reason}})
	end.


%%-----------------------------------------------------------------------------
%% do_load() -> ok
%%
%% Reads the bootstrap file, validates, and writes all terms to Mnesia.
%%-----------------------------------------------------------------------------
do_load() ->
	File = get_bootstrap_file(),
	logger:info("graphdb_bootstrap: loading ~s", [File]),
	case file:consult(File) of
		{ok, Terms} ->
			{NrefStart, Nodes, Rels} = classify_terms(Terms),
			ok = validate(NrefStart, Nodes),
			ok = validate_relationships(Rels),
			logger:info("graphdb_bootstrap: set_floor(~p)", [NrefStart]),
			ok = nref_server:set_floor(NrefStart),
			SymTable = build_symbol_table(Nodes, Rels),
			{ResNodes, ResRels} = apply_symbol_table(Nodes, Rels, SymTable),
			ok = validate_no_unresolved_labels(ResNodes, ResRels),
			ok = write_nodes(ResNodes),
			ok = write_relationships(ResRels),
			ok = rebuild_and_verify_caches(),
			logger:info("graphdb_bootstrap: loaded ~p nodes, ~p relationship pairs",
				[length(ResNodes), length(ResRels)]),
			ok;
		{error, Reason} ->
			throw({error, {consult_failed, File, Reason}})
	end.


%%-----------------------------------------------------------------------------
%% rebuild_and_verify_caches() -> ok
%%
%% After every node and arc has been written, populate each node's
%% parents/classes cache from the authoritative arcs and confirm the
%% resulting state satisfies the cache invariant.  A verify mismatch
%% here is a fatal startup error: the bootstrap data is internally
%% inconsistent.
%%-----------------------------------------------------------------------------
rebuild_and_verify_caches() ->
	case graphdb_mgr:rebuild_caches() of
		ok ->
			case graphdb_mgr:verify_caches() of
				ok ->
					ok;
				{error, Mismatches} ->
					throw({error, {bootstrap_cache_invariant_failed, Mismatches}})
			end;
		{error, Reason} ->
			throw({error, {rebuild_caches_failed, Reason}})
	end.


%%-----------------------------------------------------------------------------
%% get_bootstrap_file() -> string()
%%-----------------------------------------------------------------------------
get_bootstrap_file() ->
	case application:get_env(seerstone_graph_db, bootstrap_file) of
		{ok, File} -> File;
		undefined  -> throw({error, {missing_config, bootstrap_file}})
	end.


%%-----------------------------------------------------------------------------
%% classify_terms(Terms) -> {NrefStart, SortedNodes, Relationships}
%%
%% Partitions the flat term list into the nref_start value, a list of
%% node terms sorted by kind (category first), and a list of
%% relationship terms in file order.
%%-----------------------------------------------------------------------------
classify_terms(Terms) ->
	classify_terms(Terms, undefined, [], []).

classify_terms([], undefined, _Nodes, _Rels) ->
	throw({error, missing_nref_start});
classify_terms([], NrefStart, Nodes, Rels) ->
	{NrefStart, sort_nodes_by_kind(lists:reverse(Nodes)), lists:reverse(Rels)};
classify_terms([{nref_start, N} | Rest], undefined, Nodes, Rels)
		when is_integer(N), N > 0 ->
	classify_terms(Rest, N, Nodes, Rels);
classify_terms([{nref_start, N} | _Rest], undefined, _Nodes, _Rels) ->
	throw({error, {invalid_nref_start, N}});
classify_terms([{nref_start, _} | _Rest], _Already, _Nodes, _Rels) ->
	throw({error, duplicate_nref_start});
classify_terms([{node, _, _, _, _} = Node | Rest], NrefStart, Nodes, Rels) ->
	classify_terms(Rest, NrefStart, [Node | Nodes], Rels);
classify_terms([{relationship, _, _, _, _, _, _, _} = Rel | Rest], NrefStart, Nodes, Rels) ->
	classify_terms(Rest, NrefStart, Nodes, [Rel | Rels]);
classify_terms([Unknown | _Rest], _NrefStart, _Nodes, _Rels) ->
	throw({error, {unknown_term, Unknown}}).


%%-----------------------------------------------------------------------------
%% sort_nodes_by_kind(Nodes) -> SortedNodes
%%
%% Sorts nodes by kind priority: category, attribute, class, instance,
%% template.
%% Within the same kind, preserves file order (stable sort).
%%-----------------------------------------------------------------------------
sort_nodes_by_kind(Nodes) ->
	lists:sort(fun({node, _, KindA, _, _}, {node, _, KindB, _, _}) ->
		kind_order(KindA) =< kind_order(KindB)
	end, Nodes).

kind_order(category)  -> 1;
kind_order(attribute) -> 2;
kind_order(class)     -> 3;
kind_order(instance)  -> 4;
kind_order(template)  -> 5.


%%-----------------------------------------------------------------------------
%% validate(NrefStart, Nodes) -> ok
%%
%% Validates that every node nref is either an atom label (to be resolved
%% by the symbol table) or a positive integer below NrefStart, and that
%% every kind is one of the five legal atoms.
%%-----------------------------------------------------------------------------
validate(NrefStart, Nodes) ->
	lists:foreach(fun({node, Nref, Kind, _Name, _AVPs}) ->
		case Kind of
			category  -> ok;
			attribute -> ok;
			class     -> ok;
			instance  -> ok;
			template  -> ok;
			_         -> throw({error, {invalid_kind, Nref, Kind}})
		end,
		validate_nref(Nref, NrefStart)
	end, Nodes),
	ok.

validate_nref(Label, _NrefStart) when is_atom(Label) -> ok;
validate_nref(Nref, NrefStart) when is_integer(Nref), Nref > 0, Nref < NrefStart -> ok;
validate_nref(Nref, NrefStart) when is_integer(Nref), Nref > 0 ->
	throw({error, {nref_not_below_floor, Nref, NrefStart}});
validate_nref(Nref, _NrefStart) ->
	throw({error, {invalid_nref, Nref}}).


%%-----------------------------------------------------------------------------
%% validate_relationships(Rels) -> ok
%%
%% Validates that every relationship term carries a legal Kind atom.
%%-----------------------------------------------------------------------------
validate_relationships(Rels) ->
	lists:foreach(fun({relationship, _, _, _, _, _, _, Kind} = Rel) ->
		case Kind of
			taxonomy      -> ok;
			composition   -> ok;
			connection    -> ok;
			instantiation -> ok;
			_             -> throw({error, {invalid_relationship_kind, Kind, Rel}})
		end
	end, Rels),
	ok.


%%-----------------------------------------------------------------------------
%% build_symbol_table(Nodes, Rels) -> #{atom() => integer()}
%%
%% Discovers every atom label used as a node nref or AVP attribute key in
%% Nodes and Rels, allocates a fresh runtime nref for each (via
%% nref_server:get_nref/0, which is >= nref_start after set_floor), and
%% returns the label-to-nref map.  Called after set_floor so all allocated
%% nrefs land in the runtime tier.
%%-----------------------------------------------------------------------------
build_symbol_table(Nodes, Rels) ->
	Labels = collect_labels(Nodes, Rels),
	lists:foldl(fun(Label, Acc) ->
		Nref = nref_server:get_nref(),
		Acc#{Label => Nref}
	end, #{}, Labels).


%%-----------------------------------------------------------------------------
%% collect_labels(Nodes, Rels) -> [atom()]
%%
%% Returns a sorted, deduplicated list of every atom that appears as a
%% node nref or as an AVP attribute key (not AVP values) in Nodes or Rels.
%%-----------------------------------------------------------------------------
collect_labels(Nodes, Rels) ->
	NodeNrefLabels = [L || {node, L, _, _, _} <- Nodes, is_atom(L)],
	RelEndpointLabels = lists:flatten(
		[[L || L <- [N1, N2], is_atom(L)]
		 || {relationship, N1, _, _, _, N2, _, _} <- Rels]),
	AVPAttrLabels = lists:flatten(
		[[L || {L, _} <- AVPs, is_atom(L)]
		 || {node, _, _, _, AVPs} <- Nodes]),
	RelAVPLabels = lists:flatten(
		[[L || {L, _} <- AVPs1 ++ AVPs2, is_atom(L)]
		 || {relationship, _, _, AVPs1, _, _, AVPs2, _} <- Rels]),
	lists:usort(NodeNrefLabels ++ RelEndpointLabels ++ AVPAttrLabels ++ RelAVPLabels).


%%-----------------------------------------------------------------------------
%% apply_symbol_table(Nodes, Rels, SymTable) -> {ResolvedNodes, ResolvedRels}
%%
%% Substitutes every atom label in Nodes and Rels with the integer nref
%% from SymTable.  Throws {error, {undefined_label, Label}} if a label
%% is not found in the table.
%%-----------------------------------------------------------------------------
apply_symbol_table(Nodes, Rels, SymTable) ->
	ResNodes = [resolve_node(N, SymTable) || N <- Nodes],
	ResRels  = [resolve_rel(R, SymTable)  || R <- Rels],
	{ResNodes, ResRels}.


%%-----------------------------------------------------------------------------
%% resolve_node(Node, SymTable) -> ResolvedNode
%%-----------------------------------------------------------------------------
resolve_node({node, Nref, Kind, Name, AVPs}, SymTable) ->
	{node,
		resolve_nref(Nref, SymTable),
		Kind,
		Name,
		[{resolve_nref(A, SymTable), V} || {A, V} <- AVPs]}.


%%-----------------------------------------------------------------------------
%% resolve_rel(Rel, SymTable) -> ResolvedRel
%%-----------------------------------------------------------------------------
resolve_rel({relationship, N1, R1, AVPs1, R2, N2, AVPs2, Kind}, SymTable) ->
	{relationship,
		resolve_nref(N1, SymTable), R1,
		[{resolve_nref(A, SymTable), V} || {A, V} <- AVPs1],
		R2, resolve_nref(N2, SymTable),
		[{resolve_nref(A, SymTable), V} || {A, V} <- AVPs2],
		Kind}.


%%-----------------------------------------------------------------------------
%% resolve_nref(X, SymTable) -> integer()
%%
%% Passes integers through unchanged; maps atom labels via SymTable.
%%-----------------------------------------------------------------------------
resolve_nref(X, _SymTable) when is_integer(X) -> X;
resolve_nref(Label, SymTable) when is_atom(Label) ->
	case maps:find(Label, SymTable) of
		{ok, Nref} -> Nref;
		error      -> throw({error, {undefined_label, Label}})
	end.


%%-----------------------------------------------------------------------------
%% validate_no_unresolved_labels(Nodes, Rels) -> ok
%%
%% Sanity check after apply_symbol_table: throws if any atom remains as a
%% node nref or AVP attribute key.  A surviving atom means a label was in
%% a position not visited by collect_labels — a loader bug, not bad input.
%%-----------------------------------------------------------------------------
validate_no_unresolved_labels(Nodes, Rels) ->
	lists:foreach(fun({node, Nref, _, _, AVPs}) ->
		is_atom(Nref) andalso throw({error, {unresolved_label, Nref}}),
		[is_atom(A) andalso throw({error, {unresolved_label, A}}) || {A, _} <- AVPs]
	end, Nodes),
	lists:foreach(fun({relationship, N1, _, _, _, N2, _, _}) ->
		is_atom(N1) andalso throw({error, {unresolved_label, N1}}),
		is_atom(N2) andalso throw({error, {unresolved_label, N2}})
	end, Rels),
	ok.


%%-----------------------------------------------------------------------------
%% write_nodes(Nodes) -> ok
%%
%% Writes each node term to the Mnesia nodes table in a transaction.
%%-----------------------------------------------------------------------------
write_nodes(Nodes) ->
	lists:foreach(fun(NodeTerm) ->
		Record = term_to_node(NodeTerm),
		{atomic, ok} = mnesia:transaction(fun() ->
			ok = mnesia:write(nodes, Record, write)
		end)
	end, Nodes),
	ok.


%%-----------------------------------------------------------------------------
%% term_to_node(Term) -> #node{}
%%
%% Converts a bootstrap file node term to a Mnesia node record.
%% The {NameAttrNref, NameValue} pair becomes the first AVP entry;
%% the [{AttrNref, Value}] shorthand is expanded to map AVPs.
%%-----------------------------------------------------------------------------
term_to_node({node, Nref, Kind, {NameAttrNref, NameValue}, ExtraAVPs}) ->
	NameAVP = #{attribute => NameAttrNref, value => NameValue},
	Extras = [#{attribute => A, value => V} || {A, V} <- ExtraAVPs],
	#node{
		nref = Nref,
		kind = Kind,
		parents = [],
		classes = [],
		attribute_value_pairs = [NameAVP | Extras]
	}.


%%-----------------------------------------------------------------------------
%% write_relationships(Rels) -> ok
%%
%% Expands each relationship term into two directed rows and writes
%% both atomically in a single Mnesia transaction.  Each row gets a
%% unique ID from rel_id_server:get_id/0 (allocated outside the
%% transaction to avoid side-effects on retry).
%%-----------------------------------------------------------------------------
write_relationships(Rels) ->
	lists:foreach(fun(RelTerm) ->
		{Row1, Row2} = expand_relationship(RelTerm),
		{atomic, ok} = mnesia:transaction(fun() ->
			ok = mnesia:write(relationships, Row1, write),
			ok = mnesia:write(relationships, Row2, write)
		end)
	end, Rels),
	ok.


%%-----------------------------------------------------------------------------
%% expand_relationship(Term) -> {#relationship{}, #relationship{}}
%%
%% Allocates two nref IDs and expands a bidirectional relationship
%% term into two directed rows.  Both rows share the same Kind.
%%
%% {relationship, N1, R1, AVPs1, R2, N2, AVPs2, Kind} expands to:
%%   Row 1: source=N1, characterization=R1, target=N2, reciprocal=R2, kind=Kind
%%   Row 2: source=N2, characterization=R2, target=N1, reciprocal=R1, kind=Kind
%%-----------------------------------------------------------------------------
expand_relationship({relationship, N1, R1, AVPs1, R2, N2, AVPs2, Kind}) ->
	{Id1, Id2} = rel_id_server:get_id_pair(),
	Row1 = #relationship{
		id = Id1,
		kind = Kind,
		source_nref = N1,
		characterization = R1,
		target_nref = N2,
		reciprocal = R2,
		avps = expand_avps(AVPs1)
	},
	Row2 = #relationship{
		id = Id2,
		kind = Kind,
		source_nref = N2,
		characterization = R2,
		target_nref = N1,
		reciprocal = R1,
		avps = expand_avps(AVPs2)
	},
	{Row1, Row2}.


%%-----------------------------------------------------------------------------
%% expand_avps(Pairs) -> [#{attribute => Nref, value => term()}]
%%-----------------------------------------------------------------------------
expand_avps(AVPs) ->
	[#{attribute => A, value => V} || {A, V} <- AVPs].
