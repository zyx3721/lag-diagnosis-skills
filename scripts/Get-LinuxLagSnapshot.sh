#!/usr/bin/env bash

# Read-only Linux performance snapshot. It relies on procfs and common base tools.

set -u

SAMPLE_SECONDS=3
TOP=12
JSON_PATH=""
EVENT_LOOKBACK_HOURS=2
TEMP_DIR=""
PROBE_ERRORS=""
PROBE_RESULT=""

usage() {
    cat <<'EOF'
Usage: Get-LinuxLagSnapshot.sh [options]

Options:
  --sample-seconds N       Sampling window from 1 to 30 seconds (default: 3)
  --top N                  Maximum rows per result category (default: 12)
  --json-path PATH         Write the JSON snapshot to PATH in addition to stdout
  --event-lookback-hours N Look back from 1 to 72 hours in system logs (default: 2)
  --help                   Show this help text
EOF
}

require_integer_in_range() {
    value="$1"; minimum="$2"; maximum="$3"; label="$4"
    case "$value" in
        ''|*[!0-9]*) printf '%s must be an integer.\n' "$label" >&2; exit 2 ;;
    esac
    if [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
        printf '%s must be between %s and %s.\n' "$label" "$minimum" "$maximum" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sample-seconds) [ "$#" -ge 2 ] || exit 2; SAMPLE_SECONDS="$2"; shift 2 ;;
        --top) [ "$#" -ge 2 ] || exit 2; TOP="$2"; shift 2 ;;
        --json-path) [ "$#" -ge 2 ] || exit 2; JSON_PATH="$2"; shift 2 ;;
        --event-lookback-hours) [ "$#" -ge 2 ] || exit 2; EVENT_LOOKBACK_HOURS="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

require_integer_in_range "$SAMPLE_SECONDS" 1 30 '--sample-seconds'
require_integer_in_range "$TOP" 1 50 '--top'
require_integer_in_range "$EVENT_LOOKBACK_HOURS" 1 72 '--event-lookback-hours'

if [ "$(uname -s)" != 'Linux' ]; then
    printf 'This collector only runs on Linux.\n' >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/linux-lag-snapshot.XXXXXX")" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

json_quote() {
    value=$(printf '%s' "$1" | tr '\r\n' ' ')
    printf '"'; printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g'; printf '"'
}

json_number_or_null() {
    case "$1" in ''|*[!0-9.-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac
}

append_probe_error() {
    name="$1"; message="$2"
    [ -n "$PROBE_ERRORS" ] && PROBE_ERRORS="$PROBE_ERRORS,"
    PROBE_ERRORS="$PROBE_ERRORS{\"name\":$(json_quote "$name"),\"message\":$(json_quote "$message")}"
}

run_probe() {
    name="$1"; shift; error_file="$TEMP_DIR/$name.error"
    PROBE_RESULT=$("$@" 2>"$error_file")
    status=$?
    if [ "$status" -ne 0 ]; then
        error_message=$(tr '\r\n' ' ' < "$error_file" | cut -c1-500)
        [ -n "$error_message" ] || error_message="Command exited with status $status."
        append_probe_error "$name" "$error_message"
        PROBE_RESULT=""
    fi
    rm -f "$error_file"
}

get_cpu_ticks() {
    awk '/^cpu / { total = 0; for (i = 2; i <= NF; i++) total += $i; print total "|" ($5 + $6); exit }' /proc/stat
}

calculate_cpu_percent() {
    awk -F'|' -v before="$1" -v after="$2" 'BEGIN {
        split(before, b, /\|/); split(after, a, /\|/)
        total = a[1] - b[1]; idle = a[2] - b[2]
        if (total > 0) printf "%.1f", ((total - idle) / total) * 100
    }'
}

get_system_summary() {
    os_name=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    [ -n "$os_name" ] || os_name=$(uname -s)
    kernel=$(uname -r)
    model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || uname -m)
    processors=$(getconf _NPROCESSORS_ONLN)
    uptime_seconds=$(awk '{print $1; exit}' /proc/uptime)
    memory_kib=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
    printf '%s|%s|%s|%s|%s|%s' "$os_name" "$kernel" "$model" "$processors" "$uptime_seconds" "$memory_kib"
}

meminfo_value() {
    awk -v key="$1" '$1 == key ":" { print $2; exit }' /proc/meminfo
}

get_memory_summary() {
    available=$(meminfo_value MemAvailable); total=$(meminfo_value MemTotal)
    active=$(meminfo_value Active); inactive=$(meminfo_value Inactive)
    swap_total=$(meminfo_value SwapTotal); swap_free=$(meminfo_value SwapFree)
    available=${available:-0}; total=${total:-0}; active=${active:-0}; inactive=${inactive:-0}
    swap_total=${swap_total:-0}; swap_free=${swap_free:-0}
    awk -v available="$available" -v total="$total" -v active="$active" -v inactive="$inactive" -v swap_total="$swap_total" -v swap_free="$swap_free" 'BEGIN {
        used_percent = total > 0 ? ((total - available) / total) * 100 : 0
        printf "%.1f|%.1f|%.1f|%.1f|%.1f", available / 1024, used_percent, active / 1024, inactive / 1024, (swap_total - swap_free) / 1024
    }'
}

get_load_summary() {
    awk '{ split($4, tasks, "/"); printf "%s|%s|%s", $1, tasks[1], tasks[2] }' /proc/loadavg
}

get_volume_rows() {
    df -Pk -x tmpfs -x devtmpfs | awk 'NR > 1 && $2 > 0 { printf "%s|%.1f|%.1f|%.1f\n", $6, $2 / 1048576, $4 / 1048576, ($4 / $2) * 100 }'
}

get_disk_counters() {
    awk 'NF >= 14 && $3 !~ /^(loop|ram|fd|sr)/ { print $3 "|" $6 "|" $10 "|" $12 }' /proc/diskstats
}

get_network_counters() {
    awk -F: 'NR > 2 { gsub(/^[[:space:]]+/, "", $1); split($2, f, /[[:space:]]+/); if ($1 != "lo") print $1 "|" f[1] "|" f[9] }' /proc/net/dev
}

get_process_rows() {
    sort_field="$1"
    ps -eo pid=,comm=,%cpu=,rss=,etime= --sort="-$sort_field" | head -n "$TOP" |
        awk '{ printf "%s|%s|%s|%.1f|%s\n", $1, $2, $3, $4 / 1024, $5 }'
}

get_service_labels() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --no-legend --type=service --state=running 2>/dev/null | awk '{ print $1 }' | head -n "$TOP"
    else
        printf 'init:%s\n' "$(cat /proc/1/comm)"
    fi
}

get_recent_events() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --no-pager --since "${EVENT_LOOKBACK_HOURS} hours ago" -p warning -n "$TOP"
    else
        dmesg --level=err,warn | tail -n "$TOP"
    fi
}

build_volumes_json() {
    rows="$1"; first=1; printf '['
    while IFS='|' read -r mount size free percent; do
        [ -n "$mount" ] || continue; [ "$first" -eq 1 ] || printf ','; first=0
        printf '{"mountPoint":%s,"sizeGiB":%s,"freeGiB":%s,"freePercent":%s}' "$(json_quote "$mount")" "$(json_number_or_null "$size")" "$(json_number_or_null "$free")" "$(json_number_or_null "$percent")"
    done <<EOF
$rows
EOF
    printf ']'
}

build_processes_json() {
    rows="$1"; first=1; printf '['
    while IFS='|' read -r pid command cpu rss elapsed; do
        [ -n "$pid" ] || continue; [ "$first" -eq 1 ] || printf ','; first=0
        printf '{"processName":%s,"processId":%s,"cpuPercent":%s,"workingSetMiB":%s,"privateMemoryMiB":null,"elapsedTime":%s}' "$(json_quote "$command")" "$(json_number_or_null "$pid")" "$(json_number_or_null "$cpu")" "$(json_number_or_null "$rss")" "$(json_quote "$elapsed")"
    done <<EOF
$rows
EOF
    printf ']'
}

build_delta_json() {
    before_rows="$1"; after_rows="$2"; kind="$3"; first=1; printf '['
    while IFS='|' read -r name first_value second_value fourth_value; do
        [ -n "$name" ] || continue
        before=$(printf '%s\n' "$before_rows" | awk -F'|' -v name="$name" '$1 == name { print; exit }')
        before_first=$(printf '%s' "$before" | awk -F'|' '{print $2}')
        before_second=$(printf '%s' "$before" | awk -F'|' '{print $3}')
        [ -n "$before_first" ] || before_first="$first_value"
        [ -n "$before_second" ] || before_second="$second_value"
        if [ "$kind" = 'disk' ]; then
            read_rate=$(awk -v current="$first_value" -v previous="$before_first" -v seconds="$SAMPLE_SECONDS" 'BEGIN { value=(current-previous)*512/seconds; if(value<0)value=0; printf "%.0f", value }')
            write_rate=$(awk -v current="$second_value" -v previous="$before_second" -v seconds="$SAMPLE_SECONDS" 'BEGIN { value=(current-previous)*512/seconds; if(value<0)value=0; printf "%.0f", value }')
            object=$(printf '{"name":%s,"readBytesPerSec":%s,"writeBytesPerSec":%s,"ioInProgress":%s}' "$(json_quote "$name")" "$(json_number_or_null "$read_rate")" "$(json_number_or_null "$write_rate")" "$(json_number_or_null "$fourth_value")")
        else
            rate=$(awk -v current_in="$first_value" -v current_out="$second_value" -v previous_in="$before_first" -v previous_out="$before_second" -v seconds="$SAMPLE_SECONDS" 'BEGIN { value=((current_in-previous_in)+(current_out-previous_out))/seconds; if(value<0)value=0; printf "%.0f", value }')
            object=$(printf '{"name":%s,"bytesTotalPerSec":%s}' "$(json_quote "$name")" "$(json_number_or_null "$rate")")
        fi
        [ "$first" -eq 1 ] || printf ','; first=0; printf '%s' "$object"
    done <<EOF
$after_rows
EOF
    printf ']'
}

build_labels_json() {
    rows="$1"; property="$2"; first=1; printf '['
    while IFS= read -r row; do
        [ -n "$row" ] || continue; [ "$first" -eq 1 ] || printf ','; first=0
        printf '{"%s":%s}' "$property" "$(json_quote "$row")"
    done <<EOF
$rows
EOF
    printf ']'
}

run_probe cpuTicksBefore get_cpu_ticks; cpu_before="$PROBE_RESULT"
run_probe diskCountersBefore get_disk_counters; disks_before="$PROBE_RESULT"
run_probe networkCountersBefore get_network_counters; network_before="$PROBE_RESULT"
sleep "$SAMPLE_SECONDS"
run_probe cpuTicksAfter get_cpu_ticks; cpu_after="$PROBE_RESULT"
run_probe diskCountersAfter get_disk_counters; disks_after="$PROBE_RESULT"
run_probe networkCountersAfter get_network_counters; network_after="$PROBE_RESULT"
run_probe system get_system_summary; system_summary="$PROBE_RESULT"
run_probe memory get_memory_summary; memory_summary="$PROBE_RESULT"
run_probe systemLoad get_load_summary; load_summary="$PROBE_RESULT"
run_probe volumes get_volume_rows; volume_rows="$PROBE_RESULT"
run_probe processesByCpu get_process_rows '%cpu'; processes_cpu="$PROBE_RESULT"
run_probe processesByMemory get_process_rows rss; processes_memory="$PROBE_RESULT"
run_probe services get_service_labels; services="$PROBE_RESULT"
run_probe recentEvents get_recent_events; events="$PROBE_RESULT"

cpu_percent=$(calculate_cpu_percent "$cpu_before" "$cpu_after")
IFS='|' read -r os_name kernel model processors uptime_seconds memory_kib <<EOF
$system_summary
EOF
IFS='|' read -r available_mib memory_used_percent active_mib inactive_mib swap_used_mib <<EOF
$memory_summary
EOF
IFS='|' read -r load1 runnable total_tasks <<EOF
$load_summary
EOF
uptime_hours=$(awk -v seconds="$uptime_seconds" 'BEGIN { if (seconds > 0) printf "%.1f", seconds / 3600 }')
memory_total_mib=$(awk -v kib="$memory_kib" 'BEGIN { if (kib > 0) printf "%.1f", kib / 1024 }')

json=$(printf '{"schemaVersion":1,"platform":"Linux","generatedAt":%s,"sampleSeconds":%s,"system":{"operatingSystem":{"caption":%s,"version":%s},"computer":{"model":%s,"totalPhysicalMemoryMiB":%s},"logicalProcessorCount":%s,"uptimeHours":%s},"cpu":{"percentProcessorTime":%s},"memory":{"availableMiB":%s,"percentUsed":%s,"activeMiB":%s,"inactiveMiB":%s,"swapUsedMiB":%s},"systemLoad":{"load1":%s,"processorQueueLength":%s,"taskCount":%s},"volumes":%s,"disks":%s,"network":%s,"topProcessesByCpu":%s,"topProcessesByMemory":%s,"services":%s,"recentEvents":%s,"probeErrors":[%s]}' \
    "$(json_quote "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" "$(json_number_or_null "$SAMPLE_SECONDS")" \
    "$(json_quote "$os_name")" "$(json_quote "$kernel")" "$(json_quote "$model")" "$(json_number_or_null "$memory_total_mib")" \
    "$(json_number_or_null "$processors")" "$(json_number_or_null "$uptime_hours")" "$(json_number_or_null "$cpu_percent")" \
    "$(json_number_or_null "$available_mib")" "$(json_number_or_null "$memory_used_percent")" "$(json_number_or_null "$active_mib")" "$(json_number_or_null "$inactive_mib")" "$(json_number_or_null "$swap_used_mib")" \
    "$(json_number_or_null "$load1")" "$(json_number_or_null "$runnable")" "$(json_number_or_null "$total_tasks")" \
    "$(build_volumes_json "$volume_rows")" "$(build_delta_json "$disks_before" "$disks_after" disk)" "$(build_delta_json "$network_before" "$network_after" network)" \
    "$(build_processes_json "$processes_cpu")" "$(build_processes_json "$processes_memory")" "$(build_labels_json "$services" label)" "$(build_labels_json "$events" message)" "$PROBE_ERRORS")

if [ -n "$JSON_PATH" ]; then
    output_directory=$(dirname "$JSON_PATH")
    [ -d "$output_directory" ] || mkdir -p "$output_directory" || exit 1
    printf '%s\n' "$json" > "$JSON_PATH" || exit 1
fi

printf '%s\n' "$json"
