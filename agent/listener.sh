#!/usr/bin/env bash


validate_ipv4() {
  local ip="$1"
  local o1 o2 o3 o4 octet

  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"

  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( 10#$octet > 255 )); then
      return 1
    fi
  done

  return 0
}

start_listener() {
  local NCAT_LISTEN=(ncat --listen --keep-open --recv-only -p 6000)

  # --------------------------------------------------
  # TLS listener
  # --------------------------------------------------

  if [[ "$TLS_ENABLE" == "1" ]]; then

    if [[ ! -f "$TLS_CERT" ]]; then
      log ERROR "TLS certifikat ne postoji: $TLS_CERT"
      return 1
    fi

    if [[ ! -f "$TLS_KEY" ]]; then
      log ERROR "TLS privatni kljuĂ„Ĺ¤ ne postoji: $TLS_KEY"
      return 1
    fi

    NCAT_LISTEN+=(
      --ssl
      --ssl-cert "$TLS_CERT"
      --ssl-key "$TLS_KEY"
    )
  fi


  # --------------------------------------------------
  # Listener
  # --------------------------------------------------

  "${NCAT_LISTEN[@]}" 2>"$LOG_DIR/listener.err" | while IFS= read -r line; do

    [[ -z "${line:-}" ]] && continue


    # --------------------------------------------------
    # Distribuirana potvrda anomalije
    # --------------------------------------------------

    if [[ "$line" =~ ^CONFIRM_REQUEST[[:space:]] ]]; then
      local INCIDENT_ID
      local TARGET_IP
      local SRC_IP
      local PING_OK=0
      local PORT80_OK=0
      local CONFIRM_STATE
      local TS_NOW

      read -r _ INCIDENT_ID TARGET_IP SRC_IP <<<"$line"

      if [[ -z "${INCIDENT_ID:-}" ||
            -z "${TARGET_IP:-}" ||
            -z "${SRC_IP:-}" ]]; then

        log WARNING \
          "Neispravan CONFIRM_REQUEST: $line"

        continue
      fi

      if ! validate_ipv4 "$TARGET_IP" ||
         ! validate_ipv4 "$SRC_IP"; then

        log WARNING \
          "CONFIRM_REQUEST odbijen: neispravan TARGET_IP ili SRC_IP target=${TARGET_IP:-?} src=${SRC_IP:-?}"

        continue
      fi

      if ping -c1 -W1 "$TARGET_IP" >/dev/null 2>&1; then
        PING_OK=1
      fi

      if timeout 2 bash -c 'echo > "/dev/tcp/$1/80"' _ "$TARGET_IP" \
          >/dev/null 2>&1; then
        PORT80_OK=1
      fi

      if (( PING_OK == 1 && PORT80_OK == 1 )); then
        CONFIRM_STATE="HEALTHY"

      elif (( PING_OK == 0 && PORT80_OK == 0 )); then
        CONFIRM_STATE="UNREACHABLE"

      else
        CONFIRM_STATE="DEGRADED"
      fi

      TS_NOW=$(date +%s)

      send_server \
        "CONFIRM_RESPONSE $AGENT_ID $INCIDENT_ID $TARGET_IP $CONFIRM_STATE ping=$PING_OK port80=$PORT80_OK ts=$TS_NOW"

      log PEER \
        "CONFIRM incident_id=$INCIDENT_ID target=$TARGET_IP src=$SRC_IP state=$CONFIRM_STATE ping=$PING_OK port80=$PORT80_OK"

      continue
    fi


    # --------------------------------------------------
    # Blokiranje IP adrese
    # --------------------------------------------------

    if [[ "$line" =~ ^COMMAND_BLOCK ]]; then
      local BLOCK_IP

      BLOCK_IP=$(awk '{print $2}' <<<"$line")

      if ! validate_ipv4 "$BLOCK_IP"; then
        log WARNING "COMMAND_BLOCK odbijen: neispravan BLOCK_IP=$BLOCK_IP"
        continue
      fi

      iptables \
        -C INPUT \
        -s "$BLOCK_IP" \
        -j DROP \
        2>/dev/null \
        || iptables \
          -A INPUT \
          -s "$BLOCK_IP" \
          -j DROP \
          -m comment \
          --comment "nadzor-mreze"

      log ACTION "BLOCK $BLOCK_IP"

      continue
    fi


    # --------------------------------------------------
    # Restart servisa
    # --------------------------------------------------

    if [[ "$line" =~ ^COMMAND_RESTART ]]; then
      local svc

      svc=$(awk '{print $2}' <<<"$line")

      restart_unit "$svc"

      continue
    fi

  done
}


# --------------------------------------------------
# Listener supervisor
# --------------------------------------------------

start_listener_supervisor() {
  (
    while true; do

      if ! ss -lntp 2>/dev/null | grep -q ':6000'; then
        start_listener &
        sleep 1
      fi

      sleep 3

    done
  ) &
}
