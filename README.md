# luabindgen — lua binding generator

https://maltasea.yoiky.com/luabindgen

[GitHub](https://github.com/maltasea/luabindgen)

Generates [lua_of_ocaml](https://github.com/maltasea/lua_of_ocaml) FFI bindings
from either a C header or a Lua source. Single OCaml file, stdlib +
`str` only.

A working end-to-end demo (OCaml game → raylib via luajit) lives in
[`examples/raylib-platformer/`](examples/raylib-platformer/).

For a complete walkthrough of every input → output mapping the
generator handles (function decls, structs, enums, typedefs,
#defines, the prelude pattern for cases the generator can't reach,
and all six cross-language calling directions at runtime), read
**[`docs/book.md`](docs/book.md)**.

## what it generates

Each run emits three sibling files (named after the input):

| file | role |
|---|---|
| `<base>_external.ml`   | OCaml `external` declarations + abstract types + enum constants + struct constructors |
| `<base>_stubs.c`       | Dummy C stubs for `ocamlc -custom` linking — never executed at runtime |
| `<base>_bindings.lua`  | LuaJIT FFI `ffi.cdef [[...]]` + per-fn wrappers that handle OCaml ↔ C value conversion |

The OCaml side gets a typed library. The Lua side gets the per-function
wrappers that the lua_of_ocaml runtime calls into.

## install / run

The generator itself needs OCaml 4.10+ with the `str` library — no
opam packages, no dune.

    ocaml -I +str str.cma luabingen.ml [opts] <file.h | file.lua>

Options:

    --prefix PFX        strip a leading identifier prefix (e.g. "RLAPI")
    --lib NAME          emit `local C = ffi.load("NAME")` (default: ffi.C)
    --out-dir DIR       write generated files into DIR (default: cwd)
    --strip TOK,...     drop identifier tokens before parsing
                        (e.g. "SDL_DECLSPEC,SDLCALL")

When the parser gives up on a declaration it prints a `  warn:` line
to stderr (anonymous unions, inline function bodies, unrecognized
typedef shapes). Raylib emits zero; SDL3 emits about a dozen.

## the bytecode-magic gotcha

To use the *output*, your OCaml must match the version `loo` (the
lua_of_ocaml compiler) was built against. The bundled `loo` binary
embeds a specific OCaml bytecode magic (`Caml1999XNNN`); compiling
your `.ml` with a different OCaml series produces a mismatched magic
and `loo` fails with `Bad_magic_version`.

Check what your `loo` expects:

    strings extern/lua_of_ocaml/_build/default/compiler/bin-lua_of_ocaml/main.exe \
      | grep -E "Caml1999X[0-9]"

Then pick the matching opam switch (typical mapping: `X031`=4.14,
`X034`=5.2, `X035`=5.3, `X036`=5.4). If `loo` was rebuilt against a
different OCaml since the example was last run, the example will fail
with `Bad_magic_version` until you `eval $(opam env --switch=<right
version> --set-switch)` before `make`.

## C input

    ocaml -I +str str.cma luabingen.ml \
      --prefix "RLAPI" --lib raylib --out-dir gen extern/raylib-6.0/src/raylib.h

For `extern/raylib-6.0/src/raylib.h`: 600 function decls, 37 structs
(20 with auto-generated constructors), 22 enums (305 constants).
(The brew `/usr/local/Cellar/raylib/5.5/include/raylib.h` gives 581 /
36 / 22 / 300; counts drift between raylib versions.)

C type → OCaml side:

| C type                       | OCaml                                              |
|---                           |---                                                 |
| `void`                       | `unit`                                             |
| `int`, `unsigned`, ...       | `int`                                              |
| `float`, `double`            | `float`                                            |
| `bool`                       | `bool`                                             |
| `const char *`               | `string`                                           |
| `T *` (other)                | `int` (opaque pointer)                             |
| `Color`, `Vector2`, ...      | abstract `color`, `vector2` types                  |
| enum                         | `int` (constants exposed as `let key_space = 32`)  |

Struct-by-value parameters cross the boundary as `{0, cdata}` blocks.
The Lua wrapper extracts the cdata before calling C; the C return
value is wrapped on the way back. For each "simple" struct (all
fields scalar, recursively), a constructor is emitted:

    external make_color : int -> int -> int -> int -> color = "make_color"
    external make_vector3 : float -> float -> float -> vector3 = "make_vector3"

Complex structs (containing pointers, e.g. `Image`, `Mesh`) stay
opaque and are obtained only from API calls.

## Lua input

    ocaml -I +str str.cma luabingen.ml --out-dir gen wrap_Math.lua

For LÖVE-style `wrap_*.lua` modules: extracts public `function
mod.fn(...)`, `function mod.sub.fn(...)`, `function Class:method(...)`
definitions plus embedded `pcall(ffi.cdef, [[...]])` blobs. Conservative
defaults — args and returns typed as `float` since types can't be
recovered from Lua source. Edit the resulting `_external.ml` signatures
as you sharpen them.

Methods get the receiver class as an abstract OCaml type and become the
first arg:

    type random_generator
    external random_generator_random
      : random_generator -> float -> float -> float
      = "random_generator_random"

Duplicate definitions (LÖVE wrap files routinely define a function
twice — once for JIT, once for non-JIT) are deduplicated, last wins.

## ABI

The generated bindings target lua_of_ocaml's value encoding, observed
in its runtime + canonical hand-written example
`extern/lua_of_ocaml/example-game/love_runtime.lua`:

| OCaml type           | Lua encoding         |
|---                   |---                   |
| `int`                | `n * 2`              |
| `bool`               | `0 = false, 2 = true`|
| `float`              | `{ 253, v }`         |
| `string`             | identity             |
| block / struct       | `{ tag, f1, f2, ... }` (tag 0 for struct wrappers) |

A single `ocaml_val(v)` helper at the top of the bindings file unwraps
int or float in one call (matches the project's `love_runtime.lua`).
Returns are re-tagged based on the underlying C type (not the OCaml
mapping) — critical because a `Shader` return maps to `int` on the
OCaml side but is a real cdata struct on the Lua side, so `* 2` on it
would crash.

## putting it together

See [`examples/raylib-platformer/Makefile`](examples/raylib-platformer/Makefile)
for the full pipeline. The shape is:

    # 1. Generate bindings
    ocaml -I +str str.cma luabingen.ml --prefix "RLAPI" --lib raylib \
      --out-dir . raylib.h

    # 2. Compile OCaml + C stubs to a -custom bytecode executable
    ocamlc -c raylib_stubs.c
    ocamlc -c raylib_external.ml
    ocamlc -c main.ml
    ocamlc -custom -o main.byte raylib_stubs.o raylib_external.cmo main.cmo

    # 3. Bytecode -> Lua
    LOO_RUNTIME=path/to/lua_of_ocaml/runtime/lua \
      ./loo.sh main.byte -o gen.lua

    # 4. Concatenate bindings + generated code, run with luajit
    cat raylib_bindings.lua gen.lua > main.lua
    luajit main.lua

## limitations

- **Callbacks (function pointers)** — emitted as `typedef void* X` in
  the cdef and `int` on the OCaml side. Round-tripping OCaml functions
  through C function pointers isn't supported yet.
- **Varargs** — stripped from the OCaml signature (`TraceLog(int, const
  char*, ...)` becomes `int -> string -> unit`). OCaml externals can't
  express variadic arity.
- **Multi-line C prototypes** — the lexer handles them fine; raylib.h
  happens to be all single-line so this isn't exercised.
- **Lua input typing** — placeholder `float` signatures; user edits.
- **Array fields in field accessors** — scalar field accessors
  (`color_r`, `vector2_x`) are emitted; array fields (`float
  params[4]`, `Matrix projection[2]`) are skipped since the generic
  single-value wrapper can't return a Lua cdata array meaningfully.
  Struct *layout* preserves the array, so passing the parent struct
  through still works correctly.
- **Setters** — only getters, no setters yet. Construct new struct
  values with the `make_*` constructors and replace whole.
