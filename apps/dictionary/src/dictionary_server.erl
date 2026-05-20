%%---------------------------------------------------------------------
%% Copyright (c) 2008 SeerStone, Inc.
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: Dallas Noyes
%% Created: *** 2008
%% Description: dictionary_server is the supervised worker for dictionary
%%				operations. It coordinates access to dictionaries managed
%%				by dictionary_imp and acts as the primary interface for
%%				CRUD operations on named ETS-backed dictionaries.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev PA1 Date: *** 2008 Author: Dallas Noyes (dallas.noyes@gmail.com)
%% Stub implementation.
%%---------------------------------------------------------------------
%% Rev A Date: 2026-05-19 Author: David W. Thomas
%% Wire to dictionary_imp.
%%---------------------------------------------------------------------
-module(dictionary_server).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: PA1 ').
-created('Date: *** 2008').
-created_by('dallas.noyes@gmail.com').
%%-modified('Date: Month Day, Year 10:50:00').
%%-modified_by('dallas.noyes@gmail.com').


%%---------------------------------------------------------------------
%% Macro Functions
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
%% Records
%%---------------------------------------------------------------------
-record(state, {
	imp_proc,	%% atom() — registered name of the dictionary_imp process
	file		%% string() — backing ETS file path
}).


%%---------------------------------------------------------------------
%% Exported Functions
%%---------------------------------------------------------------------
%%---------------------------------------------------------------------
%% Exports External API
%%---------------------------------------------------------------------
-export([
		start_link/0,
		create/1,
		read/1,
		update/2,
		delete/1,
		all/0,
		size/0
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


%%---------------------------------------------------------------------
%% Exported External API Functions
%%---------------------------------------------------------------------

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create(Key)			-> gen_server:call(?MODULE, {create, Key}).
read(Key)			-> gen_server:call(?MODULE, {read, Key}).
update(Key, Value)	-> gen_server:call(?MODULE, {update, Key, Value}).
delete(Key)			-> gen_server:call(?MODULE, {delete, Key}).
all()				-> gen_server:call(?MODULE, all).
size()				-> gen_server:call(?MODULE, size).


%%---------------------------------------------------------------------
%% gen_server Behaviour Callbacks
%%---------------------------------------------------------------------

init([]) ->
	DataPath = application:get_env(seerstone_graph_db, data_path, "data"),
	File = filename:join(DataPath, "dictionary.dat"),
	ok = dictionary_imp:start_dictionary(File, dictionary),
	{ok, #state{imp_proc = dictionary, file = File}}.

handle_call({create, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:create(P, Key), State};
handle_call({read, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:read(P, Key), State};
handle_call({update, Key, Value}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:update(P, Key, Value), State};
handle_call({delete, Key}, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:delete(P, Key), State};
handle_call(all, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:all(P), State};
handle_call(size, _From, State = #state{imp_proc = P}) ->
	{reply, dictionary_imp:size(P), State};
handle_call(Request, From, State) ->
	?UEM(handle_call, {Request, From, State}),
	{noreply, State}.

handle_cast(Message, State) ->
	?UEM(handle_cast, {Message, State}),
	{noreply, State}.

handle_info(Info, State) ->
	?UEM(handle_info, {Info, State}),
	{noreply, State}.

terminate(_Reason, #state{imp_proc = P, file = F}) ->
	dictionary_imp:stop_dictionary(F, P).

code_change(_OldVsn, State, _Extra) ->
	?NYI(code_change),
	{ok, State}.
