(*-------------------------------------------------------------------------
 * Copyright (c) 2021 Bikal Gurung. All rights reserved.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License,  v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
*-------------------------------------------------------------------------*)

module Arg = struct
  type 'a witness = ..

  type (_, _) eq = Eq : ('a, 'a) eq

  module type Ty = sig
    type t

    val witness : t witness

    val eq : 'a witness -> ('a, t) eq option
  end

  type 'a id = (module Ty with type t = 'a)

  let new_id (type a) () =
    let module Ty = struct
      type t = a

      type 'a witness += Ty : t witness

      let witness = Ty

      let eq (type b) : b witness -> (b, t) eq option = function
        | Ty -> Some Eq
        | _ -> None
    end in
    (module Ty : Ty with type t = a)

  let eq : type a b. a id -> b id -> (a, b) eq option =
   fun (module TyA) (module TyB) -> TyB.eq TyA.witness

  type 'a t =
    { name : string (* name e.g. int, float, bool, string etc *)
    ; decode : string -> 'a option
    ; id : 'a id
    }

  let create ~name ~decode =
    let id = new_id () in
    { name; decode; id }

  let int = create ~name:"int" ~decode:int_of_string_opt

  let float = create ~name:"float" ~decode:float_of_string_opt

  let string = create ~name:"string" ~decode:(fun a -> Some a)

  let bool = create ~name:"bool" ~decode:bool_of_string_opt
end

type 'a arg = 'a Arg.t

let create_arg = Arg.create

module type Arg = sig
  type t

  val t : t arg
end

(** [('a, 'b) uri] represents a uniform resource identifier. The variant members
    describe the uri component types.

    - Literal Uri path literal string component eg. 'home' in '/home'
    - Arg Uri path argument component, i.e. the value is determined during
      runtime, eg. ':int' in '/home/:int' *)
type ('a, 'b) uri =
  | Nil : ('b, 'b) uri
  | Full_splat : ('b, 'b) uri
  | Trailing_slash : ('b, 'b) uri
  | Literal : string * ('a, 'b) uri -> ('a, 'b) uri
  | Arg : 'c Arg.t * ('a, 'b) uri -> ('c -> 'a, 'b) uri

type 'c route = Route : ('a, 'c) uri * 'a -> 'c route

let ( >- ) : ('a, 'b) uri -> 'a -> 'b route = fun uri f -> Route (uri, f)

module Uri_type = struct
  (** Defines existential to encode uri component type. *)
  type t =
    | PTrailing_slash : t
    | PFull_splat : t
    | PLiteral : string -> t
    | PArg : 'c Arg.t -> t

  let equal a b =
    match (a, b) with
    | PTrailing_slash, PTrailing_slash -> true
    | PFull_splat, PFull_splat -> true
    | PLiteral lit', PLiteral lit -> String.equal lit lit'
    | PArg arg', PArg arg -> (
      match Arg.eq arg.id arg'.id with
      | Some Arg.Eq -> true
      | None -> false)
    | _ -> false

  (* [of_uri uri] converts [uri] to [kind list]. This is done to get around OCaml
     type inference issue when using [uri] type in the [add] function below. *)
  let rec of_uri : type a b. (a, b) uri -> t list = function
    | Nil -> []
    | Trailing_slash -> [ PTrailing_slash ]
    | Full_splat -> [ PFull_splat ]
    | Literal (lit, uri) -> PLiteral lit :: of_uri uri
    | Arg (arg, uri) -> PArg arg :: of_uri uri
end

(** ['a t] is a node in a trie based router. *)
type 'a node =
  { route : 'a route option
  ; uri_types : (Uri_type.t * 'a node) list
  }

let rec add node (Route (path, _) as route) =
  let rec loop node = function
    | [] -> { node with route = Some route }
    | path_kind :: path_kinds ->
      List.find_opt
        (fun (path_kind', _) -> Uri_type.equal path_kind path_kind')
        node.uri_types
      |> (function
           | Some _ ->
             List.map
               (fun (path_kind', t') ->
                 if Uri_type.equal path_kind path_kind' then
                   (path_kind', loop t' path_kinds)
                 else
                   (path_kind', t'))
               node.uri_types
           | None -> (path_kind, loop empty path_kinds) :: node.uri_types)
      |> update_path node
  in
  loop node (Uri_type.of_uri path)

and empty : 'a node = { route = None; uri_types = [] }

and update_path t uri_types = { t with uri_types }

type 'a t =
  { route : 'a route option
  ; uri_types : (Uri_type.t * 'a t) array
  }

let rec create routes = List.fold_left add empty routes |> compile

and compile : 'a node -> 'a t =
 fun t ->
  { route = t.route
  ; uri_types =
      List.rev t.uri_types
      |> List.map (fun (uri_kind, t) -> (uri_kind, compile t))
      |> Array.of_list
  }

type decoded_value = D : 'c Arg.t * 'c -> decoded_value

let rec match' t uri =
  let rec loop t decoded_values = function
    | [] ->
      Option.map
        (fun (Route (path, f)) ->
          exec_route_handler f (path, List.rev decoded_values))
        t.route
    | path_token :: path_tokens ->
      let continue = ref true in
      let index = ref 0 in
      let matched_node = ref None in
      let full_splat_matched = ref false in
      while !continue && !index < Array.length t.uri_types do
        Uri_type.(
          match t.uri_types.(!index) with
          | PArg arg, t' -> (
            match arg.decode path_token with
            | Some v ->
              matched_node := Some (t', D (arg, v) :: decoded_values);
              continue := false
            | None -> incr index)
          | PLiteral lit, t' when String.equal lit path_token ->
            matched_node := Some (t', decoded_values);
            continue := false
          | PTrailing_slash, t' when String.equal "" path_token ->
            matched_node := Some (t', decoded_values);
            continue := false
          | PFull_splat, t' ->
            matched_node := Some (t', decoded_values);
            continue := false;
            full_splat_matched := true
          | _ -> incr index)
      done;
      Option.bind !matched_node (fun (t', decoded_values) ->
          if !full_splat_matched then
            (loop [@tailcall]) t' decoded_values []
          else
            (loop [@tailcall]) t' decoded_values path_tokens)
  in
  let uri = String.trim uri in
  if String.length uri > 0 then
    loop t [] (uri_tokens uri)
  else
    None

and uri_tokens s =
  let uri = Uri.of_string s in
  let uri_tokens = Uri.path uri |> String.split_on_char '/' |> List.tl in
  Uri.query uri
  |> List.map (fun (k, v) ->
         if List.length v > 0 then
           [ k; List.hd v ]
         else
           [ k ])
  |> List.concat
  |> List.append uri_tokens

and exec_route_handler : type a b. a -> (a, b) uri * decoded_value list -> b =
 fun f -> function
  | Nil, [] -> f
  | Full_splat, [] -> f
  | Trailing_slash, [] -> f
  | Literal (_, uri), decoded_values ->
    exec_route_handler f (uri, decoded_values)
  | Arg ({ id; _ }, uri), D ({ id = id'; _ }, v) :: decoded_values -> (
    match Arg.eq id id' with
    | Some Arg.Eq -> exec_route_handler (f v) (uri, decoded_values)
    | None -> assert false)
  | _, _ -> assert false

module Private = struct
  let nil = Nil

  let trailing_slash = Trailing_slash

  let full_splat = Full_splat

  let lit s uri = Literal (s, uri)

  let arg a p = Arg (a, p)

  let int = Arg.int

  let float = Arg.float

  let bool = Arg.bool

  let string = Arg.string
end
