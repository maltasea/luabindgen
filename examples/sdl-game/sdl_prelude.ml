(* OCaml side of sdl_prelude.lua — externals for the hand-written
   helpers that luabindgen can't generate yet (NULL string, event
   allocation, event.type access).

   `sdl_event` here is the same abstract type the generated
   sdl3_merged_external.ml emits, so values flow through to
   sdl_poll_event etc. without any conversion. *)

open Sdl3_merged_external

external null_str    : unit -> string    = "null_str"
external alloc_event : unit -> sdl_event = "alloc_event"
external event_type  : sdl_event -> int  = "event_type"

(* Shadow the generated sdl_poll_event (which takes `int` because the
   underlying C type is a pointer) with a version that takes our
   abstract sdl_event. The C symbol is the same; only the OCaml type
   labelling changes. *)
external sdl_poll_event : sdl_event -> bool = "sdl_poll_event"
