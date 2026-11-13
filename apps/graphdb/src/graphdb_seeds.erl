%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-11-13
%% Description: In-memory cache of every environment seed node.  A seed
%%				is a node in the permanent tier (nref < ?NREF_START):
%%				bootstrap scaffold, loader-assigned bootstrap nodes and
%%				worker init/1 seeds.  The cache lives in persistent_term
%%				and is filled once by load/0 after all graphdb workers
%%				have started; every read function touches only
%%				persistent_term, so it is safe inside an Mnesia
%%				transaction.  load/0 makes gen_server calls and must
%%				never be called inside a transaction.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-11-13 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------

-module(graphdb_seeds).
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-revision('Rev PA1').
-created('2026-11-13').
-created_by('David W. Thomas').

-compile({no_auto_import, [node/1]}).
-export([load/0, node/1, nref/1, is_seed/1, all/0, erase/0]).

%%---------------------------------------------------------------------
%% NYI / UEM Macros
%%---------------------------------------------------------------------
-define(NYI(X), (begin
	io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
	exit(nyi)
end)).
-define(UEM(F, X), (begin
	io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
	exit(uem)
end)).

-record(node, {
	nref,
	kind,
	parents              = [],
	classes              = [],
	attribute_value_pairs
}).

-define(KEY, {graphdb_seeds, cache}).


%%---------------------------------------------------------------------
%% load() -> ok | {error, {label_not_seed, Label, Nref}}
%%
%% Reads every permanent-tier node and every seed label, then stores
%% both in persistent_term.  Stores nothing on error.
%%---------------------------------------------------------------------
load() ->
	Rows = mnesia:dirty_select(nodes,
		[{#node{nref = '$1', _ = '_'}, [{'<', '$1', ?NREF_START}], ['$_']}]),
	Nodes = maps:from_list([{N#node.nref, N} || N <- Rows]),
	Labels = collect_labels(),
	case [{L, N} || {L, N} <- maps:to_list(Labels),
			not maps:is_key(N, Nodes)] of
		[] ->
			persistent_term:put(?KEY, #{nodes => Nodes, labels => Labels}),
			ok;
		[{Label, Nref} | _] ->
			{error, {label_not_seed, Label, Nref}}
	end.

%% Merge order: scaffold, attr, language, rules, remote_reference_class.
collect_labels() ->
	Scaffold = maps:from_list(
		[{A, N} || {A, N, _Kind, _Name} <- graphdb_nrefs:scaffold_spec()]),
	M0 = lists:foldl(fun({Worker, Mod}, Acc) ->
			case whereis(Worker) of
				undefined -> Acc;
				_ ->
					{ok, Map} = Mod:seeded_nrefs(),
					maps:merge(Acc, maps:filter(
						fun(_, V) -> is_integer(V) end, Map))
			end
		end, Scaffold,
		[{graphdb_attr, graphdb_attr},
		 {graphdb_language, graphdb_language},
		 {graphdb_rules, graphdb_rules}]),
	case whereis(graphdb_instance) of
		undefined -> M0;
		_ -> M0#{remote_reference_class =>
				graphdb_instance:remote_reference_class()}
	end.


%%---------------------------------------------------------------------
%% node(NrefOrLabel) -> {ok, #node{}} | not_seed
%%---------------------------------------------------------------------
node(Label) when is_atom(Label) ->
	case nref(Label) of
		{ok, Nref} -> node(Nref);
		not_seed   -> not_seed
	end;
node(Nref) when is_integer(Nref) ->
	case persistent_term:get(?KEY, undefined) of
		#{nodes := Nodes} ->
			case Nodes of
				#{Nref := Node} -> {ok, Node};
				_               -> not_seed
			end;
		undefined -> not_seed
	end.

%%---------------------------------------------------------------------
%% nref(Label) -> {ok, Nref} | not_seed
%%---------------------------------------------------------------------
nref(Label) when is_atom(Label) ->
	case persistent_term:get(?KEY, undefined) of
		#{labels := #{Label := Nref}} -> {ok, Nref};
		_                             -> not_seed
	end.

%%---------------------------------------------------------------------
%% is_seed(Nref) -> boolean()
%%---------------------------------------------------------------------
is_seed(Nref) when is_integer(Nref) ->
	case persistent_term:get(?KEY, undefined) of
		#{nodes := Nodes} -> maps:is_key(Nref, Nodes);
		undefined         -> false
	end.

%%---------------------------------------------------------------------
%% all() -> [#node{}]
%%---------------------------------------------------------------------
all() ->
	case persistent_term:get(?KEY, undefined) of
		#{nodes := Nodes} -> maps:values(Nodes);
		undefined         -> []
	end.

%%---------------------------------------------------------------------
%% erase() -> ok   (idempotent)
%%---------------------------------------------------------------------
erase() ->
	_ = persistent_term:erase(?KEY),
	ok.
