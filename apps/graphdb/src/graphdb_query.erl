%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: May 2026
%% Description: graphdb_query is the query-language gen_server.  It
%%              parses and executes queries against the graph and
%%              maintains snapshot-semantics sessions with a
%%              read-through cache.
%%
%%              F3 sequencing: session API (new_session/0, refresh/1)
%%              is real. Q1 (#q_get_node{}) is implemented; Q1b/Q2-Q6
%%              return {error, not_implemented} until Tasks 4-9.
%%
%% Design source: f3-graphdb-query-design.md at project root.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev A Date: May 2026 Author: David W. Thomas
%% Initial skeleton implementation (F3 Task 2).
%% Rev A.1 Date: May 2026 Author: David W. Thomas
%% Q1 (#q_get_node{}) implemented (F3 Task 3).
%%---------------------------------------------------------------------
-module(graphdb_query).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: May 2026').
-created_by('david@davidwt.com').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
-include_lib("graphdb/include/graphdb_nrefs.hrl").
-include_lib("graphdb/include/graphdb_query.hrl").


%%---------------------------------------------------------------------
%% Macro Functions
%%---------------------------------------------------------------------
-define(NYI(X), (begin
                    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
                    exit(nyi)
                 end)).
-define(UEM(F, X), (begin
                    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
                    exit(uem)
                 end)).


%%---------------------------------------------------------------------
%% Records — mirror canonical shapes (see ARCHITECTURE.md §3).
%% Defined locally so this module compiles standalone; matches the
%% pattern used in graphdb_language, graphdb_class, graphdb_instance.
%%---------------------------------------------------------------------
-record(node, {
    nref,
    kind,
    parents               = [],
    classes               = [],
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

-compile({nowarn_unused_record, [relationship]}).


%%---------------------------------------------------------------------
%% Public API
%%---------------------------------------------------------------------
-export([start_link/0]).
-export([
    parse_query/1,
    new_session/0,
    refresh/1,
    execute_query/1,
    execute_query/2,
    resume/2,
    find_path/3
]).


%%---------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).


%%=====================================================================
%% Public API implementation
%%=====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Parser is the identity until a text DSL lands.
parse_query(Term) -> Term.

new_session() ->
    #{snapshot_at => os:timestamp(),
      cache       => #{}}.

refresh(Session) when is_map(Session) ->
    Session#{snapshot_at := os:timestamp(),
             cache       := #{}}.

execute_query(Query) ->
    gen_server:call(?MODULE, {execute_query_1, Query}).

execute_query(Query, Session) when is_map(Session) ->
    gen_server:call(?MODULE, {execute_query_2, Query, Session}).

resume(Cont, Session) when is_map(Session) ->
    gen_server:call(?MODULE, {resume, Cont, Session}).

%% find_path/3 — public convenience matching the F3 task spec API.
find_path(From, To, MaxDepth) ->
    execute_query(#q_find_path{from      = From,
                               to        = To,
                               max_depth = MaxDepth,
                               arc_kinds = [composition, taxonomy,
                                            connection]}).


%%=====================================================================
%% gen_server callbacks
%%=====================================================================

init([]) ->
    {ok, #{}}.

handle_call({execute_query_1, Query}, _From, State) ->
    Session = new_session(),
    {Reply, _Session1} = dispatch(Query, Session),
    {reply, drop_session(Reply), State};
handle_call({execute_query_2, Query, Session}, _From, State) ->
    {Reply, Session1} = dispatch(Query, Session),
    {reply, attach_session(Reply, Session1), State};
handle_call({resume, _Cont, _Session}, _From, State) ->
    {reply, {error, not_implemented}, State};
handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?UEM(handle_cast, {Msg, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.


%%=====================================================================
%% Internal dispatch
%%=====================================================================

%% dispatch(Query, Session) -> {Reply, Session1}
%% Reply is {ok, _} | {ok, _, _} | {partial, _, _} | {error, _}.
dispatch(#q_get_node{nref = N}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {Node, Session1} ->
            {{ok, node_to_map(Node)}, Session1}
    end;
dispatch(_Query, Session) ->
    {{error, not_implemented}, Session}.

%%---------------------------------------------------------------------
%% session_read_node(Session, Nref) -> {Node | not_found, Session1}
%%
%% Read-through cache: a hit returns immediately; a miss reads Mnesia
%% and (if the node exists) populates the cache before returning. Misses
%% that hit Mnesia and find nothing are NOT cached — caching a negative
%% result would require threading the session on error replies, which
%% the current /2 API does not do.
%%
%% Cache key shape: {node, Nref}.
%%---------------------------------------------------------------------
session_read_node(#{cache := Cache} = Session, Nref) ->
    case maps:get({node, Nref}, Cache, miss) of
        miss ->
            case mnesia:dirty_read(nodes, Nref) of
                [Node] ->
                    Cache1 = Cache#{{node, Nref} => Node},
                    {Node, Session#{cache := Cache1}};
                [] ->
                    {not_found, Session}
            end;
        Node ->
            {Node, Session}
    end.

%%---------------------------------------------------------------------
%% node_to_map(Node) -> map()
%%
%% Project a #node{} record into the public result shape.
%%---------------------------------------------------------------------
node_to_map(#node{nref                  = N,
                  kind                  = K,
                  parents               = P,
                  classes               = C,
                  attribute_value_pairs = AVPs}) ->
    #{nref                  => N,
      kind                  => K,
      parents               => P,
      classes               => C,
      attribute_value_pairs => AVPs}.

%% drop_session — for /1 calls, strip the trailing session from the reply.
drop_session({ok, R, _S})            -> {ok, R};
drop_session({partial, R, C, _S})    -> {partial, R, C};
drop_session(Other)                  -> Other.

%% attach_session — ensure the reply ends with the post-dispatch session.
%% Handles both 2-shape replies (append session) and 3-shape replies
%% (replace whatever dispatch threaded through).
attach_session({error, _} = E, _S)    -> E;
attach_session({ok, R}, S)            -> {ok, R, S};
attach_session({partial, R, C}, S)    -> {partial, R, C, S};
attach_session({ok, R, _}, S)         -> {ok, R, S};
attach_session({partial, R, C, _}, S) -> {partial, R, C, S}.
