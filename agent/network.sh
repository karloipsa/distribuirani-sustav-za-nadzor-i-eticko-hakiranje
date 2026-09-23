#!/usr/bin/env bash


# --------------------------------------------------
# TLS pomoćne funkcije
# --------------------------------------------------

tls_ca_ready() {
  if [[ ! -f "$TLS_CA" ]]; then
    log ERROR "TLS CA certifikat ne postoji: $TLS_CA"
    return 1
  fi

  return 0
}


# --------------------------------------------------
# Određivanje TLS hostnamea peera
#
# PEERS u agent.conf ostaju IP adrese.
#
# Kod TLS-a IP prevodimo u hostname preko /etc/hosts:
#
# 192.168.100.2 -> agent-01
# 192.168.100.3 -> agent-02
# 192.168.100.4 -> agent-03
#
# To omogućuje Ncat --ssl-verify provjeru DNS imena
# zapisanog u certifikatu peera.
# --------------------------------------------------

peer_tls_hostname() {
  local peer="$1"
  local hostname=""

  # Ako peer već nije IPv4 adresa, tretiraj ga kao hostname.
  if [[ ! "$peer" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$peer"
    return 0
  fi

  hostname="$(
    getent hosts "$peer" 2>/dev/null |
    awk 'NR == 1 { print $2 }'
  )"

  if [[ -z "$hostname" ]]; then
    return 1
  fi

  printf '%s\n' "$hostname"
}


# --------------------------------------------------
# Slanje poruke centralnom serveru
# --------------------------------------------------

send_server() {
  local msg="$1"
  local target="$SERVER_IP"
  local cmd


  # --------------------------------------------------
  # TLS način rada
  # --------------------------------------------------

  if [[ "$TLS_ENABLE" == "1" ]]; then

    if ! tls_ca_ready; then
      # Komunikacijska greška ne smije ugasiti agenta.
      return 0
    fi

    # Server certifikat ima DNS ime "server".
    target="server"

    if ! getent hosts "$target" >/dev/null 2>&1; then
      log ERROR \
        "TLS hostname '$target' nije moguće razriješiti. Provjeri /etc/hosts."

      return 0
    fi

    cmd=(
      ncat
      --send-only
      -w 2
      --ssl
      --ssl-verify
      --ssl-trustfile "$TLS_CA"
      "$target"
      "$SERVER_PORT"
    )


  # --------------------------------------------------
  # Plaintext način rada
  # --------------------------------------------------

  else

    cmd=(
      ncat
      --send-only
      -w 2
      "$SERVER_IP"
      "$SERVER_PORT"
    )

  fi


  # --------------------------------------------------
  # Slanje
  #
  # Neuspjeh komunikacije se logira, ali se ne vraća
  # fatalni status jer nedostupan server ne smije
  # ugasiti lokalni agent proces.
  # --------------------------------------------------

  local err_detail=""

  if err_detail="$(printf '%s\n' "$msg" | "${cmd[@]}" 2>&1)"; then

    log INFO "Poslano serveru: $msg"

  else

    err_detail="$(
      printf '%s' "$err_detail" |
        tr '\r\n' '  ' |
        sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
    )"

    if [[ "$TLS_ENABLE" == "1" ]]; then
      log ERROR \
        "TLS_CONNECT_FAIL destination=server local_tls=1 target=$target detail=\"${err_detail:-UNKNOWN}\""
    else
      log ERROR \
        "COMM_CONNECT_FAIL destination=server local_tls=0 target=$target detail=\"${err_detail:-UNKNOWN}\""
    fi

  fi

  return 0
}


# --------------------------------------------------
# Slanje poruke peer agentu
# --------------------------------------------------

send_peer() {
  local msg="$1"
  local peer="$2"
  local target="$peer"
  local cmd


  # --------------------------------------------------
  # TLS način rada
  # --------------------------------------------------

  if [[ "$TLS_ENABLE" == "1" ]]; then

    if ! tls_ca_ready; then
      # Nedostupan TLS peer ne smije srušiti agent.
      return 0
    fi

    if ! target="$(peer_tls_hostname "$peer")"; then

      log ERROR \
        "Ne mogu odrediti TLS hostname za peer $peer. Provjeri /etc/hosts."

      return 0
    fi

    if ! getent hosts "$target" >/dev/null 2>&1; then

      log ERROR \
        "TLS hostname '$target' nije moguće razriješiti. Provjeri /etc/hosts."

      return 0
    fi

    cmd=(
      ncat
      --send-only
      -w 2
      --ssl
      --ssl-verify
      --ssl-trustfile "$TLS_CA"
      "$target"
      6000
    )


  # --------------------------------------------------
  # Plaintext način rada
  # --------------------------------------------------

  else

    cmd=(
      ncat
      --send-only
      -w 2
      "$peer"
      6000
    )

  fi


  # --------------------------------------------------
  # Slanje
  #
  # Peer može legitimno biti ugašen ili nedostupan.
  # To je stanje distribuiranog sustava, a ne razlog
  # za završetak lokalnog agent procesa.
  # --------------------------------------------------

  if printf '%s\n' "$msg" | "${cmd[@]}" 2>/dev/null; then

    log PEER "Poslano peeru $peer: $msg"

  else

    log ERROR "Peer $peer nije dostupan: $msg"

  fi

  return 0
}

# --------------------------------------------------
# Slanje poruke poslužitelju
#
# Dodaje kratko nasumično kašnjenje kako više agenata
# ne bi istodobno slalo poruke središnjem poslužitelju.
# --------------------------------------------------

broadcast() {
  local msg="$1"
  local delay

  printf -v delay '0.%03d' $((RANDOM % 200))
  sleep "$delay"

  send_server "$msg"

  return 0
}