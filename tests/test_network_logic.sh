#!/usr/bin/env bash
#
# test_network_logic.sh
# ---------------------
# Verifies the setup_network() decision tree in init.sh WITHOUT real hardware.
# It extracts online()/setup_network() from ../init.sh, then runs each network
# scenario against mocked `ping`, `nmcli`, `sleep`, and `read`, asserting the
# correct path is taken (already-online / static-ethernet / hotspot / manual-wifi).
#
# Run:  bash tests/test_network_logic.sh
# Exit: 0 if all scenarios pass.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${HERE}/../init.sh"
STATE="$(mktemp)"
trap 'rm -f "${STATE}"' EXIT

PASS=0; FAIL=0

# Network constants the extracted function references (defined above section 1
# in init.sh, so we provide matching defaults here for the isolated test).
STATIC_IP="172.16.1.14/16"
STATIC_GW="172.16.0.254"
STATIC_DNS="168.95.1.1,168.95.192.1"

# Extract just the network functions (online + setup_network) from init.sh,
# stopping before the standalone `setup_network` invocation line.
extract_network() {
  awk '
    /^online\(\) \{/          {grab=1}
    done && /^setup_network$/ {exit}      # stop before the invocation line
    grab                      {print}
    /^setup_network\(\) \{/   {infn=1}
    infn && /^\}/             {infn=0; done=1}
  ' "${INIT}"
}

run_scenario() {
  local name="$1" has_eth="$2" ping_mode="$3" expect="$4"
  : > "${STATE}"

  # ---- mocks ----
  ping() {  # success/failure driven by ${ping_mode} + recorded nmcli actions
    case "${ping_mode}" in
      online)    return 0 ;;
      after_eth) grep -q ETH_UP "${STATE}" && return 0 || return 1 ;;
      after_hs)  grep -q HS_CONNECT "${STATE}" && return 0 || return 1 ;;
      after_wifi)grep -q WIFI_CONNECT "${STATE}" && return 0 || return 1 ;;
      never)     return 1 ;;
    esac
  }
  nmcli() {
    local args="$*"
    case "${args}" in
      *"-f DEVICE,TYPE device status"*)
        [[ "${has_eth}" == "1" ]] && echo "eth0:ethernet" || echo "wlan0:wifi" ;;
      *"connection up cachyos-static-eth"*) echo ETH_UP >> "${STATE}" ;;
      *"device wifi connect "*hotspot*|*"device wifi connect michaels"*) echo HS_CONNECT >> "${STATE}" ;;
      *"device wifi connect "*) echo WIFI_CONNECT >> "${STATE}" ;;
      *"device wifi list"*) echo "SSID  RATE  SIGNAL" ;;
      *) : ;;
    esac
    return 0
  }
  sleep() { :; }                       # no real waiting
  read() {                             # feed manual-wifi prompt
    local _flag OPTARG OPTIND var
    # crude: assign last arg (variable name) a canned value
    for var in "$@"; do :; done
    printf -v "${var}" '%s' "TestNet"
    return 0
  }
  export HOTSPOT_PASS="dummy-pass"     # enable hotspot path
  export HOTSPOT_SSID="michaels iphone"

  # ---- run ----
  local out rc
  out="$( setup_network 2>&1 )"; rc=$?

  if echo "${out}" | grep -qi "${expect}"; then
    echo "  PASS  ${name}  →  matched: \"${expect}\""
    PASS=$((PASS+1))
  else
    echo "  FAIL  ${name}  →  expected \"${expect}\""
    echo "        got: $(echo "${out}" | tr '\n' '|')"
    FAIL=$((FAIL+1))
  fi
  unset -f ping nmcli sleep read
}

# Load the functions under test
# shellcheck disable=SC1090
source <(extract_network)

echo "── setup_network() scenario tests ──"
run_scenario "already online"           0 online     "Already connected"
run_scenario "static ethernet works"    1 after_eth  "Static Ethernet connected"
run_scenario "eth fails, hotspot works" 1 after_hs   "iPhone hotspot"
run_scenario "no eth, hotspot works"    0 after_hs   "iPhone hotspot"
run_scenario "all fail, manual wifi"    0 after_wifi "Connected via WiFi"

echo
echo "Result: ${PASS} passed, ${FAIL} failed."
[[ "${FAIL}" -eq 0 ]]
