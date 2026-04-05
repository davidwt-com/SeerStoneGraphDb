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
%% Record Definitions
%%---------------------------------------------------------------------
-record(node, {
	nref,					%% integer() — primary key
	kind,					%% category | attribute | class | instance
	parent,					%% integer() | undefined (undefined = root only)
	attribute_value_pairs	%% [#{attribute => Nref, value => term()}]
}).

-record(relationship, {
	id,						%% integer() — primary key (nref allocated normally)
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
		term_to_node/1,
		expand_avps/1,
		kind_order/1
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
		{disc_copies, NodeList},
		{index, [parent]}
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
			logger:info("graphdb_bootstrap: set_floor(~p)", [NrefStart]),
			ok = nref_server:set_floor(NrefStart),
			ok = write_nodes(Nodes),
			ok = write_relationships(Rels),
			logger:info("graphdb_bootstrap: loaded ~p nodes, ~p relationship pairs",
				[length(Nodes), length(Rels)]),
			ok;
		{error, Reason} ->
			throw({error, {consult_failed, File, Reason}})
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
classify_terms([{node, _, _, _, _, _} = Node | Rest], NrefStart, Nodes, Rels) ->
	classify_terms(Rest, NrefStart, [Node | Nodes], Rels);
classify_terms([{relationship, _, _, _, _, _, _} = Rel | Rest], NrefStart, Nodes, Rels) ->
	classify_terms(Rest, NrefStart, Nodes, [Rel | Rels]);
classify_terms([Unknown | _Rest], _NrefStart, _Nodes, _Rels) ->
	throw({error, {unknown_term, Unknown}}).


%%-----------------------------------------------------------------------------
%% sort_nodes_by_kind(Nodes) -> SortedNodes
%%
%% Sorts nodes by kind priority: category, attribute, class, instance.
%% Within the same kind, preserves file order (stable sort).
%%-----------------------------------------------------------------------------
sort_nodes_by_kind(Nodes) ->
	lists:sort(fun({node, _, KindA, _, _, _}, {node, _, KindB, _, _, _}) ->
		kind_order(KindA) =< kind_order(KindB)
	end, Nodes).

kind_order(category)  -> 1;
kind_order(attribute) -> 2;
kind_order(class)     -> 3;
kind_order(instance)  -> 4.


%%-----------------------------------------------------------------------------
%% validate(NrefStart, Nodes) -> ok
%%
%% Validates that every node nref is a positive integer below NrefStart
%% and every kind is one of the four legal atoms.
%%-----------------------------------------------------------------------------
validate(NrefStart, Nodes) ->
	lists:foreach(fun({node, Nref, Kind, _Parent, _Name, _AVPs}) ->
		case Kind of
			category  -> ok;
			attribute -> ok;
			class     -> ok;
			instance  -> ok;
			_         -> throw({error, {invalid_kind, Nref, Kind}})
		end,
		case is_integer(Nref) andalso Nref > 0 of
			true  -> ok;
			false -> throw({error, {invalid_nref, Nref}})
		end,
		case Nref < NrefStart of
			true  -> ok;
			false -> throw({error, {nref_not_below_floor, Nref, NrefStart}})
		end
	end, Nodes),
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
term_to_node({node, Nref, Kind, Parent, {NameAttrNref, NameValue}, ExtraAVPs}) ->
	NameAVP = #{attribute => NameAttrNref, value => NameValue},
	Extras = [#{attribute => A, value => V} || {A, V} <- ExtraAVPs],
	#node{
		nref = Nref,
		kind = Kind,
		parent = Parent,
		attribute_value_pairs = [NameAVP | Extras]
	}.


%%-----------------------------------------------------------------------------
%% write_relationships(Rels) -> ok
%%
%% Expands each relationship term into two directed rows and writes
%% both atomically in a single Mnesia transaction.  Each row gets a
%% unique ID from nref_server:get_nref/0 (allocated outside the
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
%% term into two directed rows.
%%
%% {relationship, N1, R1, AVPs1, R2, N2, AVPs2} expands to:
%%   Row 1: source=N1, characterization=R1, target=N2, reciprocal=R2
%%   Row 2: source=N2, characterization=R2, target=N1, reciprocal=R1
%%-----------------------------------------------------------------------------
expand_relationship({relationship, N1, R1, AVPs1, R2, N2, AVPs2}) ->
	Id1 = nref_server:get_nref(),
	Id2 = nref_server:get_nref(),
	Row1 = #relationship{
		id = Id1,
		source_nref = N1,
		characterization = R1,
		target_nref = N2,
		reciprocal = R2,
		avps = expand_avps(AVPs1)
	},
	Row2 = #relationship{
		id = Id2,
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
