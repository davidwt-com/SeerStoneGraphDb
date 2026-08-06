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

-export([namespace_of/2, target_namespace/2, node_table/1, rel_table/1]).

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
