%%-----------------------------------------------------------------------------
%% Copyright SeerStone, Inc. 2008
%%
%% All rights reserved. No part of this computer programs(s) may be
%% used, reproduced,stored in any retrieval system, or transmitted,
%% in any form or by any means, electronic, mechanical, photocopying,
%% recording, or otherwise without prior written permission of
%% SeerStone, Inc.
%%-----------------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: October 9, 2008
%% Description: The nref_allocator allocates blocks of Nrefs to the nref_servers
%%				The nref_servers request a block by calling
%%				The nref_servers confirm the use of the block.
%%
%%-----------------------------------------------------------------------------
%% Revision History
%%-----------------------------------------------------------------------------
%% Rev initial Date: October 9, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%%-----------------------------------------------------------------------------
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%-----------------------------------------------------------------------------
-module(nref_allocator).
-behaviour(gen_server).


%%-----------------------------------------------------------------------------
%% Module Attributes
%%-----------------------------------------------------------------------------
-revision('Revision: 1 ').
-created('Date: October 9, 2008 17:15:00').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: Month Day, Year 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%-----------------------------------------------------------------------------
%% Include files
%%-----------------------------------------------------------------------------
%%-----------------------------------------------------------------------------
%% Macro Functions
%%-----------------------------------------------------------------------------
%% NYI - Not Yet Implemented
%%	F = {fun,{Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun,{Arg1,Arg2,...}}
%%	X = Message
%%-----------------------------------------------------------------------------
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
					exit(nyi)
				 end)).
-define(UEM(F, X), (begin
					io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
					exit(uem)
				 end)).


%%=============================================================================
%% Exported Functions
%%=============================================================================
%%=============================================================================
%% Exports External API
%%=============================================================================

-export([
		start_link/0,		%% Starts and links the gen_server.
		allocate_nrefs/0,	%% allocates a block of nrefs.
		reuse_nref/1,		%% adds nref to the reuse list.
		reuse_nrefs/1,		%% adds list of nrefs to the reuse list.
		used_nref_block/1,	%% logs the allocation of an nref and removes it from the allocation tracker.
		used_nref/1,		%% removes nref from the confirm list.
		used_nrefs/1,		%% removes list of nrefs from the confirm list.
		update_block_size/1 %% updates the block size.
		]).

%%-----------------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%-----------------------------------------------------------------------------

-export([
		init/1,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/3
		]).


%%=============================================================================
%% Exported External API Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% start_link() -> {ok, Pid} | {error, Reason}
%%
%% Starts the nref_allocator gen_server and registers it locally.
%%-----------------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% allocate_nrefs() -> {Nref_list} | {Start, End} | {error, Reason}
%%-----------------------------------------------------------------------------
allocate_nrefs() ->
	gen_server:call(?MODULE, allocate_nrefs).


%%-----------------------------------------------------------------------------
%% reuse_nref(Nref) -> ok
%%-----------------------------------------------------------------------------
reuse_nref(Nref) when is_integer(Nref) ->
	gen_server:call(?MODULE, {reuse_nref, Nref}).


%%-----------------------------------------------------------------------------
%% reuse_nrefs(List) -> ok
%%-----------------------------------------------------------------------------
reuse_nrefs(List) ->
	gen_server:call(?MODULE, {reuse_nrefs, List}).


%%-----------------------------------------------------------------------------
%% used_nref(Nref) -> ok
%%-----------------------------------------------------------------------------
used_nref(Nref) when is_integer(Nref) ->
	gen_server:call(?MODULE, {used_nref, Nref}).


%%-----------------------------------------------------------------------------
%% used_nrefs(List) -> ok
%%-----------------------------------------------------------------------------
used_nrefs(List) ->
	gen_server:call(?MODULE, {used_nrefs, List}).


%%-----------------------------------------------------------------------------
%% used_nref_block(Block) -> ok
%%-----------------------------------------------------------------------------
used_nref_block(Block) ->
	gen_server:call(?MODULE, {used_nref_block, Block}).


%%-----------------------------------------------------------------------------
%% update_block_size(Size) -> ok
%%-----------------------------------------------------------------------------
update_block_size(Size) ->
	gen_server:call(?MODULE, {update_block_size, Size}).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init([]) -> {ok, State}
%%
%% Opens the DETS file. Initializes it if it did not previously exist.
%%-----------------------------------------------------------------------------
init([]) ->
	ok = open(),
	{ok, []}.


%%-----------------------------------------------------------------------------
%% handle_call/3
%%-----------------------------------------------------------------------------
handle_call(allocate_nrefs, _From, State) ->
	Reply = do_allocate_nrefs(),
	{reply, Reply, State};
handle_call({reuse_nref, Nref}, _From, State) ->
	Reply = do_reuse_nref(Nref),
	{reply, Reply, State};
handle_call({reuse_nrefs, List}, _From, State) ->
	Reply = do_reuse_nrefs(List),
	{reply, Reply, State};
handle_call({used_nref, Nref}, _From, State) ->
	Reply = do_used_nref(Nref),
	{reply, Reply, State};
handle_call({used_nrefs, List}, _From, State) ->
	Reply = do_used_nrefs(List),
	{reply, Reply, State};
handle_call({used_nref_block, Block}, _From, State) ->
	Reply = do_used_nref_block(Block),
	{reply, Reply, State};
handle_call({update_block_size, Size}, _From, State) ->
	Reply = do_update_block_size(Size),
	{reply, Reply, State};
handle_call(Request, From, State) ->
	?UEM(handle_call, {Request, From, State}),
	{noreply, State}.


%%-----------------------------------------------------------------------------
%% handle_cast/2
%%-----------------------------------------------------------------------------
handle_cast(Message, State) ->
	?UEM(handle_cast, {Message, State}),
	{noreply, State}.


%%-----------------------------------------------------------------------------
%% handle_info/2
%%-----------------------------------------------------------------------------
handle_info(Info, State) ->
	?UEM(handle_info, {Info, State}),
	{noreply, State}.


%%-----------------------------------------------------------------------------
%% terminate/2
%%-----------------------------------------------------------------------------
terminate(_Reason, _State) ->
	close(),
	ok.


%%-----------------------------------------------------------------------------
%% code_change/3
%%-----------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	?NYI(code_change),
	{ok, State}.


%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% open() -> ok | {error, Reason}
%%
%% Opens the DETS file for the nref_allocator data.
%%-----------------------------------------------------------------------------
open() ->
	File = "nref_allocator.dets",    %% File name is set here.
	Bool = filelib:is_file(File),  %% check this before you open the file, because dets:open_file creates the file if it doesn't exist.
    logger:info("opening dets file: ~p", [File]),
    case dets:open_file(?MODULE, [{file, File}]) of
	{ok,?MODULE} ->
	    case Bool of
		true  -> ok;	%% File exists and opened successfully
		false ->  		%% Initializes the dets file: File did not exist, but was opened successfully.
				dets:insert(?MODULE,
							[{block_size, 500},	%% block size for allocation.
						  	{free, 1},			%% next nref available for allocation.
						  	{reuse,[]},			%% list of nrefs available for allocation.
						  	{confirm,[]}, 		%% list of nrefs that have been allocated, but not yet confirmed as used
						  	{allocated, []}		%% {allocated, [{Start, End}]} list of blocks {Start, End} with the Start and End nrefs of the block.
							]),
		ok
	    end;
	{error, Reason} ->
	    logger:error("cannot open dets table: ~p", [Reason]),
    	exit(Reason),
		{error, Reason}
    end.


%%-----------------------------------------------------------------------------
%% close() -> ok | {error, Reason}
%%-----------------------------------------------------------------------------
close() -> dets:close(?MODULE).


%%-----------------------------------------------------------------------------
%% do_allocate_nrefs() -> {Nref_list} | {Start, End} | {error, Reason}
%%
%% If there are enough reused nrefs, return them; otherwise allocate a fresh block.
%%-----------------------------------------------------------------------------
do_allocate_nrefs() ->
	case get_reused() of 	%% get the nrefs from the reuse list and send them.
	{[]} ->					%% return if there are not enought reuse nrefs in list.
		get_block();  		%% get a block of nrefs
	{L} ->
		{L}
	end.


%% get a block of nrefs from the reuse stack iff there are more nrefs than block_size...send them all.
get_reused() ->
	[{block_size, B}] = dets:lookup(?MODULE, block_size),
	case dets:lookup(?MODULE, reuse) of
	[{reuse,  [S|L]}] ->
		case S >= B of
		true ->
				ok = dets:insert(?MODULE, [{reuse, []}]), %% update the reuse list
				{L};
		false  -> {[]}
		end;
	[_] -> {[]}
	end.


%% get a block of nrefs as
get_block() ->
    case dets:lookup(?MODULE, free) of
	[{free, Nref}] ->
		case dets:lookup(?MODULE, block_size) of
		[{block_size, Blocksize}] ->
			Next = Nref + Blocksize,
			case dets:lookup(?MODULE, allocated) of
			[] ->
				ok = dets:insert(?MODULE, [{free, Next + 1}, {allocated, [{Nref, Next}]}]),
				{Nref, Next};
			[{allocated, T}] ->
				ok = dets:insert(?MODULE, [{free, Next + 1}, {allocated, [{Nref, Next}|T]}]),
				{Nref, Next}
			end;
		[] -> {error, no_block_size}
		end;
  	[]     -> {error, no_free}
	end.


%%-----------------------------------------------------------------------------
%% do_reuse_nref(Nref) -> ok
%%
%% Adds a single nref to the reuse list.
%% The first element in the reuse list is the number of nrefs in the list.
%%-----------------------------------------------------------------------------
do_reuse_nref(Nref) when is_integer(Nref) ->
	case dets:lookup(?MODULE, reuse) of
	[{reuse,[L|T]}] ->		%% take the length L and the list T.
		dets:insert(?MODULE, {reuse, [L+1, Nref|T]});
	[_] ->					%% anything else, replace the list
		dets:insert(?MODULE, {reuse, [1, Nref]})
	end.


%%-----------------------------------------------------------------------------
%% do_reuse_nrefs(List) -> ok
%%
%% Adds a list of nrefs to the reuse list.
%%-----------------------------------------------------------------------------
do_reuse_nrefs(List) ->
	L2 = length(List),
	case dets:lookup(?MODULE, reuse) of
	[{reuse,[L1|T]}] ->    	%% take the lenght L1 and the list T
		dets:insert(?MODULE, {reuse, [L1 + L2 | lists:append(List, T)]});
	[_] ->					%% anything else, replace the list
		dets:insert(?MODULE, {reuse, [L2 | List]})
	end.


do_used_nref(Nref) when is_integer(Nref) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		dets:insert(?MODULE, {confirm, lists:delete(Nref, T)}).


do_used_nrefs(List) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		dets:insert(?MODULE, {confirm, list_del(List, T)}).


%% used only in do_used_nrefs
list_del([], L) -> L;
list_del([H|T], L) ->
	L2 = lists:delete(H,L),
	list_del(T,L2).


do_used_nref_block(Block) ->
	[{allocated, L}] = dets:lookup(?MODULE, allocated),
	dets:insert(?MODULE, {allocated, lists:delete(Block, L)}).


do_update_block_size(Size) ->
	dets:insert(?MODULE, [{block_size, Size}]).
