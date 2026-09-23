load_agents() {
  mapfile -t AUTH_AGENTS < <(awk '!/^\s*#/ && NF{print $1}' "$AUTH_LIST" 2>/dev/null)
  mapfile -t AUTH_IPS    < <(awk '!/^\s*#/ && NF{print $2}' "$AUTH_LIST" 2>/dev/null)

  total_agents=${#AUTH_AGENTS[@]}

  export total_agents
}

get_ip() {
  local id="$1"
  local i

  for i in "${!AUTH_AGENTS[@]}"; do
    if [[ "${AUTH_AGENTS[i]}" == "$id" ]]; then
      echo "${AUTH_IPS[i]}"
      return
    fi
  done
}

get_agent_by_ip() {
  local ip="$1"
  local i

  for i in "${!AUTH_IPS[@]}"; do
    if [[ "${AUTH_IPS[i]}" == "$ip" ]]; then
      echo "${AUTH_AGENTS[i]}"
      return 0
    fi
  done

  return 1
}

validate_agent() {
  local id="$1"
  local a

  for a in "${AUTH_AGENTS[@]}"; do
    [[ "$a" == "$id" ]] && return 0
  done

  return 1
}