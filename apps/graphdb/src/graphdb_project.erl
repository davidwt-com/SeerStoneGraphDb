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
-export([register_project/1, is_project/1, open/1,
		require_project/1, next_nref/1, next_rel_id_pair/1,
		add_relationship/5, add_relationship/6, add_relationship/7,
		add_class_membership/3,
		remove_relationship/4, remove_relationship/5,
		update_relationship/5, update_relationship/6,
		update_relationship_both/5, update_relationship_both/6]).


%%=====================================================================
%% Public API
%%=====================================================================

%%---------------------------------------------------------------------
%% register_project(Name) -> {ok, ProjectNref} | {error, term()}
%%
%% Creates the project's anchor node (a kind=instance node in the
%% environment under the Projects category, nref 5) then its three
%% physical tables (nodes_<A>, relationships_<A>, counters_<A>).
%%
%% mnesia:create_table/2 is a schema operation and cannot run inside a
%% transaction, so table creation happens AFTER the anchor write, not
%% atomically with it. ensure_tables/1 is idempotent (already_exists is
%% not an error), so a retried register_project/1 call converges.
%%
%% The anchor's nref and rel-id pair are allocated OUTSIDE the transaction
%% fun: calling gen_servers (graphdb_nref, rel_id_server) inside a Mnesia
%% activity is a latent deadlock -- load-bearing invariant in this
%% codebase.
%%---------------------------------------------------------------------
register_project(Name) when is_list(Name) ->
	case create_anchor(Name) of
		{ok, Nref} ->
			try
				ok = ensure_tables(Nref),
				{ok, Nref}
			catch
				throw:{error, _} = Err -> Err
			end;
		{error, _} = Err ->
			Err
	end.

create_anchor(Name) ->
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
%% ensure_tables(Anchor) -> ok    (throws {error, {create_table_failed, ...}})
%%
%% Creates the project's three physical tables if absent. Mirrors
%% graphdb_bootstrap:create_tables/0's shape (disc_copies, record_info-
%% derived attributes, source_nref/target_nref index on relationships).
%% The counters table has no fixed record shape -- it is looked up by a
%% bare {Key, Value} tuple via mnesia:dirty_update_counter/3.
%%---------------------------------------------------------------------
ensure_tables(Anchor) ->
	NodeList = [node()],
	ok = ensure_table(nodes_table(Anchor), [
		{record_name, node},
		{attributes, record_info(fields, node)},
		{disc_copies, NodeList}
	]),
	ok = ensure_table(rels_table(Anchor), [
		{record_name, relationship},
		{attributes, record_info(fields, relationship)},
		{disc_copies, NodeList},
		{index, [source_nref, target_nref]}
	]),
	ok = ensure_table(counters_table(Anchor), [
		{disc_copies, NodeList}
	]),
	ok.

ensure_table(Name, Opts) ->
	case mnesia:create_table(Name, Opts) of
		{atomic, ok}                       -> ok;
		{aborted, {already_exists, Name}}  -> ok;
		{aborted, Reason} ->
			throw({error, {create_table_failed, Name, Reason}})
	end.

nodes_table(Anchor)    -> list_to_atom("nodes_" ++ integer_to_list(Anchor)).
rels_table(Anchor)     -> list_to_atom("relationships_" ++ integer_to_list(Anchor)).
counters_table(Anchor) -> list_to_atom("counters_" ++ integer_to_list(Anchor)).


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
%% open(ProjectNref) ->
%%     {ok, Project} | {error, not_a_project} | {error, no_store}
%%
%% Resolves a registered project's nref into its physical store handle.
%% {error, no_store} covers an anchor that predates SP2 (registered, but
%% without tables); SP4's migration resolves that state -- open/1 reports
%% it rather than silently creating an empty store.
%%---------------------------------------------------------------------
open(ProjectNref) ->
	case is_project(ProjectNref) of
		false ->
			{error, not_a_project};
		true ->
			case tables_exist(ProjectNref) of
				true ->
					{ok, #{anchor   => ProjectNref,
						   nodes    => nodes_table(ProjectNref),
						   rels     => rels_table(ProjectNref),
						   counters => counters_table(ProjectNref)}};
				false ->
					{error, no_store}
			end
	end.

tables_exist(Anchor) ->
	lists:member(nodes_table(Anchor), mnesia:system_info(tables)).


%%---------------------------------------------------------------------
%% require_project(Project) -> ok | {error, invalid_project}
%%
%% Gate for project-scoped operations: a well-formed Project handle
%% passes; any other term is rejected. Pure (no store access) -- the
%% handle was already validated against the registry by open/1.
%%---------------------------------------------------------------------
require_project(#{anchor := _, nodes := _, rels := _, counters := _}) -> ok;
require_project(_)                                                    ->
	{error, invalid_project}.


%%---------------------------------------------------------------------
%% next_nref(Project) -> pos_integer()
%% next_rel_id_pair(Project) -> {pos_integer(), pos_integer()}
%%
%% Project-local allocators. mnesia:dirty_update_counter/3 on a key that
%% has never been written creates it with the increment as its value, so
%% the first call to either yields the low end of the unbounded monotonic
%% space -- no seeding needed at register_project/1 time. Dirty ops do not
%% participate in a surrounding transaction; callers must invoke these
%% OUTSIDE any transaction fun, same discipline as graphdb_nref:get_next/0
%% and rel_id_server:get_id_pair/0 for the environment.
%%---------------------------------------------------------------------
next_nref(#{counters := Counters}) ->
	mnesia:dirty_update_counter(Counters, nref, 1).

next_rel_id_pair(#{counters := Counters}) ->
	Id2 = mnesia:dirty_update_counter(Counters, rel_id, 2),
	{Id2 - 1, Id2}.


%%=====================================================================
%% Canonical project-scoped relationship API (SP1 §8 relocation).
%%
%% These are the project side of the environment/project split: they
%% take a Project handle as the first argument and delegate to the
%% graphdb_instance implementations.  The handle is validated inside
%% graphdb_instance via require_project/1.
%%=====================================================================

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateNref).

add_relationship(Project, SourceNref, CharNref, TargetNref, ReciprocalNref,
		TemplateNref, AVPSpec) ->
	graphdb_instance:add_relationship(Project, SourceNref, CharNref,
		TargetNref, ReciprocalNref, TemplateNref, AVPSpec).

add_class_membership(Project, InstanceNref, ClassNref) ->
	graphdb_instance:add_class_membership(Project, InstanceNref, ClassNref).

remove_relationship(Project, SourceNref, CharNref, TargetNref) ->
	graphdb_instance:remove_relationship(Project, SourceNref, CharNref,
		TargetNref).

remove_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref) ->
	graphdb_instance:remove_relationship(Project, SourceNref, CharNref,
		TargetNref, TemplateNref).

update_relationship(Project, SourceNref, CharNref, TargetNref, Updates) ->
	graphdb_instance:update_relationship(Project, SourceNref, CharNref,
		TargetNref, Updates).

update_relationship(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		Updates) ->
	graphdb_instance:update_relationship(Project, SourceNref, CharNref,
		TargetNref, TemplateNref, Updates).

update_relationship_both(Project, SourceNref, CharNref, TargetNref, Pair) ->
	graphdb_instance:update_relationship_both(Project, SourceNref, CharNref,
		TargetNref, Pair).

update_relationship_both(Project, SourceNref, CharNref, TargetNref, TemplateNref,
		Pair) ->
	graphdb_instance:update_relationship_both(Project, SourceNref, CharNref,
		TargetNref, TemplateNref, Pair).
