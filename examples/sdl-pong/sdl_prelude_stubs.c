/* C stubs for sdl_prelude.ml externals. Never executed — lua_of_ocaml
   replaces the calls with direct Lua calls. They exist only so
   `ocamlc -custom` can link. */
#include <caml/mlvalues.h>

CAMLprim value null_str   (value u)            { (void)u; return Val_int(0); }
CAMLprim value alloc_event(value u)            { (void)u; return Val_int(0); }
CAMLprim value event_type (value v)            { (void)v; return Val_int(0); }
/* sdl_poll_event is also declared in sdl3_merged_stubs.c by the
   generator; we only need our shadowing OCaml external, not a
   second C stub. */
CAMLprim value sdl_fill_rect (value a, value b, value c, value d, value e)
{ (void)a;(void)b;(void)c;(void)d;(void)e; return Val_unit; }
CAMLprim value sdl_init_kb_state (value u)     { (void)u; return Val_unit; }
CAMLprim value sdl_is_key_pressed(value v)     { (void)v; return Val_bool(0); }
