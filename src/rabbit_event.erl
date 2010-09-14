%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_event).

-include("rabbit.hrl").

-export([start_link/0]).
-export([init_stats_timer/0, ensure_stats_timer/2]).
-export([reset_stats_timer/1]).
-export([stats_level/1, if_enabled/2]).
-export([notify/2]).

%%----------------------------------------------------------------------------

-record(state, {level, timer}).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([event_type/0, event_props/0, event_timestamp/0, event/0]).

-type(event_type() :: atom()).
-type(event_props() :: term()).
-type(event_timestamp() ::
        {non_neg_integer(), non_neg_integer(), non_neg_integer()}).

-type(event() :: #event {
             type :: event_type(),
             props :: event_props(),
             timestamp :: event_timestamp()
            }).

-type(level() :: 'none' | 'coarse' | 'fine').

-opaque(state() :: #state {
               level :: level(),
               timer :: atom()
              }).

-type(timer_fun() :: fun (() -> 'ok')).

-spec(start_link/0 :: () -> rabbit_types:ok_pid_or_error()).
-spec(init_stats_timer/0 :: () -> state()).
-spec(ensure_stats_timer/2 :: (state(), timer_fun()) -> state()).
-spec(reset_stats_timer/1 :: (state()) -> state()).
-spec(stats_level/1 :: (state()) -> level()).
-spec(if_enabled/2 :: (state(), timer_fun()) -> 'ok').
-spec(notify/2 :: (event_type(), event_props()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

start_link() ->
    gen_event:start_link({local, ?MODULE}).

%% The idea is, for each of channel, queue, connection:
%%
%% On startup:
%%   Timer = init_stats_timer()
%%   notify(created event)
%%   maybe(internal_emit_stats) - so we immediately send something
%%
%% On wakeup:
%%   ensure_stats_timer(Timer, emit_stats)
%%   (Note we can't emit stats immediately, the timer may have fired 1ms ago.)
%%
%% emit_stats:
%%   internal_emit_stats
%%   reset_stats_timer(Timer) - just bookkeeping
%%
%% Pre-hibernation:
%%   internal_emit_stats
%%   reset_stats_timer(Timer) - just bookkeeping
%%
%% internal_emit_stats:
%%   notify(stats)

init_stats_timer() ->
    {ok, StatsLevel} = application:get_env(rabbit, collect_statistics),
    #state{level = StatsLevel, timer = undefined}.

ensure_stats_timer(State = #state{level = none}, _Fun) ->
    State;
ensure_stats_timer(State = #state{timer = undefined}, Fun) ->
    {ok, TRef} = timer:apply_after(?STATS_INTERVAL,
                                      erlang, apply, [Fun, []]),
    State#state{timer = TRef};
ensure_stats_timer(State, _Fun) ->
    State.

reset_stats_timer(State) ->
    State#state{timer = undefined}.

stats_level(#state{level = Level}) ->
    Level.


if_enabled(#state{level = none}, _Fun) ->
    ok;
if_enabled(_State, Fun) ->
    Fun(),
    ok.

notify(Type, Props) ->
    try
        %% TODO: switch to os:timestamp() when we drop support for
        %% Erlang/OTP < R13B01
        gen_event:notify(rabbit_event, #event{type = Type,
                                              props = Props,
                                              timestamp = now()})
    catch error:badarg ->
            %% badarg means rabbit_event is no longer registered. We never
            %% unregister it so the great likelihood is that we're shutting
            %% down the broker but some events were backed up. Ignore it.
            ok
    end.
