-- Primitives that lua_of_ocaml's runtime references but doesn't define.
-- Found while running the platformer through the pipeline: caml_call_gen
-- does `f.arity`, but no caml_mkclosure exists to produce an arity-tagged
-- value. Wrap a Lua function as a callable table with the arity field.

function caml_mkclosure(arity, fn)
  return setmetatable({arity = arity},
    { __call = function(_, ...) return fn(...) end })
end
