(* Minimal SDL3 demo via the luabindgen + lua_of_ocaml pipeline.
   Opens a 600x400 window, holds it for ~2 seconds, exits. *)

open Sdl3_merged_external

let () =
  if not (sdl_init sdl_init_video) then exit 1;
  let w = sdl_create_window "luabingen sdl" 600 400 0 in
  sdl_delay 2000;
  sdl_destroy_window w;
  sdl_quit ()
