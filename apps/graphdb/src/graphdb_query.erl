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
%%              Query sequencing: session API (new_session/0, refresh/1)
%%              is real. #q_get_node{}, #q_get_arcs{}, #q_describe{}
%%              (for kind=attribute, class, or instance),
%%              #q_instances_of{}, and #q_find_path{} are
%%              implemented along with resume/2 and snapshot_expired
%%              detection.  Walking skeleton complete.
%%
%% Design source: docs/designs/f3-graphdb-query-design.md.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev A Date: May 2026 Author: David W. Thomas
%% Initial skeleton implementation.
%% Rev A.1 Date: May 2026 Author: David W. Thomas
%% #q_get_node{} implemented.
%% Rev A.2 Date: May 2026 Author: David W. Thomas
%% #q_get_arcs{} implemented.
%% Rev A.3 Date: May 2026 Author: David W. Thomas
%% #q_describe{} for kind=attribute implemented.
%% Rev A.4 Date: May 2026 Author: David W. Thomas
%% #q_describe{} for kind=class implemented.
%% Rev A.5 Date: May 2026 Author: David W. Thomas
%% #q_describe{} for kind=instance implemented.
%% Rev A.6 Date: May 2026 Author: David W. Thomas
%% #q_instances_of{} implemented.
%% Rev A.7 Date: May 2026 Author: David W. Thomas
%% #q_find_path{} + resume/2 + snapshot_expired.
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
%% Records — mirror canonical shapes (see docs/Architecture.md §3).
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
    new_session/1,
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

%% new_session(Project) -> Session
%%
%% Same as new_session/0 but binds the session to a Project, so bare-nref
%% reads (session_read_node/2, session_read_arcs/4) resolve Home per nref
%% via resolve_home/2 instead of assuming the environment table.  The
%% Project value is stored as-is, unvalidated -- new_session/1 is a plain
%% data constructor, not an entry point that touches Mnesia or the
%% singleton, so there is nothing unsafe about accepting garbage here.
%% Validation happens at the two entry points that actually dispatch a
%% session against the worker: execute_query/2 and resume/2, below.
new_session(Project) ->
    #{snapshot_at => os:timestamp(),
      cache       => #{},
      project     => Project}.

refresh(Session) when is_map(Session) ->
    Session#{snapshot_at := os:timestamp(),
             cache       := #{}}.

execute_query(Query) ->
    gen_server:call(?MODULE, {execute_query_1, Query}).

%% execute_query(Query, Session) -> {ok, _, _} | {partial, _, _, _} | {error, _}
%%
%% Gated on the caller side by validate_session_home/1 (SP2 review wave B
%% Fix 2) BEFORE the gen_server:call, mirroring graphdb_instance:with_home/2
%% / with_project/2's established pattern: a Session built via
%% new_session/1 carries its `project` field completely unvalidated (see
%% that function's header), and dispatch/2 runs SYNCHRONOUSLY inside this
%% gen_server's own handle_call -- so a malformed Project field would reach
%% resolve_home/2's mnesia:dirty_read(graphdb_ns:node_table(Project), _)
%% and trip graphdb_ns:node_table/1's bare two-clause match FROM INSIDE the
%% singleton's own process, killing it. Rejecting it here returns a clean
%% {error, invalid_project} instead.
execute_query(Query, Session) when is_map(Session) ->
    case validate_session_home(Session) of
        ok               -> gen_server:call(?MODULE, {execute_query_2, Query, Session});
        {error, _} = Err -> Err
    end.

%% resume(Cont, Session) -> {ok, _, _} | {partial, _, _, _} | {error, _}
%%
%% Same gate as execute_query/2 above, but load-bearing for a different
%% reason here: resume/2 never calls resolve_home/2 (bfs_step/5 uses
%% home_of_id/2 + session_read_arcs_home/5, and is_scaffold_node/2 takes an
%% already-resolved Home). validate_session_home/1 must still run first,
%% though -- it has to complete before validate_cont_homes/2 below, whose
%% home_id(maps:get(project, Session, environment)) would function_clause
%% on a malformed Project handle.
resume(Cont, Session) when is_map(Session) ->
    case validate_session_home(Session) of
        ok ->
            case validate_cont_homes(Cont, Session) of
                ok ->
                    gen_server:call(?MODULE, {resume, Cont, Session});
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% validate_session_home(Session) -> ok | {error, invalid_project}
%%
%% A session with no `project` key (built via new_session/0) is always
%% environment-bound -- ok. A session built via new_session/1 must carry
%% either the atom `environment` or a well-formed Project handle;
%% graphdb_project:require_project/1 is reused for the well-formedness
%% check (same contract as graphdb_instance:with_home/2's write-side twin).
validate_session_home(Session) ->
    case maps:get(project, Session, environment) of
        environment -> ok;
        Project     -> graphdb_project:require_project(Project)
    end.

%% validate_cont_homes(Cont, Session) -> ok | {error, session_project_mismatch}
%%
%% Every home_id() a continuation can feed to home_of_id/2 must be
%% resolvable against THIS session. Checked on the caller side, before
%% the gen_server:call, for the same reason validate_session_home/1 is:
%% home_of_id/2 would otherwise return the wrong project's handle (or
%% `undefined` for an environment-bound session) deep inside the
%% singleton's own handle_call.
%%
%% Only the target and the frontier are checked. Visited keys are never
%% resolved -- they are compared, and a foreign id there can only ever
%% fail to match, which is harmless.
%%
%% FrontierOk/1 folds a shape check into the same lists:all/2 pass: a
%% frontier element of the wrong arity does not match {Id, _N, _P} and
%% falls to the catch-all `false` clause, rather than being silently
%% dropped by a list-comprehension generator (as a plain `[Id || {Id, _N,
%% _P} <- Frontier]` would do) and passing the gate unchecked. #cont_path{}
%% is defined in a public header and resume/2's Cont argument is
%% unguarded, so a malformed frontier element must fail closed here --
%% bfs_step/5's fold would otherwise function_clause deep inside this
%% gen_server's singleton process.
validate_cont_homes(#cont_path{target = {TargetId, _Nref},
                               frontier = Frontier}, Session) ->
    Bound = home_id(maps:get(project, Session, environment)),
    HomeOk = fun(environment) -> true;
                (Id)          -> Id =:= Bound
             end,
    FrontierOk = fun({Id, _N, _P}) -> HomeOk(Id);
                    (_Malformed)   -> false
                 end,
    case HomeOk(TargetId) andalso lists:all(FrontierOk, Frontier) of
        true  -> ok;
        false -> {error, session_project_mismatch}
    end.

%% find_path/3 — public convenience matching the query task spec API.
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
handle_call({resume, #cont_path{snapshot_at = ContSnap},
             #{snapshot_at := SessSnap}}, _From, State)
    when ContSnap =/= SessSnap ->
    {reply, {error, snapshot_expired}, State};
handle_call({resume, #cont_path{target          = To,
                                arc_kinds       = Kinds,
                                remaining_depth = NextBudget,
                                visited         = Visited,
                                frontier        = Frontier},
             Session}, _From, State) ->
    SnapshotAt = maps:get(snapshot_at, Session),
    {Reply, Session1} =
        bfs(SnapshotAt, To, NextBudget, NextBudget, Kinds,
            Visited, Frontier, Session),
    {reply, attach_session(Reply, Session1), State};
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
        {#node{kind = class} = Node, Session1} ->
            describe_class(Node, Lang, Session1);
        {#node{kind = instance} = Node, Session1} ->
            describe_instance(Node, Lang, Session1);
        {#node{kind = Kind}, Session1} ->
            {{error, {unsupported_kind, Kind}}, Session1}
    end;
dispatch(#q_instances_of{class = C, recursive = Recursive}, Session) ->
    Classes = case Recursive of
        true  -> [C | all_subclasses(C)];
        false -> [C]
    end,
    %% Instances only ever live in projects: the class->instance
    %% membership row (characterization = ?ARC_CLASS_TO_INST) is written
    %% into the project's own relationship table
    %% (graphdb_instance:instance_records/5), never into the
    %% environment's, regardless of what resolve_home/2 would pick for
    %% the bare class nref (a class node never exists in a project's
    %% node table, so resolve_home/2 always answers `environment` for
    %% it -- the wrong table for this particular arc shape). When the
    %% session has a Project bound, route every class in Classes
    %% through that project explicitly instead of resolve_home/2. With
    %% no Project bound, preserve prior behaviour exactly (environment
    %% read, which legitimately yields [] since no environment-resident
    %% class has project-resident instances).
    ProjectHome = maps:get(project, Session, undefined),
    {Instances, Session1} = lists:foldl(
        fun(Cl, {Acc, S}) ->
            {Arcs, S1} = if
                ProjectHome =:= undefined ->
                    session_read_arcs(S, Cl, outgoing, [instantiation]);
                true ->
                    session_read_arcs_home(S, ProjectHome, Cl, outgoing,
                                           [instantiation])
            end,
            Members = [A#relationship.target_nref || A <- Arcs,
                A#relationship.characterization =:= ?ARC_CLASS_TO_INST],
            {Members ++ Acc, S1}
        end, {[], Session}, Classes),
    {{ok, lists:usort(Instances)}, Session1};
dispatch(#q_find_path{from = From, to = To, max_depth = D,
                       arc_kinds = Kinds}, Session) ->
    SnapshotAt = maps:get(snapshot_at, Session),
    %% Entry points -- and ONLY entry points -- resolve Home by
    %% guessing. resolve_home/2 was designed for exactly this position:
    %% a bare nref with no characterization context. From here on Home
    %% travels with the frontier and is derived from each arc (see
    %% graphdb_ns:arc_target_namespace/3); it is never re-guessed.
    FromId = home_id(resolve_home(Session, From)),
    ToId   = home_id(resolve_home(Session, To)),
    %% Initial budget D doubles as the resume budget — partial conts
    %% carry max_depth as remaining_depth so resume gets a fresh full
    %% allotment rather than the exhausted 0.
    bfs(SnapshotAt, {ToId, To}, D, D, Kinds,
        #{{FromId, From} => true},
        [{FromId, From, []}],
        Session);
dispatch(_Query, Session) ->
    {{error, not_implemented}, Session}.

%%---------------------------------------------------------------------
%% resolve_home(Session, Nref) -> environment | Project
%%
%% Determines which store an Nref belongs to when no relationship
%% context is available. Every session_read_node/session_read_arcs call
%% in this module is a bare-nref, no-characterization-context read
%% (#q_get_node{}, #q_describe{}, #q_find_path{}'s endpoints, and every
%% arc-discovered nref during BFS/#q_instances_of{} traversal) -- the
%% query language's records carry no target_kind/characterization
%% alongside the nref, unlike graphdb_instance's connection-arc
%% primitives, so this can't reuse graphdb_ns:target_namespace/2
%% directly (it needs a TargetKind this module never has in hand).
%%
%% Resolution: try the session's bound Project first (if any); a
%% genuine ambiguity (the key exists in BOTH tables) is logged, and the
%% project's copy wins on the theory that a session opened against a
%% project is evidence of caller intent. This is deliberately
%% intent-following, not exhaustive-and-arbitrary: it is the one place
%% in SP2 where "try both, pick a winner" was chosen over the
%% home-relative determinism used everywhere else, because the query
%% language's entry points give no characterization context to
%% determine Home outright.
%%---------------------------------------------------------------------
resolve_home(#{project := environment}, _Nref) ->
    %% new_session/1 accepts the atom `environment` as a legitimate Home
    %% (validate_session_home/1 blesses it). Match it ahead of the project
    %% clause: without this, `environment` falls into the clause below and
    %% maps:get(anchor, environment) raises badmap INSIDE the singleton.
    environment;
resolve_home(#{project := Project}, Nref) when Project =/= undefined ->
    case mnesia:dirty_read(graphdb_ns:node_table(Project), Nref) of
        [_] ->
            case mnesia:dirty_read(nodes, Nref) of
                [_] ->
                    logger:warning(
                        "graphdb_query: nref ~p exists in both project ~p "
                        "and the environment -- resolving to the project",
                        [Nref, maps:get(anchor, Project)]);
                [] ->
                    ok
            end,
            Project;
        [] ->
            environment
    end;
resolve_home(_Session, _Nref) ->
    environment.

%%---------------------------------------------------------------------
%% home_id(Home)              -> home_id()
%% home_of_id(Session, Id)    -> environment | Project
%%
%% `home_id()` is the compact, comparable form of a Home and is what
%% travels in the BFS frontier, the visited set, #cont_path{}, and the
%% public result. The full Project handle stays out of all four: it
%% carries physical table atoms, and it makes an unwieldy map key.
%%
%% home_of_id/2 is the inverse, and is total for any id a session can
%% legitimately produce: a session binds at most ONE Project, so a
%% {project, _} id can only mean that one. resume/2 gates continuations
%% carrying a foreign id before they ever reach here (validate_cont_homes/2).
%%---------------------------------------------------------------------
home_id(environment)         -> environment;
home_id(#{anchor := Anchor}) -> {project, Anchor}.

home_of_id(_Session, environment) ->
    environment;
home_of_id(Session, {project, _Anchor}) ->
    maps:get(project, Session).

%%---------------------------------------------------------------------
%% session_read_node(Session, Nref) -> {Node | not_found, Session1}
%%
%% Read-through cache: a hit returns immediately; a miss resolves Home
%% via resolve_home/2, reads Mnesia, and (if the node exists) populates
%% the cache before returning. Misses that hit Mnesia and find nothing
%% are NOT cached — caching a negative result would require threading
%% the session on error replies, which the current /2 API does not do.
%%
%% Cache key shape: {node, Nref}.
%%---------------------------------------------------------------------
session_read_node(#{cache := Cache} = Session, Nref) ->
    case maps:get({node, Nref}, Cache, miss) of
        miss ->
            Home = resolve_home(Session, Nref),
            case mnesia:dirty_read(graphdb_ns:node_table(Home), Nref) of
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
            Home = resolve_home(Session, Nref),
            Arcs = read_arcs(Home, Nref, Dir, Kinds),
            Cache1 = Cache#{Key => Arcs},
            {Arcs, Session#{cache := Cache1}};
        Cached ->
            {Cached, Session}
    end.

%%---------------------------------------------------------------------
%% session_read_arcs_home(Session, Home, Nref, Direction, KindFilter)
%%     -> {[#relationship{}], Session1}
%%
%% Same read-through cache as session_read_arcs/4, but Home is supplied
%% by the caller instead of being resolved via resolve_home/2 -- for
%% arc shapes (e.g. the project-side class->instance membership arc
%% read by #q_instances_of{}) where resolve_home/2's bare-nref
%% resolution would pick the wrong table. Cache key is {arcs, Home,
%% Nref, Direction, KindFilter}: a 5-tuple, deliberately a different
%% shape from session_read_arcs/4's 4-tuple {arcs, Nref, Direction,
%% KindFilter} key, so the two read paths can never collide in the
%% shared per-session cache map even when called for the same Nref --
%% no entry written by one path is ever a valid key for the other.
%%---------------------------------------------------------------------
session_read_arcs_home(#{cache := Cache} = Session, Home, Nref, Dir, Kinds) ->
    Key = {arcs, Home, Nref, Dir, Kinds},
    case maps:get(Key, Cache, miss) of
        miss ->
            Arcs = read_arcs(Home, Nref, Dir, Kinds),
            Cache1 = Cache#{Key => Arcs},
            {Arcs, Session#{cache := Cache1}};
        Cached ->
            {Cached, Session}
    end.

read_arcs(Home, Nref, outgoing, Kinds) ->
    Raw = mnesia:dirty_index_read(graphdb_ns:rel_table(Home), Nref,
                                  #relationship.source_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Home, Nref, incoming, Kinds) ->
    Raw = mnesia:dirty_index_read(graphdb_ns:rel_table(Home), Nref,
                                  #relationship.target_nref),
    filter_kinds(Raw, Kinds);
read_arcs(Home, Nref, both, Kinds) ->
    read_arcs(Home, Nref, outgoing, Kinds) ++ read_arcs(Home, Nref, incoming, Kinds).

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
%% describe(attribute): composes the read-through node lookup with downward-arc traversal
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
    %% N, Parent, and every taxonomy child are all attribute nrefs -- attribute
    %% nodes are known-environment by construction (see resolve_labels_env/3),
    %% so this bypasses resolve_home/2's ambiguous-nref guess entirely.
    {Labels, Session2} = resolve_labels_env([N, Parent | Children], LangSpec,
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
%% describe_class(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%
%% describe(class): superclasses come from the parents cache; ancestors come from
%% graphdb_class:ancestors/1 (multi-parent DAG walk); subclasses come
%% from graphdb_class:subclasses/1.  QCs are returned as the flat
%% [{AttrNref, Value}] list produced by graphdb_class:inherited_qcs/1
%% — the own/inherited+origin split is a deferred enhancement.
%%---------------------------------------------------------------------
describe_class(#node{nref = N, parents = Parents,
                     attribute_value_pairs = AVPs}, LangSpec,
               Session) ->
    Superclasses = Parents,
    {ok, AncestorNodes} = graphdb_class:ancestors(N),
    {ok, SubclassNodes} = graphdb_class:subclasses(N),
    {ok, QCs}           = graphdb_class:inherited_qcs(N),
    Ancestors  = [Nd#node.nref || Nd <- AncestorNodes],
    Subclasses = [Nd#node.nref || Nd <- SubclassNodes],
    QCAttrs    = [A || {A, _Value} <- QCs],
    AllNrefs = lists:usort([N] ++ Superclasses ++ Ancestors
                           ++ Subclasses ++ QCAttrs),
    %% N, every superclass/ancestor/subclass, and every QC attribute are all
    %% class or attribute nrefs -- known-environment by construction (see
    %% resolve_labels_env/3), so this bypasses resolve_home/2 entirely.
    {Labels, Session1} = resolve_labels_env(AllNrefs, LangSpec, Session),
    Result = #{nref                       => N,
               kind                       => class,
               superclasses               => Superclasses,
               ancestors                  => Ancestors,
               subclasses                 => Subclasses,
               qualifying_characteristics => QCs,
               avps                       => AVPs,
               labels                     => Labels},
    {{ok, Result}, Session1}.

%%---------------------------------------------------------------------
%% describe_instance(Node, LangSpec, Session)
%%     -> {{ok, ResultMap}, Session1}
%%
%% describe(instance): surfaces compositional + class structure, resolved attributes
%% via 4-priority inheritance (Task 0's resolve_value/2 returns
%% {ok, Value, Source}), and BOTH outgoing and incoming connection
%% arcs (per-direction characterization and AVPs differ).
%%
%% Home is resolved once, via resolve_home/2 against the described
%% instance's own nref N, and threaded into the two Project-taking
%% graphdb_instance calls (compositional_ancestors/2, resolve_value/3)
%% below -- both operate on N's own compositional/attribute space, so
%% they share N's Home.
%%---------------------------------------------------------------------
describe_instance(#node{nref = N, parents = Parents, classes = Classes,
                        attribute_value_pairs = AVPs} = Node, LangSpec,
                  Session) ->
    CompositionalParent = case Parents of
        [P | _] -> P;
        []      -> undefined
    end,
    Home = resolve_home(Session, N),
    {ok, CompAncestorNodes} = graphdb_instance:compositional_ancestors(Home, N),
    CompAncestors = [Nd#node.nref || Nd <- CompAncestorNodes],
    %% class_ancestors is the transitive closure of "is-a" from the
    %% instance's classes, INCLUDING the direct classes themselves so
    %% callers can ask one list "what is this instance" without having
    %% to merge `classes` and the strictly-ancestral set.
    ClassAncestors = lists:usort(Classes ++ lists:flatmap(
        fun(C) ->
            {ok, AncNodes} = graphdb_class:ancestors(C),
            [Nd#node.nref || Nd <- AncNodes]
        end, Classes)),
    Resolved = resolved_attributes(Node, Home),
    {OutArcs, Session1} = session_read_arcs(Session, N, outgoing,
                                            [connection]),
    {InArcs,  Session2} = session_read_arcs(Session1, N, incoming,
                                            [connection]),
    Outgoing = [#{characterization => A#relationship.characterization,
                  target           => A#relationship.target_nref,
                  template         => template_avp(A#relationship.avps)}
                || A <- OutArcs],
    Incoming = [#{characterization => A#relationship.characterization,
                  source           => A#relationship.source_nref,
                  template         => template_avp(A#relationship.avps)}
                || A <- InArcs],
    %% Split into known-environment nrefs (classes/class-ancestors/arc-label
    %% characterizations -- always environment by field-role, per
    %% graphdb_ns:namespace_of/2) and genuinely ambiguous ones (N itself,
    %% the compositional parent/ancestors, and connection target/source --
    %% all instance-space nrefs that may collide in key with an environment
    %% nref, so they still need resolve_home/2's per-session guess). Routing
    %% the first group directly to the environment table, instead of through
    %% resolve_home/2, is the SP2 review wave B Fix 1: previously ALL of
    %% AllNrefs went through resolve_home/2, so a project-bound session with
    %% enough instances could silently misresolve a low environment nref
    %% (e.g. an arc-label characterization) into the project's own table,
    %% get back the wrong kind, and drop its label with no error.
    EnvNrefs = lists:usort(
        Classes ++ ClassAncestors
        ++ [maps:get(characterization, M) || M <- Outgoing]
        ++ [maps:get(characterization, M) || M <- Incoming]),
    AmbiguousNrefs = lists:usort(
        [N]
        ++ case CompositionalParent of undefined -> []; X -> [X] end
        ++ CompAncestors
        ++ [maps:get(target, M) || M <- Outgoing]
        ++ [maps:get(source, M) || M <- Incoming]),
    {EnvLabels, Session3}       = resolve_labels_env(EnvNrefs, LangSpec,
                                                      Session2),
    {AmbiguousLabels, Session4} = resolve_labels(AmbiguousNrefs, LangSpec,
                                                 Session3),
    %% EnvLabels second: on key overlap (reachable when a connection
    %% target is also one of the instance's classes) the known-environment
    %% resolution is authoritative over resolve_home/2's guess.
    Labels = maps:merge(AmbiguousLabels, EnvLabels),
    Result = #{nref                    => N,
               kind                    => instance,
               classes                 => Classes,
               class_ancestors         => ClassAncestors,
               compositional_parent    => CompositionalParent,
               compositional_ancestors => CompAncestors,
               resolved_attributes     => Resolved,
               outgoing_connections    => Outgoing,
               incoming_connections    => Incoming,
               avps                    => AVPs,
               labels                  => Labels},
    {{ok, Result}, Session4}.

%%---------------------------------------------------------------------
%% resolved_attributes(Node, Home) -> #{AttrNref => #{value, source}}
%%
%% Walks every class's full QC list and resolves each via
%% graphdb_instance:resolve_value/3, which returns
%% {ok, Value, Source} (Task 0). Home is the instance's own resolved
%% store (environment | Project), as determined by the caller via
%% resolve_home/2.
%%---------------------------------------------------------------------
resolved_attributes(#node{nref = N, classes = Classes}, Home) ->
    QCAttrs = lists:usort(lists:flatmap(
        fun(C) ->
            {ok, QCs} = graphdb_class:inherited_qcs(C),
            [A || {A, _Value} <- QCs]
        end, Classes)),
    lists:foldl(fun(Q, Acc) ->
        case graphdb_instance:resolve_value(Home, N, Q) of
            {ok, Value, Source} -> Acc#{Q => #{value  => Value,
                                               source => Source}};
            not_found            -> Acc
        end
    end, #{}, QCAttrs).

template_avp(AVPs) ->
    case lists:search(
            fun(#{attribute := A}) -> A =:= ?ARC_TEMPLATE end,
            AVPs) of
        {value, #{value := V}} -> V;
        false                  -> undefined
    end.

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
%% resolve_labels_env(Nrefs, LangSpec, Session) -> {LabelMap, Session1}
%%
%% Resolves a label for every nref via graphdb_language.  For
%% LangSpec = default, uses base-language English. For
%% {language, LangNref}, looks up the registered chain.  Nrefs that
%% resolve to no label are simply omitted from the map.
%%
%% Two entry points, both thin wrappers around the shared /4 worker below,
%% differing only in how each nref's kind is looked up for NAME_ATTR_*
%% selection (SP2 review wave B Fix 1):
%%
%%   resolve_labels/3     -- for nrefs that are genuinely ambiguous bare
%%                            nrefs with no context to disambiguate them
%%                            (e.g. describe_instance's own nref, its
%%                            compositional parent/ancestors, and connection
%%                            target/source nrefs -- all instance-space,
%%                            may legitimately live in a bound Project, and
%%                            may collide in key with an environment nref).
%%                            Kind detection routes through resolve_home/2,
%%                            same as before.
%%
%%   resolve_labels_env/3 -- for nrefs that are known-environment BY
%%                            CONSTRUCTION: arc-label characterizations,
%%                            class nrefs, and attribute nrefs always
%%                            resolve to the environment (see
%%                            graphdb_ns:namespace_of/2's characterization/
%%                            node_classes/taxonomy_parent clauses -- classes
%%                            and attributes are never Project-resident).
%%                            Kind detection reads the environment `nodes`
%%                            table directly, with NO resolve_home/2 guess
%%                            at all -- so a project-bound session can never
%%                            misresolve one of these into the project's own
%%                            table and silently drop its label.  Before
%%                            this fix, describe_attribute/describe_class
%%                            (100% known-environment nrefs) and half of
%%                            describe_instance's AllNrefs went through
%%                            resolve_home/2 unnecessarily/incorrectly.
%%---------------------------------------------------------------------
resolve_labels(Nrefs, LangSpec, Session) ->
    resolve_labels_4(Nrefs, LangSpec, Session, ambiguous).

resolve_labels_env(Nrefs, LangSpec, Session) ->
    resolve_labels_4(Nrefs, LangSpec, Session, environment).

resolve_labels_4(Nrefs, LangSpec, Session, HomeMode) ->
    Chain = label_chain(LangSpec),
    Map = lists:foldl(fun
        (undefined, Acc) -> Acc;
        (N, Acc) when is_integer(N) ->
            case resolve_one_label(Session, N, Chain, HomeMode) of
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
    end;
%% Catch-all: a #q_describe{} left with `labels` unset (or carrying any
%% unrecognised spec) must not function_clause inside the singleton.
label_chain(_Other)                -> [en].

lookup_chain_for_nref(LangNref) ->
    %% Translates a language Nref to a code, then asks
    %% graphdb_language:make_chain/1. Simplified for now: returns [en]
    %% as default chain. Future build-out replaces this once language
    %% nrefs are stabilised.
    _ = LangNref,
    [en].

resolve_one_label(Session, Nref, Chain, HomeMode) ->
    NameAttr = name_attr_for_node(Session, Nref, HomeMode),
    %% The language overlay itself is environment-bound (labels are
    %% registered against the shared language layer, not per-project) --
    %% only the kind-detection read above is Home-routed.
    case graphdb_language:resolve_label(Nref, NameAttr, Chain, environment) of
        {ok, Label} -> Label;
        not_found   -> undefined
    end.

%%---------------------------------------------------------------------
%% name_attr_for_node(Session, Nref, HomeMode) -> integer()
%%
%% Returns the appropriate NAME_ATTR_* for the node based on its kind.
%%
%%   HomeMode = environment -- Nref is known-environment by construction
%%              (see resolve_labels_env/3's header); reads the environment
%%              `nodes` table directly, no resolve_home/2 guess.
%%   HomeMode = ambiguous   -- Nref is a genuinely ambiguous bare nref (may
%%              be a project instance colliding in key with an environment
%%              nref); resolves Home via resolve_home/2 first, as before.
%%
%% The catch-all returns NAME_ATTR_CATEGORY as a safe default — templates
%% and other unknown kinds will simply fail to resolve, which the caller
%% handles by omitting them from the label map.
%%---------------------------------------------------------------------
name_attr_for_node(_Session, Nref, environment) ->
    name_attr_of_kind(mnesia:dirty_read(nodes, Nref));
name_attr_for_node(Session, Nref, ambiguous) ->
    Home = resolve_home(Session, Nref),
    name_attr_of_kind(mnesia:dirty_read(graphdb_ns:node_table(Home), Nref)).

name_attr_of_kind([#node{kind = category}])  -> ?NAME_ATTR_CATEGORY;
name_attr_of_kind([#node{kind = attribute}]) -> ?NAME_ATTR_ATTRIBUTE;
name_attr_of_kind([#node{kind = class}])     -> ?NAME_ATTR_CLASS;
name_attr_of_kind([#node{kind = instance}])  -> ?NAME_ATTR_INSTANCE;
name_attr_of_kind(_)                         -> ?NAME_ATTR_CATEGORY.

%%---------------------------------------------------------------------
%% all_subclasses(ClassNref) -> [integer()]
%%
%% Transitive closure of graphdb_class:subclasses/1 (which returns
%% direct children only).  Does NOT include ClassNref itself.
%%---------------------------------------------------------------------
all_subclasses(C) ->
    {ok, Direct} = graphdb_class:subclasses(C),
    DirectNrefs = [N#node.nref || N <- Direct],
    DirectNrefs ++ lists:flatmap(fun all_subclasses/1, DirectNrefs).

%%---------------------------------------------------------------------
%% bfs(SnapshotAt, Target, ResumeBudget, RemainingDepth, ArcKinds,
%%     Visited, Frontier, Session) -> {Reply, Session1}
%%
%%     Frontier   :: [{HomeId, Nref, PathToHere}]
%%     PathToHere :: [#{from, via, to, kind}]   (edges already taken)
%%
%% ResumeBudget is the original max_depth — stored on the cont so resume
%% gets a fresh full allotment, not the exhausted 0.  RemainingDepth is
%% the budget for THIS run of bfs.
%%
%% Returns:
%%   {{ok, EdgeList}, Session1}                       -- target found
%%   {{ok, no_path}, Session1}                        -- frontier emptied
%%   {{partial, BestSoFar, #cont_path{}}, Session1}   -- depth-bounded
%%---------------------------------------------------------------------
bfs(_Snap, _ToKey, _Budget, _D, _Kinds, _Vis, [], Session) ->
    {{ok, no_path}, Session};
bfs(Snap, ToKey, Budget, 0, Kinds, Vis, Frontier, Session) ->
    %% Depth exhausted but frontier non-empty -- partial. The first bfs/8
    %% clause above already matches an empty Frontier (any D) and returns
    %% before this clause is reached, so Frontier is guaranteed non-empty
    %% here; no `[] -> []` fallback arm is reachable.
    [{_HomeId, _Nref, BestSoFar} | _] = Frontier,
    Cont = #cont_path{snapshot_at     = Snap,
                      target          = ToKey,
                      arc_kinds       = Kinds,
                      remaining_depth = Budget,
                      visited         = Vis,
                      frontier        = Frontier},
    {{partial, BestSoFar, Cont}, Session};
bfs(Snap, ToKey, Budget, D, Kinds, Vis, Frontier, Session) ->
    {NextFrontier, Vis1, FoundPath, Session1} =
        bfs_step(ToKey, Kinds, Frontier, Vis, Session),
    case FoundPath of
        {found, Path} ->
            {{ok, Path}, Session1};
        not_found ->
            bfs(Snap, ToKey, Budget, D - 1, Kinds, Vis1, NextFrontier,
                Session1)
    end.

bfs_step(ToKey, Kinds, Frontier, Vis, Session) ->
    lists:foldl(
        fun({HomeId, Nref, PathToHere}, {Acc, V, Found, S}) ->
            case Found of
                {found, _} ->
                    {Acc, V, Found, S};
                not_found ->
                    %% session_read_arcs_home/5, NOT session_read_arcs/4:
                    %% the Home is known, so there is nothing to guess.
                    Home = home_of_id(S, HomeId),
                    {Arcs, S1} = session_read_arcs_home(S, Home, Nref,
                                                        outgoing, Kinds),
                    expand_arcs(ToKey, HomeId, Home, Nref, PathToHere,
                                Arcs, V, Acc, Found, S1)
            end
        end, {[], Vis, not_found, Session}, Frontier).

expand_arcs(_ToKey, _FromId, _FromHome, _From, _PathHere, [], V, Acc,
            Found, S) ->
    {Acc, V, Found, S};
expand_arcs(ToKey, FromId, FromHome, From, PathHere,
            [#relationship{kind             = K,
                           characterization = C,
                           target_nref      = T} | Rest],
            V, Acc, Found, S) ->
    %% Half A: the target's Home is DERIVED from the arc we arrived on,
    %% never guessed from the bare nref.
    TargetHome = graphdb_ns:arc_target_namespace(FromHome, K, C),
    TargetId   = home_id(TargetHome),
    Edge = make_edge(From, C, T, K, FromId, TargetId),
    NewPath = PathHere ++ [Edge],
    %% Half B: compare and remember the Home-qualified key. A bare nref
    %% is unique only within a Home.
    Key = {TargetId, T},
    case Key of
        ToKey ->
            {Acc, V, {found, NewPath}, S};
        _ ->
            case maps:is_key(Key, V) orelse is_scaffold_node(TargetHome, T) of
                true ->
                    expand_arcs(ToKey, FromId, FromHome, From, PathHere,
                                Rest, V, Acc, Found, S);
                false ->
                    V1 = V#{Key => true},
                    Acc1 = Acc ++ [{TargetId, T, NewPath}],
                    expand_arcs(ToKey, FromId, FromHome, From, PathHere,
                                Rest, V1, Acc1, Found, S)
            end
    end.

%%---------------------------------------------------------------------
%% make_edge(From, Char, To, Kind, FromId, TargetId) -> map()
%%
%% A path edge discloses `home` iff this hop crosses stores. The absent
%% key means "same store as the previous hop"; the first edge's store is
%% the one the caller named in `from`. A consumer reconstructs the whole
%% Home sequence by carrying the last disclosed value forward.
%%
%% The value is a home_id(), never the raw Project handle -- results
%% must not leak physical table atoms.
%%---------------------------------------------------------------------
make_edge(From, Char, To, Kind, HomeId, HomeId) ->
    #{from => From, via => Char, to => To, kind => Kind};
make_edge(From, Char, To, Kind, _FromId, TargetId) ->
    #{from => From, via => Char, to => To, kind => Kind,
      home => TargetId}.

%%---------------------------------------------------------------------
%% is_scaffold_node(Home, Nref) -> boolean()
%%
%% Category nodes are structural scaffold (nrefs 1-5) -- never
%% traversed by graph queries.  Matches the semantics already encoded
%% in graphdb_class:ancestors/1 which filters NREF_CLASSES out of the
%% taxonomy walk.  Without this filter, two classes sharing only
%% NREF_CLASSES as a parent would be considered taxonomically
%% connected, which contradicts both the design and existing helpers.
%%
%% Takes a resolved Home rather than a Session: the caller already
%% derived it from the arc. This needs no policy about what
%% scaffold-ness means under a project session -- a project-homed nref
%% reads from the project's table, finds kind=instance, and yields
%% false, which is the right answer reached structurally.
%%---------------------------------------------------------------------
is_scaffold_node(Home, Nref) ->
    case mnesia:dirty_read(graphdb_ns:node_table(Home), Nref) of
        [#node{kind = category}] -> true;
        _                        -> false
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
