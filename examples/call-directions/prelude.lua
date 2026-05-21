-- Hand-written Lua glue for the call-directions demo.
-- All cross-language calls at runtime are dispatched through Lua:
-- lua_of_ocaml compiles OCaml bytecode to Lua, LuaJIT runs it, and
-- the FFI is the only way to reach C. The functions below are the
-- meeting points.

local ffi = require("ffi")

ffi.cdef [[
  unsigned long strlen(const char *s);
  void qsort(void *base, unsigned long nmemb, unsigned long size,
             int (*compar)(const void *, const void *));
]]

----------------------------------------------------------------------
-- (1) the bridge OCaml uses to reach libc's strlen.
--
-- OCaml external "c_strlen" -> here -> ffi.C.strlen -> libc.
-- Returns are OCaml-encoded ints (n * 2).
----------------------------------------------------------------------
function c_strlen(s)
  return tonumber(ffi.C.strlen(s)) * 2
end

----------------------------------------------------------------------
-- (2) a pure Lua function OCaml calls directly.
--
-- OCaml external "lua_uppercase" -> here. No C, no luabindgen-
-- generated wrapper — this is the same pattern as sdl_prelude.lua.
----------------------------------------------------------------------
function lua_uppercase(s)
  return string.upper(s)
end

----------------------------------------------------------------------
-- (3) chained OCaml -> Lua -> C. Same body as (1) but called via a
-- different name so the demo can label the directions separately.
----------------------------------------------------------------------
function lua_then_c_strlen(s)
  return tonumber(ffi.C.strlen(s)) * 2
end

----------------------------------------------------------------------
-- (4) Lua -> OCaml. The OCaml side registers a function here; the
-- Lua side later invokes it. lua_of_ocaml compiles OCaml closures to
-- Lua functions with arity metadata, so a stored closure is directly
-- callable.
----------------------------------------------------------------------
local ocaml_cb

function register_ocaml_callback(f)
  ocaml_cb = f
end

function invoke_ocaml_from_lua(s)
  print("   [Lua] invoking OCaml callback with " .. ('%q'):format(s))
  local result = ocaml_cb(s)
  print("   [Lua] OCaml returned " .. ('%q'):format(result))
end

----------------------------------------------------------------------
-- (5) pure Lua -> C. No OCaml in the chain at all — just to make
-- the contrast with (3) explicit. Triggered by OCaml only because
-- something has to start the program.
----------------------------------------------------------------------
function run_pure_lua_to_c_test()
  local n = tonumber(ffi.C.strlen("hello from lua"))
  print("   [Lua] ffi.C.strlen('hello from lua') = " .. n)
end

----------------------------------------------------------------------
-- (6) C -> Lua. qsort is a C library function that takes a function
-- pointer; we hand it one by wrapping a Lua function via ffi.cast.
-- The C library then calls back into Lua O(n log n) times during
-- the sort.
----------------------------------------------------------------------
function run_c_callback_test()
  local arr = ffi.new("int[5]", { 5, 2, 8, 1, 4 })
  local call_count = 0
  local comparator = ffi.cast(
    "int (*)(const void *, const void *)",
    function(a, b)
      call_count = call_count + 1
      local ia = ffi.cast("const int *", a)[0]
      local ib = ffi.cast("const int *", b)[0]
      if ia < ib then return -1
      elseif ia > ib then return 1
      else return 0 end
    end)
  ffi.C.qsort(arr, 5, ffi.sizeof("int"), comparator)
  local sorted = {}
  for i = 0, 4 do sorted[i + 1] = arr[i] end
  print("   [Lua] sorted result: " .. table.concat(sorted, ", "))
  print("   [Lua] C qsort called our Lua comparator " .. call_count .. " times")
  comparator:free()
end
