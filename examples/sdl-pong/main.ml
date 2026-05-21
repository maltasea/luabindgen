(* Two-player Pong via luabindgen + lua_of_ocaml + luajit + SDL3.
   Left paddle: W / S.   Right paddle: ↑ / ↓.   Esc or close to quit. *)

open Sdl3_merged_external
open Sdl_prelude

let win_w   = 600
let win_h   = 400
let paddle_w = 12.0
let paddle_h = 80.0
let paddle_speed = 5.0
let ball_size = 10.0

type paddle = { mutable y : float }
type ball   = { mutable x  : float; mutable y  : float;
                mutable vx : float; mutable vy : float }

let left   = { y = 160.0 }
let right_ = { y = 160.0 }
let ball   = { x = 295.0; y = 195.0; vx = 4.0; vy = 3.0 }
let score_l = ref 0
let score_r = ref 0

(* Small deterministic PRNG — lua_of_ocaml's Random module isn't
   reliably wired up; this side-steps it. *)
let seed = ref 7
let rand_bool () =
  seed := !seed * 1103515245 + 12345;
  (!seed lsr 16) land 1 = 0

let reset_ball ~towards_left =
  ball.x <- 295.0;
  ball.y <- 195.0;
  ball.vx <- (if towards_left then -. 4.0 else 4.0);
  ball.vy <- (if rand_bool () then -. 3.0 else 3.0)

let clamp_paddle y = max 30.0 (min (float_of_int win_h -. paddle_h) y)

let update () =
  if sdl_is_key_pressed sdl_scancode_w then
    left.y <- clamp_paddle (left.y -. paddle_speed);
  if sdl_is_key_pressed sdl_scancode_s then
    left.y <- clamp_paddle (left.y +. paddle_speed);
  if sdl_is_key_pressed sdl_scancode_up then
    right_.y <- clamp_paddle (right_.y -. paddle_speed);
  if sdl_is_key_pressed sdl_scancode_down then
    right_.y <- clamp_paddle (right_.y +. paddle_speed);

  ball.x <- ball.x +. ball.vx;
  ball.y <- ball.y +. ball.vy;

  if ball.y < 30.0 then (ball.y <- 30.0; ball.vy <- -. ball.vy);
  if ball.y +. ball_size > float_of_int win_h then
    (ball.y <- float_of_int win_h -. ball_size; ball.vy <- -. ball.vy);

  (* paddle collisions: left at x=20, right at x=win_w-32 *)
  let bx, by = ball.x, ball.y in
  if bx < 20.0 +. paddle_w && bx +. ball_size > 20.0
     && by +. ball_size > left.y && by < left.y +. paddle_h
     && ball.vx < 0.0
  then ball.vx <- -. ball.vx *. 1.05;

  let rx = float_of_int win_w -. 20.0 -. paddle_w in
  if bx +. ball_size > rx && bx < rx +. paddle_w
     && by +. ball_size > right_.y && by < right_.y +. paddle_h
     && ball.vx > 0.0
  then ball.vx <- -. ball.vx *. 1.05;

  if ball.x +. ball_size < 0.0 then
    (incr score_r; reset_ball ~towards_left:false);
  if ball.x > float_of_int win_w then
    (incr score_l; reset_ball ~towards_left:true)

let draw ren =
  (* background *)
  ignore (sdl_set_render_draw_color ren 18 22 36 255);
  ignore (sdl_render_clear ren);

  (* HUD bar + center net *)
  ignore (sdl_set_render_draw_color ren 50 60 90 255);
  sdl_fill_rect ren 0.0 0.0 (float_of_int win_w) 26.0;
  let mid = float_of_int (win_w / 2) -. 1.0 in
  let rec dotted y =
    if y < float_of_int win_h then begin
      sdl_fill_rect ren mid y 2.0 8.0;
      dotted (y +. 16.0)
    end
  in
  dotted 32.0;

  (* paddles *)
  ignore (sdl_set_render_draw_color ren 230 230 240 255);
  sdl_fill_rect ren 20.0 left.y   paddle_w paddle_h;
  sdl_fill_rect ren (float_of_int win_w -. 20.0 -. paddle_w) right_.y
                paddle_w paddle_h;

  (* ball *)
  ignore (sdl_set_render_draw_color ren 250 200 90 255);
  sdl_fill_rect ren ball.x ball.y ball_size ball_size;

  (* score *)
  ignore (sdl_set_render_draw_color ren 230 230 240 255);
  ignore (sdl_render_debug_text ren 12.0 8.0
            (Printf.sprintf "P1: %d" !score_l));
  ignore (sdl_render_debug_text ren (float_of_int win_w -. 60.0) 8.0
            (Printf.sprintf "P2: %d" !score_r));
  ignore (sdl_render_debug_text ren
            (float_of_int (win_w / 2) -. 60.0) 8.0
            "W/S    arrows");

  ignore (sdl_render_present ren)

let () =
  if not (sdl_init sdl_init_video) then exit 1;
  let win = sdl_create_window "luabindgen pong" win_w win_h 0 in
  let ren = sdl_create_renderer win (null_str ()) in
  sdl_init_kb_state ();

  let event = alloc_event () in
  let running = ref true in
  while !running do
    sdl_pump_events ();
    while sdl_poll_event event do
      let t = event_type event in
      if t = sdl_event_quit then running := false
    done;
    if sdl_is_key_pressed sdl_scancode_escape then running := false;
    update ();
    draw ren;
    sdl_delay 16
  done;

  sdl_destroy_renderer ren;
  sdl_destroy_window win;
  sdl_quit ()
