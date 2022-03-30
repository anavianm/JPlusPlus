(* Semantic checking for the MicroC compiler *)

open Ast
open Sast

module StringMap = Map.Make(String)

(* Semantic checking of the AST. Returns an SAST if successful,
   throws an exception if something is wrong.

   Check each global variable, then check each function *)

let check (classes) =
  let check_class (currClass) = 
    (* Check if a certain kind of binding has void type or is a duplicate
     of another, previously checked binding *)
    let check_binds (kind : string) (to_check : bind list) = 
      let name_compare (_, n1) (_, n2) = compare n1 n2 in
      let check_it checked binding = 
        let void_err = "illegal void " ^ kind ^ " " ^ snd binding
        and dup_err = "duplicate " ^ kind ^ " " ^ snd binding
        in match binding with
          (* No void bindings *)
          (Void, _) -> raise (Failure void_err)
        | (_, n1) -> match checked with
                      (* No duplicate bindings *)
                        ((_, n2) :: _) when n1 = n2 -> raise (Failure dup_err)
                      | _ -> binding :: checked

      in let _ = List.fold_left check_it [] (List.sort name_compare to_check) 
        in to_check
    in 

    let check_ivdecls (to_check: ivdecl list) = 
      let ivname_compare d1 d2 = compare d1.iname d2.iname in
      let ivcheck_it checked ivar = 
        let void_err = "illegal void field " ^ ivar.iname
        and dup_err = "duplicate field " ^ ivar.iname
        in match ivar.ityp with
          (* No void bindings *)
          Void -> raise (Failure void_err)
        | _ -> match checked with
                      (* No duplicate bindings *)
                        (sivar2 :: _) when ivar.iname = sivar2.siname -> raise (Failure dup_err)
                      | _ -> let sivar = {spub = ivar.pub;
                                          sityp = ivar.ityp;
                                          siname = ivar.iname} 
                             in sivar :: checked

      in let checked_sivars = List.fold_left ivcheck_it [] (List.sort ivname_compare to_check) 
        in checked_sivars
    in

    (* TODO::IF weird bug check 'to_check' *)

    (* Check Fields *)

    let fields' = check_ivdecls currClass.fields in

    (* TODO Built-in functions*)

    let built_in_decls = 
      let add_bind map (name, ty) = StringMap.add name {
        priv = false;
        typ = Void; 
        fname = name; 
        formals = [(ty, "x")];
        locals = []; body = [] } map
      in List.fold_left add_bind StringMap.empty [ ("printi", Int);
                                 ("printb", Bool);
                                 ("printf", Float);
                                 ("print", Str);
                                 ("printbig", Int) ] in

    (* Add function name to symbol table *)
    let add_method map md = 
      let built_in_err = "function " ^ md.fname ^ " may not be defined"
      and dup_err = "duplicate method " ^ md.fname
      and make_err er = raise (Failure er)
      and n = currClass.cname ^ md.fname (* Name of the class ^ function *) (*TODO POssible bug?*)
      in match md with (* No duplicate functions or redefinitions of built-ins *)
          _ when StringMap.mem n built_in_decls -> make_err built_in_err
        | _ when StringMap.mem n map -> make_err dup_err  
        | _ ->  StringMap.add n md map 
    in

    (* Collect all other function names into one symbol table *)
    let method_decls = List.fold_left add_method built_in_decls currClass.methods
    in
    
    (* Return a method from our symbol table *)
    let find_method cname s = 
      try StringMap.find (cname ^ s) method_decls
      with Not_found -> raise (Failure ("unrecognized method " ^ s ^ " in class " ^ cname))
    in

    (* Check Methods *)

    let check_method currmethod = 
      (* Make sure no formals or locals are void or duplicates *)
      let formals' = check_binds "formal" currmethod.formals in
      let locals' = check_binds "local" currmethod.locals in

      (* Raise an exception if the given rvalue type cannot be assigned to
       the given lvalue type *)
      let check_assign lvaluet rvaluet err =
        if lvaluet = rvaluet then lvaluet else raise (Failure err)
      in   

      (* Build local symbol table of variables for this function *)
      let symbols = List.fold_left (fun m (ty, name) -> StringMap.add name ty m)
          StringMap.empty (formals' @ locals')
      in

      (* Return a variable from our local symbol table *)
      let type_of_identifier s =
        try StringMap.find s symbols
        with Not_found -> raise (Failure ("undeclared identifier " ^ s))
      in


      (* Return a semantically-checked expression, i.e., with a type *)
      let rec expr = function
          Literal  l  -> (Int, SLiteral l)
        | Fliteral l  -> (Float, SFliteral l)
        | BoolLit l   -> (Bool, SBoolLit l)
        | StringLit l -> (Str,  SStringLit l)
        | Noexpr      -> (Void, SNoexpr)
        | Id s        -> (type_of_identifier s, SId s)
        | Assign(var, e) as ex -> 
            let lt = type_of_identifier var
            and (rt, e') = expr e in
            let err = "illegal assignment " ^ string_of_typ lt ^ " = " ^ 
              string_of_typ rt ^ " in " ^ string_of_expr ex
            in (check_assign lt rt err, SAssign(var, (rt, e')))
        | Unop(op, e) as ex -> 
            let (t, e') = expr e in
            let ty = match op with
              Neg when t = Int || t = Float -> t
            | Not when t = Bool -> Bool
            | _ -> raise (Failure ("illegal unary operator " ^ 
                                  string_of_uop op ^ string_of_typ t ^
                                  " in " ^ string_of_expr ex))
            in (ty, SUnop(op, (t, e')))
        | Binop(e1, op, e2) as e -> 
            let (t1, e1') = expr e1 
            and (t2, e2') = expr e2 in
            (* All binary operators require operands of the same type *)
            let same = t1 = t2 in
            (* Determine expression type based on operator and operand types *)
            let ty = match op with
              Add | Sub | Mult | Div when same && t1 = Int   -> Int
            | Add | Sub | Mult | Div when same && t1 = Float -> Float
            | Equal | Neq            when same               -> Bool
            | Less | Leq | Greater | Geq
                      when same && (t1 = Int || t1 = Float) -> Bool
            | And | Or when same && t1 = Bool -> Bool
            | _ -> raise (
          Failure ("illegal binary operator " ^
                        string_of_typ t1 ^ " " ^ string_of_op op ^ " " ^
                        string_of_typ t2 ^ " in " ^ string_of_expr e))
            in (ty, SBinop((t1, e1'), op, (t2, e2')))
        | Call(fname, args) as call -> 
            let fd = match fname with
              "printf" -> (find_method "" fname) 
            | "printb" -> (find_method "" fname) 
            | "print" -> (find_method "" fname)
            | "printi" -> (find_method "" fname)
            | "printbig" -> (find_method "" fname) 
            | _ -> (find_method currClass.cname fname)
            in
            let param_length = List.length fd.formals in
            if List.length args != param_length then
              raise (Failure ("expecting " ^ string_of_int param_length ^ 
                              " arguments in " ^ string_of_expr call))
            else let check_call (ft, _) e = 
              let (et, e') = expr e in 
              let err = "illegal argument found " ^ string_of_typ et ^
                " expected " ^ string_of_typ ft ^ " in " ^ string_of_expr e
              in (check_assign ft et err, e')
            in 
            let args' = List.map2 check_call fd.formals args
            in (fd.typ, SCall(fname, args'))
        (* | Mcall(objectId, mname, args) as mcall -> 
            let md = find_method objectId mname in 
            let param_length = List.length md.formals in
            if List.length args != param_length then
              raise (Failure ("expecting " ^ string_of_int param_length ^ 
                              " arguments in " ^ string_of_expr mcall))
            else let check_call (mt, _) e = 
              let (et, e') = expr e in 
              let err = "illegal argument found " ^ string_of_typ et ^
                " expected " ^ string_of_typ mt ^ " in " ^ string_of_expr e
              in (check_assign mt et err, e')
            in 
            let args' = List.map2 check_call md.formals args
            in (md.typ, SMCall(objectId, mname, args')) *)
        | _ -> raise (Failure "fail!!!!")

      in

      let check_bool_expr e = 
        let (t', e') = expr e
        and err = "expected Boolean expression in " ^ string_of_expr e
        in if t' != Bool then raise (Failure err) else (t', e') 
      in

      (* Return a semantically-checked statement i.e. containing sexprs *)
      let rec check_stmt = function
          Expr e -> SExpr (expr e)
        | If(p, b1, b2) -> SIf(check_bool_expr p, check_stmt b1, check_stmt b2)
        | For(e1, e2, e3, st) ->
      SFor(expr e1, check_bool_expr e2, expr e3, check_stmt st)
        | While(p, s) -> SWhile(check_bool_expr p, check_stmt s)
        | Return e -> let (t, e') = expr e in
          if t = currmethod.typ then SReturn (t, e') 
          else raise (
      Failure ("return gives " ^ string_of_typ t ^ " expected " ^
        string_of_typ currmethod.typ ^ " in " ^ string_of_expr e))
        
        (* A block is correct if each statement is correct and nothing
          follows any Return statement.  Nested blocks are flattened. *)
        | Block sl -> 
            let rec check_stmt_list = function
                [Return _ as s] -> [check_stmt s]
              | Return _ :: _   -> raise (Failure "nothing may follow a return")
              | Block sl :: ss  -> check_stmt_list (sl @ ss) (* Flatten blocks *)
              | s :: ss         -> check_stmt s :: check_stmt_list ss
              | []              -> []
            in SBlock(check_stmt_list sl)

      in (* body of check_function *)
      { spriv = currmethod.priv;
        styp = currmethod.typ;
        sfname = currmethod.fname;
        sformals = formals';
        slocals  = locals';
        sbody = match check_stmt (Block currmethod.body) with
      SBlock(sl) -> sl
        | _ -> let err = "internal error: block didn't become a block?"
        in raise (Failure err)
      }

    in 
    {
      scname = currClass.cname; 
      spname = currClass.pname; 
      sfields = fields';
      smethods = (List.map check_method currClass.methods);
    }
  in (List.map check_class classes)
