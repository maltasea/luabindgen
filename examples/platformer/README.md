# platformer

End-to-end demo: OCaml game → bytecode → lua_of_ocaml → luajit → libraylib.

## requires

- `ocaml` 5.4.x (bytecode magic `Caml1999X036` to match the bundled
  loo binary). On this machine the system switch (`/Users/ben`) has it.
- `luajit` in PATH.
- raylib installed (`brew install raylib`).

## run

```
make run
```

## what's here

| file | role |
|---|---|
| `main.ml` | the game — player rect, gravity, jump, 3 platforms |
| `missing_runtime.lua` | shim for `caml_mkclosure` which lua_of_ocaml's runtime references but doesn't define |
| `Makefile` | generates bindings, compiles, links, loo, luajit |

## generated at build time

- `raylib_external.ml` — OCaml externals + `let key_space = 32` enum constants
- `raylib_stubs.c` — C stubs (never executed; only for ocamlc linking)
- `raylib_bindings.lua` — LuaJIT FFI cdef + wrappers
- `main.byte`, `gen.lua`, `main.lua` — pipeline outputs

## controls

- `←` / `→` — move
- `space` — jump (while grounded)
- `esc` or close button — quit
