%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-06-29
%% Description: Pure namespace resolution module.  Encodes which
%%				database namespace each kind of nref reference belongs
%%				to.  No dependencies on other modules; fixed lookup table
%%				based on the project-environment separation model.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-06-29 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------

-module(graphdb_ns).

-export([namespace_of/1, target_namespace/1]).

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
%% namespace_of(Role) -> environment | project | home
%%
%% Encodes docs/designs/project-env-reference-namespace-model-design.md §3.
%% `home` = same store as the containing record (node's own DB / row's home).
%%---------------------------------------------------------------------
namespace_of(characterization)     -> environment;
namespace_of(reciprocal)           -> environment;
namespace_of(avp_attribute)        -> environment;
namespace_of(node_classes)         -> environment;
namespace_of(taxonomy_parent)      -> environment;
namespace_of(compositional_parent) -> project;
namespace_of(node_nref)            -> home;
namespace_of(source_nref)          -> home.


%%---------------------------------------------------------------------
%% target_namespace(TargetKind) -> environment | project
%%
%% The single routed field (relationship.target_nref): project iff instance.
%%---------------------------------------------------------------------
target_namespace(instance)  -> project;
target_namespace(category)  -> environment;
target_namespace(attribute) -> environment;
target_namespace(class)     -> environment.
