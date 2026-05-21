# raylib-platformer

End-to-end demo: OCaml game → bytecode → lua_of_ocaml → luajit → libraylib.
A tiny platformer (gravity, jump, 3 platforms, screen-wrap) proving the
full luabindgen pipeline drives raylib.

## requires

- **An OCaml whose bytecode magic matches `loo`'s.** The bundled
  `loo` binary embeds a specific `Caml1999XNNN` magic; compiling with
  a different OCaml series fails with `Bad_magic_version`. To check:

      strings ../../extern/lua_of_ocaml/_build/default/compiler/bin-lua_of_ocaml/main.exe \
        | grep -E "Caml1999X[0-9]"

  Typical mapping: `X031`=4.14, `X034`=5.2, `X035`=5.3, `X036`=5.4.
  Activate the matching switch before `make`:

      eval $(opam env --switch=<matching version> --set-switch)

- **luajit** — `which luajit`

- **raylib** — `brew install raylib`. The dylib must be discoverable
  by `ffi.load("raylib")` (brew puts it where macOS dyld looks).

## run

    make run

`make clean && make run` does the whole pipeline from scratch:

1. `luabingen.ml` reads `/usr/local/Cellar/raylib/5.5/include/raylib.h`
   → `raylib_external.ml` + `raylib_stubs.c` + `raylib_bindings.lua`
2. `ocamlc` compiles the stubs, the externals, and `main.ml`, linking
   to `-custom` bytecode
3. `loo.sh` (the lua_of_ocaml compiler) turns the bytecode into
   `gen.lua`
4. `cat missing_runtime.lua raylib_bindings.lua gen.lua > main.lua`
5. `luajit main.lua` opens the window

## controls

- `←` / `→` — move
- `space` — jump (while grounded)
- `esc` or close button — quit

## what's here

| file | role |
|---|---|
| `main.ml`             | gameplay + render. 120-ish lines |
| `Makefile`            | the full pipeline |
| `README.md`           | this file |
| `.gitignore`          | ignores everything generated at build time |

## runtime dependency

Requires `caml_mkclosure` in `extern/lua_of_ocaml/runtime/lua/stdlib.lua`.
The lua_of_ocaml code generator emits `caml_mkclosure(arity, fn)` to
wrap closures, but historically the runtime didn't define it — the
first OCaml closure call would then crash inside `caml_call_gen` doing
`f.arity` on a number. This repo's vendored lua_of_ocaml has the fix:

    function caml_mkclosure(arity, fn)
      return setmetatable({arity = arity},
        { __call = function(_, ...) return fn(...) end })
    end

If you're running against an older lua_of_ocaml that doesn't have it,
add the function to `runtime/lua/stdlib.lua` before building.

## how `main.ml` uses the bindings

The interesting bits, all driven by what `luabingen` emitted from
`raylib.h`:

**Opaque types** — `color` and `vector2` are abstract OCaml types. The
program never inspects them, only constructs and passes them.

    let bg = make_color 30 40 65 255     (* int -> int -> int -> int -> color *)
    clear_background bg                   (* color -> unit *)

**Enum constants** — `key_space`, `key_left`, `key_right` are plain
`int` values, snake-cased from raylib's `KEY_SPACE` etc.

    if is_key_down key_space && on_ground () then p.vy <- jump_vy

**Struct-by-value arguments** — `draw_triangle` takes three Vector2s.
The OCaml side hands over `vector2` values; the Lua wrapper extracts
each one's cdata before calling `C.DrawTriangle`.

    draw_triangle (make_vector2 0.0 350.0)
                  (make_vector2 160.0 200.0)
                  (make_vector2 320.0 350.0)
                  mtn_far

**Struct returns** — `make_color` etc. are externals that return an
abstract type; the Lua wrapper wraps the cdata as `{0, cdata}` so the
OCaml side has an opaque token to pass around.

That's basically the whole API surface needed — abstract types,
constructors, draw functions taking colors and vectors, plus int-
typed keyboard polling.

## what doesn't work

- **OCaml callbacks into C** — raylib's `SetTraceLogCallback` etc.
  would need a real OCaml-fn → C-fn-ptr bridge. Not done.
- **Sound** — would work in principle (the bindings cover raudio) but
  not exercised by this example.

The mouse-follow dot at the cursor uses generated field accessors
(`vector2_x`, `vector2_y`) on the `Vector2` returned by
`get_mouse_position`, so scalar-field reads round-trip end-to-end.
Array fields (`float params[4]`, `Matrix projection[2]`) don't have
accessors yet — the struct's *layout* is preserved correctly, you
just can't read the array out element-by-element from OCaml.
