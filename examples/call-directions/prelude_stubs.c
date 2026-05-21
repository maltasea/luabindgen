/* Linker placeholders for the externals in prelude.ml. They never
   execute — lua_of_ocaml replaces each primitive call with a direct
   Lua call to the same-named function. */
#include <caml/mlvalues.h>

CAMLprim value c_strlen         (value a)         { (void)a; return Val_int(0); }
CAMLprim value lua_uppercase    (value a)         { (void)a; return Val_int(0); }
CAMLprim value lua_then_c_strlen(value a)         { (void)a; return Val_int(0); }
CAMLprim value register_ocaml_callback(value a)   { (void)a; return Val_unit; }
CAMLprim value invoke_ocaml_from_lua  (value a)   { (void)a; return Val_unit; }
CAMLprim value run_pure_lua_to_c_test (value u)   { (void)u; return Val_unit; }
CAMLprim value run_c_callback_test    (value u)   { (void)u; return Val_unit; }
