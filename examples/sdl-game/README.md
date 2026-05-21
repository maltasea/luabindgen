# sdl-game

End-to-end demo: OCaml → bytecode → lua_of_ocaml → luajit → libSDL3.

Opens an SDL3 window, attaches a renderer, animates a clear color, exits
when you close the window. Proves luabindgen can drive a second
well-known C library beyond raylib.

## requires

- **OCaml 5.4.x** — same bytecode-magic requirement as the other
  examples. On this machine: `eval $(opam env --switch=/Users/ben --set-switch)`.
- **luajit** in PATH.
- **SDL3** — `brew install sdl3`. The dylib must be discoverable by
  `ffi.load("SDL3")` (brew puts it where macOS dyld looks).

## run

```
make run
```

`make clean && make run` does the whole pipeline from scratch.

## what's here

| file | role |
|---|---|
| `main.ml`             | the demo |
| `Makefile`            | pipeline + curated header list |
| `sdl_prelude.lua`     | hand-written glue (NULL string, event alloc, event.type) |
| `sdl_prelude.ml`      | OCaml externals matching `sdl_prelude.lua` |
| `sdl_prelude_stubs.c` | linker placeholders for the prelude externals |
| `README.md`           | this file |

## the per-example prelude

luabindgen can't yet auto-generate three things SDL3 needs for a real
interactive demo:

1. **NULL pointer args** — `SDL_CreateRenderer(window, NULL)` for the
   default driver. We can't pass nil through OCaml's `string` type.
2. **Caller-allocated structs** — `SDL_PollEvent(SDL_Event *event)`
   writes to a struct the caller provides. luabindgen has no
   `alloc_X` constructor for opaque-by-API types.
3. **Reading union fields** — `event.type` lives in a union we
   skipped at parse time.

`sdl_prelude.{lua,ml,stubs.c}` is hand-written glue for those gaps —
the same pattern lua_of_ocaml uses in
`extern/lua_of_ocaml/example-game/love_runtime.lua`. About 30 lines
total. The Makefile cats the prelude lua after the generated
bindings and links the prelude `.cmo` / `.o` alongside the generated
ones. `sdl_prelude.ml` `open`s the generated module so its shadowing
`sdl_poll_event : sdl_event -> bool` wins over the generator's
`int -> bool`.

## SDL3 quirks that surfaced

Building this example exercised parts of the C parser that raylib
didn't touch:

- **`SDL_DECLSPEC`, `SDLCALL` attribute macros** — SDL3 functions are
  `extern SDL_DECLSPEC <ret> SDLCALL <name>(args);`. Stripped via
  `--strip "SDL_DECLSPEC,SDLCALL,..."`.
- **`#define` constants for init flags** — `SDL_INIT_VIDEO = 0x20`
  is a C `#define`, not an enum constant. luabindgen now extracts
  simple `#define NAME <int-lit>` lines and emits OCaml `let`s for
  them, alongside the enum constants.
- **Header concatenation produces duplicates** — SDL.h is just
  `#include`s; we concat per-subsystem headers, and overlapping
  declarations (e.g. SDL_egl.h and SDL_opengl.h sharing GL fn decls)
  appear twice. luabindgen now dedups fn/struct/enum entries.
- **Libc-conflicting names** — SDL_stdinc.h declares `strlcat`,
  `alloca`, etc. for portability inside `#if`s that we can't evaluate.
  Their generated stubs would clash with libc / clang builtins at
  link time. luabindgen filters a built-in list of these names.
- **Static inline function bodies** — `SDL_FORCE_INLINE int foo(x) {
  ... }` would leak the body's `return` statement into the next
  declaration if not handled. luabindgen detects `{` after the param
  list and skips the body.
- **Anonymous unions/structs in struct fields** — SDL_GamepadBinding
  has nested `union { int button; struct { ... } axis; ... } input;`.
  We skip these as opaque (the parent struct's alignment is wrong
  without proper modeling, but the cdef accepts the parent).
- **Forward references across headers** — SDL_GPUColorTargetInfo
  contains an SDL_FColor by value; the structs come from different
  files in different concat order. luabindgen now topologically sorts
  struct definitions by by-value dependency.
- **Header curation** — the OpenGL/EGL/Vulkan/Metal headers pull in
  platform-specific types (HDC, HWND) inside `#ifdef _WIN32` blocks
  we can't evaluate. Same for MSVC `__debugbreak` in SDL_assert.h.
  The Makefile uses a curated header list rather than `*.h`.

## what's still rough

The prelude covers the three immediate gaps for this demo, but the
underlying generator limits remain:

- **NULL pointer passing** — should be expressible without a
  per-binding helper. An OCaml `option`-typed wrapper in the
  generator (`string option` instead of `string`) would do it
  cleanly.
- **Output-parameter struct allocation** — the prelude allocates an
  `LB_SDL_Event` stand-in because we don't know `SDL_Event`'s real
  size. A real `--with-unions` pass that models C unions would
  remove the need.
- **Anonymous-union field access** — `event.key.scancode` etc.
  can't be reached. The variant types (`SDL_KeyboardEvent`,
  `SDL_MouseButtonEvent`, …) are parsed but the anonymous-union
  field that holds them is skipped.

These are real gaps; the platformer doesn't hit them because raylib
returns Vector2/Color by value, uses no caller-allocated output
structs, and has no union types in its hot path.
