%%
%%  Copyright 2013, Andreas Stenius <kaos@astekk.se>
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

%% @copyright 2013, Andreas Stenius
%% @author Andreas Stenius <kaos@astekk.se>
%% @doc Read support.
%%
%% Everything for reading data out of a message.

-module(ecapnp_get).
-author("Andreas Stenius <kaos@astekk.se>").

-export([root/2, root/3, field/2, union/1, ref_data/2, ref_data/3]).

-include("ecapnp.hrl").


%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Get the root object for a message.
%% @see ecapnp:get_root/3
-spec root(schema_node(), message()) -> {ok, Root::object()}.
root(Node, Segments) ->
    {ok, ecapnp_obj:from_data(Segments, Node)}.

-spec root(type_name(), schema_name(), message()) -> {ok, Root::object()}.
root(Type, Schema, Segments) ->
    root(Schema:schema(Type), Segments).

%% @doc Read the field value of object.
%% @see ecapnp:get/2
-spec field(field_name(), object()) -> field_value().
%%field(FieldName, #object{ ref=Ref }=Object)
field(FieldName, #rpc_call{ params = Object }) -> field(FieldName, Object);
field(FieldName, #promise{ schema = Schema }=Promise) ->
    case ecapnp_schema:find_field(FieldName, Schema) of
        #field{ id = Id, kind = #ptr{ type = {struct, Type} } } ->
            transform_promise(Promise, Type, {getPointerField, Id});
        #field{ kind = Kind } ->
            case ecapnp:wait(Promise, 5000) of
                {ok, Res} -> read_field(Kind, Res);
                timeout -> throw(timeout)
            end
    end;
field(FieldName, Object)
  when is_record(Object, object) ->
    case ecapnp_obj:field(FieldName, Object) of
        false -> throw({unknown_field, FieldName, Object});
        Field -> read_field(Field, Object)
    end.

%% @doc Read the unnamed union value of object.
%% @see ecapnp:get/1
-spec union(object()) -> {field_name(), field_value()} | field_name().
union(#rpc_call{ params = Object }) -> union(Object);
union(#object{ schema=#schema_node{
                         kind=#struct{ union_field=Union }
                        }}=Object) ->
    if Union /= none -> read_field(Union, Object);
       true -> throw({no_unnamed_union_in_object, Object})
    end.

%% @doc internal function not intended for client code.
ref_data(Ptr, Obj) ->
    read_ptr(Ptr, Obj).

%% @doc Read data of object reference as type.
%% This is a Low-level function.
ref_data(Type, Obj, Default) ->
    read_ptr(#ptr{ type=Type, default=Default }, Obj).


%% ===================================================================
%% internal functions
%% ===================================================================

transform_promise(#promise{ transform = Ts, schema = S } = P, Type, T) ->
    P#promise{ transform = [T|Ts], schema = ecapnp_schema:get(Type, S) }.

read_field(#field{ kind = void }, _) -> void;
read_field(#field{ kind=Kind }, Object) -> read_field(Kind, Object);
read_field(#data{ type=Type, align=Align, default=Default }=D, Object) ->
    case Type of
        {enum, EnumType} ->
            Tag = read_field(D#data{ type=uint16 }, Object),
            get_enum_value(EnumType, Tag, Object);
        {union, Fields} ->
            Tag = read_field(D#data{ type=uint16 }, Object),
            case lists:keyfind(Tag, #field.id, Fields) of
                #field{ name=FieldName }=Field ->
                    {FieldName, read_field(Field, Object)}
            end;
        Type ->
            case ecapnp_val:size(Type) of
                0 -> void;
                Size ->
                    ecapnp_val:get(
                      Type, ecapnp_ref:read_struct_data(
                              Align, Size, Object#object.ref),
                      Default)
            end
    end;
read_field(#ptr{ idx=Idx }=Ptr, #object{ ref = Ref }=Object) ->
    Obj = ecapnp_obj:init(
            ecapnp_ref:read_struct_ptr(Idx, Ref),
            Object),
    read_ptr(Ptr, Obj);
read_field(#group{ id=Type }, Object) ->
    case ecapnp_obj:to_struct(Type, Object) of
        #object{
          schema = #schema_node{
                      kind = #struct{
                                union_field = Union,
                                fields = []
                               }}}=Group
          when Union =/= none ->
            %% when we read a named union, we want to get the union
            %% value directly, but a named union is represented as a
            %% unnamed union wrapped in a group
            read_field(Union, Group);
        Group ->
            Group
    end.

read_ptr(#ptr{ type=Type, default=Default }, #object{ ref = Ref }=Obj) ->
    case Type of
        text -> ecapnp_ref:read_text(Ref, Default);
        data -> ecapnp_ref:read_data(Ref, Default);
        object -> read_obj(object, Obj, Default);
        {struct, StructType} -> read_obj(StructType, Obj, Default);
        {interface, InterfaceType} -> read_obj(InterfaceType, Obj, Default);
        {list, ElementType} -> read_list(ElementType, Default, Obj)
    end.

read_obj(Type, #object{ ref = #ref{ kind=null } }=Obj, Default) ->
    if is_binary(Default) ->
            ecapnp_obj:from_data(Default, Type, Obj)
    end;
read_obj(Type, Obj, _) ->
    ecapnp_obj:to_struct(Type, Obj).

read_list({struct, StructType}, Default, #object{ ref = Ref }=Obj) ->
    Schema = ecapnp_schema:get(StructType, Obj),
    case ecapnp_ref:read_list_refs(
           Ref, ecapnp_schema:get_ref_kind(Schema), undefined)
    of
        [] -> [];
        undefined ->
            if is_binary(Default) ->
                    ecapnp_obj:from_data(Default, {list, {struct, StructType}}, Obj);
               true -> Default
            end;
        Refs when is_record(hd(Refs), ref) ->
            [read_ptr(#ptr{ type = {struct, StructType} },
                      ecapnp_obj:init(R, Obj))
             || R <- Refs]
    end;
read_list(ElementType, Default, #object{ ref = Ref }=Obj) ->
    case ecapnp_ref:read_list(Ref, undefined) of
        undefined ->
            if is_binary(Default) ->
                    ecapnp_obj:from_data(
                      Default, {list, ElementType}, Obj);
               true ->
                    Default
            end;
        Refs when is_record(hd(Refs), ref) ->
            [read_ptr(
               #ptr{ type=ElementType },
               ecapnp_obj:init(R, Obj))
             || R <- Refs];
        Values ->
            case ElementType of
                {enum, EnumType} ->
                    [get_enum_value(
                       EnumType,
                       ecapnp_val:get(uint16, Data),
                       Obj)
                     || Data <- Values];
                _ when is_atom(ElementType) ->
                    [ecapnp_val:get(ElementType, Data)
                     || Data <- Values]
            end
    end.

get_enum_value(Type, Tag, Obj) ->
    #schema_node{ kind=#enum{ values=Values } }
        = ecapnp_schema:lookup(Type, Obj),
    case lists:keyfind(Tag, 1, Values) of
        {Tag, Value} -> Value;
        false -> Tag
    end.
