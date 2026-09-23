#!/usr/bin/env bash

# Handler modules share the server runtime initialized by server.sh.
source "$BASE/handlers/health.sh"
source "$BASE/handlers/services.sh"
source "$BASE/handlers/peer-monitoring.sh"
source "$BASE/handlers/traffic-consensus.sh"
source "$BASE/handlers/block-results.sh"
source "$BASE/handlers/nids-response.sh"

PROTOCOL_MISMATCH_LOG_INTERVAL=5
LAST_PROTOCOL_MISMATCH_LOG=0

dispatch_line() {
  local line="$1"

  [[ -z "${line:-}" ]] && {
    log DEBUG "Prazna linija"
    return 0
  }

  if [[ "$line" =~ ^(Server:|Date:|Content-Type:|Content-Length:) ]]; then
    log DEBUG \
      "Ignoriram HTTP header spill: $line"

    return 0
  fi

  local TYPE
  local AGENT

  read -r TYPE AGENT _ <<<"$line"

  # Prihvacamo samo poznate poruke aplikacijskog protokola.
  # Binarni ili drugi nevaljani ulaz moze znaciti TLS/plaintext mismatch.
  local possible_tls_mismatch=0

  case "$TYPE" in
    NIDS_ALERT|BLOCK_RESULT|HEARTBEAT|SERVICE_STATUS|TRAFFIC_ALERT|CONFIRM_RESPONSE|BANNER|BANNER_EMPTY|NEW_DEVICE|PEER_STATE|COMMAND_BLOCK)
      ;;
    *)
      if [[ "${TLS_ENABLE:-0}" == "0" ]]; then
        possible_tls_mismatch=1

        local now
        now="$(date +%s)"

        if (( now - LAST_PROTOCOL_MISMATCH_LOG >= PROTOCOL_MISMATCH_LOG_INTERVAL )); then
          log WARNING \
            "PROTOCOL_MISMATCH local_tls=0 reason=INVALID_MESSAGE_TYPE possible_tls_mismatch=1"

          LAST_PROTOCOL_MISMATCH_LOG="$now"
        fi
      else
        log DEBUG \
          "INVALID_MESSAGE_TYPE local_tls=1"
      fi

      return 0
      ;;
  esac

  # NIDS nije klasični host-agent pa se njegove poruke
  # obrađuju prije validate_agent().
  case "$TYPE" in

    NIDS_ALERT)
      handle_nids_alert "$line"
      return 0
      ;;

    BLOCK_RESULT)
      handle_block_result "$line"
      return 0
      ;;
  esac

  if ! validate_agent "${AGENT:-}"; then
    log WARNING \
      "Nepoznat agent '${AGENT:-?}'; linija='$line'"

    return 0
  fi

  case "$TYPE" in

    HEARTBEAT)
      handle_heartbeat "$line" "$AGENT"
      ;;

    SERVICE_STATUS)
      handle_service_status "$line" "$AGENT"
      ;;

    TRAFFIC_ALERT)
      handle_traffic_alert "$line"
      ;;

    CONFIRM_RESPONSE)
      handle_confirm_response "$line"
      ;;

    BANNER)
      handle_banner "$line" "$AGENT"
      ;;

    BANNER_EMPTY)
      handle_banner_empty "$line" "$AGENT"
      ;;

    NEW_DEVICE)
      handle_new_device "$line" "$AGENT"
      ;;

    PEER_STATE)
      handle_peer_state "$line" "$AGENT"
      ;;

    COMMAND_BLOCK)
      log ACTION "$line"
      ;;

    *)
      log DEBUG \
        "Ignoriram liniju: $line"
      ;;
  esac
}

start_server_listener() {
  local line
  local listener_pid
  local listener_fd

  # Ncat radi kao zaseban coprocess.
  # Glavni Bash proces ostaje vlasnik runtime stanja:
  #
  # last_heartbeat[]
  # agent_health_state[]
  # failure_map[]
  # confirm_map[]
  coproc SERVER_NCAT {
    "${NCAT_BASE[@]}" \
      2>>"$LOG_DIR/ncat_listener.err"
  }

  listener_pid="$SERVER_NCAT_PID"
  listener_fd="${SERVER_NCAT[0]}"

  while kill -0 "$listener_pid" 2>/dev/null; do

    # Čekaj poruku najviše WATCHDOG_INTERVAL sekundi.
    #
    # Ako poruka stigne:
    #   -> dispatch_line
    #
    # Ako ne stigne:
    #   -> read timeout
    #
    # U oba slučaja nakon toga provjeravamo heartbeatove.
    if IFS= read \
        -r \
        -t "$WATCHDOG_INTERVAL" \
        -u "$listener_fd" \
        line; then

      dispatch_line "$line"
    fi

    check_agent_health
    check_confirmation_timeouts
  done

  wait "$listener_pid" 2>/dev/null || true
}
