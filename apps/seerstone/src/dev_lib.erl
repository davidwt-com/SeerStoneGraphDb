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
%% Created: Aug 18, 2008
%% Description: dev_lib is a collecton of functions useful in development
%%--------------------------------------------------------------------- 
%% Revision History
%%--------------------------------------------------------------------- 
%% Rev PA1 Date: August 18, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%% 
%%--------------------------------------------------------------------- 
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%  
%% 
%% 
%%--------------------------------------------------------------------- 

-module(dev_lib).



%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: 1 ').
-created('Date: August 18, 2008 10:41:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: August 18, 2008 10:41:00').
%%-modified_by('dallas.noyes@gmail.com').




%%
%% Include files
%%


%%
%% Macro Functions
%%--------------------------------------------------------------------- 
%% NYI is from Joe Armstrongs boook pg. 424
%% 		"Not Yet Implemented" returns message when a function is called
%%		that is NYI.
%%
%%		copy this into each file where you are working and then use as:
%%			glurk(X, Y) -> 
%%				?NYI({glurk, X, Y}).
%%
%% UEM "UnExpected Message" returns message when a function returns an
%%		unexpected message.
%%
%%		copy this into each file where you are working and then use as:
%%			fun1() -> ......
%%				receive
%%					Other ->
%%						?UEM(fun1, Other)
%% 				end
%%
%%--------------------------------------------------------------------- 

-define(NYI(X), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).


%%
%% API Function Definitions
%%
%%--------------------------------------------------------------------- 
%% trace_module(Mod, StartFun)
%%   A simple tracer based on Joe Armstrongs example on page 428.
%%	 Traces all fuinciton calls and return values in the module MOD
%% 
%%--------------------------------------------------------------------- 


%%
%% Exported Functions
%%--------------------------------------------------------------------- 
%% Description module dev_lib
%%--------------------------------------------------------------------- 
%% dev_lib is a collection of functions useful in development
%% 
%% 
%%--------------------------------------------------------------------- 
%% Exports U/I
%%--------------------------------------------------------------------- 
%% trace_module(Mod, StartFun) 
%%		a simple trace function that traces all
%%		calls and returns.
%% test_dbg()
%%		same as trace_module but using the library dbg.  
%%		this hides all the details of the low-level Erlang BIFs.
%%		this needs to be copied into your code and modified.
%%		Example from pg 430 of Joe Armstrongs book.
%% dump(File, Term)	
%%		If the data structure is large, then write it to a file
%%		for later inspection.			
%%   
%% 
%%--------------------------------------------------------------------- 

-export([
		trace_module/2,
		dump/2	
		]).


%%
%% API Function Definitions
%%
%%--------------------------------------------------------------------- 
%% trace_module(Mod, StartFun)
%%   A simple tracer based on Joe Armstrongs example on page 428.
%%	 Traces all fuinciton calls and return values in the module MOD
%% 
%%--------------------------------------------------------------------- 

trace_module(Mod, StartFun) ->
	%% spawn a process to do the tracing
	spawn(fun() -> trace_module1(Mod, StartFun) end).

trace_module1(Mod, StartFun) -> 
	%% The next line says: trace all funciton calls and return
	%%			values in Mod.
	erlang:trace_pattern({Mod, '_','_'},	
						 [{'_',[], [{return_trace}]}],
						 [local]),
	%% spawn a function to do the tracing
	S = self(),
	Pid = spawn(fun() -> do_trace(S, StartFun) end),
	%% setup the trace.  Tell the system to start tracing
	%% the prcess Pid
	erlang:trace(Pid, true, [call, procs]),
	%% now tell Pid to start
	Pid ! {S, start},
	trace_loop().

%% do_trace evaluates StartFun()
%%		when it is told to do so by Parent.
do_trace(Parent, StartFun) ->
	receive
		{Parent, start} ->
			StartFun()
	end.

%% trace_loop displays the function call and return values.
trace_loop() ->
	receive
		{trace,_,call, X} ->
			io:format("Call: ~p~n",[X]),
			trace_loop();
		{trace, _, return_from, Call, Ret} ->
			io:format("~p => ~p~n",[Call, Ret]),
			trace_loop();
		Other ->
			io:format("Other = ~p~n",[Other]),
			trace_loop()		
	end.


%%--------------------------------------------------------------------- 
%% test_dbg()
%%		same as trace_module but using the library dbg.  
%%		this hides all the details of the low-level Erlang BIFs.
%%		this needs to be copied into your code and modified.
%%		Example from pg 430 of Joe Armstrongs book.
%% 
%%--------------------------------------------------------------------- 
%%test_dbg() ->
%%	dbg:tracer(),
%%	dbg:tpl(traccer_test, your_function_name, '_',
%%			dbg:fun2ms(fun(_) -> return_trace() end)),
%%	dbg:p(all,[c]),
%%	your_module:your_function_call.

%%--------------------------------------------------------------------- 
%% dump(File, Term)
%%		If the data structure is large, then write it to a file
%%		for later inspection.			
%% 
%%--------------------------------------------------------------------- 
dump(File, Term) ->
	Out = File ++ ".tmp",
	io:format("** dumpng to ~s~n", [Out]),
	{ok, S} = file:open(Out, [write]),
	io:format(S, "~p~n", [Term]),
	file:close(S).

