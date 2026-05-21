-- Hand-written Lua glue for the call-directions test/sim. Each
-- function exposes one cross-language calling pattern; main.ml asserts
-- on the returned value to confirm the call actually happened.

local ffi = require("ffi")

ffi.cdef [[
  unsigned long strlen(const char *s);
  void qsort(void *base, unsigned long nmemb, unsigned long size,
             int (*compar)(const void *, const void *));
]]

----------------------------------------------------------------------
-- (1) OCaml -> C: OCaml external "c_strlen" -> here -> ffi.C.strlen.
-- Returns an OCaml-encoded int (n * 2).
----------------------------------------------------------------------
function c_strlen(s)
  return tonumber(ffi.C.strlen(s)) * 2
end

----------------------------------------------------------------------
-- (2) OCaml -> Lua: pure Lua function, no C.
----------------------------------------------------------------------
function lua_uppercase(s)
  return string.upper(s)
end

----------------------------------------------------------------------
-- (3) OCaml -> Lua -> C chained: same body as (1), different name
-- so the test can label the directions separately.
----------------------------------------------------------------------
function lua_then_c_strlen(s)
  return tonumber(ffi.C.strlen(s)) * 2
end

----------------------------------------------------------------------
-- (4) Lua -> OCaml: OCaml stashes a closure here; Lua later invokes
-- it and returns the result. lua_of_ocaml compiles OCaml closures
-- to Lua functions, so a stored closure is directly callable.
----------------------------------------------------------------------
local ocaml_cb

function register_ocaml_callback(f)
  ocaml_cb = f
end

function invoke_ocaml_from_lua(s)
  print("   [Lua] invoking OCaml callback with " .. ('%q'):format(s))
  local result = ocaml_cb(s)
  print("   [Lua] OCaml returned " .. ('%q'):format(result))
  return result
end

----------------------------------------------------------------------
-- (5) Lua -> C: pure Lua -> ffi.C, no OCaml in the chain at all.
-- Returns the strlen as an OCaml-encoded int so main.ml can assert.
----------------------------------------------------------------------
function run_pure_lua_to_c_test()
  local n = tonumber(ffi.C.strlen("hello from lua"))
  print("   [Lua] ffi.C.strlen('hello from lua') = " .. n)
  return n * 2
end

----------------------------------------------------------------------
-- (6) C -> Lua callback. qsort takes a function pointer; we hand
-- it a Lua function via ffi.cast. The C library then calls back
-- into Lua O(n log n) times. Returns the call count (OCaml-encoded)
-- so main.ml can assert C actually invoked our Lua function.
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
  return call_count * 2
end
