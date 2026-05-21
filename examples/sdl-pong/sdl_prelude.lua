-- Per-example glue for the pong demo. Extends the helpers from
-- examples/sdl-game/sdl_prelude.lua with a few more shapes pong
-- needs that the generator can't auto-emit: SDL_FRect allocation,
-- keyboard-state polling.

local ffi = require("ffi")

-- (1) NULL where a string is expected
function null_str() return nil end

-- (2) SDL_Event stand-in (same as sdl-game)
ffi.cdef [[
typedef struct {
  uint32_t type;
  uint8_t  pad[124];
} LB_SDL_Event;
]]

function alloc_event()  return ffi.new("LB_SDL_Event") end
function event_type(ev) return (ev.type) * 2 end

local C = ffi.load("SDL3")

function sdl_poll_event(ev)
  return (C.SDL_PollEvent(ffi.cast("SDL_Event *", ev))) and 2 or 0
end

-- (3) draw a filled rectangle. luabindgen exposes SDL_RenderFillRect
-- as taking an opaque int (the SDL_FRect pointer) — useless from
-- OCaml. This wrapper builds an SDL_FRect on the spot.
function sdl_fill_rect(ren, x, y, w, h)
  local r = ffi.new("SDL_FRect", x, y, w, h)
  C.SDL_RenderFillRect(ren, r)
end

-- (4) keyboard state — SDL_GetKeyboardState returns a pointer to
-- an internal Uint8 array indexed by SDL scancode. Cache it once
-- (the pointer never changes), then read individual scancodes.
local kb_state
function sdl_init_kb_state()
  kb_state = C.SDL_GetKeyboardState(nil)
end

function sdl_is_key_pressed(scancode)
  if kb_state == nil then return 0 end
  return (kb_state[scancode] ~= 0) and 2 or 0
end
