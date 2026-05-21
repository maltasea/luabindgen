/* C stubs for sdl_prelude.ml externals. These are never executed —
   lua_of_ocaml replaces the calls with direct Lua calls. They exist
   only so `ocamlc -custom` can link. */

#include <caml/mlvalues.h>

CAMLprim value null_str(value v_unit)   { (void)v_unit; return Val_int(0); }
CAMLprim value alloc_event(value v_unit){ (void)v_unit; return Val_int(0); }
CAMLprim value event_type(value v)      { (void)v;      return Val_int(0); }
