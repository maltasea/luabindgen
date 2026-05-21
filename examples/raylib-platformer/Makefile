## examples/platformer — drives raylib via luabindgen + lua_of_ocaml + luajit
##
## Requires OCaml 5.4.x (system switch on this machine) so the bytecode
## magic (Caml1999X036) matches what the bundled loo binary expects.

# Resolve paths relative to this Makefile so `make -C examples/...`
# and shells with a different cwd both work.
THIS_DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LUABINGEN := $(abspath $(THIS_DIR)/../../luabingen.ml)
LUO       := $(abspath $(THIS_DIR)/../../extern/lua_of_ocaml)
RAYLIB_H  ?= /usr/local/Cellar/raylib/5.5/include/raylib.h

OCAMLC ?= ocamlc
LUAJIT ?= luajit

GENERATED = raylib_external.ml raylib_stubs.c raylib_bindings.lua
OBJS      = raylib_stubs.o raylib_external.cmo main.cmo

.PHONY: all run clean
all: main.lua

# 1. Generate the three binding files from the raylib header.
# Grouped target (GNU make 4.3+): one recipe produces all three files,
# so parallel `make -j` can't race by launching duplicate generators.
$(GENERATED) &: $(LUABINGEN) $(RAYLIB_H)
	ocaml -I +str str.cma $(LUABINGEN) \
	  --prefix "RLAPI" --lib raylib --out-dir . $(RAYLIB_H)

# 2. Compile C stubs + OCaml externals + main.
raylib_stubs.o: raylib_stubs.c
	$(OCAMLC) -c raylib_stubs.c

raylib_external.cmo: raylib_external.ml
	$(OCAMLC) -c raylib_external.ml

main.cmo: main.ml raylib_external.cmo
	$(OCAMLC) -c main.ml

# 3. Link to a -custom bytecode executable (loo wants this form).
main.byte: $(OBJS)
	$(OCAMLC) -custom -o main.byte \
	  raylib_stubs.o raylib_external.cmo main.cmo

# 4. Bytecode -> Lua, then concatenate bindings + generated code.
gen.lua: main.byte
	LOO_RUNTIME=$(LUO)/runtime/lua $(LUO)/loo.sh main.byte -o gen.lua

main.lua: raylib_bindings.lua gen.lua
	cat raylib_bindings.lua gen.lua > main.lua

run: main.lua
	$(LUAJIT) main.lua

clean:
	rm -f $(GENERATED) $(OBJS) raylib_external.cmi main.cmi \
	      main.byte gen.lua main.lua
