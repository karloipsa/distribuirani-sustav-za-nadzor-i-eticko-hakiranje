#!/usr/bin/env bash

declare -gA blocked_sources

handle_block_result() {
  local line="$1"

  local sender
  local incident_id
  local src_ip
  local status

  local o1
  local o2
  local o3
  local o4
  local octet

  sender=$(awk '{print $2}' <<<"$line")

  incident_id=$(
    grep -oE 'incident_id=[^ ]+' <<<"$line" |
    cut -d= -f2- ||
    true
  )

  # src parsiramo kao raw vrijednost.
  # INVALID_INPUT namjerno može sadržavati nevaljani IP.
  src_ip=$(
    grep -oE 'src=[^ ]+' <<<"$line" |
    cut -d= -f2- ||
    true
  )

  status=$(
    grep -oE 'status=[^ ]+' <<<"$line" |
    cut -d= -f2 ||
    true
  )

  if [[ "$sender" != "nids" ]]; then
    log WARNING \
      "BLOCK_RESULT od nepoznatog sendera sender=${sender:-UNKNOWN} line='$line'"

    return 0
  fi

  if [[ -z "${incident_id:-}" ||
        -z "${src_ip:-}" ||
        -z "${status:-}" ]]; then

    log WARNING \
      "Neispravan BLOCK_RESULT: '$line'"

    return 0
  fi

  case "$status" in
    SUCCESS|EXISTS|FAIL|INVALID_INPUT|EXPIRED)
      ;;
    *)
      log WARNING \
        "BLOCK_RESULT s nepoznatim statusom status=$status incident_id=$incident_id src=$src_ip"

      return 0
      ;;
  esac

  # SUCCESS, EXISTS i EXPIRED mijenjaju stanje blokade,
  # pa za njih src mora biti stvarno valjan IPv4.
  if [[ "$status" == "SUCCESS" ||
        "$status" == "EXISTS" ||
        "$status" == "EXPIRED" ]]; then

    if [[ ! "$src_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      log WARNING \
        "BLOCK_RESULT status=$status s nevaljanim src=$src_ip incident_id=$incident_id"

      return 0
    fi

    IFS='.' read -r o1 o2 o3 o4 <<<"$src_ip"

    for octet in "$o1" "$o2" "$o3" "$o4"; do
      if (( 10#$octet > 255 )); then
        log WARNING \
          "BLOCK_RESULT status=$status s nevaljanim src=$src_ip incident_id=$incident_id"

        return 0
      fi
    done
  fi

  log BLOCK_RESULT \
    "sender=$sender incident_id=$incident_id src=$src_ip status=$status"

  if [[ "$status" == "SUCCESS" || "$status" == "EXISTS" ]]; then
    blocked_sources["$src_ip"]="ACTIVE"

    log BLOCK_STATE \
      "src=$src_ip state=ACTIVE incident_id=$incident_id result=$status"
  fi

  if [[ "$status" == "EXPIRED" ]]; then
    unset 'blocked_sources[$src_ip]'

    log BLOCK_STATE \
      "src=$src_ip state=INACTIVE incident_id=$incident_id result=$status"
  fi
}