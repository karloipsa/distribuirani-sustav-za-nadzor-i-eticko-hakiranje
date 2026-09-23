#!/usr/bin/env bash

get_local_ip() {
  ip -4 -o addr show dev "$IFACE" 2>/dev/null \
    | awk '{print $4}' \
    | cut -d/ -f1
}

detect_traffic_alert() {
  local local_ip=""
  local filter=""
  local TOP_COUNT=0
  local TOP_SRC="NA"
  local ts_now=""
  local trusted_ips=""

  local_ip=$(get_local_ip)

  if [[ -z "${local_ip:-}" ]]; then
    log WARNING "Ne mogu odrediti lokalni IP na sučelju $IFACE"
    return 1
  fi

  # Pouzdani čvorovi laboratorija:
  # - lokalni agent
  # - centralni server
  # - svi konfigurirani peer agenti
  #
  # Njihov normalni nadzorni promet ne smije uzrokovati TRAFFIC_ALERT.
  trusted_ips="$local_ip $SERVER_IP ${PEERS[*]:-}"

  # Promatramo dolazni promet koji može biti zanimljiv
  # za jednostavne flood/scan scenarije:
  #
  # - ICMP echo request
  # - TCP SYN bez ACK-a
  # - UDP promet
  #
  # Promet mora biti usmjeren prema lokalnom agentu.
  filter="dst host $local_ip and (icmp[icmptype]=8 or (tcp[tcpflags] & 2 != 0 and tcp[tcpflags] & 16 = 0) or udp)"

  read -r TOP_COUNT TOP_SRC < <(
    timeout "$TRAFFIC_WINDOW" \
      tcpdump -l -nn -tt \
        -i "$IFACE" \
        -c "$TRAFFIC_PKT" \
        "$filter" 2>/dev/null \
      | awk -v trusted="$trusted_ips" '
        BEGIN {
          n = split(trusted, t, " ")

          for (i = 1; i <= n; i++) {
            if (t[i] != "") {
              trusted_ip[t[i]] = 1
            }
          }
        }

        {
          s = $0

          # Iz tcpdump retka izdvoji samo izvor.
          #
          # Primjeri:
          #
          # ICMP:
          #   192.168.100.5
          #
          # TCP/UDP:
          #   192.168.100.5.54321
          sub(/^.*IP /, "", s)
          sub(/ > .*/, "", s)

          # TCP/UDP izvor može sadržavati port kao peti
          # numerički dio. ICMP ima samo četiri dijela.
          nparts = split(s, parts, ".")

          if (nparts == 5) {
            sub(/\.[0-9]+$/, "", s)
          }

          # Brojimo samo valjane IPv4 izvore koji nisu
          # pouzdani čvorovi laboratorija.
          if (s ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && !(s in trusted_ip)) {
            cnt[s]++
          }
        }

        END {
          top = "NA"
          max = 0

          for (ip in cnt) {
            if (cnt[ip] > max) {
              max = cnt[ip]
              top = ip
            }
          }

          printf "%d %s\n", max, top
        }
      ' || true
  )

  TOP_COUNT=${TOP_COUNT:-0}
  TOP_SRC=${TOP_SRC:-NA}

  if [[ "$TOP_COUNT" =~ ^[0-9]+$ ]] &&
     (( TOP_COUNT > TRAFFIC_THR )) &&
     [[ "$TOP_SRC" != "NA" ]]; then

    ts_now=$(date +%s)

    broadcast \
      "TRAFFIC_ALERT $AGENT_ID $TOP_COUNT $ts_now src=$TOP_SRC"

    log ALERT \
      "TRAFFIC source=$TOP_SRC count=$TOP_COUNT window=${TRAFFIC_WINDOW}s threshold=$TRAFFIC_THR local_ip=$local_ip"

    return 0
  fi

  log DEBUG \
    "TRAFFIC top_src=$TOP_SRC count=$TOP_COUNT window=${TRAFFIC_WINDOW}s threshold=$TRAFFIC_THR local_ip=$local_ip"

  return 0
}