(** Copyright 2024, Kostya Oreshin and Nikita Shchutskii *)

(** SPDX-License-Identifier: MIT *)

open Typedtree
open Ast
open Parser

module R : sig
  type 'a t

  val bind : 'a t -> f:('a -> 'b t) -> 'b t
  val return : 'a -> 'a t
  val fail : error -> 'a t

  include Base.Monad.Infix with type 'a t := 'a t

  module Syntax : sig
    val ( let* ) : 'a t -> ('a -> 'b t) -> 'b t
  end

  module RList : sig
    val fold_left : 'a list -> init:'b t -> f:('b -> 'a -> 'b t) -> 'b t
  end

  val fresh : int t

  (** Running a transformer: getting the inner result value *)
  val run : 'a t -> ('a, error) Result.t
end = struct
  (* A compositon: State monad after Result monad *)
  type 'a t = int -> int * ('a, error) Result.t

  let ( >>= ) : 'a 'b. 'a t -> ('a -> 'b t) -> 'b t =
    fun m f st ->
    let last, r = m st in
    match r with
    | Result.Error x -> last, Error x
    | Ok a -> f a last
  ;;

  let fail e st = st, Base.Result.fail e
  let return x last = last, Base.Result.return x
  let bind x ~f = x >>= f

  let ( >>| ) : 'a 'b. 'a t -> ('a -> 'b) -> 'b t =
    fun x f st ->
    match x st with
    | st, Ok x -> st, Ok (f x)
    | st, Result.Error e -> st, Result.Error e
  ;;

  module Syntax = struct
    let ( let* ) x f = bind x ~f
  end

  module RList = struct
    let fold_left xs ~init ~f =
      Base.List.fold_left xs ~init ~f:(fun acc x ->
        let open Syntax in
        let* acc = acc in
        f acc x)
    ;;
  end

  let fresh : int t = fun last -> last + 1, Result.Ok last
  let run m = snd (m 0)
end

type fresh = int

module Type = struct
  type t = ty

  let rec occurs_in v = function
    | Ty_var b | Ty_ord b | Ty_enum b -> b = v
    | Ty_arrow (l, r) -> occurs_in v l || occurs_in v r
    | Ty_prim _ -> false
    | Ty_list ty | Ty_tree ty | Ty_maybe ty -> occurs_in v ty
    | Ty_tuple (ty1, ty2, ty_list) ->
      List.exists (fun ty -> occurs_in v ty) (ty1 :: ty2 :: ty_list)
  ;;

  let free_vars =
    let rec helper acc = function
      | Ty_var b | Ty_ord b | Ty_enum b -> VarSet.add b acc
      | Ty_arrow (l, r) -> helper (helper acc l) r
      | Ty_prim _ -> acc
      | Ty_list ty | Ty_tree ty | Ty_maybe ty -> helper acc ty
      | Ty_tuple (ty1, ty2, ty_list) ->
        List.fold_left (fun acc ty -> helper acc ty) acc (ty1 :: ty2 :: ty_list)
    in
    helper VarSet.empty
  ;;
end

module Subst : sig
  type t

  val pp : Stdlib.Format.formatter -> t -> unit
  val empty : t
  val singleton : fresh -> ty -> t R.t

  (** Getting value from substitution. May raise [Not_found] *)
  val find_exn : fresh -> t -> ty

  val find : fresh -> t -> ty option
  val apply : t -> ty -> ty
  val unify : ty -> ty -> t R.t

  (** Compositon of substitutions *)
  val compose : t -> t -> t R.t

  val compose_all : t list -> t R.t
  val remove : t -> fresh -> t
end = struct
  open R
  open R.Syntax
  open Base

  (* an association list. In real world replace it by a finite map *)
  type t = (fresh * ty) list

  let pp ppf subst =
    let open Stdlib.Format in
    fprintf
      ppf
      "[ %a ]"
      (pp_print_list
         ~pp_sep:(fun ppf () -> fprintf ppf ", ")
         (fun ppf (k, v) -> fprintf ppf "%d -> %a" k Pprint.pp_ty v))
      subst
  ;;

  let empty = []
  let mapping k v = if Type.occurs_in k v then fail `Occurs_check else return (k, v)

  let singleton k v =
    let* mapping = mapping k v in
    return [ mapping ]
  ;;

  let find_exn k xs = List.Assoc.find_exn xs k ~equal:Int.equal
  let find k xs = List.Assoc.find xs k ~equal:Int.equal
  let remove xs k = List.Assoc.remove xs k ~equal:Int.equal

  let apply s =
    let rec helper = function
      | Ty_var b as ty ->
        (match find_exn b s with
         | exception Not_found_s _ -> ty
         | x -> x)
      | Ty_arrow (l, r) -> Ty_arrow (helper l, helper r)
      | Ty_list ty -> Ty_list (helper ty)
      | Ty_tuple (ty1, ty2, ty_list) ->
        Ty_tuple (helper ty1, helper ty2, List.map ty_list ~f:helper)
      | Ty_tree ty -> Ty_tree (helper ty)
      | Ty_maybe ty -> Ty_maybe (helper ty)
      | Ty_ord ty ->
        (match helper (Ty_var ty) with
         | Ty_var ty' -> Ty_ord ty'
         | t' -> t')
      | Ty_enum ty ->
        (match helper (Ty_var ty) with
         | Ty_var ty' -> Ty_enum ty'
         | t' -> t')
      | other -> other
    in
    helper
  ;;

  let rec unify l r =
    match l, r with
    | Ty_prim l, Ty_prim r when String.equal l r -> return empty
    | Ty_var a, Ty_var b when Int.equal a b -> return empty
    | Ty_var b, t | t, Ty_var b -> singleton b t
    | Ty_ord _, Ty_arrow _ | Ty_arrow _, Ty_ord _ -> fail (`Unification_failed (l, r))
    | Ty_enum b, (Ty_prim _ as t) | (Ty_prim _ as t), Ty_enum b -> singleton b t
    | Ty_ord b, t | t, Ty_ord b -> singleton b t
    | Ty_arrow (l1, r1), Ty_arrow (l2, r2) ->
      let* subs1 = unify l1 l2 in
      let* subs2 = unify (apply subs1 r1) (apply subs1 r2) in
      compose subs2 subs1
    | Ty_list ty1, Ty_list ty2 -> unify ty1 ty2
    | Ty_tuple (t1, t2, tt), Ty_tuple (t1', t2', tt')
      when List.length tt = List.length tt' ->
      RList.fold_left
        (List.zip_exn (t1 :: t2 :: tt) (t1' :: t2' :: tt'))
        ~init:(return empty)
        ~f:(fun acc (t1, t2) ->
          let* subs = unify (apply acc t1) (apply acc t2) in
          compose subs acc)
    | Ty_tree ty1, Ty_tree ty2 -> unify ty1 ty2
    | Ty_maybe ty1, Ty_maybe ty2 -> unify ty1 ty2
    | _ -> fail (`Unification_failed (l, r))

  and extend s (k, v) =
    let bind v f =
      match v with
      | Ty_var k' when k = k' -> return s
      | _ -> f v
    in
    let ( let** ) = bind in
    let** v = v in
    match List.Assoc.find s ~equal:Int.equal k with
    | None ->
      let** v = apply s v in
      let* s2 = singleton k v in
      RList.fold_left s ~init:(return s2) ~f:(fun acc (k, v) ->
        let** v = apply s2 v in
        let* mapping = mapping k v in
        return (mapping :: acc))
    | Some v2 ->
      let* s2 = unify v v2 in
      compose s2 s

  and compose s2 s1 = RList.fold_left s2 ~init:(return s1) ~f:extend

  let compose_all ss = RList.fold_left ss ~init:(return empty) ~f:compose
end

module VarSet = struct
  include VarSet

  let fold_left_m f acc set =
    fold
      (fun x acc ->
        let open R.Syntax in
        let* acc = acc in
        f acc x)
      acc
      set
  ;;
end

module Scheme = struct
  type t = scheme

  let occurs_in v = function
    | S (xs, t) -> (not (VarSet.mem v xs)) && Type.occurs_in v t
  ;;

  let free_vars = function
    | S (bs, t) -> VarSet.diff (Type.free_vars t) bs
  ;;

  let apply sub (S (names, ty)) =
    let s2 = VarSet.fold (fun k s -> Subst.remove s k) names sub in
    S (names, Subst.apply s2 ty)
  ;;
end

module SMap = Map.Make (String)

module TypeEnv = struct
  open Base

  type t = scheme SMap.t

  let extend : t -> string * scheme -> t = fun e (name, scheme) -> SMap.add name scheme e
  let empty = SMap.empty

  let pp ppf =
    let open Stdlib.Format in
    fprintf ppf "[ \n%a ]" (fun ppf env ->
      SMap.iter (fun name (S (_, t)) -> fprintf ppf "%s:  %a\n" name Pprint.pp_ty t) env)
  ;;

  let free_vars : t -> VarSet.t =
    fun env ->
    SMap.fold (fun _ s acc -> VarSet.union acc (Scheme.free_vars s)) env VarSet.empty
  ;;

  let apply s = SMap.map (Scheme.apply s)
  let find_exn name = SMap.find name
end

open R
open R.Syntax

let unify = Subst.unify
let fresh_var = fresh >>| fun n -> Ty_var n

let instantiate : scheme -> ty R.t =
  fun (S (bs, t)) ->
  VarSet.fold_left_m
    (fun typ name ->
      let* f1 = fresh_var in
      let* s = Subst.singleton name f1 in
      return (Subst.apply s typ))
    bs
    (return t)
;;

let generalize : TypeEnv.t -> Type.t -> Scheme.t =
  fun env ty ->
  let free = VarSet.diff (Type.free_vars ty) (TypeEnv.free_vars env) in
  S (free, ty)
;;

let lookup_env e xs =
  match TypeEnv.find_exn e xs with
  | exception Not_found -> fail (`No_variable e)
  | scheme ->
    let* ans = instantiate scheme in
    return ans
;;

let built_in_sign op =
  (function
    | And | Or -> return (Ty_prim "Bool", Ty_prim "Bool", Ty_prim "Bool")
    | Cons ->
      let* t = fresh_var in
      return (t, Ty_list t, Ty_list t)
    | Plus | Minus | Divide | Mod | Multiply | Pow ->
      return (Ty_prim "Int", Ty_prim "Int", Ty_prim "Int")
    | _ -> fresh >>| fun t -> Ty_ord t, Ty_ord t, Ty_prim "Bool")
    op
  >>| fun (t1, t2, t3) -> Ty_arrow (t1, Ty_arrow (t2, t3))
;;

let rec tp_to_ty = function
  | TUnit -> Ty_prim "()"
  | TBool -> Ty_prim "Bool"
  | TInt -> Ty_prim "Int"
  | MaybeParam tp -> Ty_maybe (tp_to_ty tp)
  | TreeParam tp -> Ty_tree (tp_to_ty tp)
  | ListParam tp -> Ty_list (tp_to_ty tp)
  | TupleParams (t1, t2, tt) -> Ty_tuple (tp_to_ty t1, tp_to_ty t2, List.map tp_to_ty tt)
  | FunctionType (FuncT (t1, t2, [])) -> Ty_arrow (tp_to_ty t1, tp_to_ty t2)
  | FunctionType (FuncT (t1, t2, hd :: tl)) ->
    Ty_arrow (tp_to_ty t1, tp_to_ty (FunctionType (FuncT (t2, hd, tl))))
;;

let rec bindings bb env =
  let f (subst, env) = function
    | FunDef (Ident name, p, pp, bd, bb), tv0, _ ->
      let* tt, inner_env = helper_pp (p :: pp) env in
      let* s1, inner_env = bindings bb inner_env in
      let* s2, t1 =
        (match bd with
         | Guards (ep, eps) -> helper_guards (ep :: eps) inner_env
         | OrdBody e -> infer e inner_env)
        >>| fun (s, ty) -> s, ty_arr (List.map (Subst.apply s) (List.rev tt)) ty
      in
      let* s = Subst.compose_all [ s2; s1; subst ] in
      let* s3 = unify (Subst.apply s tv0) t1 in
      let* s = Subst.compose s3 s in
      let env = TypeEnv.apply s env in
      let t2 = generalize env (Subst.apply s tv0) in
      Subst.compose s subst >>| fun s -> s, TypeEnv.extend env (name, t2)
    | VarsDef (_, bd, bb), tv0, names ->
      let* s1, inner_env = bindings bb env in
      let* s2, t1 =
        match bd with
        | Guards (ep, eps) -> helper_guards (ep :: eps) env
        | OrdBody e -> infer e inner_env
      in
      let* s = Subst.compose_all [ s2; s1; subst ] in
      let* s_p = Subst.compose s subst in
      let* s3 = unify (Subst.apply s_p tv0) t1 in
      let* s = Subst.compose s3 s in
      let env = TypeEnv.apply s env in
      let* fenv =
        RList.fold_left names ~init:(return env) ~f:(fun env' name ->
          lookup_env name env >>| fun t -> TypeEnv.extend env' (name, generalize env t))
      in
      Subst.compose s subst >>| fun s -> s, fenv
    | _ -> return (subst, env)
  in
  let* prep_bb, decls, delta_env, env = prep [] [] TypeEnv.empty env bb in
  let init =
    RList.fold_left
      decls
      ~init:(return (Subst.empty, env))
      ~f:(fun (s, env) (name, t1) ->
        let* _ = lookup_env name delta_env in
        let* t2 = lookup_env name env in
        let* s1 = unify t1 t2 in
        Subst.compose s1 s >>| fun fs -> fs, TypeEnv.apply s1 env)
  in
  RList.fold_left prep_bb ~init ~f

and helper_guards eps env =
  let* fresh = fresh_var in
  RList.fold_left
    eps
    ~init:(return (Subst.empty, fresh))
    ~f:(fun (s, t) (cond, e) ->
      let* s2, t1 = infer cond env in
      let* s3, t2 = infer e env in
      let* s4 = unify t1 (Ty_prim "Bool") in
      let* s5 = unify t t2 in
      Subst.compose_all [ s5; s4; s3; s2; s ] >>| fun fs -> fs, Subst.apply s5 t)

and prep prep_bb decls env1 env2 = function
  | [] -> return (prep_bb, decls, env1, env2)
  | Decl (Ident name, t) :: tl -> prep prep_bb ((name, tp_to_ty t) :: decls) env1 env2 tl
  | (FunDef (Ident name, _, _, _, _) as b) :: tl ->
    let* tv = fresh_var in
    let ext env = TypeEnv.extend env (name, S (VarSet.empty, tv)) in
    prep ((b, tv, [ name ]) :: prep_bb) decls (ext env1) (ext env2) tl
  | (VarsDef (p, _, _) as b) :: tl ->
    let* _, env1, _ = helper_p p env1 [] in
    let* t, env2, names = helper_p p env2 [] in
    prep ((b, t, names) :: prep_bb) decls env1 env2 tl

and helper_p (al, pat, etps) env names =
  (match pat with
   | PWildcard ->
     let* fresh = fresh_var in
     let* _, t = etps_hndl etps fresh in
     return (t, env, names)
   | PConst (NegativePInt _) ->
     let* _, t = etps_hndl etps (Ty_prim "Int") in
     return (t, env, names)
   | PConst (OrdinaryPConst c) ->
     let* _, t =
       etps_hndl
         etps
         (Ty_prim
            (match c with
             | Int _ -> "Int"
             | Bool _ -> "Bool"
             | Unit -> "()"))
     in
     return (t, env, names)
   | PIdentificator (Ident name) ->
     let* fresh = fresh_var in
     let* _, t = etps_hndl etps fresh in
     return (t, TypeEnv.extend env (name, S (VarSet.empty, t)), name :: names)
   | PMaybe Nothing ->
     let* fresh = fresh_var in
     let* _, t = etps_hndl etps (Ty_maybe fresh) in
     return (t, env, names)
   | PMaybe (Just pt) ->
     let* t, env, names = helper_p pt env names in
     let* s, t = etps_hndl etps (Ty_maybe t) in
     return (t, TypeEnv.apply s env, names)
   | PList (PCons (x, xs)) ->
     let* t1, env1, names1 = helper_p x env names in
     let* t2, env2, names2 = helper_p xs env1 names1 in
     let* s = unify t2 (Ty_list t1) in
     let t = Subst.apply s t2 in
     let* s2, t' = etps_hndl etps t in
     let* fs = Subst.compose s2 s in
     return (t', TypeEnv.apply fs env2, names2)
   | PTuple (p1, p2, pp) ->
     let* t1, env1, names1 = helper_p p1 env names in
     let* t2, env2, names2 = helper_p p2 env1 names1 in
     let* tt, env, names =
       RList.fold_left
         pp
         ~init:(return ([], env2, names2))
         ~f:(fun (tt, env, names) p ->
           let* t, env', names = helper_p p env names in
           return (t :: tt, env', names))
     in
     let* s, t = etps_hndl etps (Ty_tuple (t1, t2, tt)) in
     return (t, TypeEnv.apply s env, names)
   | PList (PEnum pp) ->
     let* fresh = fresh_var in
     let* env, el_t, names =
       RList.fold_left
         pp
         ~init:(return (env, fresh, names))
         ~f:(fun (env, t, names) p ->
           let* t', env', names = helper_p p env names in
           let* s = unify t t' in
           return (TypeEnv.apply s env', Subst.apply s t, names))
     in
     let* s, t = etps_hndl etps (Ty_list el_t) in
     return (t, TypeEnv.apply s env, names)
   | PTree _ -> failwith "is not required by the first deadline")
  >>| fun (t, env, names) ->
  let env', names =
    List.fold_left
      (fun (env, names) (Ident name) ->
        TypeEnv.extend env (name, S (VarSet.empty, t)), name :: names)
      (env, names)
      al
  in
  t, env', names

and helper_pp pp env =
  RList.fold_left
    pp
    ~init:(return ([], env))
    ~f:(fun (tt, env) p ->
      let* t, env', _ = helper_p p env [] in
      return (t :: tt, env'))

and infer (e, etps) env =
  let helper_list ee t =
    RList.fold_left
      ee
      ~init:(return (Subst.empty, t))
      ~f:(fun (s, t) e ->
        let* s2, t2 = infer e env in
        let* s3 = unify t t2 in
        Subst.compose_all [ s3; s2; s ] >>| fun s -> s, Subst.apply s3 t2)
    >>| fun (s, t) -> s, Ty_list t
  in
  let ty_enum = fresh >>| fun b -> Ty_enum b in
  let helper_e expr env =
    match expr with
    | Const const ->
      (match const with
       | Int _ -> return (Subst.empty, Ty_prim "Int")
       | Bool _ -> return (Subst.empty, Ty_prim "Bool")
       | Unit -> return (Subst.empty, Ty_prim "()"))
    | Identificator (Ident i) -> lookup_env i env >>| fun t -> Subst.empty, t
    | ENothing ->
      let* fresh = fresh_var in
      return (Subst.empty, Ty_maybe fresh)
    | EJust ->
      let* fresh = fresh_var in
      return (Subst.empty, Ty_arrow (fresh, Ty_maybe fresh))
    | BinTreeBld _ -> failwith "is not required by the first deadline"
    | ListBld (OrdList (IncomprehensionlList ee)) -> fresh_var >>= helper_list ee
    | ListBld (LazyList (e1, Some e2, Some e3)) -> ty_enum >>= helper_list [ e1; e2; e3 ]
    | ListBld (LazyList (e1, Some e2, None) | LazyList (e1, None, Some e2)) ->
      ty_enum >>= helper_list [ e1; e2 ]
    | ListBld (LazyList (e1, None, None)) -> ty_enum >>= helper_list [ e1 ]
    | FunctionApply (f, a, aa) ->
      (match aa with
       | [] ->
         let* s1, t1 = infer f env in
         let* s2, t2 = infer a (TypeEnv.apply s1 env) in
         let* tv = fresh_var in
         let* s3 = unify (Subst.apply s2 t1) (Ty_arrow (t2, tv)) in
         let trez = Subst.apply s3 tv in
         let* final_subst = Subst.compose_all [ s3; s2; s1 ] in
         return (final_subst, trez)
       | hd :: tl ->
         infer (FunctionApply ((FunctionApply (f, a, []), []), hd, tl), []) env)
    | IfThenEsle (c, th, el) ->
      let* s1, t1 = infer c env in
      let* s2, t2 = infer th env in
      let* s3, t3 = infer el env in
      let* s4 = unify t1 (Ty_prim "Bool") in
      let* s5 = unify t2 t3 in
      let* final_subst = Subst.compose_all [ s5; s4; s3; s2; s1 ] in
      return (final_subst, Subst.apply s5 t2)
    | Neg e ->
      let* s, t = infer e env in
      let* s1 = unify t (Ty_prim "Int") in
      let* s2 = Subst.compose s1 s in
      return (s2, Subst.apply s1 t)
    | TupleBld (e1, e2, ee) ->
      let* s1, t1 = infer e1 env in
      let* s2, t2 = infer e2 env in
      let* ss, tt =
        RList.fold_left
          ee
          ~init:(return ([], []))
          ~f:(fun (ss, tt) e -> infer e env >>| fun (s, t) -> s :: ss, t :: tt)
      in
      let* final_subst = Subst.compose_all (s1 :: s2 :: ss) in
      return (final_subst, Ty_tuple (t1, t2, tt))
    | Binop (e1, op, e2) ->
      let* sign = built_in_sign op in
      let* s1, t1 = infer e1 env in
      let* s2, t2 = infer e2 env in
      let* tv = fresh_var in
      let* s3 = unify (Ty_arrow (t1, Ty_arrow (t2, tv))) sign in
      let* final_subst = Subst.compose_all [ s1; s2; s3 ] in
      return (final_subst, Subst.apply s3 tv)
    | Lambda (p, pp, e) ->
      let* tt, env' = helper_pp (p :: pp) env in
      let* s, ty = infer e env' in
      let trez = ty_arr (List.map (Subst.apply s) (List.rev tt)) (Subst.apply s ty) in
      return (s, trez)
    | InnerBindings (b, bb, e) ->
      let* s, env = bindings (b :: bb) env in
      let* s2, t2 = infer e env in
      Subst.compose s2 s >>| fun fs -> fs, t2
    | Case (e, pb, pbs) ->
      let* fresh = fresh_var in
      let* s1, t1 =
        RList.fold_left
          (pb :: pbs)
          ~init:(return (Subst.empty, fresh))
          ~f:(fun (s, t) (p, b) ->
            let* s1, t1 =
              match b with
              | OrdBody e -> infer (Lambda (p, [], e), []) env
              | Guards (ep, eps) ->
                let* t, env', _ = helper_p p env [] in
                let* s, ty = helper_guards (ep :: eps) env' in
                let trez = Ty_arrow (Subst.apply s t, ty) in
                return (s, trez)
            in
            let* s2 = unify t1 t in
            Subst.compose_all [ s2; s1; s ] >>| fun fs -> fs, Subst.apply s2 t)
      in
      let* s2, t2 = infer e (TypeEnv.apply s1 env) in
      let* tv = fresh_var in
      let* s3 = unify (Subst.apply s2 t1) (Ty_arrow (t2, tv)) in
      let trez = Subst.apply s3 tv in
      let* final_subst = Subst.compose_all [ s3; s2; s1 ] in
      return (final_subst, trez)
    | ListBld (OrdList (ComprehensionList (e, c, cc))) ->
      let* s1, env' =
        RList.fold_left
          (c :: cc)
          ~init:(return (Subst.empty, env))
          ~f:(fun (s, env) cmp ->
            let* s1, env =
              match cmp with
              | Condition x ->
                let* s1, t1 = infer x env in
                let* s2 = unify t1 (Ty_prim "Bool") in
                let* final_subst = Subst.compose s2 s1 in
                return (final_subst, env)
              | Generator (p, e) ->
                let* s2, t2 = infer e env in
                let* t3, env', _ = helper_p p env [] in
                let* s3 = unify t2 (Ty_list t3) in
                let* s = Subst.compose s3 s2 in
                return (s, env')
            in
            Subst.compose s1 s >>| fun fs -> fs, env)
      in
      let* s2, t2 = infer e (TypeEnv.apply s1 env') in
      let* final_subst = Subst.compose s2 s1 in
      return (final_subst, Ty_list t2)
  in
  match etps with
  | [] -> helper_e e env
  | etps ->
    let* fresh = fresh_var in
    let* _, t0 = etps_hndl etps fresh in
    helper_e e env
    >>= fun (s, t) ->
    let* s' = unify t t0 in
    Subst.compose s' s >>| fun fs -> fs, Subst.apply s' t

and etps_hndl etps init =
  RList.fold_left
    etps
    ~init:(return (Subst.empty, init))
    ~f:(fun (s, t) tp ->
      unify t (tp_to_ty tp)
      >>= fun s' -> Subst.compose s' s >>| fun fs -> fs, Subst.apply s' t)

and ty_arr tt t =
  match tt with
  | [] -> t
  | hd :: tl -> Ty_arrow (hd, ty_arr tl t)
;;

let w e = Result.map snd (run (infer e TypeEnv.empty))
let w_program p = Result.map snd (run (bindings p TypeEnv.empty))

let%expect_test "int type" =
  (match parse_expr "42" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "bool type" =
  (match parse_expr "True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "unit type" =
  (match parse_expr "()" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error _ -> print_endline "failure")
   | _ -> ());
  [%expect {| () |}]
;;

let%expect_test "const with explicit correct single type" =
  (match parse_expr "42 :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "const with explicit correct multiple type" =
  (match parse_expr "(42 :: Int) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "const with explicit wrong single type" =
  (match parse_expr "42 :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "const with explicit wrong multiple type" =
  (match parse_expr "(42 :: Int) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "tuple" =
  (match parse_expr "(42, True)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (Int, Bool) |}]
;;

let%expect_test "tuple with extra types" =
  (match parse_expr "(42, True, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (Int, Bool, ()) |}]
;;

let%expect_test "tuple with explicit correct single type" =
  (match parse_expr "(42, True, ()) :: (Int, Bool, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (Int, Bool, ()) |}]
;;

let%expect_test "tuple with explicit correct multiple type" =
  (match parse_expr "((42, True, ()) :: (Int, Bool, ())) :: (Int, Bool, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (Int, Bool, ()) |}]
;;

let%expect_test "tuple with explicit wrong single type" =
  (match parse_expr "(42, True, ()) :: (Bool, Bool, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "tuple with explicit wrong multiple type" =
  (match parse_expr "((42, True, ()) :: (Int, Bool, ())) :: (Bool, Bool, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "maybe type just" =
  (match parse_expr "\\x -> Just x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t0 -> Maybe t0 |}]
;;

let%expect_test "maybe type just int" =
  (match parse_expr "\\x -> Just (x + 1)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Maybe Int |}]
;;

let%expect_test "maybe type just list" =
  (match parse_expr "\\x y -> Just (y : x)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [t3] -> t3 -> Maybe [t3] |}]
;;

let%expect_test "maybe type nothing" =
  (match parse_expr "Nothing" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Maybe t0 |}]
;;

let%expect_test "correct ariphmetic operation" =
  (match parse_expr "5 + 3" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "incorrect ariphmetic operation" =
  (match parse_expr "5 + ()" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on () and Int |}]
;;

let%expect_test "ariphmetic operation with explicit correct single type" =
  (match parse_expr "(5 + 3) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "ariphmetic operation with explicit correct multiple type" =
  (match parse_expr "((5 + 3) :: Int) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "ariphmetic operation with explicit wrong single type" =
  (match parse_expr "(5 + 3) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "ariphmetic operation with explicit wrong multiple type" =
  (match parse_expr "((5 + 3) :: Int) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "correct logical operation" =
  (match parse_expr "True && False" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "incorrect logical operation" =
  (match parse_expr "True && 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "logical operation with correct explicit single type" =
  (match parse_expr "True && False :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "logical operation with correct explicit multiple type" =
  (match parse_expr "(True && False :: Bool) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "logical operation with incorrect explicit single type" =
  (match parse_expr "True && False :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "logical operation with incorrect explicit multiple type" =
  (match parse_expr "(True && False :: Bool) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "correct comparison operation with int" =
  (match parse_expr "1 <= 2" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "correct comparison operation with bool" =
  (match parse_expr "False <= True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "incorrect comparison operation with () and int" =
  (match parse_expr "1 <= ()" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on () and Int |}]
;;

let%expect_test "incorrect comparison operation with bool and int" =
  (match parse_expr "1 <= True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "comparison operation with explicit correct single type" =
  (match parse_expr "(1 <= 2) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "comparison operation with explicit correct multiple type" =
  (match parse_expr "((1 <= 2) :: Bool) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "comparison operation with explicit wrong single type" =
  (match parse_expr "(1 <= 2) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "comparison operation with explicit wrong multiple type" =
  (match parse_expr "((1 <= 2) :: Int) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "cons correct with int" =
  (match parse_expr "1 : []" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "cons correct with bool" =
  (match parse_expr "True : []" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Bool] |}]
;;

let%expect_test "cons incorrect with int" =
  (match parse_expr "1 : 2" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and [Int] |}]
;;

let%expect_test "cons incorrect with bool" =
  (match parse_expr "True : False" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and [Bool] |}]
;;

let%expect_test "cons incorrect with int and bool" =
  (match parse_expr "1 : [True]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "neg type correct" =
  (match parse_expr "-42" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "neg type incorrect" =
  (match parse_expr "-True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "neg type with explicit correct single type" =
  (match parse_expr "-42 :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "neg type with explicit correct multiple type" =
  (match parse_expr "(-42 :: Int) :: Int" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "neg type with explicit wrong single type" =
  (match parse_expr "-42 :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "neg type with explicit wrong multiple type" =
  (match parse_expr "(-42 :: Int) :: Bool" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "ord polymor" =
  (match parse_expr "(\\f -> let g = (f True) in (f 3)) (\\x -> x)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "if correct with int return type" =
  (match parse_expr "if True then 1 else -1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "if correct with tuple return type" =
  (match parse_expr "if True then (True, 2) else (False, -1)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (Bool, Int) |}]
;;

let%expect_test "if incorrect with int condition" =
  (match parse_expr "if (1 + 2) then (True, 2) else (False, -1)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "if incorrect with tuple condition" =
  (match parse_expr "if (True, ()) then (True, 2) else (False, -1)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on (Bool, ()) and Bool |}]
;;

let%expect_test "if incorrect with int and bool return types" =
  (match parse_expr "if True then 1 else False" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "if incorrect with int and tuple return types" =
  (match parse_expr "if True then 1 else (1, False)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and (Int, Bool) |}]
;;

let%expect_test "if incorrect with bool and list return types" =
  (match parse_expr "if True then True else [1, 4]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and [Int] |}]
;;

let%expect_test "lambda ident" =
  (match parse_expr "\\x -> x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t0 -> t0 |}]
;;

let%expect_test "lambda int return type" =
  (match parse_expr "\\x -> 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t0 -> Int |}]
;;

let%expect_test "lambda narrowing to int type" =
  (match parse_expr "\\x -> x + 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Int |}]
;;

let%expect_test "lambda tuple return type" =
  (match parse_expr "\\x -> (x, ())" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t0 -> (t0, ()) |}]
;;

let%expect_test "lambda multiple arguments" =
  (match parse_expr "\\x y z -> x + y + z" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Int -> Int -> Int |}]
;;

let%expect_test "lambda narrowing to list type" =
  (match parse_expr "\\x -> 1 : x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] -> [Int] |}]
;;

let%expect_test "lambda narrowing to arrow type" =
  (match parse_expr "\\f -> \\y -> f y" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (t1 -> t2) -> t1 -> t2 |}]
;;

let%expect_test "lambda occurs check" =
  (match parse_expr "\\x -> x x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Occurs check failed |}]
;;

let%expect_test "lambda tuple return type" =
  (match parse_expr "\\x -> x `mod` 2 == 0 && x > 5" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Bool |}]
;;

let%expect_test "lambda correct with explicit single type" =
  (match parse_expr "(\\x -> 1) :: (Int -> Int)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Int |}]
;;

let%expect_test "lambda correct with explicit multiple type" =
  (match parse_expr "((\\x -> 1) :: (Bool -> Int)) :: (Bool -> Int)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool -> Int |}]
;;

let%expect_test "lambda wrong with explicit single type" =
  (match parse_expr "(\\x -> ()) :: (() -> Bool)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on () and Bool |}]
;;

let%expect_test "lambda wrong with explicit multiple type" =
  (match parse_expr "((\\x -> ()) :: (() -> ())) :: (() -> [Int])" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on [Int] and () |}]
;;

let%expect_test "let id" =
  (match parse_expr "let x = x in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t1 |}]
;;

let%expect_test "let narrowing to int" =
  (match parse_expr "let x = x; y = 1 in x + y" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "let narrowing to [int]" =
  (match parse_expr "let x = x; y = 1 in y : x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "let narrowing to bool" =
  (match parse_expr "let x = x; y = True in y && x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "let function" =
  (match parse_expr "let compose f g x = f (g x) in compose" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (t4 -> t5) -> (t3 -> t4) -> t3 -> t5 |}]
;;

let%expect_test "let recursive fib" =
  (match
     parse_expr
       "let fib n = if (n == 0) then 0 else if (n==1) then 1 else ((fib (n-1)) + (fib \
        (n-2))) in fib"
   with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Int |}]
;;

let%expect_test "let recursive fac" =
  (match
     parse_expr
       "let factorial = \\n -> if n == 0 then 1 else n * factorial (n - 1) in factorial"
   with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Int |}]
;;

let%expect_test "let with explicit correct single type" =
  (match parse_expr "let (x :: Int) = x in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "let with explicit correct mutliple type" =
  (match parse_expr "let ((x :: Int) :: Int) = x in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int |}]
;;

let%expect_test "let with explicit wrong single type" =
  (match parse_expr "let (x :: Bool) = 1 in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "let with explicit wrong mutliple type" =
  (match parse_expr "let ((x :: Int) :: Bool) = x in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "let wrong unification" =
  (match parse_expr "let x = if x <= True then 1 else 0 in x + 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "let wrong unification" =
  (match parse_expr "let x = if x <= True then True else False in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "let wrong unification" =
  (match parse_expr "let x = if x <= True then True else False in x" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "case correct with int type" =
  (match parse_expr "\\x -> case x of 1 -> True; 2 -> False" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> Bool |}]
;;

let%expect_test "case correct with lists" =
  (match parse_expr "\\x -> case x of (x:xs) -> x; [] -> []" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [[t5]] -> [t5] |}]
;;

let%expect_test "case correct with int lists and explicit similar types" =
  (match parse_expr "\\x -> case x of ((x :: [Int]):(xs :: [[Int]])) -> x; [] -> []" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [[Int]] -> [Int] |}]
;;

let%expect_test "case incorrect with int lists and explicit different types" =
  (match parse_expr "\\x -> case x of ((x :: [Int]):(xs :: [[Bool]])) -> x; [] -> []" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "function apply correct" =
  (match parse_expr "(\\x -> x + 1) True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "function apply incorrect" =
  (match parse_expr "(\\x -> x + 1) True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "function apply list return type" =
  (match parse_expr "(\\x -> x : []) True" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Bool] |}]
;;

let%expect_test "function apply with correct single type" =
  (match parse_expr "(\\(x :: Int) -> x <= 2) 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "function apply return correct multiple type" =
  (match parse_expr "(\\((x :: Int) :: Int) -> x <= 2) 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Bool |}]
;;

let%expect_test "function apply return wrong single type" =
  (match parse_expr "(\\(x :: Bool) -> x <= 2) 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "function apply return wrong multiple type" =
  (match parse_expr "(\\((x :: Int) :: Bool) -> x <= 2) 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "function apply return correct single type" =
  (match parse_expr "(\\(x :: Int) -> x : []) 1" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "list int" =
  (match parse_expr "[1, 2]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "lazy list int" =
  (match parse_expr "[1..]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "lazy list wrong type" =
  (match parse_expr "[(True, 1)..]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Enum t0 and (Bool, Int) |}]
;;

let%expect_test "list of list" =
  (match parse_expr "[[True]]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [[Bool]] |}]
;;

let%expect_test "wrong list of different types" =
  (match parse_expr "[True, (), 3]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and () |}]
;;

let%expect_test "comprehension list with generator" =
  (match parse_expr "[x * y | x <- [1..10], y <- [1]]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "comprehension list with simple condition" =
  (match parse_expr "[1 * 2 | True]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| [Int] |}]
;;

let%expect_test "comprehension list with condition" =
  (match parse_expr "\\x -> [ x | x < 10 ]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> [Int] |}]
;;

let%expect_test "comprehension list with condition and generator" =
  (match parse_expr "\\y -> [ x * y | x <- [1..10], y <= 10  ]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Int -> [Int] |}]
;;

let%expect_test "wrong comprehension list with generator condition" =
  (match parse_expr "\\x y -> [ x * y | x < 10, y <- [True, False]]" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "several functions" =
  (match parse_line "f x = g x; g y = y" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
  [
  f:  t4 -> t4
  g:  t4 -> t4
   ] |}]
;;

let%expect_test "mutually recursive functions" =
  (match parse_line "f x = g x; g y = f y" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
  [
  f:  t4 -> t5
  g:  t4 -> t5
   ] |}]
;;

let%expect_test "mutually recursive functions with guards" =
  (match
     parse_line
       "isEven n | n == 0 = True | n > 0 = isOdd (n - 1) | True = isOdd (-n); isOdd n | \
        n == 0 = False | n > 0 = isEven (n - 1) | True = isEven (-n)"
   with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
  [
  isEven:  Int -> Bool
  isOdd:  Int -> Bool
   ] |}]
;;

let%expect_test "guards" =
  (match parse_line "f x | x > 0 = x | True = -1" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    f:  Int -> Int
     ] |}]
;;

let%expect_test "where single statement" =
  (match parse_line "f x = x + y where y = 1" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| 
    [
    f:  Int -> Int
     ] |}]
;;

let%expect_test "where single statement with explicit incorrect type" =
  (match parse_line "f x = x + y where (y :: Bool) = 1" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "unification failed on Bool and Int");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "where multiple statements" =
  (match parse_line "f x = x && y || z where y = False; z = True" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| 
    [
    f:  Bool -> Bool
     ] |}]
;;

let%expect_test "where single statement incorrect" =
  (match parse_line "f x = x + y where y = True" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "where single statement with param shadowing incorrect" =
  (match parse_line "f x y = x + y where y = True" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "where multiple statements incorrect" =
  (match parse_line "f x  = x && y || z where y = False; z = 3" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "where polymorphic argument" =
  (match parse_line "f x = y where y = False" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    f:  t1 -> Bool
     ] |}]
;;

let%expect_test "where list argument" =
  (match parse_line "f (x:xs) = y : xs where y = 2" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    f:  [Int] -> [Int]
     ] |}]
;;

let%expect_test "function with tuple argument" =
  (match parse_line "f (x, y) = (x + 1, y && True)" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    f:  (Int, Bool) -> (Int, Bool)
     ] |}]
;;

let%expect_test "several functions with incorrect type" =
  (match parse_line "f x = x + 1; g = f y where y = False" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "correct arrow declaration" =
  (match parse_line "f :: Int -> Int; f x = x" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    f:  Int -> Int
     ] |}]
;;

let%expect_test "incorrect arrow declaration" =
  (match parse_line "f :: Int; f x = x" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and t1 -> t1 |}]
;;

let%expect_test "incorrect arrow declaration with different types" =
  (match parse_line "f :: Int -> Bool; f x = x" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    unification failed on Bool and Int |}]
;;

let%expect_test "incorrect list declaration with different types" =
  (match parse_line "a :: [Int]; a = [False, True]" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    unification failed on Int and Bool |}]
;;

let%expect_test "correct declaration with explicit type" =
  (match parse_line "a :: [Int]; (a :: [Int]) = [1, 2]" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    a:  [Int]
     ] |}]
;;

let%expect_test "incorrect declaration with explicit type" =
  (match parse_line "f :: Bool -> Bool; f (x :: Int) = x" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    unification failed on Bool and Int |}]
;;

let%expect_test "correct tuple declaration" =
  (match parse_line "a :: (Int, Bool, ()); a = (1, True, ())" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    [
    a:  (Int, Bool, ())
     ] |}]
;;

let%expect_test "incorrect tuple declaration" =
  (match parse_line "a :: (Int, Bool, ()); a = (False, True, ())" with
   | Result.Ok bindings ->
     (match w_program bindings with
      | Result.Ok env -> Format.printf "%a" TypeEnv.pp env
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {|
    unification failed on Int and Bool |}]
;;

let%expect_test "failed unification" =
  (match parse_expr "let f = (\\id -> (id 1, id True)) (\\x -> x) in f" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "generalization" =
  (match parse_expr "let f = \\x -> let const = \\y -> x in const x in f" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| t6 -> t6 |}]
;;

let%expect_test "incompatible restrictions" =
  (match
     parse_expr
       "let double f z = f (f z) in (double (\\x -> x+1) 1, double (\\x -> x && x) \
        False) in double"
   with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Int and Bool |}]
;;

let%expect_test "y-combinator" =
  (match parse_expr "let fix f = f (fix f) in fix" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| (t3 -> t3) -> t3 |}]
;;

let%expect_test "z-combinator without recursion" =
  (match parse_expr "let fix f eta = f (fix f) eta in fix" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| ((t2 -> t5) -> t2 -> t5) -> t2 -> t5 |}]
;;

let%expect_test "occurs check" =
  (match parse_expr "let f x = f in f" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| Occurs check failed |}]
;;

let%expect_test "fail unification" =
  (match parse_expr "let f = (\\x -> x) in let g = (f True) in f 3" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;

let%expect_test "fail unification" =
  (match parse_expr "(\\f -> let g = (f True) in (f 3)) (\\x -> x)" with
   | Result.Ok ast ->
     (match w ast with
      | Result.Ok ty -> Format.printf "%a" Pprint.pp_ty ty
      | Result.Error err -> Format.printf "%a" Pprint.pp_error err)
   | _ -> prerr_endline "parsing error");
  [%expect {| unification failed on Bool and Int |}]
;;
