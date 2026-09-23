#!/usr/bin/env bash

run_initial_checks() {
  local ts
  local ts2
  local i
  local svc
  local prt
  local code

  ts=$(date +%s)
  broadcast "HEARTBEAT $AGENT_ID $ts"

  for i in "${!SERVICES[@]}"; do
    svc="${SERVICES[$i]}"
    prt="${PORTS[$i]}"

    if ! resolve_unit "$svc" >/dev/null; then
      log WARNING "Servis '$svc' ne postoji na ovom hostu, preskačem"
      continue
    fi

    if is_unit_active "$svc"; then
      code=0
    else
      code=1
    fi

    ts2=$(date +%s)
    broadcast "SERVICE_STATUS $AGENT_ID $svc $code $ts2"
  done
}


start_heartbeat_job() {
  (
    while true; do
      sleep "$HEARTBEAT_INT"

      local ts
      ts=$(date +%s)

      broadcast "HEARTBEAT $AGENT_ID $ts"
    done
  ) &
}


start_status_job() {
  (
    while true; do
      local i
      local svc
      local prt
      local code
      local ts3

      sleep "$STATUS_INT"

      for i in "${!SERVICES[@]}"; do
        svc="${SERVICES[$i]}"
        prt="${PORTS[$i]}"

        if ! resolve_unit "$svc" >/dev/null; then
          continue
        fi

        if is_unit_active "$svc"; then
          code=0
        else
          code=1
        fi

        ts3=$(date +%s)
        broadcast "SERVICE_STATUS $AGENT_ID $svc $code $ts3"
      done
    done
  ) &
}


start_latency_job() {
  (
    # Svaki agent lokalno pamti samo vlastita opažanja peerova.
    #
    # peer_failures:
    #   broj uzastopnih ciklusa u kojima nisu dostupni
    #   ni ping ni port 80.
    #
    # peer_states:
    #   zadnje lokalno zaključeno stanje peera.
    declare -A peer_failures=()
    declare -A peer_states=()

    while true; do
      local peer
      local lat
      local pr
      local ts4

      local ping_ok
      local failures
      local state
      local previous_state

      sleep "$LAT_INT"

      for peer in "${PEERS[@]}"; do
        [[ -z "${peer:-}" ]] && continue

        # --------------------------------------------------
        # 1. Ping / latencija
        # --------------------------------------------------

        lat=$(
          ping -c2 -q "$peer" 2>/dev/null |
          awk -F'/' '/min/ {print $5}' ||
          true
        )

        if [[ -n "${lat:-}" ]]; then
          ping_ok=1
        else
          ping_ok=0
          lat="NaN"
        fi

        broadcast "PEER_LATENCY $AGENT_ID $peer $lat"


        # --------------------------------------------------
        # 2. Dostupnost porta 80
        #
        # pr=0 -> port dostupan
        # pr=1 -> port nije dostupan
        # --------------------------------------------------

        if timeout 2 bash -c "echo > /dev/tcp/$peer/80" &>/dev/null; then
          pr=0
        else
          pr=1
        fi

        ts4=$(date +%s)

        broadcast \
          "PEER_PORT $AGENT_ID $peer 80 $pr $ts4"


        # --------------------------------------------------
        # 3. Lokalno zaključivanje stanja peera
        # --------------------------------------------------

        failures="${peer_failures[$peer]:-0}"
        previous_state="${peer_states[$peer]:-UNKNOWN}"

        if (( ping_ok == 1 && pr == 0 )); then

          # Peer odgovara na ping i servis je dostupan.
          state="HEALTHY"
          failures=0

        elif (( ping_ok == 0 && pr == 1 )); then

          # Ne odgovara ni host ni servis.
          # Ne proglašavamo ga odmah nedostupnim zbog
          # jednog neuspjelog mjerenja.
          failures=$(( failures + 1 ))

          if (( failures >= 2 )); then
            state="UNREACHABLE"
          else
            state="DEGRADED"
          fi

        else

          # Jedan signal radi, drugi ne.
          #
          # Primjeri:
          # - ping radi, nginx ne radi
          # - ping ne radi, ali port 80 jest dostupan
          state="DEGRADED"
          failures=0
        fi

        peer_failures["$peer"]=$failures
        peer_states["$peer"]="$state"


        # --------------------------------------------------
        # 4. Sažeti rezultat šaljemo serveru
        # --------------------------------------------------

        send_server \
          "PEER_STATE $AGENT_ID $peer $state latency=$lat port80=$pr failures=$failures ts=$ts4"


        # Lokalno posebno zabilježi promjenu stanja.
        if [[ "$state" != "$previous_state" ]]; then
          log INFO \
            "PEER_STATE peer=$peer old=$previous_state new=$state latency=$lat port80=$pr failures=$failures"
        fi
      done
    done
  ) &
}


start_banner_job() {
  (
    (( BANNER_INT > 0 )) || exit 0

    while true; do
      local peer

      sleep "$BANNER_INT"

      for peer in "${PEERS[@]}"; do
        [[ -n "${peer:-}" ]] && probe_banner_for_ip "$peer"
      done
    done
  ) &
}


start_discovery_job() {
  (
    (( DISCOV_INT > 0 )) || exit 0

    local seen_cache="$LOG_DIR/seen_devices.txt"
    touch "$seen_cache"

    while true; do
      sleep "$DISCOV_INT"

      nmap -sn "$SUBNET" -oG - 2>/dev/null |
      awk '/Up$/{print $2}' |
      while IFS= read -r ip; do
        if ! grep -Fxq "$ip" "$seen_cache"; then
          printf '%s\n' "$ip" >> "$seen_cache"

          local ts5
          ts5=$(date +%s)

          broadcast "NEW_DEVICE $AGENT_ID $ip $ts5"
          log INFO "NEW_DEVICE agent=$AGENT_ID ip=$ip ts=$ts5"
        fi

        if (( BANNER_DISCOVERY )); then
          probe_banner_for_ip "$ip"
        fi
      done
    done
  ) &
}


start_traffic_job() {
  (
    while true; do
      sleep "$TRAFFIC_INT"
      detect_traffic_alert
    done
  ) &
}


start_all_jobs() {
  start_heartbeat_job
  start_status_job
  start_latency_job
  start_banner_job
  start_discovery_job

  # Privremeno isključeno:
  # mrežnu detekciju sada obavlja centralni NIDS
  # start_traffic_job

  start_listener_supervisor
}