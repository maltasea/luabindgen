# call-directions

Demonstrates all six cross-language call directions across the
**OCaml ↔ Lua ↔ C** boundary in the luabindgen + lua_of_ocaml + LuaJIT
pipeline. Single text-only program; `make run` prints labelled output
for each direction.

## the pipeline at runtime

```
              ┌──────────────────────────────────────────────────┐
              │   one luajit process                             │
              │                                                  │
   .ml   ─┐   │   gen.lua          ─── compiled OCaml as Lua     │
          │   │                                                  │
   .cmo ──┼─→ │   prelude.lua      ─── hand-written Lua glue     │ ── ffi ──→ libc
          │   │                                                  │            (qsort,
   .o   ──┘   │   (no C runs here — stubs were linker fodder)    │             strlen)
              │                                                  │
              └──────────────────────────────────────────────────┘
```

Everything that looked like C or OCaml *at compile time* is Lua at
runtime. The FFI is the only path to C. So every "OCaml -> Lua" call
is just one Lua function calling another; every "OCaml -> C" call is
a Lua function dispatching through `ffi.C`.

## the six directions

| # | direction          | demoed by (line in `main.ml`)        | mechanism |
|---|---                 |---                                   |---        |
| 1 | OCaml → C          | `c_strlen "hello, world!"`           | OCaml external -> Lua wrapper -> `ffi.C.strlen` |
| 2 | OCaml → Lua        | `lua_uppercase "abc def"`            | OCaml external -> hand-written global Lua fn |
| 3 | OCaml → Lua → C    | `lua_then_c_strlen "chained call"`   | (1) + (2) composed; the Lua wrapper itself uses `ffi.C` |
| 4 | Lua → OCaml        | `register_ocaml_callback` + `invoke_ocaml_from_lua` | OCaml hands a closure to Lua, Lua stores and later invokes it; works because `lua_of_ocaml` compiles closures to Lua functions with arity metadata |
| 5 | Lua → C            | `run_pure_lua_to_c_test ()`          | pure Lua-side `ffi.cdef` + `ffi.C` call; OCaml only initiates the test |
| 6 | C → Lua (callback) | `run_c_callback_test ()`             | `ffi.cast` wraps a Lua function as a C function pointer; passed to `qsort`, which calls back into Lua O(n log n) times |

(C ↔ OCaml direct calling isn't a thing in this pipeline — at runtime
there's no C compiled-OCaml bridge; everything that came from OCaml
is now Lua. The "C → OCaml" direction reduces to "C → Lua" because
the OCaml function is a Lua function.)

## files

| file                | role |
|---                  |---   |
| `main.ml`           | OCaml entry point; orchestrates all six directions |
| `prelude.ml`        | OCaml externals naming the prelude functions |
| `prelude.lua`       | hand-written Lua glue: FFI cdef, helper functions, OCaml-callback storage |
| `prelude_stubs.c`   | linker placeholders so `ocamlc -custom` links |
| `Makefile`          | builds and runs |

## requires

- An OCaml whose bytecode magic matches `loo`'s — see the top-level
  README's "bytecode-magic gotcha" section.
- `luajit` in PATH.
- libc (everyone has it).

## run

```
make run
```

Expected output ends with:

```
=== (6) C -> Lua  (qsort calls a Lua comparator) ===
   [Lua] sorted result: 1, 2, 4, 5, 8
   [Lua] C qsort called our Lua comparator 8 times

done.
```

If `qsort` calls the Lua comparator 8 times to sort 5 elements, you've
genuinely got C calling into Lua at runtime — the JIT-compiled Lua
function is being invoked synchronously by libc's qsort via a
function-pointer argument it received from us.
