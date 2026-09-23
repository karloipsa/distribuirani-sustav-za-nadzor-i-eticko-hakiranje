#!/usr/bin/env bash

init_logging() {
  mkdir -p "$LOG_DIR" "$BASE/ssl"

  LOG_FILE="$LOG_DIR/promet.log"
  : > "$LOG_FILE"

  HAVE_FLOCK=1
  if ! command -v flock >/dev/null 2>&1; then
    HAVE_FLOCK=0
  fi

  LOCK_FILE="$LOG_FILE.lock"
  if [[ $HAVE_FLOCK -eq 1 ]]; then
    exec {LOCK_FD}>"$LOCK_FILE"
  fi

  export LOG_FILE HAVE_FLOCK LOCK_FILE
  [[ ${LOCK_FD:-} ]] && export LOCK_FD
}

lock_begin() {
  if [[ $HAVE_FLOCK -eq 1 ]]; then
    flock "$LOCK_FD"
  fi
}

lock_end() {
  if [[ $HAVE_FLOCK -eq 1 ]]; then
    flock -u "$LOCK_FD"
  fi
}

rotate_logs() {
  lock_begin

  local f="$LOG_FILE"
  local sz=0

  [[ -f $f ]] && sz=$(stat -c%s "$f" 2>/dev/null || echo 0)

  if (( sz > ROTATE_SIZE )); then
    local i
    for ((i=MAX_ROTATES; i>1; i--)); do
      mv -f "$f.$((i-1))" "$f.$i" 2>/dev/null || true
    done
    mv -f "$f" "$f.1" 2>/dev/null || true
    : > "$f"
  fi

  lock_end
}

log() {
  local lvl="$1"
  local msg="$2"

  [[ "$lvl" == "DEBUG" && "$DEBUG" != "1" ]] && return

  rotate_logs
  lock_begin
  printf '[%s] [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S.%3N')" "$lvl" "$msg" >> "$LOG_FILE"
  lock_end
}