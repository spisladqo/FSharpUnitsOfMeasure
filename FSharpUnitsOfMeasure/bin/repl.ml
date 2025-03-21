(** Copyright 2024, Vlasenco Daniel and Kudrya Alexandr *)

(** SPDX-License-Identifier: MIT *)

open Parse.Structure
open Checks
open Interp.Interpret
open Interp.Misc
open Format

type config =
  { mutable file_path : string option
  ; mutable do_not_type : bool
  ; mutable greet_user : bool
  }

let pprog = Angstrom.parse_string ~consume:Angstrom.Consume.All pprog

let help_msg =
  "  F# with units of measure interpreter version 1.0\n\n\
  \  REPL: dune exec ./bin/repl.exe <options>\n\
  \  Read and interpret file: dune exec ./bin/repl.exe <options> --file <filepath>\n\n\
  \  options:\n\
  \   --do-not-type: turn off inference\n\
  \   --no-hi: turn off greeting message and line separators\n\
  \   --help: show this message"
;;

let greetings_msg =
  "───────────────────────────────┬──────────────────────────────────────────────────────────────┬───────────────────────────────\n\
  \                               │ Welcome to F# with units of measure interpreter \
   version 1.0! │                                \n\
  \                               \
   └──────────────────────────────────────────────────────────────┘                                "
;;

let hori_line =
  "───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
;;

let pp_env env =
  Base.Map.iteri
    ~f:(fun ~key ~data ->
      match Base.Map.find env key with
      | Some _ ->
        if not (is_builtin_fun key)
        then
          if is_builtin_op key
          then
            print_endline
              (Format.asprintf "val ( %s ) : %s = %a" key "<type>" pp_value data)
          else
            print_endline (Format.asprintf "val %s : %s = %a" key "<type>" pp_value data)
      | None -> ())
    env;
  printf "\n"
;;

let run_single options =
  (* let run text env = *)
  let run text =
    match pprog text with
    | Error _ -> print_endline (Format.asprintf "Syntax error")
    (* env *)
    | Ok ast ->
      (* Infer *)
      if options.do_not_type = false
      then
        print_endline
          "Inference can't be done. To turn off this message, run REPL with \
           --do-not-type option";
      (match eval ast with
       | Ok (env, out_lst) ->
         List.iter
           (fun v ->
             match v with
             | Ok v' -> print_endline (Format.asprintf "- : %s = %a" "<type>" pp_value v')
             | _ -> ())
           out_lst;
         pp_env env
       | Error e ->
         print_endline (Format.asprintf "Interpreter error: %a" pp_error e);
         if options.greet_user then print_endline hori_line else print_endline "")
  in
  let open In_channel in
  match options.file_path with
  | Some file_name ->
    let text = with_open_bin file_name input_all |> String.trim in
    let _ = run text in
    ()
  | None ->
    let rec input_lines lines =
      match input_line stdin with
      | Some line ->
        if String.ends_with ~suffix:";;" line
        then (
          let _ = run (lines ^ "\n" ^ line) in
          input_lines "")
        else input_lines (lines ^ "\n" ^ line)
      | None -> ()
    in
    let _ = input_lines "" in
    ()
;;

let () =
  let options = { file_path = None; do_not_type = false; greet_user = true } in
  let () =
    let open Arg in
    parse
      [ ( "--file"
        , String (fun filename -> options.file_path <- Some filename)
        , "Read code from the file and interpret" )
      ; ( "--do-not-type"
        , Unit (fun () -> options.do_not_type <- true)
        , "Turn off inference" )
      ; ( "--no-hi"
        , Unit (fun () -> options.greet_user <- false)
        , "Turn off greetings message" )
      ; "--help", Unit (fun () -> print_endline help_msg), "Show help message"
      ]
      (fun _ -> exit 1)
      "REPL"
  in
  if options.greet_user then print_endline greetings_msg;
  run_single options
;;
