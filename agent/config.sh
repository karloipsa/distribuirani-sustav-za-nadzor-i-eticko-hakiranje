#!/usr/bin/env bash

read_conf() {
  local expr="$1"

  yq e -r "$expr" "$CONF" 2>/dev/null || true
}


init_config() {
  BASE="$1"
  CONF="$BASE/agent.conf"

  LOG_DIR="$BASE/log"

  ROTATE_SIZE=2000000
  MAX_ROTATES=3

  mkdir -p "$LOG_DIR" "$BASE/ssl"


  # --------------------------------------------------
  # Osnovna konfiguracija agenta
  # --------------------------------------------------

  AGENT_ID="$(read_conf '.id')"

  SERVER_IP="$(read_conf '.server_ip')"
  SERVER_PORT="$(read_conf '.server_port')"

  IFACE="$(read_conf '.iface')"
  [[ "$IFACE" == "null" || -z "$IFACE" ]] && IFACE="eth0"


  # --------------------------------------------------
  # Intervali
  # --------------------------------------------------

  HEARTBEAT_INT="$(read_conf '.intervals.heartbeat')"
  [[ "$HEARTBEAT_INT" == "null" || -z "$HEARTBEAT_INT" ]] && HEARTBEAT_INT=20

  STATUS_INT="$(read_conf '.intervals.status')"
  [[ "$STATUS_INT" == "null" || -z "$STATUS_INT" ]] && STATUS_INT=40

  LAT_INT="$(read_conf '.intervals.latency')"
  [[ "$LAT_INT" == "null" || -z "$LAT_INT" ]] && LAT_INT=60

  BANNER_INT="$(read_conf '.intervals.banner')"
  [[ "$BANNER_INT" == "null" || -z "$BANNER_INT" ]] && BANNER_INT=90

  DISCOV_INT="$(read_conf '.intervals.discovery')"
  [[ "$DISCOV_INT" == "null" || -z "$DISCOV_INT" ]] && DISCOV_INT=120

  TRAFFIC_INT="$(read_conf '.intervals.traffic')"
  [[ "$TRAFFIC_INT" == "null" || -z "$TRAFFIC_INT" ]] && TRAFFIC_INT=120


  # --------------------------------------------------
  # Traffic monitoring
  # --------------------------------------------------

  TRAFFIC_PKT="$(read_conf '.traffic.sample_packets')"
  [[ "$TRAFFIC_PKT" == "null" || -z "$TRAFFIC_PKT" ]] && TRAFFIC_PKT=80

  TRAFFIC_THR="$(read_conf '.traffic.threshold')"
  [[ "$TRAFFIC_THR" == "null" || -z "$TRAFFIC_THR" ]] && TRAFFIC_THR=60

  TRAFFIC_WINDOW="$(read_conf '.traffic.window_seconds')"
  [[ "$TRAFFIC_WINDOW" == "null" || -z "$TRAFFIC_WINDOW" ]] && TRAFFIC_WINDOW=5


  # --------------------------------------------------
  # Servisi
  # --------------------------------------------------

  mapfile -t SERVICES < <(
    read_conf '.services[].name' |
    tr '[:upper:]' '[:lower:]'
  )

  mapfile -t PORTS < <(
    read_conf '.services[].port'
  )


  # --------------------------------------------------
  # Peer čvorovi
  # --------------------------------------------------

  if yq e -r '.peers' "$CONF" >/dev/null 2>&1; then
    mapfile -t PEERS < <(
      read_conf '.peers[]'
    )
  else
    PEERS=()
  fi


  # --------------------------------------------------
  # Mreža
  # --------------------------------------------------

  SUBNET="$(read_conf '.subnet')"
  [[ "$SUBNET" == "null" || -z "$SUBNET" ]] && SUBNET="192.168.100.0/24"


  # --------------------------------------------------
  # Debug
  # --------------------------------------------------

  DEBUG="$(read_conf '.debug')"
  [[ "$DEBUG" == "null" || -z "$DEBUG" ]] && DEBUG=0


  # --------------------------------------------------
  # TLS
  # --------------------------------------------------

  TLS_ENABLE="$(read_conf '.tls.enable')"
  [[ "$TLS_ENABLE" == "null" || -z "$TLS_ENABLE" ]] && TLS_ENABLE=0


  TLS_CA="$(read_conf '.tls.ca')"
  [[ "$TLS_CA" == "null" || -z "$TLS_CA" ]] && \
    TLS_CA="$BASE/ssl/ca-cert.pem"

  # Ako je TLS_CA relativna putanja, npr. ./ssl/ca-cert.pem,
  # pretvori je u apsolutnu putanju unutar direktorija agenta.
  if [[ "$TLS_CA" != /* ]]; then
    TLS_CA="$BASE/${TLS_CA#./}"
  fi


  TLS_CERT="$(read_conf '.tls.cert')"
  [[ "$TLS_CERT" == "null" || -z "$TLS_CERT" ]] && \
    TLS_CERT="$BASE/ssl/${AGENT_ID}-cert.pem"


  TLS_KEY="$(read_conf '.tls.key')"
  [[ "$TLS_KEY" == "null" || -z "$TLS_KEY" ]] && \
    TLS_KEY="$BASE/ssl/${AGENT_ID}-key.pem"


  # --------------------------------------------------
  # Banner konfiguracija
  # --------------------------------------------------

  BANNER_MODE="$(read_conf '.banner.mode')"
  [[ "$BANNER_MODE" == "null" || -z "$BANNER_MODE" ]] && BANNER_MODE="change"

  BANNER_DISCOVERY="$(read_conf '.banner.discovery')"
  [[ "$BANNER_DISCOVERY" == "null" || -z "$BANNER_DISCOVERY" ]] && BANNER_DISCOVERY=1


  # --------------------------------------------------
  # Debug intervali
  # --------------------------------------------------

  if [[ "$DEBUG" == "1" ]]; then
    HEARTBEAT_INT=5
    STATUS_INT=10
    LAT_INT=15
    BANNER_INT=30
    DISCOV_INT=30
    TRAFFIC_INT=10
  fi


  # --------------------------------------------------
  # Export
  # --------------------------------------------------

  export BASE CONF LOG_DIR ROTATE_SIZE MAX_ROTATES

  export AGENT_ID SERVER_IP SERVER_PORT IFACE

  export HEARTBEAT_INT STATUS_INT LAT_INT
  export BANNER_INT DISCOV_INT TRAFFIC_INT

  export TRAFFIC_PKT TRAFFIC_THR TRAFFIC_WINDOW

  export SUBNET DEBUG

  export TLS_ENABLE TLS_CA TLS_CERT TLS_KEY

  export BANNER_MODE BANNER_DISCOVERY
}