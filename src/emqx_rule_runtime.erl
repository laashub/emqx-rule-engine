%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_rule_runtime).

-include("rule_engine.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ apply_rule/2
        , apply_rules/2
        , clear_rule_payload/0
        ]).

-import(emqx_rule_maps,
        [ nested_get/2
        , nested_put/3
        ]).

-type(input() :: map()).
-type(alias() :: atom()).
-type(collection() :: {alias(), [term()]}).

%%------------------------------------------------------------------------------
%% Apply rules
%%------------------------------------------------------------------------------
-spec(apply_rules(list(emqx_rule_engine:rule()), input()) -> ok).
apply_rules([], _Input) ->
    clear_rule_payload(),
    ok;
apply_rules([#rule{enabled = false}|More], Input) ->
    apply_rules(More, Input);
apply_rules([Rule = #rule{id = RuleID}|More], Input) ->
    try apply_rule(Rule, Input)
    catch
        %% ignore the errors if select or match failed
        _:{select_and_transform_error, Error} ->
            ?LOG(warning, "SELECT clause exception for ~s failed: ~p",
                 [RuleID, Error]);
        _:{match_conditions_error, Error} ->
            ?LOG(warning, "WHERE clause exception for ~s failed: ~p",
                 [RuleID, Error]);
        _:{select_and_collect_error, Error} ->
            ?LOG(warning, "FOREACH clause exception for ~s failed: ~p",
                 [RuleID, Error]);
        _:{match_incase_error, Error} ->
            ?LOG(warning, "INCASE clause exception for ~s failed: ~p",
                 [RuleID, Error]);
        _:Error:StkTrace ->
            ?LOG(error, "Apply rule ~s failed: ~p. Stacktrace:~n~p",
                 [RuleID, Error, StkTrace])
    end,
    apply_rules(More, Input).

apply_rule(#rule{id = RuleId,
                 is_foreach = true,
                 fields = Fields,
                 doeach = DoEach,
                 incase = InCase,
                 conditions = Conditions,
                 actions = Actions}, Input) ->
    {Selected, Collection} = ?RAISE(select_and_collect(Fields, Input),
                                        {select_and_collect_error, _REASON_}),
    ColumnsAndSelected = maps:merge(Input, Selected),
    case ?RAISE(match_conditions(Conditions, ColumnsAndSelected),
                {match_conditions_error, _REASON_}) of
        true ->
            ok = emqx_rule_metrics:inc(RuleId, 'rules.matched'),
            Collection2 = filter_collection(Input, InCase, DoEach, Collection),
            {ok, [take_actions(Actions, Coll, Input) || Coll <- Collection2]};
        false ->
            {error, nomatch}
    end;

apply_rule(#rule{id = RuleId,
                 is_foreach = false,
                 fields = Fields,
                 conditions = Conditions,
                 actions = Actions}, Input) ->
    Selected = ?RAISE(select_and_transform(Fields, Input),
                      {select_and_transform_error, _REASON_}),
    case ?RAISE(match_conditions(Conditions, maps:merge(Input, Selected)),
                {match_conditions_error, _REASON_}) of
        true ->
            ok = emqx_rule_metrics:inc(RuleId, 'rules.matched'),
            {ok, take_actions(Actions, Selected, Input)};
        false ->
            {error, nomatch}
    end.

clear_rule_payload() ->
    erlang:erase(rule_payload).

%% SELECT Clause
select_and_transform(Fields, Input) ->
    select_and_transform(Fields, Input, #{}).

select_and_transform([], _Input, Output) ->
    Output;
select_and_transform(['*'|More], Input, Output) ->
    select_and_transform(More, Input, maps:merge(Output, Input));
select_and_transform([{as, Field, Alias}|More], Input, Output) ->
    Key = emqx_rule_utils:unsafe_atom_key(Alias),
    Val = eval(Field, Input),
    select_and_transform(More,
        nested_put(Key, Val, Input),
        nested_put(Key, Val, Output));
select_and_transform([Field|More], Input, Output) ->
    Val = eval(Field, Input),
    Key = alias(Field, Val),
    select_and_transform(More,
        nested_put(Key, Val, Input),
        nested_put(Key, Val, Output)).

%% FOREACH Clause
-spec select_and_collect(list(), input()) -> {input(), collection()}.
select_and_collect(Fields, Input) ->
    select_and_collect(Fields, Input, {#{}, {'item', []}}).

select_and_collect([{as, Field, Alias}], Input, {Output, _}) ->
    Key = emqx_rule_utils:unsafe_atom_key(Alias),
    Val = eval(Field, Input),
    {nested_put(Key, Val, Output), {Key, ensure_list(Val)}};
select_and_collect([{as, Field, Alias}|More], Input, {Output, LastKV}) ->
    Key = emqx_rule_utils:unsafe_atom_key(Alias),
    Val = eval(Field, Input),
    select_and_collect(More,
        nested_put(Key, Val, Input),
        {nested_put(Key, Val, Output), LastKV});
select_and_collect([Field], Input, {Output, _}) ->
    Val = eval(Field, Input),
    Key = alias(Field, Val),
    {nested_put(Key, Val, Output), {'item', ensure_list(Val)}};
select_and_collect([Field|More], Input, {Output, LastKV}) ->
    Val = eval(Field, Input),
    Key = alias(Field, Val),
    select_and_collect(More,
        nested_put(Key, Val, Input),
        {nested_put(Key, Val, Output), LastKV}).

%% Filter each item got from FOREACH
filter_collection(Input, InCase, DoEach, {CollKey, CollVal}) ->
    lists:filtermap(
        fun(Item) ->
            InputAndItem = maps:merge(Input, #{CollKey => Item}),
            case ?RAISE(match_conditions(InCase, InputAndItem),
                    {match_incase_error, _REASON_}) of
                true when DoEach == [] -> true;
                true ->
                    {true, ?RAISE(select_and_transform(DoEach, InputAndItem),
                                  {doeach_error, _REASON_})};
                false -> false
            end
        end, CollVal).

%% Conditional Clauses such as WHERE, WHEN.
match_conditions({'and', L, R}, Data) ->
    match_conditions(L, Data) andalso match_conditions(R, Data);
match_conditions({'or', L, R}, Data) ->
    match_conditions(L, Data) orelse match_conditions(R, Data);
match_conditions({'not', Var}, Data) ->
    case eval(Var, Data) of
        Bool when is_boolean(Bool) ->
            not Bool;
        _other -> false
    end;
match_conditions({in, Var, {list, Vals}}, Data) ->
    lists:member(eval(Var, Data), [eval(V, Data) || V <- Vals]);
match_conditions({'fun', Name, Args}, Data) ->
    apply_func(Name, [eval(Arg, Data) || Arg <- Args], Data);
match_conditions({Op, L, R}, Data) when ?is_comp(Op) ->
    compare(Op, eval(L, Data), eval(R, Data));
%%match_conditions({'like', Var, Pattern}, Data) ->
%%    match_like(eval(Var, Data), Pattern);
match_conditions({}, _Data) ->
    true.

%% comparing numbers against strings
compare(Op, L, R) when is_number(L), is_binary(R) ->
    do_compare(Op, L, number(R));
compare(Op, L, R) when is_binary(L), is_number(R) ->
    do_compare(Op, number(L), R);
compare(Op, L, R) when is_atom(L), is_binary(R) ->
    do_compare(Op, atom_to_binary(L, utf8), R);
compare(Op, L, R) when is_binary(L), is_atom(R) ->
    do_compare(Op, L, atom_to_binary(R, utf8));
compare(Op, L, R) ->
    do_compare(Op, L, R).

do_compare('=', L, R) -> L == R;
do_compare('>', L, R) -> L > R;
do_compare('<', L, R) -> L < R;
do_compare('<=', L, R) -> L =< R;
do_compare('>=', L, R) -> L >= R;
do_compare('<>', L, R) -> L /= R;
do_compare('!=', L, R) -> L /= R;
do_compare('=~', T, F) -> emqx_topic:match(T, F).

number(Bin) ->
    try binary_to_integer(Bin)
    catch error:badarg -> binary_to_float(Bin)
    end.

%% Step3 -> Take actions
take_actions(Actions, Selected, Envs) ->
    lists:map(fun(Action) -> take_action(Action, Selected, Envs) end, Actions).

take_action(#action_instance{id = Id}, Selected, Envs) ->
    try
        {ok, #action_instance_params{apply = Apply}}
            = emqx_rule_registry:get_action_instance_params(Id),
        Result = Apply(Selected, Envs),
        emqx_rule_metrics:inc(Id, 'actions.success'),
        Result
    catch
        _Error:Reason:Stack ->
            emqx_rule_metrics:inc(Id, 'actions.failure'),
            error({take_action_failed, {Id, Reason, Stack}})
    end.

eval({var, [<<"payload">> | Vars]}, Input) ->
    nested_get(Vars,
        case erlang:get(rule_payload) of
            undefined ->
                Map = ensure_map(nested_get(<<"payload">>, Input)),
                erlang:put(rule_payload, Map), Map;
            Map -> Map
        end);
eval({var, Var}, Input) ->
    nested_get(Var, Input);
eval({const, Val}, _Input) ->
    Val;
eval({Op, L, R}, Input) when ?is_arith(Op) ->
    apply_func(Op, [eval(L, Input), eval(R, Input)], Input);
eval({'case', undefined, CaseClauses, ElseClauses}, Input) ->
    eval_case_clauses(CaseClauses, ElseClauses, Input);
eval({'case', CaseOn, CaseClauses, ElseClauses}, Input) ->
    eval_switch_clauses(CaseOn, CaseClauses, ElseClauses, Input);
eval({'fun', Name, Args}, Input) ->
    apply_func(Name, [eval(Arg, Input) || Arg <- Args], Input).

alias(Field, Val) ->
    case alias(Field) of
        undefined -> Val;
        Alias -> Alias
    end.

alias({var, Var}) ->
    emqx_rule_utils:unsafe_atom_key(Var);
alias({const, Val}) ->
    Val;
alias(_) -> undefined.

eval_case_clauses([], ElseClauses, Input) ->
    case ElseClauses of
        undefined -> undefined;
        _ -> eval(ElseClauses, Input)
    end;
eval_case_clauses([{Cond, Clause} | CaseClauses], ElseClauses, Input) ->
    case match_conditions(Cond, Input) of
        true ->
            eval(Clause, Input);
        _ ->
            eval_case_clauses(CaseClauses, ElseClauses, Input)
    end.

eval_switch_clauses(_CaseOn, [], ElseClauses, Input) ->
    case ElseClauses of
        undefined -> undefined;
        _ -> eval(ElseClauses, Input)
    end;
eval_switch_clauses(CaseOn, [{Cond, Clause} | CaseClauses], ElseClauses, Input) ->
    ConResult = eval(Cond, Input),
    case eval(CaseOn, Input) of
        ConResult ->
            eval(Clause, Input);
        _ ->
            eval_switch_clauses(CaseOn, CaseClauses, ElseClauses, Input)
    end.

apply_func(Name, Args, Input) when is_atom(Name) ->
    case erlang:apply(emqx_rule_funcs, Name, Args) of
        Func when is_function(Func) ->
            erlang:apply(Func, [Input]);
        Result -> Result
    end.

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------
ensure_map(Map) when is_map(Map) ->
    Map;
ensure_map(MaybeJson) ->
    try emqx_json:decode(MaybeJson, [return_maps]) of
        JsonMap when is_map(JsonMap) -> JsonMap;
        _Val -> #{}
    catch _:_ -> #{}
    end.

ensure_list(List) when is_list(List) -> List;
ensure_list(_NotList) -> [].
