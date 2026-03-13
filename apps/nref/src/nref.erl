%%--------------------------------------------------------------------- 
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be 
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of 
%% SeerStone, Inc.
%%--------------------------------------------------------------------- 
%% Author: Dallas Noyes
%% Created: August 16, 2008
%% Description: 
%%		The nref is the top level application module for the seerstone nref server.
%%		It's basic purpose is to start the nref supervisor (nref_sup).
%%		The SeerStone nref server is responsible for assigning nrefs: globaly unique node reference numbers for the SeerStone Database.
%%		The assignment includes issuing nrefs on request, and recycling nrefs.
%%		The nref service is:
%%			Hugely scalable so that it's capacity can be dynamically increased by adding servers.
%%			Can issue trillions of nrefs per minute with *** (finish description based on testing)
%%			Able to assure that all nrefs are unique
%%			Highly fault tolerent
%%  
%% Resources for understanding the erlang applications behavior:
%%  OTP behaviour see http://www.erlang.org/doc/design_principles/part_frame.html starting section 7.0
%%	Application callback exports: http://erlang.org/documentation/doc-5.0.1/lib/kernel-2.6.1/doc/html/application.html
%%--------------------------------------------------------------------- 
%% Revision History
%%--------------------------------------------------------------------- 
%% Rev PA1 Date: October 8, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%% 
%%--------------------------------------------------------------------- 
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%  
%%--------------------------------------------------------------------- 
-module(nref).
-behaviour(application).  


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: 1 ').
-created('Date: October 8, 2008 14:57:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: Month Day, Year 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
%% -import(lists, [map/2]). N/A


%%---------------------------------------------------------------------
%% Macro Functions
%%--------------------------------------------------------------------- 
%% NYI - Not Yet Implemented
%%	X = {fun, {Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun, {Arg1,Arg2,...}}
%%	X = Message
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
%% Exported Functions
%%--------------------------------------------------------------------- 
%% Description module seerstone
%%--------------------------------------------------------------------- 
%% seerstone is the top level module of the SeerStone database.
%% 
%% 
%%--------------------------------------------------------------------- 
%% Exports Behavior Callback Functions
%%--------------------------------------------------------------------- 
-export([
		start/2, 
		start_phase/3, 
		prep_stop/1, 
		stop/1, 
		config_change/3
		]).


%%--------------------------------------------------------------------- 
%% start/2
%% Description: applicaiton callback function.
%%		An application is started by:
%%			> application:start(seerstone).
%%			ok
%%
%%		The values in the .app fil can be overridden by values in a
%%		system configuration file (e.g. seerstone.config)
%%
%% Module:start(Type, ModuleStartArgs) -> Return
%%
%% Types:
%% 		Type = normal | {takeover, node()} | {failover, node()}
%% 		ModuleStartArgs = term()
%% 		Pid = pid()
%% 		State = state()
%%		Return = {ok, Pid} | {ok, Pid, State} | {error, Reason}
%%
%% ModuleStartArgs are defined by mod key in the .app file.
%% The application master reads the .app file to get the ModuleStartArgs
%% and hands them into start/2.
%%
%% This function starts a primary application. Normally, this function 
%% starts the main supervisor of the primary application.
%%
%% StartType is usually the atom normal. It has other values only in the case 
%% of a takeover or failover, see Distributed Applications http://www.erlang.org/doc/design_principles/distributed_applications.html. 
%%
%% {takeover, node()} | {failover, node()} is only used in distributed systems.
%% 
%% {takeover, Node}, is used only in distributed systems when the manager determines
%% that a higher priority node that the applicaiton was running on until the node failed
%% is again available.  The purpose of {takeover, Node} is to allow the state transfer between
%% current node and the higher priority node.  So the higher priority node is started, state transfer,
%% and shutdown of lower priority node occures automaticaly.
%% If the application does not have the start-phases key defined in the application's  
%% resource file,the application will be stopped by the application controller after
%% this call returns (see start-phase/3). This makes it possible to transfer the 
%% internal state from the running application to the one to be started. 
%% This function must not stop the application on Node, but it 
%% may shut down parts of it. For example, instead of stopping the application, 
%% the main supervisor may terminate all its children.
%%
%% {failover, Node} means the application is being restarted due to a 
%% crash of the node where the application was previously executing.  
%% {failover, node()} is valid only if the start_phases key is defined in the 
%% applications resource file. Otherwise the type is set to normal at failover.
%%
%% The ModuleStartArgs parameter is specified in the application resource file
%% (.app), as {mod, {Module, ModuleStartArgs}}.
%%
%% State is any term. It is passed to Module:prep_stop/1. 
%% If no State is returned, [] is used. 
%%--------------------------------------------------------------------- 

start(normal, []) ->
    case nref_sup:start_link() of
		{ok, Pid} ->
			{ok, Pid};
		ignore -> 
			{error, ignore};
		{error, Reason} ->	
			{error, Reason}
    end;
start(Type, StartArgs) ->
	?NYI({start, {Type, StartArgs}}),
	ok.



%%--------------------------------------------------------------------- 
%% start_phase/3
%% Description: callback for starting an included application in phases.
%%				this is only used when the *.app moduel includes {start_phases,...}.
%%				to implement the functionality of a phased start.
%%
%% Module:start_phase(Phase, Type, PhaseStartArgs) -> Return
%%
%% Types:
%%		Phase = atom()
%%		Type = normal | {takeover, node()} | {failover, node()}
%%		PhaseStartArgs = term()
%%		Pid = pid()
%%		State = state()
%%		Return = {ok, Pid} | {ok, Pid, State} | {error, Reason}
%%
%% This function starts a application in the phase Phase. 
%% It is called by default only for a primary application and not for 
%% the included applications, refer to User's Guide chapter 'Design Principles' 
%% regarding incorporating included applications.
%%
%% The PhaseStartArgs parameter is specified in the application's resource file (.app), 
%% as {start_phases, [{Phase, PhaseStartArgs}]}, the Module as {mod, {Module, ModuleStartArgs}}.
%%
%% This call back function is only valid for applications with a defined start_phases key. 
%% This function will be called once per Phase.
%%
%% StartType is usually the atom normal. It has other values only in the case 
%% of a takeover or failover, see Distributed Applications http://www.erlang.org/doc/design_principles/distributed_applications.html. 
%%
%% If Type is {takeover, Node}, it is a distributed application which runs on the Node. 
%% When this call returns for the last start phase, the application on 
%% Node will be stopped by the application controller. 
%% This makes it possible to transfer the internal state from the running application.
%% When designing the start phase function it is imperative that the application 
%% is not allowed to terminate the application on node. 
%% However, it possible to partially shut it down for eg. the main supervisor 
%% may terminate all the application's children.
%%
%% If Type is {failover, Node}, due to a crash of the node where the 
%% application was previously executing, the application will restart. 
%%
%% start is called when starting the application and should create the 
%% supervision tree by starting the top supervisor. 
%% It is expected to return the pid of the top supervisor and an optional
%% term State, which defaults to []. This term is passed as-is to stop.
%%--------------------------------------------------------------------- 
start_phase(Phase, Type, PhaseStartArgs) -> 
	?NYI({start_phase, {Phase, Type, PhaseStartArgs}})
	%% create the supervision tree by starting the top supervisor
	%% Return = {ok, Pid} | {ok, Pid, State} | {error, Reason}
	.


%%--------------------------------------------------------------------- 
%% prep_stop/1
%% Module:prep_stop(State) -> NewState
%%
%% Types:
%%		State = state()
%%		NewState = state()
%%
%% See Module:stop/1. This function is called when the application is about to be stopped, 
%% before shutting down the processes of the application.
%%
%% State is the state that was returned from Mod:start/2, or [] if no state was returned. 
%% NewState will be passed to Module:stop/1.
%%
%% If Module:prep_stop/1 isn't defined, NewState will be identical to State. 
%%--------------------------------------------------------------------- 
prep_stop(State) -> 
	?NYI({prep_stop, {State}}).
%%	Return = NewState.

%%--------------------------------------------------------------------- 
%% stop/1
%% Description: this is the callback function for the application master
%%				it is called by the applicaiton master after the applicaiton
%%				has been shutdown.
%%
%%  An application is stopped, but not unloaded, by calling:
%%     > application:stop(seerstone).
%%		ok
%%
%% The applicaiton master stops the applicaiton by telling the top supervisor to
%% shutdown.  The top supervisor tells all of its child processes to shutdown etc.
%% and the entire tree is terminated in reversed start order.   The application
%% master then calls this application callback function stop/1 in the module define
%% in the mod key in the *.app file.
%%
%% Module:stop(State) -> void()
%%
%% Types:
%%		State = state()
%%
%% stop/1 is called after the application has been stopped and should do any 
%% necessary cleaning up. Note that the actual stopping of the application, 
%% that is the shutdown of the supervision tree, is handled automatically as 
%% described in Starting and Stopping Applications 
%% see http://www.erlang.org/doc/design_principles/applications.html#stopping.
%%
%% This function is called when the application has stopped, either because it crashed, 
%% or because someone called application:stop. 
%% It cleans up after the Module:start/2 function.
%%
%% Before Mod:stop/1 is called, Mod:prep_stop/1 will have been called. 
%% State is the state that was returned from Mod:prep_stop/1. 
%%--------------------------------------------------------------------- 
stop(State) -> 
	?NYI({stop, {State}}),
	ok.


%%--------------------------------------------------------------------- 
%% config_change/3
%% Module:config_change(Changed, New, Removed) -> ok
%%
%%	Types:
%%		Changed = [{Parameter, NewValue}]
%%		New = [{Parameter, Value}]
%%		Removed = [Parameter]
%%		Parameter = atom()
%%		NewValue = term()
%%		Value = term()
%%
%% After an installation of a new release all started applications on 
%% a node are notified of the changed, new and removed configuration parameters. 
%% The unchanged configuration parameters are not affected and 
%% therefore the function is not evaluated for applications which have 
%% unchanged configuration parameters between the old and new releases. 
%%--------------------------------------------------------------------- 
config_change(Changed, New, Removed) -> 
	?NYI({config_change, {Changed, New, Removed}}),
	ok.


