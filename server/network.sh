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


agent_tls_hostname() {
  local ip="$1"
  local hostname

  hostname="$(
    awk -v target_ip="$ip" '
      NF >= 2 && $1 !~ /^#/ && $2 == target_ip {
        print $1
        exit
      }
    ' "$AUTH_LIST"
  )"

  if [[ -z "$hostname" ]]; then
    return 1
  fi

  printf '%s\n' "$hostname"
}


# --------------------------------------------------
# Ncat listener za centralni server
# --------------------------------------------------

init_ncat_base() {
  NCAT_BASE=(
    ncat
    --listen
    --keep-open
    -m 100
    -p "$PORT"
    --idle-timeout 5
  )

  if [[ "$TLS_ENABLE" == "1" ]]; then

    if [[ ! -f "$TLS_CERT" ]]; then
      log ERROR "TLS certifikat servera ne postoji: $TLS_CERT"
      return 1
    fi

    if [[ ! -f "$TLS_KEY" ]]; then
      log ERROR "TLS privatni ključ servera ne postoji: $TLS_KEY"
      return 1
    fi

    NCAT_BASE+=(
      --ssl
      --ssl-cert "$TLS_CERT"
      --ssl-key "$TLS_KEY"
    )
  fi
}


# --------------------------------------------------
# Provjera zauzetosti porta
# --------------------------------------------------

port_in_use() {
  local port="$1"

  ss -lnt 2>/dev/null |
    awk '{print $4}' |
    grep -qE "[:.]$port$"
}


# --------------------------------------------------
# Slanje poruke agentu
#
# VAŽNO:
# Nedostupan agent nije fatalna greška servera.
# Greška se logira, ali server mora nastaviti raditi.
# --------------------------------------------------

send_to_agent() {
  local ip="$1"
  local message="$2"
  local target="$ip"
  local cmd

  if [[ -z "${ip:-}" ]]; then
    log ERROR "Slanje agentu nije moguće: prazna IP adresa"
    return 0
  fi


  # --------------------------------------------------
  # TLS način rada
  # --------------------------------------------------

  if [[ "$TLS_ENABLE" == "1" ]]; then

    if ! tls_ca_ready; then
      return 0
    fi

    if ! target="$(agent_tls_hostname "$ip")"; then
      log ERROR \
        "Ne mogu odrediti TLS hostname za agenta s IP adresom $ip"

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
      "$ip"
      6000
    )

  fi


  # --------------------------------------------------
  # Slanje
  #
  # Greška komunikacije se evidentira, ali funkcija
  # završava uspješno kako set -e ne bi ugasio server.
  # --------------------------------------------------

  if printf '%s\n' "$message" | "${cmd[@]}" 2>/dev/null; then
    return 0
  fi

  log ERROR "Slanje agentu $ip nije uspjelo: $message"

  return 0
}


# --------------------------------------------------
# Lokalno iptables blokiranje
# --------------------------------------------------

iptables_drop_once() {
  local ip="$1"

  sudo -n iptables \
    -C INPUT \
    -s "$ip" \
    -j DROP \
    2>/dev/null \
    ||
  sudo -n iptables \
    -A INPUT \
    -s "$ip" \
    -j DROP \
    -m comment \
    --comment "nadzor-mreze"
}