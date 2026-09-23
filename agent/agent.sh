#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

BASE="$(cd "$(dirname "$0")" && pwd)"

source "$BASE/config.sh"
source "$BASE/logging.sh"
source "$BASE/services.sh"
source "$BASE/network.sh"
source "$BASE/banner.sh"
source "$BASE/traffic.sh"
source "$BASE/listener.sh"
source "$BASE/jobs.sh"


# --------------------------------------------------
# Inicijalizacija
# --------------------------------------------------

init_config "$BASE"
init_logging
load_unit_list
init_banner


# --------------------------------------------------
# Cleanup
# --------------------------------------------------

cleanup() {
  pkill -P $$ 2>/dev/null || true
}

trap cleanup EXIT


# --------------------------------------------------
# Startup informacije
# --------------------------------------------------

log INFO \
  "Agent '$AGENT_ID' pokrenut (TLS=$TLS_ENABLE, iface=$IFACE)"

log INFO \
  "Configured services: $(printf '%s ' "${SERVICES[@]}")"


# --------------------------------------------------
# Pokretanje background poslova
#
# Listener se mora pokrenuti prije inicijalnih provjera.
# Server može odmah nakon SERVICE_STATUS poruke poslati
# COMMAND_RESTART, pa agentov port 6000 mora već biti spreman.
# --------------------------------------------------

start_all_jobs


# --------------------------------------------------
# Čekanje listenera
# --------------------------------------------------

LISTENER_READY=0

for _ in {1..20}; do

  if ss -lnt 2>/dev/null |
     awk '{print $4}' |
     grep -qE '[:.]6000$'; then

    LISTENER_READY=1
    break
  fi

  sleep 0.25
done


if (( LISTENER_READY == 0 )); then
  log ERROR \
    "Listener na portu 6000 nije pokrenut tijekom startup timeouta"

  exit 1
fi


log INFO \
  "Listener spreman na portu 6000 (TLS=$TLS_ENABLE)"


# --------------------------------------------------
# Inicijalne provjere
# --------------------------------------------------

sleep 1

run_initial_checks


# --------------------------------------------------
# Agent ostaje aktivan
# --------------------------------------------------

wait