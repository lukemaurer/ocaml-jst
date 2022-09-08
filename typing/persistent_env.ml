(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*   Xavier Leroy, projet Gallium, INRIA Rocquencourt                     *)
(*   Gabriel Scherer, projet Parsifal, INRIA Saclay                       *)
(*                                                                        *)
(*   Copyright 2019 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Persistent structure descriptions *)

open Misc
open Cmi_format

module Consistbl = Consistbl.Make (Compilation_unit.Name)

let add_delayed_check_forward = ref (fun _ -> assert false)

type error =
  | Illegal_renaming of Compilation_unit.Name.t * Compilation_unit.Name.t * filepath
  | Inconsistent_import of Compilation_unit.Name.t * filepath * filepath
  | Need_recursive_types of Compilation_unit.t
  | Depend_on_unsafe_string_unit of Compilation_unit.t
  | Inconsistent_package_declaration of Compilation_unit.t * filepath
  | Direct_reference_from_wrong_package of Compilation_unit.t * filepath

exception Error of error
let error err = raise (Error err)

module Persistent_signature = struct
  type t =
    { filename : string;
      cmi : Cmi_format.cmi_infos }

  let load = ref (fun ~unit_name ->
      let unit_name = Compilation_unit.Name.to_string unit_name in
      match Load_path.find_uncap (unit_name ^ ".cmi") with
      | filename -> Some { filename; cmi = read_cmi filename }
      | exception Not_found -> None)
end

type can_load_cmis =
  | Can_load_cmis
  | Cannot_load_cmis of EnvLazy.log

type pers_struct = {
  ps_unit: Compilation_unit.t;
  ps_crcs: (Compilation_unit.Name.t * Digest.t option) list;
  ps_filename: string;
  ps_flags: pers_flags list;
}

(* If a .cmi file is missing (or invalid), we
   store it as Missing in the cache. *)
type 'a pers_struct_info =
  | Missing
  | Found of pers_struct * 'a

type 'a t = {
  persistent_structures : 'a pers_struct_info Compilation_unit.Name.Tbl.t;
  imported_units: Compilation_unit.Name.Set.t ref;
  imported_opaque_units: Compilation_unit.Name.Set.t ref;
  crc_units: Consistbl.t;
  can_load_cmis: can_load_cmis ref;
}

let empty () = {
  persistent_structures = Compilation_unit.Name.Tbl.create 17;
  imported_units = ref Compilation_unit.Name.Set.empty;
  imported_opaque_units = ref Compilation_unit.Name.Set.empty;
  crc_units = Consistbl.create ();
  can_load_cmis = ref Can_load_cmis;
}

let clear penv =
  let {
    persistent_structures;
    imported_units;
    imported_opaque_units;
    crc_units;
    can_load_cmis;
  } = penv in
  Compilation_unit.Name.Tbl.clear persistent_structures;
  imported_units := Compilation_unit.Name.Set.empty;
  imported_opaque_units := Compilation_unit.Name.Set.empty;
  Consistbl.clear crc_units;
  can_load_cmis := Can_load_cmis;
  ()

let clear_missing {persistent_structures; _} =
  let missing_entries =
    Compilation_unit.Name.Tbl.fold
      (fun name r acc -> if r = Missing then name :: acc else acc)
      persistent_structures []
  in
  List.iter (Compilation_unit.Name.Tbl.remove persistent_structures)
    missing_entries

let add_import {imported_units; _} s =
  imported_units := Compilation_unit.Name.Set.add s !imported_units

let register_import_as_opaque {imported_opaque_units; _} s =
  imported_opaque_units := Compilation_unit.Name.Set.add s !imported_opaque_units

let find_in_cache {persistent_structures; _} s =
  match Compilation_unit.Name.Tbl.find persistent_structures s with
  | exception Not_found -> None
  | Missing -> None
  | Found (_ps, pm) -> Some pm

let import_crcs penv ~source crcs =
  let {crc_units; _} = penv in
  let import_crc (unit, crco) =
    match crco with
    | None -> ()
    | Some crc ->
        add_import penv unit;
        Consistbl.check crc_units unit crc source
  in List.iter import_crc crcs

let check_consistency penv ps =
  try import_crcs penv ~source:ps.ps_filename ps.ps_crcs
  with Consistbl.Inconsistency {
      unit_name = name;
      inconsistent_source = source;
      original_source = auth;
    } ->
    error (Inconsistent_import(name, auth, source))

let can_load_cmis penv =
  !(penv.can_load_cmis)
let set_can_load_cmis penv setting =
  penv.can_load_cmis := setting

let without_cmis penv f x =
  let log = EnvLazy.log () in
  let res =
    Misc.(protect_refs
            [R (penv.can_load_cmis, Cannot_load_cmis log)]
            (fun () -> f x))
  in
  EnvLazy.backtrack log;
  res

let fold {persistent_structures; _} f x =
  Compilation_unit.Name.Tbl.fold (fun modname pso x -> match pso with
      | Missing -> x
      | Found (_, pm) -> f modname pm x)
    persistent_structures x

(* Reading persistent structures from .cmi files *)

let save_pers_struct penv crc ps pm =
  let {persistent_structures; crc_units; _} = penv in
  let modname = Compilation_unit.name ps.ps_unit in
  Compilation_unit.Name.Tbl.add persistent_structures modname (Found (ps, pm));
  List.iter
    (function
        | Rectypes -> ()
        | Alerts _ -> ()
        | Unsafe_string -> ()
        | Opaque -> register_import_as_opaque penv modname)
    ps.ps_flags;
  Consistbl.set crc_units modname crc ps.ps_filename;
  add_import penv modname

let acknowledge_pers_struct penv check modname pers_sig pm =
  let { Persistent_signature.filename; cmi } = pers_sig in
  let unit = cmi.cmi_unit in
  let crcs = cmi.cmi_crcs in
  let flags = cmi.cmi_flags in
  let ps = { ps_unit = unit;
             ps_crcs = crcs;
             ps_filename = filename;
             ps_flags = flags;
           } in
  let found_name = Compilation_unit.name unit in
  if not (Compilation_unit.Name.equal modname found_name) then
    error (Illegal_renaming(modname, found_name, filename));
  List.iter
    (function
        | Rectypes ->
            if not !Clflags.recursive_types then
              error (Need_recursive_types(unit))
        | Unsafe_string ->
            if Config.safe_string then
              error (Depend_on_unsafe_string_unit(unit));
        | Alerts _ -> ()
        | Opaque -> register_import_as_opaque penv modname)
    ps.ps_flags;
  if check then check_consistency penv ps;
  (* CR lmaurer: Rethink where to put this or else parameterize it. Currently it
     trips up the packager, which is the one thing that *is* allowed to look
     inside *)
  if false && not (Compilation_unit.can_access_by_name unit) then
    error (Direct_reference_from_wrong_package (unit, filename));
  let {persistent_structures; _} = penv in
  Compilation_unit.Name.Tbl.add persistent_structures modname (Found (ps, pm));
  ps

let read_pers_struct penv val_of_pers_sig check modname filename =
  add_import penv modname;
  let cmi = read_cmi filename in
  let pers_sig = { Persistent_signature.filename; cmi } in
  let pm = val_of_pers_sig pers_sig in
  let ps = acknowledge_pers_struct penv check modname pers_sig pm in
  (ps, pm)

let find_pers_struct penv val_of_pers_sig check name =
  let {persistent_structures; _} = penv in
  if Compilation_unit.Name.equal name Compilation_unit.Name.predef_exn then raise Not_found;
  match Compilation_unit.Name.Tbl.find persistent_structures name with
  | Found (ps, pm) -> (ps, pm)
  | Missing -> raise Not_found
  | exception Not_found ->
    match can_load_cmis penv with
    | Cannot_load_cmis _ -> raise Not_found
    | Can_load_cmis ->
        let psig =
          match !Persistent_signature.load ~unit_name:name with
          | Some psig -> psig
          | None ->
            Compilation_unit.Name.Tbl.add persistent_structures name Missing;
            if false then begin
              Format.eprintf "Missing: %a@." Compilation_unit.Name.print name;
              Load_path.get_paths () |> List.iter (fun p ->
                  Format.eprintf " - %s@." p
                );
              Load_path.dump_all ()
            end;
            raise Not_found
        in
        add_import penv name;
        let pm = val_of_pers_sig psig in
        let ps = acknowledge_pers_struct penv check name psig pm in
        (ps, pm)

(* Emits a warning if there is no valid cmi for name *)
let check_pers_struct penv f ~loc name =
  let name_as_string () = Compilation_unit.Name.to_string name in
  try
    ignore (find_pers_struct penv f false name)
  with
  | Not_found ->
      let warn = Warnings.No_cmi_file(name_as_string (), None) in
        Location.prerr_warning loc warn
  | Cmi_format.Error err ->
      let msg = Format.asprintf "%a" Cmi_format.report_error err in
      let warn = Warnings.No_cmi_file(name_as_string (), Some msg) in
        Location.prerr_warning loc warn
  | Error err ->
      let msg =
        match err with
        | Illegal_renaming(name, ps_unit, filename) ->
            Format.asprintf
              " %a@ contains the compiled interface for @ \
               %a when %a was expected"
              Location.print_filename filename
              Compilation_unit.Name.print ps_unit
              Compilation_unit.Name.print name
        | Inconsistent_import _ -> assert false
        | Need_recursive_types unit ->
            Format.asprintf
              "%a uses recursive types"
              Compilation_unit.print unit
        | Depend_on_unsafe_string_unit unit ->
            Format.asprintf "%a uses -unsafe-string"
              Compilation_unit.print unit
        | Inconsistent_package_declaration _ -> assert false
        | Direct_reference_from_wrong_package (unit, _filename) ->
            Format.asprintf "%a is inaccessible from %a"
              Compilation_unit.print unit
              Compilation_unit.Prefix.print
                (Compilation_unit.Prefix.from_clflags ())
      in
      let warn = Warnings.No_cmi_file(name_as_string (), Some msg) in
        Location.prerr_warning loc warn

let read penv f modname filename =
  snd (read_pers_struct penv f true modname filename)

let find penv f name =
  snd (find_pers_struct penv f true name)

let check penv f ~loc name =
  let {persistent_structures; _} = penv in
  if not (Compilation_unit.Name.Tbl.mem persistent_structures name) then begin
    (* PR#6843: record the weak dependency ([add_import]) regardless of
       whether the check succeeds, to help make builds more
       deterministic. *)
    add_import penv name;
    if (Warnings.is_active (Warnings.No_cmi_file("", None))) then
      !add_delayed_check_forward
        (fun () -> check_pers_struct penv f ~loc name)
  end

let crc_of_unit penv f name =
  let (ps, _pm) = find_pers_struct penv f true name in
  let _, crco =
    try
      List.find (fun (name', _crco) ->
          Compilation_unit.Name.equal name' name)
        ps.ps_crcs
    with Not_found ->
      assert false
  in
    match crco with
      None -> assert false
    | Some crc -> crc

let imports {imported_units; crc_units; _} =
  Consistbl.extract (Compilation_unit.Name.Set.elements !imported_units)
    crc_units

let looked_up {persistent_structures; _} modname =
  Compilation_unit.Name.Tbl.mem persistent_structures modname

let is_imported {imported_units; _} s =
  Compilation_unit.Name.Set.mem s !imported_units

let is_imported_opaque {imported_opaque_units; _} s =
  Compilation_unit.Name.Set.mem s !imported_opaque_units

let make_cmi penv comp_unit sign alerts =
  let flags =
    List.concat [
      if !Clflags.recursive_types then [Cmi_format.Rectypes] else [];
      if !Clflags.opaque then [Cmi_format.Opaque] else [];
      (if !Clflags.unsafe_string then [Cmi_format.Unsafe_string] else []);
      [Alerts alerts];
    ]
  in
  let crcs = imports penv in
  {
    cmi_unit = comp_unit;
    cmi_sign = sign;
    cmi_crcs = crcs;
    cmi_flags = flags
  }

let save_cmi penv psig pm =
  let { Persistent_signature.filename; cmi } = psig in
  Misc.try_finally (fun () ->
      let {
        cmi_unit = comp_unit;
        cmi_sign = _;
        cmi_crcs = imports;
        cmi_flags = flags;
      } = cmi in
      let crc =
        output_to_file_via_temporary (* see MPR#7472, MPR#4991 *)
          ~mode: [Open_binary] filename
          (fun temp_filename oc -> output_cmi temp_filename oc cmi) in
      let modname = Compilation_unit.name comp_unit in
      (* Enter signature in persistent table so that imports()
         will also return its crc *)
      let ps =
        { ps_unit = comp_unit;
          ps_crcs = (modname, Some crc) :: imports;
          ps_filename = filename;
          ps_flags = flags;
        } in
      save_pers_struct penv crc ps pm
    )
    ~exceptionally:(fun () -> remove_file filename)

let report_error ppf =
  let open Format in
  function
  | Illegal_renaming(unit, ps_unit, filename) -> fprintf ppf
      "Wrong file naming: %a@ contains the compiled interface for@ \
       %a when %a was expected"
      Location.print_filename filename
      Compilation_unit.Name.print ps_unit
      Compilation_unit.Name.print unit
  | Inconsistent_import(modname, source1, source2) -> fprintf ppf
      "@[<hov>The files %a@ and %a@ \
              make inconsistent assumptions@ over interface %a@]"
      Location.print_filename source1 Location.print_filename source2
      Compilation_unit.Name.print modname
  | Need_recursive_types(import) ->
      fprintf ppf
        "@[<hov>Invalid import of %a, which uses recursive types.@ %s@]"
        Compilation_unit.print import
        "The compilation flag -rectypes is required"
  | Depend_on_unsafe_string_unit(import) ->
      fprintf ppf
        "@[<hov>Invalid import of %a, compiled with -unsafe-string.@ %s@]"
        Compilation_unit.print import
        "This compiler has been configured in strict \
                           safe-string mode (-force-safe-string)"
  | Inconsistent_package_declaration(intf_package, intf_filename) ->
      fprintf ppf
        "@[<hov>The interface %a@ is compiled for package %s.@ %s]"
        Compilation_unit.print intf_package intf_filename
         "The compilation flag -for-pack with the same package is required"
  | Direct_reference_from_wrong_package(unit, filename) ->
      fprintf ppf
        "@[<hov>Invalid reference to %a (in file %s) from package %a.@ %s]"
        Compilation_unit.print unit
        filename
        Compilation_unit.Prefix.print (Compilation_unit.Prefix.from_clflags ())
        "Can only access members of this library's package or a containing package"

let () =
  Location.register_error_of_exn
    (function
      | Error err ->
          Some (Location.error_of_printer_file report_error err)
      | _ -> None
    )
