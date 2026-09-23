#!/usr/bin/env bash

declare -gA confirm_map


clear_confirmation_incident() {
  local key="$1"
  local observer
  local slot

  for observer in "${AUTH_AGENTS[@]}"; do
    slot="$key,response_$observer"
    unset "confirm_map[$slot]"
  done

  unset "confirm_map[$key,incident_id]"
  unset "confirm_map[$key,origin]"
  unset "confirm_map[$key,target_agent]"
  unset "confirm_map[$key,target_ip]"
  unset "confirm_map[$key,src_ip]"
  unset "confirm_map[$key,expected]"
  unset "confirm_map[$key,started_at]"
  unset "confirm_map[$key,alert_count]"
}


block_source_from_consensus() {
  local incident_id="$1"
  local src_ip="$2"
  local agent_id
  local target_ip

  if [[ -z "${src_ip:-}" ]]; then
    log WARNING \
      "CONFIRM incident_id=$incident_id nema src_ip; blokada preskočena"
    return 0
  fi

  if iptables_drop_once "$src_ip"; then
    log ACTION \
      "CONFIRM incident_id=$incident_id server lokalno blokirao src=$src_ip"
  else
    log WARNING \
      "CONFIRM incident_id=$incident_id server nije uspio blokirati src=$src_ip"
  fi

  for agent_id in "${AUTH_AGENTS[@]}"; do
    target_ip=$(get_ip "$agent_id")
    [[ -z "${target_ip:-}" ]] && continue

    if [[ "$target_ip" == "$src_ip" ]]; then
      log DEBUG \
        "CONFIRM incident_id=$incident_id skip COMMAND_BLOCK self agent=$agent_id ip=$target_ip"
      continue
    fi

    send_to_agent "$target_ip" \
      "COMMAND_BLOCK $src_ip"

    log ACTION \
      "CONFIRM incident_id=$incident_id COMMAND_BLOCK src=$src_ip -> $agent_id"
  done
}


start_distributed_confirmation() {
  local incident_id="$1"
  local origin="$2"
  local target_agent="$3"
  local target_ip="$4"
  local src_ip="$5"

  local key="incident_$incident_id"
  local observer
  local observer_ip
  local slot
  local expected=0

  if [[ -z "${incident_id:-}" ||
        -z "${origin:-}" ||
        -z "${target_agent:-}" ||
        -z "${target_ip:-}" ||
        -z "${src_ip:-}" ]]; then

    log WARNING \
      "CONFIRM start odbijen: nedostaju podaci incident_id=${incident_id:-?} origin=${origin:-?} target_agent=${target_agent:-?} target_ip=${target_ip:-?} src_ip=${src_ip:-?}"

    return 0
  fi

  confirm_map["$key,incident_id"]="$incident_id"
  confirm_map["$key,origin"]="$origin"
  confirm_map["$key,target_agent"]="$target_agent"
  confirm_map["$key,target_ip"]="$target_ip"
  confirm_map["$key,src_ip"]="$src_ip"
  confirm_map["$key,started_at"]="$(date +%s)"

  for observer in "${AUTH_AGENTS[@]}"; do
    [[ "$observer" == "$target_agent" ]] && continue

    observer_ip=$(get_ip "$observer")
    [[ -z "${observer_ip:-}" ]] && continue

    slot="$key,response_$observer"
    confirm_map["$slot"]="PENDING"
    expected=$(( expected + 1 ))

    send_to_agent "$observer_ip" \
      "CONFIRM_REQUEST $incident_id $target_ip $src_ip"

    log ACTION \
      "CONFIRM_REQUEST incident_id=$incident_id origin=$origin target=$target_agent target_ip=$target_ip src=$src_ip -> observer=$observer"
  done

  confirm_map["$key,expected"]="$expected"

  if (( expected == 0 )); then
    log WARNING \
      "CONFIRM incident_id=$incident_id nema dostupnih observera"
    clear_confirmation_incident "$key"
    return 0
  fi

  log ACTION \
    "CONFIRM_START incident_id=$incident_id origin=$origin target=$target_agent target_ip=$target_ip src=$src_ip expected=$expected quorum=${QUORUM_PERCENT}%"
}



check_confirmation_timeouts() {
  local timeout="${CONFIRM_TIMEOUT:-10}"
  local now
  local map_key
  local key
  local started_at
  local incident_id
  local age

  now=$(date +%s)

  for map_key in "${!confirm_map[@]}"; do
    [[ "$map_key" == *,started_at ]] || continue

    key="${map_key%,started_at}"
    started_at="${confirm_map["$map_key"]:-0}"

    [[ "$started_at" =~ ^[0-9]+$ ]] || continue

    age=$(( now - started_at ))
    (( age >= timeout )) || continue

    incident_id="${confirm_map["$key,incident_id"]:-UNKNOWN}"

    log WARNING \
      "CONFIRM_TIMEOUT incident_id=$incident_id age=${age}s timeout=${timeout}s"

    finish_confirmation_if_ready "$key" 1
  done
}

finish_confirmation_if_ready() {
  local key="$1"
  local force_timeout="${2:-0}"

  local incident_id="${confirm_map["$key,incident_id"]:-}"
  local origin="${confirm_map["$key,origin"]:-}"
  local target_agent="${confirm_map["$key,target_agent"]:-}"
  local target_ip="${confirm_map["$key,target_ip"]:-}"
  local src_ip="${confirm_map["$key,src_ip"]:-}"
  local expected="${confirm_map["$key,expected"]:-0}"

  local observer
  local slot
  local response
  local responded=0
  local healthy=0
  local degraded=0
  local unreachable=0
  local impact=0
  local required
  local result="PENDING"

  if (( expected <= 0 )); then
    return 0
  fi

  required=$(( (expected * QUORUM_PERCENT + 99) / 100 ))
  (( required < 1 )) && required=1

  for observer in "${AUTH_AGENTS[@]}"; do
    slot="$key,response_$observer"
    response="${confirm_map["$slot"]:-MISSING}"

    case "$response" in
      HEALTHY)
        responded=$(( responded + 1 ))
        healthy=$(( healthy + 1 ))
        ;;

      DEGRADED)
        responded=$(( responded + 1 ))
        degraded=$(( degraded + 1 ))
        impact=$(( impact + 1 ))
        ;;

      UNREACHABLE)
        responded=$(( responded + 1 ))
        unreachable=$(( unreachable + 1 ))
        impact=$(( impact + 1 ))
        ;;
    esac
  done

  if (( impact >= required )); then
    result="IMPACT_CONFIRMED"

  elif (( healthy >= required )); then
    result="HEALTHY_CONFIRMED"

  elif (( responded >= expected || force_timeout == 1 )); then
    result="UNCERTAIN"
  fi

  log PEER \
    "CONFIRM_PROGRESS incident_id=$incident_id origin=$origin target=$target_agent responded=$responded/$expected required=$required healthy=$healthy degraded=$degraded unreachable=$unreachable result=$result"

  [[ "$result" == "PENDING" ]] && return 0

  case "$origin" in
    TRAFFIC)
      if [[ "$result" == "IMPACT_CONFIRMED" ]]; then
        log DECISION \
          "action=BLOCK incident_id=$incident_id src=$src_ip target=$target_agent reason=DISTRIBUTED_IMPACT_CONFIRMED"

        block_source_from_consensus \
          "$incident_id" \
          "$src_ip"
      else
        log DECISION \
          "action=ALERT_ONLY incident_id=$incident_id src=$src_ip target=$target_agent reason=DISTRIBUTED_TARGET_HEALTHY"
      fi
      ;;

    NIDS)
      if declare -F handle_nids_confirmation_result >/dev/null 2>&1; then
        handle_nids_confirmation_result \
          "$incident_id" \
          "$target_agent" \
          "$target_ip" \
          "$src_ip" \
          "$result" \
          "$responded" \
          "$expected" \
          "$healthy" \
          "$degraded" \
          "$unreachable"
      else
        log WARNING \
          "CONFIRM incident_id=$incident_id origin=NIDS nema result handler"
      fi
      ;;
  esac

  clear_confirmation_incident "$key"
}


handle_traffic_alert() {
  local line="$1"

  local alert_agent
  local alert_count
  local alert_time
  local src_ip
  local target_ip
  local incident_id
  local key

  log ALERT "$line"

  alert_agent=$(awk '{print $2}' <<<"$line")
  alert_count=$(awk '{print $3}' <<<"$line")
  alert_time=$(awk '{print $4}' <<<"$line")

  src_ip=$(
    grep -oE 'src=([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  if [[ -z "${src_ip:-}" ]]; then
    log WARNING \
      "TRAFFIC_ALERT bez src=; potvrda preskočena agent=$alert_agent count=$alert_count"
    return 0
  fi

  target_ip=$(get_ip "$alert_agent")

  if [[ -z "${target_ip:-}" ]]; then
    log WARNING \
      "TRAFFIC_ALERT nema poznat target_ip za agent=$alert_agent"
    return 0
  fi

  incident_id="traffic-${alert_time}-${alert_agent}-${src_ip//./_}"
  key="incident_$incident_id"

  start_distributed_confirmation \
    "$incident_id" \
    "TRAFFIC" \
    "$alert_agent" \
    "$target_ip" \
    "$src_ip"

  if [[ -n "${confirm_map["$key,incident_id"]:-}" ]]; then
    confirm_map["$key,alert_count"]="$alert_count"
  fi
}


handle_confirm_response() {
  local line="$1"

  local from_agent
  local incident_id
  local target_ip
  local state
  local rest
  local key
  local slot
  local expected_target_ip
  local current
  local ping_ok
  local port80_ok
  local ts_value

  read -r _ from_agent incident_id target_ip state rest <<<"$line"

  if [[ -z "${from_agent:-}" ||
        -z "${incident_id:-}" ||
        -z "${target_ip:-}" ||
        -z "${state:-}" ]]; then

    log WARNING \
      "Neispravan CONFIRM_RESPONSE: $line"
    return 0
  fi

  case "$state" in
    HEALTHY|DEGRADED|UNREACHABLE)
      ;;

    *)
      log WARNING \
        "CONFIRM_RESPONSE incident_id=$incident_id nepoznat state=$state from=$from_agent"
      return 0
      ;;
  esac

  key="incident_$incident_id"

  if [[ -z "${confirm_map["$key,incident_id"]:-}" ]]; then
    log WARNING \
      "CONFIRM_RESPONSE za nepoznat ili završen incident_id=$incident_id from=$from_agent"
    return 0
  fi

  expected_target_ip="${confirm_map["$key,target_ip"]:-}"

  if [[ "$target_ip" != "$expected_target_ip" ]]; then
    log WARNING \
      "CONFIRM_RESPONSE incident_id=$incident_id target mismatch expected=$expected_target_ip received=$target_ip from=$from_agent"
    return 0
  fi

  slot="$key,response_$from_agent"
  current="${confirm_map["$slot"]:-MISSING}"

  if [[ "$current" == "MISSING" ]]; then
    log WARNING \
      "CONFIRM_RESPONSE incident_id=$incident_id neočekivan observer=$from_agent"
    return 0
  fi

  if [[ "$current" != "PENDING" ]]; then
    log DEBUG \
      "CONFIRM_RESPONSE incident_id=$incident_id duplicate observer=$from_agent state=$state"
    return 0
  fi

  ping_ok=$(
    grep -oE 'ping=[01]' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  port80_ok=$(
    grep -oE 'port80=[01]' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  ts_value=$(
    grep -oE 'ts=[0-9]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  confirm_map["$slot"]="$state"

  log PEER \
    "CONFIRM_RESPONSE incident_id=$incident_id observer=$from_agent target=$target_ip state=$state ping=${ping_ok:-UNKNOWN} port80=${port80_ok:-UNKNOWN} ts=${ts_value:-UNKNOWN}"

  finish_confirmation_if_ready "$key"
}