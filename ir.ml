(*pp deriving *)
(** Monadic IR *)

open Utility
open PP

type scope = Var.scope
  deriving (Show, Pickle)
(* term variables *)
type var = Var.var
  deriving (Show, Pickle)
type var_info = Var.var_info
  deriving (Show, Pickle)
type binder = Var.binder
  deriving (Show, Pickle)

(* type variables *)
type tyvar = Types.quantifier
  deriving (Show, Pickle)
type tyarg = Types.type_arg
  deriving (Show, Pickle)

type name = string
  deriving (Show, Pickle)
type 'a name_map = 'a Utility.stringmap
  deriving (Show, Pickle)

type language = string
  deriving (Show, Pickle)

let var_of_binder (x, _) = x

type constant = Constant.constant
  deriving (Show, Pickle)

type location = Syntax.location
  deriving (Show, Pickle)

type value =
  [ `Constant of constant
  | `Variable of var
  | `Extend of (value name_map * value option)
  | `Project of (name * value)
  | `Erase of (name * value)
  | `Inject of (name * value * Types.datatype)

  | `TAbs of tyvar list * value
  | `TApp of value * tyarg list

  | `XmlNode of (name * value name_map * value list)
  | `ApplyPure of (value * value list)
  (* should really be implemented as constants *)
  | `Comparison of (value * Syntaxutils.comparison * value)

  | `Coerce of (value * Types.datatype)
  | `Abs of value
  ]
and tail_computation =
  [ `Return of (value)
  | `Apply of (value * value list)

  | `Special of special

  | `Case of (value * (binder * computation) name_map * (binder * computation) option)
  | `If of (value * computation * computation)
  ]
and binding =
  [ `Let of binder * (tyvar list * tail_computation)
  | `Fun of (binder * (tyvar list * binder list * computation) * location)
  | `Rec of (binder * (tyvar list * binder list * computation) * location) list
  | `Alien of (binder * language)
  | `Module of (string * binding list option) ]
and special =
  [ `App of value * value
  | `Wrong of Types.datatype
  | `Database of value
  | `Query of SqlQuery.sqlQuery
  | `Table of (value * value * (Types.datatype * Types.datatype))
  | `CallCC of (value) ]
and computation = binding list * tail_computation
  deriving (Show, Pickle)  

let letm (b, tc) = `Let (b, ([], tc))
let letmv (b, v) = letm (b, `Return v)
(*let letv (b, v) = `Let (b, `Return v)*)

let rec is_atom =
  function
    | `Constant (`Bool _)
    | `Constant (`Int _)
    | `Constant (`Char _)
    | `Constant (`Float _)
    | `Variable _ -> true
    | `Erase (_, v)
    | `Coerce (v, _)
    | `Abs v -> is_atom v
    | _ -> false

let with_bindings bs' (bs, tc) = (bs' @ bs, tc)

type program = computation
  deriving (Show, Pickle)

let string_of_var = string_of_int

let string_of_value _ = "[VALUE]"
let string_of_tail_computation _ = "[TAIL_COMPUTATION]"
let string_of_binding _ = "[BINDING]"
let string_of_special _ = "[SPECIAL]"
let string_of_computation _ = "[COMPUTATION]"
let string_of_program _ = "[PROGRAM]"

module type TRANSFORM =
sig
  type environment = Types.datatype Env.Int.t

  class visitor : environment ->
  object ('self_type)
    val tyenv : environment

    method lookup_type : var -> Types.datatype
    method constant : constant -> (constant * Types.datatype * 'self_type)
    method option :
      'a.
      ('self_type -> 'a -> ('a * Types.datatype * 'self_type)) ->
      'a option -> 'a option * Types.datatype option * 'self_type
    method list :
      'a.
      ('self_type -> 'a -> ('a * Types.datatype * 'self_type)) ->
      'a list -> 'a list * Types.datatype list * 'self_type
    method name_map :
      'a.
      ('self_type -> 'a -> ('a * Types.datatype * 'self_type)) ->
      'a name_map -> 'a name_map * Types.datatype name_map * 'self_type        
    method var : var -> (var * Types.datatype * 'self_type)
    method value : value -> (value * Types.datatype * 'self_type)
                                                
    method tail_computation :
      tail_computation -> (tail_computation * Types.datatype * 'self_type)
    method special : special -> (special * Types.datatype * 'self_type)      
    method bindings : binding list -> (binding list * 'self_type)
    method computation : computation -> (computation * Types.datatype * 'self_type)
    method binding : binding -> (binding * 'self_type)
    method binder : binder -> (binder * 'self_type)
  end  
end

let doc_concat sep l =
  match l with 
      [] -> empty
    | (h::t) -> h ^^ List.fold_left (fun a d -> sep ^^ d ^^ a) empty t

let doc_join f = (doc_concat break) -<- List.map f

let var_name v n = if n = "" then "__"^(string_of_int v) else n

class stringIR venv = 
object (o : 'self_type)
  val venv = venv

  method add_bindings bs =
    let venv = List.fold_left 
      (fun m (v, (_, n, _)) -> IntMap.add v (var_name v n) m) venv bs in
      {< venv=venv >}
  
  method constant : constant -> doc = fun c ->
    let s = match c with
      | `Bool x -> string_of_bool x
      | `Int x -> Num.string_of_num x
      | `Char x -> "'" ^ Char.escaped x ^ "'"
      | `String x -> "\"" ^ x ^ "\""
      | `Float x -> string_of_float x
    in text s

  method comparison : Syntaxutils.comparison -> doc = fun cmp ->
    match cmp with
      | `Less -> text "<"
      | `LessEq -> text "<="
      | `Equal -> text "=="
      | `NotEq -> text "!="

  method value : value -> doc = fun v ->
    match v with 
      | `Constant c -> o#constant c
      | `Variable v -> text (IntMap.find v venv)

      | `Extend (r, v) ->
          (let r_doc = doc_concat (text "," ^^ break)
             (StringMap.to_list (fun n v -> text n ^| text "=" ^| o#value v) r) in
             match v with
                 None -> group (parens (r_doc))
               | Some v -> 
                   group (parens (r_doc ^| text "|" ^| 
                                      group (o#value v))))

      | `Project (n, v) -> group (o#value v ^^ text "." ^^ text n)

      | `Erase (n, v) -> parens (group (o#value v ^^ text "\\" ^^ text n))
      | `Inject _ -> text "INJECT"
      | `TAbs _ -> text "TABS"
      | `TApp (v, ts) -> o#value v
      | `XmlNode _ -> text "XMLNODE"
      | `ApplyPure (v, vl) ->
          group (parens (o#value v ^| (doc_join o#value vl)))
      | `Comparison (v1, cmp, v2) -> 
          group (o#value v1 ^| o#comparison cmp ^| o#value v2)
      | `Coerce _ -> text "COERCE"
      | `Abs _ -> text "ABS"
          
  method tail_computation : tail_computation -> doc = fun tc ->
    match tc with
        `Return v -> o#value v

      | `Apply (v, vl) -> 
          group (o#value v ^| (doc_join o#value vl))

      | `Case (v, names, opt) ->
          let cases = 
            StringMap.fold 
              (fun n (b, c) d -> 
                 let o = o#add_bindings [b] in
                   group (text n ^| o#binder b ^| text "->") ^| 
                       o#computation c ^| d)
              names empty in
          let comp = 
            match opt with
              | None -> empty
              | Some (b, c) ->
                  let o = o#add_bindings [b] in
                    group (text "let" ^| o#binder b ^| text "=" 
                             ^| o#value v ^| text "in") ^| 
                        o#computation c in
            group (
              nest 2 (group (
                        group (text "match" ^| o#value v ^| text "with") ^| 
                            nest 2  (group cases))) ^|
                  group (comp))
                
      | `If (v, t, f) ->          
          group (
            nest 2 (
              group (text "if" ^| o#value v) ^|
                  nest 2 (group (text "then" ^| o#computation t)) ^| 
                      nest 2 (group (text "else" ^| o#computation f))))
                      
      | `Special v -> text "SPECIAL"
          
  method bindings : binding list -> 'self_type * doc = fun bs ->
    List.fold_left
      (fun (o, accum_d) b -> let (o, d) = o#binding b in o, accum_d ^| d)
      (o, empty) bs

  method computation : computation -> doc = fun (bs, tc) ->
    let (o, d) = o#bindings bs in 
      d ^| o#tail_computation tc

  method binding : binding -> 'self_type * doc = fun b ->
    match b with
        `Let (x, (_, tc)) ->
          let o = o#add_bindings [x] in
            o, group (text "let" ^| o#binder x ^|
                 text "=" ^| group(o#tail_computation tc ^| text "in"))
                     
      | `Fun (binder, (_, f_binders, comp), loc) ->
          let o = o#add_bindings f_binders in
            o, nest 2 (group (
              group (text "let" ^| o#binder binder ^| 
                         doc_join o#binder f_binders ^| text "=") ^| 
                  group(o#computation comp ^| text "in")))
              
      | `Rec funs -> 
          let o = o#add_bindings (List.map fst3 funs) in
          let (_, docs) = o#bindings (List.map (fun x -> `Fun x) funs) in
            o, docs
            
      | `Alien _ -> o, text "ALIEN"
      | `Module _ -> o, text "MODULE"

  method binder : binder -> doc = fun (v, (_, name, _)) ->
    text (var_name v name)

end

let string_of_ir venv comp =
  pretty 70 ((new stringIR venv)#computation comp)

(* Traversal with type reconstruction *)
(*
  Essentially this is a map-fold operation over the IR datatypes that also
  constructs the type as it goes along (using type annotations on
  binders).
*)
module Transform : TRANSFORM =
struct
  open Types
  open TypeUtils

  type environment = datatype Env.Int.t

  let info_type (t, _, _) = t

  (*
    HACK:

    The ir_ignore_type_errors setting tries to ignore any type errors
    during type deconstruction. It is only necessary because the
    optimisations on Syntax.expression don't maintain type correctness.

    In fact, now that it is possible to run type inference after
    optimisation (to restore type correctness), this setting is
    unnecessary.
  *)
  let ignore_type_errors = Settings.add_bool("ir_ignore_type_errors", false, `User)
  let deconstruct f t =
    if not (Settings.get_value ignore_type_errors) then
      f t
    else
      try
        f t
      with
          TypeDestructionError _ -> t

  module Env = Env.Int

  class visitor (tyenv : environment) =
  object ((o : 'self_type))
    val tyenv = tyenv

    method lookup_type : var -> datatype = fun var ->
      Env.lookup tyenv var
        
    method constant : constant -> (constant * datatype * 'self_type) = fun c ->
      match c with
        | `Bool _ -> c, bool_type, o
        | `Int _ -> c, int_type, o
        | `Char _ -> c, char_type, o
        | `String _ -> c, string_type, o
        | `Float _ -> c, float_type, o

    method option :
      'a.
      ('self_type -> 'a -> ('a * datatype * 'self_type)) ->
      'a option -> 'a option * datatype option * 'self_type =
      fun f v ->
        match v with
          | None -> None, None, o
          | Some v ->
              let v, t, o = f o v in
                Some v, Some t, o
        
    method list :
      'a.
      ('self_type -> 'a -> ('a * datatype * 'self_type)) ->
      'a list -> 'a list * datatype list * 'self_type =
      fun f v ->
        let vs, ts, o =
          List.fold_left
            (fun (vs, ts, o) v ->
               let (v, t, o) = f o v in
                 v::vs, t::ts, o)
            ([], [], o)
            v
        in
          List.rev vs, List.rev ts, o
          
    method name_map :
      'a.
      ('self_type -> 'a -> ('a * datatype * 'self_type)) ->
      'a name_map -> 'a name_map * datatype name_map * 'self_type =
      fun f vmap ->
        StringMap.fold
          (fun name v (vmap, tmap, o) ->
             let (v, t, o) = f o v in
               (StringMap.add name v vmap,
                StringMap.add name t tmap,
                o))
          vmap
          (StringMap.empty, StringMap.empty, o)

    method var : var -> (var * datatype * 'self_type) =
      fun var -> (var, o#lookup_type var, o)
        
    method value : value -> (value * datatype * 'self_type) =
      function
        | `Constant c -> let (c, t, o) = o#constant c in `Constant c, t, o
        | `Variable x -> let (x, t, o) = o#var x in `Variable x, t, o
        | `Extend (fields, base) ->
            let (fields, field_types, o) = o#name_map (fun o -> o#value) fields in
            let (base, base_type, o) = o#option (fun o -> o#value) base in

            let t =
              match base_type with
                | None -> make_record_type field_types
                | Some t ->
                    begin
                      match TypeUtils.concrete_type t with
                        | `Record row ->
                            `Record (extend_row field_types row)
                        | _ -> assert false
                    end
            in
              `Extend (fields, base), t, o
        | `Project (name, v) ->
            (*             Debug.print ("project_e: " ^ Show_value.show (`Project (name, v))); *)
            let (v, vt, o) = o#value v in
(*               Debug.print ("project_vt: " ^ Types.string_of_datatype vt); *)
              `Project (name, v), deconstruct (project_type name) vt, o
        | `Erase (name, v) ->
(*             Debug.print ("erase_e: " ^ Show_value.show (`Erase (name, v))); *)
            let (v, vt, o) = o#value v in
            let t = deconstruct (erase_type name) vt in
(*               Debug.print ("erase_vt: " ^ Types.string_of_datatype vt); *)
(*               Debug.print ("erase_t: " ^ Types.string_of_datatype t); *)
              `Erase (name, v), t, o
        | `Inject (name, v, t) ->
            let v, _vt, o = o#value v in
              `Inject (name, v, t), t, o
        | `TAbs (tyvars, v) ->
            let v, t, o = o#value v in
            let t = Types.for_all (tyvars, t) in
              `TAbs (tyvars, v), t, o
        | `TApp (v, ts) ->
            let v, t, o = o#value v in
            let t = Instantiate.apply_type t ts in
              `TApp (v, ts), t, o
        | `XmlNode (tag, attributes, children) ->
            let (attributes, attribute_types, o) = o#name_map (fun o -> o#value) attributes in
            let (children, children_types, o) = o#list (fun o -> o#value) children in

              (*
                let _ = assert (StringMap.for_all (fun t -> t=string_type) attribute_types) in
                let _ = assert (List.for_all (fun t -> t=xml_type) children_types) in
              *)
              `XmlNode (tag, attributes, children), xml_type, o            
        | `ApplyPure (f, args) ->
            let (f, ft, o) = o#value f in
            let (args, arg_types, o) = o#list (fun o -> o#value) args in
              (* TODO: check arg types match *)
              `ApplyPure (f, args), deconstruct return_type ft, o
        | `Comparison (v, op, w) ->
            let v, _, o = o#value v in
            let w, _, o = o#value w in
              `Comparison (v, op, w), bool_type, o
            (* TODO: get rid of comparison *)
        | `Coerce (v, t) ->
            let v, vt, o = o#value v in
            (* TODO: check that vt <: t *)
              `Coerce (v, t), t, o
        | `Abs v ->
            let v, t, o = o#value v in
              `Abs v, abs_type t, o

    method tail_computation :
      tail_computation -> (tail_computation * datatype * 'self_type) =
      function
          (* TODO: type checking *)
        | `Return v ->
            let v, t, o = o#value v in
              `Return v, t, o
        | `Apply (f, args) ->
            let f, ft, o = o#value f in
            let args, arg_types, o = o#list (fun o -> o#value) args in
              (* TODO: check arg types match *)
(*               Debug.print ("apply: " ^ Show_tail_computation.show (`Apply (f, args))); *)
              `Apply (f, args), deconstruct return_type ft, o
        | `Special special ->
            let special, t, o = o#special special in
              `Special special, t, o

        | `Case (v, cases, default) ->
            let v, _, o = o#value v in
            let cases, case_types, o =
              o#name_map
                (fun o (b, c) ->
                   let b, o = o#binder b in
                   let c, t, o = o#computation c in
                     (b, c), t, o) cases in
            let default, default_type, o =
              o#option (fun o (b, c) ->
                          let b, o = o#binder b in
                          let c, t, o = o#computation c in
                            (b, c), t, o) default in
            let t =
              if not (StringMap.is_empty case_types) then
                (StringMap.to_alist ->- List.hd ->- snd) case_types
              else
                val_of default_type
            in
              `Case (v, cases, default), t, o
        | `If (v, left, right) ->
            let v, _, o = o#value v in
            let left, t, o = o#computation left in
            let right, _, o = o#computation right in
              `If (v, left, right), t, o
                 
    method special : special -> (special * datatype * 'self_type) =
      function
        | `App (v, w) ->
            let v, vt, o = o#value v in
            let w, wt, o = o#value w in
              `App (v, w), app_type vt wt, o
        | `Wrong t -> `Wrong t, t, o
        | `Database v ->
            let v, _, o = o#value v in
              `Database v, `Primitive `DB, o
        | `Query q ->
            let row =
	      (List.fold_right
	         (fun (expr, alias) env ->
                    match expr with 
                      | `F field -> 
                          StringMap.add alias (`Present field.SqlQuery.ty) env
                      | _ -> assert(false) (* can't handle other kinds of expressions *))
	         q.SqlQuery.cols StringMap.empty, Unionfind.fresh `Closed) in
            let t =  `Application (Types.list, [`Record row]) in
              `Query q, t, o
        | `Table (db, table_name, (rt, wt)) ->
            let db, _, o = o#value db in
            let table_name, _, o = o#value table_name in
              `Table (db, table_name, (rt, wt)), `Table (rt, wt), o
        | `CallCC v ->
            let v, t, o = o#value v in
              `CallCC v, deconstruct return_type t, o
      
    method bindings : binding list -> (binding list * 'self_type) =
      fun bs ->
        let bs, o =
          List.fold_left
            (fun (bs, o) b ->
               let (b, o) = o#binding b in
                 (b::bs, o))
            ([], o)
            bs
        in
          List.rev bs, o

    method computation : computation -> (computation * datatype * 'self_type) =
      fun (bs, tc) ->
(*         Debug.print ("computation: " ^ Show_computation.show (bs, tc)); *)
        let bs, o = o#bindings bs in
        let tc, t, o = o#tail_computation tc in
          (bs, tc), t, o
                                                       
    method binding : binding -> (binding * 'self_type) =
      function
        | `Let (x, (tyvars, tc)) ->
            let (xv, (xt, _, _) as x), o = o#binder x in
            let tc, t, o = o#tail_computation tc in
(*               Debug.print ("bound "^string_of_int(xv)^" of type "^string_of_datatype xt^ *)
(*                              " to expression of type "^string_of_datatype t); *)
              `Let (x, (tyvars, tc)), o
        | `Fun (f, (tyvars, xs, body), location) ->
            let xs, body, o =
              let (xs, o) =
                List.fold_right
                  (fun x (xs, o) ->
                     let x, o = o#binder x in
                       (x::xs, o))
                  xs
                  ([], o) in
              let body, _, o = o#computation body in
                xs, body, o in
            let f, o = o#binder f in
              (* TODO: check that xs and body match up with f *)
              `Fun (f, (tyvars, xs, body), location), o
        | `Rec defs ->
            let _, o =
              List.fold_right
                (fun (f, _, _) (fs, o) ->
                   let f, o = o#binder f in
                     (f::fs, o))
                defs
                ([], o) in

            let defs, o =
              List.fold_left
                (fun (defs, o) (f, (tyvars, xs, body), location) ->
                   let xs, o =
                     List.fold_right
                       (fun x (xs, o) ->
                          let (x, o) = o#binder x in
                            (x::xs, o))
                       xs
                       ([], o) in
                  let body, _, o = o#computation body in
                    (f, (tyvars, xs, body), location)::defs, o)
                ([], o)
                defs in
            let defs = List.rev defs in
              `Rec defs, o
        | `Alien (x, language) ->
            let x, o = o#binder x in
              `Alien (x, language), o
        | `Module (name, defs) ->
            let defs, o =
              match defs with
                | None -> None, o
                | Some defs ->
                    let defs, o = o#bindings defs
                    in
                      Some defs, o
            in
              `Module (name, defs), o

    method binder : binder -> (binder * 'self_type) =
      fun (var, info) ->
(*        Debug.print ("var: "^string_of_int var^", type: "^(Types.string_of_datatype (info_type info)));*)
        let tyenv = Env.bind tyenv (var, info_type info) in
          (var, info), {< tyenv=tyenv >}
  end
end

module Inline =
struct
  let rec is_inlineable_value =
    function
      | v when is_atom v -> true
      | `Project (_, v)
      | `Inject (_, v, _) -> is_inlineable_value v
      | _ -> false

  let inliner tyenv env =
  object (o)
    inherit Transform.visitor(tyenv) as super

    val env = env

    method with_env env =
      {< env = env >}

    method value =
      function
        | `Variable var when IntMap.mem var env -> IntMap.find var env, o#lookup_type var, o          
        | v -> super#value v

    method bindings =
      function
        | b :: bs ->
            let b, o = o#binding b in
              begin
                match b with
                  | `Let ((x, (_, _, `Local)), (tyvars, `Return v)) when is_inlineable_value v ->
                      let v =
                        match tyvars with
                          | [] -> v
                          | tyvars -> `TAbs (tyvars, v)
                      in
                        (o#with_env (IntMap.add x (fst3 (o#value v)) env))#bindings bs
                  | _ ->
                      let bs, o = o#bindings bs in
                        b :: bs, o
              end
        | [] -> [], o
  end

  let program typing_env p =
(*    Debug.print (Show_computation.show p);*)
    fst3 ((inliner typing_env IntMap.empty)#computation p)
end

(*
  Eliminate dead functions and value bindings.

  Currently this is rather basic. It only does one pass, and it only
  eliminates variables in the following situations:

    - never used anywhere
    - only used recursively, but not mutually recursively
    - only used mutually recursively, and all the other mutually
    recursive bindings are only used mutually recursively

  If we partition mutually recursive bindings into strongly connected
  components beforehand then this will help eliminate more recursive
  bindings.
  
  A much more effective approach is to use one of Appel and Jim's
  algorithms described in `Shrinking lambda reductions in linear
  time'.

  They describe three algorithms. All of them eliminate all dead
  variables (as well as inlining linear variables, though that aspect
  is neither here nor there really).

  The naive algorithm gathers a census of variable counts, uses it to
  perform inlining, and is applied repeatedly until there are no dead
  variables left.

  The improved algorithm does the same, but updates the census as it
  goes along (e.g. whenever it deletes a function it passes over the
  body of the function and adjusts the census to take account of any
  uses of variables that have just been deleted).

  Both the naive algorithm and the improved algorithm are quadratic in
  the worst case, though the improved algorithm works quite well in
  practice. The improved algorithm is used in SML/NJ and MLton, and it
  used to be used in SML.NET. Appel and Jim suggest just bounding the
  number of times the improved algorithm is iterated rather than
  trying to run it exhaustively. In all but pathological cases this
  gets rid of most dead functions.

  The graphical algorithm depends on a graphical representation of
  terms (connecting definitions to uses of variables). It takes linear
  time and is the algorithm now used in SML.NET. It is extremely fast
  in practice and eliminates all dead variables in one
  pass. Unfortunately our terms are represented as trees, so we cannot
  use this algorithm here.
*)
module ElimDeadDefs =
struct
  let show_rec_uses = Settings.add_bool("show_rec_uses", false, `User)

  let counter tyenv =
  object (o)
    inherit Transform.visitor(tyenv) as super
      
    val env = IntMap.empty
    val rec_env = IntMap.empty
    val mutrec_env = IntMap.empty
      
    method with_env env =
      {< env = env >}

    method with_envs (env, rec_env, mutrec_env) =
      {< env = env; rec_env = rec_env; mutrec_env = mutrec_env >}

    method init (x, (_, name, _)) =
      o#with_env (IntMap.add x 0 env)

    method initrec (x, (_, name, _)) =
      o#with_envs (IntMap.add x 0 env, IntMap.add x (0, false) rec_env, IntMap.add x (0, true) mutrec_env)

    method set_rec_status f (r,m) =
      let (count, _) = IntMap.find f rec_env in
      let rec_env = IntMap.add f (count, r) rec_env in
      let (count, _) = IntMap.find f mutrec_env in
      let mutrec_env = IntMap.add f (count, m) mutrec_env in
        o#with_envs (env, rec_env, mutrec_env)

    method set_rec f =
      o#set_rec_status f (true, false)

    method set_mutrec f =
      o#set_rec_status f (false, true)

    method set_nonrec f =
      o#set_rec_status f (false, false)

    method set_nonrecs fs =
      IntSet.fold (fun f o -> o#set_nonrec f) fs o

    method inc x =
      if IntMap.mem x rec_env then
        let count = IntMap.find x env
        and rcount, ractive = IntMap.find x rec_env
        and mcount, mactive = IntMap.find x mutrec_env in
        let envs =
          match ractive, mactive with
            | false, false -> IntMap.add x (count+1) env, rec_env, mutrec_env
            | true, false -> env, IntMap.add x (rcount+1, ractive) rec_env, mutrec_env
            | false, true -> env, rec_env, IntMap.add x (mcount+1, mactive) mutrec_env
            | true, true -> assert false
        in
          o#with_envs envs
      else if IntMap.mem x env then
        o#with_env (IntMap.add x ((IntMap.find x env)+1) env)
      else
        o#with_env (IntMap.add x 1 env)

    method var =
      fun x ->         
        if IntMap.mem x env then
          x, o#lookup_type x, o#inc x
        else
          super#var x

    method binding b =
      match b with
        | `Let (x, (tyvars, `Return _)) ->
            let b, o = super#binding b in
              b, o#init x
        | `Fun (f, (tyvars, _, _), _) ->
            let b, o = super#binding b in
              b, o#init f
        | `Rec defs ->
            let fs, o =
              List.fold_right
                (fun (f, _, _) (fs, o) ->
                   let f, o = o#binder f in
                     (IntSet.add (var_of_binder f) fs, o#initrec f))
                defs
                (IntSet.empty, o) in

            let defs, o =
              List.fold_left
                (fun (defs, o) (f, (tyvars, xs, body), location) ->
                   let xs, o =
                     List.fold_right
                       (fun x (xs, o) ->
                          let (x, o) = o#binder x in
                            (x::xs, o))
                       xs
                       ([], o) in
                   let o = o#set_rec (var_of_binder f) in
                   let body, _, o = o#computation body in
                   let o = o#set_mutrec (var_of_binder f) in
                     (f, (tyvars, xs, body), location)::defs, o)
                ([], o)
                defs in
            let o = o#set_nonrecs fs in
            let defs = List.rev defs in
              `Rec defs, o
        | _ ->
            super#binding b

    method get_envs () = (env, rec_env, mutrec_env)
  end

  let eliminator tyenv (env, rec_env, mutrec_env) =
  object (o)
    inherit Transform.visitor(tyenv) as super
      
    val env = env
    val rec_env = rec_env
    val mutrec_env = mutrec_env
      
    method is_dead x =
      IntMap.mem x env && (IntMap.find x env = 0)

    method is_dead_rec f =
      IntMap.mem f env && (IntMap.find f env = 0
          && (not (IntMap.mem f mutrec_env) || fst (IntMap.find f mutrec_env) = 0))

    method bindings =
      function
        | b :: bs ->
            begin
              let b, o = o#binding b in
                match b with
                  | `Let ((x, (_, name, _)), (_tyvars, _)) when o#is_dead x ->
                      o#bindings bs
                  | `Fun ((f, (_, name, _)), _, _) when o#is_dead f ->
                      o#bindings bs
                  | `Rec defs ->
                      Debug.if_set show_rec_uses (fun () -> "Rec block:");
                      let fs, defs =
                        List.fold_left
                          (fun (fs, defs) (((f, (_, name, _)), _, _) as def) ->
                             Debug.if_set show_rec_uses
                               (fun () ->
                                  "  (" ^ name ^ ") non-rec uses: "^string_of_int (IntMap.find f env)^
                                    ", rec uses: "^string_of_int (fst (IntMap.find f rec_env))^
                                    ", mut-rec uses: "^string_of_int (fst (IntMap.find f mutrec_env)));
                             if o#is_dead_rec f then fs, defs
                             else
                               IntSet.add f fs, def :: defs)
                          (IntSet.empty, [])
                          defs in

                      (*
                         If none of the mutually recursive bindings appear elsewhere
                         then we can delete them all.
                      *)
                      let defs =
                        if IntSet.for_all o#is_dead fs then []
                        else
                          List.rev defs
                      in
                        begin
                          match defs with
                            | [] -> o#bindings bs
                            | defs ->
                                let bs, o = o#bindings bs in
                                  `Rec defs :: bs, o
                        end                              
                  | _ ->
                      let bs, o = o#bindings bs in
                        b :: bs, o
            end
        | [] -> [], o
  end

  let count tyenv p =
    let _, _, o = (counter tyenv)#computation p in
      o#get_envs()

  let program tyenv p =
    let envs = count tyenv p in
(*      Debug.print ("before elim dead defs: " ^ Show_computation.show p);*)
    let p, _, _ = (eliminator tyenv envs)#computation p in
(*      Debug.print ("after elim dead defs: " ^ Show_computation.show p);*)
      p
end
