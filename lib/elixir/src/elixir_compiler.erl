%% Elixir compiler front-end to the Erlang backend.
-module(elixir_compiler).
-export([get_opt/1, string/2, quoted/2, bootstrap/0,
         file/1, file/2, file_to_path/2, eval_forms/3]).
-include("elixir.hrl").

get_opt(Key) ->
  Map = elixir_config:get(compiler_options),
  case maps:find(Key, Map) of
    {ok, Value} -> Value;
    error -> false
  end.

string(Contents, File) when is_list(Contents), is_binary(File) ->
  string(Contents, File, nil).
string(Contents, File, Dest) ->
  Forms = elixir:'string_to_quoted!'(Contents, 1, File, []),
  quoted(Forms, File, Dest).

quoted(Forms, File) when is_binary(File) ->
  quoted(Forms, File, nil).
quoted(Forms, File, Dest) ->
  Previous = get(elixir_module_binaries),

  try
    put(elixir_module_binaries, []),
    elixir_lexical:run(File, Dest, fun
      (Pid) ->
        Env = elixir:env_for_eval([{line, 1}, {file, File}]),
        eval_forms(Forms, [], Env#{lexical_tracker := Pid})
    end),
    lists:reverse(get(elixir_module_binaries))
  after
    put(elixir_module_binaries, Previous)
  end.

file(Relative) when is_binary(Relative) ->
  file(Relative, nil).
file(Relative, Dest) ->
  File = filename:absname(Relative),
  {ok, Bin} = file:read_file(File),
  string(elixir_utils:characters_to_list(Bin), File, case Dest of
    nil -> Dest;
    _   -> filename:absname(Dest)
  end).

file_to_path(File, Dest) when is_binary(File), is_binary(Dest) ->
  Comp = file(File, Dest),
  Abs  = filename:absname(Dest),
  _ = [binary_to_path(X, Abs) || X <- Comp],
  Comp.

%% Evaluates the given code through the Erlang compiler.
%% It may end-up evaluating the code if it is deemed a
%% more efficient strategy depending on the code snippet.

eval_forms(Forms, Vars, E) ->
  case (?key(E, module) == nil) andalso allows_fast_compilation(Forms) of
    true  ->
      Binding = [{Key, Value} || {_Name, _Kind, Key, Value} <- Vars],
      {Result, _Binding, EE, _S} = elixir:eval_forms(Forms, Binding, E),
      {Result, EE};
    false ->
      compile(Forms, Vars, E)
  end.

compile(Forms, Vars, #{line := Line, file := File} = E) ->
  Dict = [{{Name, Kind}, {Value, 0, true}} || {Name, Kind, Value, _} <- Vars],
  S = elixir_env:env_to_scope_with_vars(E, Dict),
  {Expr, EE, _S} = elixir:quoted_to_erl(Forms, E, S),

  {Module, I} = retrieve_compiler_module(),
  Fun  = code_fun(?key(E, module)),
  Form = code_mod(Fun, Expr, Line, File, Module, Vars),
  Args = list_to_tuple([V || {_, _, _, V} <- Vars]),

  {Module, Binary} = elixir_erl_compiler:noenv_forms(Form, File, [nowarn_nomatch]),
  code:load_binary(Module, "", Binary),

  Purgeable = beam_lib:chunks(Binary, [labeled_locals]) ==
              {ok, {Module, [{labeled_locals, []}]}},
  dispatch(Module, Fun, Args, Purgeable, I, EE).

dispatch(Module, Fun, Args, Purgeable, I, E) ->
  Res = Module:Fun(Args),
  code:delete(Module),
  if Purgeable ->
      code:purge(Module),
      return_compiler_module(I);
     true ->
       ok
  end,
  {Res, E}.

code_fun(nil) -> '__FILE__';
code_fun(_)   -> '__MODULE__'.

code_mod(Fun, Expr, Line, File, Module, Vars) when is_binary(File), is_integer(Line) ->
  Tuple    = {tuple, Line, [{var, Line, K} || {_, _, K, _} <- Vars]},
  Relative = elixir_utils:relative_to_cwd(File),

  [{attribute, Line, file, {elixir_utils:characters_to_list(Relative), 1}},
   {attribute, Line, module, Module},
   {attribute, Line, compile, no_auto_import},
   {attribute, Line, export, [{Fun, 1}, {'__RELATIVE__', 0}]},
   {function, Line, Fun, 1, [
     {clause, Line, [Tuple], [], [Expr]}
   ]},
   {function, Line, '__RELATIVE__', 0, [
     {clause, Line, [], [], [elixir_erl:elixir_to_erl(Relative)]}
   ]}].

retrieve_compiler_module() ->
  elixir_code_server:call(retrieve_compiler_module).

return_compiler_module(I) ->
  elixir_code_server:cast({return_compiler_module, I}).

allows_fast_compilation({'__block__', _, Exprs}) ->
  lists:all(fun allows_fast_compilation/1, Exprs);
allows_fast_compilation({defmodule, _, _}) -> true;
allows_fast_compilation(_) -> false.

%% Bootstrapper

bootstrap() ->
  {ok, _} = application:ensure_all_started(elixir),
  Update = fun(Old) -> maps:merge(Old, #{docs => false, relative_paths => false}) end,
  _ = elixir_config:update(compiler_options, Update),
  _ = elixir_config:put(bootstrap, true),
  [bootstrap_file(File) || File <- bootstrap_main()].

bootstrap_file(File) ->
  try
    Lists = file(File),
    _ = [binary_to_path(X, "lib/elixir/ebin") || X <- Lists],
    io:format("Compiled ~ts~n", [File])
  catch
    Kind:Reason ->
      io:format("~p: ~p~nstacktrace: ~p~n", [Kind, Reason, erlang:get_stacktrace()]),
      erlang:halt(1)
  end.

bootstrap_main() ->
  [<<"lib/elixir/lib/kernel.ex">>,
   <<"lib/elixir/lib/macro/env.ex">>,
   <<"lib/elixir/lib/keyword.ex">>,
   <<"lib/elixir/lib/module.ex">>,
   <<"lib/elixir/lib/list.ex">>,
   <<"lib/elixir/lib/macro.ex">>,
   <<"lib/elixir/lib/code.ex">>,
   <<"lib/elixir/lib/code/identifier.ex">>,
   <<"lib/elixir/lib/module/locals_tracker.ex">>,
   <<"lib/elixir/lib/kernel/typespec.ex">>,
   <<"lib/elixir/lib/kernel/utils.ex">>,
   <<"lib/elixir/lib/exception.ex">>,
   <<"lib/elixir/lib/protocol.ex">>,
   <<"lib/elixir/lib/stream/reducers.ex">>,
   <<"lib/elixir/lib/enum.ex">>,
   <<"lib/elixir/lib/inspect/algebra.ex">>,
   <<"lib/elixir/lib/inspect.ex">>,
   <<"lib/elixir/lib/regex.ex">>,
   <<"lib/elixir/lib/string.ex">>,
   <<"lib/elixir/lib/string/chars.ex">>,
   <<"lib/elixir/lib/io.ex">>,
   <<"lib/elixir/lib/path.ex">>,
   <<"lib/elixir/lib/file.ex">>,
   <<"lib/elixir/lib/system.ex">>,
   <<"lib/elixir/lib/kernel/cli.ex">>,
   <<"lib/elixir/lib/kernel/error_handler.ex">>,
   <<"lib/elixir/lib/kernel/parallel_compiler.ex">>,
   <<"lib/elixir/lib/kernel/lexical_tracker.ex">>].

binary_to_path({ModuleName, Binary}, CompilePath) ->
  Path = filename:join(CompilePath, atom_to_list(ModuleName) ++ ".beam"),
  case file:write_file(Path, Binary) of
    ok -> Path;
    {error, Reason} -> error('Elixir.File.Error':exception([{action, "write to"}, {path, Path}, {reason, Reason}]))
  end.
