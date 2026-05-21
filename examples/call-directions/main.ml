(* Each of the six directions across the OCaml / Lua / C boundary.
   See README.md for the architecture diagram. *)

open Prelude

let banner s = Printf.printf "\n=== %s ===\n" s

let () =

  banner "(1) OCaml -> C";
  Printf.printf "    c_strlen \"hello, world!\" = %d\n"
    (c_strlen "hello, world!");

  banner "(2) OCaml -> Lua";
  Printf.printf "    lua_uppercase \"abc def\" = %s\n"
    (lua_uppercase "abc def");

  banner "(3) OCaml -> Lua -> C (chained)";
  Printf.printf "    lua_then_c_strlen \"chained call\" = %d\n"
    (lua_then_c_strlen "chained call");

  banner "(4) Lua -> OCaml";
  let reverse_words s =
    String.split_on_char ' ' s
    |> List.rev
    |> String.concat " "
  in
  register_ocaml_callback reverse_words;
  invoke_ocaml_from_lua "hello world from ocaml";

  banner "(5) Lua -> C  (no OCaml in the chain)";
  run_pure_lua_to_c_test ();

  banner "(6) C -> Lua  (qsort calls a Lua comparator)";
  run_c_callback_test ();

  print_endline "\ndone."
