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
%% Description: nref_server serves Nrefs.
%%				nref_server is a client of the nref_allocator.
%%
%%				The servers work from blocks of Nrefs that they request from
%%				the nref_allocator.  As they allocate a block they confirm the allocation
%%				with the nref_allocator.
%%
%% This is a server callback module for the erlang server behavior (gen_server).
%%
%% Resources for understanding the erlang server (gen_server) behaviour:
%%  gen_server manual: http://www.erlang.org/doc/man/gen_server.html
%%  OTP behaviour see http://www.erlang.org/doc/design_principles/part_frame.html starting section 2.0
%%  Server Behaviour: http://www.erlang.org/doc/design_principles/gen_server_concepts.html#2
%%	Server callback exports: http://erlang.org/documentation/doc-5.0.1/lib/stdlib-1.9.1/doc/html/gen_server.html
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev Initial Date: October 10, 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Initial implementation and testing of module completed.
%%---------------------------------------------------------------------
%% Rev A Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%%
%%---------------------------------------------------------------------
-module(nref_server).
-behaviour(gen_server).


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
%% Macro Functions
%%---------------------------------------------------------------------
%% NYI - Not Yet Implemented
%%	F = {fun,{Arg1,Arg2,...}}
%%
%% UEM - UnExpected Message
%%	F = {fun,{Arg1,Arg2,...}}
%%	X = Message
%%---------------------------------------------------------------------
-define(NYI(F), (begin
					io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, F]),
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
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,			%% Starts and links the gen_server.
		get_nref/0, 			%% returns a single nref and adds it to the allocation tracker.
		confirm_nref/1,			%% removes nref from the confirm list.
		confirm_nrefs/1,		%% removes list of nrefs from the confirm list.
		reuse_nref/1,			%% adds nref to the reuse list.
		reuse_nrefs/1,			%% adds list of nrefs to the reuse list.
		confirm_nref_block/2	%% logs the allocation of an nref and removes it from the allocation tracker.
		]).

%%---------------------------------------------------------------------
%% Exports Behaviour Callback for -behaviour(gen_server).
%%---------------------------------------------------------------------

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
%% Starts the nref_server gen_server and registers it locally.
%%-----------------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% get_nref() -> Nref
%%-----------------------------------------------------------------------------
get_nref() ->
	gen_server:call(?MODULE, get_nref).


%%-----------------------------------------------------------------------------
%% confirm_nref(Nref) -> ok
%%-----------------------------------------------------------------------------
confirm_nref(Nref) ->
	gen_server:call(?MODULE, {confirm_nref, Nref}).


%%-----------------------------------------------------------------------------
%% confirm_nrefs(List) -> ok
%%-----------------------------------------------------------------------------
confirm_nrefs(List) ->
	gen_server:call(?MODULE, {confirm_nrefs, List}).


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
%% confirm_nref_block(Nref, Count) -> ok
%%-----------------------------------------------------------------------------
confirm_nref_block(Nref, Count) ->
	gen_server:call(?MODULE, {confirm_nref_block, Nref, Count}).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init([]) -> {ok, State}
%%
%% Opens the DETS file for this nref_server instance.
%%-----------------------------------------------------------------------------
init([]) ->
	open("nref_server.dets"),
	{ok, []}.


%%-----------------------------------------------------------------------------
%% handle_call/3
%%-----------------------------------------------------------------------------
handle_call(get_nref, _From, State) ->
	Reply = do_get_nref(),
	{reply, Reply, State};
handle_call({confirm_nref, Nref}, _From, State) ->
	Reply = do_confirm_nref(Nref),
	{reply, Reply, State};
handle_call({confirm_nrefs, List}, _From, State) ->
	Reply = do_confirm_nrefs(List),
	{reply, Reply, State};
handle_call({reuse_nref, Nref}, _From, State) ->
	Reply = do_reuse_nref(Nref),
	{reply, Reply, State};
handle_call({reuse_nrefs, List}, _From, State) ->
	Reply = do_reuse_nrefs(List),
	{reply, Reply, State};
handle_call({confirm_nref_block, Nref, Count}, _From, State) ->
	Reply = do_confirm_nref_block(Nref, Count),
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
%% open(File) -> true | exit(nref_server_open)
%%
%% Opens the DETS file. Initializes it if it did not previously exist.
%%-----------------------------------------------------------------------------
open(File) ->
    io:format("dets opened:~p~n", [File]),
    Bool = filelib:is_file(File),
    case dets:open_file(?MODULE, [{file, File}]) of
	{ok, ?MODULE} ->
	    case Bool of
		true  -> void;					%% File exists and opened successfully
		false -> ok = initialize(File) 	%% Initializes the dets file: File did not exist, but was opened successfully.
	    end,
	    true;
	{error, Reason} ->
	    io:format("cannot open dets table ~p~n", [Reason]),
    	exit(nref_server_open)
    end.


close() -> dets:close(?MODULE).


%% nref_server uses DETS
%%	free is the current available nref to allocate (and increment).
%%	top is the last nref in the block to allocate before requesting more from the nref_allocator.
%%	reuse is a list of nrefs to use in precedence to free.
%%  confirm is the list of nrefs that have been allocated but not yet confirmed as used.
initialize(_File) ->
	dets:insert(?MODULE, [{free,1},{top, 1},{reuse,[]}, {confirm,[]}]),
	ok.


%%-----------------------------------------------------------------------------
%% do_get_nref() -> Nref
%%
%% Returns a single nref.
%% Takes the nref off the top of the reuse list if available.
%% Otherwise increments the free counter.
%% Adds the nref to the confirm list in any case.
%%-----------------------------------------------------------------------------
do_get_nref() ->
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
%% Increments the free counter and adds the nref to the confirm list.
%% called only by do_get_nref/0.
increment(N) when is_integer(N) ->
	case dets:lookup(?MODULE, confirm) of
	[] ->
		dets:insert(?MODULE, [{free, N + 1}, {confirm, [N]}]);
	[{confirm, T}] ->
		dets:insert(?MODULE, [{free, N + 1}, {confirm, [N|T]}])
	end.


%% Is the Allocator really responsible for confirmation messaging?  If so how?  Do the requestors confirm to the allocation process?
%% Is the Allocator responsible for reuse?
%%
do_confirm_nref(Nref) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		Confirm_list_new = lists:delete(Nref, T),
		dets:insert(?MODULE, {confirm, Confirm_list_new}).

do_confirm_nrefs(List) ->
	[{confirm, T}] = dets:lookup(?MODULE, confirm),
		Confirm_list_new = lists:subtract(List, T),
		dets:insert(?MODULE, {confirm, Confirm_list_new}).

%% do_confirm_nref_block(Nref, Count) -> ok
%% Called to take the block out of the {block,_} watch list.
do_confirm_nref_block(Nref, Count) ->
	L = dets:lookup(?MODULE, block),
	L2 = lists:delete({Nref,Count},L),
	ok = dets:insert(?MODULE, [{block, L2}]),
	ok.


do_reuse_nref(Nref) when is_integer(Nref) ->
	case dets:lookup(?MODULE, reuse) of
	[] ->
		dets:insert(?MODULE, {reuse, [Nref]});
	[{reuse,T}] ->
		dets:insert(?MODULE, {reuse, [Nref|T]})
	end.

do_reuse_nrefs(List) ->
	[{reuse,T}] = dets:lookup(?MODULE, reuse),
		Reuse_list = lists:append(List,T),
		dets:insert(?MODULE, {reuse, Reuse_list}).
