(* Test/simulate each cross-language call direction across the
   OCaml / Lua / C boundary in our pipeline. Each direction does a
   call, compares the result to an expected value, and prints PASS
   or FAIL. Exits 0 iff every direction passes — so this doubles as
   a runnable regression test, not just a demo. *)

open Prelude

let pass = ref 0
let fail = ref 0

let check label cond detail =
  if cond then begin
    incr pass;
    Printf.printf "  PASS  %-32s %s\n" label detail
  end else begin
    incr fail;
    Printf.printf "  FAIL  %-32s %s\n" label detail
  end

let banner s = Printf.printf "\n=== %s ===\n" s

let () =

  banner "(1) OCaml -> C";
  let n = c_strlen "hello, world!" in
  check "c_strlen returns 13" (n = 13)
    (Printf.sprintf "got %d" n);

  banner "(2) OCaml -> Lua";
  let s = lua_uppercase "abc def" in
  check "lua_uppercase returns 'ABC DEF'" (s = "ABC DEF")
    (Printf.sprintf "got %S" s);

  banner "(3) OCaml -> Lua -> C (chained)";
  let n = lua_then_c_strlen "chained call" in
  check "chained returns 12" (n = 12)
    (Printf.sprintf "got %d" n);

  banner "(4) Lua -> OCaml";
  let reverse_words s =
    String.split_on_char ' ' s
    |> List.rev
    |> String.concat " "
  in
  register_ocaml_callback reverse_words;
  let r = invoke_ocaml_from_lua "hello world from ocaml" in
  check "lua got reverse_words result"
    (r = "ocaml from world hello")
    (Printf.sprintf "got %S" r);

  banner "(5) Lua -> C  (no OCaml in the chain)";
  let n = run_pure_lua_to_c_test () in
  check "lua's strlen('hello from lua') = 14" (n = 14)
    (Printf.sprintf "got %d" n);

  banner "(6) C -> Lua  (qsort calls a Lua comparator)";
  let calls = run_c_callback_test () in
  check "qsort called comparator at least 4 times"
    (calls >= 4)
    (Printf.sprintf "comparator was called %d times" calls);

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
