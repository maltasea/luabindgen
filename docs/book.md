# The luabindgen Book

How the generator turns a C header (or a Lua source) into the three
sibling files an OCaml-via-lua_of_ocaml-via-LuaJIT program needs to
talk to a C library, and how to plug the cases the generator can't
synthesize on its own.

  - [Part I — The runtime, in one diagram](#part-i--the-runtime-in-one-diagram)
  - [Part II — C header in, three files out](#part-ii--c-header-in-three-files-out)
  - [Part III — Lua source in](#part-iii--lua-source-in)
  - [Part IV — Cross-language calling at runtime](#part-iv--cross-language-calling-at-runtime)
  - [Part V — Mechanics](#part-v--mechanics)
  - [Part VI — What the generator can't do, and how to glue around it](#part-vi--what-the-generator-cant-do-and-how-to-glue-around-it)

---

## Part I — The runtime, in one diagram

```
              ┌──────────────────────────────────────────────────┐
              │   one luajit process                             │
              │                                                  │
   .ml   ─┐   │   gen.lua          ── compiled OCaml as Lua      │
          │   │                                                  │
   .cmo ──┼─→ │   prelude.lua      ── hand-written glue          │ ── ffi ──→ libfoo
          │   │                                                  │
   .o   ──┘   │   bindings.lua     ── generated FFI wrappers     │
              │                                                  │
              │   (no C runs here — the .o stubs were linker     │
              │    fodder for `ocamlc -custom`, never executed)  │
              └──────────────────────────────────────────────────┘
```

The generator's job is to populate `gen.lua` (via the OCaml externals
it emits) and `bindings.lua` (the FFI wrappers it emits) so that an
OCaml call like `init_window 600 400 "title"` reaches `libfoo`'s C
`InitWindow` through one Lua hop. The `.o` stubs satisfy `ocamlc
-custom`'s linker; nothing in them actually runs.

The "ABI" everything must agree on is the value encoding
`lua_of_ocaml` uses at runtime:

| OCaml value   | Lua representation         |
|---            |---                         |
| `int`         | `n * 2`                    |
| `bool`        | `0` (false) or `2` (true)  |
| `float`       | `{ 253, v }`               |
| `string`      | identity (Lua string)      |
| record/tuple  | `{ tag, f1, f2, ... }`     |

The generator wires up every wrapper to match.

---

## Part II — C header in, three files out

`luabingen header.h` writes three files named after the header:

```
<base>_external.ml     OCaml externals + abstract types + constants + constructors
<base>_stubs.c         CAMLprim placeholders, one per external
<base>_bindings.lua    ffi.cdef + per-function Lua wrappers
```

Every C construct below maps into one or more of those.

### 2.1 — Function declarations

Input:

```c
RLAPI void InitWindow(int width, int height, const char *title);
RLAPI int  GetScreenWidth(void);
RLAPI bool WindowShouldClose(void);
```

With `--prefix RLAPI` and `--lib raylib`:

**external.ml**

```ocaml
external init_window : int -> int -> string -> unit = "init_window"
external get_screen_width : unit -> int = "get_screen_width"
external window_should_close : unit -> bool = "window_should_close"
```

**stubs.c**

```c
CAMLprim value init_window(value v1, value v2, value v3) {
  (void)v1; (void)v2; (void)v3; return Val_unit;
}
CAMLprim value get_screen_width(value v_unit) {
  (void)v_unit; return Val_int(0);
}
CAMLprim value window_should_close(value v_unit) {
  (void)v_unit; return Val_bool(0);
}
```

**bindings.lua**

```lua
ffi.cdef [[
  void InitWindow(int width, int height, const char * title);
  int GetScreenWidth(void);
  bool WindowShouldClose(void);
]]
local C = ffi.load("raylib")

function init_window(a1,a2,a3) C.InitWindow(ocaml_val(a1), ocaml_val(a2), a3); return end
function get_screen_width() return (C.GetScreenWidth()) * 2 end
function window_should_close() return (C.WindowShouldClose()) and 2 or 0 end
```

What's happening:

- **Args** are unwrapped on the Lua side. `ocaml_val(a)` is the one
  helper the generator emits at the top of `bindings.lua` — it
  divides ints by 2 and unboxes floats from their `{253,v}` form.
  Strings pass through unchanged because LuaJIT FFI accepts Lua
  strings as `const char *`.
- **Returns** are re-tagged to match the OCaml encoding:
  `int * 2`, `bool and 2 or 0`, `void` → no return.

### 2.2 — Type mapping

| C type                  | OCaml side | abi notes                                  |
|---                      |---         |---                                         |
| `void`                  | `unit`     |                                            |
| `bool`, `_Bool`         | `bool`     | encoded as `0` / `2`                        |
| `int`, `unsigned`, etc. | `int`      | encoded as `n * 2`                          |
| `float`, `double`       | `float`    | boxed `{253, v}`                            |
| `char *`, `const char *`| `string`   | identity in (Lua → C), `ffi.string` on out  |
| other `T *`             | `int`      | opaque pointer (passthrough cdata)          |
| `T[]` in a param        | `int`      | C array decays to pointer in parameter pos  |
| named struct            | abstract OCaml type `t` (snake-cased) — see §2.3 |        |
| named enum              | `int`      | constants emitted as `let key_space = 32`   |
| named callback typedef  | `int`      | opaque (no OCaml → C-fn-ptr bridge yet)     |

### 2.3 — Structs

A struct gets:

- an **abstract OCaml type** (`type color`) so the OCaml signature
  can reference it;
- a **`make_<name>` constructor** if every field is recursively a
  scalar (or another simple struct);
- a **field accessor per scalar field**;
- a **`typedef struct ...` in the ffi.cdef** with all fields
  preserved in source-order layout.

Input:

```c
typedef struct Color { unsigned char r, g, b, a; } Color;
typedef struct RenderTexture { unsigned int id; Texture texture; Texture depth; } RenderTexture;

RLAPI void ClearBackground(Color color);
RLAPI Vector2 GetWindowPosition(void);
```

**external.ml** (excerpt)

```ocaml
type color
type vector2
type render_texture

external make_color
  : int -> int -> int -> int -> color = "make_color"
external make_vector2
  : float -> float -> vector2 = "make_vector2"
external make_render_texture
  : int -> texture -> texture -> render_texture = "make_render_texture"

external color_r : color -> int = "color_r"
external color_g : color -> int = "color_g"
external color_b : color -> int = "color_b"
external color_a : color -> int = "color_a"
external vector2_x : vector2 -> float = "vector2_x"
external vector2_y : vector2 -> float = "vector2_y"
external render_texture_id : render_texture -> int = "render_texture_id"
external render_texture_texture : render_texture -> texture = "render_texture_texture"

external clear_background : color -> unit = "clear_background"
external get_window_position : unit -> vector2 = "get_window_position"
```

**bindings.lua** (excerpt)

```lua
ffi.cdef [[
  typedef struct Color Color;            -- forward decl up front
  typedef struct Vector2 Vector2;
  typedef struct RenderTexture RenderTexture;
  -- struct bodies, topologically sorted by by-value deps:
  struct Color { unsigned char r; unsigned char g; unsigned char b; unsigned char a; };
  struct Vector2 { float x; float y; };
  struct Texture { ... };
  struct RenderTexture {
    unsigned int id;
    struct Texture texture;
    struct Texture depth;
  };

  void ClearBackground(Color color);
  Vector2 GetWindowPosition(void);
]]

-- struct ABI: a struct value crosses as a wrapped block {0, cdata}.
-- OCaml side sees an opaque token; Lua wrappers unwrap/wrap at the
-- boundary.
function make_color(a1,a2,a3,a4)
  return { 0, ffi.new("Color", { ocaml_val(a1), ocaml_val(a2), ocaml_val(a3), ocaml_val(a4) }) }
end
function color_r(a1) return (a1[2].r) * 2 end
function clear_background(a1) C.ClearBackground(a1[2]); return end
function get_window_position() return { 0, C.GetWindowPosition() } end
```

So in OCaml you write:

```ocaml
let bg = make_color 30 40 65 255 in
clear_background bg;
let m = get_window_position () in
Printf.printf "%.0f %.0f\n" (vector2_x m) (vector2_y m)
```

Why the `{0, cdata}` wrap? lua_of_ocaml's runtime distinguishes
OCaml values by shape (`number` = int, `table[1]==253` = float, etc.).
A raw cdata pointer would be misinterpreted; wrapping it as a one-
field block with tag 0 makes it look like a normal OCaml record to
the runtime. The OCaml-side abstract type ensures the user can't
accidentally do arithmetic on it.

**Simple vs complex.** A "simple" struct is one whose fields all
reduce to scalars (or other simple structs). `Color`, `Vector2`,
`Rectangle`, `Camera3D` are simple. `Image` (has `void *data`),
`Mesh` (lots of pointers), `Font` (pointers to glyph tables) are
complex.

- **Simple structs** get a `make_` constructor and full field
  accessors. You can build them from OCaml and pass them around.
- **Complex structs** are opaque. No constructor — you obtain them
  by calling library functions (`LoadImage`, `LoadFont`, etc.).
  Field accessors are still emitted for scalar fields, so you can
  read `image_width`, `image_height` etc. from OCaml even though
  you can't construct an `Image` yourself.

**Self-referential pointer fields.** `typedef struct Node { Node *next; } Node;`
is tricky because the typedef alias isn't visible inside its own
body. The generator notices and emits `struct Node *next` in field
position so the cdef parses.

**Array fields.** `float v[4]` preserves the array shape in the
cdef (so struct layout is correct):

```lua
struct Matrix { float m0; ... float m15; };
```

No accessor for the array field itself (a generic single-value
getter can't return a Lua cdata array meaningfully); the parent
struct's layout is correct, which is what matters for round-tripping.

**Function-pointer fields.** `T (*name)(args);` inside a struct is
detected and stored as `Ptr Void` — opaque, no accessor. Otherwise
the parser would chew through the function-pointer's argument
names and invent fake struct fields.

**Anonymous unions/structs.** `union { int a; struct { int b; } c; } f;`
as a field is skipped with a `warn:` line. We can't faithfully model
the alternative-layout semantics; the alternative is misparsed
fake fields.

### 2.4 — Enums

Input:

```c
typedef enum KeyboardKey {
  KEY_NULL  = 0,
  KEY_SPACE = 32,
  KEY_LEFT  = 263
} KeyboardKey;

enum {
  ANON_A = 7,
  ANON_B = 8
};

enum ConfigFlags {
  FLAG_VSYNC_HINT     = 0x40u,
  FLAG_FULLSCREEN     = 0x02u,
  FLAG_RESIZABLE      = 0x4u,
  FLAG_BIG_FLAG       = 1 << 30,
  FLAG_COMBINED       = FLAG_VSYNC_HINT | FLAG_FULLSCREEN
};
```

**external.ml**

```ocaml
let key_null = 0
let key_space = 32
let key_left = 263

let anon_a = 7
let anon_b = 8

let flag_vsync_hint = 64
let flag_fullscreen = 2
let flag_resizable = 4
let flag_big_flag = 1073741824
let flag_combined = 66
```

What to know:

- **Each constant is a top-level `let`**, snake-cased.
- **Tagged enums** emit a `typedef int <TagName>;` in the cdef so
  the name resolves where used in struct fields or function args.
- **Anonymous top-level enums** (`enum { A=1, B=2 };`) still emit
  their constants — just without a typedef.
- **Value expressions** beyond bare literals are evaluated by a
  tiny integer-expression interpreter that handles `<<`, `>>`,
  `|`, `&`, `^`, `+`, `-`, unary `-` / `~`, parens, and references
  to prior enum constants. Anything outside that subset (e.g.
  `sizeof(int)`) prints `  warn: ...` to stderr and falls back to
  previous + 1.
- **Suffixes** (`u`, `U`, `l`, `L`) are stripped before parsing
  literals.
- **OCaml-reserved names** (`true`, `false`, `mod`, `type`, …) are
  skipped — they'd produce uncompilable `let`s.

### 2.5 — Typedefs

#### Simple aliases

```c
typedef Vector4 Quaternion;
typedef Texture Texture2D;
```

These become transparent aliases — both ends of the typedef chain
resolve to the same OCaml type. The cdef emits `typedef Vector4
Quaternion;` so the alias name works inside struct field types
that reference it.

#### Pointer aliases (opaque handles)

```c
typedef struct Foo *FooHandle;
```

`FooHandle` is **not** a struct-by-value type; it's a pointer alias.
The generator emits `Alias (FooHandle, Ptr (Named Foo))`:

```ocaml
type foo  (* forward, no constructor — opaque struct *)

external get_foo : unit -> int = "get_foo"     (* returns the pointer as opaque int *)
external use_foo : int -> unit = "use_foo"
```

```lua
typedef struct Foo Foo;
typedef Foo * FooHandle;

function get_foo() return C.GetFoo() end           -- passthrough; no {0, cdata}
function use_foo(a1) C.UseFoo(a1); return end      -- passthrough
```

Common pattern in C APIs that hide internal struct layout
(SDL_Window, sqlite3_stmt, …).

#### Function-pointer typedefs

```c
typedef void (*TraceLogCallback)(int level, const char *fmt, ...);
RLAPI void SetTraceLogCallback(TraceLogCallback cb);
```

```lua
typedef void* TraceLogCallback;     -- opaque pointer in the cdef
```

```ocaml
external set_trace_log_callback : int -> unit = "set_trace_log_callback"
```

The OCaml side sees an opaque int. There's no OCaml → C-function-
pointer bridge yet; if you need to register a callback, you go
through Lua (`ffi.cast` a Lua function to a C function pointer in a
prelude) and pass the resulting opaque int back through OCaml.

### 2.6 — `#define` integer constants

```c
#define SDL_INIT_VIDEO 0x20u
#define SDL_INIT_AUDIO 0x10u
#define MAX_LIGHTS     8
```

```ocaml
let sdl_init_video = 32
let sdl_init_audio = 16
let max_lights = 8
```

Only single-token integer literal `#define`s are extracted (decimal,
hex, with `u`/`U`/`l`/`L` suffix). Anything more complex (function
macros, macro references, string literals, expressions) is silently
skipped — too risky to evaluate.

### 2.7 — CLI flags

| flag                    | effect                                                  |
|---                      |---                                                      |
| `--prefix STRING`       | strip from leading identifier (e.g. "RLAPI ")           |
| `--lib NAME`            | emit `local C = ffi.load("NAME")` (default `ffi.C`)     |
| `--out-dir DIR`         | write the three files into DIR (created if missing)     |
| `--strip TOK,TOK,...`   | drop identifier tokens before parsing (`SDL_DECLSPEC`, `SDLCALL`, ...) |

### 2.8 — Warning lines

At the end of parsing, the generator prints `  warn: ...` lines to
stderr for sites where it gave up:

```
[C] 934 fn decls, 126 structs (12 simple), 77 enums, 332 #defines from sdl3.h
  warn: skipped anonymous union/struct field (2 occurrences, lines 21345,21365)
  warn: skipped inline function body: SDL_RectsEqual (1 occurrences, lines 9592)
  warn: unrecognized typedef shape (skipped) (9 occurrences, lines 57,58,59,...)
  warn: enum FLAG_X.FLAG_BAD: couldn't evaluate `sizeof(int)`, using prev+1
```

The number-with-lines shape makes it easy to grep the source and
decide whether the skip mattered. Raylib emits zero of these; SDL3
emits about a dozen.

---

## Part III — Lua source in

`luabingen wrap_Math.lua` extracts the public binding surface from a
Lua source file. The same three output files are produced. **Types
can't be recovered from Lua source** — there's no signature info —
so all argument and return types default to `float` (the most common
LÖVE-shape). The user edits as they sharpen the API.

### 3.1 — Top-level function definitions

Input:

```lua
function love_math.random(l, u)
  return rng:random(l, u)
end

function love_math.noise(x, y, z, w)
  -- ...
end
```

**external.ml**

```ocaml
external love_math_random : float -> float -> float = "love_math_random"
external love_math_noise  : float -> float -> float -> float -> float = "love_math_noise"
```

**bindings.lua** (the body is a routed call into the original
Lua function, name preserved):

```lua
function love_math_random(a1,a2)
  return { 253, love_math.random(ocaml_val(a1), ocaml_val(a2)) }
end
```

### 3.2 — Method definitions

Input:

```lua
function RandomGenerator:random(l, u)
  return rng:random(l, u)
end
```

The receiver class becomes an abstract OCaml type, prepended as the
first argument:

```ocaml
type random_generator
external random_generator_random
  : random_generator -> float -> float -> float = "random_generator_random"
```

The Lua wrapper extracts the cdata from the `{0, instance}` block
and dispatches via the colon syntax:

```lua
function random_generator_random(a1,a2,a3)
  return { 253, a1[2]:random(ocaml_val(a2), ocaml_val(a3)) }
end
```

### 3.3 — `ffi.cdef` blocks

`pcall(ffi.cdef, [[...]])` / `ffi.cdef([[...]])` / `ffi.cdef [[...]]`
inside the Lua source are captured and concatenated into the generated
`_bindings.lua` so LuaJIT still sees the C declarations the source
needed.

### 3.4 — Dedup

LÖVE wrap files routinely define the same function twice (one branch
for JIT, one for non-JIT). Lua semantics: the latter wins. The
generator drops earlier dupes so the OCaml externals don't collide.

### 3.5 — Control-block descent

Functions defined inside `if jit then ... else ... end` blocks are
picked up — the parser doesn't skip control structures wholesale.

---

## Part IV — Cross-language calling at runtime

(See `examples/call-directions/` for a runnable test of each
direction.)

| # | direction         | how it works                                                     |
|---|---                |---                                                               |
| 1 | OCaml → C         | OCaml external → generated Lua wrapper → `ffi.C.fn`              |
| 2 | OCaml → Lua       | OCaml external → hand-written global Lua function                |
| 3 | OCaml → Lua → C   | (1) + (2) composed                                               |
| 4 | Lua → OCaml       | OCaml hands a closure to Lua; Lua stores and later invokes it    |
| 5 | Lua → C           | pure Lua-side `ffi.cdef` + `ffi.C` call                          |
| 6 | C → Lua           | `ffi.cast` wraps a Lua function as a C function pointer; a C   library calls back into Lua via the pointer (e.g. `qsort`'s comparator) |

C ↔ OCaml as a separate direction doesn't exist in this pipeline:
at runtime everything that came from OCaml is already Lua, so "C →
OCaml" is the same mechanism as (6) — the Lua function that the C
library calls happens to dispatch into compiled-OCaml code.

### 4.1 — OCaml → C (the everyday path)

```ocaml
let bg = make_color 30 40 65 255
let () = clear_background bg
```

- `make_color` is a generated Lua function that builds the C-side
  `Color` cdata and wraps it as `{0, cdata}`.
- `clear_background` is a generated Lua function that unwraps
  `bg[2]` to the cdata and calls `C.ClearBackground(cdata)`.
- LuaJIT FFI moves the value into the C call's struct-by-value slot.

### 4.2 — OCaml → Lua (the prelude pattern)

When a function the OCaml side wants doesn't exist in the C library
— or needs hand-written shape-conversion — declare it as an OCaml
external pointing at a hand-written global Lua function:

```ocaml
external null_str : unit -> string = "null_str"
```

```lua
function null_str() return nil end
```

The Lua function is global, so the OCaml-compiled code finds it by
name. `examples/sdl-game/sdl_prelude.{lua,ml,stubs.c}` is the
canonical sample.

### 4.3 — Lua → OCaml (closure registration)

The OCaml side hands a closure to a Lua function; Lua stores it and
later invokes it:

```ocaml
external register_cb : (string -> string) -> unit = "register_cb"
external invoke_cb   : string -> string = "invoke_cb"

let () =
  register_cb (fun s -> "you said: " ^ s);
  let r = invoke_cb "hello" in
  print_endline r
```

```lua
local stored
function register_cb(f) stored = f end
function invoke_cb(s) return stored(s) end
```

This works because `lua_of_ocaml` compiles closures to Lua
functions with arity metadata (via `caml_mkclosure`), so a stored
closure is directly callable as `stored(s)`.

### 4.4 — Lua → C (direct FFI in a prelude)

Inside a hand-written prelude:

```lua
local ffi = require("ffi")
ffi.cdef [[ unsigned long strlen(const char *s); ]]
function lua_strlen(s) return tonumber(ffi.C.strlen(s)) * 2 end
```

Useful when you don't want to run luabindgen against a header but
do need one call. Common for libc functions that the generator
filters out for safety (alloca, malloc, strlen, …).

### 4.5 — C → Lua (function-pointer callback)

C libraries that take a function pointer can call back into Lua via
`ffi.cast`:

```lua
function run_c_callback_test()
  local comparator = ffi.cast(
    "int (*)(const void *, const void *)",
    function(a, b) ... end)
  ffi.C.qsort(arr, 5, ffi.sizeof("int"), comparator)
  comparator:free()
end
```

`qsort` then invokes the Lua function synchronously O(n log n)
times during the sort. Same mechanism would let raylib's
`SetTraceLogCallback` route trace events into your Lua/OCaml code,
or sqlite's busy-handler callbacks reach OCaml via Lua.

---

## Part V — Mechanics

### 5.1 — The pipeline in commands

```
header.h ──[luabingen]──→ <base>_external.ml + _stubs.c + _bindings.lua
                                                          ↓
main.ml ──[ocamlc]──→ main.cmo                            │
                                                          │
ocamlc -custom -o main.byte stubs.o external.cmo main.cmo │
                              ↓                           │
main.byte ──[loo.sh]──→ gen.lua                           │
                              ↓                           │
                       cat bindings.lua [prelude.lua] gen.lua > main.lua
                              ↓
                       luajit main.lua  ──→ ffi.load("foo") → libfoo.dylib
```

### 5.2 — Why the `.o` stubs exist

`ocamlc -custom` links a C runtime into the bytecode executable.
Every OCaml `external f : ... = "f"` requires a C symbol called `f`
to exist at link time. The `_stubs.c` file provides those symbols
(returning the right shape so the OCaml linker is happy), but they
never run: at runtime, lua_of_ocaml has replaced every primitive call
with a direct Lua call to the same-named function.

### 5.3 — Bytecode-magic compatibility

`loo` is built against a specific version of `js_of_ocaml-compiler`,
which embeds the OCaml bytecode magic it can parse (`Caml1999XNNN`).
Your `ocamlc` must produce matching bytecode.

```
strings extern/lua_of_ocaml/_build/default/compiler/bin-lua_of_ocaml/main.exe \
  | grep -E "Caml1999X[0-9]"
```

| magic     | OCaml series |
|---        |---           |
| X031      | 4.14         |
| X034      | 5.2          |
| X035      | 5.3          |
| X036      | 5.4          |

Activate the matching opam switch before `make`:

```
eval $(opam env --switch=<matching version> --set-switch)
```

### 5.4 — The `ocaml_val` helper

Every generated `_bindings.lua` opens with:

```lua
local function ocaml_val(v)
  if type(v) == "number" then return v / 2 end
  if type(v) == "table" and v[1] == 253 then return v[2] or 0 end
  return v
end
```

One helper, both int and float. Mirrors the
canonical pattern from `extern/lua_of_ocaml/example-game/love_runtime.lua`.

### 5.5 — Return-value re-tagging

The generator picks the conversion based on the **C** return type,
not the OCaml mapping. This matters: a `Shader` return type maps to
OCaml `int` (opaque struct token), but the actual Lua-side value is
a cdata. `* 2` on a cdata would crash. So the wrapper rule is:

| C return type           | wrapper does                       |
|---                      |---                                 |
| `int`/`char`/etc.       | `return (call) * 2`                |
| `bool`                  | `return (call) and 2 or 0`         |
| `float`/`double`        | `return { 253, call }`             |
| `char *` / `const char *`| `return ffi.string(call)`         |
| named struct            | `return { 0, call }`               |
| other pointer / opaque  | `return call`                      |
| `void`                  | `call; return`                     |

---

## Part VI — What the generator can't do, and how to glue around it

### 6.1 — NULL pointer arguments

`SDL_CreateRenderer(window, NULL)` needs a NULL `const char *`, but
the generated wrapper passes the OCaml string through unchanged. An
OCaml `""` is the empty string, not NULL. The fix lives in a prelude:

```lua
function null_str() return nil end
```

```ocaml
external null_str : unit -> string = "null_str"
let r = sdl_create_renderer win (null_str ())
```

### 6.2 — Caller-allocated output structs

`SDL_PollEvent(SDL_Event *event)` expects the caller to allocate an
`SDL_Event` and pass its address. The generator types the arg as
opaque int. Prelude:

```lua
function alloc_event() return ffi.new("SDL_Event") end
```

```ocaml
external alloc_event : unit -> sdl_event = "alloc_event"
external sdl_poll_event : sdl_event -> bool = "sdl_poll_event"   -- shadows
```

(Where `SDL_Event` is a union with unknown size to the generator,
substitute a same-sized stand-in struct — see
`examples/sdl-game/sdl_prelude.lua`.)

### 6.3 — Reading union fields / anonymous-union fields

`event.type` is a Uint32 field at the start of every SDL_Event
variant. The generator doesn't model unions; write the accessor by
hand:

```lua
function event_type(ev) return (ev.type) * 2 end
```

### 6.4 — Constructing structs with non-primitive fields from primitives

`SDL_FRect` is simple (`{float x, y, w, h;}`) so it could in
principle get a constructor. But the function that *takes* it
(`SDL_RenderFillRect`) expects `SDL_FRect *`, not by-value. Lua-
side helper:

```lua
function sdl_fill_rect(ren, x, y, w, h)
  local r = ffi.new("SDL_FRect", x, y, w, h)
  C.SDL_RenderFillRect(ren, r)
end
```

`examples/sdl-pong/sdl_prelude.lua` shows this pattern.

### 6.5 — Indexing C-side arrays returned as pointers

`SDL_GetKeyboardState` returns a `const Uint8 *` indexed by
scancode. The generator gives you an opaque int. To use it:

```lua
local kb_state
function sdl_init_kb_state() kb_state = C.SDL_GetKeyboardState(nil) end
function sdl_is_key_pressed(scancode)
  return (kb_state[scancode] ~= 0) and 2 or 0
end
```

### 6.6 — OCaml callbacks called from C

There's no automatic OCaml-fn → C-fn-ptr bridge. If a C library
wants a callback, the user must wrap a Lua function via
`ffi.cast` in a prelude and pass the resulting opaque pointer
through the OCaml side. Example pattern in §4.5.

### 6.7 — `Random`, OS-state stdlib modules

lua_of_ocaml's vendored runtime doesn't reliably wire up all of
OCaml's stdlib. `Random.self_init` failed for the pong demo. Use
hand-rolled alternatives where it bites; nothing about the binding
generator can fix this.

### 6.8 — Platform-conditional headers

The preprocessor strips all `#`-lines, including the conditionals
that gate platform-specific code. SDL3's `__debugbreak` (MSVC
intrinsic in an `#ifdef _MSC_VER` block) leaks through. Workarounds:

- pass `--strip TOK,TOK` for keywords like `__cdecl`, `__attribute__`,
  attribute macros, etc.
- prune the input to a curated subset of headers (the `sdl-game`
  example skips the OpenGL/EGL/Vulkan/Metal headers that pull in
  `HDC`, `HWND`, …)
- live with the `warn:` lines the parser prints when it gives up on
  a declaration — they tell you exactly which line was the trouble.

### 6.9 — When the prelude pattern is the right answer

The three prelude files (`prelude.lua`, `prelude.ml`, `prelude_stubs.c`)
are about 30 lines of code total and let you fill in anything the
generator can't synthesize. The `sdl-game` and `sdl-pong` examples
both use it. The rule of thumb: if the C library exposes an idiom
the generator doesn't understand (NULL args, output structs, union
fields, callback registration), wrap it in a prelude function and
declare a matching OCaml external. Don't fight the generator —
extend it with hand-written glue at the seams.

---

## Appendix — Examples in the tree

| folder                          | what it shows |
|---                              |---            |
| `examples/raylib-platformer/`   | full game (gravity, jump, AABB collision); exercises struct constructors, scalar field accessors, every primitive return type, enum constants. |
| `examples/sdl-game/`            | minimal SDL3 demo — open window, animate clear color, exit on close. The first prelude example (NULL strings, event allocation, union field access). |
| `examples/sdl-pong/`            | two-player Pong; adds keyboard-state polling and filled-rect drawing on top of the sdl-game prelude. |
| `examples/call-directions/`     | runnable assertion of all six cross-language calling directions. `make check` exits non-zero on any failure. |
| `tests/run.sh`                  | 46 fixture tests on the generator's output; `make test` from the repo root. |
