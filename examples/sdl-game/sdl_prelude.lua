-- Hand-written helpers that luabindgen can't generate yet.
-- Matches the lua_of_ocaml example-game/love_runtime.lua pattern:
-- per-binding "glue" code that fills the gaps the generic emitter
-- doesn't cover.

local ffi = require("ffi")

-- NULL pointer passed where a string is expected (e.g.
-- SDL_CreateRenderer(window, NULL) for the default driver).
function null_str() return nil end

-- luabindgen treats SDL_Event (a union) as an opaque forward-declared
-- struct, so its size isn't known to LuaJIT and `ffi.new("SDL_Event")`
-- fails. Declare a same-size stand-in struct here: the first 4 bytes
-- are the event type (matches the type tag in every SDL_Event variant);
-- the remaining 124 bytes pad to SDL_Event's documented 128-byte size.
-- The Lua side passes a cast pointer to the SDL_Event * APIs.
ffi.cdef([[
typedef struct {
  uint32_t type;
  uint8_t  pad[124];
} LB_SDL_Event;
]])

function alloc_event()
  return ffi.new("LB_SDL_Event")
end

function event_type(ev)
  return (ev.type) * 2
end

-- Override the generator's sdl_poll_event so the LB_SDL_Event pointer
-- gets cast to SDL_Event * for the FFI call.
local C = ffi.load("SDL3")
function sdl_poll_event(ev)
  return (C.SDL_PollEvent(ffi.cast("SDL_Event *", ev))) and 2 or 0
end
