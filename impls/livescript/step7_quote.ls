readline = require './node_readline'
{id, map, each, last, all, unique, zip, Obj, elem-index} = require 'prelude-ls'
{read_str} = require './reader'
{pr_str} = require './printer'
{Env} = require './env'
{runtime-error, ns} = require './core'
{list-to-pairs} = require './utils'


defer-tco = (env, ast) ->
    type: \tco
    env: env
    ast: ast
    eval: -> eval_ast env, ast


is-thruthy = ({type, value}) -> 
    type != \const or value not in [\nil \false]


fmap-ast = (fn, {type, value}: ast) -->
    {type: type, value: fn value}


make-symbol = (name) -> {type: \symbol, value: name}
make-list = (value) -> {type: \list, value: value}
make-call = (name, params) -> make-list [make-symbol name] ++ params
is-symbol = (ast, name) -> ast.type == \symbol and ast.value == name


eval_simple = (env, {type, value}: ast) ->
    switch type
    | \symbol => env.get value
    | \list, \vector => ast |> fmap-ast map eval_ast env
    | \map => ast |> fmap-ast Obj.map eval_ast env
    | otherwise => ast


eval_ast = (env, {type, value}: ast) -->
    loop
        if type != \list
            return eval_simple env, ast
        else if value.length == 0
            return ast

        result = if value[0].type == \symbol
            params = value[1 to]
            switch value[0].value
            | 'def!'       => eval_def env, params
            | 'let*'       => eval_let env, params
            | 'do'         => eval_do env, params
            | 'if'         => eval_if env, params
            | 'fn*'        => eval_fn env, params
            | 'quote'      => eval_quote env, params
            | 'quasiquote' => eval_quasiquote env, params
            | otherwise    => eval_apply env, value
        else 
            eval_apply env, value

        if result.type == \tco
            env = result.env
            {type, value}: ast = result.ast
        else
            return result


check_params = (name, params, expected) ->
    if params.length != expected
        runtime-error "'#{name}' expected #{expected} parameters, 
                       got #{params.length}"


eval_def = (env, params) ->
    check_params 'def!', params, 2

    # Name is in the first parameter, and is not evaluated.
    name = params[0]
    if name.type != \symbol
        runtime-error "expected a symbol for the first parameter 
                       of def!, got a #{name.type}"

    # Evaluate the second parameter and store 
    # it under name in the env.
    env.set name.value, (eval_ast env, params[1])


eval_let = (env, params) ->
    check_params 'let*', params, 2

    binding_list = params[0]
    if binding_list.type not in [\list \vector]
        runtime-error "expected 1st parameter of 'let*' to 
                       be a binding list (or vector), 
                       got a #{binding_list.type}"
    else if binding_list.value.length % 2 != 0
        runtime-error "binding list of 'let*' must have an even 
                       number of parameters"

    # Make a new environment with the 
    # current environment as outer.
    let_env = new Env env

    # Evaluate all binding values in the
    # new environment.
    binding_list.value
    |> list-to-pairs
    |> each ([binding_name, binding_value]) ->
        if binding_name.type != \symbol
            runtime-error "expected a symbol as binding name, 
                           got a #{binding_name.type}"

        let_env.set binding_name.value, (eval_ast let_env, binding_value)

    # Defer evaluation of let* body with TCO.
    defer-tco let_env, params[1]


eval_do = (env, params) ->
    if params.length == 0
        runtime-error "'do' expected at least one parameter"

    [...rest, last-param] = params
    rest |> each eval_ast env
    defer-tco env, last-param


eval_if = (env, params) ->
    if params.length < 2
        runtime-error "'if' expected at least 2 parameters"
    else if params.length > 3
        runtime-error "'if' expected at most 3 parameters"

    cond = eval_ast env, params[0]
    if is-thruthy cond
        defer-tco env, params[1]
    else if params.length > 2
        defer-tco env, params[2]
    else
        {type: \const, value: \nil}


eval_fn = (env, params) ->
    check_params 'fn*', params, 2

    if params[0].type not in [\list \vector]
        runtime-error "'fn*' expected first parameter to be a list or vector."

    if not all (.type == \symbol), params[0].value
        runtime-error "'fn*' expected only symbols in the parameters list."

    binds = params[0].value |> map (.value)
    vargs = null

    # Parse variadic bind.
    if binds.length >= 2
        [...rest, amper, name] = binds
        if amper == '&' and name != '&'
            binds = rest
            vargs = name

    if elem-index '&', binds
        runtime-error "'fn*' invalid usage of variadic parameters."

    if (unique binds).length != binds.length
        runtime-error "'fn*' duplicate symbols in parameters list."

    body = params[1]

    fn_instance = (...values) ->
        if not vargs and values.length != binds.length
            runtime-error "function expected #{binds.length} parameters, 
                           got #{values.length}"
        else if vargs and values.length < binds.length
            runtime-error "function expected at least 
                           #{binds.length} parameters, 
                           got #{values.length}"

        # Set binds to values in the new env.
        fn_env = new Env env

        for [name, value] in (zip binds, values)
            fn_env.set name, value

        if vargs
            fn_env.set vargs, 
                make-list values.slice binds.length

        # Defer evaluation of the function body to TCO.
        defer-tco fn_env, body

    {type: \function, value: fn_instance}


eval_apply = (env, list) ->
    [fn, ...args] = list |> map eval_ast env
    if fn.type != \function
        runtime-error "#{fn.value} is not a function, got a #{fn.type}"

    fn.value.apply env, args


eval_quote = (env, params) ->
    if params.length != 1
        runtime-error "quote expected 1 parameter, got #{params.length}"

    params[0]


is-pair = (ast) -> ast.type in [\list \vector] and ast.value.length != 0


eval_quasiquote = (env, params) ->
    if params.length != 1
        runtime-error "quasiquote expected 1 parameter, got #{params.length}"

    ast = params[0]
    new-ast = if not is-pair ast
        make-call 'quote', [ast]
    else if is-symbol ast.value[0], 'unquote'
        ast.value[1]
    else if is-pair ast.value[0] and \
            is-symbol ast.value[0].value[0], 'splice-unquote'
        make-call 'concat', [
            ast.value[0].value[1]
            make-call 'quasiquote', [make-list ast.value[1 to]]
        ]
    else
        make-call 'cons', [
            make-call 'quasiquote', [ast.value[0]]
            make-call 'quasiquote', [make-list ast.value[1 to]]
        ]

    defer-tco env, new-ast


repl_env = new Env
for symbol, value of ns
    repl_env.set symbol, value

# Evil eval.
repl_env.set 'eval', do
    type: \function
    value: (ast) -> eval_ast repl_env, ast  # or use current env? (@ = this).


rep = (line) ->
    line
    |> read_str
    |> eval_ast repl_env
    |> (ast) -> pr_str ast, print_readably=true


# Define not.
rep '(def! not (fn* (x) (if x false true)))'

# Define load-file.
rep '
(def! load-file 
  (fn* (f)
    (eval
      (read-string
        (str "(do " (slurp f) "\nnil)")))))'

# Parse program arguments.
# The first two (exe and core-file) are, respectively,
# the interpreter executable (nodejs or lsc) and the
# source file being executed (stepX_*.(ls|js)).
[exe, core-file, mal-file, ...argv] = process.argv

repl_env.set '*ARGV*', do
    type: \list
    value: argv |> map (arg) ->
        type: \string
        value: arg

if mal-file
    rep "(load-file \"#{mal-file}\")"
else
    # REPL.
    loop
        line = readline.readline 'user> '
        break if not line? or line == ''
        try
            console.log rep line
        catch error
            if error.message
            then console.error error.message
            else console.error "Error:", pr_str error, print_readably=true
