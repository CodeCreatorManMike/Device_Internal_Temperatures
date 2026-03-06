#!/usr/bin/env bash

set -u
export LC_ALL=C

kv() {
  printf '%s: %s\n' "$1" "$2"
}

to_celsius() {
  # Apple battery temp is usually centi-degrees C (e.g., 3029 -> 30.29 C)
  awk -v raw="$1" 'BEGIN { if (raw == "" || raw ~ /[^0-9]/) { print "not available"; exit } printf "%.2f C", raw/100.0 }'
}

to_signed_i64() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '%s' "$(( $1 ))"
  else
    printf 'not available'
  fi
}

first_match_value() {
  # $1 = blob, $2 = exact key name without quotes
  printf '%s\n' "$1" | awk -v key="$2" -F'= ' '$1 ~ "\"" key "\"" { gsub(/^ +| +$/, "", $2); print $2; exit }'
}

pm_batt="$(pmset -g batt 2>/dev/null)"
pm_therm="$(pmset -g therm 2>/dev/null)"
batt_blob="$(ioreg -rn AppleSmartBattery -l 2>/dev/null)"

power_source="$(printf '%s\n' "$pm_batt" | sed -n '1p' | sed -E "s/.*'([^']+)'.*/\1/")"
batt_line="$(printf '%s\n' "$pm_batt" | sed -n '2p')"

charge_pct="$(printf '%s\n' "$batt_line" | sed -E 's/.*\t([0-9]+%)?.*/\1/')"
batt_state="$(printf '%s\n' "$batt_line" | awk -F';' '{gsub(/^ +| +$/, "", $2); print $2}')"
time_remaining="$(printf '%s\n' "$batt_line" | awk -F';' '{gsub(/^ +| +$/, "", $3); print $3}')"

raw_temp="$(first_match_value "$batt_blob" "Temperature")"
raw_virtual_temp="$(first_match_value "$batt_blob" "VirtualTemperature")"
raw_voltage_mv="$(first_match_value "$batt_blob" "Voltage")"
raw_amperage="$(first_match_value "$batt_blob" "Amperage")"
raw_cycle_count="$(first_match_value "$batt_blob" "CycleCount")"
raw_current_capacity="$(first_match_value "$batt_blob" "CurrentCapacity")"
raw_max_capacity="$(first_match_value "$batt_blob" "MaxCapacity")"
raw_external_connected="$(first_match_value "$batt_blob" "ExternalConnected")"

amperage_signed="$(to_signed_i64 "$raw_amperage")"
if [ "$amperage_signed" != "not available" ]; then
  amperage_out="${amperage_signed} mA"
else
  amperage_out="not available"
fi

if [ -n "$raw_voltage_mv" ]; then
  voltage_out="${raw_voltage_mv} mV"
else
  voltage_out="not available"
fi

thermal_warning="$(printf '%s\n' "$pm_therm" | awk -F': ' '/thermal warning level|Thermal warning level/ {print $2; exit}')"
perf_warning="$(printf '%s\n' "$pm_therm" | awk -F': ' '/performance warning level|Performance warning level/ {print $2; exit}')"
cpu_power_status="$(printf '%s\n' "$pm_therm" | awk -F': ' '/CPU power status/ {print $2; exit}')"

if printf '%s\n' "$pm_therm" | grep -qi 'No thermal warning level has been recorded'; then
  thermal_warning="none"
fi
if printf '%s\n' "$pm_therm" | grep -qi 'No performance warning level has been recorded'; then
  perf_warning="none"
fi
if printf '%s\n' "$pm_therm" | grep -qi 'No CPU power status has been recorded'; then
  cpu_power_status="not recorded"
fi

[ -z "$power_source" ] && power_source="not available"
[ -z "$charge_pct" ] && charge_pct="not available"
[ -z "$batt_state" ] && batt_state="not available"
[ -z "$time_remaining" ] && time_remaining="not available"
[ -z "$raw_cycle_count" ] && raw_cycle_count="not available"
[ -z "$raw_current_capacity" ] && raw_current_capacity="not available"
[ -z "$raw_max_capacity" ] && raw_max_capacity="not available"
[ -z "$raw_external_connected" ] && raw_external_connected="not available"
[ -z "$thermal_warning" ] && thermal_warning="not available"
[ -z "$perf_warning" ] && perf_warning="not available"
[ -z "$cpu_power_status" ] && cpu_power_status="not available"

kv "Power Source" "$power_source"
kv "Battery Charge" "$charge_pct"
kv "Battery State" "$batt_state"
kv "Battery Time Remaining" "$time_remaining"
kv "Battery Temperature" "$(to_celsius "$raw_temp")"
kv "Battery Virtual Temperature" "$(to_celsius "$raw_virtual_temp")"
kv "Battery Voltage" "$voltage_out"
kv "Battery Amperage" "$amperage_out"
kv "Battery Cycle Count" "$raw_cycle_count"
kv "Battery Capacity" "${raw_current_capacity}% / ${raw_max_capacity}%"
kv "External Power Connected" "$raw_external_connected"
kv "Thermal Warning Level" "$thermal_warning"
kv "Performance Warning Level" "$perf_warning"
kv "CPU Power Status" "$cpu_power_status"
