(**
 * Copyright (c) 2017, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)

open Core
open Hhbc_ast
open Instruction_sequence
open Emit_expression

module A = Ast
module H = Hhbc_ast
module TC = Hhas_type_constraint
module SN = Naming_special_names
module CBR = Continue_break_rewriter

(* Context for code generation. It would be more elegant to pass this
 * around in an environment parameter. *)
let verify_return = ref false
let default_return_value = ref instr_null
let default_dropthrough = ref None
let set_verify_return b = verify_return := b
let set_default_return_value i = default_return_value := i
let set_default_dropthrough i = default_dropthrough := i

let emit_return () =
  if !verify_return
  then gather [instr_verifyRetTypeC; instr_retc]
  else instr_retc

let rec emit_stmt st =
  match st with
  | A.Expr (_, A.Yield_break) ->
    gather [
      instr_null;
      emit_return ();
    ]
  | A.Expr (_, A.Call ((_, A.Id (_, "unset")), exprl, [])) ->
    gather (List.map exprl emit_unset_expr)
  | A.Expr expr ->
    emit_ignored_expr expr
  | A.Return (_, None) ->
    gather [
      instr_null;
      emit_return ();
    ]
  | A.Return (_,  Some expr) ->
    gather [
      from_expr expr;
      emit_return ();
    ]
  | A.GotoLabel (_, label) ->
    instr_label (Label.named label)
  | A.Goto (_, label) ->
    instr_jmp (Label.named label)
  | A.Block b -> emit_stmts b
  | A.If (condition, consequence, alternative) ->
    emit_if condition (A.Block consequence) (A.Block alternative)
  | A.While (e, b) ->
    emit_while e (A.Block b)
  | A.Break _ ->
    instr_break 1 (* TODO: Break takes an argument *)
  | A.Continue _ ->
    instr_continue 1 (* TODO: Continue takes an argument *)
  | A.Do (b, e) ->
    emit_do (A.Block b) e
  | A.For (e1, e2, e3, b) ->
    emit_for e1 e2 e3 (A.Block b)
  | A.Throw e ->
    gather [
      from_expr e;
      instr (IContFlow Throw);
    ]
  | A.Try (try_block, catch_list, finally_block) ->
    if catch_list <> [] && finally_block <> [] then
      emit_stmt (A.Try([A.Try (try_block, catch_list, [])], [], finally_block))
    else if catch_list <> [] then
      emit_try_catch (A.Block try_block) catch_list
    else
      emit_try_finally (A.Block try_block) (A.Block finally_block)

  | A.Switch (e, cl) ->
    emit_switch e cl
  | A.Foreach (collection, await_pos, iterator, block) ->
    emit_foreach (await_pos <> None) collection iterator
      (A.Block block)
  | A.Def_inline _ ->
    emit_nyi "Def_inline"
  | A.Static_var es ->
    emit_static_var es
  (* TODO: What do we do with unsafe? *)
  | A.Unsafe
  | A.Fallthrough
  | A.Noop -> empty

and emit_if condition consequence alternative =
  match alternative with
  | A.Block []
  | A.Block [A.Noop] ->
    let done_label = Label.next_regular () in
    gather [
      emit_jmpz condition done_label;
      emit_stmt consequence;
      instr_label done_label;
    ]
  | _ ->
    let alternative_label = Label.next_regular () in
    let done_label = Label.next_regular () in
    gather [
      emit_jmpz condition alternative_label;
      emit_stmt consequence;
      instr_jmp done_label;
      instr_label alternative_label;
      emit_stmt alternative;
      instr_label done_label;
    ]

and emit_static_var es =
  let emit_static_var_single e =
    match snd e with
    | A.Lvar (_, name) ->
      gather [
        instr_null;
        instr_static_loc_init name;
      ]
    | A.Binop (A.Eq _, (_, A.Lvar (_, name)), (_, A.Id (_, _) as e))
    | A.Binop (A.Eq _, (_, A.Lvar (_, name)), (_, A.Class_const (_, _) as e)) ->
      let l = Label.next_regular () in
      gather [
        instr_static_loc name;
        instr_jmpnz l;
        from_expr e;
        instr_setl @@ Local.Named name;
        instr_popc;
        instr_label l;
      ]
    | A.Binop (A.Eq _, (_, A.Lvar (_, name)), e) ->
      gather [
        from_expr e;
        instr_static_loc_init name;
      ]
    | _ -> failwith "Static var - impossible"
  in
  gather @@ List.map es ~f:emit_static_var_single

and emit_while e b =
  let break_label = Label.next_regular () in
  let cont_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  (* TODO: This is *bizarre* codegen for a while loop.
  It would be better to generate this as
  instr_label continue_label;
  from_expr e;
  instr_jmpz break_label;
  body;
  instr_jmp continue_label;
  instr_label break_label;
  *)
  let instrs = gather [
    emit_jmpz e break_label;
    instr_label start_label;
    emit_stmt b;
    instr_label cont_label;
    emit_jmpnz e start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_do b e =
  let cont_label = Label.next_regular () in
  let break_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  let instrs = gather [
    instr_label start_label;
    emit_stmt b;
    instr_label cont_label;
    emit_jmpnz e start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_for e1 e2 e3 b =
  let break_label = Label.next_regular () in
  let cont_label = Label.next_regular () in
  let start_label = Label.next_regular () in
  (* TODO: this is bizarre codegen for a "for" loop.
     This should be codegen'd as
     emit_ignored_expr initializer;
     instr_label start_label;
     from_expr condition;
     instr_jmpz break_label;
     body;
     instr_label continue_label;
     emit_ignored_expr increment;
     instr_jmp start_label;
     instr_label break_label;
  *)
  let instrs = gather [
    emit_ignored_expr e1;
    emit_jmpz e2 break_label;
    instr_label start_label;
    emit_stmt b;
    instr_label cont_label;
    emit_ignored_expr e3;
    emit_jmpnz e2 start_label;
    instr_label break_label;
  ] in
  CBR.rewrite_in_loop instrs cont_label break_label None

and emit_switch scrutinee_expr cl =
  stash_in_local scrutinee_expr
  begin fun local break_label ->
  (* If there is no default clause, add an empty one at the end *)
  let is_default c = match c with A.Default _ -> true | _ -> false in
  let cl =
    if List.exists cl is_default
    then cl
    else cl @ [A.Default []] in
  (* "continue" in a switch in PHP has the same semantics as break! *)
  let cl = List.map cl ~f:emit_case in
  let bodies = gather @@ List.map cl ~f:snd in
  let init = gather @@ List.map cl
    ~f: begin fun x ->
          let (e_opt, l) = fst x in
          match e_opt with
          | None ->
            instr_jmp l
          | Some e ->
            (* Special case for simple scrutinee *)
            match scrutinee_expr with
            | (_, A.Lvar _) ->
              gather [from_expr e; instr_cgetl2 local; instr_eq; instr_jmpnz l]
            | _ ->
              gather [instr_cgetl local; from_expr e; instr_eq; instr_jmpnz l]
        end
  in
  let instrs = gather [
    init;
    bodies;
  ] in
CBR.rewrite_in_switch instrs break_label
  end

and emit_catch end_label ((_, catch_type), (_, catch_local), b) =
    (* Note that this is a "regular" label; we're not going to branch to
    it directly in the event of an exception. *)
    let next_catch = Label.next_regular () in
    gather [
      instr_dup;
      instr_instanceofd catch_type;
      instr_jmpz next_catch;
      instr_setl (Local.Named catch_local);
      instr_popc;
      emit_stmt (A.Block b);
      instr_jmp end_label;
      instr_label next_catch;
    ]

and emit_catches catch_list end_label =
  gather (List.map catch_list ~f:(emit_catch end_label))

and emit_try_catch try_block catch_list =
  let end_label = Label.next_regular () in
  let catch_label = Label.next_catch () in
  let try_body = gather [
    emit_stmt try_block;
    instr_jmp end_label;
  ] in
  gather [
    instr_try_catch_begin catch_label;
    try_body;
    instr_try_catch_end;
    instr_label catch_label;
    instr_catch;
    emit_catches catch_list end_label;
    instr_throw;
    instr_label end_label;
  ]

and emit_try_finally try_block finally_block =
  (*
  We need to generate four things:
  (1) the try-body, which will be followed by
  (2) the normal-continuation finally body, and
  (3) an epilogue to the finally body that deals with finally-blocked
      break and continue
  (4) the exceptional-continuation fault body.
  *)

  (* (1) Try body

  The try body might have un-rewritten continues and breaks which
  branch to a label outside of the try. This means that we must
  first run the normal-continuation finally, and then branch to the
  appropriate label.

  We do this by running a rewriter which turns continues and breaks
  inside the try body into setting temp_local to an integer which indicates
  what action the finally must perform when it is finished, followed by a
  jump directly to the finally.
  *)
  let try_body = emit_stmt try_block in
  let temp_local = Local.get_unnamed_local () in
  let finally_start = Label.next_regular () in
  let finally_end = Label.next_regular () in
  let cont_and_break = CBR.get_continues_and_breaks try_body in
  let try_body = CBR.rewrite_in_try_finally
    try_body cont_and_break temp_local finally_start in

  (* (2) Finally body

  Note that this is used both in the normal-continuation and
  exceptional-continuation cases; we generate the same code twice.

  TODO: We might consider changing the codegen so that the finally block
  is only generated once. We could do this by making the fault block set a
  temp local to -1, and then branch to the finally block. In the finally block
  epilogue it can check to see if the local is -1, and if so, issue an unwind
  instruction.

  It is illegal to have a continue or break which branches out of a finally.
  Unfortunately we at present do not detect this at parse time; rather, we
  generate an exception at run-time by rewriting continue and break
  instructions found inside finally blocks.

  TODO: If we make this illegal at parse time then we can remove this pass.
  *)
  let finally_body = emit_stmt finally_block in
  let finally_body = CBR.rewrite_in_finally finally_body in

  (* (3) Finally epilogue *)

  let finally_epilogue =
    CBR.emit_finally_epilogue cont_and_break temp_local finally_end in

  (* (4) Fault body

  We now emit the fault body; it is just cleanup code for the temp_local,
  a copy of the finally body (without the branching epilogue, since we are
  going to unwind rather than branch), and an unwind instruction.

  TODO: The HHVM emitter sometimes emits seemingly spurious
  unset-unnamed-local instructions into the fault block.  These look
  like bugs in the emitter. Investigate; if they are bugs in the HHVM
  emitter, get them fixed there. If not, get a clear explanation of
  what they are for and why they are required.
  *)

  let cleanup_local =
    if cont_and_break = [] then empty else instr_unsetl temp_local in
  let fault_body = gather [
      cleanup_local;
      finally_body;
      instr_unwind;
    ] in
  let fault_label = Label.next_fault () in
  (* Put it all together. *)
  gather [
    instr_try_fault fault_label try_body fault_body;
    instr_label finally_start;
    finally_body;
    finally_epilogue;
    instr_label finally_end;
  ]

and get_foreach_lvalue e =
  match e with
  | A.Lvar (_, x) -> Some (Local.Named x)
  | _ -> None

and get_foreach_key_value iterator =
  match iterator with
  | A.As_kv ((_, k), (_, v)) ->
    begin match get_foreach_lvalue v with
    | None -> None
    | Some v_lid ->
      match get_foreach_lvalue k with
      | None -> None
      | Some k_lid ->
        Some (Some k_lid, v_lid)
    end
  | A.As_v (_, v) ->
    begin match get_foreach_lvalue v with
    | None -> None
    | Some lid -> Some (None, lid)
    end

and emit_foreach _has_await collection iterator block =
  (* TODO: await *)
  (* TODO: generate .numiters based on maximum nesting depth *)
  (* TODO: We need to be able to process arbitrary lvalues in the key, value
     pair. This will require writing a preamble into the block, in the general
     case. For now we just support locals. *)
  let iterator_number = Iterator.get_iterator () in
  let fault_label = Label.next_fault () in
  let loop_break_label = Label.next_regular () in
  let loop_continue_label = Label.next_regular () in
  let loop_head_label = Label.next_regular () in
  match get_foreach_key_value iterator with
  | None -> emit_nyi "foreach codegen does not support arbitrary lvalues yet"
  | Some (k, v) ->
    let init, next = match k with
    | Some k ->
      let init = instr_iterinitk iterator_number loop_break_label v k in
      let cont = instr_iternextk iterator_number loop_head_label v k in
      init, cont
    | None ->
      let init = instr_iterinit iterator_number loop_break_label v in
      let cont = instr_iternext iterator_number loop_head_label v in
      init, cont in
    let body = emit_stmt block in
    let result = gather [
      from_expr collection;
      init;
      instr_try_fault
        fault_label
        (* try body *)
        (gather [
          instr_label loop_head_label;
          body;
          instr_label loop_continue_label;
          next
        ])
        (* fault body *)
        (gather [
          instr_iterfree iterator_number;
          instr_unwind ]);
      instr_label loop_break_label
    ] in
    Iterator.free_iterator ();
    CBR.rewrite_in_loop
      result loop_continue_label loop_break_label (Some iterator_number)

and emit_stmts stl =
  let results = List.map stl emit_stmt in
  gather results

and emit_case c =
  let l = Label.next_regular () in
  let b = match c with
    | A.Default b
    | A.Case (_, b) ->
        emit_stmt (A.Block b)
  in
  let e = match c with
    | A.Case (e, _) -> Some e
    | _ -> None
  in
  (e, l), gather [instr_label l; b]

let emit_dropthrough_return () =
  match !default_dropthrough with
  | Some instrs -> instrs
  | _ ->
    gather [!default_return_value; emit_return ()]

let rec emit_final_statement s =
  match s with
  | A.Throw _ | A.Return _ | A.Goto _ ->
    emit_stmt s
  | A.Block b ->
    emit_final_statements b
  | _ ->
    gather [
      emit_stmt s;
      emit_dropthrough_return ()
    ]

and emit_final_statements b =
  match b with
  | [] -> emit_dropthrough_return ()
  | [s] -> emit_final_statement s
  | s::b ->
    let i1 = emit_stmt s in
    let i2 = emit_final_statements b in
    gather [i1; i2]
