rotate_logs() {
  local f="$LOG_DIR/agent.log"

  if [[ -f "$f" && $(stat -c%s "$f" 2>/dev/null || echo 0) -gt $ROTATE_SIZE ]]; then
    local i
    for ((i=MAX_ROTATES; i>1; i--)); do
      mv -f "$f.$((i-1))" "$f.$i" 2>/dev/null || true
    done
    mv -f "$f" "$f.1" 2>/dev/null || true
    : > "$f"
  fi
}

log() {
  local lvl="$1"
  local msg="$2"

  [[ "$lvl" == "DEBUG" && "$DEBUG" != "1" ]] && return

  rotate_logs
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$msg" | tee -a "$LOG_DIR/agent.log" >/dev/null
}

init_logging() {
  mkdir -p "$LOG_DIR"
  : > "$LOG_DIR/agent.log"
}