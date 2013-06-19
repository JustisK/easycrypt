(* -------------------------------------------------------------------- *)
(* Expressions / formulas matching for tactics                          *)
(* -------------------------------------------------------------------- *)

(* -------------------------------------------------------------------- *)
open EcUtils
open EcMaps
open EcIdent
open EcParsetree
open EcEnv
open EcTypes
open EcModules
open EcFol
open EcBaseLogic

(* -------------------------------------------------------------------- *)
module Zipper = struct
  exception InvalidCPos

  module P = EcPath

  type ('a, 'state) folder =
    'a -> 'state -> instr -> 'state * instr list

  type ipath =
  | ZTop
  | ZWhile  of expr * spath
  | ZIfThen of expr * spath * stmt
  | ZIfElse of expr * stmt  * spath

  and spath = (instr list * instr list) * ipath

  type zipper = {
    z_head : instr list;                (* instructions on my left (rev)       *)
    z_tail : instr list;                (* instructions on my right (me incl.) *)
    z_path : ipath ;                    (* path (zipper) leading to me         *)
  }

  let zipper hd tl zpr = { z_head = hd; z_tail = tl; z_path = zpr; }
    
  let rec zipper_of_cpos ((i, sub) : codepos) zpr s =
    let (s1, i, s2) =
      try  List.split_n (i-1) s.s_node 
      with Not_found -> raise InvalidCPos
    in
    match sub with
    | None -> zipper s1 (i::s2) zpr
    | Some (b, sub) -> begin
      match i.i_node, b with
      | Swhile (e, sw), 0 ->
          zipper_of_cpos sub (ZWhile (e, ((s1, s2), zpr))) sw
      | Sif (e, ifs1, ifs2), 0 ->
          zipper_of_cpos sub (ZIfThen (e, ((s1, s2), zpr), ifs2)) ifs1
      | Sif (e, ifs1, ifs2), 1 ->
          zipper_of_cpos sub (ZIfElse (e, ifs1, ((s1, s2), zpr))) ifs2
      | _ -> raise InvalidCPos
    end

  let zipper_of_cpos cpos s = zipper_of_cpos cpos ZTop s

  let rec zip i ((hd, tl), ip) =
    let s = stmt (List.rev_append hd (List.ocons i tl)) in

    match ip with
    | ZTop -> s
    | ZWhile  (e, sp)     -> zip (Some (i_while (e, s))) sp
    | ZIfThen (e, sp, se) -> zip (Some (i_if (e, s, se))) sp
    | ZIfElse (e, se, sp) -> zip (Some (i_if (e, se, s))) sp

  let zip zpr = zip None ((zpr.z_head, zpr.z_tail), zpr.z_path)

  let after ~strict zpr =
    let rec doit acc ip =
      match ip with
      | ZTop                          -> acc
      | ZWhile  (_, ((_, is), ip))    -> doit (is :: acc) ip
      | ZIfThen (_, ((_, is), ip), _) -> doit (is :: acc) ip
      | ZIfElse (_, _, ((_, is), ip)) -> doit (is :: acc) ip
    in

    let after =
      match zpr.z_tail, strict with
      | []     , _     -> doit [[]] zpr.z_path
      | is     , false -> doit [is] zpr.z_path
      | _ :: is, true  -> doit [is] zpr.z_path
    in
      List.rev after

  let rec fold env cpos f state s =
    let zpr = zipper_of_cpos cpos s in

      match zpr.z_tail with
      | []      -> raise InvalidCPos
      | i :: tl -> begin
          match f env state i with
          | (state', [i']) when i == i' && state == state' -> (state, s)
          | (state', si  ) -> (state', zip { zpr with z_tail = si @ tl })
      end
end

(* -------------------------------------------------------------------- *)
module IMatch = struct
  type spattern =
  | IM_Instr   of ipattern list
  | IM_Repeat  of spattern * int * int option
  | IM_Group   of spattern
  | IM_Concat  of spattern list

  and ipattern =
  | IP_While
  | IP_IfThen
  | IP_Any

  type t = spattern

  type token = [
    | `LParen | `RParen
    | `LBrace | `RBrace
    | `LBrack | `RBrack
    | `Any
    | `Plus
    | `Star
    | `QMark
    | `Int   of int
    | `CharS of string
  ]

  exception CompilationFailure
  exception LexError

  let isdigit = function '0' .. '9' -> true | _ -> false
  let islower = function 'a' .. 'z' -> true | _ -> false

  let lexwhile cond stream =
    let aout = Buffer.create 15 in
    let rec doit () =
      match Stream.peek stream with
      | Some c when cond c ->
          Stream.junk stream;
          Buffer.add_char aout c;
          doit ()
      | _ -> Buffer.contents aout
    in
      doit ()

  let lexint stream =
    int_of_string (lexwhile isdigit stream)

  let lexlow stream =
    lexwhile islower stream

  let lex (stream : char Stream.t) : token option =
    let aspunct = function
      | '(' -> Some `LParen
      | ')' -> Some `RParen
      | '{' -> Some `LBrace
      | '}' -> Some `RBrace
      | '[' -> Some `LBrack
      | ']' -> Some `RBrack
      | '+' -> Some `Plus
      | '*' -> Some `Star
      | '?' -> Some `QMark
      | '_' -> Some `Any
      | _   -> None
    in

    match Stream.peek stream with
    | None -> None
    | Some c when isdigit c -> Some (`Int   (lexint stream))
    | Some c when islower c -> Some (`CharS (lexlow stream))
    | Some c ->
      match aspunct c with
      | Some tk -> Stream.junk stream; Some tk
      | None    -> raise LexError

  let lexstream (stream : char Stream.t) : token Stream.t =
    let next (_ : int) = lex stream in
      Stream.from next

  let eat next stream =
    try  next (Stream.next stream)
    with Stream.Failure -> raise CompilationFailure

  let e_eq  tk1 tk2 = if tk1 <> tk2 then raise CompilationFailure
  let e_int tk = match tk with `Int i -> i | _ -> raise CompilationFailure
  let e_low tk = match tk with `CharS s -> s | _ -> raise CompilationFailure

  let ipattern_of_string (s : string) =
    let ipattern_of_char = function
      | 'i' -> IP_IfThen
      | 'w' -> IP_While
      | _   -> raise CompilationFailure
    in

    let acc = ref [] in
      for i = String.length s - 1 downto 0 do
        acc := (ipattern_of_char s.[i]) :: !acc
      done;
      !acc

  let rec compile (stream : token Stream.t) =
    let rec doit seq =
      let junk_and_doit seq = Stream.junk stream; doit seq in

      match Stream.peek stream, seq with
      | None       , _  -> IM_Concat (List.rev seq)
      | Some `Star , [] -> raise CompilationFailure
      | Some `QMark, [] -> raise CompilationFailure

      | Some `Star , r :: rs -> junk_and_doit ((IM_Repeat (r, 0, None  )) :: rs)
      | Some `QMark, r :: rs -> junk_and_doit ((IM_Repeat (r, 0, Some 1)) :: rs)
      | Some `Plus , r :: rs -> junk_and_doit ((IM_Repeat (r, 1, None  )) :: rs)

      | Some `Any, _ -> junk_and_doit ((IM_Instr [IP_Any]) :: seq)

      | Some `LParen, _ ->
          let () = Stream.junk stream in
          let r  = compile stream in
            eat (e_eq `RParen) stream; doit (r :: seq)

      | Some `LBrace, []      -> raise CompilationFailure
      | Some `LBrace, r :: rs ->
          let () = Stream.junk stream in
          let n  = eat (e_int) stream in
          let () = eat (e_eq `RBrace) stream in
            doit ((IM_Repeat (r, n, None)) :: rs)

      | Some `LBrack, _ ->
          let () = Stream.junk stream in
          let cs = eat (e_low) stream in
          let () = eat (e_eq `RBrack) stream in
            doit ((IM_Instr (ipattern_of_string cs)) :: seq)

      | Some (`CharS cs), _ ->
          let () = Stream.junk stream in
          let cs = ipattern_of_string cs in
          let cs = List.map (fun c -> IM_Instr [c]) cs in
            doit ((IM_Concat cs) :: seq)

      | _, _ -> raise CompilationFailure
    in
      doit []

  type mtch = unit

  exception InvalidPattern of string

  let compile pattern =
    try  compile (lexstream (Stream.of_string pattern))
    with CompilationFailure -> raise (InvalidPattern pattern)

  let match_ _ie _is = assert false

  let get _m _i = assert false

  let get_as_while _m _i = assert false

  let get_as_if _m _i = assert false
end

(* -------------------------------------------------------------------- *)
type 'a evmap = Ev of ('a option) Mid.t

module EV = struct
  let empty : 'a evmap = Ev Mid.empty

  let of_idents (ids : ident list) : 'a evmap =
    let m =
      List.fold_left
        (fun m x -> Mid.add x None m)
        Mid.empty ids
    in
      Ev m

  let add (x : ident) (Ev m) =
    Ev (Mid.change (some -| odfl None) x m)

  let get (x : ident) (Ev m) =
    match Mid.find_opt x m with
    | None          -> None
    | Some None     -> Some `Unset
    | Some (Some a) -> Some (`Set a)

  let doget (x : ident) m =
    match get x m with
    | Some (`Set a) -> a
    | _ -> assert false
end

(* -------------------------------------------------------------------- *)
exception MatchFailure

(* Rigid unification, don't cross binders *)
let f_match hyps ue ev ptn subject =
  let ue = EcUnify.UniEnv.copy ue in
  let ev = let Ev ev = ev in ref ev in
  let env = EcEnv.LDecl.toenv hyps in

  let rec doit ptn subject =
    match ptn.f_node, subject.f_node with
    | Flocal x1, Flocal x2 when id_equal x1 x2 -> ()
  
    | Flocal x, _ -> begin
        match Mid.find_opt x !ev with
        | None ->
            raise MatchFailure

        | Some None ->
            ev := Mid.add x (Some subject) !ev

        | Some (Some a) -> begin
            if not (EcReduction.is_alpha_eq hyps subject a) then
              raise MatchFailure
        end
    end
  
    | Fpvar (pv1, m1), Fpvar (pv2, m2) ->
        let pv1 = EcEnv.NormMp.norm_pvar env pv1 in
        let pv2 = EcEnv.NormMp.norm_pvar env pv2 in
          if not (EcTypes.pv_equal pv1 pv2) then
            raise MatchFailure;
          if not (EcMemory.mem_equal m1 m2) then
            raise MatchFailure
  
    | Fif (c1, t1, e1), Fif (c2, t2, e2) ->
        List.iter2 doit [c1; t1; e1] [c2; t2; e2]
  
    | Fint i1, Fint i2 ->
        if i1 <> i2 then raise MatchFailure
  
    | Fapp (f1, fs1), Fapp (f2, fs2) ->
        if List.length fs1 <> List.length fs2 then
          raise MatchFailure;
        List.iter2 doit (f1::fs1) (f2::fs2)
  
    | Fop (op1, tys1), Fop (op2, tys2) -> begin
        if not (EcPath.p_equal op1 op2) then
          raise MatchFailure;
        try  List.iter2 (EcUnify.unify env ue) tys1 tys2
        with EcUnify.UnificationFailure _ -> raise MatchFailure
    end
  
    | Fglob (mp1, me1), Fglob (mp2, me2) ->
        let mp1 = EcEnv.NormMp.norm_mpath env mp1 in
        let mp2 = EcEnv.NormMp.norm_mpath env mp2 in
          if not (EcPath.m_equal mp1 mp2) then
            raise MatchFailure;
          if not (EcMemory.mem_equal me1 me2) then
            raise MatchFailure
  
    | _, _ -> raise MatchFailure

  in
    doit ptn subject; (ue, Ev !ev)

let f_match hyps (ue, ev) ~ptn subject =
  let (ue, Ev ev) = f_match hyps ue ev ptn subject in
    if not (Mid.for_all (fun _ x -> x <> None) ev) then
      raise MatchFailure;
    let clue =
      try  EcUnify.UniEnv.close ue
      with EcUnify.UninstanciateUni _ -> raise MatchFailure
    in
      (ue, clue, Ev ev)

(* -------------------------------------------------------------------- *)
type ptnpos = [`Select | `Sub of ptnpos] Mint.t

exception InvalidPosition

module FPosition = struct
  let occurences =
    let rec doit1 n p =
      match p with
      | `Select -> n+1
      | `Sub p  -> doit n p

    and doit n (ps : ptnpos) =
      Mint.fold (fun _ p n -> doit1 n p) ps n

    in
      fun p -> doit 0 p

  let filter (s : Sint.t) =
    let rec doit1 n p =
      match p with
      | `Select -> (n+1, if Sint.mem n s then None else Some `Select)
      | `Sub p  -> begin
          match doit n p with
          | (n, sub) when Mint.is_empty sub -> (n, None)
          | (n, sub) -> (n, Some (`Sub sub))
      end

    and doit n (ps : ptnpos) =
      Mint.mapi_filter_fold (fun _ p n -> doit1 n p) ps n

    in
      fun p -> snd (doit 0 p)

  let topattern (p : ptnpos) (f : form) =
    let x = EcIdent.create "p" in
  
    let rec doit1 p fp =
      match p with
      | `Select -> f_local x fp.f_ty
      | `Sub p  -> begin
          match fp.f_node with
          | Flocal _ -> raise InvalidPosition
          | Fpvar  _ -> raise InvalidPosition
          | Fglob  _ -> raise InvalidPosition
          | Fop    _ -> raise InvalidPosition
          | Fint   _ -> raise InvalidPosition
  
          | Fquant (q, b, f) ->
              let f' = as_seq1 (doit p [f]) in
                FSmart.f_quant (fp, (q, b, f)) (q, b, f')
  
          | Fif (c, f1, f2)  ->
              let (c', f1', f2') = as_seq3 (doit p [c; f1; f2]) in
                FSmart.f_if (fp, (c, f1, f2)) (c', f1', f2')
  
          | Fapp (f, fs) -> begin
              match doit p fs with
              | [] -> assert false
              | f' :: fs' ->
                  FSmart.f_app (fp, (f, fs, fp.f_ty)) (f', fs', fp.f_ty)
          end
  
          | Ftuple fs ->
              let fs' = doit p fs in
                FSmart.f_tuple (fp, fs) fs'
  
          | Flet (lv, f1, f2) ->
              let (f1', f2') = as_seq2 (doit p [f1; f2]) in
                FSmart.f_let (fp, (lv, f1, f2)) (lv, f1', f2')
  
          | FhoareF   _ -> raise InvalidPosition
          | FhoareS   _ -> raise InvalidPosition
          | FbdHoareF _ -> raise InvalidPosition
          | FbdHoareS _ -> raise InvalidPosition
          | FequivF   _ -> raise InvalidPosition
          | FequivS   _ -> raise InvalidPosition
          | Fpr       _ -> raise InvalidPosition
      end
  
    and doit ps fps =
      match Mint.is_empty ps with
      | true  -> fps
      | false ->
          let imin = fst (Mint.min_binding ps)
          and imax = fst (Mint.max_binding ps) in
          if imin < 0 || imax >= List.length fps then
            raise InvalidPosition;
          let fps = List.mapi (fun i x -> (x, Mint.find_opt i ps)) fps in
          let fps = List.map (function (f, None) -> f | (f, Some p) -> doit1 p f) fps in
            fps
  
    in
      (x, as_seq1 (doit p [f]))
end
