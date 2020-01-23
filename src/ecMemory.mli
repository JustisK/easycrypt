(* --------------------------------------------------------------------
 * Copyright (c) - 2012--2016 - IMDEA Software Institute
 * Copyright (c) - 2012--2018 - Inria
 * Copyright (c) - 2012--2018 - Ecole Polytechnique
 *
 * Distributed under the terms of the CeCILL-C-V1 license
 * -------------------------------------------------------------------- *)

(* -------------------------------------------------------------------- *)
open EcSymbols

(* -------------------------------------------------------------------- *)
type memory = EcIdent.t

val mem_equal : memory -> memory -> bool

(* -------------------------------------------------------------------- *)
type local_memtype

val lmem_hash : local_memtype -> int

type memtype = local_memtype option

val mt_hash : memtype -> int

val lmt_equal    : local_memtype -> local_memtype -> bool
val lmt_xpath    : local_memtype -> EcPath.xpath
val lmt_bindings : local_memtype -> ((int*int) option * EcTypes.ty) Msym.t
(* the "int option" indicate if the variable is defined as the projection of
   "arg" or as a variable *)

val mt_equal    : memtype -> memtype -> bool
val mt_xpath    : memtype -> EcPath.xpath
val mt_bindings : memtype -> ((int*int) option * EcTypes.ty) Msym.t
val mt_fv       : memtype -> int EcIdent.Mid.t

(* -------------------------------------------------------------------- *)
type memenv = memory * memtype

val mem_hash : memenv -> int
val me_equal : memenv -> memenv -> bool

(* -------------------------------------------------------------------- *)
exception DuplicatedMemoryBinding of symbol

val memory   : memenv -> memory
val memtype  : memenv -> memtype
val xpath    : memenv -> EcPath.xpath
val bindings : memenv -> ((int*int) option * EcTypes.ty) Msym.t

(* -------------------------------------------------------------------- *)
val empty_local : memory -> EcPath.xpath -> memenv
val abstract    : memory -> memenv

val bindp    : symbol -> (int*int) option -> EcTypes.ty -> memenv -> memenv
val bind     : symbol -> EcTypes.ty -> memenv -> memenv
val bind_proj: int -> int -> symbol -> EcTypes.ty -> memenv -> memenv
val lookup   : symbol -> memenv -> ((int*int) option * EcTypes.ty) option
val is_bound : symbol -> memenv -> bool
val is_bound_pv : EcTypes.prog_var -> memenv -> bool

(* -------------------------------------------------------------------- *)
val mt_subst :
     (EcPath.xpath -> EcPath.xpath)
  -> (EcTypes.ty -> EcTypes.ty)
  -> memtype -> memtype

val mt_substm :
     (EcPath.path -> EcPath.path)
  -> EcPath.mpath EcIdent.Mid.t
  -> (EcTypes.ty -> EcTypes.ty)
  -> memtype -> memtype

val me_subst :
     (EcPath.xpath -> EcPath.xpath)
  -> memory EcIdent.Mid.t
  -> (EcTypes.ty -> EcTypes.ty)
  -> memenv -> memenv

val me_substm :
     (EcPath.path -> EcPath.path)
  -> EcPath.mpath EcIdent.Mid.t
  -> memory EcIdent.Mid.t
  -> (EcTypes.ty -> EcTypes.ty)
  -> memenv -> memenv
