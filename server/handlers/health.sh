#!/usr/bin/env bash

declare -gA last_heartbeat
declare -gA agent_health_state

# Zadnje lokalno zaključeno stanje koje je svaki agent
# prijavio za svaki promatrani peer.
#
# Ključ je:
#   observer,target_agent
#
# Primjer:
#   peer_state_map["agent-01,agent-03"]="UNREACHABLE"
declare -gA peer_state_map
declare -gA peer_state_seen

# Zadnje globalno stanje koje je server zaključio za host.
# Koristi se da se ista korelacijska poruka ne ispisuje
# svakih nekoliko sekundi.
declare -gA correlated_node_state

declare -g last_watchdog_check=0

WATCHDOG_INTERVAL=5

handle_heartbeat() {
  local line="$1"
  local AGENT="$2"
  local now
  local previous_state
  local previous_correlated_state

  now=$(date +%s)
  previous_state="${agent_health_state[$AGENT]:-UNKNOWN}"
  previous_correlated_state="${correlated_node_state[$AGENT]:-UNKNOWN}"

  last_heartbeat["$AGENT"]=$now
  agent_health_state["$AGENT"]="HEALTHY"
  correlated_node_state["$AGENT"]="HEALTHY"

  log HEARTBEAT "$line"

  if [[ "$previous_state" == "STALE" ]]; then
    log RECOVERY \
      "state=HEALTHY host=$AGENT previous=$previous_correlated_state reason=HEARTBEAT_RESTORED"
  fi
}


correlate_stale_agent() {
  local target_agent="$1"
  local hb_age="${2:-UNKNOWN}"

  local now
  local observer
  local key
  local state
  local seen
  local age

  local fresh=0
  local healthy=0
  local degraded=0
  local unreachable=0
  local expected_observers

  local previous_state
  local new_state
  local reason

  now=$(date +%s)

  # Za jedan ciljni host očekujemo opažanja svih ostalih
  # konfiguriranih agenata.
  expected_observers=$(( total_agents > 1 ? total_agents - 1 : 0 ))

  for observer in "${AUTH_AGENTS[@]}"; do
    [[ "$observer" == "$target_agent" ]] && continue

    key="$observer,$target_agent"
    state="${peer_state_map[$key]:-}"
    seen="${peer_state_seen[$key]:-}"

    [[ -z "$state" || -z "$seen" ]] && continue

    age=$(( now - seen ))

    # PEER_STATE se trenutno generira svakih ~60 s.
    # Ako je opažanje starije od HEARTBEAT_TIMEOUT,
    # ne koristimo ga za trenutnu korelaciju.
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

  previous_state="${correlated_node_state[$target_agent]:-UNKNOWN}"

  # Svi ostali agenti neovisno tvrde da ciljni host nije dostupan.
  if (( expected_observers > 0 &&
        unreachable >= expected_observers )); then

    new_state="NODE_FAILURE"
    reason="HEARTBEAT_STALE_PEERS_UNREACHABLE"

  # Heartbeat je nestao, ali barem jedan svježi peer i dalje
  # normalno vidi host. To upućuje na kvar agent procesa /
  # gubitak telemetrije, a ne na pad cijelog hosta.
  elif (( healthy > 0 && unreachable == 0 )); then

    new_state="AGENT_FAILURE"
    reason="HEARTBEAT_STALE_PEER_REACHABLE"

  # Imamo peer podatke, ali se opažanja još ne slažu dovoljno
  # za siguran zaključak.
  elif (( fresh > 0 )); then

    new_state="NODE_STATE_UNCERTAIN"
    reason="HEARTBEAT_STALE_MIXED_PEER_EVIDENCE"

  # Heartbeat je stale, ali nemamo dovoljno svježih peer podataka.
  else

    new_state="NODE_STATE_UNCERTAIN"
    reason="HEARTBEAT_STALE_NO_FRESH_PEER_EVIDENCE"
  fi

  correlated_node_state["$target_agent"]="$new_state"

  # Logiramo samo promjenu globalnog zaključka.
  if [[ "$new_state" != "$previous_state" ]]; then
    log CORRELATION \
      "state=$new_state host=$target_agent heartbeat=STALE heartbeat_age=${hb_age}s peers_fresh=$fresh peers_healthy=$healthy peers_degraded=$degraded peers_unreachable=$unreachable reason=$reason"
  fi
}


check_agent_health() {
  local now
  local agent
  local last_hb
  local hb_age
  local previous_state

  now=$(date +%s)

  # Watchdog stvarnu provjeru radi najviše jednom
  # svakih WATCHDOG_INTERVAL sekundi.
  if (( now - last_watchdog_check < WATCHDOG_INTERVAL )); then
    return 0
  fi

  last_watchdog_check=$now

  for agent in "${AUTH_AGENTS[@]}"; do
    last_hb="${last_heartbeat[$agent]:-}"
    previous_state="${agent_health_state[$agent]:-UNKNOWN}"

    # Agent još nikad nije poslao heartbeat.
    # Dok ga prvi put ne vidimo, njegovo stanje je UNKNOWN
    # i watchdog ga ne proglašava kvarom.
    if [[ -z "$last_hb" ]]; then
      agent_health_state["$agent"]="UNKNOWN"
      continue
    fi

    hb_age=$(( now - last_hb ))

    if (( hb_age > HEARTBEAT_TIMEOUT )); then
      agent_health_state["$agent"]="STALE"

      # Stale heartbeat više nije automatski NODE_FAILURE.
      # Server ga korelira sa svježim PEER_STATE opažanjima.
      correlate_stale_agent "$agent" "$hb_age"

    else
      agent_health_state["$agent"]="HEALTHY"
      correlated_node_state["$agent"]="HEALTHY"
    fi
  done
}
