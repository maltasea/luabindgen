# sdl-pong

Two-player Pong via luabindgen → lua_of_ocaml → luajit → libSDL3.
A real (if minimal) game on top of the binding pipeline.

```
        P1: 3                  W/S    arrows                  P2: 2
        ────────────────────────────────────────────────────────────
         │
         │
         │                              ║
         │                              ║      ●
         │                              ║
         │                                              │
         │                                              │
         │                                              │
```

## controls

- left paddle: `W` / `S`
- right paddle: `↑` / `↓`
- quit: `Esc` or close window

## requires

Same toolchain as the other SDL example: an OCaml whose bytecode magic
matches `loo`'s (`strings extern/lua_of_ocaml/.../main.exe | grep
Caml1999X`), `luajit` in PATH, and `brew install sdl3`. See the
top-level README's "bytecode-magic gotcha".

## run

```
make run
```

## what this exercises beyond `sdl-game`

`sdl-game` opens a window and animates a clear color. `sdl-pong` adds:

- **Keyboard state polling** via `SDL_GetKeyboardState` + scancode
  constants (`sdl_scancode_w`, `sdl_scancode_up`, …). A new prelude
  helper caches the keyboard-state pointer (returned as opaque from
  the generator) and exposes `sdl_is_key_pressed scancode -> bool`.
- **Filled rectangle drawing** via `SDL_RenderFillRect`. The
  generator types the `SDL_FRect *` arg as opaque int, useless from
  OCaml; the prelude wraps it as `sdl_fill_rect ren x y w h` and
  builds the FRect inside.
- **Text rendering** via `SDL_RenderDebugText` — no font asset
  needed, takes string + float coordinates.
- **A real game loop**: pump events, poll keyboard, update physics,
  draw, present, delay. ~120 lines of OCaml.

`lua_of_ocaml`'s `Random` module isn't reliably wired up in the
vendored runtime, so the demo uses a hand-written linear-congruential
PRNG for ball-direction randomness. Deterministic per session.

## files

| file                  | role |
|---                    |---   |
| `main.ml`             | game logic |
| `sdl_prelude.lua`     | extends sdl-game's glue with `sdl_fill_rect` + keyboard-state helpers |
| `sdl_prelude.ml`      | OCaml externals matching the prelude |
| `sdl_prelude_stubs.c` | linker placeholders |
| `Makefile`            | same shape as sdl-game's |
