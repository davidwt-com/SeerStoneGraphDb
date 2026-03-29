%%----------------------------------------------------------------------------- 
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be 
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of 
%% SeerStone, Inc.
%%
%%  All page references are to Joe Armstrong's Programming Erlang.
%%----------------------------------------------------------------------------- 
%% Author: Dallas Noyes
%% Created: October 2, 2008
%% Description: SeerStone Dictionary implementation using ETS.
%%----------------------------------------------------------------------------- 
%% Revision History
%%----------------------------------------------------------------------------- 
%% Rev PA1 Date: October 2, 2008 
%% Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%% 
%%----------------------------------------------------------------------------- 
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%  
%% 
%% 
%%----------------------------------------------------------------------------- 

-module(dictionary_imp).

%% Macro Functions
%%----------------------------------------------------------------------------- 
%% NYI is from Joe Armstrongs boook pg. 424
%% 		"Not Yet Implemented" returns message when a function is called
%%		that is NYI.
%%
%%		copy this into each file where you are working and then use as:
%%			glurk(X, Y) -> 
%%				?NYI({glurk, X, Y}).  
%% 
%% NYI - Not Yet Implemented
%%	X = {fun,Arg1,Arg2,...}
%%
%% UEM - UnExpected Message
%%	F = {fun,Arg1,Arg2,...}
%%	X = Message
%%----------------------------------------------------------------------------- 

-define(NYI(X), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).



%%----------------------------------------------------------------------------- 
%% Module Attributes
%%----------------------------------------------------------------------------- 
-revision('Revision: 1 ').
-created('Date: October 2, 2008 10:50:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: August 1, 2008 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%---------------------------------------------------------------------
%% Data Structures
%%---------------------------------------------------------------------
%% Data Type: 
%% where:
%%----------------------------------------------------------------------
%%
%% N/A

%%---------------------------------------------------------------------
%% Mnesia Configuration Parameters
%%---------------------------------------------------------------------
%%
%% N/A

%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
%%
%% N/A

%%---------------------------------------------------------------------
%% Exported Functions
%%--------------------------------------------------------------------- 
%% Description module dictionary_imp
%%--------------------------------------------------------------------- 
%% The dictionary_imp is the implementation module for the SeerStone
%% The dictionary is memory based and uses Erlang ETS as the basis.
%%
%% All dictionary semantics are CRUD
%% 
%%--------------------------------------------------------------------- 
%% Exports U/I
%%--------------------------------------------------------------------- 
%% Description of U/I Exported functions
%%   
%% 
%%--------------------------------------------------------------------- 

-export([ 
		create/2,
		read/2,
		update/3,	
		delete/2,

		all/1,
		size/1,	

		start_dictionary/2,
		stop_dictionary/2,
		delete_dictionary/2	
		]).


%% Exports Intermodule
%%--------------------------------------------------------------------- 
%% Description of Intermodule Exported functions
%%--------------------------------------------------------------------- 
%%
%% None


%% Exports Internal
%%--------------------------------------------------------------------- 
%% Description of Internal Exported functions
%%--------------------------------------------------------------------- 
%%
%% None


%%--------------------------------------------------------------------- 
%% API Function Definitions
%%--------------------------------------------------------------------- 

start_dictionary(File, Proc_Name) -> 
	%% defines File initialization method for "ETS".
	F1 = fun(F)-> Tab = ets:new(words,[private,set]), put("tab", Tab), ets:tab2file(Tab, F) end,  
	%% defines File load to memory for "pds" and starts loop().
	F2 = fun() -> {ok,Tab} = ets:file2tab(File),  
				  put("tab",Tab),
			 	  loop()
				  end,	
	file_exists(File, F1), %% makes sure File exists, creates new File if needed.
	start_registered_process(Proc_Name, F2).							


%%
%% makes sure file exists, creates new file if needed.
%% Fun is the fun() to create the file. 
%%
file_exists(File, Fun) -> 
	case filelib:is_file(File) of
		true -> ok;			%% dictionary exists.
		false -> Fun(File)	%% empty dictionary created.
	end.


%% start a registerd process with Proc_Name and the Fun.
%% Fun is the fun() to load the Proc_Name into memory for the file and start the loop.  It is defined for each type in start_dictionary.
start_registered_process(Proc_Name, Fun) ->
	case is_pid(whereis(Proc_Name))of
		false -> register(Proc_Name, spawn(Fun)), ok;  %% no Proc_Name process is defined.
		true -> logger:warning("~p process is already started", [Proc_Name])	
	end.


rpc(F, Proc_Name) ->
	case is_pid(whereis(Proc_Name))of
		true ->
			Proc_Name ! {self(),F},
			receive
				{Proc_Name, Reply} -> Reply
			end;
		false ->
			logger:warning("~p not open", [Proc_Name])
		end.


loop() ->
	receive
		{From, F} -> F(From), 
		loop()
	end.



%% Note that all of these functions always succeed.  This is true even if there is no Proc_Name.
%% This might need to send a message saying that it failed because there was no Proc_Name.

create(Proc_Name, Key) -> 
	rpc(fun(From) -> From!{Proc_Name, ets:insert_new(get("tab"), {list_to_binary(Key)})} end, Proc_Name).

read(Proc_Name, Key) -> 	
	rpc(fun(From) -> From!{Proc_Name, ets:lookup(get("tab"),list_to_binary(Key))} end, Proc_Name).

update(Proc_Name, Key, Value) ->
	rpc(fun(From) -> From!{Proc_Name, ets:insert(get("tab"),{list_to_binary(Key),Value})} end, Proc_Name).

delete(Proc_Name, Key) ->
	rpc(fun(From) -> From!{Proc_Name,ets:delete(get("tab"),{list_to_binary(Key)})} end, Proc_Name).

all(Proc_Name) -> 
	rpc(fun(From) -> From!{Proc_Name, ets:tab2list(get("tab"))} end, Proc_Name).

%% Returns the number of keys in the open Proc_Name.	
size(Proc_Name)-> 
	rpc(fun(From) -> From!{Proc_Name, ets:info(get("tab"), size)} end, Proc_Name).


stop_dictionary(File, Proc_Name) -> 
	rpc(fun(From) ->
		Tab = get("tab"),
		ets:tab2file(Tab, File),
		ets:delete(Tab),		
		From!{Proc_Name,ok},
		exit({stop_dictionary,File}) 
		end, 
	Proc_Name),
	ok.


delete_dictionary(Type, File) -> 
	Proc_Name = dictionary,
	case is_pid(whereis(Proc_Name))of
		true ->	stop_dictionary(Type,File),		%% process is open.
			file:delete(File);					%% note that stop_dictionary flushes the pds to File and exists the process.  File is then deleted, so it doesn't matter if the process had opened File or not.
		false -> case filelib:is_file(File) of 	%% process is not open
			true -> file:delete(File);			%% file exists so delete it.
			false -> logger:warning("can't find ~p to delete", [File]), true %% file does not exits so you'r done.
			end 	
	end.


