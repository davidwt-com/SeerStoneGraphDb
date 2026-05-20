%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: 2026-05-19
%% Description: rel_id_server allocates unique integer IDs for the
%%              #relationship{id} primary key.  Separate from
%%              nref_server so that arc-row IDs do not consume
%%              graph-visible nref integers.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: 2026-05-19 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026-05-19 Author: David W. Thomas
%%
%%---------------------------------------------------------------------
-module(rel_id_server).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: PA1 ').
-created('Date: 2026-05-19').
-created_by('david@davidwt.com').


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
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,	%% Starts and links the gen_server.
		get_id/0		%% Returns next ID, advances counter.
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
%% Starts the rel_id_server gen_server and registers it locally.
%%-----------------------------------------------------------------------------
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%-----------------------------------------------------------------------------
%% get_id() -> integer()
%%
%% Returns the next unique relationship row ID and advances the counter.
%%-----------------------------------------------------------------------------
get_id() ->
	gen_server:call(?MODULE, get_id).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init([]) -> {ok, State}
%%
%% Opens the DETS file for this rel_id_server instance.
%%-----------------------------------------------------------------------------
init([]) ->
	open("rel_id_server.dets"),
	{ok, []}.


%%-----------------------------------------------------------------------------
%% handle_call/3
%%-----------------------------------------------------------------------------
handle_call(get_id, _From, State) ->
	Reply = do_get_id(),
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
	dets:close(?MODULE),
	ok.


%%-----------------------------------------------------------------------------
%% code_change/3
%%-----------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.


%%=============================================================================
%% Internal Functions
%%=============================================================================

%%-----------------------------------------------------------------------------
%% open(File) -> true | exit(rel_id_server_open)
%%
%% Opens the DETS file. Initializes it if the counter key is absent.
%%-----------------------------------------------------------------------------
open(File) ->
	case dets:open_file(?MODULE, [{file, File}]) of
		{ok, ?MODULE} ->
			case dets:member(?MODULE, counter) of
				false -> initialize();
				true  -> void
			end,
			true;
		{error, Reason} ->
			logger:error("cannot open rel_id_server dets table: ~p", [Reason]),
			exit(rel_id_server_open)
	end.


%%-----------------------------------------------------------------------------
%% initialize() -> ok
%%
%% Seeds the DETS counter from the maximum existing relationship ID in Mnesia,
%% or 1 if Mnesia is unavailable or the relationships table is empty.
%%-----------------------------------------------------------------------------
initialize() ->
	StartId = seed_from_mnesia(),
	dets:insert(?MODULE, {counter, StartId}),
	ok.


%%-----------------------------------------------------------------------------
%% seed_from_mnesia() -> integer()
%%
%% Scans the Mnesia relationships table for the maximum existing ID.
%% Returns max(1, Max + 1) on success, 1 if Mnesia is unavailable.
%%-----------------------------------------------------------------------------
seed_from_mnesia() ->
	try
		Max = mnesia:dirty_foldl(
			fun(Rec, Acc) -> max(element(2, Rec), Acc) end,
			0,
			relationships),
		max(1, Max + 1)
	catch
		_:_ -> 1
	end.


%%-----------------------------------------------------------------------------
%% do_get_id() -> integer()
%%
%% Reads the current counter, increments it in DETS, returns the old value.
%%-----------------------------------------------------------------------------
do_get_id() ->
	[{counter, N}] = dets:lookup(?MODULE, counter),
	ok = dets:insert(?MODULE, {counter, N + 1}),
	N.
