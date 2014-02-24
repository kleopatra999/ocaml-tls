open Core

let ref _ = raise (Failure "no.")

let o f g x = f (g x)

module Server = struct

  let (<>) = Utils.cs_append

  type content_type = Packet.content_type

  type crypto_context = {
    sequence      : int64 ;
    stream_cipher : Cryptokit.Stream.stream_cipher option ; (* XXX *)
    cipher        : Ciphersuite.encryption_algorithm ;
    cipher_secret : string ;
    cipher_iv     : string ;
    mac           : Ciphersuite.hash_algorithm ;
    mac_secret    : string
  }

  (* EVERYTHING a cipher needs, be it input or output. And pure, too. *)
  type crypto_state = [
    `Nothing
  | `Crypted of crypto_context
  ]

  type connection_end = Server | Client

  type security_parameters = {
    entity        : connection_end ;
    ciphersuite   : Ciphersuite.ciphersuite ;
    master_secret : string ;
    client_random : Cstruct.t ;
    server_random : Cstruct.t ;
  }

  (* EVERYTHING a well-behaved dispatcher needs. And pure, too. *)
  type tls_internal_state = [
      `Initial
    | `Handshaking of security_parameters * Cstruct.t list
    | `KeysExchanged of crypto_state * crypto_state * security_parameters * Cstruct.t list
    | `Established
  ]

  let state_to_string = function
    | `Initial -> "Initial"
    | `Handshaking _ -> "Shaking hands"
    | `KeysExchanged _ -> "Keys are exchanged"
    | `Established -> "Established"

  let answer_client_finished (sp : security_parameters) (packets : Cstruct.t list) (buf : Cstruct.t) (raw : Cstruct.t)  =
    let msgs = Cstruct.copyv packets in
    let computed = Crypto.finished sp.master_secret "client finished" msgs in
    let checksum = Cstruct.copy buf 0 12 in
    assert (computed = checksum);
    let my_check = Crypto.finished sp.master_secret "server finished" (msgs ^ Cstruct.copy raw 0 (Cstruct.len raw)) in
    let send = Writer.assemble_handshake (Finished (Cstruct.of_string my_check)) in
    (`Established, [`Record (Packet.HANDSHAKE, send)], `Pass)


  let answer_client_key_exchange (sp : security_parameters) (packets : Cstruct.t list) (kex : Cstruct.t) (raw : Cstruct.t) =
    let data = Cstruct.copy kex 0 (Cstruct.len kex) in
    Ciphersuite.(match ciphersuite_kex sp.ciphersuite with
                 | RSA ->
                    let pms = Crypto.decryptRSA (Crypto_utils.get_key "server.key") data in
                    let premastersecret = String.sub pms ((String.length pms) - 48) 48 in
                    let cr = Cstruct.copy sp.client_random 0 32 in
                    let sr = Cstruct.copy sp.server_random 0 32 in
                    let mastersecret = Crypto.generate_master_secret premastersecret (cr ^ sr) in
                    Printf.printf "master secret\n";
                    Cstruct.hexdump (Cstruct.of_string mastersecret);

                    let key, iv, mac = ciphersuite_cipher_mac_length sp.ciphersuite in
                    let keyblocklength =  2 * key + 2 * mac + 2 * iv in
                    let keyblock = Crypto.key_block keyblocklength mastersecret (sr ^ cr) in

                    let c_mac, off = (String.sub keyblock 0 mac, mac) in
                    let s_mac, off = (String.sub keyblock off mac, off + mac) in
                    let c_key, off = (String.sub keyblock off key, off + key) in
                    let s_key, off = (String.sub keyblock off key, off + key) in
                    let c_iv, off = (String.sub keyblock off iv, off + iv) in
                    let s_iv = String.sub keyblock off iv in

                    let mac = ciphersuite_mac sp.ciphersuite in
                    let sequence = Int64.of_int 0 in
                    let cipher = ciphersuite_cipher sp.ciphersuite in

                    let c_stream_cipher, s_stream_cipher =
                      match cipher with
                      | RC4_128 ->
                         let ccipher = new Cryptokit.Stream.arcfour c_key in
                         let scipher = new Cryptokit.Stream.arcfour s_key in
                         (Some ccipher, Some scipher)
                      | _ -> (None, None)
                    in

                    let c_context =
                      { stream_cipher = c_stream_cipher ;
                        cipher_secret = c_key ;
                        cipher_iv = c_iv ;
                        mac_secret = c_mac ;
                        cipher ; mac ; sequence } in
                    let s_context =
                      { stream_cipher = s_stream_cipher ;
                        cipher_secret = s_key ;
                        cipher_iv = s_iv ;
                        mac_secret = s_mac ;
                        cipher ; mac ; sequence }
                    in
                    let params = { sp with master_secret = mastersecret } in
                    (`KeysExchanged (`Crypted s_context, `Crypted c_context, params, packets @ [raw]), [], `Pass)
                 | _ -> assert false)

  let answer_client_hello (ch : client_hello) raw =
    let cipher = Ciphersuite.TLS_RSA_WITH_3DES_EDE_CBC_SHA in
    assert (List.mem cipher ch.ciphersuites);
    (* TODO : real random *)
    let r = Cstruct.create 32 in
    let params = { entity        = Server ;
                   ciphersuite   = cipher ;
                   master_secret = "" ;
                   client_random = ch.random ;
                   server_random = r } in
    let server_hello : server_hello =
      { version      = (3, 1) ;
        random       = r ;
        sessionid    = None ;
        ciphersuites = cipher ;
        extensions   = [] } in
    let bufs = [Writer.assemble_handshake (ServerHello server_hello)] in
    let kex = Ciphersuite.ciphersuite_kex cipher in
    let bufs' =
      if Ciphersuite.needs_certificate kex then
        (let cert = Crypto_utils.get_cert_from_file "server.pem" in
         bufs @ [Writer.assemble_handshake (Certificate [cert])])
      else
        bufs
    in
    (* TODO: Server Key Exchange *)
    (* server hello done! *)
    let hello_done = Writer.assemble_handshake ServerHelloDone in
    let packets = bufs' @ [hello_done] in
    (`Handshaking (params, raw :: packets),
     List.map (fun e -> `Record (Packet.HANDSHAKE, e)) packets,
     `Pass)

  type record = content_type * Cstruct.t

  (* this is the externally-visible state somebody will keep track of for us. *)
  type state = {
    machina   : tls_internal_state ;
    decryptor : crypto_state ;
    encryptor : crypto_state ;
  }

  let empty_state = { machina = `Initial ;
                      decryptor = `Nothing ;
                      encryptor = `Nothing }


  (* well-behaved pure encryptor *)
  let encrypt : crypto_state -> content_type -> Cstruct.t -> crypto_state * Cstruct.t
  = fun s ty buf ->
      match s with
      | `Nothing -> (s, buf)
      | `Crypted ctx ->
         let sign = Crypto.signature ctx.mac ctx.mac_secret ctx.sequence ty buf in
         let to_encrypt = buf <> sign in
         let enc, next_iv =
           match ctx.stream_cipher with
           | Some x -> (Crypto.crypt_stream x to_encrypt, "")
           | None -> Crypto.encrypt_block ctx.cipher ctx.cipher_secret ctx.cipher_iv to_encrypt
         in
         let add1 = Int64.add (Int64.of_int 1) in
         (`Crypted { ctx with sequence = add1 ctx.sequence ;
                              cipher_iv = next_iv },
          enc)

  (* well-behaved pure decryptor *)
  let decrypt : crypto_state -> content_type -> Cstruct.t -> crypto_state * Cstruct.t
  = fun s ty buf ->
      match s with
      | `Nothing -> (s, buf)
      | `Crypted ctx ->
         let dec, next_iv =
           match ctx.stream_cipher with
           | Some x -> (Crypto.crypt_stream x buf, "")
           | None -> Crypto.decrypt_block ctx.cipher ctx.cipher_secret ctx.cipher_iv buf
         in
         let macstart = (Cstruct.len dec) - (Ciphersuite.hash_length ctx.mac) in
         let body, mac = Cstruct.split dec macstart in
         let cmac = Crypto.signature ctx.mac ctx.mac_secret ctx.sequence ty body in
         assert (Utils.cs_eq cmac mac);
         let add1 = Int64.add (Int64.of_int 1) in
         (`Crypted { ctx with sequence = add1 ctx.sequence ;
                              cipher_iv = next_iv },
          body)

  (* party time *)
  let rec separate_records : Cstruct.t ->  (tls_hdr * Cstruct.t) list
  = fun buf -> (* we assume no fragmentation here *)
    match Cstruct.len buf with
    | 0 -> []
    | _ ->
      let (hdr, buf', len) = Reader.parse_hdr buf in
      (hdr, buf') :: separate_records (Cstruct.shift buf len)

  let assemble_records : record list -> Cstruct.t =
    o Utils.cs_appends @@ List.map @@ Writer.assemble_hdr

  type rec_resp = [
    | `Change_enc of crypto_state
    | `Record     of record
  ]
  type dec_resp = [ `Change_dec of crypto_state | `Pass ]

  let handle_record
  : tls_internal_state -> content_type -> Cstruct.t
    -> (tls_internal_state * rec_resp list * dec_resp)
  = fun is ct buf ->
    Printf.printf "HANDLE_RECORD (in state %s) %s\n"
                  (state_to_string is)
                  (Packet.content_type_to_string ct);
    match ct with
    | Packet.ALERT ->
       let al = Reader.parse_alert buf in
       Printf.printf "ALERT: %s" (Printer.alert_to_string al);
       (is, [], `Pass)
    | Packet.APPLICATION_DATA ->
       Printf.printf "APPLICATION DATA";
       Cstruct.hexdump buf;
       (is, [], `Pass)
    | Packet.CHANGE_CIPHER_SPEC ->
       begin
         match is with
         | `KeysExchanged (enc, dec, _, _) ->
            let ccs = Cstruct.create 1 in
            Cstruct.set_uint8 ccs 0 1;
            (is,
             [`Record (Packet.CHANGE_CIPHER_SPEC, ccs); `Change_enc enc],
             `Change_dec dec)
         | _ -> assert false
       end
    | Packet.HANDSHAKE ->
       begin
         match (is, Reader.parse_handshake buf) with
         | `Initial, ClientHello ch ->
              answer_client_hello ch buf
         | `Handshaking (p, bs), ClientKeyExchange kex ->
              answer_client_key_exchange p bs kex buf
         | `KeysExchanged (_, _, p, bs), Finished fin ->
              answer_client_finished p bs fin buf
         | `Established, ClientHello ch -> (* key renegotiation *)
              answer_client_hello ch buf
         | _, _-> assert false
       end
    | _ -> assert false

  let handle_raw_record state (hdr, buf) =
    let (dec_st, dec) = decrypt state.decryptor hdr.content_type buf in
    let (machina, items, dec_cmd) =
      handle_record state.machina hdr.content_type dec in
    let (encryptor, encs) =
      let rec loop st = function
        | [] -> (st, [])
        | `Change_enc st'   :: xs -> loop st' xs
        | `Record (ty, buf) :: xs ->
            let (st1, enc ) = encrypt st ty buf in
            let (st2, rest) = loop st1 xs in
            (st2, (ty, enc) :: rest)
      in
      loop state.encryptor items in
    let decryptor = match dec_cmd with
      | `Change_dec dec -> dec
      | `Pass           -> dec_st in
    ({ machina ; encryptor ; decryptor }, encs)

  let handle_tls : state -> Cstruct.t -> state * Cstruct.t
  = fun state buf ->
    let in_records = separate_records buf in
    let (state', out_records) =
      let rec loop st = function
        | []    -> (st, [])
        | r::rs ->
            let (st1, raw_rs ) = handle_raw_record st r in
            let (st2, raw_rs') = loop st1 rs in
            (st2, raw_rs @ raw_rs') in
      loop state in_records in
    let buf' = assemble_records out_records in
    (state', buf')

end
