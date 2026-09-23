load_unit_list() {
  UNIT_LIST="$(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}')"
  export UNIT_LIST
}

resolve_unit() {
  local base="$1"

  if grep -qx "${base}.service" <<<"$UNIT_LIST"; then
    echo "$base"
    return 0
  fi

  if grep -qx "${base}d.service" <<<"$UNIT_LIST"; then
    echo "${base}d"
    return 0
  fi

  return 1
}

is_unit_active() {
  local name="$1"
  local unit

  unit=$(resolve_unit "$name") || return 2
  systemctl is-active --quiet "$unit" && return 0 || return 1
}

restart_unit() {
  local name="$1"
  local unit
  local svc
  local allowed=0

  for svc in "${SERVICES[@]}"; do
    if [[ "$name" == "$svc" ]]; then
      allowed=1
      break
    fi
  done

  if (( allowed == 0 )); then
    log WARNING "RESTART odbijen: servis '$name' nije u allowlisti"
    return 0
  fi

  unit=$(resolve_unit "$name") || {
    log WARNING "RESTART: servis '$name' ne postoji na ovom hostu, preskačem"
    return 0
  }

  systemctl restart "${unit}.service" && log ACTION "$unit restartan"
}