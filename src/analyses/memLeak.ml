(** An analysis for the detection of memory leaks ([memLeak]). *)

open GoblintCil
open Analyses
open MessageCategory

module ToppedVarInfoSet = SetDomain.ToppedSet(CilType.Varinfo)(struct let topname = "All Heap Variables" end)

module Spec : Analyses.MCPSpec =
struct
  include Analyses.IdentitySpec

  let name () = "memLeak"

  module D = ToppedVarInfoSet
  module C = Lattice.Unit

  let context _ _ = ()

  (* HELPER FUNCTIONS *)
  let warn_for_multi_threaded ctx =
    if not (ctx.ask (Queries.MustBeSingleThreaded { since_start = true })) then
      M.warn ~category:(Behavior (Undefined MemoryLeak)) ~tags:[CWE 401] "Program isn't running in single-threaded mode. A memory leak might occur due to multi-threading"

  let check_for_mem_leak ?(assert_exp_imprecise = false) ?(exp = None) ctx =
    let state = ctx.local in
    if not @@ D.is_empty state then
      match assert_exp_imprecise, exp with
      | true, Some exp -> M.warn ~category:(Behavior (Undefined MemoryLeak)) ~tags:[CWE 401] "assert expression %a is unknown. Memory leak might possibly occur for heap variables: %a" d_exp exp D.pretty state
      | _ -> M.warn ~category:(Behavior (Undefined MemoryLeak)) ~tags:[CWE 401] "Memory leak detected for heap variables: %a" D.pretty state

  (* TRANSFER FUNCTIONS *)
  let return ctx (exp:exp option) (f:fundec) : D.t =
    (* Returning from "main" is one possible program exit => need to check for memory leaks *)
    if f.svar.vname = "main" then check_for_mem_leak ctx;
    ctx.local

  let special ctx (lval:lval option) (f:varinfo) (arglist:exp list) : D.t =
    let state = ctx.local in
    let desc = LibraryFunctions.find f in
    match desc.special arglist with
    | Malloc _
    | Calloc _
    | Realloc _ ->
      (* Warn about multi-threaded programs as soon as we encounter a dynamic memory allocation function *)
      warn_for_multi_threaded ctx;
      begin match ctx.ask Queries.HeapVar with
        | `Lifted var -> D.add var state
        | _ -> state
      end
    | Free ptr ->
      begin match ctx.ask (Queries.MayPointTo ptr) with
        | a when not (Queries.LS.is_top a) && not (Queries.LS.mem (dummyFunDec.svar, `NoOffset) a) && Queries.LS.cardinal a = 1 ->
          (* Note: Need to always set "ana.malloc.unique_address_count" to a value > 0 *)
          let unique_pointed_to_heap_vars =
            Queries.LS.filter (fun (v, _) -> ctx.ask (Queries.IsHeapVar v) && not @@ ctx.ask (Queries.IsMultiple v)) a
            |> Queries.LS.elements
            |> List.map fst
            |> D.of_list
          in
          D.diff state unique_pointed_to_heap_vars
        | _ -> state
      end
    | Abort ->
      (* An "Abort" special function indicates program exit => need to check for memory leaks *)
      check_for_mem_leak ctx;
      state
    | Assert { exp; _ } ->
      let warn_for_assert_exp =
        match ctx.ask (Queries.EvalInt exp) with
        | a when Queries.ID.is_bot a -> M.warn ~category:Assert "assert expression %a is bottom" d_exp exp
        | a ->
          begin match Queries.ID.to_bool a with
            | Some b ->
              (* If we know for sure that the expression in "assert" is false => need to check for memory leaks *)
              if b = false then
                check_for_mem_leak ctx
              else ()
            | None -> check_for_mem_leak ctx ~assert_exp_imprecise:true ~exp:(Some exp)
          end
      in
      warn_for_assert_exp;
      state
    | _ -> state

  let startstate v = D.bot ()
  let exitstate v = D.top ()
end

let _ =
  MCP.register_analysis (module Spec : MCPSpec)