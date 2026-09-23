#!/usr/bin/env bash

declare -gA nids_alert_last_seen
declare -gA nids_alert_streak
declare -g RESPONSE_ACTION="ALERT_ONLY"
declare -g RESPONSE_REASON="UNKNOWN"
declare -g RESPONSE_STREAK=0

RESPONSE_REPEAT_WINDOW=30

send_control_to_nids() {
  local message="$1"
  local target="$NIDS_CONTROL_IP"
  local cmd

  if [[ -z "${NIDS_CONTROL_IP:-}" ||
        -z "${NIDS_CONTROL_PORT:-}" ]]; then
    log WARNING "NIDS control endpoint nije konfiguriran"
    return 0
  fi

  if [[ "${TLS_ENABLE:-0}" == "1" ]]; then

    if [[ -z "${TLS_CA:-}" || ! -f "$TLS_CA" ]]; then
      log WARNING \
        "TLS CA nije dostupan za NIDS control: ${TLS_CA:-UNSET}"
      return 0
    fi

    target="nids"

    if ! getent hosts "$target" >/dev/null 2>&1; then
      log WARNING \
        "TLS hostname 'nids' nije moguće razriješiti. Provjeri /etc/hosts."
      return 0
    fi

    cmd=(
      ncat
      --send-only
      --wait 3s
      --wait 3s
      --ssl
      --ssl-verify
      --ssl-trustfile "$TLS_CA"
      "$target"
      "$NIDS_CONTROL_PORT"
    )

  else

    cmd=(
      ncat
      --send-only
      --wait 3s
      --wait 3s
      "$NIDS_CONTROL_IP"
      "$NIDS_CONTROL_PORT"
    )

  fi

  if printf '%s\n' "$message" | "${cmd[@]}" 2>/dev/null; then
    log ACTION \
      "NIDS_CONTROL poslan destination=$target:$NIDS_CONTROL_PORT tls=${TLS_ENABLE:-0}"
    return 0
  fi

  log WARNING \
    "NIDS_CONTROL slanje nije uspjelo destination=$target:$NIDS_CONTROL_PORT tls=${TLS_ENABLE:-0}"

  return 0
}


send_block_request_to_nids() {
  local incident_id="$1"
  local src_ip="$2"
  local ttl="$3"

  if [[ -z "$incident_id" || -z "$src_ip" || -z "$ttl" ]]; then
    log WARNING \
      "send_block_request_to_nids: nedostaje incident_id, src_ip ili ttl"
    return 1
  fi

  send_control_to_nids \
    "BLOCK_REQUEST $incident_id $src_ip $ttl"
}

handle_nids_confirmation_result() {
  local incident_id="$1"
  local target_agent="$2"
  local target_ip="$3"
  local src_ip="$4"
  local result="$5"
  local responded="$6"
  local expected="$7"
  local healthy="$8"
  local degraded="$9"
  local unreachable="${10}"

  if [[ -z "${incident_id:-}" ||
        -z "${target_agent:-}" ||
        -z "${target_ip:-}" ||
        -z "${src_ip:-}" ]]; then

    log WARNING \
      "NIDS_CONFIRM_RESULT odbijen: nedostaju podaci"

    return 0
  fi

  log CORRELATION \
    "incident_id=$incident_id state=$result host=$target_agent dst=$target_ip src=$src_ip confirm_responded=$responded/$expected confirm_healthy=$healthy confirm_degraded=$degraded confirm_unreachable=$unreachable"

  case "$result" in

    IMPACT_CONFIRMED)

      if [[ "${blocked_sources[$src_ip]:-}" == "ACTIVE" ]]; then
        log DECISION \
          "action=ALREADY_BLOCKED incident_id=$incident_id host=$target_agent src=$src_ip dst=$target_ip reason=SOURCE_ALREADY_BLOCKED"

        return 0
      fi

      log DECISION \
        "action=BLOCK incident_id=$incident_id host=$target_agent src=$src_ip dst=$target_ip reason=DISTRIBUTED_IMPACT_CONFIRMED"

      log ACTION \
        "Distribuirana potvrda pokreće BLOCK_REQUEST incident_id=$incident_id src_ip=$src_ip ttl=${BLOCK_TTL}s"

      send_block_request_to_nids \
        "$incident_id" \
        "$src_ip" \
        "$BLOCK_TTL"
      ;;

    HEALTHY_CONFIRMED)

      log DECISION \
        "action=ALERT_ONLY incident_id=$incident_id host=$target_agent src=$src_ip dst=$target_ip reason=DISTRIBUTED_TARGET_HEALTHY"
      ;;

      UNCERTAIN)

        log DECISION \
          "action=ALERT_ONLY incident_id=$incident_id host=$target_agent src=$src_ip dst=$target_ip reason=DISTRIBUTED_CONFIRMATION_UNCERTAIN"
        ;;


    *)

      log WARNING \
        "Nepoznat rezultat distribuirane potvrde incident_id=$incident_id result=$result"
      ;;
  esac
}

decide_nids_response() {
  local src_ip="$1"
  local dst_ip="$2"
  local correlation_state="$3"
  local heartbeat_status="$4"
  local expected_observers="$5"
  local fresh="$6"
  local healthy="$7"
  local degraded="$8"
  local unreachable="$9"
  local now="${10}"

  local alert_key
  local previous_seen
  local streak

  alert_key="${src_ip},${dst_ip}"
  previous_seen="${nids_alert_last_seen[$alert_key]:-0}"
  streak="${nids_alert_streak[$alert_key]:-0}"

  # Ako se isti src -> dst alert ponavlja unutar definiranog
  # prozora, tretiramo ga kao nastavak istog incidenta.
  if (( previous_seen > 0 &&
        now - previous_seen <= RESPONSE_REPEAT_WINDOW )); then

    streak=$(( streak + 1 ))

  else
    streak=1
  fi

  nids_alert_last_seen["$alert_key"]=$now
  nids_alert_streak["$alert_key"]=$streak

  RESPONSE_ACTION="ALERT_ONLY"
  RESPONSE_REASON="NO_AUTOMATIC_RESPONSE"
  RESPONSE_STREAK=$streak

  case "$correlation_state" in

    NETWORK_ATTACK+AGENT_FAILURE)

      RESPONSE_ACTION="BLOCK"
      RESPONSE_REASON="ATTACK_WITH_AGENT_FAILURE"
      ;;

    NETWORK_ATTACK+NODE_FAILURE)

      RESPONSE_ACTION="BLOCK"
      RESPONSE_REASON="ATTACK_WITH_NODE_FAILURE"
      ;;

    NETWORK_ATTACK+HOST_STATE_UNCERTAIN)

      RESPONSE_ACTION="ALERT_ONLY"
      RESPONSE_REASON="HOST_STATE_UNCERTAIN"
      ;;

    NETWORK_ATTACK)

      # Bez svježeg heartbeata nemamo dovoljno konteksta
      # za automatsku preventivnu akciju.
      if [[ "$heartbeat_status" != "OK" ]]; then

        RESPONSE_ACTION="ALERT_ONLY"
        RESPONSE_REASON="HEARTBEAT_NOT_CONFIRMED"
        return 0
      fi

      # Kod konfiguriranih peer observera želimo imati cijeli
      # očekivani skup svježih opažanja.
      if (( expected_observers > 0 &&
            fresh < expected_observers )); then

        RESPONSE_ACTION="ALERT_ONLY"
        RESPONSE_REASON="INSUFFICIENT_PEER_EVIDENCE"
        return 0
      fi

      # Host je zdrav iz svih dostupnih perspektiva.
      # Jedan alert može biti kratki burst / false positive.
      if (( expected_observers > 0 &&
            healthy >= expected_observers &&
            degraded == 0 &&
            unreachable == 0 )); then

        if (( streak >= 2 )); then

          RESPONSE_ACTION="BLOCK"
          RESPONSE_REASON="PERSISTENT_ATTACK_HEALTHY_TARGET"

        else

          RESPONSE_ACTION="ALERT_ONLY"
          RESPONSE_REASON="FIRST_ALERT_NO_OBSERVED_IMPACT"
        fi

        return 0
      fi

      RESPONSE_ACTION="ALERT_ONLY"
      RESPONSE_REASON="PEER_EVIDENCE_NOT_CONSISTENT"
      ;;

    *)

      RESPONSE_ACTION="ALERT_ONLY"
      RESPONSE_REASON="UNKNOWN_CORRELATION_STATE"
      ;;
  esac
}

handle_server_target_alert() {
  local attack_type="$1"
  local src_ip="$2"
  local dst_ip="$3"
  local now="$4"

  local alert_key
  local previous_seen
  local streak
  local incident_id

  if [[ "$attack_type" != "ICMP_FLOOD" || -z "${src_ip:-}" ]]; then
    log DECISION \
      "action=ALERT_ONLY target=SERVER src=${src_ip:-UNKNOWN} dst=$dst_ip reason=UNSUPPORTED_OR_INVALID_ALERT"
    return 0
  fi

  incident_id="icmp-${now}-${src_ip//./_}-${dst_ip//./_}"

  if [[ "${blocked_sources[$src_ip]:-}" == "ACTIVE" ]]; then
    log DECISION \
      "action=ALREADY_BLOCKED incident_id=$incident_id target=SERVER src=$src_ip dst=$dst_ip reason=SOURCE_ALREADY_BLOCKED"
    return 0
  fi

  if [[ "${RESPONSE_MODE:-correlated}" == "nids_only" ]]; then
    log CORRELATION \
      "state=NETWORK_ATTACK target=SERVER dst=$dst_ip src=$src_ip reason=NIDS_ALERT_SERVER_TARGET"

    log DECISION \
      "mode=nids_only action=BLOCK incident_id=$incident_id target=SERVER src=$src_ip dst=$dst_ip reason=NIDS_ONLY_ICMP_FLOOD_SERVER_TARGET"

    send_block_request_to_nids \
      "$incident_id" \
      "$src_ip" \
      "$BLOCK_TTL"

    return 0
  fi

  alert_key="${src_ip},${dst_ip}"
  previous_seen="${nids_alert_last_seen[$alert_key]:-0}"
  streak="${nids_alert_streak[$alert_key]:-0}"

  if (( previous_seen > 0 &&
        now - previous_seen <= RESPONSE_REPEAT_WINDOW )); then
    streak=$(( streak + 1 ))
  else
    streak=1
  fi

  nids_alert_last_seen["$alert_key"]=$now
  nids_alert_streak["$alert_key"]=$streak

  log CORRELATION \
    "state=NETWORK_ATTACK target=SERVER dst=$dst_ip src=$src_ip streak=$streak reason=NIDS_ALERT_SERVER_TARGET"

  if (( streak < 2 )); then
    log DECISION \
      "action=ALERT_ONLY target=SERVER src=$src_ip dst=$dst_ip streak=$streak reason=FIRST_ALERT_SERVER_TARGET"
    return 0
  fi

  log DECISION \
    "action=BLOCK incident_id=$incident_id target=SERVER src=$src_ip dst=$dst_ip streak=$streak reason=PERSISTENT_ATTACK_SERVER_TARGET"

  log ACTION \
    "Server target BLOCK_REQUEST incident_id=$incident_id src_ip=$src_ip ttl=${BLOCK_TTL}s"

  send_block_request_to_nids \
    "$incident_id" \
    "$src_ip" \
    "$BLOCK_TTL"
}

handle_nids_alert() {
  local line="$1"

  local attack_type
  local src_ip
  local dst_ip
  local count
  local window
  local threshold

  local target_agent
  local last_hb
  local now
  local hb_age

  local observer
  local key
  local state
  local seen
  local age

  local expected_observers
  local fresh=0
  local healthy=0
  local degraded=0
  local unreachable=0

  local heartbeat_status
  local heartbeat_age_text
  local host_state
  local correlation_state
  local reason
  local incident_id

  attack_type=$(
    grep -oE 'type=[^ ]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  src_ip=$(
    grep -oE 'src=([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  dst_ip=$(
    grep -oE 'dst=([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  count=$(
    grep -oE 'count=[0-9]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  window=$(
    grep -oE 'window=[^ ]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  threshold=$(
    grep -oE 'threshold=[0-9]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  log NIDS_ALERT \
    "type=${attack_type:-UNKNOWN} src=${src_ip:-UNKNOWN} dst=${dst_ip:-UNKNOWN} count=${count:-0} window=${window:-UNKNOWN} threshold=${threshold:-UNKNOWN}"

  now=$(date +%s)

  if [[ "${dst_ip:-}" == "${SERVER_IP:-}" ]]; then
    handle_server_target_alert \
      "$attack_type" \
      "$src_ip" \
      "$dst_ip" \
      "$now"
    return 0
  fi

  target_agent=$(get_agent_by_ip "$dst_ip" || true)

  if [[ -z "${target_agent:-}" ]]; then
    log CORRELATION \
      "state=NETWORK_ATTACK target=UNKNOWN dst=${dst_ip:-UNKNOWN} src=${src_ip:-UNKNOWN} reason=NIDS_ALERT_UNKNOWN_TARGET"

    log DECISION \
      "action=ALERT_ONLY src=${src_ip:-UNKNOWN} dst=${dst_ip:-UNKNOWN} reason=UNKNOWN_TARGET"

    return 0
  fi

  # --------------------------------------------------
  # RQ2 eksperimentalni mod: NIDS-only
  #
  # U ovom modu odluka se temelji samo na NIDS detekciji.
  # Heartbeat, peer evidence i distributed confirmation
  # namjerno se preskaču radi usporedbe s correlated modom.
  # --------------------------------------------------

  if [[ "${RESPONSE_MODE:-correlated}" == "nids_only" ]]; then

    if [[ "$attack_type" != "ICMP_FLOOD" ||
          -z "${src_ip:-}" ]]; then

      log DECISION \
        "mode=nids_only action=ALERT_ONLY host=$target_agent src=${src_ip:-UNKNOWN} dst=$dst_ip reason=UNSUPPORTED_OR_INVALID_ALERT"

      return 0
    fi

    incident_id="icmp-${now}-${src_ip//./_}-${dst_ip//./_}"

    if [[ "${blocked_sources[$src_ip]:-}" == "ACTIVE" ]]; then

      log DECISION \
        "mode=nids_only action=ALREADY_BLOCKED incident_id=$incident_id host=$target_agent src=$src_ip dst=$dst_ip reason=SOURCE_ALREADY_BLOCKED"

      return 0
    fi

    log DECISION \
      "mode=nids_only action=BLOCK incident_id=$incident_id host=$target_agent src=$src_ip dst=$dst_ip reason=NIDS_ONLY_ICMP_FLOOD"

    log ACTION \
      "NIDS-only BLOCK_REQUEST incident_id=$incident_id src_ip=$src_ip ttl=${BLOCK_TTL}s"

    send_block_request_to_nids \
      "$incident_id" \
      "$src_ip" \
      "$BLOCK_TTL"

    return 0
  fi

  expected_observers=$(( total_agents > 1 ? total_agents - 1 : 0 ))

  for observer in "${AUTH_AGENTS[@]}"; do
    [[ "$observer" == "$target_agent" ]] && continue

    key="$observer,$target_agent"
    state="${peer_state_map[$key]:-}"
    seen="${peer_state_seen[$key]:-}"

    [[ -z "$state" || -z "$seen" ]] && continue

    age=$(( now - seen ))

    (( age > HEARTBEAT_TIMEOUT )) && continue

    fresh=$(( fresh + 1 ))

    case "$state" in
      HEALTHY)
        healthy=$(( healthy + 1 ))
        ;;

      DEGRADED)
        degraded=$(( degraded + 1 ))
        ;;

      UNREACHABLE)
        unreachable=$(( unreachable + 1 ))
        ;;
    esac
  done

  last_hb="${last_heartbeat[$target_agent]:-}"

  if [[ -z "$last_hb" ]]; then

    heartbeat_status="UNKNOWN"
    heartbeat_age_text="UNKNOWN"
    host_state="UNKNOWN"
    correlation_state="NETWORK_ATTACK"
    reason="NIDS_ALERT_NO_HEARTBEAT"

  else

    hb_age=$(( now - last_hb ))
    heartbeat_age_text="${hb_age}s"

    if (( hb_age <= HEARTBEAT_TIMEOUT )); then

      heartbeat_status="OK"
      host_state="HEALTHY"
      correlation_state="NETWORK_ATTACK"
      reason="NIDS_ALERT_HEARTBEAT_OK"

    else

      heartbeat_status="STALE"
      host_state="STALE"

      if (( expected_observers > 0 &&
            unreachable >= expected_observers )); then

        correlation_state="NETWORK_ATTACK+NODE_FAILURE"
        reason="NIDS_ALERT_HEARTBEAT_STALE_PEERS_UNREACHABLE"

      elif (( healthy > 0 && unreachable == 0 )); then

        correlation_state="NETWORK_ATTACK+AGENT_FAILURE"
        reason="NIDS_ALERT_HEARTBEAT_STALE_PEER_REACHABLE"

      elif (( fresh > 0 )); then

        correlation_state="NETWORK_ATTACK+HOST_STATE_UNCERTAIN"
        reason="NIDS_ALERT_HEARTBEAT_STALE_MIXED_PEER_EVIDENCE"

      else

        correlation_state="NETWORK_ATTACK+HOST_STATE_UNCERTAIN"
        reason="NIDS_ALERT_HEARTBEAT_STALE_NO_FRESH_PEER_EVIDENCE"
      fi
    fi
  fi

  log CORRELATION \
    "state=$correlation_state host=$target_agent dst=$dst_ip src=$src_ip heartbeat=$heartbeat_status heartbeat_age=$heartbeat_age_text host_state=$host_state peers_expected=$expected_observers peers_fresh=$fresh peers_healthy=$healthy peers_degraded=$degraded peers_unreachable=$unreachable reason=$reason"

  # --------------------------------------------------
  # Response policy
  # --------------------------------------------------

  if [[ "$attack_type" != "ICMP_FLOOD" ||
        -z "${src_ip:-}" ]]; then

    log DECISION \
      "action=ALERT_ONLY host=$target_agent src=${src_ip:-UNKNOWN} dst=$dst_ip reason=UNSUPPORTED_OR_INVALID_ALERT"

    return 0
  fi

  decide_nids_response \
    "$src_ip" \
    "$dst_ip" \
    "$correlation_state" \
    "$heartbeat_status" \
    "$expected_observers" \
    "$fresh" \
    "$healthy" \
    "$degraded" \
    "$unreachable" \
    "$now"

  log DEBUG \
    "BLOCK_CHECK src=$src_ip blocked_state=${blocked_sources[$src_ip]:-NONE} response_action=$RESPONSE_ACTION"

  if [[ "$RESPONSE_ACTION" == "BLOCK" &&
        "${blocked_sources[$src_ip]:-}" == "ACTIVE" ]]; then

    RESPONSE_ACTION="ALREADY_BLOCKED"
    RESPONSE_REASON="SOURCE_ALREADY_BLOCKED"
  fi

  log DECISION \
    "action=$RESPONSE_ACTION host=$target_agent src=$src_ip dst=$dst_ip correlation=$correlation_state streak=$RESPONSE_STREAK reason=$RESPONSE_REASON"

  # Prvi NIDS alarm prema hostu koji prema postojećoj
  # telemetriji još izgleda zdrav ne blokiramo odmah.
  #
  # Umjesto toga pokrećemo aktivnu distribuiranu potvrdu:
  # ostali agenti odmah provjeravaju dostupnost ciljnog hosta.
  if [[ "$RESPONSE_ACTION" == "ALERT_ONLY" &&
        ( "$RESPONSE_REASON" == "FIRST_ALERT_NO_OBSERVED_IMPACT" ||
          "$RESPONSE_REASON" == "PEER_EVIDENCE_NOT_CONSISTENT" ) ]]; then

    incident_id="icmp-${now}-${src_ip//./_}-${dst_ip//./_}"

    log ACTION \
      "Pokrećem distribuiranu potvrdu incident_id=$incident_id src=$src_ip dst=$dst_ip target=$target_agent"

    start_distributed_confirmation \
      "$incident_id" \
      "NIDS" \
      "$target_agent" \
      "$dst_ip" \
      "$src_ip"

    return 0
  fi

  if [[ "$RESPONSE_ACTION" != "BLOCK" ]]; then
    return 0
  fi

  incident_id="icmp-${now}-${src_ip//./_}-${dst_ip//./_}"

  log ACTION \
    "Automatski BLOCK_REQUEST incident_id=$incident_id src_ip=$src_ip ttl=${BLOCK_TTL}s correlation=$correlation_state decision_reason=$RESPONSE_REASON"

  send_block_request_to_nids \
    "$incident_id" \
    "$src_ip" \
    "$BLOCK_TTL"
}