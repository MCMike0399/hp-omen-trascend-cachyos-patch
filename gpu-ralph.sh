#!/bin/bash
# gpu-ralph.sh — "Ralph loop" monitoring + GPS thermal limit diagnostic
# HP Omen Transcend 14 (8C58) + RTX 4060 Laptop
#
# Problem: WMI SET writes gpu_slowdown_temp=87°C (0x57) but the NVIDIA driver
# still enforces a GPS thermal limit at ~58-60°C causing permanent power throttle.
# GPU stuck at ~33W/P3 instead of reaching 55-65W at native 2880×1800 in P3R.
#
# This script monitors GPU state and attempts corrective actions.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

LOGFILE="/tmp/gpu-ralph.log"
CSVLOG="/tmp/gpu-ralph.csv"

# Initialize CSV if not exists
if [[ ! -f "$CSVLOG" ]]; then
    echo "timestamp,power_w,temp_c,clk_mhz,mem_mhz,util_pct,pstate,enforced_limit_w,slowdown_tlimit,max_op_tlimit,fan1_rpm,fan2_rpm,fan_pct" > "$CSVLOG"
fi

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOGFILE"; }

# ─── Gather GPU data ────────────────────────────────────────────────────────
read_gpu() {
    GPU_CSV=$(nvidia-smi --query-gpu=power.draw,temperature.gpu,clocks.gr,clocks.mem,utilization.gpu,pstate,enforced.power.limit,power.limit --format=csv,noheader,nounits 2>/dev/null || echo "0,0,0,0,0,P0,0,0")
    IFS=',' read -r POWER TEMP CLK MEM UTIL PSTATE ENFORCED PLIMIT <<< "$GPU_CSV"
    POWER=$(echo "$POWER" | xargs)
    TEMP=$(echo "$TEMP" | xargs)
    CLK=$(echo "$CLK" | xargs)
    MEM=$(echo "$MEM" | xargs)
    UTIL=$(echo "$UTIL" | xargs)
    PSTATE=$(echo "$PSTATE" | xargs)
    ENFORCED=$(echo "$ENFORCED" | xargs)
    PLIMIT=$(echo "$PLIMIT" | xargs)

    # Thermal limit details
    TLIMIT_RAW=$(nvidia-smi -q 2>/dev/null | grep -E "T\.Limit" || true)
    SLOWDOWN_TLIMIT=$(echo "$TLIMIT_RAW" | grep "Slowdown" | awk -F: '{print $2}' | xargs)
    MAX_OP_TLIMIT=$(echo "$TLIMIT_RAW" | grep "Max Operating" | head -1 | awk -F: '{print $2}' | xargs)
    TARGET_TEMP=$(nvidia-smi -q 2>/dev/null | grep "GPU Target Temperature" | awk -F: '{print $2}' | xargs)

    # Clock event reasons (current)
    SW_THERMAL=$(nvidia-smi -q 2>/dev/null | grep -A1 "SW Thermal Slowdown" | head -1 | awk -F: '{print $2}' | xargs)
    SW_POWER=$(nvidia-smi -q 2>/dev/null | grep "SW Power Cap" | head -1 | awk -F: '{print $2}' | xargs)

    # SW Thermal Slowdown cumulative counter (microseconds)
    SW_THERMAL_US=$(nvidia-smi -q 2>/dev/null | grep -A15 "Clocks Event Reasons Counters" | grep "SW Thermal" | awk -F: '{print $2}' | xargs | awk '{print $1}')
}

# ─── Gather fan data ─────────────────────────────────────────────────────────
read_fans() {
    # Find HP hwmon
    HP_HWMON=""
    for hw in /sys/class/hwmon/hwmon*; do
        if [[ -f "$hw/name" ]] && grep -q "hp" "$hw/name" 2>/dev/null; then
            HP_HWMON="$hw"
            break
        fi
    done

    FAN1_RPM=0; FAN2_RPM=0; FAN_PCT="auto"
    if [[ -n "$HP_HWMON" ]]; then
        FAN1_RPM=$(cat "$HP_HWMON/fan1_input" 2>/dev/null || echo 0)
        FAN2_RPM=$(cat "$HP_HWMON/fan2_input" 2>/dev/null || echo 0)
        PWM_ENABLE=$(cat "$HP_HWMON/pwm1_enable" 2>/dev/null || echo 2)
        if [[ "$PWM_ENABLE" == "1" ]]; then
            PWM_VAL=$(cat "$HP_HWMON/pwm1" 2>/dev/null || echo 0)
            FAN_PCT="$((PWM_VAL * 100 / 255))%"
        fi
    fi

    # CPU temp
    CPU_TEMP=0
    for hw in /sys/class/hwmon/hwmon*; do
        if [[ -f "$hw/name" ]] && grep -q "coretemp" "$hw/name" 2>/dev/null; then
            CPU_TEMP=$(($(cat "$hw/temp1_input" 2>/dev/null || echo 0) / 1000))
            break
        fi
    done
}

# ─── Estimate effective GPS thermal limit ────────────────────────────────────
calc_gps_limit() {
    # GPU Slowdown T.Limit Temp shows margin to the slowdown threshold
    # Negative = above threshold (throttled)
    # Effective GPS limit ≈ current_temp + slowdown_tlimit
    local val="${SLOWDOWN_TLIMIT%% *}"  # strip units
    val="${val%C}"
    val=$(echo "$val" | xargs)
    if [[ -n "$val" && "$val" != "N/A" ]]; then
        GPS_EFFECTIVE=$((TEMP + val))
    else
        GPS_EFFECTIVE="?"
    fi
}

# ─── Assess health ──────────────────────────────────────────────────────────
assess() {
    STATUS=""
    COLOR="$GREEN"

    POWER_INT=${POWER%.*}

    if [[ "$UTIL" -ge 90 && "$POWER_INT" -lt 45 ]]; then
        STATUS="THROTTLED — GPU at ${UTIL}% util but only ${POWER}W (limit: ${ENFORCED}W)"
        COLOR="$RED"
    elif [[ "$UTIL" -ge 90 && "$POWER_INT" -ge 45 && "$POWER_INT" -lt 55 ]]; then
        STATUS="PARTIAL — drawing ${POWER}W, could reach ${ENFORCED}W"
        COLOR="$YELLOW"
    elif [[ "$UTIL" -ge 90 && "$POWER_INT" -ge 55 ]]; then
        STATUS="HEALTHY — drawing ${POWER}W at ${UTIL}% util"
        COLOR="$GREEN"
    else
        STATUS="LOW LOAD — ${UTIL}% util, ${POWER}W"
        COLOR="$CYAN"
    fi

    # Check GPS thermal limit
    local sd_val="${SLOWDOWN_TLIMIT%% *}"
    sd_val="${sd_val%C}"
    sd_val=$(echo "$sd_val" | xargs)
    if [[ -n "$sd_val" && "$sd_val" != "N/A" ]]; then
        if [[ "$sd_val" -lt 5 ]]; then
            GPS_STATUS="${RED}GPS LIMIT ACTIVE — effective ~${GPS_EFFECTIVE}°C (should be 87°C)${NC}"
        else
            GPS_STATUS="${GREEN}GPS OK — ${sd_val}°C headroom to slowdown${NC}"
        fi
    else
        GPS_STATUS="${YELLOW}GPS unknown${NC}"
    fi
}

# ─── Display ─────────────────────────────────────────────────────────────────
display() {
    clear
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  ${MAGENTA}RALPH LOOP${NC}${BOLD} — GPU Power Monitor       ${DIM}${ts}${NC}${BOLD}  ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    echo -e "${BOLD}║${NC}  ${BOLD}Status:${NC} ${COLOR}${STATUS}${NC}"
    echo -e "${BOLD}║${NC}  ${BOLD}GPS:${NC}    ${GPS_STATUS}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    # GPU metrics
    local pwr_bar=""
    local pwr_int=${POWER%.*}
    local enf_int=${ENFORCED%.*}
    local pwr_pct=$((pwr_int * 100 / (enf_int > 0 ? enf_int : 65)))
    for ((i=0; i<50; i++)); do
        if ((i * 100 / 50 < pwr_pct)); then
            if ((pwr_pct < 60)); then pwr_bar+="${RED}█${NC}"
            elif ((pwr_pct < 80)); then pwr_bar+="${YELLOW}█${NC}"
            else pwr_bar+="${GREEN}█${NC}"
            fi
        else
            pwr_bar+="░"
        fi
    done

    echo -e "${BOLD}║${NC}  Power:  ${BOLD}${POWER}W${NC} / ${ENFORCED}W  [${pwr_bar}]"
    echo -e "${BOLD}║${NC}  Temp:   ${BOLD}${TEMP}°C${NC}  (target: ${TARGET_TEMP})   CPU: ${CPU_TEMP}°C"
    echo -e "${BOLD}║${NC}  Clocks: ${BOLD}${CLK} MHz${NC} / 3105 MHz   Mem: ${MEM} MHz"
    echo -e "${BOLD}║${NC}  PState: ${BOLD}${PSTATE}${NC}   Util: ${BOLD}${UTIL}%${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    # Thermal limits
    echo -e "${BOLD}║${NC}  ${DIM}Slowdown T.Limit:     ${SLOWDOWN_TLIMIT}  (effective GPS: ~${GPS_EFFECTIVE}°C)${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}Max Operating T.Limit: ${MAX_OP_TLIMIT}${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}SW Thermal Slowdown:   ${SW_THERMAL}  (cumul: ${SW_THERMAL_US:-?} µs)${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}SW Power Cap:          ${SW_POWER}${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"

    # Fans
    echo -e "${BOLD}║${NC}  Fans:   CPU: ${BOLD}${FAN1_RPM} RPM${NC}   GPU: ${BOLD}${FAN2_RPM} RPM${NC}   Duty: ${FAN_PCT}"

    # Goal assessment
    echo -e "${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║${NC}  ${DIM}GOAL: GPU@100% → ~80°C, fans near max, 55-65W draw${NC}"

    local temp_ok=false; local power_ok=false; local fan_ok=false
    [[ "$TEMP" -ge 75 && "$TEMP" -le 85 ]] && temp_ok=true
    [[ "${POWER%.*}" -ge 50 ]] && power_ok=true
    [[ "$FAN1_RPM" -ge 4000 || "$FAN2_RPM" -ge 4000 ]] && fan_ok=true

    local temp_icon=$([[ "$temp_ok" == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}")
    local power_icon=$([[ "$power_ok" == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}")
    local fan_icon=$([[ "$fan_ok" == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}")

    echo -e "${BOLD}║${NC}  ${temp_icon} Temp 75-85°C   ${power_icon} Power ≥50W   ${fan_icon} Fans ≥4000RPM"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}  Ctrl+C to stop  |  Log: ${LOGFILE}  |  CSV: ${CSVLOG}${NC}"
}

# ─── CSV log ─────────────────────────────────────────────────────────────────
log_csv() {
    echo "$(date '+%H:%M:%S'),${POWER},${TEMP},${CLK},${MEM},${UTIL},${PSTATE},${ENFORCED},${SLOWDOWN_TLIMIT},${MAX_OP_TLIMIT},${FAN1_RPM},${FAN2_RPM},${FAN_PCT}" >> "$CSVLOG"
}

# ─── Main loop ───────────────────────────────────────────────────────────────
INTERVAL="${1:-3}"

trap 'echo -e "\n${YELLOW}Ralph loop stopped.${NC} CSV data in: ${CSVLOG}"; exit 0' INT TERM

log "=== Ralph loop started (interval: ${INTERVAL}s) ==="

while true; do
    read_gpu
    read_fans
    calc_gps_limit
    assess
    display
    log_csv
    log "pwr=${POWER}W temp=${TEMP}°C clk=${CLK}MHz util=${UTIL}% pstate=${PSTATE} gps_eff=${GPS_EFFECTIVE}°C fans=${FAN1_RPM}/${FAN2_RPM}"
    sleep "$INTERVAL"
done
