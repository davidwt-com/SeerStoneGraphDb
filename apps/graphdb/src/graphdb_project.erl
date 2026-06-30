%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-06-29
%% Description: Project registry module (SP1 — Reference & Namespace
%%              Model).  Provides register_project/1 to create a
%%              project anchor node in the environment under the
%%              Projects category (nref 5), and is_project/1 to
%%              test whether an nref names a registered project.
%%
%%              This is a plain module — not a gen_server.  All
%%              functions run in the caller's process.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-06-29 Author: David W. Thomas (david@davidwt.com)
%% Initial implementation: SP1 project registry.
%%---------------------------------------------------------------------

-module(graphdb_project).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: PA1 ').
-created('Date: 2026-06-29').
-created_by('david@davidwt.com').


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
-define(NYI(X), (begin
	io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
	exit(nyi)
end)).
-define(UEM(F, X), (begin
	io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
	exit(uem)
end)).


%%---------------------------------------------------------------------
%% Record definitions (inline — no shared graphdb records header)
%%---------------------------------------------------------------------
-record(node, {
	nref,
	kind,
	parents = [],
	classes = [],
	attribute_value_pairs
}).

-record(relationship, {
	id,
	kind,
	source_nref,
	characterization,
	target_nref,
	reciprocal,
	avps
}).


%%---------------------------------------------------------------------
%% Exports
%%---------------------------------------------------------------------
-export([register_project/1, is_project/1, open_session/1, session_project/1]).


%%=====================================================================
%% Public API
%%=====================================================================

%%---------------------------------------------------------------------
%% register_project(Name) -> {ok, ProjectNref} | {error, term()}
%%
%% Creates a kind=instance node in the environment under the Projects
%% category (nref 5) via a pair of category composition arcs, then
%% returns the new node's nref.
%%
%% The nref and rel-id pair are allocated OUTSIDE the transaction fun:
%% calling gen_servers (graphdb_nref, rel_id_server) inside a Mnesia
%% activity is a latent deadlock — load-bearing invariant in this
%% codebase.
%%---------------------------------------------------------------------
register_project(Name) when is_list(Name) ->
	Nref = graphdb_nref:get_next(),
	{Id1, Id2} = rel_id_server:get_id_pair(),
	NameAVP = #{attribute => ?NAME_ATTR_INSTANCE, value => Name},
	Node = #node{nref = Nref, kind = instance,
				 parents = [?NREF_PROJECTS],
				 attribute_value_pairs = [NameAVP]},
	P2C = #relationship{id = Id1, kind = composition,
						source_nref = ?NREF_PROJECTS,
						characterization = ?ARC_CAT_CHILD,
						target_nref = Nref, reciprocal = ?ARC_CAT_PARENT,
						avps = []},
	C2P = #relationship{id = Id2, kind = composition,
						source_nref = Nref,
						characterization = ?ARC_CAT_PARENT,
						target_nref = ?NREF_PROJECTS, reciprocal = ?ARC_CAT_CHILD,
						avps = []},
	Fun = fun() ->
		ok = mnesia:write(nodes, Node, write),
		ok = mnesia:write(relationships, P2C, write),
		ok = mnesia:write(relationships, C2P, write),
		Nref
	end,
	graphdb_mgr:transaction(Fun).


%%---------------------------------------------------------------------
%% is_project(Nref) -> boolean()
%%
%% Returns true iff the node at Nref has ?NREF_PROJECTS (5) in its
%% parents cache — i.e. it was registered as a project anchor node.
%%---------------------------------------------------------------------
is_project(Nref) ->
	case graphdb_mgr:get_node(Nref) of
		{ok, #node{parents = Parents}} -> lists:member(?NREF_PROJECTS, Parents);
		_                              -> false
	end.


%%---------------------------------------------------------------------
%% open_session(ProjectNref) -> {ok, Session} | {error, not_a_project}
%%
%% Opens a session on a registered project. Returns an opaque Session map
%% if the nref is a registered project, otherwise {error, not_a_project}.
%% Session is #{kind => project_session, project => Nref}.
%%---------------------------------------------------------------------
open_session(ProjectNref) ->
	case is_project(ProjectNref) of
		true  -> {ok, #{kind => project_session, project => ProjectNref}};
		false -> {error, not_a_project}
	end.


%%---------------------------------------------------------------------
%% session_project(Session) -> ProjectNref
%%
%% Extracts the project nref from an opaque session map.
%%---------------------------------------------------------------------
session_project(#{kind := project_session, project := Nref}) -> Nref.
