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
%% Created: October 10, 2008
%% Description: nref_include is the client side module for the nref Server
%%				The nref_include is the local capability that requests a block of nrefs from the Server
%%				and then hands them out, as needed locally.
%%				
%%				nref_include is the client of the nref_allocator and should be included in any module where nrefs are needed.
%%			
%%				The nref_include works from blocks of Nrefs that are request from
%%				the nref_allocator.  As they allocate a block they confirm the allocation
%%				with the nref_allocator.
%%
%%				The nref_include is also responsible for tracking the deallocation of nrefs,
%%				reusing them locally if possible, or handing them on to the nref_allocation for
%%				reuse.
%% 
%%--------------------------------------------------------------------- 
%% Revision History
%%--------------------------------------------------------------------- 
%% Rev Initial Date: October 10, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%%--------------------------------------------------------------------- 
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%  
%%--------------------------------------------------------------------- 
-module(nref_include).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: 1 ').
-created('Date: October 10, 2008 17:15:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: Month Day, Year 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exported Functions
%%--------------------------------------------------------------------- 
%%--------------------------------------------------------------------- 
%% Exports External API
%%--------------------------------------------------------------------- 
-export([
		open/0, 			%% Opens an nref Dets file.
		close/0, 			%% Closes the nref Dets file.
		initialize/1,		%% initializes the Dets file.
		get_nref/0, 		%% returns a single nref and adds it to the allocation tracker.
		confirm_nref/1,		%% removes nref from the confirm list.
		confirm_nrefs/1,	%% removes list of nrefs from the confirm list.
		reuse_nref/1,		%% adds nref to the reuse list.
		reuse_nrefs/1,		%% adds list of nrefs to the reuse list.
		confirm_nref_block/2%% logs the allocation of an nref and removes it from the allocation tracker.
		]).


%% Each local service keeps track of the nref info in a file called ***nrefs.dets where *** is an integer.
%% When open is called, the module looks at all of the ***nrefs files to find one that is not currently in use, and opens that one.
%% If there is no ***nref file available it requests the next available *** number and opens the file. 
open() ->
	case get_file() of
	ok -> ok;
	{no_file} ->
		nref_allocator! {self(), get_file},
			receive
				{nref_allocator, {get_file, Response}} -> {get_file, Response}
			end,
			open(Response)
	end.


get_file() ->
	%% need to retrieve the systems variable for where the nref files are stored.
	case check_file( filelib:wildcard("*nrefs.dets") ) of
	ok 	-> ok;
	_	-> {no_file}
	end.


check_file([])		-> {no_file};
check_file([H|T]) 	->
	case dets:open_file(H, [{file, H}]) of
	ok -> ok;
	_  -> check_file(T)  %% file in use or error — try next
	end.


open(File) ->
    io:format("dets opened:~p~n", [File]),
    Bool = filelib:is_file(File),
    case dets:open_file(?MODULE, [{file, File}]) of
	{ok, ?MODULE} ->
	    case Bool of
		true  -> void;								 %% File exists and opened successfully
		false -> ok = initialize(File) %% Initializes the dets file: File did not exist, but was opened successfully.
	    end,
	    true;
	{error, Reason} ->
	    io:format("cannot open dets table ~p~n", [Reason]),
    	exit(nref_server_open)
    end.


close() -> dets:close(?MODULE).


%% nref_allocator uses DETS
%%	free is the current available nref to allocate (and increment).
%%	top is the last nref in the block to allocate before requesting more from the nref_server.
%%	reuse is a list of nrefs to use in precedence to free.
%%  confirm is the list of nrefs that have been allocated but not yet confirmed as used.
initialize(_File) ->
	dets:insert(?MODULE, [{free,1},{top, 1},{reuse,[]}, {confirm,[]}]),
	ok.

%% get_nref() -> nref
%% Returns a single nref.
%% Takes the nref off the top of the reuse list if available.
%% Otherwise increments the free counter.
%% adds the nref to the confirm list in any case.
get_nref() ->
	case dets:lookup(?MODULE, reuse) of    %% Reuse released nrefs preferentialy
	[{reuse, []}] 	->
    	case dets:lookup(?MODULE, free) of %% No Reuse availalbe so take next free nref
		[{free, N}] -> 
				case dets:lookup(?MODULE, top) of 
				[{top,N}] ->			   %% Free = Top so request another block.
					get_another_nref_block();
				[_] ->					 	%% Free <> Top so use Free
					increment(N),
	    			N
    			end;
		[] -> 
			get_another_nref_block()
		end;
	[{reuse,[N|T]}]	->
		ok = dets:insert(?MODULE, [{reuse,T}, {confirm,[N]}]),
		N
	end.

get_another_nref_block() ->
	{First, Last} = nref_allocator:allocate_nrefs(),
	dets:insert(?MODULE, [{free,First + 1}, {top,Last}]),
	First.

%% increment(nref) -> ok.				
%% Increments the free list and adds the nref to the confirm list.
%% called only by get_nref/1.
increment(N) when is_integer(N) ->	
	case dets:lookup(?MODULE, confirm) of
	[] ->
		dets:insert(?MODULE, [{free, N + 1}, {confirm, [N]}]);
	[{confirm, T}] ->
		dets:insert(?MODULE, [{free, N + 1}, {confirm, [N|T]}])
	end.

%% Stopped Here
%% Is the Allocator really responsible for confirmation messaging?  If so how?  Do the requestors confirm to the allocation process?
%% Is the Allocator responsible for reuse?
%%
confirm_nref(Nref) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		Confirm_list_new = lists:delete(Nref, T),
		dets:insert(?MODULE, {confirm, Confirm_list_new}).
confirm_nrefs(List) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		Confirm_list_new = lists:subtract(List, T),
		dets:insert(?MODULE, {confirm, Confirm_list_new}).

%% confirm_nref_block(Nref, Count) -> ok
%% Called to take the block out of the {block,_} watch list.
confirm_nref_block(Nref, Count) ->
	L = dets:lookup(?MODULE, block),
	L2 = lists:delete({Nref,Count},L),
	ok = dets:insert(?MODULE, [{block, L2}]),
	ok.


reuse_nref(Nref) when is_integer(Nref) ->
	case dets:lookup(?MODULE, reuse) of
	[] ->
		dets:insert(?MODULE, {reuse, [Nref]});
	[{reuse,T}] ->
		dets:insert(?MODULE, {reuse, [Nref|T]})
	end.

reuse_nrefs(List) ->
	[{reuse,T}] = dets:lookup(?MODULE, reuse),
		Reuse_list = lists:append(List,T),
		dets:insert(?MODULE, {reuse, Reuse_list}).



