%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% graphdb_query.hrl -- AST records and opaque types for the query
%% language. Records (not maps) for dialyzer support; matches project
%% style.
%%
%% Design source: docs/f3-graphdb-query-design.md.
%%---------------------------------------------------------------------

-ifndef(GRAPHDB_QUERY_HRL).
-define(GRAPHDB_QUERY_HRL, 1).

%% -- Arc kind atoms (mirror relationship.kind values) -----------------
-type arc_kind() :: composition | taxonomy | connection | instantiation.

%% -- Language spec (Q2-Q4 label resolution) ---------------------------
-type language_spec() :: default | {language, LangNref :: integer()}.

%% -- AST records ------------------------------------------------------

%% Q1 — get_node : raw node record by nref
-record(q_get_node, {
    nref :: integer()
}).

%% Q1b — get_arcs : arcs at nref, filtered by direction + kind
-record(q_get_arcs, {
    nref      :: integer(),
    direction :: outgoing | incoming | both,
    arc_kinds :: all | [arc_kind()]
}).

%% Q2/Q3/Q4 — describe : dispatched in executor by looked-up node kind
-record(q_describe, {
    nref   :: integer(),
    labels :: language_spec()
}).

%% Q5 — list_instances_of : all instances of class (optionally recursive)
-record(q_instances_of, {
    class     :: integer(),
    recursive :: boolean()
}).

%% Q6 — find_path : bounded BFS, optionally restricted to arc kinds
-record(q_find_path, {
    from      :: integer(),
    to        :: integer(),
    max_depth :: pos_integer(),
    arc_kinds :: [arc_kind()]
}).

%% -- Continuation -----------------------------------------------------
%% Returned by bounded queries (currently only Q6). Tagged with the
%% snapshot it was issued against; resuming with a mismatched session
%% returns {error, snapshot_expired}.
-record(cont_path, {
    snapshot_at      :: erlang:timestamp(),
    target           :: integer(),
    arc_kinds        :: [arc_kind()],
    remaining_depth  :: non_neg_integer(),
    visited          :: #{integer() => true},
    %% [{Nref, PathToHere}] — frontier nodes to expand on resume
    frontier         :: [{integer(), [map()]}]
}).

-endif.
