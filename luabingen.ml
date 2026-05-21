(* luabingen — C header -> LuaJIT FFI + OCaml externals + C stubs
   Usage: ocaml -I +str str.cma luabingen.ml [--prefix PREFIX] <header.h>

   Pipeline:
     header.h
       -> Pp.run        : strip comments, drop preprocessor lines
       -> Lex.tokens    : token stream
       -> Parse.unit    : typed AST (typedefs, structs, enums, fn decls)
       -> Emit.{ml,c,lua} : the three sibling output files
*)

(* ================================================================== *)
(* AST                                                                 *)
(* ================================================================== *)

module Ast = struct
  (* C types we care about. We preserve struct/typedef names so that
     downstream emitters can decide how to cross the OCaml<->Lua
     boundary; the *current* OCaml mapper still collapses them to int,
     but the information is no longer lost. *)
  type ctype =
    | Void
    | Bool
    | Char of bool                  (* signed when true *)
    | Short of bool
    | Int of bool                   (* int / unsigned int *)
    | Long of bool
    | LongLong of bool
    | Float
    | Double
    | Named of string               (* struct/typedef/enum name *)
    | Ptr of ctype
    | Array of ctype * int option   (* length, when present, matters for
                                       struct layout (`float v[4]` is 4
                                       floats inline, not a pointer). *)
    | Const of ctype

  type param = { ptype : ctype; pname : string }
  type fn = { ret : ctype; name : string; params : param list }

  type field = { ftype : ctype; fname : string }
  type sdef = { sname : string; fields : field list }
  type edef = { ename : string; consts : (string * string option) list }

  type top =
    | Fn       of fn
    | Struct   of sdef
    | Enum     of edef
    | Alias    of string * ctype           (* typedef T A; *)
    | Callback of string * ctype * ctype list
                              (* typedef R ( * N )( ...) -- function pointer *)
end

(* ================================================================== *)
(* Preprocess                                                          *)
(* ================================================================== *)

module Pp = struct
  (* Strip // and /* */ comments, leaving string literals alone.
     Newlines inside block comments are preserved so line counts stay
     useful when we eventually report errors. *)
  let strip_comments s =
    let buf = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      let c = s.[!i] in
      if c = '/' && !i + 1 < n && s.[!i + 1] = '/' then begin
        while !i < n && s.[!i] <> '\n' do incr i done
      end
      else if c = '/' && !i + 1 < n && s.[!i + 1] = '*' then begin
        i := !i + 2;
        while !i + 1 < n && not (s.[!i] = '*' && s.[!i + 1] = '/') do
          if s.[!i] = '\n' then Buffer.add_char buf '\n';
          incr i
        done;
        if !i + 1 < n then i := !i + 2 else i := n
      end
      else if c = '"' then begin
        Buffer.add_char buf c; incr i;
        while !i < n && s.[!i] <> '"' do
          if s.[!i] = '\\' && !i + 1 < n then begin
            Buffer.add_char buf s.[!i];
            Buffer.add_char buf s.[!i + 1];
            i := !i + 2
          end else begin
            Buffer.add_char buf s.[!i]; incr i
          end
        done;
        if !i < n then (Buffer.add_char buf '"'; incr i)
      end
      else begin
        Buffer.add_char buf c; incr i
      end
    done;
    Buffer.contents buf

  (* Drop lines starting with # (after whitespace). Supports the
     backslash continuation convention. *)
  let strip_pp s =
    let lines = String.split_on_char '\n' s in
    let buf = Buffer.create (String.length s) in
    let in_cont = ref false in
    List.iter (fun line ->
      let t = String.trim line in
      let ends_bs =
        String.length t > 0 && t.[String.length t - 1] = '\\'
      in
      let is_pp = String.length t > 0 && t.[0] = '#' in
      if !in_cont then begin
        in_cont := ends_bs;
        Buffer.add_char buf '\n'
      end else if is_pp then begin
        in_cont := ends_bs;
        Buffer.add_char buf '\n'
      end else begin
        Buffer.add_string buf line;
        Buffer.add_char buf '\n'
      end
    ) lines;
    Buffer.contents buf

  let run s = strip_pp (strip_comments s)
end

(* ================================================================== *)
(* Lexer                                                               *)
(* ================================================================== *)

module Lex = struct
  type tok =
    | TIdent  of string
    | TInt    of string            (* keep as string; we don't compute *)
    | TLParen | TRParen
    | TLBrace | TRBrace
    | TLBrack | TRBrack
    | TStar
    | TComma
    | TSemi
    | TEq
    | TEllipsis
    | TOther of char               (* anything else, parser may skip *)

  let is_ident_start c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '_'

  let is_ident_cont c =
    is_ident_start c || (c >= '0' && c <= '9')

  let is_digit c = c >= '0' && c <= '9'

  let tokens s =
    let n = String.length s in
    let i = ref 0 in
    let out = ref [] in
    let push t = out := t :: !out in
    while !i < n do
      let c = s.[!i] in
      match c with
      | ' ' | '\t' | '\n' | '\r' -> incr i
      | '(' -> push TLParen; incr i
      | ')' -> push TRParen; incr i
      | '{' -> push TLBrace; incr i
      | '}' -> push TRBrace; incr i
      | '[' -> push TLBrack; incr i
      | ']' -> push TRBrack; incr i
      | '*' -> push TStar;   incr i
      | ',' -> push TComma;  incr i
      | ';' -> push TSemi;   incr i
      | '=' -> push TEq;     incr i
      | '.' when !i + 2 < n && s.[!i + 1] = '.' && s.[!i + 2] = '.' ->
          push TEllipsis; i := !i + 3
      | c when is_ident_start c ->
          let start = !i in
          while !i < n && is_ident_cont s.[!i] do incr i done;
          push (TIdent (String.sub s start (!i - start)))
      | c when is_digit c ->
          let start = !i in
          while !i < n &&
                (is_ident_cont s.[!i] || s.[!i] = '.' ||
                 s.[!i] = '+' || s.[!i] = '-')
          do incr i done;
          push (TInt (String.sub s start (!i - start)))
      | c -> push (TOther c); incr i
    done;
    List.rev !out
end

(* ================================================================== *)
(* Parser                                                              *)
(* ================================================================== *)

module Parse = struct
  open Ast
  open Lex

  exception Stop

  (* Mutable token cursor. Cheap and easy for a recursive-descent
     parser this small. *)
  type st = { mutable toks : tok list }

  let peek st = match st.toks with [] -> None | t :: _ -> Some t
  let advance st = match st.toks with [] -> () | _ :: r -> st.toks <- r
  let eat st t = match st.toks with
    | x :: r when x = t -> st.toks <- r; true
    | _ -> false

  (* Skip until (and including) a terminator at brace depth 0. *)
  let skip_until_top st terminators =
    let depth = ref 0 in
    try
      while true do
        match peek st with
        | None -> raise Stop
        | Some t ->
            advance st;
            (match t with
             | TLBrace | TLParen | TLBrack -> incr depth
             | TRBrace | TRParen | TRBrack ->
                 if !depth > 0 then decr depth
             | _ when !depth = 0 && List.mem t terminators -> raise Exit
             | _ -> ())
      done; ()
    with Exit -> () | Stop -> ()

  (* Collect tokens forming a balanced { ... } block, with the leading
     '{' already consumed. Returns the inner tokens (without the
     matching '}'). *)
  let collect_brace_body st =
    let acc = ref [] in
    let depth = ref 1 in
    let going = ref true in
    while !going do
      match peek st with
      | None -> going := false
      | Some t ->
          advance st;
          (match t with
           | TLBrace -> incr depth; acc := t :: !acc
           | TRBrace ->
               decr depth;
               if !depth = 0 then going := false
               else acc := t :: !acc
           | _ -> acc := t :: !acc)
    done;
    List.rev !acc

  (* --- type parsing --- *)
  (* Type specifier: a sequence of identifiers (`const`, `unsigned`,
     `int`, `Color`, ...) followed by zero or more `*`s. We stop as
     soon as we see an identifier whose role is "the declared name"
     (handled by callers, since we don't know in advance). *)

  let primitive_of_words ws =
    (* Resolve a list of type-specifier words to a ctype.
       Order of words is irrelevant in C: `unsigned int`, `int unsigned`,
       `signed long long int` all denote the same type. *)
    let has w = List.mem w ws in
    let unsigned = has "unsigned" in
    let signed_explicit = has "signed" in
    let signed = signed_explicit || not unsigned in
    if has "void" then Void
    else if has "_Bool" || has "bool" then Bool
    else if has "char" then Char signed
    else if has "short" then Short signed
    else if has "long" then
      if List.length (List.filter ((=) "long") ws) >= 2
      then LongLong signed else Long signed
    else if has "float" then Float
    else if has "double" then Double
    else if has "int" || unsigned || signed_explicit then Int signed
    else
      (* Pick the first non-qualifier word as a named type. *)
      let qualifiers =
        ["const"; "volatile"; "static"; "extern"; "inline"; "restrict";
         "register"; "_Atomic"; "_Noreturn"]
      in
      let names = List.filter (fun w -> not (List.mem w qualifiers)) ws in
      (match names with
       | n :: _ -> Named n
       | [] -> Void  (* shouldn't happen — treat as void *))

  (* Consume a run of "type words" (identifiers used as type specifiers)
     and the trailing '*'s. Returns (ctype, consumed_anything).

     Also handles tag-qualified `struct X` / `enum X` / `union X` —
     consumes the keyword and treats the following identifier as the
     named type, so e.g. `void f(struct Foo *p)` parses with Foo as
     the type and p as the param name. *)
  let parse_type st =
    let words = ref [] in
    let saw_const = ref false in
    let going = ref true in
    while !going do
      match peek st with
      | Some (TIdent ("struct" | "enum" | "union")) ->
          advance st;
          (match peek st with
           | Some (TIdent n) ->
               advance st;
               words := n :: !words;
               going := false
           | _ -> going := false)
      | Some (TIdent w) when
          List.mem w
            ["const"; "volatile"; "static"; "extern"; "inline"; "restrict";
             "register"; "_Atomic"; "_Noreturn";
             "void"; "_Bool"; "bool"; "char"; "short"; "int"; "long";
             "float"; "double"; "signed"; "unsigned"] ->
          if w = "const" then saw_const := true;
          words := w :: !words;
          advance st
      | _ -> going := false
    done;
    (* Did we accumulate a real type specifier (something other than just
       qualifiers like `const`)? *)
    let type_specifiers =
      List.filter (fun w ->
        not (List.mem w
               ["const"; "volatile"; "static"; "extern"; "inline";
                "restrict"; "register"; "_Atomic"; "_Noreturn"])
      ) !words
    in
    let base =
      if type_specifiers = [] then begin
        (* Either nothing collected, or only qualifiers — the next
           identifier is the named-type. *)
        match peek st with
        | Some (TIdent w) ->
            advance st;
            (match peek st with
             | Some (TIdent "const") -> advance st; saw_const := true
             | _ -> ());
            Named w
        | _ -> Void
      end else
        primitive_of_words !words
    in
    (* Collect pointer stars *)
    let t = ref base in
    while peek st = Some TStar do
      advance st;
      t := Ptr !t;
      (* `T * const` etc. *)
      (match peek st with
       | Some (TIdent "const") | Some (TIdent "volatile") -> advance st
       | _ -> ())
    done;
    let final = if !saw_const then Const !t else !t in
    final

  (* Parse one parameter inside a function param list. The param's name
     (if present) is the last identifier before ',' or ')'. *)
  let rec parse_param st =
    (* Special case: a lone "void" means no parameters. *)
    match peek st with
    | Some (TIdent "void") ->
        (* Could be the type "void" of a real param like `void *p`.
           Disambiguate by lookahead. *)
        (match st.toks with
         | _ :: TRParen :: _ -> advance st; None
         | _ ->
             let t = parse_type st in
             let name = match peek st with
               | Some (TIdent n) -> advance st; n
               | _ -> ""
             in
             (* swallow array suffix `[N]` or `[]` *)
             (match peek st with
              | Some TLBrack ->
                  let _ = collect_brack_until_close st in ()
              | _ -> ());
             Some { ptype = t; pname = name })
    | _ ->
        let t = parse_type st in
        (* The next token is either the param name, or a comma/RParen
           if the param was anonymous. *)
        let name = match peek st with
          | Some (TIdent n) -> advance st; n
          | _ -> ""
        in
        (match peek st with
         | Some TLBrack -> collect_brack_until_close st
         | _ -> ());
        Some { ptype = t; pname = name }

  and collect_brack_until_close st =
    (* swallow [ ... ] including nested brackets *)
    if eat st TLBrack then begin
      let depth = ref 1 in
      while !depth > 0 do
        match peek st with
        | None -> depth := 0
        | Some TLBrack -> advance st; incr depth
        | Some TRBrack -> advance st; decr depth
        | Some _ -> advance st
      done
    end

  let parse_param_list st =
    (* '(' already consumed; consume params and the closing ')'. We
       drop any trailing `...` varargs marker — those can't be expressed
       as an OCaml external arity, so the binding caller is responsible
       for passing extras through some other channel. *)
    let params = ref [] in
    (match peek st with
     | Some TRParen -> advance st
     | _ ->
         let going = ref true in
         while !going do
           (match peek st with
            | Some TEllipsis -> advance st
            | _ ->
                (match parse_param st with
                 | Some p -> params := p :: !params
                 | None -> ()));
           match peek st with
           | Some TComma -> advance st
           | Some TRParen -> advance st; going := false
           | None -> going := false
           | _ -> advance st
         done);
    List.rev !params

  (* --- struct/enum/typedef parsers --- *)

  (* `struct NAME? { fields }` — `struct` already consumed. *)
  let parse_struct_body st =
    let tag = match peek st with
      | Some (TIdent n) -> advance st; Some n
      | _ -> None
    in
    if not (eat st TLBrace) then (tag, [])
    else begin
      let fields = ref [] in
      let going = ref true in
      while !going do
        match peek st with
        | Some TRBrace -> advance st; going := false
        | None -> going := false
        | _ ->
            (* Parse one field declaration: type name [, name]* ; *)
            let t = parse_type st in
            let going2 = ref true in
            while !going2 do
              match peek st with
              | Some (TIdent n) ->
                  advance st;
                  (* Capture array length if present: `float v[4]` should
                     contribute four float-sized slots to the struct,
                     not a single one. *)
                  let ftype =
                    match peek st with
                    | Some TLBrack ->
                        let len =
                          match st.toks with
                          | _ :: TInt s :: _ ->
                              (try Some (int_of_string s)
                               with _ -> None)
                          | _ -> None
                        in
                        collect_brack_until_close st;
                        Array (t, len)
                    | Some (TOther ':') ->
                        (* bitfield: ': N' — drop info, keep base type *)
                        advance st;
                        (match peek st with
                         | Some (TInt _) -> advance st
                         | _ -> ());
                        t
                    | _ -> t
                  in
                  fields := { ftype; fname = n } :: !fields;
                  (match peek st with
                   | Some TComma -> advance st
                   | _ -> going2 := false)
              | Some TSemi -> going2 := false
              | _ -> going2 := false; advance st
            done;
            ignore (eat st TSemi)
      done;
      (tag, List.rev !fields)
    end

  (* `enum NAME? { CONST [= val], ... }` *)
  let parse_enum_body st =
    let tag = match peek st with
      | Some (TIdent n) -> advance st; Some n
      | _ -> None
    in
    if not (eat st TLBrace) then (tag, [])
    else begin
      let consts = ref [] in
      let going = ref true in
      while !going do
        match peek st with
        | Some TRBrace -> advance st; going := false
        | Some (TIdent n) ->
            advance st;
            let v =
              if eat st TEq then
                (* swallow expression up to comma or '}' at depth 0 *)
                let buf = Buffer.create 16 in
                let depth = ref 0 in
                let stop = ref false in
                while not !stop do
                  match peek st with
                  | None -> stop := true
                  | Some (TComma | TRBrace) when !depth = 0 -> stop := true
                  | Some t ->
                      advance st;
                      (match t with
                       | TLParen | TLBrace | TLBrack -> incr depth
                       | TRParen | TRBrace | TRBrack -> decr depth
                       | _ -> ());
                      let s = match t with
                        | TIdent x -> x | TInt x -> x
                        | TStar -> "*" | TComma -> ","
                        | TLParen -> "(" | TRParen -> ")"
                        | TLBrace -> "{" | TRBrace -> "}"
                        | TLBrack -> "[" | TRBrack -> "]"
                        | TSemi -> ";" | TEq -> "="
                        | TEllipsis -> "..." | TOther c -> String.make 1 c
                      in
                      Buffer.add_string buf s; Buffer.add_char buf ' '
                done;
                Some (String.trim (Buffer.contents buf))
              else None
            in
            consts := (n, v) :: !consts;
            (match peek st with
             | Some TComma -> advance st
             | _ -> ())
        | _ -> advance st
      done;
      (tag, List.rev !consts)
    end

  (* Try to parse a function-pointer typedef of the shape
        typedef R  ( * Name ) ( params );
     `typedef` is already consumed. Returns Some Callback or None;
     on None the cursor is reset by the caller. *)
  let try_callback_typedef st =
    let saved = st.toks in
    let ret = parse_type st in
    (* Expect ( * Name ) *)
    if not (eat st TLParen) then (st.toks <- saved; None)
    else begin
      (* The '*' may be preceded by qualifiers; skip up to '*' *)
      while peek st = Some (TStar) = false &&
            (match peek st with
             | Some (TIdent _) -> true
             | _ -> false)
      do advance st done;
      if not (eat st TStar) then (st.toks <- saved; None)
      else
        match peek st with
        | Some (TIdent name) ->
            advance st;
            if not (eat st TRParen) then (st.toks <- saved; None)
            else if not (eat st TLParen) then (st.toks <- saved; None)
            else begin
              let params = parse_param_list st in
              ignore (eat st TSemi);
              Some (Callback (name, ret, List.map (fun p -> p.ptype) params))
            end
        | _ -> st.toks <- saved; None
    end

  (* Try to parse `typedef T A;` (simple alias). Returns Some Alias
     or None. Cursor is left at end of statement on success. *)
  let try_alias_typedef st =
    let saved = st.toks in
    let t = parse_type st in
    match peek st with
    | Some (TIdent name) ->
        advance st;
        (* might be `typedef T A[N];` etc. — swallow trailers *)
        (match peek st with
         | Some TLBrack -> collect_brack_until_close st
         | _ -> ());
        if eat st TSemi then Some (Alias (name, t))
        else (st.toks <- saved; None)
    | _ -> st.toks <- saved; None

  (* Parse a `typedef` statement. The keyword is already consumed. *)
  let parse_typedef st =
    match peek st with
    | Some (TIdent "struct") ->
        advance st;
        let (_tag, fields) = parse_struct_body st in
        (* the final identifier is the alias name *)
        let trailing_names = ref [] in
        let going = ref true in
        while !going do
          match peek st with
          | Some (TIdent n) ->
              advance st;
              trailing_names := n :: !trailing_names;
              (match peek st with
               | Some TComma -> advance st
               | _ -> ())
          | Some TStar -> advance st
          | Some TSemi -> advance st; going := false
          | None -> going := false
          | _ -> advance st
        done;
        (* For each trailing name, emit a Struct entry. *)
        List.rev_map (fun n -> Struct { sname = n; fields }) !trailing_names
    | Some (TIdent "enum") ->
        advance st;
        let (_tag, consts) = parse_enum_body st in
        let trailing_names = ref [] in
        let going = ref true in
        while !going do
          match peek st with
          | Some (TIdent n) ->
              advance st;
              trailing_names := n :: !trailing_names;
              (match peek st with
               | Some TComma -> advance st
               | _ -> ())
          | Some TSemi -> advance st; going := false
          | None -> going := false
          | _ -> advance st
        done;
        List.rev_map
          (fun n -> Enum { ename = n; consts })
          !trailing_names
    | Some (TIdent "union") ->
        (* treat unions like opaque structs to keep things simple *)
        advance st;
        let (_tag, _fields) = parse_struct_body st in
        skip_until_top st [TSemi]; []
    | _ ->
        (* Either typedef-of-callback or typedef-of-alias. *)
        (match try_callback_typedef st with
         | Some cb -> [cb]
         | None ->
             (match try_alias_typedef st with
              | Some a -> [a]
              | None ->
                  (* give up, skip statement *)
                  skip_until_top st [TSemi]; []))

  (* Try to parse a top-level function declaration starting at the
     current token. Returns Some Fn or None; on None the cursor is
     advanced by one token so the outer loop makes progress. *)
  let try_fn_decl st =
    let saved = st.toks in
    let ret = parse_type st in
    match peek st with
    | Some (TIdent name) ->
        advance st;
        if eat st TLParen then begin
          let params = parse_param_list st in
          if eat st TSemi then Some (Fn { ret; name; params })
          else (st.toks <- saved; advance st; None)
        end else (st.toks <- saved; advance st; None)
    | _ -> st.toks <- saved; advance st; None

  let parse_unit toks =
    let st = { toks } in
    let out = ref [] in
    let going = ref true in
    while !going do
      match peek st with
      | None -> going := false
      | Some (TIdent "typedef") ->
          advance st;
          List.iter (fun d -> out := d :: !out) (parse_typedef st)
      | Some (TIdent "struct") ->
          (* `struct Foo { ... };`  -> a struct definition.
             `struct Foo somefn(...);` -> a function decl with a
             tag-qualified return type. Look two tokens past the
             tag for a `{` to disambiguate. *)
          (match st.toks with
           | _ :: TIdent _ :: TLBrace :: _ | _ :: TLBrace :: _ ->
               advance st;
               let (tag, fields) = parse_struct_body st in
               (match tag with
                | Some n -> out := Struct { sname = n; fields } :: !out
                | None -> ());
               skip_until_top st [TSemi]
           | _ ->
               (* Not a struct definition — let try_fn_decl handle it
                  via parse_type, which understands `struct Foo`. *)
               (match try_fn_decl st with
                | Some d -> out := d :: !out
                | None -> ()))
      | Some (TIdent "enum") ->
          (match st.toks with
           | _ :: TIdent _ :: TLBrace :: _ | _ :: TLBrace :: _ ->
               advance st;
               let (tag, consts) = parse_enum_body st in
               (match tag with
                | Some n -> out := Enum { ename = n; consts } :: !out
                | None -> ());
               skip_until_top st [TSemi]
           | _ ->
               (match try_fn_decl st with
                | Some d -> out := d :: !out
                | None -> ()))
      | Some TSemi -> advance st
      | Some _ ->
          (match try_fn_decl st with
           | Some d -> out := d :: !out
           | None -> ())
    done;
    List.rev !out
end

(* ================================================================== *)
(* Type mapping                                                        *)
(* ================================================================== *)

module Typ = struct
  open Ast

  (* Environment of known type names → "kind tag" used by emitters.
     - `Struct`  : aggregate; on the OCaml side we treat as opaque int.
     - `Enum`    : maps to int.
     - `Alias t` : transparent alias.
     - `Callback`: treated as opaque pointer (int).
  *)
  type kind = KStruct | KEnum | KAlias of ctype | KCallback

  let make_env (tops : top list) : (string, kind) Hashtbl.t =
    let h = Hashtbl.create 64 in
    List.iter (function
      | Struct s   -> Hashtbl.replace h s.sname KStruct
      | Enum e     -> Hashtbl.replace h e.ename KEnum
      | Alias (n, t) -> Hashtbl.replace h n (KAlias t)
      | Callback (n, _, _) -> Hashtbl.replace h n KCallback
      | Fn _ -> ()) tops;
    h

  let rec resolve env t =
    match t with
    | Named n ->
        (match Hashtbl.find_opt env n with
         | Some (KAlias t') -> resolve env t'
         | _ -> t)
    | Const t' -> Const (resolve env t')
    | Ptr t'   -> Ptr (resolve env t')
    | Array (t', n) -> Array (resolve env t', n)
    | _ -> t

  (* CamelCase / PascalCase -> snake_case. Kept here (rather than in
     Emit) because ocaml_of needs it for the OCaml type name of a
     struct. Digit↔letter boundaries don't get an underscore — that
     keeps "Texture2D" as "texture2d", not "texture2_d". *)
  let snake s =
    let b = Buffer.create (String.length s + 4) in
    String.iteri (fun i c ->
      if c >= 'A' && c <= 'Z' then begin
        let prev_lower =
          i > 0 && s.[i - 1] >= 'a' && s.[i - 1] <= 'z'
        in
        if prev_lower then Buffer.add_char b '_';
        Buffer.add_char b (Char.lowercase_ascii c)
      end else
        Buffer.add_char b c
    ) s;
    let r = Buffer.contents b in
    if String.length r > 0 && r.[0] = '_'
    then String.sub r 1 (String.length r - 1) else r

  (* Map a (resolved) ctype to its OCaml external type. A struct becomes
     an abstract OCaml type named after the struct (snake-cased). *)
  let rec ocaml_of env t =
    match resolve env t with
    | Void -> "unit"
    | Bool -> "bool"
    | Char _ -> "int"
    | Short _ | Int _ | Long _ | LongLong _ -> "int"
    | Float | Double -> "float"
    | Const t' -> ocaml_of env t'
    | Ptr (Const (Char _)) | Ptr (Char _) -> "string"
    | Ptr _ -> "int"
    | Array _ -> "int"
    | Named n ->
        (match Hashtbl.find_opt env n with
         | Some KEnum -> "int"
         | Some KStruct -> snake n
         | Some KCallback -> "int"
         | Some (KAlias t') -> ocaml_of env t'
         | None -> "int")

end

(* ================================================================== *)
(* Emit                                                                *)
(* ================================================================== *)

module Emit = struct
  open Ast

  let snake = Typ.snake

  (* Lookup a struct definition by name. *)
  let struct_map (tops : top list) : (string, sdef) Hashtbl.t =
    let h = Hashtbl.create 32 in
    List.iter (function
      | Struct s -> Hashtbl.replace h s.sname s
      | _ -> ()) tops;
    h

  (* A struct is "simple" if every field is recursively a scalar (or a
     simple struct). Only simple structs get auto-generated
     constructors; everything else stays opaque-by-API. *)
  let rec is_simple_type env smap seen t =
    match Typ.resolve env t with
    | Void -> false
    | Bool | Char _ | Short _ | Int _ | Long _ | LongLong _
    | Float | Double -> true
    | Const t' -> is_simple_type env smap seen t'
    | Ptr _ | Array _ -> false
    | Named n ->
        if List.mem n seen then true
        else
          (match Hashtbl.find_opt env n with
           | Some Typ.KEnum -> true
           | Some Typ.KStruct ->
               (match Hashtbl.find_opt smap n with
                | Some s ->
                    List.for_all
                      (fun f -> is_simple_type env smap (n :: seen) f.ftype)
                      s.fields
                | None -> false)
           | Some (Typ.KAlias t') -> is_simple_type env smap seen t'
           | Some Typ.KCallback -> false
           | None -> false)

  let is_simple_struct env smap s =
    s.fields <> [] &&
    List.for_all
      (fun f -> is_simple_type env smap [s.sname] f.ftype)
      s.fields

  let strip_prefix prefix name =
    let pn = String.length prefix and nn = String.length name in
    if prefix = "" then name
    else if nn >= pn && String.sub name 0 pn = prefix
    then String.sub name pn (nn - pn) else name

  (* Re-stringify a C type so we can write it back into the
     ffi.cdef block. Keeps qualifiers and stars in roughly the right
     positions; good enough for LuaJIT's parser. *)
  let rec c_of = function
    | Void -> "void"
    | Bool -> "bool"
    | Char true -> "char"
    | Char false -> "unsigned char"
    | Short true -> "short"
    | Short false -> "unsigned short"
    | Int true -> "int"
    | Int false -> "unsigned int"
    | Long true -> "long"
    | Long false -> "unsigned long"
    | LongLong true -> "long long"
    | LongLong false -> "unsigned long long"
    | Float -> "float"
    | Double -> "double"
    | Named n -> n
    | Const t -> "const " ^ c_of t
    | Ptr t -> c_of t ^ " *"
    | Array (t, _) -> c_of t ^ " *"
        (* used for function parameters where the array decays to a
           pointer; field-position arrays go through `field_decl` below
           so the [N] suffix lands in the right place. *)

  (* Classify a *C* type for boundary conversion. Drives Lua-side
     unwrapping of args and re-tagging of returns. We distinguish
     AStruct from APassthrough because structs cross as a wrapped block
     {0, cdata}, not as raw cdata. *)
  type abi =
    | AVoid
    | AInt
    | ABool
    | AFloat
    | AStruct         (* struct-by-value: block {0, cdata} *)
    | APassthrough    (* string, pointer, callback handle, ... *)

  let abi_of env t =
    let rec go t = match Typ.resolve env t with
      | Ast.Void -> AVoid
      | Ast.Bool -> ABool
      | Ast.Char _ | Ast.Short _ | Ast.Int _
      | Ast.Long _ | Ast.LongLong _ -> AInt
      | Ast.Float | Ast.Double -> AFloat
      | Ast.Const t' -> go t'
      | Ast.Ptr _ | Ast.Array _ -> APassthrough
      | Ast.Named n ->
          (match Hashtbl.find_opt env n with
           | Some Typ.KStruct -> AStruct
           | _ -> APassthrough)
    in go t

  (* The Lua-side expression that converts wrapper-arg `name` (an OCaml
     value) into the value the C function actually expects. *)
  let arg_unwrap env t name =
    match abi_of env t with
    | AInt | AFloat | ABool -> "ocaml_val(" ^ name ^ ")"
    | AStruct -> name ^ "[2]"     (* block {0, cdata} -> cdata *)
    | AVoid | APassthrough -> name

  (* How to re-tag a C return value back into the OCaml encoding the
     caller expects. *)
  let wrap_return env t expr_str =
    match abi_of env t with
    | AVoid   -> expr_str ^ "; return"
    | AInt    -> "return (" ^ expr_str ^ ") * 2"
    | ABool   -> "return (" ^ expr_str ^ ") and 2 or 0"
    | AFloat  -> "return { 253, " ^ expr_str ^ " }"
    | AStruct -> "return { 0, " ^ expr_str ^ " }"
    | APassthrough -> "return " ^ expr_str

  (* Sequence of (constructor_name, struct_def) for the simple structs
     in `structs`. Skips constructor emission if a function with the
     same name already exists (e.g. raylib has no `MakeColor`, but a
     header that does would otherwise produce duplicate externals).
     Order preserved for stable output. *)
  let constructors ~prefix ~fns env smap structs =
    let fn_names = Hashtbl.create 32 in
    List.iter (fun fn ->
      Hashtbl.replace fn_names
        (snake (strip_prefix prefix fn.name)) ()
    ) fns;
    List.filter_map (fun s ->
      if not (is_simple_struct env smap s) then None
      else
        let n = "make_" ^ snake s.sname in
        if Hashtbl.mem fn_names n then None else Some (n, s)
    ) structs

  (* Per-field accessor name: <struct>_<field> in snake_case. Field
     names are already snake_case in C; just normalize structs. *)
  let accessor_name s f =
    snake s.sname ^ "_" ^ snake f.fname

  (* All struct field accessors, in the order their structs appear.
     Emitted for any struct that has fields — even complex ones, since
     reading e.g. `image_width` is still useful even though Image as a
     whole has a `void *data` field that keeps it from being
     constructible.

     Skips an accessor if it would collide with a function name in
     `fns` (snake-cased, prefix-stripped). Raylib has e.g. an
     `ImageMipmaps` function AND an `Image.mipmaps` field — both would
     snake to `image_mipmaps`; we prefer the function. *)
  let accessors ~prefix ~fns structs =
    let fn_names = Hashtbl.create 64 in
    List.iter (fun fn ->
      Hashtbl.replace fn_names
        (snake (strip_prefix prefix fn.name)) ()
    ) fns;
    List.concat_map (fun s ->
      if s.fields = [] then []
      else
        List.filter_map (fun f ->
          let n = accessor_name s f in
          let is_array = match f.ftype with Array _ -> true | _ -> false in
          (* Skip arrays — they'd need a different API (return a Lua
             cdata array, not a single value). Skip name collisions
             with existing functions. *)
          if is_array || Hashtbl.mem fn_names n then None
          else Some (n, s, f)
        ) s.fields
    ) structs

  (* Parse a raw enum-value expression. We only handle plain decimal and
     hex literals (good enough for raylib.h's enums). Anything more
     complex falls back to "previous + 1" auto-increment. *)
  let parse_int_lit s =
    try Some (int_of_string (String.trim s))
    with _ -> None

  let enum_values e =
    let prev = ref (-1) in
    List.map (fun (name, raw) ->
      let v = match raw with
        | Some s ->
            (match parse_int_lit s with
             | Some n -> n
             | None -> !prev + 1)
        | None -> !prev + 1
      in
      prev := v;
      (name, v)
    ) e.consts

  let write_ml ~env ~smap ~prefix ~src ~fns ~structs ~enums out =
    Printf.fprintf out "(* Auto-generated from %s *)\n\n" src;
    (* Abstract type per struct, so signatures can reference them. *)
    List.iter (fun s ->
      Printf.fprintf out "type %s\n" (snake s.sname)
    ) structs;
    if structs <> [] then Printf.fprintf out "\n";
    (* Enum constants — one `let name = value` per constant, snake-
       cased. Computed expressions fall back to previous + 1. Names
       that would clash with OCaml's reserved words / built-in
       literals are skipped (the C-side `bool` fallback enum has
       `true` and `false` constants — those just shadow OCaml's). *)
    let ocaml_reserved =
      ["true"; "false"; "and"; "or"; "not"; "mod"; "land"; "lor";
       "lxor"; "lsl"; "lsr"; "asr"; "type"; "function"; "match";
       "with"; "let"; "in"; "val"; "do"; "done"; "then"; "else";
       "if"; "while"; "for"; "begin"; "end"; "rec"; "as"; "of";
       "open"; "module"; "struct"; "sig"; "fun"; "when"; "ref";
       "assert"; "lazy"; "include"; "object"; "class"; "method";
       "private"; "virtual"; "constraint"; "inherit"; "initializer";
       "new"; "object"; "to"; "downto"; "exception"; "external";
       "try"; "raise"]
    in
    List.iter (fun e ->
      List.iter (fun (name, v) ->
        let oname = snake name in
        if not (List.mem oname ocaml_reserved) then
          Printf.fprintf out "let %s = %d\n" oname v
      ) (enum_values e)
    ) enums;
    if enums <> [] then Printf.fprintf out "\n";
    (* Constructors for simple structs. *)
    List.iter (fun (cname, s) ->
      let arg_types =
        List.map (fun f -> Typ.ocaml_of env f.ftype) s.fields in
      let sig_ =
        String.concat " -> " (arg_types @ [snake s.sname]) in
      Printf.fprintf out "external %s : %s = \"%s\"\n" cname sig_ cname
    ) (constructors ~prefix ~fns env smap structs);
    if constructors ~prefix ~fns env smap structs <> []
    then Printf.fprintf out "\n";
    (* Field accessors: one external per struct field. Lets OCaml read
       fields of struct values returned by C, e.g. (vector2_x pos). *)
    let accs = accessors ~prefix ~fns structs in
    List.iter (fun (aname, s, f) ->
      Printf.fprintf out "external %s : %s -> %s = \"%s\"\n"
        aname (snake s.sname) (Typ.ocaml_of env f.ftype) aname
    ) accs;
    if accs <> [] then Printf.fprintf out "\n";
    (* Function externals. *)
    List.iter (fun fn ->
      let lname = snake (strip_prefix prefix fn.name) in
      let arg_types =
        match fn.params with
        | [] -> ["unit"]
        | ps -> List.map (fun p -> Typ.ocaml_of env p.ptype) ps
      in
      let sig_ = String.concat " -> "
                   (arg_types @ [Typ.ocaml_of env fn.ret]) in
      Printf.fprintf out "external %s : %s = \"%s\"\n" lname sig_ lname
    ) fns

  let write_c ~env ~smap ~prefix ~src ~fns ~structs out =
    Printf.fprintf out "/* Auto-generated from %s */\n" src;
    Printf.fprintf out "#include <caml/mlvalues.h>\n\n";
    (* Constructor stubs first. They're never executed; loo replaces
       them with direct Lua calls. *)
    List.iter (fun (cname, s) ->
      Printf.fprintf out "CAMLprim value %s(" cname;
      let n = List.length s.fields in
      if n = 0 then Printf.fprintf out "value v_unit"
      else List.iteri (fun i _ ->
        if i > 0 then Printf.fprintf out ",";
        Printf.fprintf out "value v%d" (i + 1)) s.fields;
      Printf.fprintf out ") { ";
      if n = 0 then Printf.fprintf out "(void)v_unit; "
      else List.iteri (fun i _ ->
        Printf.fprintf out "(void)v%d; " (i + 1)) s.fields;
      Printf.fprintf out "return Val_int(0); }\n"
    ) (constructors ~prefix ~fns env smap structs);
    (* Accessor stubs (also never executed). *)
    List.iter (fun (aname, _s, _f) ->
      Printf.fprintf out
        "CAMLprim value %s(value v1) { (void)v1; return Val_int(0); }\n"
        aname
    ) (accessors ~prefix ~fns structs);
    List.iter (fun fn ->
      let lname = snake (strip_prefix prefix fn.name) in
      Printf.fprintf out "CAMLprim value %s(" lname;
      let n = List.length fn.params in
      (if n = 0 then Printf.fprintf out "value v_unit"
       else List.iteri (fun i _ ->
              if i > 0 then Printf.fprintf out ",";
              Printf.fprintf out "value v%d" (i + 1)) fn.params);
      Printf.fprintf out ") { ";
      if n = 0 then Printf.fprintf out "(void)v_unit; "
      else List.iteri (fun i _ ->
             Printf.fprintf out "(void)v%d; " (i + 1)) fn.params;
      (match fn.ret with
       | Void -> Printf.fprintf out "return Val_unit;"
       | Bool -> Printf.fprintf out "return Val_bool(0);"
       | _    -> Printf.fprintf out "return Val_int(0);");
      Printf.fprintf out " }\n"
    ) fns

  (* For struct-by-value fields we want the underlying C type for the
     ffi.cdef, but in struct *expressions* (like ffi.new("RenderTexture",
     {id, tex_cdata, depth_cdata})) we just hand over the cdata
     unchanged. The Lua emitter already strips the wrapper before
     passing values to C, so no special handling is needed here. *)

  let write_lua ~env ~smap ~prefix ~lib ~src ~fns ~structs ~tops out =
    Printf.fprintf out "-- Auto-generated from %s\n" src;
    Printf.fprintf out "local ffi = require(\"ffi\")\n\n";
    Printf.fprintf out "ffi.cdef([[\n";
    (* Structs and aliases interleaved in source order — a later struct
       can have a field of type EarlierAlias, so we can't separate them
       into two phases. (E.g. `typedef Texture Texture2D;` between the
       Texture and Font definitions, where Font has a Texture2D field.) *)
    let any_type = ref false in
    List.iter (function
      | Struct s when s.fields <> [] ->
          any_type := true;
          Printf.fprintf out "  typedef struct %s {\n" s.sname;
          List.iter (fun f ->
            (* Arrays are written with the [N] suffix in field position,
             not as a pointer — that's how C declares them and what
             ffi.cdef expects for inline struct layout. *)
          (match f.ftype with
           | Array (inner, Some n) ->
               Printf.fprintf out "    %s %s[%d];\n" (c_of inner) f.fname n
           | Array (inner, None) ->
               Printf.fprintf out "    %s %s[];\n" (c_of inner) f.fname
           | _ ->
               Printf.fprintf out "    %s %s;\n" (c_of f.ftype) f.fname)
          ) s.fields;
          Printf.fprintf out "  } %s;\n" s.sname
      | Struct s ->
          (* Empty struct = forward declaration. Emit as opaque so other
             types referring to `Foo *` resolve. *)
          any_type := true;
          Printf.fprintf out "  typedef struct %s %s;\n" s.sname s.sname
      | Alias (name, t) ->
          any_type := true;
          Printf.fprintf out "  typedef %s %s;\n" (c_of t) name
      | Callback (name, _, _) ->
          (* LuaJIT FFI doesn't support va_list and we don't actually
             round-trip OCaml callbacks through the C side yet, so
             expose them as opaque void* for now. *)
          any_type := true;
          Printf.fprintf out "  typedef void* %s;\n" name
      | _ -> ()
    ) tops;
    if !any_type then Printf.fprintf out "\n";
    List.iter (fun fn ->
      Printf.fprintf out "  %s %s(" (c_of fn.ret) fn.name;
      (match fn.params with
       | [] -> Printf.fprintf out "void"
       | ps ->
           List.iteri (fun i p ->
             if i > 0 then Printf.fprintf out ", ";
             Printf.fprintf out "%s %s" (c_of p.ptype)
               (if p.pname = "" then Printf.sprintf "a%d" (i + 1)
                else p.pname)) ps);
      Printf.fprintf out ");\n"
    ) fns;
    (match lib with
     | None ->
         Printf.fprintf out "]])\n\nlocal C = ffi.C\n\n"
     | Some name ->
         Printf.fprintf out "]])\n\nlocal C = ffi.load(\"%s\")\n\n" name);

    Printf.fprintf out
      "local function ocaml_val(v)\n\
      \  if type(v) == \"number\" then return v / 2 end\n\
      \  if type(v) == \"table\" and v[1] == 253 then return v[2] or 0 end\n\
      \  return v\n\
       end\n\n";

    (* Struct constructors. *)
    let ctors = constructors ~prefix ~fns env smap structs in
    if ctors <> [] then
      Printf.fprintf out "-- Struct constructors\n";
    List.iter (fun (cname, s) ->
      let params =
        String.concat ","
          (List.mapi (fun i _ -> Printf.sprintf "a%d" (i + 1)) s.fields) in
      let args =
        String.concat ", "
          (List.mapi (fun i f ->
             let aname = Printf.sprintf "a%d" (i + 1) in
             arg_unwrap env f.ftype aname) s.fields) in
      Printf.fprintf out
        "function %s(%s) return { 0, ffi.new(\"%s\", { %s }) } end\n"
        cname params s.sname args
    ) ctors;
    if ctors <> [] then Printf.fprintf out "\n";

    (* Field accessors: unwrap struct block, access field, re-tag based
       on the field's C type. Reuses wrap_return so int -> *2, float ->
       {253,v}, nested struct -> {0,cdata}, etc. *)
    let accs = accessors ~prefix ~fns structs in
    if accs <> [] then Printf.fprintf out "-- Field accessors\n";
    List.iter (fun (aname, _s, f) ->
      let expr = Printf.sprintf "a1[2].%s" f.fname in
      let body = wrap_return env f.ftype expr in
      Printf.fprintf out "function %s(a1) %s end\n" aname body
    ) accs;
    if accs <> [] then Printf.fprintf out "\n";

    Printf.fprintf out
      "-- Wrappers (OCaml external -> C call with value conversion)\n";
    List.iter (fun fn ->
      let lname = snake (strip_prefix prefix fn.name) in
      let n = List.length fn.params in
      let params_str =
        if n = 0 then ""
        else
          String.concat ","
            (List.mapi (fun i _ -> Printf.sprintf "a%d" (i + 1)) fn.params)
      in
      let args_str =
        String.concat ", "
          (List.mapi (fun i p ->
             let aname = Printf.sprintf "a%d" (i + 1) in
             arg_unwrap env p.ptype aname) fn.params)
      in
      let call = Printf.sprintf "C.%s(%s)" fn.name args_str in
      let body = wrap_return env fn.ret call in
      Printf.fprintf out "function %s(%s) %s end\n" lname params_str body
    ) fns
end

(* ================================================================== *)
(* Lua 5.1 lexer                                                       *)
(* ================================================================== *)

module Lua_lex = struct
  type tok =
    | LIdent  of string
    | LKw     of string                  (* reserved word *)
    | LStr    of string                  (* contents of "..." or '...' *)
    | LLStr   of string                  (* contents of [[ ... ]] / [=[ ]=] *)
    | LNum    of string
    | LLP | LRP                          (* ( ) *)
    | LLB | LRB                          (* { } *)
    | LLBK | LRBK                        (* [ ] *)
    | LComma | LSemi | LColon | LDColon
    | LDot | LDDot | LDDDot              (* . .. ... *)
    | LAssign                            (* = *)
    | LEq | LNeq | LLt | LGt | LLe | LGe
    | LPlus | LMinus | LStar | LSlash | LPct | LCaret | LHash
    | LOther of char

  let keywords = [
    "and"; "break"; "do"; "else"; "elseif"; "end"; "false"; "for";
    "function"; "goto"; "if"; "in"; "local"; "nil"; "not"; "or";
    "repeat"; "return"; "then"; "true"; "until"; "while"
  ]

  let is_ident_start c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '_'
  let is_ident_cont c =
    is_ident_start c || (c >= '0' && c <= '9')
  let is_digit c = c >= '0' && c <= '9'

  (* `[==[ ... ]==]` long bracket. Returns (level, body) starting at the
     leading `[`. If not a long bracket, returns None and leaves the
     cursor untouched. *)
  let try_long_bracket s i =
    let n = String.length s in
    if !i >= n || s.[!i] <> '[' then None
    else begin
      let save = !i in
      let j = ref (!i + 1) in
      let level = ref 0 in
      while !j < n && s.[!j] = '=' do incr j; incr level done;
      if !j >= n || s.[!j] <> '[' then (i := save; None)
      else begin
        let body_start = !j + 1 in
        (* Skip an immediately-following newline per Lua spec. *)
        let body_start =
          if body_start < n && s.[body_start] = '\n' then body_start + 1
          else body_start in
        let k = ref body_start in
        let found = ref None in
        while !found = None && !k < n do
          if s.[!k] = ']' then begin
            let m = ref (!k + 1) in
            let lvl = ref 0 in
            while !m < n && s.[!m] = '=' do incr m; incr lvl done;
            if !lvl = !level && !m < n && s.[!m] = ']'
            then found := Some (!k, !m + 1)
            else incr k
          end else incr k
        done;
        match !found with
        | Some (close_pos, after) ->
            let body = String.sub s body_start (close_pos - body_start) in
            i := after;
            Some (!level, body)
        | None ->
            (* Unterminated — treat as not a long bracket. *)
            i := save; None
      end
    end

  let try_long_comment s i =
    (* Already past the leading `--`. *)
    try_long_bracket s i

  let read_short_string s i quote =
    let n = String.length s in
    let buf = Buffer.create 16 in
    incr i;  (* skip opening quote *)
    while !i < n && s.[!i] <> quote do
      if s.[!i] = '\\' && !i + 1 < n then begin
        let c = s.[!i + 1] in
        let translated = match c with
          | 'n' -> "\n" | 't' -> "\t" | 'r' -> "\r"
          | '\\' -> "\\" | '\'' -> "'" | '"' -> "\""
          | '0' -> "\000"
          | _ -> String.make 1 c
        in
        Buffer.add_string buf translated;
        i := !i + 2
      end else if s.[!i] = '\n' then begin
        (* unterminated string — bail to avoid spinning *)
        i := n
      end else begin
        Buffer.add_char buf s.[!i]; incr i
      end
    done;
    if !i < n then incr i;  (* skip closing quote *)
    Buffer.contents buf

  let read_number s i =
    let n = String.length s in
    let start = !i in
    (* hex prefix *)
    if !i + 1 < n && s.[!i] = '0' && (s.[!i + 1] = 'x' || s.[!i + 1] = 'X')
    then begin
      i := !i + 2;
      while !i < n && (is_digit s.[!i] ||
                       (s.[!i] >= 'a' && s.[!i] <= 'f') ||
                       (s.[!i] >= 'A' && s.[!i] <= 'F') ||
                       s.[!i] = '.' || s.[!i] = 'p' || s.[!i] = 'P' ||
                       s.[!i] = '+' || s.[!i] = '-') do incr i done
    end else begin
      while !i < n && (is_digit s.[!i] || s.[!i] = '.' ||
                       s.[!i] = 'e' || s.[!i] = 'E' ||
                       (((!i > start) && (s.[!i-1] = 'e' || s.[!i-1] = 'E'))
                        && (s.[!i] = '+' || s.[!i] = '-'))) do incr i done
    end;
    String.sub s start (!i - start)

  let tokens src =
    let n = String.length src in
    let i = ref 0 in
    let out = ref [] in
    let push t = out := t :: !out in
    while !i < n do
      let c = src.[!i] in
      match c with
      | ' ' | '\t' | '\n' | '\r' -> incr i
      | '-' when !i + 1 < n && src.[!i + 1] = '-' ->
          (* comment: '--' followed by either long bracket or to EOL *)
          i := !i + 2;
          (match try_long_comment src i with
           | Some _ -> ()
           | None ->
               while !i < n && src.[!i] <> '\n' do incr i done)
      | '-' -> push LMinus; incr i
      | '+' -> push LPlus;  incr i
      | '*' -> push LStar;  incr i
      | '/' -> push LSlash; incr i
      | '%' -> push LPct;   incr i
      | '^' -> push LCaret; incr i
      | '#' -> push LHash;  incr i
      | '(' -> push LLP;    incr i
      | ')' -> push LRP;    incr i
      | '{' -> push LLB;    incr i
      | '}' -> push LRB;    incr i
      | ']' -> push LRBK;   incr i
      | ',' -> push LComma; incr i
      | ';' -> push LSemi;  incr i
      | ':' when !i + 1 < n && src.[!i + 1] = ':' ->
          push LDColon; i := !i + 2
      | ':' -> push LColon; incr i
      | '=' when !i + 1 < n && src.[!i + 1] = '=' ->
          push LEq; i := !i + 2
      | '=' -> push LAssign; incr i
      | '~' when !i + 1 < n && src.[!i + 1] = '=' ->
          push LNeq; i := !i + 2
      | '<' when !i + 1 < n && src.[!i + 1] = '=' ->
          push LLe; i := !i + 2
      | '<' -> push LLt; incr i
      | '>' when !i + 1 < n && src.[!i + 1] = '=' ->
          push LGe; i := !i + 2
      | '>' -> push LGt; incr i
      | '.' when !i + 2 < n && src.[!i + 1] = '.' && src.[!i + 2] = '.' ->
          push LDDDot; i := !i + 3
      | '.' when !i + 1 < n && src.[!i + 1] = '.' ->
          push LDDot; i := !i + 2
      | '.' when !i + 1 < n && is_digit src.[!i + 1] ->
          push (LNum (read_number src i))
      | '.' -> push LDot; incr i
      | '"' -> push (LStr (read_short_string src i '"'))
      | '\'' -> push (LStr (read_short_string src i '\''))
      | '[' ->
          (match try_long_bracket src i with
           | Some (_lvl, body) -> push (LLStr body)
           | None -> push LLBK; incr i)
      | c when is_ident_start c ->
          let start = !i in
          while !i < n && is_ident_cont src.[!i] do incr i done;
          let w = String.sub src start (!i - start) in
          if List.mem w keywords then push (LKw w) else push (LIdent w)
      | c when is_digit c ->
          push (LNum (read_number src i))
      | c -> push (LOther c); incr i
    done;
    List.rev !out
end

(* ================================================================== *)
(* Lua AST + parser                                                    *)
(* ================================================================== *)

module Lua_ast = struct
  (* A "function path" denotes the name a `function` declaration is
     bound to. Possible shapes:
       local function f(...) end          -> { path=[f]; method=false; local_=true }
       function f(...) end                -> { path=[f]; method=false }
       function a.b.c(...) end            -> { path=[a;b;c]; method=false }
       function a.b:m(...) end            -> { path=[a;b]; method=Some m }
  *)
  type fn_path = {
    path   : string list;
    method_: string option;
    local_ : bool;
  }

  type fn = {
    fp     : fn_path;
    params : string list;
    has_vararg : bool;
    line   : int;        (* 1-based line of `function` keyword, 0 if unknown *)
  }

  (* `pcall(ffi.cdef, [[...]])` and `ffi.cdef([[...]])` etc. yield a
     Cdef carrying the raw embedded C source. *)
  type top =
    | Fn   of fn
    | Cdef of string
end

module Lua_parse = struct
  open Lua_lex
  open Lua_ast

  type st = {
    mutable toks : tok list;
  }

  let peek st = match st.toks with [] -> None | t :: _ -> Some t
  let peek2 st = match st.toks with _ :: t :: _ -> Some t | _ -> None
  let advance st = match st.toks with [] -> () | _ :: r -> st.toks <- r

  (* Skip until we hit something that can't be the continuation of the
     current expression. Lua has no required statement terminator, so
     the boundary has to be inferred from what comes next. We stop on:
       - `,` `;` `)` `]` `}` at top depth (end of expression list);
       - block-ending keywords (`end`, `then`, ...);
       - statement-starting keywords (`local`, `if`, `for`, ...) at top
         depth — these can't appear inside an expression;
       - `function` followed by an identifier — that's the next
         statement, NOT an anonymous-function expression (which is
         `function` followed by `(`).
     Anonymous functions `function() ... end` are tracked with their
     own depth so we don't get fooled by the `end` keyword inside them.
  *)
  let skip_expr st =
    let depth = ref 0 in
    let fn_depth = ref 0 in
    let going = ref true in
    while !going do
      match peek st with
      | None -> going := false
      | Some t ->
          (match t with
           | LLP | LLB | LLBK -> incr depth; advance st
           | LRP | LRB | LRBK ->
               if !depth = 0 then going := false
               else (decr depth; advance st)
           | LKw "function" when !depth = 0 && !fn_depth = 0 ->
               (match peek2 st with
                | Some LLP -> incr fn_depth; advance st
                | _ -> going := false)
           | LKw "function" -> incr fn_depth; advance st
           | LKw "end" when !fn_depth > 0 -> decr fn_depth; advance st
           | LComma | LSemi when !depth = 0 && !fn_depth = 0 ->
               going := false
           | LKw ("local" | "if" | "for" | "while" | "do" | "repeat"
                  | "return" | "break" | "goto")
             when !depth = 0 && !fn_depth = 0 -> going := false
           | LKw ("end" | "then" | "else" | "elseif" | "until")
             when !depth = 0 && !fn_depth = 0 -> going := false
           | _ -> advance st)
    done

  (* Consume tokens up to and including the matching closer of the
     block we're currently inside (the caller already consumed the
     opening keyword and pushed it onto the stack).

     Tracking has to be a stack rather than a depth counter because of
     `for ... do ... end` and `while ... do ... end`, which open ONE
     block with two keywords. We mark the `do` belonging to a for/while
     so it doesn't get counted as a fresh `do ... end` block. *)
  type opener = OFn | OIf | OForWhile | OForWhileDo | ODo | ORepeat

  let skip_block_to_end st =
    let stack = ref [OFn] in
    while !stack <> [] do
      match peek st with
      | None -> stack := []
      | Some t ->
          advance st;
          (match t with
           | LKw "function" -> stack := OFn :: !stack
           | LKw "if"       -> stack := OIf :: !stack
           | LKw ("for" | "while") -> stack := OForWhile :: !stack
           | LKw "do" ->
               (match !stack with
                | OForWhile :: rest -> stack := OForWhileDo :: rest
                | _ -> stack := ODo :: !stack)
           | LKw "repeat" -> stack := ORepeat :: !stack
           | LKw "until" ->
               (match !stack with
                | ORepeat :: rest -> stack := rest
                | _ -> ())
           | LKw "end" ->
               (match !stack with _ :: rest -> stack := rest | [] -> ())
           | _ -> ())
    done

  (* `function NAME (params) body end`. The `function` keyword has been
     consumed; if `is_local`, the `local` keyword too. Returns the
     Fn record. *)
  let parse_function st ~is_local =
    (* Function name path: ident ( '.' ident )* ( ':' ident )? *)
    let path = ref [] in
    let method_ = ref None in
    let bail = ref false in
    (match peek st with
     | Some (LIdent n) -> advance st; path := [n]
     | _ -> bail := true);
    if not !bail then begin
      let going = ref true in
      while !going do
        match peek st with
        | Some LDot ->
            advance st;
            (match peek st with
             | Some (LIdent n) -> advance st; path := n :: !path
             | _ -> going := false)
        | Some LColon ->
            advance st;
            (match peek st with
             | Some (LIdent n) -> advance st; method_ := Some n
             | _ -> ());
            going := false
        | _ -> going := false
      done
    end;
    (* Params: '(' [ name [, name]* [, ...] | ... ] ')' *)
    let params = ref [] in
    let has_vararg = ref false in
    (match peek st with
     | Some LLP ->
         advance st;
         let going = ref true in
         while !going do
           (match peek st with
            | Some (LIdent n) ->
                advance st; params := n :: !params;
                (match peek st with
                 | Some LComma -> advance st
                 | _ -> going := false)
            | Some LDDDot ->
                advance st; has_vararg := true; going := false
            | _ -> going := false)
         done;
         (match peek st with Some LRP -> advance st | _ -> ())
     | _ -> ());
    (* Body: skip until matching `end`. *)
    skip_block_to_end st;
    let fp = {
      path = List.rev !path;
      method_ = !method_;
      local_ = is_local;
    } in
    { fp; params = List.rev !params; has_vararg = !has_vararg; line = 0 }

  (* Detect `pcall(ffi.cdef, <string>)` or `ffi.cdef(<string>)` or
     `ffi.cdef <string>` (Lua's no-paren single-arg call). When the
     current token is the leading identifier of such a call, parse it
     and return Some cdef_body; otherwise return None and rewind. *)
  let try_cdef_call st : string option =
    let saved = st.toks in
    let extract_string () =
      match peek st with
      | Some (LStr s) -> advance st; Some s
      | Some (LLStr s) -> advance st; Some s
      | _ -> None
    in
    let read_dotted () =
      (* read `a.b.c` returning the list *)
      let acc = ref [] in
      (match peek st with
       | Some (LIdent n) -> advance st; acc := [n]
       | _ -> ());
      let going = ref true in
      while !going do
        match peek st, peek2 st with
        | Some LDot, Some (LIdent n) ->
            advance st; advance st; acc := n :: !acc
        | _ -> going := false
      done;
      List.rev !acc
    in
    let is_cdef_path = function
      | ["ffi"; "cdef"] | ["cdef"] -> true
      | _ -> false
    in
    let path = read_dotted () in
    match path with
    | ["pcall"] ->
        (* pcall(ffi.cdef, "..." | [[...]] ) *)
        (match peek st with
         | Some LLP ->
             advance st;
             let inner = read_dotted () in
             if is_cdef_path inner then begin
               (match peek st with
                | Some LComma ->
                    advance st;
                    let r = extract_string () in
                    (match peek st with
                     | Some LRP -> advance st | _ -> ());
                    (match r with
                     | Some s -> Some s
                     | None -> st.toks <- saved; None)
                | _ -> st.toks <- saved; None)
             end else (st.toks <- saved; None)
         | _ -> st.toks <- saved; None)
    | p when is_cdef_path p ->
        (* ffi.cdef("...") or ffi.cdef "..." or ffi.cdef [[...]] *)
        (match peek st with
         | Some LLP ->
             advance st;
             let r = extract_string () in
             (match peek st with Some LRP -> advance st | _ -> ());
             (match r with
              | Some s -> Some s
              | None -> st.toks <- saved; None)
         | Some (LStr _) | Some (LLStr _) -> extract_string ()
         | _ -> st.toks <- saved; None)
    | _ -> st.toks <- saved; None

  let parse_unit toks =
    let st = { toks } in
    let out = ref [] in
    let going = ref true in
    while !going do
      match peek st with
      | None -> going := false
      | Some (LKw "function") ->
          advance st;
          out := Fn (parse_function st ~is_local:false) :: !out
      | Some (LKw "local") ->
          (* `local function f(...) end` or `local x = ...` *)
          advance st;
          (match peek st with
           | Some (LKw "function") ->
               advance st;
               out := Fn (parse_function st ~is_local:true) :: !out
           | _ ->
               (* skip statement: identifiers, optional `= ...` *)
               skip_expr st;
               (match peek st with Some LSemi -> advance st | _ -> ()))
      | Some (LIdent _) ->
          (* Statement starts with an expression. Could be a function
             call we want (pcall/ffi.cdef) or a plain assignment. *)
          (match try_cdef_call st with
           | Some body -> out := Cdef body :: !out
           | None ->
               (* not a cdef; skip the statement *)
               skip_expr st;
               (match peek st with Some LSemi -> advance st | _ -> ()))
      | Some (LKw ("if" | "for" | "while" | "do" | "repeat")) ->
          (* Skip top-level control blocks. (LÖVE wrap files don't
             define bindable functions inside these, but if they ever
             do, this is the seam to descend into instead of skipping.) *)
          advance st;
          skip_block_to_end st
      | Some (LKw "return") ->
          advance st;
          skip_expr st;
          (match peek st with Some LSemi -> advance st | _ -> ())
      | Some LSemi -> advance st
      | Some _ -> advance st
    done;
    List.rev !out

  (* Convenience: filter unit to just fn declarations whose path makes
     them a candidate for binding (anything that's `module.fn` or
     `Class:method`, but not local helpers). *)
  let public_fns tops =
    List.filter_map (function
      | Fn f when not f.fp.local_ &&
                  (f.fp.path <> [] || f.fp.method_ <> None) -> Some f
      | _ -> None) tops

  let cdef_blocks tops =
    List.filter_map (function Cdef s -> Some s | _ -> None) tops
end

(* ================================================================== *)
(* Lua-input emitter                                                   *)
(* ================================================================== *)
(* Type info cannot be recovered from Lua source — we know names and
   arity, not whether `l` in `random(l, u)` is an int or float. So we
   emit conservative defaults: all args float, all returns float,
   method-receivers as an abstract class type. The output is a
   binding *skeleton* the user edits.

   ffi.cdef blobs found inside the Lua source are concatenated into a
   single block in the generated _bindings.lua, so LuaJIT still sees
   the C type definitions the source declared. *)

module Lua_emit = struct
  open Lua_ast

  (* Flat external name for an OCaml-visible function.
       love_math.random       -> love_math_random
       love.event.poll        -> love_event_poll
       RandomGenerator:random -> random_generator_random           *)
  let ext_name fp =
    let p = String.concat "_" (List.map Typ.snake fp.path) in
    match fp.method_ with
    | Some m -> p ^ "_" ^ Typ.snake m
    | None -> p

  (* When fp is a method, the receiver class identifier (used both as
     the OCaml type name and to dispatch on the Lua side). *)
  let receiver_class fp =
    match fp.method_, List.rev fp.path with
    | Some _, last :: _ -> Some last
    | _ -> None

  let classes fns =
    (* Distinct class names in encounter order *)
    let seen = Hashtbl.create 8 in
    List.filter_map (fun f ->
      match receiver_class f.fp with
      | Some c when not (Hashtbl.mem seen c) ->
          Hashtbl.add seen c (); Some c
      | _ -> None
    ) fns

  (* LÖVE wrap files routinely define the same function twice (e.g.
     one branch for JIT, one for non-JIT). Lua semantics: the latter
     wins. OCaml can't have duplicate externals at all, so we drop
     earlier duplicates and keep the last occurrence. *)
  let dedup_fns fns =
    let total = Hashtbl.create 32 in
    List.iter (fun f ->
      let k = ext_name f.fp in
      Hashtbl.replace total k
        (1 + (try Hashtbl.find total k with Not_found -> 0))
    ) fns;
    let seen = Hashtbl.create 32 in
    List.filter (fun f ->
      let k = ext_name f.fp in
      let i = (try Hashtbl.find seen k with Not_found -> 0) + 1 in
      Hashtbl.replace seen k i;
      i = Hashtbl.find total k
    ) fns

  let write_ml ~src ~fns out =
    let fns = dedup_fns fns in
    Printf.fprintf out "(* Auto-generated from %s *)\n" src;
    Printf.fprintf out "(* All signatures are conservative defaults — \
                        edit as needed. *)\n\n";
    let cs = classes fns in
    List.iter (fun c -> Printf.fprintf out "type %s\n" (Typ.snake c)) cs;
    if cs <> [] then Printf.fprintf out "\n";
    List.iter (fun f ->
      let name = ext_name f.fp in
      let self_arg = match receiver_class f.fp with
        | Some c -> [Typ.snake c]
        | None -> [] in
      let arg_count = List.length f.params in
      let other_args = List.init arg_count (fun _ -> "float") in
      let args = self_arg @ other_args in
      let args = if args = [] then ["unit"] else args in
      let sig_ = String.concat " -> " (args @ ["float"]) in
      Printf.fprintf out "external %s : %s = \"%s\"\n" name sig_ name
    ) fns

  let write_c ~src ~fns out =
    let fns = dedup_fns fns in
    Printf.fprintf out "/* Auto-generated from %s */\n" src;
    Printf.fprintf out "#include <caml/mlvalues.h>\n\n";
    List.iter (fun f ->
      let name = ext_name f.fp in
      let has_self = receiver_class f.fp <> None in
      let arg_count =
        (if has_self then 1 else 0) + List.length f.params in
      Printf.fprintf out "CAMLprim value %s(" name;
      if arg_count = 0 then Printf.fprintf out "value v_unit"
      else for i = 1 to arg_count do
        if i > 1 then Printf.fprintf out ",";
        Printf.fprintf out "value v%d" i
      done;
      Printf.fprintf out ") { ";
      if arg_count = 0 then Printf.fprintf out "(void)v_unit; "
      else for i = 1 to arg_count do
        Printf.fprintf out "(void)v%d; " i
      done;
      (* default return: boxed float so it parses as a float OCaml
         value; the user re-tags if they change the return type *)
      Printf.fprintf out "return Val_int(0); }\n"
    ) fns

  let write_lua ~src ~fns ~cdefs out =
    let fns = dedup_fns fns in
    Printf.fprintf out "-- Auto-generated from %s\n" src;
    Printf.fprintf out "-- Conservative wrappers: all args unwrapped \
                        as numbers, all returns boxed as floats.\n";
    Printf.fprintf out "-- Edit the per-fn conversion as the OCaml \
                        signatures sharpen.\n\n";
    if cdefs <> [] then begin
      Printf.fprintf out "local ffi = require(\"ffi\")\n\n";
      Printf.fprintf out "ffi.cdef([[\n";
      List.iter (fun c -> Printf.fprintf out "%s\n" c) cdefs;
      Printf.fprintf out "]])\n\n"
    end;
    Printf.fprintf out
      "local function ocaml_val(v)\n\
      \  if type(v) == \"number\" then return v / 2 end\n\
      \  if type(v) == \"table\" and v[1] == 253 then return v[2] or 0 end\n\
      \  return v\n\
       end\n\n";
    List.iter (fun f ->
      let name = ext_name f.fp in
      let has_self = receiver_class f.fp <> None in
      let arg_count =
        (if has_self then 1 else 0) + List.length f.params in
      let params =
        String.concat ","
          (List.init arg_count (fun i -> Printf.sprintf "a%d" (i + 1))) in
      let call =
        if has_self then begin
          let method_ = match f.fp.method_ with Some m -> m | None -> "" in
          let other_args =
            String.concat ", "
              (List.mapi (fun i _ ->
                 Printf.sprintf "ocaml_val(a%d)" (i + 2)) f.params) in
          Printf.sprintf "a1[2]:%s(%s)" method_ other_args
        end else begin
          let lua_target = String.concat "." f.fp.path in
          let args_str =
            String.concat ", "
              (List.mapi (fun i _ ->
                 Printf.sprintf "ocaml_val(a%d)" (i + 1)) f.params) in
          Printf.sprintf "%s(%s)" lua_target args_str
        end
      in
      Printf.fprintf out "function %s(%s) return { 253, %s } end\n"
        name params call
    ) fns
end

(* ================================================================== *)
(* CLI                                                                 *)
(* ================================================================== *)

let prefix = ref ""
let out_dir = ref "."
let lib = ref ""
let remaining = ref []

let join dir name =
  if dir = "" || dir = "." then name
  else Filename.concat dir name

(* Create the output directory (with intermediate dirs) if it doesn't
   exist already. Delegates to /bin/mkdir -p so we don't have to walk
   the path ourselves; Filename.quote keeps it shell-safe. *)
let ensure_dir dir =
  if dir <> "" && dir <> "." && not (Sys.file_exists dir) then
    let cmd = Printf.sprintf "mkdir -p %s" (Filename.quote dir) in
    if Sys.command cmd <> 0 then
      (Printf.eprintf "luabingen: failed to create out-dir %s\n" dir;
       exit 1)

let process_c_header header =
  ensure_dir !out_dir;
  let base = Filename.chop_extension (Filename.basename header) in
  let ic = open_in header in
  let n = in_channel_length ic in
  let raw = really_input_string ic n in
  close_in ic;

  let source = Pp.run raw in
  let toks = Lex.tokens source in
  let tops = Parse.parse_unit toks in
  let env = Typ.make_env tops in
  let smap = Emit.struct_map tops in

  let prefix = String.trim !prefix in

  let fns = List.filter_map
              (function Ast.Fn f -> Some f | _ -> None) tops in
  let structs = List.filter_map
                  (function Ast.Struct s -> Some s | _ -> None) tops in
  let aliases = List.filter_map
                  (function Ast.Alias (n, t) -> Some (n, t) | _ -> None)
                  tops in
  let enums = List.filter_map
                (function Ast.Enum e -> Some e | _ -> None) tops in
  let simple_n =
    List.length (List.filter (Emit.is_simple_struct env smap) structs) in

  Printf.eprintf
    "[C] %d function decls, %d structs (%d simple), %d enums from %s\n"
    (List.length fns) (List.length structs) simple_n
    (List.length enums)
    (Filename.basename header);

  let ml_path  = join !out_dir (base ^ "_external.ml") in
  let c_path   = join !out_dir (base ^ "_stubs.c") in
  let lua_path = join !out_dir (base ^ "_bindings.lua") in

  let oc = open_out ml_path in
  Emit.write_ml ~env ~smap ~prefix ~src:(Filename.basename header)
    ~fns ~structs ~enums oc;
  close_out oc;
  Printf.printf "Wrote %s\n" ml_path;

  let oc = open_out c_path in
  Emit.write_c ~env ~smap ~prefix ~src:(Filename.basename header)
    ~fns ~structs oc;
  close_out oc;
  Printf.printf "Wrote %s\n" c_path;

  let oc = open_out lua_path in
  let lib_opt = if !lib = "" then None else Some !lib in
  Emit.write_lua ~env ~smap ~prefix ~lib:lib_opt
    ~src:(Filename.basename header) ~fns ~structs ~tops oc;
  close_out oc;
  let _ = aliases in
  Printf.printf "Wrote %s\n" lua_path

let process_lua_source path =
  ensure_dir !out_dir;
  let base = Filename.chop_extension (Filename.basename path) in
  let ic = open_in path in
  let n = in_channel_length ic in
  let raw = really_input_string ic n in
  close_in ic;
  let toks = Lua_lex.tokens raw in
  let tops = Lua_parse.parse_unit toks in
  let fns = Lua_parse.public_fns tops in
  let cdefs = Lua_parse.cdef_blocks tops in
  Printf.eprintf "[Lua] %d public fn decls, %d ffi.cdef blocks from %s\n"
    (List.length fns) (List.length cdefs) (Filename.basename path);

  let ml_path  = join !out_dir (base ^ "_external.ml") in
  let c_path   = join !out_dir (base ^ "_stubs.c") in
  let lua_path = join !out_dir (base ^ "_bindings.lua") in

  let oc = open_out ml_path in
  Lua_emit.write_ml ~src:(Filename.basename path) ~fns oc;
  close_out oc;
  Printf.printf "Wrote %s\n" ml_path;

  let oc = open_out c_path in
  Lua_emit.write_c ~src:(Filename.basename path) ~fns oc;
  close_out oc;
  Printf.printf "Wrote %s\n" c_path;

  let oc = open_out lua_path in
  Lua_emit.write_lua ~src:(Filename.basename path) ~fns ~cdefs oc;
  close_out oc;
  Printf.printf "Wrote %s\n" lua_path

let () =
  Arg.parse
    [ "--prefix",  Arg.Set_string prefix,
      " Function name prefix to strip (e.g. \"RLAPI \")";
      "--out-dir", Arg.Set_string out_dir,
      " Directory to write generated files into (default: cwd)";
      "--lib",     Arg.Set_string lib,
      " Library to ffi.load (default: use ffi.C, which assumes the lib \
        is already loaded in-process)" ]
    (fun s -> remaining := s :: !remaining)
    "luabingen [opts] <file.h | file.lua>";

  let args = List.rev !remaining in
  if args = [] then
    (Printf.eprintf
       "Usage: luabingen [--prefix PFX] [--out-dir DIR] [--lib NAME] \
        <file.h | file.lua>\n";
     exit 1);

  let input = List.hd args in
  let ext = String.lowercase_ascii (Filename.extension input) in
  match ext with
  | ".lua" -> process_lua_source input
  | _ -> process_c_header input
