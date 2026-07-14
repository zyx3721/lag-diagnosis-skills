#!/bin/bash

# Compatible with the Bash 3.2 bundled with macOS. The script only reads system state
# unless --json-path is supplied, in which case it writes the requested report file.

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
Usage: Get-MacOSLagSnapshot.sh [options]

Options:
  --sample-seconds N       Sampling window from 1 to 30 seconds (default: 3)
  --top N                  Maximum processes, interfaces, services, and events (default: 12)
  --json-path PATH         Write the JSON snapshot to PATH instead of stdout only
  --event-lookback-hours N Look back from 1 to 72 hours in the unified log (default: 2)
  --help                   Show this help text
EOF
}

require_integer_in_range() {
    value="$1"
    minimum="$2"
    maximum="$3"
    label="$4"

    case "$value" in
        ''|*[!0-9]*)
            printf '%s must be an integer.\n' "$label" >&2
            exit 2
            ;;
    esac

    if [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
        printf '%s must be between %s and %s.\n' "$label" "$minimum" "$maximum" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sample-seconds)
            [ "$#" -ge 2 ] || { printf '%s requires a value.\n' "$1" >&2; exit 2; }
            SAMPLE_SECONDS="$2"
            shift 2
            ;;
        --top)
            [ "$#" -ge 2 ] || { printf '%s requires a value.\n' "$1" >&2; exit 2; }
            TOP="$2"
            shift 2
            ;;
        --json-path)
            [ "$#" -ge 2 ] || { printf '%s requires a value.\n' "$1" >&2; exit 2; }
            JSON_PATH="$2"
            shift 2
            ;;
        --event-lookback-hours)
            [ "$#" -ge 2 ] || { printf '%s requires a value.\n' "$1" >&2; exit 2; }
            EVENT_LOOKBACK_HOURS="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

require_integer_in_range "$SAMPLE_SECONDS" 1 30 '--sample-seconds'
require_integer_in_range "$TOP" 1 50 '--top'
require_integer_in_range "$EVENT_LOOKBACK_HOURS" 1 72 '--event-lookback-hours'

if [ "$(uname -s)" != 'Darwin' ]; then
    printf 'This collector only runs on macOS.\n' >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macos-lag-snapshot.XXXXXX")" || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

json_quote() {
    value=$(printf '%s' "$1" | tr '\r\n' ' ')
    printf '"'
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g'
    printf '"'
}

json_number_or_null() {
    case "$1" in
        ''|*[!0-9.-]*) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}

append_probe_error() {
    name="$1"
    message="$2"
    [ -n "$PROBE_ERRORS" ] && PROBE_ERRORS="$PROBE_ERRORS,"
    PROBE_ERRORS="$PROBE_ERRORS{\"name\":$(json_quote "$name"),\"message\":$(json_quote "$message")}"
}

run_probe() {
    name="$1"
    shift
    error_file="$TEMP_DIR/$name.error"
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
    sysctl -n kern.cp_time | awk '{ total = 0; for (i = 1; i <= NF; i++) total += $i; print total "|" $4 }'
}

calculate_cpu_percent() {
    awk -F'|' -v before="$1" -v after="$2" 'BEGIN {
        split(before, b, /\|/); split(after, a, /\|/)
        total = a[1] - b[1]; idle = a[2] - b[2]
        if (total <= 0) print ""
        else printf "%.1f", ((total - idle) / total) * 100
    }'
}

get_system_summary() {
    product_name=$(sw_vers -productName)
    product_version=$(sw_vers -productVersion)
    build_version=$(sw_vers -buildVersion)
    model=$(sysctl -n hw.model)
    memory_bytes=$(sysctl -n hw.memsize)
    logical_processors=$(sysctl -n hw.ncpu)
    boot_epoch=$(sysctl -n kern.boottime | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
    now_epoch=$(date +%s)
    uptime_hours=$(awk -v now="$now_epoch" -v boot="$boot_epoch" 'BEGIN { if (boot > 0) printf "%.1f", (now - boot) / 3600 }')
    printf '%s|%s|%s|%s|%s|%s|%s' "$product_name" "$product_version" "$build_version" "$model" "$memory_bytes" "$logical_processors" "$uptime_hours"
}

vm_page_count() {
    printf '%s\n' "$1" | awk -F: -v key="$2" '$1 == key { gsub(/[^0-9]/, "", $2); print $2; exit }'
}

get_memory_summary() {
    page_size=$(sysctl -n hw.pagesize)
    vm_output=$(vm_stat)
    free_pages=$(vm_page_count "$vm_output" 'Pages free')
    active_pages=$(vm_page_count "$vm_output" 'Pages active')
    inactive_pages=$(vm_page_count "$vm_output" 'Pages inactive')
    wired_pages=$(vm_page_count "$vm_output" 'Pages wired down')
    compressed_pages=$(vm_page_count "$vm_output" 'Pages occupied by compressor')

    free_pages=${free_pages:-0}
    active_pages=${active_pages:-0}
    inactive_pages=${inactive_pages:-0}
    wired_pages=${wired_pages:-0}
    compressed_pages=${compressed_pages:-0}

    awk -v page_size="$page_size" -v free="$free_pages" -v active="$active_pages" -v inactive="$inactive_pages" -v wired="$wired_pages" -v compressed="$compressed_pages" 'BEGIN {
        printf "%.1f|%.1f|%.1f|%.1f|%.1f", free * page_size / 1048576, active * page_size / 1048576, inactive * page_size / 1048576, wired * page_size / 1048576, compressed * page_size / 1048576
    }'
}

get_volume_rows() {
    df -kP -l | awk 'NR > 1 {
        size = $2; available = $4; capacity = $5
        $1 = $2 = $3 = $4 = $5 = ""
        sub(/^[[:space:]]+/, "")
        mount = $0
        gsub(/%/, "", capacity)
        if (size > 0) printf "%s|%.1f|%.1f|%.1f\n", mount, size / 1048576, available / 1048576, (available / size) * 100
    }'
}

get_process_rows() {
    sort_key="$1"
    ps -Ao pid=,comm=,%cpu=,rss=,etime= | LC_ALL=C sort -k"$sort_key","$sort_key"nr | head -n "$TOP" |
        awk '{ printf "%s|%s|%s|%.1f|%s\n", $1, $2, $3, $4 / 1024, $5 }'
}

get_network_counters() {
    netstat -ibn | awk 'NR > 1 && $1 !~ /^lo/ && $7 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ && !seen[$1]++ { print $1 "|" $7 "|" $10 }'
}

get_service_labels() {
    launchctl list | awk 'NR > 1 && NF >= 3 { print $3 }' | head -n "$TOP"
}

get_recent_events() {
    log_output=$(log show --last "${EVENT_LOOKBACK_HOURS}h" --style compact --predicate 'messageType == error OR messageType == fault') || return $?
    printf '%s\n' "$log_output" | tail -n "$TOP"
}

build_volumes_json() {
    rows="$1"
    first=1
    printf '['
    while IFS='|' read -r mount size free percent; do
        [ -n "$mount" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"mountPoint":%s,"sizeGiB":%s,"freeGiB":%s,"freePercent":%s}' "$(json_quote "$mount")" "$(json_number_or_null "$size")" "$(json_number_or_null "$free")" "$(json_number_or_null "$percent")"
    done <<EOF
$rows
EOF
    printf ']'
}

build_processes_json() {
    rows="$1"
    first=1
    printf '['
    while IFS='|' read -r pid command cpu rss elapsed; do
        [ -n "$pid" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"processName":%s,"processId":%s,"cpuPercent":%s,"workingSetMiB":%s,"privateMemoryMiB":null,"elapsedTime":%s}' "$(json_quote "$command")" "$(json_number_or_null "$pid")" "$(json_number_or_null "$cpu")" "$(json_number_or_null "$rss")" "$(json_quote "$elapsed")"
    done <<EOF
$rows
EOF
    printf ']'
}

build_network_json() {
    before_rows="$1"
    after_rows="$2"
    first=1
    printf '['
    while IFS='|' read -r interface in_bytes out_bytes; do
        [ -n "$interface" ] || continue
        before=$(printf '%s\n' "$before_rows" | awk -F'|' -v interface="$interface" '$1 == interface { print $2 "|" $3; exit }')
        before_in=${before%%|*}
        before_out=${before#*|}
        [ "$before" = "$before_in" ] && before_in="$in_bytes" && before_out="$out_bytes"
        bytes_per_second=$(awk -v current_in="$in_bytes" -v current_out="$out_bytes" -v previous_in="$before_in" -v previous_out="$before_out" -v seconds="$SAMPLE_SECONDS" 'BEGIN {
            delta = (current_in - previous_in) + (current_out - previous_out)
            if (delta < 0) delta = 0
            if (seconds > 0) printf "%.0f", delta / seconds
        }')
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"name":%s,"bytesTotalPerSec":%s}' "$(json_quote "$interface")" "$(json_number_or_null "$bytes_per_second")"
    done <<EOF
$after_rows
EOF
    printf ']'
}

build_services_json() {
    labels="$1"
    first=1
    printf '['
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"label":%s}' "$(json_quote "$label")"
    done <<EOF
$labels
EOF
    printf ']'
}

build_events_json() {
    events="$1"
    first=1
    printf '['
    while IFS= read -r event; do
        [ -n "$event" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"message":%s}' "$(json_quote "$event")"
    done <<EOF
$events
EOF
    printf ']'
}

run_probe cpuTicksBefore get_cpu_ticks
cpu_before="$PROBE_RESULT"
run_probe networkCountersBefore get_network_counters
network_before="$PROBE_RESULT"
sleep "$SAMPLE_SECONDS"
run_probe cpuTicksAfter get_cpu_ticks
cpu_after="$PROBE_RESULT"
run_probe networkCountersAfter get_network_counters
network_after="$PROBE_RESULT"

run_probe system get_system_summary
system_summary="$PROBE_RESULT"
run_probe memory get_memory_summary
memory_summary="$PROBE_RESULT"
run_probe volumes get_volume_rows
volume_rows="$PROBE_RESULT"
run_probe processesByCpu get_process_rows 3
process_cpu_rows="$PROBE_RESULT"
run_probe processesByMemory get_process_rows 4
process_memory_rows="$PROBE_RESULT"
run_probe services get_service_labels
service_labels="$PROBE_RESULT"
run_probe recentEvents get_recent_events
recent_events="$PROBE_RESULT"
cpu_percent=$(calculate_cpu_percent "$cpu_before" "$cpu_after")

IFS='|' read -r os_name os_version os_build model memory_bytes logical_processors uptime_hours <<EOF
$system_summary
EOF
IFS='|' read -r free_mib active_mib inactive_mib wired_mib compressed_mib <<EOF
$memory_summary
EOF
total_memory_mib=$(awk -v bytes="$memory_bytes" 'BEGIN { if (bytes > 0) printf "%.1f", bytes / 1048576 }')

json=$(printf '{"schemaVersion":1,"platform":"macOS","generatedAt":%s,"sampleSeconds":%s,"system":{"operatingSystem":{"caption":%s,"version":%s,"buildNumber":%s},"computer":{"manufacturer":"Apple","model":%s,"totalPhysicalMemoryMiB":%s},"logicalProcessorCount":%s,"uptimeHours":%s},"cpu":{"percentProcessorTime":%s},"memory":{"availableMiB":%s,"activeMiB":%s,"inactiveMiB":%s,"wiredMiB":%s,"compressedMiB":%s},"systemLoad":{"processorQueueLength":null},"volumes":%s,"disks":[],"network":%s,"topProcessesByCpu":%s,"topProcessesByMemory":%s,"services":%s,"recentEvents":%s,"probeErrors":[%s]}' \
    "$(json_quote "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
    "$(json_number_or_null "$SAMPLE_SECONDS")" \
    "$(json_quote "$os_name")" "$(json_quote "$os_version")" "$(json_quote "$os_build")" \
    "$(json_quote "$model")" "$(json_number_or_null "$total_memory_mib")" \
    "$(json_number_or_null "$logical_processors")" "$(json_number_or_null "$uptime_hours")" \
    "$(json_number_or_null "$cpu_percent")" \
    "$(json_number_or_null "$free_mib")" "$(json_number_or_null "$active_mib")" "$(json_number_or_null "$inactive_mib")" "$(json_number_or_null "$wired_mib")" "$(json_number_or_null "$compressed_mib")" \
    "$(build_volumes_json "$volume_rows")" "$(build_network_json "$network_before" "$network_after")" \
    "$(build_processes_json "$process_cpu_rows")" "$(build_processes_json "$process_memory_rows")" \
    "$(build_services_json "$service_labels")" "$(build_events_json "$recent_events")" "$PROBE_ERRORS")

if [ -n "$JSON_PATH" ]; then
    output_directory=$(dirname "$JSON_PATH")
    if [ ! -d "$output_directory" ]; then
        mkdir -p "$output_directory" || exit 1
    fi
    printf '%s\n' "$json" > "$JSON_PATH" || exit 1
fi

printf '%s\n' "$json"
