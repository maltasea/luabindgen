(* OCaml-side declarations for the cross-language glue. Each external
   names a function defined in prelude.lua; lua_of_ocaml turns the
   external call into a direct Lua call by that name. *)

external c_strlen          : string -> int    = "c_strlen"
external lua_uppercase     : string -> string = "lua_uppercase"
external lua_then_c_strlen : string -> int    = "lua_then_c_strlen"

external register_ocaml_callback
  : (string -> string) -> unit
  = "register_ocaml_callback"
(* Returns whatever the registered OCaml callback returned, so the
   test side can assert on it. *)
external invoke_ocaml_from_lua : string -> string = "invoke_ocaml_from_lua"

(* Both return ints so main.ml can assert on the value. *)
external run_pure_lua_to_c_test : unit -> int = "run_pure_lua_to_c_test"
external run_c_callback_test    : unit -> int = "run_c_callback_test"
