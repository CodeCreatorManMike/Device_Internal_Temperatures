#!/usr/bin/env bash

set -u
set -o pipefail
export LC_ALL=C

# -----------------------------------------------------------------------------
# Nexthink-ready macOS battery / thermal inventory script
#
# Recommended Nexthink context:
# - Interactive User
#
# Recommended Nexthink outputs to define in the UI:
# - Status                    (String)
# - Success                   (String)   # use Bool only if your macOS Bash RA config supports it cleanly
# - ErrorMessage              (String)
# - PowerSource               (String)
# - BatteryCharge             (String)
# - BatteryState              (String)
# - BatteryTimeRemaining      (String)
# - BatteryTemperature        (String)
# - BatteryVirtualTemperature (String)
# - BatteryVoltage            (String)
# - BatteryAmperage           (String)
# - BatteryCycleCount         (String)
# - BatteryCurrentCapacity    (String)
# - BatteryMaxCapacity        (String)
# - BatteryHealthPercent      (String)
# - ExternalPowerConnected    (String)
# - ThermalWarningLevel       (String)
# - PerformanceWarningLevel   (String)
# - CpuPowerStatus            (String)
# -----------------------------------------------------------------------------

readonly MAX_OUTPUT_LEN=1000
EMITTED=0

# ----- fixed output defaults --------------------------------------------------

Status="Error"
Success="false"
ErrorMessage="Unknown error"

PowerSource="not available"
BatteryCharge="not available"
BatteryState="not available"
BatteryTimeRemaining="not available"
BatteryTemperature="not available"
BatteryVirtualTemperature="not available"
BatteryVoltage="not available"
BatteryAmperage="not available"
BatteryCycleCount="not available"
BatteryCurrentCapacity="not available"
BatteryMaxCapacity="not available"
BatteryHealthPercent="not available"
ExternalPowerConnected="not available"
ThermalWarningLevel="not available"
PerformanceWarningLevel="not available"
CpuPowerStatus="not available"

# ----- helpers ----------------------------------------------------------------

trim_output() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\t'/ }"
  if [ "${#value}" -gt "$MAX_OUTPUT_LEN" ]; then
    value="${value:0:$MAX_OUTPUT_LEN}"
  fi
  printf '%s' "$value"
}

emit_kv() {
  local key="$1"
  local value="${2:-}"
  printf '%s: %s\n' "$key" "$(trim_output "$value")"
}

emit_outputs() {
  [ "$EMITTED" -eq 1 ] && return 0
  EMITTED=1

  emit_kv "Status" "$Status"
  emit_kv "Success" "$Success"
  emit_kv "ErrorMessage" "$ErrorMessage"

  emit_kv "PowerSource" "$PowerSource"
  emit_kv "BatteryCharge" "$BatteryCharge"
  emit_kv "BatteryState" "$BatteryState"
  emit_kv "BatteryTimeRemaining" "$BatteryTimeRemaining"
  emit_kv "BatteryTemperature" "$BatteryTemperature"
  emit_kv "BatteryVirtualTemperature" "$BatteryVirtualTemperature"
  emit_kv "BatteryVoltage" "$BatteryVoltage"
  emit_kv "BatteryAmperage" "$BatteryAmperage"
  emit_kv "BatteryCycleCount" "$BatteryCycleCount"
  emit_kv "BatteryCurrentCapacity" "$BatteryCurrentCapacity"
  emit_kv "BatteryMaxCapacity" "$BatteryMaxCapacity"
  emit_kv "BatteryHealthPercent" "$BatteryHealthPercent"
  emit_kv "ExternalPowerConnected" "$ExternalPowerConnected"
  emit_kv "ThermalWarningLevel" "$ThermalWarningLevel"
  emit_kv "PerformanceWarningLevel" "$PerformanceWarningLevel"
  emit_kv "CpuPowerStatus" "$CpuPowerStatus"
}

fail() {
  local message="${1:-Unexpected error}"
  Status="Error"
  Success="false"
  ErrorMessage="$message"
  emit_outputs
  exit 1
}

on_err() {
  local exit_code="$1"
  local line_no="$2"
  fail "Command failed at line ${line_no} with exit code ${exit_code}"
}

trap 'on_err $? $LINENO' ERR

is_non_negative_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

to_celsius() {
  local raw="${1:-}"
  if is_non_negative_int "$raw"; then
    awk -v raw="$raw" 'BEGIN { printf "%.2f C", raw/100.0 }'
  else
    printf 'not available'
  fi
}

to_signed_i64() {
  local raw="${1:-}"
  if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$raw"
  else
    printf 'not available'
  fi
}

first_match_value() {
  # $1 = blob, $2 = exact key name without quotes
  printf '%s\n' "$1" | awk -v key="$2" -F'= ' '$1 ~ "\"" key "\"" { gsub(/^ +| +$/, "", $2); print $2; exit }'
}

safe_value() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf 'not available'
  fi
}

calc_health_percent() {
  local current="${1:-}"
  local max="${2:-}"

  if is_non_negative_int "$current" && is_non_negative_int "$max" && [ "$max" -gt 0 ]; then
    awk -v c="$current" -v m="$max" 'BEGIN { printf "%.2f%%", (c/m)*100 }'
  else
    printf 'not available'
  fi
}

# ----- main -------------------------------------------------------------------

pm_batt="$(pmset -g batt 2>/dev/null || true)"
pm_therm="$(pmset -g therm 2>/dev/null || true)"
batt_blob="$(ioreg -rn AppleSmartBattery -l 2>/dev/null || true)"

[ -n "$pm_batt" ] || fail "Unable to read battery information from pmset"
[ -n "$batt_blob" ] || fail "Unable to read AppleSmartBattery information from ioreg"

power_source="$(printf '%s\n' "$pm_batt" | sed -n '1p' | sed -E "s/.*'([^']+)'.*/\1/")"
batt_line="$(printf '%s\n' "$pm_batt" | sed -n '2p')"

charge_pct="$(printf '%s\n' "$batt_line" | sed -nE 's/.*([0-9]+%).*/\1/p')"
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
  BatteryAmperage="${amperage_signed} mA"
fi

if is_non_negative_int "${raw_voltage_mv:-}"; then
  BatteryVoltage="${raw_voltage_mv} mV"
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

PowerSource="$(safe_value "$power_source")"
BatteryCharge="$(safe_value "$charge_pct")"
BatteryState="$(safe_value "$batt_state")"
BatteryTimeRemaining="$(safe_value "$time_remaining")"
BatteryTemperature="$(to_celsius "$raw_temp")"
BatteryVirtualTemperature="$(to_celsius "$raw_virtual_temp")"
BatteryCycleCount="$(safe_value "$raw_cycle_count")"
ExternalPowerConnected="$(safe_value "$raw_external_connected")"
ThermalWarningLevel="$(safe_value "$thermal_warning")"
PerformanceWarningLevel="$(safe_value "$perf_warning")"
CpuPowerStatus="$(safe_value "$cpu_power_status")"

if is_non_negative_int "${raw_current_capacity:-}"; then
  BatteryCurrentCapacity="${raw_current_capacity} mAh"
fi

if is_non_negative_int "${raw_max_capacity:-}"; then
  BatteryMaxCapacity="${raw_max_capacity} mAh"
fi

BatteryHealthPercent="$(calc_health_percent "$raw_current_capacity" "$raw_max_capacity")"

Status="Success"
Success="true"
ErrorMessage=""

emit_outputs
exit 0
