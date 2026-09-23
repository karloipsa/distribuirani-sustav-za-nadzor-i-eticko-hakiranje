#!/usr/bin/env bash

handle_banner() {
  local line="$1"
  local AGENT="$2"

  local peer
  local port
  local banner
  local http_status
  local server_name
  local content_type

  peer=$(awk '{print $3}' <<<"$line")
  port=$(awk '{print $4}' <<<"$line")
  banner=$(cut -d' ' -f5- <<<"$line")

  http_status=$(
    sed -n 's#^HTTP/[^ ]* \([0-9][0-9][0-9]\).*#\1#p' <<<"$banner"
  )

  server_name=$(
    tr '|' '\n' <<<"$banner" |
      sed -n 's/^[Ss]erver:[[:space:]]*//p' |
      head -n1
  )

  content_type=$(
    tr '|' '\n' <<<"$banner" |
      sed -n 's/^[Cc]ontent-[Tt]ype:[[:space:]]*//p' |
      head -n1
  )

  log BANNER \
    "observer=$AGENT target=$peer port=$port status=FOUND http_status=${http_status:-UNKNOWN} server=${server_name:-UNKNOWN} content_type=${content_type:-UNKNOWN}"
}


handle_banner_empty() {
  local line="$1"
  local AGENT="$2"

  local peer
  local port

  peer=$(awk '{print $3}' <<<"$line")
  port=$(awk '{print $4}' <<<"$line")

  log BANNER \
    "observer=$AGENT target=$peer port=$port status=EMPTY http_status=UNKNOWN server=UNKNOWN content_type=UNKNOWN"
}


handle_new_device() {
  local line="$1"
  local AGENT="$2"
  local ip
  local ts

  ip=$(awk '{print $3}' <<<"$line")
  ts=$(awk '{print $4}' <<<"$line")

  log NEW_DEVICE \
    "agent=$AGENT ip=$ip first_seen=$ts"
}


handle_peer_state() {
  local line="$1"
  local observer="$2"

  local target_ip
  local state
  local target_agent
  local key
  local now

  local latency
  local port80
  local failures

  target_ip=$(awk '{print $3}' <<<"$line")
  state=$(awk '{print $4}' <<<"$line")

  if [[ -z "${target_ip:-}" || -z "${state:-}" ]]; then
    log WARNING \
      "Neispravan PEER_STATE od $observer: '$line'"
    return 0
  fi

  case "$state" in
    HEALTHY|DEGRADED|UNREACHABLE)
      ;;
    *)
      log WARNING \
        "Nepoznato PEER_STATE stanje '$state' od $observer: '$line'"
      return 0
      ;;
  esac

  target_agent=$(get_agent_by_ip "$target_ip" || true)

  if [[ -z "${target_agent:-}" ]]; then
    log WARNING \
      "PEER_STATE od $observer za nepoznati target_ip=$target_ip"
    return 0
  fi

  # Agent ne bi trebao prijavljivati samoga sebe kao peer.
  if [[ "$observer" == "$target_agent" ]]; then
    log WARNING \
      "Ignoriram PEER_STATE self-observation observer=$observer target=$target_agent"
    return 0
  fi

  now=$(date +%s)
  key="$observer,$target_agent"

  peer_state_map["$key"]="$state"
  peer_state_seen["$key"]=$now

  latency=$(
    grep -oE 'latency=[^ ]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  port80=$(
    grep -oE 'port80=[01]' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  failures=$(
    grep -oE 'failures=[0-9]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  log PEER_STATE \
    "observer=$observer target=$target_agent target_ip=$target_ip state=$state latency=${latency:-UNKNOWN} port80=${port80:-UNKNOWN} failures=${failures:-UNKNOWN}"

  # Ako je heartbeat ciljnog agenta već stale, nova peer
  # informacija može promijeniti globalni zaključak odmah,
  # bez čekanja sljedećeg heartbeat događaja.
  if [[ "${agent_health_state[$target_agent]:-UNKNOWN}" == "STALE" ]]; then
    local last_hb
    local hb_age

    last_hb="${last_heartbeat[$target_agent]:-}"

    if [[ -n "$last_hb" ]]; then
      hb_age=$(( now - last_hb ))
      correlate_stale_agent "$target_agent" "$hb_age"
    fi
  fi
}
