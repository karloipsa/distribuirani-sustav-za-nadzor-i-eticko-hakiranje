BANNER_CACHE=""

init_banner() {
  BANNER_CACHE="$LOG_DIR/banner_cache.txt"
  touch "$BANNER_CACHE"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

make_one_line() {
  awk '
    BEGIN { IGNORECASE=1 }
    NR == 1 {
      gsub(/\r/, "")
      if ($0 != "") parts[++n] = $0
      next
    }
    /^Server:/ || /^Content-Type:/ {
      gsub(/\r/, "")
      parts[++n] = $0
    }
    END {
      for (i = 1; i <= n; i++) {
        printf "%s%s", parts[i], (i < n ? "|" : "")
      }
    }
  '
}

get_cached_hash() {
  local key="$1"
  awk -v k="$key" -F'\t' '$1==k{print $2}' "$BANNER_CACHE" 2>/dev/null | tail -n1
}

set_cached_hash() {
  local key="$1"
  local hash="$2"
  printf "%s\t%s\n" "$key" "$hash" >> "$BANNER_CACHE"
}

probe_banner_for_ip() {
  local ip="$1"
  local raw=""
  local banner=""
  local oneline=""
  local h=""
  local key=""
  local old=""

  if have_cmd curl; then
    raw=$(curl -sS -I --max-time 2 "http://$ip/" 2>/dev/null | sed -n '1,5p') || true
  else
    raw=$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n' "$ip" \
      | ncat -w2 "$ip" 80 2>/dev/null | sed -n '1,5p') || true
  fi

  banner="${raw:-}"

  if [[ -z "$banner" ]]; then
    broadcast "BANNER_EMPTY $AGENT_ID $ip 80"
    log INFO "Banner grab sa $ip: PRAZAN"
    return 0
  fi

  oneline=$(printf "%s" "$banner" | make_one_line)

  if [[ "$BANNER_MODE" == "all" ]]; then
    broadcast "BANNER $AGENT_ID $ip 80 $oneline"
    log INFO "Banner grab sa $ip: dobiven"
    return 0
  fi

  h=$(printf "%s" "$oneline" | sha1sum | awk '{print $1}')
  key="$ip:80"
  old=$(get_cached_hash "$key")

  if [[ "$h" != "$old" ]]; then
    set_cached_hash "$key" "$h"
    broadcast "BANNER $AGENT_ID $ip 80 $oneline"
    log INFO "Banner promjena na $ip"
  fi
}