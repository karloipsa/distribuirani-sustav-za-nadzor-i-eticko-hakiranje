#!/usr/bin/env bash

declare -A failure_map

handle_service_status() {
  local line="$1"
  local AGENT="$2"

  local svc
  local status
  local ip
  local key
  local agent_id
  local fails
  local pct
  local thr

  svc=$(awk '{print $3}' <<<"$line")
  status=$(awk '{print $4}' <<<"$line")
  [[ "$status" =~ ^[0-9]+$ ]] || status=1

  log SERVICE_STATUS "$line (human=$([[ $status -eq 0 ]] && echo OK || echo FAIL))"

  if (( status != 0 )); then
    ip=$(get_ip "$AGENT")
    if [[ -n "${ip:-}" ]]; then
      send_to_agent "$ip" "COMMAND_RESTART $svc"
      log ACTION "IMMEDIATE: COMMAND_RESTART $svc -> $AGENT ($ip)"
    fi
  fi

  key="$svc,$AGENT"

  if (( status != 0 )); then
    failure_map["$key"]=1
  else
    unset "failure_map[$key]"
  fi

  declare -A uniq=()

  for key in "${!failure_map[@]}"; do
    if [[ $key == "$svc,"* ]]; then
      agent_id=${key#*,}
      uniq["$agent_id"]=1
    fi
  done

  fails=${#uniq[@]}
  pct=$(( total_agents == 0 ? 0 : fails * 100 / total_agents ))
  thr=$QUORUM_PERCENT

  if (( pct >= thr )); then
    log ALERT "Usluga $svc pala na $pct% agenata (prag $thr%)"

    for agent_id in "${!uniq[@]}"; do
      ip=$(get_ip "$agent_id")
      [[ -z "${ip:-}" ]] && continue

      send_to_agent "$ip" "COMMAND_RESTART $svc"
      log ACTION "Poslan COMMAND_RESTART $svc -> $agent_id ($ip)"
    done

    for key in "${!failure_map[@]}"; do
      [[ $key == "$svc,"* ]] && unset "failure_map[$key]"
    done
  fi
}
