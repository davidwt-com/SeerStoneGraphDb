%%---------------------------------------------------------------------
%% Copyright (c) 2026 David W. Thomas
%% SPDX-License-Identifier: GPL-2.0-or-later
%%---------------------------------------------------------------------
%% Author: David W. Thomas
%% Created: May 2026
%% Description: Switchable node-nref allocation facade for graphdb.
%%              Permanent phase (init): hands out permanent-tier nrefs
%%              [?LABEL_START, ?NREF_START) computed from the nodes table.
%%              Runtime phase (after the boot flip): delegates to
%%              nref_server:get_nref/0.  The phase lives in persistent_term
%%              so a single process restart cannot resurrect the wrong phase.
%%---------------------------------------------------------------------
%% Revision History
%%---------------------------------------------------------------------
%% Rev A Date: May 2026 Author: David W. Thomas
%% Initial implementation.
%%---------------------------------------------------------------------
-module(graphdb_nref).
-behaviour(gen_server).


%%---------------------------------------------------------------------
%% Module Attributes
%%---------------------------------------------------------------------
-revision('Revision: A ').
-created('Date: May 2026').
-created_by('david@davidwt.com').

-define(NYI(X), (begin
    io:format("*** NYI ~p ~p ~p~n",[?MODULE, ?LINE, X]),
    exit(nyi)
end)).
-define(UEM(F, X), (begin
    io:format("*** UEM ~p:~p ~p ~p~n",[?MODULE, F, ?LINE, X]),
    exit(uem)
end)).


%%---------------------------------------------------------------------
%% Include files
%%---------------------------------------------------------------------
-include_lib("graphdb/include/graphdb_nrefs.hrl").


%%---------------------------------------------------------------------
%% Public API
%%---------------------------------------------------------------------
-export([
    start_link/0,
    get_next/0,
    set_permanent_phase/0,
    set_runtime_phase/0,
    phase/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(PHASE_KEY, {?MODULE, phase}).

-record(state, {cursor :: undefined | integer()}).

%%---------------------------------------------------------------------
%% start_link() -> {ok, pid()}
%%---------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%---------------------------------------------------------------------
%% get_next() -> integer()
%%
%% The single entry point for all graphdb node-nref allocation.  The phase
%% decides the tier: permanent (init) -> compute-from-DB cursor; runtime
%% (after the flip) -> nref_server:get_nref/0.
%%---------------------------------------------------------------------
-spec get_next() -> pos_integer().
get_next() ->
    case phase() of
        runtime   -> nref_server:get_nref();
        permanent -> gen_server:call(?MODULE, next_permanent)
    end.

%%---------------------------------------------------------------------
%% phase() -> permanent | runtime   (defaults to permanent when unset)
%%---------------------------------------------------------------------
-spec phase() -> permanent | runtime.
phase() ->
    persistent_term:get(?PHASE_KEY, permanent).

%%---------------------------------------------------------------------
%% set_permanent_phase() -> ok
%%---------------------------------------------------------------------
-spec set_permanent_phase() -> ok.
set_permanent_phase() ->
    persistent_term:put(?PHASE_KEY, permanent),
    ok.

%%---------------------------------------------------------------------
%% set_runtime_phase() -> ok
%%
%% Flips to runtime and raises nref_server's floor to ?NREF_START so the
%% first runtime allocation lands in the runtime tier.  Idempotent
%% (set_floor is monotonic; persistent_term:put overwrites).
%%---------------------------------------------------------------------
-spec set_runtime_phase() -> ok.
set_runtime_phase() ->
    ok = nref_server:set_floor(?NREF_START),
    persistent_term:put(?PHASE_KEY, runtime),
    ok.

%%---------------------------------------------------------------------
%% Callbacks
%%---------------------------------------------------------------------
init([]) ->
    {ok, #state{cursor = undefined}}.


handle_call(next_permanent, _From, #state{cursor = undefined}) ->
    allocate(compute_cursor());
handle_call(next_permanent, _From, #state{cursor = C}) ->
    allocate(C);
handle_call(Request, From, State) ->
    ?UEM(handle_call, {Request, From, State}),
    {noreply, State}.

handle_cast(Message, State) ->
    ?UEM(handle_cast, {Message, State}),
    {noreply, State}.

handle_info(Info, State) ->
    ?UEM(handle_info, {Info, State}),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%---------------------------------------------------------------------
%% Internal Functions
%%---------------------------------------------------------------------

%%---------------------------------------------------------------------
%% allocate(N) -> {reply, N, #state{}}
%%
%% Hands out N and advances the cursor.  On spillover (N >= ?NREF_START)
%% raises the runtime floor so runtime allocations stay above the spill.
%%---------------------------------------------------------------------
allocate(N) when N >= ?NREF_START ->
    ok = nref_server:set_floor(N + 1),
    {reply, N, #state{cursor = N + 1}};
allocate(N) ->
    {reply, N, #state{cursor = N + 1}}.

%%---------------------------------------------------------------------
%% compute_cursor() -> integer()
%%
%% Next permanent nref = max(?LABEL_START, 1 + max permanent nref already in
%% the nodes table).  nref is the primary key, so dirty_all_keys/1 yields
%% every nref directly.  Runtime nrefs (>= ?NREF_START) are filtered out.
%%---------------------------------------------------------------------
compute_cursor() ->
    Keys  = mnesia:dirty_all_keys(nodes),
    Below = [K || K <- Keys, is_integer(K), K < ?NREF_START],
    case Below of
        [] -> ?LABEL_START;
        _  -> erlang:max(?LABEL_START, lists:max(Below) + 1)
    end.
