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

let bg                  = make_color  35  40  65 255
let ground_col          = make_color  60  90  60 255
let plat_col            = make_color 130 100  70 255
let player_col_grounded = make_color 230  80  60 255
let player_col_air      = make_color 240 200  80 255

type player = { mutable x : int; mutable y : int; mutable vy : int }

let p = { x = 280; y = ground_y - 30; vy = 0 }

let platforms =
  [| (100, 280, 80, 12);
     (250, 230, 80, 12);
     (400, 180, 80, 12) |]

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

  (* Land on platforms (only when falling, only if we crossed the top
     edge in this step). *)
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

let draw () =
  begin_drawing ();
  clear_background bg;
  draw_rectangle 0 ground_y win_w (win_h - ground_y) ground_col;
  Array.iter (fun (px, py, pw, ph) ->
    draw_rectangle px py pw ph plat_col
  ) platforms;
  let pc = if on_ground () then player_col_grounded else player_col_air in
  draw_rectangle p.x p.y 30 30 pc;
  draw_fps 8 8;
  end_drawing ()

let () =
  while not (window_should_close ()) do
    step ();
    draw ()
  done;
  close_window ()
