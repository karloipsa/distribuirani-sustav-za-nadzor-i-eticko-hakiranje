conf_val() {
  awk -v k="$1" '$1==k":"{print $2}' "$CONF" 2>/dev/null || true
}


init_config() {
  BASE="$1"

  CONF="$BASE/server.conf"
  AUTH_LIST="$BASE/dozvoljeni_agenti.txt"


  # --------------------------------------------------
  # Osnovna konfiguracija
  # --------------------------------------------------

  LOG_DIR="$(conf_val log_dir)"
  : "${LOG_DIR:=$BASE/log}"

  PORT="$(conf_val port)"
  : "${PORT:=5000}"

  SERVER_IP="$(conf_val server_ip)"
  : "${SERVER_IP:=192.168.100.1}"

  QUORUM_PERCENT="$(conf_val quorum_percent)"
  : "${QUORUM_PERCENT:=67}"

  HEARTBEAT_TIMEOUT="$(conf_val heartbeat_timeout)"
  : "${HEARTBEAT_TIMEOUT:=120}"

  WATCHDOG_INTERVAL="$(conf_val watchdog_interval)"
  : "${WATCHDOG_INTERVAL:=5}"

  NIDS_CONTROL_IP="$(conf_val nids_control_ip)"
  : "${NIDS_CONTROL_IP:=192.168.100.254}"

  NIDS_CONTROL_PORT="$(conf_val nids_control_port)"
  : "${NIDS_CONTROL_PORT:=5001}"

  TLS_CA_PORT="$(conf_val tls_ca_port)"
  : "${TLS_CA_PORT:=5002}"

  BLOCK_TTL="$(conf_val block_ttl)"
  : "${BLOCK_TTL:=60}"

  DEBUG="$(conf_val debug)"
  : "${DEBUG:=0}"

  RESPONSE_MODE="$(conf_val response_mode)"
  : "${RESPONSE_MODE:=correlated}"


  # --------------------------------------------------
  # TLS konfiguracija
  # --------------------------------------------------

  TLS_ENABLE="$(conf_val tls_enable)"
  : "${TLS_ENABLE:=0}"

  TLS_CERT="$(conf_val tls_cert)"
  : "${TLS_CERT:=$BASE/ssl/server-cert.pem}"

  TLS_KEY="$(conf_val tls_key)"
  : "${TLS_KEY:=$BASE/ssl/server-key.pem}"

  TLS_CA="$(conf_val tls_ca)"
  : "${TLS_CA:=$BASE/ssl/ca-cert.pem}"


  # --------------------------------------------------
  # Validacija quorum vrijednosti
  # --------------------------------------------------

  if ! [[ "$QUORUM_PERCENT" =~ ^[0-9]+$ ]]; then
    QUORUM_PERCENT=67
  fi

  (( QUORUM_PERCENT < 1 )) &&
    QUORUM_PERCENT=1

  (( QUORUM_PERCENT > 100 )) &&
    QUORUM_PERCENT=100


  # --------------------------------------------------
  # Validacija heartbeat timeouta
  # --------------------------------------------------

  if ! [[ "$HEARTBEAT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    HEARTBEAT_TIMEOUT=120
  fi

  if (( HEARTBEAT_TIMEOUT < 1 )); then
    HEARTBEAT_TIMEOUT=120
  fi


  # --------------------------------------------------
  # Validacija watchdog intervala
  # --------------------------------------------------

  if ! [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]]; then
    WATCHDOG_INTERVAL=5
  fi

  if (( WATCHDOG_INTERVAL < 1 )); then
    WATCHDOG_INTERVAL=5
  fi


  # --------------------------------------------------
  # Validacija block TTL-a
  # --------------------------------------------------

  if ! [[ "$BLOCK_TTL" =~ ^[0-9]+$ ]]; then
    BLOCK_TTL=60
  fi

  if (( BLOCK_TTL < 1 )); then
    BLOCK_TTL=60
  fi


  # --------------------------------------------------
  # Validacija response moda
  # --------------------------------------------------

  case "$RESPONSE_MODE" in
    correlated|nids_only)
      ;;
    *)
      RESPONSE_MODE="correlated"
      ;;
  esac


  # --------------------------------------------------
  # Log rotacija
  # --------------------------------------------------

  ROTATE_SIZE=5000000
  MAX_ROTATES=3


  # --------------------------------------------------
  # Export
  # --------------------------------------------------

  export BASE
  export CONF
  export AUTH_LIST
  export LOG_DIR
  export PORT
  export SERVER_IP

  export QUORUM_PERCENT
  export HEARTBEAT_TIMEOUT
  export WATCHDOG_INTERVAL
  export BLOCK_TTL

  export NIDS_CONTROL_IP
  export NIDS_CONTROL_PORT

  export TLS_CA_PORT
  export TLS_ENABLE
  export TLS_CERT
  export TLS_KEY
  export TLS_CA

  export DEBUG
  export RESPONSE_MODE

  export ROTATE_SIZE
  export MAX_ROTATES
}