# sdl-game

End-to-end demo: OCaml → bytecode → lua_of_ocaml → luajit → libSDL3.

Opens an SDL3 window, holds it for 2 seconds, exits. Proves luabindgen
can drive a second well-known C library beyond raylib.

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
| `main.ml`  | the demo |
| `Makefile` | pipeline + curated header list |
| `README.md` | this file |

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

## what's not here

This is "open a window, hold it, exit." A real game using these
bindings would need:

- **NULL pointer passing** — `SDL_CreateRenderer(window, NULL)`
  for the default renderer. No clean way to express NULL through
  our `string` argument convention yet.
- **Output-parameter struct allocation** — `SDL_PollEvent(SDL_Event
  *event)` writes an event to caller-allocated storage. No way to
  allocate an SDL_Event on the OCaml side and read its fields back
  after the call.
- **Struct field accessors for `unions`** — anonymous unions in
  events would need bespoke modeling.

These are real gaps; the platformer doesn't hit them because raylib
returns Vector2/Color by value and uses no callbacks.
