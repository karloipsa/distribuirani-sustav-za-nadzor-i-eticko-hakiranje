#!/usr/bin/env bash
set -euo pipefail

ulimit -n 4096 || true
trap '' PIPE

BASE="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------
# Učitavanje modula
# --------------------------------------------------

source "$BASE/config.sh"
source "$BASE/logging.sh"
source "$BASE/agents.sh"
source "$BASE/network.sh"
source "$BASE/handlers.sh"


# --------------------------------------------------
# Inicijalizacija
# --------------------------------------------------

init_config "$BASE"
init_logging
load_agents
init_ncat_base


# --------------------------------------------------
# Startup informacije
# --------------------------------------------------

log INFO \
  "Pokrećem modularni server na portu $PORT (TLS=$TLS_ENABLE, quorum=$QUORUM_PERCENT%, heartbeat_timeout=${HEARTBEAT_TIMEOUT}s, watchdog=${WATCHDOG_INTERVAL}s)"


# --------------------------------------------------
# Glavna serverska petlja
# --------------------------------------------------

while true; do

  if port_in_use "$PORT"; then
    log WARNING \
      "Port $PORT zauzet; čekam 1s"

    sleep 1
    continue
  fi

  # Listener sada u sebi:
  #
  # - prima poruke agenata
  # - prima NIDS_ALERT
  # - održava last_heartbeat stanje
  # - svakih WATCHDOG_INTERVAL sekundi
  #   provjerava zdravlje agenata
  start_server_listener

  log WARNING \
    "Listener na $PORT je izašao; restart za 1s"

  sleep 1
done