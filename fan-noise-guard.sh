#!/usr/bin/env bash
# fan-noise-guard.sh
#
# Watchdog for a Dell PowerEdge R-family server's iDRAC manual fan control.
# iDRAC ramps fans to a loud fixed speed because it can't read thermal
# sensors on a third-party PCIe GPU (an NVIDIA card, in the case this was
# built for) — especially painful if that GPU is a passively-cooled
# datacenter card with no fan of its own. Manual IPMI fan control fixes the
# noise but disables iDRAC's own thermal response entirely, so this script
# is the replacement thermal response: it polls CPU/GPU temps and steps fan
# speed up as they rise.
#
# Safety model:
#  - Any failure to read a temperature (probe missing/erroring, hung command,
#    non-numeric output), or a temp >= PANIC_C, immediately (a) blasts fans
#    to 100% manually as a first response that doesn't depend on iDRAC
#    reacting quickly, then (b) hands control back to automatic/dynamic
#    iDRAC control, and STAYS there (does not re-arm manual mode) until this
#    script is restarted, so a human notices instead of the watchdog
#    silently flapping or running blind.
#  - Sensor reads are wrapped in `timeout` so a hung nvidia-smi/sensors call
#    can't block the loop forever with fans stuck at a stale speed — a
#    timeout is treated the same as any other failed read.
#  - The companion systemd unit's ExecStopPost also forces automatic
#    control, so a stopped or crashed watchdog never leaves fans pinned
#    low with nothing minding them.
#
# Must run as root (ipmitool needs the raw IPMI device).

set -uo pipefail

IPMI="/usr/bin/ipmitool"
POLL_INTERVAL=10       # seconds between checks
READ_TIMEOUT=5         # max seconds to wait on nvidia-smi/sensors before treating as a failed read
LOG_TAG="fan-noise-guard"
DRY_RUN="${DRY_RUN:-0}"   # DRY_RUN=1 ./fan-noise-guard.sh: log decisions, never touch fans

# STATS_FILE=/path/to/stats.csv ./fan-noise-guard.sh: append one CSV row per
# poll with everything we can measure — temps, GPU load/power (leading
# indicators of heat generation, available before temperature itself moves),
# and the *actual* fan RPM read back from the BMC (ground truth, not just
# the speed we requested). This is deliberately not used for any control
# decision — it's pure observability, meant as system-identification data
# for evaluating/retuning profiles later. Unset (default) disables it
# entirely with zero overhead.
STATS_FILE="${STATS_FILE:-}"
STATS_HEADER="ts,profile,panicked,gpu_temp_c,cpu_temp_c,gpu_util_pct,gpu_power_w,load1,tier,target_fan_pct,fan_rpm_avg"
stats_warned=0

# temp (°C) -> fan speed (%) tiers, evaluated on max(cpu_package, gpu).
# ENTER[i] is the temp at/above which we escalate from tier i to tier i+1.
# EXIT[i] is the temp at/below which we may drop back from tier i+1 to tier
# i. The gap between ENTER and EXIT is hysteresis: it stops the watchdog
# from flapping between two speeds when temp is hovering right at a boundary
# (e.g. bouncing between 44C and 45C), by requiring temp to fall well below
# where it stepped up before stepping back down.
#
# FAN_PROFILE picks which ENTER/EXIT/SPEEDS set to use — it's the only
# thing that trades noise for headroom. PANIC_C is deliberately NOT part of
# a profile: it's the hardware safety ceiling, not a comfort preference, so
# it stays the same no matter which profile is picked.
FAN_PROFILE="${FAN_PROFILE:-balanced}"
case "$FAN_PROFILE" in
  silent)
    # Quietest. Runs warmer within each tier before ramping — fine as long
    # as your components' actual thermal limits leave margin for it.
    ENTER=(50 60 70 78)
    EXIT=(45 55 65 73)
    SPEEDS=(20 30 45 60 85)
    ;;
  balanced)
    ENTER=(45 55 65 75)
    EXIT=(40 50 60 70)
    SPEEDS=(30 40 55 70 90)
    ;;
  performance)
    # Ramps sooner and harder to keep temps lower, at the cost of more fan
    # noise even at idle-ish loads.
    ENTER=(38 46 54 65)
    EXIT=(33 41 49 60)
    SPEEDS=(40 55 70 85 100)
    ;;
  *)
    echo "fan-noise-guard: unknown FAN_PROFILE '${FAN_PROFILE}' (expected: silent, balanced, performance)" >&2
    exit 1
    ;;
esac
PANIC_C=82   # hard ceiling: bail to automatic control and stay there, regardless of profile

last_speed=-1
tier=0   # index into SPEEDS; current committed tier (persists across polls)
panicked=0
panic_log_counter=0

log() {
  logger -t "$LOG_TAG" -- "$*" 2>/dev/null
  echo "$(date '+%F %T') $*"
}

is_valid_temp() {
  # Integers only (optionally negative, though a negative package/GPU temp
  # would itself be implausible sensor garbage worth rejecting too).
  [[ "$1" =~ ^-?[0-9]+$ ]]
}

read_gpu_temp() {
  timeout "$READ_TIMEOUT" nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1
}

read_cpu_temp() {
  # Highest "Package id N" temp1_input across all coretemp adapters.
  timeout "$READ_TIMEOUT" sensors -u 2>/dev/null | awk '
    /^Package id [0-9]+:/ { inpkg=1; next }
    inpkg && /_input:/ { print $2; inpkg=0; next }
    /^[A-Za-z]/ { inpkg=0 }
  ' | sort -rn | head -n1 | cut -d. -f1
}

# --- Stats-mode telemetry readers -------------------------------------
# All of these are best-effort and MUST NOT affect control decisions: they
# set `stat_*` globals to blank on any failure instead of erroring, unlike
# the safety-critical read_gpu_temp/read_cpu_temp above. A broken telemetry
# read should never trigger emergency_response — it isn't part of the thing
# keeping the hardware safe, just a bystander recording it.

read_gpu_extra() {
  local out
  out=$(timeout "$READ_TIMEOUT" nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1)
  stat_gpu_util="$(cut -d',' -f1 <<< "$out" | tr -d ' ')"
  stat_gpu_power="$(cut -d',' -f2 <<< "$out" | tr -d ' ')"
}

read_load1() {
  cut -d' ' -f1 /proc/loadavg 2>/dev/null
}

# Average RPM across every "Fan*" SDR entry iDRAC reports — the actual
# physical result, as opposed to the percentage we asked for. Useful since
# speed(%) -> RPM -> airflow -> cooling is not necessarily linear.
read_fan_rpm_avg() {
  timeout "$READ_TIMEOUT" "$IPMI" sdr type fan 2>/dev/null | awk -F'|' '
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $5)
      split($5, a, " ")
      if (a[1] ~ /^[0-9]+$/) { sum += a[1]; n++ }
    }
    END { if (n > 0) printf "%.0f", sum / n }
  '
}

log_stats() {
  [[ -z "$STATS_FILE" ]] && return 0
  [[ "$stats_warned" -eq 1 ]] && return 0   # already gave up this run, don't keep retrying every poll
  if [[ ! -f "$STATS_FILE" ]] && ! ( echo "$STATS_HEADER" > "$STATS_FILE" ) 2>/dev/null; then
    log "WARNING: cannot write STATS_FILE='${STATS_FILE}' (permissions? missing directory?) — stats logging disabled for this run"
    stats_warned=1
    return 0
  fi
  read_gpu_extra
  local load1 fanrpm fan_field
  load1=$(read_load1)
  fanrpm=$(read_fan_rpm_avg)
  fan_field="$last_speed"
  [[ "$panicked" -eq 1 ]] && fan_field="auto"
  echo "$(date -Iseconds),${FAN_PROFILE},${panicked},${gpu:-},${cpu:-},${stat_gpu_util:-},${stat_gpu_power:-},${load1:-},${tier},${fan_field},${fanrpm:-}" >> "$STATS_FILE" 2>/dev/null
}

set_manual_speed() {
  local pct="$1" hex
  hex=$(printf '0x%02x' "$pct")
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would set manual mode + fan speed ${pct}% (${hex})"
    return 0
  fi
  "$IPMI" raw 0x30 0x30 0x01 0x00 >/dev/null \
    && "$IPMI" raw 0x30 0x30 0x02 0xff "$hex" >/dev/null
}

set_automatic() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would force automatic/dynamic fan control"
    return 0
  fi
  "$IPMI" raw 0x30 0x30 0x01 0x01 >/dev/null
}

# Shared failure/over-temp response: since we can't be sure *why* things
# went wrong (dead sensor, hung IPMI, dying BMC), don't rely on any single
# recovery path. First force fans to 100% manually — this doesn't depend on
# iDRAC reacting, and manual-mode IPMI commands are the same primitive we've
# been using successfully all along, so it's likely to work even if
# something else is degraded. Then hand off to iDRAC's automatic control as
# the sustained fallback. Sets `panicked=1`, which is sticky: the main loop
# won't attempt to re-arm manual control on its own, so a human has to look
# at the logs and restart the service.
emergency_response() {
  local reason="$1"
  log "PANIC: ${reason} -> forcing fans to 100% and handing off to automatic iDRAC control (sticky; restart service to re-arm)"
  set_manual_speed 100 || log "PANIC: manual 100% speed command also failed, continuing to automatic handoff anyway"
  set_automatic || log "PANIC: automatic control handoff command failed too — iDRAC/IPMI may be unresponsive; check hardware/BMC directly"
  panicked=1
}

# Updates the global `tier` in place based on max temp `t`, using the
# ENTER/EXIT hysteresis bands, then sets the global `step_tier_speed`.
# Escalating can jump multiple tiers in one poll (no reason to delay cooling
# if temp spikes hard); de-escalating naturally happens one tier per poll
# since each EXIT check only fires once temp has dropped below that tier's
# own band.
#
# Must be called directly (not via `$(step_tier ...)`) — command
# substitution forks a subshell, which would silently discard the `tier`
# mutation on return and defeat the hysteresis entirely.
step_tier() {
  local t="$1"
  while (( tier < ${#SPEEDS[@]} - 1 )) && (( t >= ENTER[tier] )); do
    tier=$(( tier + 1 ))
  done
  while (( tier > 0 )) && (( t <= EXIT[tier - 1] )); do
    tier=$(( tier - 1 ))
  done
  step_tier_speed="${SPEEDS[tier]}"
}

on_signal() {
  log "signal received, restoring automatic fan control before exit"
  set_automatic
  exit 0
}
trap on_signal INT TERM

log "starting (profile=${FAN_PROFILE} dry_run=${DRY_RUN} stats_file=${STATS_FILE:-disabled}): poll=${POLL_INTERVAL}s enter=${ENTER[*]} exit=${EXIT[*]} speeds=${SPEEDS[*]} panic=${PANIC_C}C"

while true; do
  gpu=$(read_gpu_temp)
  cpu=$(read_cpu_temp)

  if [[ "$panicked" -eq 0 ]]; then
    if ! is_valid_temp "$gpu" || ! is_valid_temp "$cpu"; then
      emergency_response "failed to read temps (gpu='${gpu}' cpu='${cpu}') — probe missing, command hung/timed out, or unexpected output"
    else
      max_t=$(( gpu > cpu ? gpu : cpu ))

      if (( max_t >= PANIC_C )); then
        emergency_response "max temp ${max_t}C (gpu=${gpu}C cpu=${cpu}C) >= ${PANIC_C}C"
      else
        step_tier "$max_t"
        target="$step_tier_speed"
        if [[ "$target" != "$last_speed" ]]; then
          log "temp gpu=${gpu}C cpu=${cpu}C max=${max_t}C -> fan speed ${last_speed}% -> ${target}%"
          if set_manual_speed "$target"; then
            last_speed="$target"
          else
            emergency_response "ipmitool command to set fan speed ${target}% failed"
          fi
        fi
      fi
    fi
  else
    panic_log_counter=$(( (panic_log_counter + 1) % 30 ))
    if [[ "$panic_log_counter" -eq 0 ]]; then
      log "still in PANIC/automatic-control state; restart the service to re-arm manual control"
    fi
  fi

  log_stats

  sleep "$POLL_INTERVAL"
done
