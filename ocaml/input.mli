(** Use this to read in a program.

    TODO: Add convenience functions to get SSA directly, and maybe more input
    options.
*)

open Arch
open Arg
open Grammar_scope

(** A speclist suitable to pass to Arg.parse.
    Add this to the speclist for your program. *)
val speclist : (key * spec * doc) list

(** A speclist with only streaming inputs *)
val stream_speclist : (key * spec * doc) list

(** A speclist with only trace inputs *)
val trace_speclist : (key * spec * doc) list

(** Get the program as specified by the commandline. *)
val get_program : unit -> Ast.program * Scope.t * arch option

val get_stream_program : unit -> (Ast.program) Stream.t * arch option

val init_ro : bool ref

(* Rate to stream frames at *)
val streamrate : int64 ref

(** [get_arch (Some x)] returns [x], and [get_arch None] raises an
    informational exception. *)
val get_arch : arch option -> arch
