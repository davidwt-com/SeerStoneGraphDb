%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-06-29
%% Description: Pure namespace resolution module.  Encodes which
%%				database namespace each kind of nref reference belongs
%%				to, and resolves a Home into its physical table atoms.
%%				No dependencies on other modules; fixed lookup table
%%				based on the project-environment separation model.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-06-29 Author: David W. Thomas
%% Initial implementation.
%% Rev PA2 Date: 2026-08-05 Author: David W. Thomas
%% SP2: home-relative routing.  namespace_of/1 and target_namespace/1
%% replaced by /2 forms taking a Home (environment | project handle).
%% node_table/1 and rel_table/1 added.
%%---------------------------------------------------------------------

-module(graphdb_ns).
-include_lib("graphdb/include/graphdb_nrefs.hrl").

-export([namespace_of/2, target_namespace/2, arc_target_namespace/3,
	node_table/1, rel_table/1]).

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


%%---------------------------------------------------------------------
%% namespace_of(Home, Role) -> environment | Home
%%
%% Encodes docs/designs/project-env-reference-namespace-model-design.md §3
%% (amended 2026-08-02 for home-relative routing). `Home` is the store the
%% containing record was read from: `environment` or a `graphdb_project`
%% handle. target_nref and source_nref are NOT roles here — they need the
%% arc label's target_kind too, so they route through target_namespace/2
%% directly at the call site (see that design's §6 code block).
%%---------------------------------------------------------------------
namespace_of(_Home, characterization)     -> environment;
namespace_of(_Home, reciprocal)           -> environment;
namespace_of(_Home, avp_attribute)        -> environment;
namespace_of(_Home, node_classes)         -> environment;
namespace_of(_Home, taxonomy_parent)      -> environment;
namespace_of(Home,  compositional_parent) -> Home;
namespace_of(Home,  node_nref)            -> Home.


%%---------------------------------------------------------------------
%% target_namespace(Home, TargetKind) -> environment | Home
%%
%% The routed-field resolver: category/attribute/class targets are always
%% environment; an instance target is home-relative (Home itself — whatever
%% that Home is, environment or a specific project).
%%---------------------------------------------------------------------
target_namespace(_Home, category)  -> environment;
target_namespace(_Home, attribute) -> environment;
target_namespace(_Home, class)     -> environment;
target_namespace(Home,  instance)  -> Home.


%%---------------------------------------------------------------------
%% arc_target_namespace(Home, ArcKind, Characterization)
%%     -> environment | Home
%%
%% The arc-row analogue of namespace_of/2, for a traversal that has an
%% arc in hand.  `Home` is the store the arc row was READ from.
%%
%% Unlike a bare nref, an nref reached BY TRAVERSING AN ARC is not
%% ambiguous: #relationship.kind and .characterization are present on
%% every row and together determine the target's store outright.  This
%% is what lets graphdb_query stop guessing mid-traversal.
%%
%%   taxonomy      -- class/attribute refinement; projects hold only
%%                    instances, so the target is always environment.
%%   composition   -- home-relative: category/class composition is
%%                    environment<->environment, instance composition is
%%                    project<->project.
%%   connection    -- instance<->instance inside one store.
%%   instantiation -- the 29/30 membership pair.  BOTH rows live in the
%%                    project's table, but 29 (instance->class) targets
%%                    an environment class while 30 (class->instance)
%%                    targets a project instance.  This is the one arc
%%                    shape whose ends deliberately differ in Home, and
%%                    the characterization is exactly what says which
%%                    direction we are walking.
%%
%% Deliberately total.  A caller of this module is the graphdb_query
%% singleton; a function_clause here would take the query server down
%% for every session over one malformed row, so an unrecognised shape
%% logs and degrades to same-store (which is what that row did before
%% this function existed).
%%---------------------------------------------------------------------
arc_target_namespace(_Home, taxonomy,    _Char) -> environment;
arc_target_namespace(Home,  composition, _Char) -> Home;
arc_target_namespace(Home,  connection,  _Char) -> Home;
arc_target_namespace(_Home, instantiation, ?ARC_INST_TO_CLASS) -> environment;
arc_target_namespace(Home,  instantiation, ?ARC_CLASS_TO_INST) -> Home;
arc_target_namespace(Home,  Kind, Char) ->
	logger:warning(
		"graphdb_ns: unroutable arc kind ~p (characterization ~p) -- "
		"defaulting to same store ~p",
		[Kind, Char, Home]),
	Home.


%%---------------------------------------------------------------------
%% node_table(Home) -> atom()
%% rel_table(Home)  -> atom()
%%
%% Resolves a Home into its physical Mnesia table atoms. `environment`
%% resolves to the literal shared tables; a project handle (as returned by
%% graphdb_project:open/1) carries its own table atoms directly.
%%---------------------------------------------------------------------
node_table(environment)   -> nodes;
node_table(#{nodes := T}) -> T.

rel_table(environment)  -> relationships;
rel_table(#{rels := T}) -> T.
