(* SDL3 demo: open a window, attach a renderer, animate a clear color,
   quit on the close-window event. *)

open Sdl3_merged_external
open Sdl_prelude

let win_w = 600
let win_h = 400

let () =
  if not (sdl_init sdl_init_video) then exit 1;

  let win = sdl_create_window "luabingen sdl" win_w win_h 0 in
  (* NULL driver name lets SDL pick a default backend. *)
  let ren = sdl_create_renderer win (null_str ()) in

  let event = alloc_event () in
  let frame = ref 0 in
  let running = ref true in
  while !running do
    while sdl_poll_event event do
      if event_type event = sdl_event_quit then running := false
    done;

    (* Slowly shift the clear color so you can see the loop is alive. *)
    let r = (!frame / 2)        mod 256 in
    let g = (!frame / 3 + 80)   mod 256 in
    let b = (!frame / 5 + 160)  mod 256 in
    ignore (sdl_set_render_draw_color ren r g b 255);
    ignore (sdl_render_clear ren);
    ignore (sdl_render_present ren);

    incr frame;
    sdl_delay 16
  done;

  sdl_destroy_renderer ren;
  sdl_destroy_window win;
  sdl_quit ()
