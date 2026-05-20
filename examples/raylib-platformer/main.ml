(* Tiny platformer — proof that the luabindgen + lua_of_ocaml pipeline
   can drive raylib. Arrow keys move, space jumps. *)

open Raylib_external

let win_w = 600
let win_h = 400

let ground_y = 350
let gravity = 1
let jump_vy = -14
let move_speed = 4

let () = init_window win_w win_h "platformer"
let () = set_target_fps 60

(* --- palette --- *)
let sky_top    = make_color  30  40  80 255
let sky_bot    = make_color 120 160 200 255
let sun_col    = make_color 255 220 130 255
let cloud_col  = make_color 245 245 250 230
let mtn_far    = make_color  70  90 130 255
let mtn_near   = make_color  50  70 110 255
let grass_col  = make_color  70 160  70 255
let grass_dark = make_color  50 120  50 255
let dirt_col   = make_color  90  60  40 255
let dirt_dark  = make_color  60  40  25 255
let plat_top   = make_color 180 140  90 255
let plat_mid   = make_color 140 100  60 255
let plat_dark  = make_color  90  60  40 255

let body_red    = make_color 220  60  60 255
let body_yellow = make_color 240 200  80 255
let body_dark   = make_color 130  30  30 255
let skin_col    = make_color 255 215 170 255
let hair_col    = make_color  60  40  30 255
let eye_col     = make_color  20  20  20 255

(* --- player + platforms --- *)
type player = { mutable x : int; mutable y : int; mutable vy : int }
let p = { x = 280; y = ground_y - 30; vy = 0 }

let platforms =
  [| (100, 280, 80, 14);
     (250, 230, 80, 14);
     (400, 180, 80, 14) |]

let on_ground () = p.y >= ground_y - 30

let aabb_overlap (ax, ay, aw, ah) (bx, by, bw, bh) =
  ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by

let step () =
  if is_key_down key_right then p.x <- p.x + move_speed;
  if is_key_down key_left  then p.x <- p.x - move_speed;
  if is_key_down key_space && on_ground () then p.vy <- jump_vy;
  p.vy <- p.vy + gravity;
  p.y <- p.y + p.vy;
  if p.y > ground_y - 30 then (p.y <- ground_y - 30; p.vy <- 0);
  if p.vy >= 0 then begin
    let pr = (p.x, p.y, 30, 30) in
    Array.iter (fun plat ->
      let (_, py, _, _) = plat in
      if aabb_overlap pr plat
         && p.y + 30 - p.vy <= py + 2
      then (p.y <- py - 30; p.vy <- 0)
    ) platforms
  end;
  if p.x < -30 then p.x <- win_w;
  if p.x > win_w then p.x <- -30

(* --- drawing --- *)

let draw_sun () =
  draw_circle 80 70 26.0 sun_col;
  draw_circle 80 70 18.0 (make_color 255 240 180 255)

let draw_cloud cx cy =
  draw_circle  cx        cy      18.0 cloud_col;
  draw_circle (cx + 16) (cy + 4) 14.0 cloud_col;
  draw_circle (cx - 14) (cy + 4) 12.0 cloud_col;
  draw_circle (cx + 30) (cy + 6) 10.0 cloud_col

let draw_mountains () =
  let v x y = make_vector2 (float_of_int x) (float_of_int y) in
  (* far range *)
  draw_triangle (v   0 ground_y) (v 160 200) (v 320 ground_y) mtn_far;
  draw_triangle (v 240 ground_y) (v 400 220) (v 560 ground_y) mtn_far;
  (* near range *)
  draw_triangle (v (-40) ground_y) (v  60 250) (v 200 ground_y) mtn_near;
  draw_triangle (v  340 ground_y) (v 470 240) (v 620 ground_y) mtn_near

let draw_ground () =
  (* grass strip *)
  draw_rectangle 0 ground_y win_w 6 grass_col;
  draw_rectangle 0 (ground_y + 6) win_w 2 grass_dark;
  (* dirt body *)
  draw_rectangle_gradient_v 0 (ground_y + 8) win_w (win_h - ground_y - 8)
    dirt_col dirt_dark

let draw_platform (px, py, pw, ph) =
  (* shadow underneath *)
  draw_rectangle (px + 2) (py + ph) pw 3 (make_color 0 0 0 80);
  (* body *)
  draw_rectangle px py pw ph plat_mid;
  (* top highlight (grass-like) *)
  draw_rectangle px py pw 3 plat_top;
  (* bottom edge *)
  draw_rectangle px (py + ph - 2) pw 2 plat_dark

let draw_player () =
  let x = p.x and y = p.y in
  let in_air = not (on_ground ()) in
  let body = if in_air then body_yellow else body_red in
  let outline = body_dark in
  (* legs *)
  draw_rectangle (x + 5)  (y + 22) 7 8 outline;
  draw_rectangle (x + 18) (y + 22) 7 8 outline;
  (* body *)
  draw_rectangle (x + 4)  (y + 12) 22 12 body;
  draw_rectangle (x + 4)  (y + 22) 22 2 outline;
  (* head *)
  draw_rectangle (x + 7)  y        16 14 skin_col;
  (* hair *)
  draw_rectangle (x + 7)  y        16 4 hair_col;
  draw_rectangle (x + 7)  (y + 3)  2  2 hair_col;
  draw_rectangle (x + 21) (y + 3)  2  2 hair_col;
  (* eyes (facing direction-ish) *)
  let ex = if is_key_down key_left then x + 9 else x + 12 in
  draw_rectangle ex       (y + 6) 2 3 eye_col;
  draw_rectangle (ex + 5) (y + 6) 2 3 eye_col

let draw_hud () =
  draw_fps 8 8;
  draw_text "<- -> to move, space to jump" 8 (win_h - 22) 14
    (make_color 255 255 255 180)

let draw () =
  begin_drawing ();
  (* sky *)
  draw_rectangle_gradient_v 0 0 win_w ground_y sky_top sky_bot;
  draw_sun ();
  draw_cloud 200  60;
  draw_cloud 430  90;
  draw_mountains ();
  draw_ground ();
  Array.iter draw_platform platforms;
  draw_player ();
  draw_hud ();
  end_drawing ()

(* --- main loop --- *)
let () =
  while not (window_should_close ()) do
    step ();
    draw ()
  done;
  close_window ()
