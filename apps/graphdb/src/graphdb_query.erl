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
%%              is real. Q1 (#q_get_node{}), Q1b (#q_get_arcs{}), and
%%              Q2 (#q_describe{} for kind=attribute) are implemented;
%%              Q3-Q6 return {error, not_implemented} until Tasks 6-9.
%%
%% Design source: f3-graphdb-query-design.md at project root.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev A Date: May 2026 Author: David W. Thomas
%% Initial skeleton implementation (F3 Task 2).
%% Rev A.1 Date: May 2026 Author: David W. Thomas
%% Q1 (#q_get_node{}) implemented (F3 Task 3).
%% Rev A.2 Date: May 2026 Author: David W. Thomas
%% Q1b (#q_get_arcs{}) implemented (F3 Task 4).
%% Rev A.3 Date: May 2026 Author: David W. Thomas
%% Q2 (#q_describe{} for kind=attribute) implemented (F3 Task 5).
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
dispatch(#q_get_arcs{nref = N, direction = Dir, arc_kinds = Kinds},
         Session) ->
    {Arcs, Session1} = session_read_arcs(Session, N, Dir, Kinds),
    {{ok, [arc_to_map(A) || A <- Arcs]}, Session1};
dispatch(#q_describe{nref = N, labels = Lang}, Session) ->
    case session_read_node(Session, N) of
        {not_found, Session1} ->
            {{error, {nref_not_found, N}}, Session1};
        {#node{kind = attribute} = Node, Session1} ->
            describe_attribute(Node, Lang, Session1);
        {#node{kind = Kind}, Session1} ->
            {{error, {unsupported_kind, Kind}}, Session1}
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
%% session_read_arcs(Session, Nref, Direction, KindFilter)
%%     -> {[#relationship{}], Session1}
%%
%% Cache key is {arcs, Nref, Direction, KindFilter} -- the filter is
%% part of the key because filters with different shapes are not
%% interchangeable. (Heuristic refinement deferred until needed.)
%%---------------------------------------------------------------------
session_read_arcs(#{cache := Cache} = Session, Nref, Dir, Kinds) ->
    Key = {arcs, Nref, Dir, Kinds},
    case maps:get(Key, Cache, miss) of
        miss ->
            Arcs = read_arcs(Nref, Dir, Kinds),
            Cache1 = Cache#{Key => Arcs},
            {Arcs, Session#{cache := Cache1}};
        Cached ->
            {Cached, Session}
    end.

read_arcs(Nref, outgoing, Kinds) ->
    Raw = mnesia:dirty_index_read(relationships, Nref,
                                  #relationship.source_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Nref, incoming, Kinds) ->
    Raw = mnesia:dirty_index_read(relationships, Nref,
                                  #relationship.target_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Nref, both, Kinds) ->
    read_arcs(Nref, outgoing, Kinds) ++ read_arcs(Nref, incoming, Kinds).

filter_kinds(Arcs, all) -> Arcs;
filter_kinds(Arcs, Kinds) when is_list(Kinds) ->
    [A || A <- Arcs, lists:member(A#relationship.kind, Kinds)].

%%---------------------------------------------------------------------
%% arc_to_map(Rel) -> map()
%%
%% Project a #relationship{} record into the public result shape.
%%---------------------------------------------------------------------
arc_to_map(#relationship{id               = Id,
                         kind             = K,
                         source_nref      = S,
                         characterization = C,
                         target_nref      = T,
                         reciprocal       = R,
                         avps             = AVPs}) ->
    #{id               => Id,
      kind             => K,
      source_nref      => S,
      characterization => C,
      target_nref      => T,
      reciprocal       => R,
      avps             => AVPs}.

%%---------------------------------------------------------------------
%% describe_attribute(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%
%% Q2: composes the read-through node lookup with downward-arc traversal
%% to enumerate taxonomy children, then resolves a label for self +
%% parent + each child via graphdb_language.  Returns a map with
%% nref/kind/attribute_type/parent/children/avps/labels.
%%---------------------------------------------------------------------
describe_attribute(#node{nref = N, parents = Parents,
                         attribute_value_pairs = AVPs}, LangSpec,
                   Session) ->
    %% Taxonomy parent is the head of the parents cache list (single-chain).
    Parent = case Parents of
        [P | _] -> P;
        []      -> undefined
    end,
    %% Children: downward taxonomy arcs from this node carry
    %% characterization = ?ARC_ATTR_CHILD (24), so read OUTGOING arcs
    %% and project target_nref. (Incoming arcs to N labelled
    %% ARC_ATTR_CHILD point AT N from its parent, not from its
    %% children — see q1b_incoming_all_kinds.)
    {ChildArcs, Session1} = session_read_arcs(Session, N, outgoing,
                                              [taxonomy]),
    Children = [A#relationship.target_nref || A <- ChildArcs,
        A#relationship.characterization =:= ?ARC_ATTR_CHILD],
    AttrType = avp_value_of(AVPs, attribute_type_marker(Session1)),
    {Labels, Session2} = resolve_labels([N, Parent | Children], LangSpec,
                                        Session1),
    Result = #{nref           => N,
               kind           => attribute,
               attribute_type => AttrType,
               parent         => Parent,
               children       => Children,
               avps           => AVPs,
               labels         => Labels},
    {{ok, Result}, Session2}.

%%---------------------------------------------------------------------
%% attribute_type_marker(Session) -> integer() | undefined
%%
%% Look up the seeded `attribute_type` literal-attribute nref.  The
%% session cache key {seeded, attribute_type} reserves a slot for a
%% future memoised lookup; the current implementation does not
%% populate it (each dispatch re-queries graphdb_attr).  See plan
%% Task 5 note for rationale.
%%---------------------------------------------------------------------
attribute_type_marker(#{cache := Cache} = _Session) ->
    case maps:get({seeded, attribute_type}, Cache, miss) of
        miss      -> safe_seeded_attribute_type();
        Cached    -> Cached
    end.

safe_seeded_attribute_type() ->
    try
        {ok, #{attribute_type := At}} = graphdb_attr:seeded_nrefs(),
        At
    catch _:_ -> undefined
    end.

%%---------------------------------------------------------------------
%% avp_value_of(AVPs, undefined | AttrNref) -> term() | undefined
%%---------------------------------------------------------------------
avp_value_of(_AVPs, undefined) -> undefined;
avp_value_of(AVPs, AttrNref) ->
    case lists:search(fun(#{attribute := A}) -> A =:= AttrNref end, AVPs) of
        {value, #{value := V}} -> V;
        false                  -> undefined
    end.

%%---------------------------------------------------------------------
%% resolve_labels(Nrefs, LangSpec, Session) -> {LabelMap, Session1}
%%
%% Resolves a label for every nref via graphdb_language.  For
%% LangSpec = default, uses base-language English. For
%% {language, LangNref}, looks up the registered chain.  Nrefs that
%% resolve to no label are simply omitted from the map.
%%---------------------------------------------------------------------
resolve_labels(Nrefs, LangSpec, Session) ->
    Chain = label_chain(LangSpec),
    Map = lists:foldl(fun
        (undefined, Acc) -> Acc;
        (N, Acc) when is_integer(N) ->
            case resolve_one_label(N, Chain) of
                undefined -> Acc;
                Label     -> Acc#{N => Label}
            end
    end, #{}, Nrefs),
    {Map, Session}.

label_chain(default)               -> [en];
label_chain({language, LangNref})  ->
    case lookup_chain_for_nref(LangNref) of
        [] -> [en];
        L  -> L
    end.

lookup_chain_for_nref(LangNref) ->
    %% Translates a language Nref to a code, then asks
    %% graphdb_language:make_chain/1. Simplified for now: returns [en]
    %% as default chain. Future build-out replaces this once language
    %% nrefs are stabilised.
    _ = LangNref,
    [en].

resolve_one_label(Nref, Chain) ->
    NameAttr = name_attr_for_node(Nref),
    case graphdb_language:resolve_label(Nref, NameAttr, Chain, environment) of
        {ok, Label} -> Label;
        not_found   -> undefined
    end.

%%---------------------------------------------------------------------
%% name_attr_for_node(Nref) -> integer()
%%
%% Returns the appropriate NAME_ATTR_* for the node based on its kind.
%% Reads through dirty_read for kind detection.  The catch-all
%% returns NAME_ATTR_CATEGORY as a safe default — templates and other
%% unknown kinds will simply fail to resolve, which the caller handles
%% by omitting them from the label map.
%%---------------------------------------------------------------------
name_attr_for_node(Nref) ->
    case mnesia:dirty_read(nodes, Nref) of
        [#node{kind = category}]  -> ?NAME_ATTR_CATEGORY;
        [#node{kind = attribute}] -> ?NAME_ATTR_ATTRIBUTE;
        [#node{kind = class}]     -> ?NAME_ATTR_CLASS;
        [#node{kind = instance}]  -> ?NAME_ATTR_INSTANCE;
        _                         -> ?NAME_ATTR_CATEGORY
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
