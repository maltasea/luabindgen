## examples/call-directions — demonstrates all six cross-language call
## directions in our pipeline (OCaml / Lua / C). Text-only program;
## no window, no library beyond libc (qsort / strlen via FFI).
##
## Uses hand-written prelude.lua rather than luabindgen-generated
## bindings — the point here is the runtime call architecture, not
## the generator. (The other examples cover the generator.)
##
## See the top-level README's "bytecode-magic gotcha" for the OCaml
## version requirement.

THIS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
LUO      := $(abspath $(THIS_DIR)/../../extern/lua_of_ocaml)

OCAMLC ?= ocamlc
LUAJIT ?= luajit

OBJS = prelude_stubs.o prelude.cmo main.cmo

.PHONY: all run check clean
all: main.lua

# `check` runs the program; each direction asserts PASS/FAIL; the
# program exits non-zero on any failure. Suitable for a CI hook.
check: main.lua
	@$(LUAJIT) main.lua

prelude_stubs.o: prelude_stubs.c
	$(OCAMLC) -c prelude_stubs.c

prelude.cmo: prelude.ml
	$(OCAMLC) -c prelude.ml

main.cmo: main.ml prelude.cmo
	$(OCAMLC) -c main.ml

main.byte: $(OBJS)
	$(OCAMLC) -custom -o main.byte $(OBJS)

gen.lua: main.byte
	LOO_RUNTIME=$(LUO)/runtime/lua $(LUO)/loo.sh main.byte -o gen.lua

main.lua: prelude.lua gen.lua
	cat prelude.lua gen.lua > main.lua

run: main.lua
	@$(LUAJIT) main.lua

clean:
	rm -f $(OBJS) prelude.cmi main.cmi main.byte gen.lua main.lua
