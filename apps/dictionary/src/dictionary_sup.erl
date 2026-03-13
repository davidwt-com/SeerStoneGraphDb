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
%% Created: August 26, 2008
%% Description: dictionary_sup is the supervisor for all of the dictionary
%%				workers. It is the callback module for the erlang Supervisor Behaviour.
%%  
%% Resources for understanding the erlang Supervisor behaviour
%%  OTP behaviour see http://www.erlang.org/doc/design_principles/part_frame.html starting section 5.0
%%  Supervisor Documentation: http://www.erlang.org/doc/man/supervisor.html
%%	Supervisor Behaviour: http://www.erlang.org/doc/design_principles/sup_princ.html#5
%%	Supervisor callback exports: http://erlang.org/documentation/doc-5.0.1/lib/stdlib-1.9.1/doc/html/supervisor.html
%%--------------------------------------------------------------------- 
%% Revision History
%%--------------------------------------------------------------------- 
%% Rev PA1 Date: August 26, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%% 
%%--------------------------------------------------------------------- 
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%  
%%--------------------------------------------------------------------- 
-module(dictionary_sup).
-behaviour(supervisor).  


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: 1 ').
-created('Date: August 16, 2008 17:15:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: August 1, 2008 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%--------------------------------------------------------------------- 
%% Include files
%%--------------------------------------------------------------------- 
-import(lists, [map/2]).


%%
%% Macro Functions
%%--------------------------------------------------------------------- 
%% NYI - Not Yet Implemented
%%	X = {fun,{Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun,{}Arg1,Arg2,...}}
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

%%--------------------------------------------------------------------- 
%% Exports External.
%%--------------------------------------------------------------------- 
-export([
		start_link/0
		]).


%%--------------------------------------------------------------------- 
%% Exports Behaviour Callback for -behavior(Supervisor).
%%--------------------------------------------------------------------- 

-export([
		init/1 
		]).



%%--------------------------------------------------------------------- 
%%--------------------------------------------------------------------- 
%% Function Definitions External.
%%--------------------------------------------------------------------- 
%%--------------------------------------------------------------------- 

start_link() ->
	supervisor:start_link(dictionary_sup, []).


%%--------------------------------------------------------------------- 
%%--------------------------------------------------------------------- 
%% Function Definitions Behaviour Callback.
%%--------------------------------------------------------------------- 
%%--------------------------------------------------------------------- 

%%--------------------------------------------------------------------- 
%%  init/1
%%    Module:init(StartArgs) -> Return
%%
%%      Types:
%%            SupFlags = {restart_strategy(), MaxR, MaxT}
%%            restart_strategy() = one_for_all | 
%%								   one_for_one | 
%%								   rest_for_one | 
%%								   simple_one_for_one
%%            MaxR = int() >= 0
%%            MaxT = int() > 0
%%            ChildSpec = child_spec()
%%			  Return = {ok, {SupFlags, [ChildSpec]}} | 
%%					   ignore | 
%%					   {error, Reason}
%%
%% The supervisor is responsible for starting, stopping and monitoring its child processes. 
%% The basic idea of a supervisor is that it should keep its child processes 
%% alive by restarting them when necessary.
%%
%% The children of a supervisor is defined as a list of child specifications. 
%% When the supervisor is started, the child processes are started in order from 
%% left to right according to this list. When the supervisor terminates, 
%% it first terminates its child processes in reversed start order, from right to left. 
%%
%% restart_strategies:
%%    * one_for_one - if one child process terminates and should be restarted, 
%%					only that child process is affected.
%%    * one_for_all - if one child process terminates and should be restarted, 
%%					all other child processes are terminated and then all child processes are restarted.
%%    * rest_for_one - if one child process terminates and should be restarted, 
%%					the 'rest' of the child processes -- i.e. the child processes after the 
%%					terminated child process in the start order -- are terminated. 
%%					Then the terminated child process and all child processes after it are restarted.
%%	  * simple_one_for_one - a simplified one_for_one supervisor, where all child processes are 
%%					dynamically added instances of the same process type, i.e. running the same code.
%%					see: http://www.erlang.org/doc/design_principles/sup_princ.html#5.9
%%      
%%  The functions terminate_child/2, delete_child/2 and restart_child/2 are invalid for simple_one_for_one supervisors and will return {error,simple_one_for_one} if the specified supervisor uses this restart strategy.
%%
%%	MaxR is the maximum number of restarts which can be performed within MaxT seconds.
%%
%%  When the restart strategy is simple_one_for_one, the list of child specifications 
%%	must be a list with one element only. This child is not started during the
%%	initialization phase, but all children are started dynamically. Each dynamically 
%%	started child is of the same type, which means that all children are instances 
%%	of the initial child specification. New children are created with a call to 
%%	start_child(Supervisor, ExtraStartArgs).
%%
%%  If a child start function returns ignore, the child is kept in the 
%%	supervisor's list of children. The child can be restarted explicitly 
%%	by calling restart_child/2. The child is also restarted if the supervisor 
%%	is one_for_all and performs a restart of all children, or if the 
%%	supervisor is rest_for_one and performs a restart of this child. 
%%	The supervisor start-up fails and terminates if the 
%%	child start function returns {error, Reason}
%%
%%  This function can return ignore in order to inform the parent, 
%%	especially if it is another supervisor, that the supervisor is not 
%%	started according to configuration data, for instance. 
%%
%%				child_spec() = {Id,StartFunc,Restart,Shutdown,Type,Modules}
%%				 Id = term()
%%				 StartFunc = {M,F,A}
%%					M = F = atom()
%%					A = [term()]
%%				 Restart = permanent | transient | temporary
%%				 Shutdown = brutal_kill | int()>=0 | infinity
%%				 Type = worker | supervisor
%%				 Modules = [Module] | dynamic
%%					Module = atom()
%%
%%    * Id is a name that is used to identify the child specification internally by the supervisor.
%%    * StartFunc defines the function call used to start the child process. 
%%		It should be a module-function-arguments tuple {M,F,A} used as apply(M,F,A).
%%
%%      The start function must create and link to the child process, and should return {ok,Child} 
%%		or {ok,Child,Info} where Child is the pid of the child process and Info an arbitrary term 
%%		which is ignored by the supervisor.
%%
%%      The start function can also return ignore if the child process for some 
%%		reason cannot be started, in which case the child specification will be 
%%		kept by the supervisor but the non-existing child process will be ignored.
%%
%%      If something goes wrong, the function may also return an error tuple {error,Error}.
%%
%%  Note that the start_link functions of the different behaviour modules fulfill the above requirements.
%%    * Restart defines when a terminated child process should be restarted. 
%%		A permanent child process should always be restarted, a temporary child process should never be restarted and a transient child process should be restarted only if it terminates abnormally, i.e. with another exit reason than normal.
%%    * Shutdown defines how a child process should be terminated. 
%%		brutal_kill means the child process will be unconditionally terminated using exit(Child,kill). 
%%		An integer timeout value means that the supervisor will tell the child process to terminate by 
%%		calling exit(Child,shutdown) and then wait for an exit signal with reason shutdown back from the 
%%		child process. If no exit signal is received within the specified time, the child process is 
%%		unconditionally terminated using exit(Child,kill).
%%      If the child process is another supervisor, Shutdown should be set to infinity to give the subtree ample time to shutdown.
%%
%%      Important note on simple-one-for-one supervisors: 
%%		The dynamically created child processes of a simple-one-for-one supervisor are not 
%%		explicitly killed, regardless of shutdown strategy, but are expected to terminate when 
%%		the supervisor does (that is, when an exit signal from the parent process is received).
%%
%%  Note that all child processes implemented using the standard OTP behavior modules 
%%  automatically adhere to the shutdown protocol.
%%    * Type specifies if the child process is a supervisor or a worker.
%%    * Modules is used by the release handler during code replacement to 
%%		determine which processes are using a certain module. 
%%		As a rule of thumb Modules should be a list with one element [Module], 
%%		where Module is the callback module, if the child process is a 
%%		supervisor, gen_server or gen_fsm. If the child process is an 
%%		event manager (gen_event) with a dynamic set of callback modules, 
%%		Modules should be dynamic. See OTP Design Principles for more information about release handling.
%%    * Internally, the supervisor also keeps track of the pid Child of 
%%		the child process, or undefined if no pid exists.
%%--------------------------------------------------------------------- 
init([]) -> 
%% Start Supervisors (eg. SUP1, SUP2,....)
	%% Set Supervisory Flags:
 		Restart_Strategy = one_for_one, %% one_for_all | one_for_one | rest_for_one | simple_one_for_one
  		MaxR = 5, 					%% maximum number of restarts
		MaxT = 5000, 				%% restart period,
	SupFlags = {Restart_Strategy, MaxR, MaxT}, 
	{ok, ChSpec1} = childspec(dictionary_server),	
	{ok, ChSpec2} = childspec(term_server),			
	{ok, {SupFlags, [ChSpec1, ChSpec2]}};
init(State) -> 
	?NYI({init, {State}}),
	ignore.

%% make a copy one this fun() for each child process.
%% Increment number and add to init/1.
%% NOTE USE EITHER SUPERVISORS OR WORKERS BUT NOT BOTH!
childspec(Name) -> %% use the name if the specs are identical otherwise copy as childspec(1), childspec(2)....for each of the children with unique specs.
	%% Define Wkr1 child_spec
		Id = Name, %Id = term()
		StartFunc = {Id, start_link, []}, %% module-function-arguments tuple used as apply(M, F, A).
		Restart = permanent, 	%% Restart = permanent | transient | temporary
		Shutdown = brutal_kill, %% Shutdown = brutal_kill | int()>=0 | infinity
		Type = worker, 			%% Type = worker | supervisor
		Module = Name,			%% name of the callback module
		Modules = [Module], 	%% Modules = [Module] | dynamic
	ChildSpec = {Name, StartFunc, Restart, Shutdown, Type, Modules},
	{ok, ChildSpec}.	

