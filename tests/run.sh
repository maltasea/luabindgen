#!/bin/sh
# tests/run.sh — pattern-assertion tests for luabingen.
#
# Each test feeds a small synthetic header into the generator and asserts
# the output contains (or omits) specific patterns. Adding a new test
# is one heredoc + a few `expect`/`refute` calls. Run as `make test`
# from the repo root or directly via `sh tests/run.sh`.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LB="$HERE/../luabingen.ml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/luabingen-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
CURRENT=""

start() { CURRENT="$1"; }

# Generate <base>_{external.ml,stubs.c,bindings.lua} from stdin into $TMP.
gen() {
  local base="$1"; shift
  cat > "$TMP/$base.h"
  ocaml -I +str str.cma "$LB" --out-dir "$TMP" "$@" "$TMP/$base.h" \
    >"$TMP/$base.gen.log" 2>&1 || {
      echo "  FAIL: generator crashed; see $TMP/$base.gen.log"
      FAIL=$((FAIL + 1))
      return 1
    }
}

# Assert a regex matches somewhere in the named output file.
expect() {
  local kind="$1"   # ml | c | lua
  local base="$2"
  local re="$3"
  local file
  case "$kind" in
    ml)  file="$TMP/${base}_external.ml" ;;
    c)   file="$TMP/${base}_stubs.c" ;;
    lua) file="$TMP/${base}_bindings.lua" ;;
  esac
  if grep -qE -- "$re" "$file" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$CURRENT]: expected /$re/ in ${base}_${kind}"
    FAIL=$((FAIL + 1))
  fi
}

# Assert a regex does NOT match in the named output file.
refute() {
  local kind="$1" base="$2" re="$3" file
  case "$kind" in
    ml)  file="$TMP/${base}_external.ml" ;;
    c)   file="$TMP/${base}_stubs.c" ;;
    lua) file="$TMP/${base}_bindings.lua" ;;
  esac
  if grep -qE -- "$re" "$file" 2>/dev/null; then
    echo "  FAIL [$CURRENT]: did not expect /$re/ in ${base}_${kind}"
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

# Assert exactly N matches of regex in file (catches dup-emit regressions).
count() {
  local kind="$1" base="$2" want="$3" re="$4" file
  case "$kind" in
    ml)  file="$TMP/${base}_external.ml" ;;
    c)   file="$TMP/${base}_stubs.c" ;;
    lua) file="$TMP/${base}_bindings.lua" ;;
  esac
  local got
  got="$(grep -cE -- "$re" "$file" 2>/dev/null || echo 0)"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$CURRENT]: expected $want matches of /$re/ in \
${base}_${kind}, got $got"
    FAIL=$((FAIL + 1))
  fi
}

# ----------------------------------------------------------------------
# regression tests for the five bugs in report-gpt.txt (2026-05-21)
# ----------------------------------------------------------------------

start "char* return goes through ffi.string"
gen str_ret <<'EOF'
const char *GetName(void);
EOF
expect ml  str_ret '^external get_name : unit -> string'
expect lua str_ret 'function get_name\(\) local _s = C\.GetName\(\) .* ffi\.string'

start "array parameter decays to pointer (opaque int on OCaml side)"
gen arr_param <<'EOF'
void UseValues(float values[4]);
EOF
expect ml  arr_param '^external use_values : int -> unit'
refute ml  arr_param '^external use_values : float -> unit'

start "snake-cased duplicate names emit only one external"
gen dup_snake <<'EOF'
int FooBar(void);
int Foo_Bar(void);
EOF
count ml  dup_snake 1 '^external foo_bar :'
count c   dup_snake 1 'CAMLprim value foo_bar\('

start "enum integer literal with u/U suffix"
gen enum_suffix <<'EOF'
typedef enum ExampleFlag {
  EXAMPLE_A = 0x20u,
  EXAMPLE_B = 0x40U
} ExampleFlag;
EOF
expect ml enum_suffix '^let example_a = 32$'
expect ml enum_suffix '^let example_b = 64$'

start "anonymous top-level enum emits its constants"
gen anon_enum <<'EOF'
enum { ANON_A = 7, ANON_B = 8 };
enum { ANON_C = 10 };
EOF
expect ml anon_enum '^let anon_a = 7$'
expect ml anon_enum '^let anon_b = 8$'
expect ml anon_enum '^let anon_c = 10$'

# ----------------------------------------------------------------------
# existing-behavior regression locks
# ----------------------------------------------------------------------

start "simple struct emits abstract type + make_ constructor"
gen simple_struct <<'EOF'
typedef struct Color { int r, g, b, a; } Color;
void clear_background(Color c);
EOF
expect ml  simple_struct '^type color'
expect ml  simple_struct '^external make_color : int -> int -> int -> int -> color = "make_color"'
expect ml  simple_struct '^external clear_background : color -> unit'
expect lua simple_struct 'function make_color\(.*\) return \{ 0, ffi\.new\("Color"'
expect lua simple_struct 'function clear_background\(a1\) C\.clear_background\(a1\[2\]\); return end'

start "struct field accessors (scalar) — color_r etc."
gen color_fields <<'EOF'
typedef struct Color { int r, g, b, a; } Color;
EOF
expect ml  color_fields '^external color_r : color -> int = "color_r"'
expect ml  color_fields '^external color_a : color -> int = "color_a"'
expect lua color_fields 'function color_r\(a1\) return \(a1\[2\]\.r\) \* 2 end'

start "array struct fields preserve [N] in cdef; no accessor for arrays"
gen arr_field <<'EOF'
typedef struct Matrix { float m[16]; } Matrix;
EOF
expect lua arr_field 'float m\[16\];'
refute ml  arr_field '^external matrix_m :'

start "varargs stripped from OCaml signature"
gen varg <<'EOF'
void TraceLog(int level, const char *fmt, ...);
EOF
expect ml varg '^external trace_log : int -> string -> unit = "trace_log"'
refute ml varg 'unit -> unit'

start "typedef'd callback becomes opaque void* in cdef"
gen cb <<'EOF'
typedef int (*Handler)(int code);
void SetHandler(Handler h);
EOF
expect lua cb 'typedef void\* Handler;'

start "tag-qualified types in params (struct Foo *p, enum X s)"
gen tag <<'EOF'
struct Foo { int x; };
typedef enum { OK = 0, BAD = -1 } Status;
void f(struct Foo *p);
void g(enum Status s);
EOF
expect ml tag '^external f : int -> unit'
expect ml tag '^external g : int -> unit'
expect ml tag '^let ok = 0$'
expect ml tag '^let bad = -1$'

start "#define NAME <int-lit> becomes a let binding"
gen define <<'EOF'
#define FLAG_VSYNC 0x40u
#define LEVEL_HIGH 5
EOF
expect ml define '^let flag_vsync = 64$'
expect ml define '^let level_high = 5$'

start "ffi.load \"lib\" emitted with --lib"
gen lib_flag <<'EOF'
void f(void);
EOF
expect lua lib_flag 'local C = ffi\.C$'
gen lib_flag_named --lib MyLib <<'EOF'
void f(void);
EOF
expect lua lib_flag_named 'local C = ffi\.load\("MyLib"\)'

# ----------------------------------------------------------------------
# smoke test: bundled raylib header parses & emits expected counts
# ----------------------------------------------------------------------

RAYLIB_H="$HERE/../extern/raylib-6.0/src/raylib.h"
if [ -f "$RAYLIB_H" ]; then
  start "raylib 6.0: 600 fn decls / 37 structs / 22 enums"
  ocaml -I +str str.cma "$LB" --prefix RLAPI --out-dir "$TMP" \
    "$RAYLIB_H" > "$TMP/raylib.log" 2>&1
  if grep -qE '600 fn decls.*37 structs.*22 enums' "$TMP/raylib.log"; then
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$CURRENT]: counts drifted"
    grep -E 'fn decls' "$TMP/raylib.log" | head -1
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP raylib smoke: $RAYLIB_H not vendored"
fi

# ----------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
