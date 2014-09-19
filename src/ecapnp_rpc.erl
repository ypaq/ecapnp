%%
%%  Copyright 2014, Andreas Stenius <kaos@astekk.se>
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%

%% @copyright 2014, Andreas Stenius
%% @author Andreas Stenius <kaos@astekk.se>
%% @doc Everything rpc.
%%

-module(ecapnp_rpc).
-author("Andreas Stenius <kaos@astekk.se>").

%% API
-export([import_capability/3, request/2, send/1, wait/2]).

%% Internal helper functions
-export([get_target/1, wait/3, dump/1]).

%%-define(ECAPNP_DEBUG,1). %% un-comment to enable debug messages, or
%%-define(ECAPNP_TRACE,1). %% un-comment to enable debug messages and trace the gen_server

-include("ecapnp.hrl").


%% ===================================================================
%% API functions
%% ===================================================================

%% ===================================================================
import_capability(Vat, ObjectId, Schema) ->
    #promise{
       owner = {ecapnp_vat, Vat},
       pid = ecapnp_vat:import_capability(Vat, ObjectId),
       schema = Schema
      }.

%% ===================================================================
request(MethodName, Target) ->
    do_request(MethodName, get_target(Target)).

%% ===================================================================
send(Req0) when is_record(Req0, rpc_call) ->
    case decode_target(Req0) of
        {#promise{ owner = {Mod, Pid} } = Promise, Req} ->
            ?DBG("== CALL~n~s", [?DUMP(Req)]),
            Promise#promise{ pid = Mod:send(Pid, Req) };
        {Promise, RPCCall}
          when is_record(Promise, promise), is_record(RPCCall, rpc_call) ->
            {Promise, RPCCall}
    end.

%% ===================================================================
wait(#promise{ pid = Pid }=Promise, Time) ->
    {ok, Res} = ecapnp_promise:wait(Pid, Time),
    wait_result(Promise, transform(Promise, Res)).

%%--------------------------------------------------------------------
wait(Pid, Ts, Time) ->
    {ok, Res} = ecapnp_promise:wait(Pid, Time),
    wait_result(Pid, transform(Ts, Res)).

%% ===================================================================
get_target(#object{ ref = #ref{ kind = Target }, schema = Schema })
  when is_record(Target, interface_ref) ->
    {Target, Schema};
get_target(#promise{ schema = Schema } = Target) ->
    {Target, Schema}.


%% ===================================================================
dump(#rpc_call{ target = T, interface = I, method = M, params = P,
                results = R, resultSchema = S }) ->
    io_lib:format("#rpc_call{\n"
                  "\ttarget = ~s,\n"
                  "\tinterface = ~p,\n"
                  "\tmethod = ~p,\n"
                  "\tparams = ~s,\n"
                  "\tresults = ~s,\n"
                  "\tresultSchema = ~s\n"
                  "}",
                  [ecapnp:dump(T), I, M, ecapnp:dump(P),
                   ecapnp:dump(R), ecapnp:dump(S)]).

%% ===================================================================
%% Internal functions
%% ===================================================================

do_request(MethodName, {Target, Schema}) ->
    {ok, Interface, Method} = ecapnp_schema:find_method_by_name(
                                MethodName, Schema),
    {ok, Msg} = ecapnp_set:root('Message', rpc_capnp),
    Call = ecapnp:init(call, Msg),
    Payload = ecapnp:init(params, Call),
    Content = ecapnp:init(
                content, ecapnp_schema:lookup(
                           Method#method.paramType, Interface),
                Payload),
    ResultSchema = ecapnp_schema:get(Method#method.resultType, Interface),
    #rpc_call{
       target = Target,
       interface = Interface#schema_node.id,
       method = Method#method.id,
       params = Content,
       resultSchema = ResultSchema
      }.

decode_target(#rpc_call{ target = Target, resultSchema = Schema } = Req) ->
    case Target of
        #interface_ref{ owner = promise, id = {Pid, Ts} } ->
            %% we need the target to resolve before dispatching the call, but we're not supposed to block
            %% the sender, but give a promise for the calls' result back, so we have to create this promise
            %% here, now.
            {ok, Promise} = ecapnp_promise_sup:start_promise(
                              [{fullfiller,
                                fun () ->
                                        {ok, Obj} = wait(Pid, Ts, infinity),
                                        {T, _S} = get_target(Obj),
                                        wait(send(Req#rpc_call{ target = T }), infinity)
                                end}]),
            #promise{ pid = Promise, schema = Schema };
        #interface_ref{ owner = O, id = I } ->
            {#promise{ owner = O, schema = Schema },
             Req#rpc_call{ target = I }};
        #promise{ owner = O, pid = P, transform = Ts } ->
            {#promise{ owner = O, schema = Schema },
             Req#rpc_call{ target = {P, Ts} }}
    end.

transform(#promise{ transform = []}, Res) -> Res;
transform(#promise{ transform = Ts}, Obj) -> transform(Ts, Obj);
transform([], Obj) -> Obj;
transform([{getPointerField, Idx}|Ts], Obj) ->
    transform(Ts, ecapnp:get({ptr, Idx}, Obj)).

wait_result(#promise{ schema = Schema }, Res) ->
    wait_result(Schema, Res);
wait_result(undefined, Res) ->
    ?DBG(".. RESULT ~s", [?DUMP(Res)]),
    Res;
wait_result(Schema, Res) ->
    Obj = ecapnp_obj:to_struct(Schema, Res),
    ?DBG(".. RESULT {ok, ~s}", [?DUMP(Obj)]),
    {ok, Obj}.
