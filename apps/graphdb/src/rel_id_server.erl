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
%% Rev PA2 Date: 2026-08-09 Author: David W. Thomas
%% Counter seeding repaired -- three defects, all in the same path:
%%   1. seed_from_mnesia/0 called mnesia:dirty_foldl/3, which does not
%%      exist.  Now mnesia:foldl/3 inside a transaction.
%%   2. Its blanket `catch _:_ -> 1' turned the resulting undef -- and
%%      every other failure -- into a seed of 1, the one value that
%%      collides with live rows and makes mnesia:write silently overwrite
%%      them.  Now 1 is returned only for a definite "table does not
%%      exist"; anything else logs and exits.
%%   3. Seeding ran from init/1, where the relationships table cannot be
%%      read yet (see counter/0), so it could never observe existing rows
%%      no matter how (1) and (2) were fixed.  Now seeded lazily on first
%%      id request.
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
		get_id/0,		%% Returns next ID, advances counter.
		get_id_pair/0	%% Returns {Id1, Id2} for one reciprocal arc pair.
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


%%-----------------------------------------------------------------------------
%% get_id_pair() -> {integer(), integer()}
%%
%% Returns two consecutive IDs for a reciprocal arc pair in one call.
%%-----------------------------------------------------------------------------
get_id_pair() ->
	gen_server:call(?MODULE, get_id_pair).


%%=============================================================================
%% gen_server Behaviour Callbacks
%%=============================================================================

%%-----------------------------------------------------------------------------
%% init([]) -> {ok, State}
%%
%% Opens the DETS file for this rel_id_server instance.  Does NOT seed the
%% counter -- see counter/0 for why that cannot happen here.
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
handle_call(get_id_pair, _From, State) ->
	Reply = do_get_id_pair(),
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
			true;
		{error, Reason} ->
			logger:error("cannot open rel_id_server dets table: ~p", [Reason]),
			exit(rel_id_server_open)
	end.


%%-----------------------------------------------------------------------------
%% counter() -> integer()
%%
%% Returns the current counter value, seeding it on first use.
%%
%% Seeding is deliberately LAZY -- it cannot be done in init/1.  Startup
%% ordering makes the table unreadable at that point, and circularly so:
%%
%%   * rel_id_server must start BEFORE graphdb_mgr, because
%%     graphdb_bootstrap consumes ids from get_id_pair/0 while loading the
%%     scaffold; and
%%   * the relationships table does not exist until graphdb_bootstrap
%%     creates it, which happens inside graphdb_mgr:init/1 -- and mnesia
%%     itself is not even running until graphdb_bootstrap:ensure_mnesia/0
%%     starts it there.
%%
%% So at init/1 the answer is never knowable: an eager seed always reads
%% "no rows" and lands on 1, which is exactly the value that collides with
%% live rows when the DETS file was lost but Mnesia survived.  By first
%% get_id/get_id_pair call, bootstrap has run, mnesia is up, and the table
%% is loaded -- so the high-water mark is real.
%%-----------------------------------------------------------------------------
counter() ->
	case dets:lookup(?MODULE, counter) of
		[{counter, N}] ->
			N;
		[] ->
			Seed = seed_from_mnesia(),
			ok = dets:insert(?MODULE, {counter, Seed}),
			Seed
	end.


%%-----------------------------------------------------------------------------
%% seed_from_mnesia() -> integer() | exit(rel_id_server_seed)
%%
%% Returns the id the counter should start at: one past the highest id
%% already present in the Mnesia relationships table.
%%
%% Called only from counter/0, i.e. once, on the first id request after
%% the DETS counter key is found absent.  Two states reach it:
%%
%%   * Genuine first boot.  graphdb_bootstrap has created the relationships
%%     table and is loading the scaffold, so the table exists and is empty;
%%     the fold returns 0 and the counter starts at 1.  (A caller reaching
%%     here before the table exists reads {no_exists, ...} and also gets 1,
%%     which is equally correct -- no table means no rows.)
%%
%%   * DETS file lost while Mnesia survived -- restore, data-dir move, or
%%     partial recovery.  The table is loaded and populated, and the
%%     counter MUST resume above its highest id.  Starting at 1 here hands
%%     out ids that collide with live primary keys, and mnesia:write then
%%     SILENTLY OVERWRITES existing rows.
%%
%% Because that second case is silent data loss, any outcome that is not a
%% definite answer is fatal rather than defaulted.  In particular a blanket
%% `catch _:_ -> 1' is not safe here -- 1 is precisely the corrupting
%% value, so swallowing an error produces the worst possible guess.
%%-----------------------------------------------------------------------------
seed_from_mnesia() ->
	%% element(2, Rec) is #relationship.id, the table's primary key; this
	%% module deliberately carries no #relationship{} copy of its own.
	Fold = fun(Rec, Acc) -> max(element(2, Rec), Acc) end,
	Read = fun() -> mnesia:foldl(Fold, 0, relationships) end,
	case mnesia:transaction(Read) of
		{atomic, Max} when is_integer(Max) ->
			max(1, Max + 1);
		{aborted, {no_exists, relationships}} ->
			1;
		Other ->
			logger:error(
				"rel_id_server: cannot determine the highest existing "
				"relationship id (~p) -- refusing to seed the counter, "
				"because restarting at 1 would hand out ids that collide "
				"with live rows and silently overwrite them",
				[Other]),
			exit(rel_id_server_seed)
	end.


%%-----------------------------------------------------------------------------
%% do_get_id() -> integer()
%%
%% Reads the current counter, increments it in DETS, returns the old value.
%%-----------------------------------------------------------------------------
do_get_id() ->
	N = counter(),
	ok = dets:insert(?MODULE, {counter, N + 1}),
	N.


%%-----------------------------------------------------------------------------
%% do_get_id_pair() -> {integer(), integer()}
%%
%% Allocates two consecutive IDs atomically for a reciprocal arc pair.
%%-----------------------------------------------------------------------------
do_get_id_pair() ->
	N = counter(),
	ok = dets:insert(?MODULE, {counter, N + 2}),
	{N, N + 1}.
