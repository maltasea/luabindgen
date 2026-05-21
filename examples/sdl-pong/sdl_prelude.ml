(* OCaml externals for the hand-written Lua helpers in
   sdl_prelude.lua. Shadows the generator's signatures where we need
   the abstract sdl_event type or a different convention. *)

open Sdl3_merged_external

external null_str    : unit -> string    = "null_str"
external alloc_event : unit -> sdl_event = "alloc_event"
external event_type  : sdl_event -> int  = "event_type"
external sdl_poll_event : sdl_event -> bool = "sdl_poll_event"

external sdl_fill_rect
  : int -> float -> float -> float -> float -> unit
  = "sdl_fill_rect"

external sdl_init_kb_state  : unit -> unit       = "sdl_init_kb_state"
external sdl_is_key_pressed : int  -> bool       = "sdl_is_key_pressed"
