(** Strongly connected component based value numbering.
    
    Currently we only implement the RPO algorithm, described in
    "SCC-Based Value Numbering" by Keith Cooper and Taylor Simpson.
    http://citeseer.ist.psu.edu/41805.html

    TODO: This has been hacked on a bit and could use some cleanup. (Removing
    silly things and making it easier to understand.)

    TODO: canonicalize constants in HInt

    @author Ivan Jager
*)

(* Big picture:

   vn_h maps vars to their value numbers (VN). Vars which map to the same
   VN are belived to be congruent. Everything starts off at T, except
   free variables which are assumed to be unique.

   The [lookup] function tries to find a matching (same operator and
   congruent operants) expression in a hashtable (eid2vn). If none is present
   it adds the expression with a new VN, thereby creating a new equivalence
   class.

   The RPO algorithm works by calling [lookup] for each variable, updating
   vn_h with the new VN, until it reaches a fixed point. At this point,
   if two variables have the same VN, they are equivalent.

   The latice looks like this: Top -> HInt (constant) -> Hash (variable, corresponds to bottom in the CP lattice)

*)


open Type
open Ssa
open ExtList

module VH = Var.VarHash
module C = Cfg.SSA
module G = C.G

module D = Debug.Make(struct let name = "SCCVN" and default=`NoDebug end)
open D

module Dom = Dominator.Make(G)
    

type vn = Top | Hash of Ssa.var | HInt of (int64 * typ)
let top = Top
type expid = 
  | Const of Ssa.value (* Except Var *)
  | Bin of binop_type * vn * vn
  | Un of unop_type * vn
  | Cst of cast_type * typ * vn
  | Unique of var (* for free variables and unknowns *)
  | Ld of vn * vn * vn * typ
  | St of vn * vn * vn * vn * typ
  | Ph of vn list
      
type rpoinfo = { (* private to the SCCVN module *)
  vn_h : vn VH.t; (* maps vars to value numbers *)
  eid2vn : (expid, vn) Hashtbl.t; (* maps expids to value numbers *)
  vn2eid : expid VH.t; (* inverse of eid2vn *)
  (* vn2eid is expid VH.t rather than (vn, expid) Hashtbl.t, since top is
     never used as a key, and the map from HInt is trivial. *)
}

let vn2eid info = function
  | Top -> raise Not_found
  | HInt(i,t) -> Const(Int(i,t))
  | Hash v -> VH.find info.vn2eid v

let hash_to_string = function
  | Top -> "T"
  | Hash v -> "<"^Pp.var_to_string v^">"
  | HInt(i,t) -> Int64.to_string i ^":"^ Pp.typ_to_string t

let meet a b = match (a,b) with
  | (Top, x)
  | (x, Top) ->
      Some x
  | (HInt _, HInt _) when a = b ->
      Some a
  | (Hash x, Hash y) when x == y ->
      Some a
  | (Hash _, Hash _)
  | (HInt _, HInt _) ->
      None
  | ((Hash _ as x), _)
  | (_, (Hash _ as x)) ->
      Some x


(** [node_sdom cfg a b] returns true if position [a] strictly dominates
    position [b]. (where a position is a bbid * distance into the BB) *)
let pos_sdom cfg =
  let {Dom.sdom=sdom;} = Dom.compute_all cfg (G.V.create Cfg.BB_Entry) in
  (fun (a_bb, a_i) (b_bb, b_i) ->
     sdom a_bb b_bb || (a_bb = b_bb && a_i < b_i)
  )

  

let defsite cfg =
  let defsites = VH.create 5700 in
  G.iter_vertex
    (fun b ->
       let rec addone i = function
	 | Move(l,_,_) -> VH.add defsites l (b,i)
	 | _ -> ()
	 in
       List.iteri addone (C.get_stmts cfg b)
    )
    cfg;
  let beforeentry = (C.G.V.create Cfg.BB_Entry, -1) in
  (fun x -> 
     try VH.find defsites x
     with Not_found -> beforeentry (* globals come from before BB_Entry *)
  )


let add_const =
  let name = "fake var for constant"
  and typ = Array(TMem Ast.reg_1, TMem Ast.reg_1) (* BS type *) in
  (fun info c ->
     let eid = Const c in
     let h = match c with
       | Int(i,t) ->
	   HInt(i,t)
       | _ ->
	   let v = Var.newvar name typ in
	   VH.add info.vn2eid v eid;
	   Hash v
     in
     Hashtbl.add info.eid2vn eid h;
     h )

let get_expid info =
  let vn = function
    | (Int _ | Lab _) as v -> (
	try Hashtbl.find info.eid2vn (Const v)
	with Not_found ->
	  add_const info v
      )
    | Var x -> (
	try VH.find info.vn_h x
	with Not_found ->
	  failwith("get_expid: unknown var: "^Pp.var_to_string x)
      )
  in
  fun var -> function
    | Val(Var _ as v) ->
	vn2eid info (vn v) 
    | Val v -> Const v
    | BinOp((PLUS|TIMES|AND|OR|XOR|EQ|NEQ) as op,v1,v2) ->
	let (h1,h2) = (vn v1, vn v2) in
	if h1 <= h2 then Bin(op, h1, h2) else Bin(op, h2, h1)
    | BinOp(op,v1,v2) -> Bin(op, vn v1, vn v2)
    | UnOp(op, v) -> Un(op, vn v)
    | Cast(ct, t, v) -> Cst(ct,t, vn v)
    | Unknown _ -> Unique var
    | Load(m,i,e,t) -> Ld(vn m, vn i, vn e, t)
    | Store(m,i,v,e,t) -> St(vn m, vn i, vn v, vn e, t)
    | Phi vars -> Ph(List.map (fun v -> vn (Var v)) vars)

(* Perform some simplifications on an expid, using constant folding
   and some identities. *)
let opt_expid info var exp =
  let toconst (i,t) = Const(Int(i,t)) in
  let eid = get_expid info var exp in
  let sameas = function
    | Top -> eid
    | vn -> vn2eid info vn
  in
  match eid with
  (* constant folding *)
  | Bin(op, HInt v1, HInt v2) ->
      toconst (Arithmetic.binop op v1 v2)
  | Un(op, HInt v) ->
      toconst (Arithmetic.unop op v)
  | Cst(ct, t, HInt v) ->
      toconst (Arithmetic.cast ct v t)
  (* phis can be constant*)
  | Ph(x::xs) as eid -> (
      match
	List.fold_left
	  (function Some x -> meet x | None -> (fun _ -> None))
	  (Some x) xs
      with
      | None -> eid
      | Some(HInt v) -> toconst v
      | Some(Hash _ as vn) -> vn2eid info vn
      | Some Top -> eid (* FIXME: what to do here? *)
    )
  (* identities on binops *)
  | Bin(AND, _, (HInt(0L,t) as v)) ->
      sameas v
  | Bin(AND, x, HInt(i,t)) when Arithmetic.tos64 (i,t) = -1L ->
      sameas x
  | Bin(OR, x, HInt(0L,_)) ->
      sameas x
  | Bin(OR, _, (HInt(i,t) as v)) when Arithmetic.tos64 (i,t) = -1L ->
      sameas v
  | Bin(XOR, x, HInt(0L,_))
  | Bin(PLUS, x, HInt(0L,_))
  | Bin(LSHIFT, x, HInt(0L,_))
  | Bin(RSHIFT, x, HInt(0L,_))
  | Bin(ARSHIFT, x, HInt(0L,_))
  | Bin(TIMES, x, HInt(1L,_))
  | Bin(DIVIDE, x, HInt(1L,_))
  | Bin(SDIVIDE, x, HInt(1L,_)) ->
      sameas x
  | Bin(AND, x, y)
  | Bin(OR, x, y)
      when x = y ->
      sameas x
  | Bin(XOR, x, y) when x = y ->
      Const(Int(0L, Var.typ var))
  | Bin(LT, _, HInt(0L,_)) ->
      Const(Ssa.val_false)
  | Bin(LE, _, HInt(i,t)) when Arithmetic.tos64 (i,t) = -1L ->
      Const(Ssa.val_true)
	(* TODO: add SLT and SLE. Requires canonicalized ints *)
  | x -> x

(* simplifications in vine_opt which we don't (yet) do here:
   associative optimizations
   a - b = a + -b
   !(a-1) = -a
   redundant casts
*)


let lookup ~opt info var exp =
  let get_eid = if opt then opt_expid else get_expid in
  try
    let eid = get_eid info var exp in
    try Hashtbl.find info.eid2vn eid
    with Not_found ->
      match eid with
      | Const(Var _) -> top
      | Const(Int(i,t)) -> HInt(i,t)
      | _ ->
	  let h = Hash var in
	  Hashtbl.add info.eid2vn eid h;
	  VH.add info.vn2eid var eid;
	  h
  with Not_found -> (* no VNs for subexpressions yet *)
    top
      


module Dfs = Graph.Traverse.Dfs(G)

let fold_postfix_component f g v i=
  let acc = ref i in
  Dfs.postfix_component (fun x -> acc := f x !acc) g v;
  !acc

    
let rpo ~opt cfg =
  let info = {
    vn_h = VH.create 57;
    eid2vn = Hashtbl.create 57;
    vn2eid = VH.create 57;
  }
  in
  (* Contrary to the paper, only assigned SSA variables should have
     their hashes set to Top. Otherwise, uninitialized variables are
     all equivalent. *)
  let filter l = function
    | Move(v,e, _) ->
	VH.add info.vn_h v top;
	(v,e)::l
    | _ -> l
  in
  let moves = (* extract the moves only once *)
    fold_postfix_component
      (fun b l ->
	 List.fold_left filter l (List.rev(C.get_stmts cfg b))
      )
      cfg (C.G.V.create Cfg.BB_Entry) []
  in
  let () = (* add all other uninitialized vars as unique *)
    let vis = object
      inherit Ssa_visitor.nop
      method visit_rvar x =
	if not(VH.mem info.vn_h x) then (
	  dprintf "Adding uninitialized variable %s" (Pp.var_to_string x);
	  let h = Hash x
	  and eid = Unique x in
	  VH.add info.vn_h x h;
	  VH.add info.vn2eid x eid;
	  Hashtbl.add info.eid2vn eid h;
	);
	`DoChildren
    end
    in
    C.G.iter_vertex
    (fun b -> ignore(Ssa_visitor.stmts_accept vis (C.get_stmts cfg b)))
    cfg;
  in
  let vn x = 
    try VH.find info.vn_h x
    with Not_found -> failwith("vn: Unknown var: "^Pp.var_to_string x)
  in
  let lookup = lookup ~opt info in
  let count = ref 0 in
  let changed = ref true in
  while !changed do
    changed := false;
    dprintf "Starting iteration %d" !count;
    incr count;
    List.iter
      (fun (v,e) ->
	 let oldvn = vn v in
	 let temp = lookup v e in
	 if oldvn <> temp (*&& temp <> top*) then (
	   assert(temp <> top); (* FIXME: prove this is always true *)
	   changed := true;
	   dprintf "Updating %s -> %s" (Pp.var_to_string v) (hash_to_string temp);
	   VH.replace info.vn_h v temp
	 ) )
      moves
  done;
  (******** END OF ALGORITHM FROM PAPER ******)
  let inverse = Hashtbl.create (VH.length info.vn_h) in
  let () = VH.iter (fun k v -> Hashtbl.add inverse v k) info.vn_h in
  let hash2equiv = Hashtbl.find_all inverse in
  let vn2eid = vn2eid info in
(*  let () =
    if debug then (
      List.iter
	(fun (v,_) ->
	   let h = vn v in
	   let v2s = Pp.var_to_string in
	   pdebug (v2s v^" = "^hash_to_string h^" "^List.fold_left (fun s v -> s^v2s v^" ") "[" (hash2equiv h) ^"]"))
	moves
    )
  in*)
  (vn,hash2equiv,vn2eid)


let hash_replacement hash2equiv vn2eid defsite psdom =
  let remove_dominated vars =
    let lt (_,d) (_,d') = psdom d d' in
    let rec extract_roots found = function
      | [] -> found
      | first::rest ->
	  let (min,rest) =
	    List.fold_left
	      (fun (m,r) x -> if lt m x then (m,x::r) else (x,m::r))
	      (first,[]) rest
	  in
	  if List.exists (fun x -> lt x min) found then
	    found
	  else
	    extract_roots (min::found) rest
    in
    let var_defsites = List.rev_map (fun x -> (x, defsite x)) vars in
    List.map fst (extract_roots [] var_defsites)
  in
  (* cache the variables that are not dominated by an equivalent variable *)
  let myequiv_ht = Hashtbl.create 5700 in
  let hash2equiv x =
    try Hashtbl.find myequiv_ht x
    with Not_found ->
      let res = remove_dominated (hash2equiv x) in
      Hashtbl.add myequiv_ht x res;
      res
  in
  fun pos hash ->
    let rec find_best p rest =
      match rest with
      | [] -> None
      | v'::tl ->
	  let p' = defsite v' in
	  if psdom p' p then
	    Some v'
	  else find_best p tl
    in
    match vn2eid hash with
    | Unique v when psdom (defsite v) pos ->
	Some(Var v)
    | Const c ->
	Some c
    | _ ->
	match find_best pos (hash2equiv hash) with
	| Some v -> Some(Var v)
	| None -> None

(** Use SCCVN to elliminate redundant expressions, replacing them with a
    previously computed value. Some variables will no longer be used after
    this, so it may be beneficial to run dead code elimination after.

    @param opt Enable constant folding and algebraic simplifications.
    @return the new CFG and a bool indicating whether anything changed.
*)
let replacer ?(opt=true) cfg =
  let () = pdebug "Running rpo algorithm" in
  let (vn,hash2equiv,vn2eid) = rpo ~opt cfg in
  let () = pdebug "Compting dominators" in
  let psdom = pos_sdom cfg in
  let () = pdebug "Computing defsites" in
  let defsite = defsite cfg in
  let hash_replacement = hash_replacement hash2equiv vn2eid defsite psdom in
  let changed = ref false in
  let vis = object
    inherit Ssa_visitor.nop
    val mutable pos = (C.G.V.create Cfg.BB_Entry, 0)
    method set_pos p = pos <- p
    method visit_value = function
      | Ssa.Var v ->
	  (match hash_replacement pos (vn v) with
	   | Some(Ssa.Var var) when v == var -> `SkipChildren
	   | Some v' ->
	       changed := true;
	       dprintf "Replacing var %s with %s" (Pp.var_to_string v) (Pp.value_to_string v');
	       `ChangeTo v'
	   | None -> `SkipChildren
	  )
      | _  -> `SkipChildren

    method visit_stmt = function
      | Ssa.Move(_,Val _, _) -> (* visit value will handle that properly *)
	  `DoChildren
      | Ssa.Move(v,e, a) -> (
	  match hash_replacement pos (vn v) with
	  | Some vl ->
	      changed := true;
	      dprintf "Replacing exp %s with %s" (Pp.ssa_exp_to_string e) (Pp.value_to_string vl);
	      `ChangeTo(Move(v, Val vl, a))
	  | None -> `DoChildren
	)
      | _ -> `DoChildren
  end
  in
  let somechange = ref false in
  let replace b cfg =
    let stmts = 
      List.mapi
	(fun i s ->
	   vis#set_pos (b,i);
	   Ssa_visitor.stmt_accept vis s
	)
	(C.get_stmts cfg b)
    in
    if !changed then (
      somechange := true;
      changed := false;
      C.set_stmts cfg b stmts)
    else cfg
  in
  pdebug "Doing replacement";
  let cfg = G.fold_vertex replace cfg cfg in
  (cfg, !somechange)


(** [aliased cfg] returns a function [f] to tell whether two values are
    aliased. [f x y] returns: Some true when [x=y], Some false when [x<>y],
    or None when it could not statically determine whether [x=y].
*)
let aliased cfg =
  let (vn, _, _) = rpo ~opt:false cfg in
  fun x y -> match (x,y) with
  | (Int(i,_), Int(i',_)) ->
      Some(i = i')
  | (Lab x, Lab y) when x = y ->
      Some true
  | (Var x, Var y) when vn x = vn y ->
      Some true
  | _ -> 
      (* We could also check whether an lval was assigned a constant,
       * but running SCCVN.replace would get rid of any references to
       * such variables anyways. *)
      None


