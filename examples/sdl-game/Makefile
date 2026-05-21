## examples/sdl-game — drives SDL3 via luabindgen + lua_of_ocaml + luajit
##
## Requires OCaml 5.4.x (Caml1999X036 bytecode magic to match the
## bundled loo binary), luajit, and SDL3 (brew install sdl3).
##
## SDL3 is split across many headers; SDL.h itself is just #include's.
## The Makefile concatenates the per-subsystem headers into one file
## then runs luabingen against that. The --strip flag drops SDL's
## attribute macros (SDL_DECLSPEC, SDLCALL, ...) so the parser sees a
## plain `<ret> SDL_Foo(args)` shape.

THIS_DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LUABINGEN := $(abspath $(THIS_DIR)/../../luabingen.ml)
LUO       := $(abspath $(THIS_DIR)/../../extern/lua_of_ocaml)
SDL_INC   ?= $(abspath $(THIS_DIR)/../../extern/SDL-release-3.4.8/include)

OCAMLC ?= ocamlc
LUAJIT ?= luajit

STRIP_TOKENS = SDL_DECLSPEC,SDLCALL,SDL_FORCE_INLINE,SDL_INLINE,SDL_NORETURN,_Nullable,_Nonnull,__cdecl,__stdcall,__attribute__

GENERATED = sdl3_merged_external.ml sdl3_merged_stubs.c sdl3_merged_bindings.lua
OBJS      = sdl3_merged_stubs.o sdl3_merged_external.cmo main.cmo

.PHONY: all run clean
all: main.lua

# 0. Merge SDL3's per-subsystem headers into one file. SDL.h itself is
#    just #include's, which the preprocessor strips.
## Curated subset of SDL3 headers — the minimum needed for an
## init/window/render/event-poll demo. Full SDL3 has too many
## platform-conditional macros and corner cases (nested anonymous
## unions, MSVC intrinsics in `#ifdef _MSC_VER` blocks, OpenGL/EGL/
## Vulkan/Metal pulling in HDC/HWND, ...) for our minimal preprocessor
## to handle cleanly. Extend SDL_HEADERS as needed.
##
## SDL_stdinc.h MUST be first — Uint8/16/32/64/bool typedefs are
## referenced everywhere.
SDL_HEADERS = \
  $(SDL_INC)/SDL3/SDL_stdinc.h     \
  $(SDL_INC)/SDL3/SDL_error.h      \
  $(SDL_INC)/SDL3/SDL_properties.h \
  $(SDL_INC)/SDL3/SDL_init.h       \
  $(SDL_INC)/SDL3/SDL_timer.h      \
  $(SDL_INC)/SDL3/SDL_pixels.h     \
  $(SDL_INC)/SDL3/SDL_rect.h       \
  $(SDL_INC)/SDL3/SDL_blendmode.h  \
  $(SDL_INC)/SDL3/SDL_iostream.h   \
  $(SDL_INC)/SDL3/SDL_surface.h    \
  $(SDL_INC)/SDL3/SDL_video.h      \
  $(SDL_INC)/SDL3/SDL_keycode.h    \
  $(SDL_INC)/SDL3/SDL_scancode.h   \
  $(SDL_INC)/SDL3/SDL_keyboard.h   \
  $(SDL_INC)/SDL3/SDL_mouse.h      \
  $(SDL_INC)/SDL3/SDL_pen.h        \
  $(SDL_INC)/SDL3/SDL_power.h      \
  $(SDL_INC)/SDL3/SDL_sensor.h     \
  $(SDL_INC)/SDL3/SDL_guid.h       \
  $(SDL_INC)/SDL3/SDL_joystick.h   \
  $(SDL_INC)/SDL3/SDL_gamepad.h    \
  $(SDL_INC)/SDL3/SDL_touch.h      \
  $(SDL_INC)/SDL3/SDL_audio.h      \
  $(SDL_INC)/SDL3/SDL_camera.h     \
  $(SDL_INC)/SDL3/SDL_events.h     \
  $(SDL_INC)/SDL3/SDL_gpu.h        \
  $(SDL_INC)/SDL3/SDL_render.h

sdl3_merged.h: $(SDL_HEADERS)
	cat $(SDL_HEADERS) > sdl3_merged.h

# 1. Generate bindings.
$(GENERATED) &: $(LUABINGEN) sdl3_merged.h
	ocaml -I +str str.cma $(LUABINGEN) \
	  --strip "$(STRIP_TOKENS)" --lib SDL3 --out-dir . sdl3_merged.h

# 2. Compile.
sdl3_merged_stubs.o: sdl3_merged_stubs.c
	$(OCAMLC) -c sdl3_merged_stubs.c

sdl3_merged_external.cmo: sdl3_merged_external.ml
	$(OCAMLC) -c sdl3_merged_external.ml

main.cmo: main.ml sdl3_merged_external.cmo
	$(OCAMLC) -c main.ml

main.byte: $(OBJS)
	$(OCAMLC) -custom -o main.byte $(OBJS)

# 3. Bytecode -> Lua.
gen.lua: main.byte
	LOO_RUNTIME=$(LUO)/runtime/lua $(LUO)/loo.sh main.byte -o gen.lua

main.lua: sdl3_merged_bindings.lua gen.lua
	cat sdl3_merged_bindings.lua gen.lua > main.lua

run: main.lua
	$(LUAJIT) main.lua

clean:
	rm -f sdl3_merged.h $(GENERATED) $(OBJS) \
	      sdl3_merged_external.cmi main.cmi \
	      main.byte gen.lua main.lua
