#!/usr/bin/env bash

set -euo pipefail

plugin_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
timer="$plugin_root/timer.sh"
test_root="$(mktemp -d)"
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"

cleanup() {
    if [ -n "${unrelated_pid:-}" ]; then
        kill "$unrelated_pid" 2>/dev/null || true
        wait "$unrelated_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show-environment" ]; then' \
    '    exit "${MOCK_SYSTEMD_AVAILABLE:-1}"' \
    'fi' \
    'if [ "${1:-}" = "--user" ] && [ "${2:-}" = "is-active" ]; then' \
    '    exit "${MOCK_SYSTEMD_ACTIVE:-1}"' \
    'fi' \
    'printf "%s\n" "$*" >>"$SYSTEMCTL_LOG"' \
    >"$mock_bin/systemctl"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ]; then' \
    '    status_file="${MOCK_STATUS_FILE:-}"' \
    '    [ -n "$status_file" ] || exit 1' \
    '    status="$(sed -n "${MOCK_LIST_COUNT:-1}p" "$status_file")"' \
    '    [ -n "$status" ] || status="$(tail -n 1 "$status_file")"' \
    '    printf "{\"result\":{\"panes\":[{\"pane_id\":\"w1:p1\",\"agent_status\":\"%s\"}]}}\n" "$status"' \
    '    exit 0' \
    'fi' \
    'if [ "${1:-}" = "pane" ] && [ "${2:-}" = "report-metadata" ]; then' \
    '    printf "%s\n" "$*" >>"$HERDR_LOG"' \
    '    exit 0' \
    'fi' \
    'exit 1' \
    >"$mock_bin/herdr"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'sed -n '\''s/.*"pane_id":"\([^"]*\)".*"agent_status":"\([^"]*\)".*/\1\t\2/p'\''' \
    >"$mock_bin/jq"

chmod +x "$mock_bin/systemctl" "$mock_bin/herdr" "$mock_bin/jq"

socket="$test_root/herdr.sock"
state_dir="$test_root/state"
config_dir="$test_root/config"
systemctl_log="$test_root/systemctl.log"
herdr_log="$test_root/herdr.log"
touch "$systemctl_log"
touch "$herdr_log"

run_timer() {
    env \
        PATH="$mock_bin:/usr/bin:/bin" \
        HERDR_ENV=1 \
        HERDR_SOCKET_PATH="$socket" \
        HERDR_BIN_PATH=herdr \
        HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" \
        XDG_CONFIG_HOME="$config_dir" \
        SYSTEMCTL_LOG="$systemctl_log" \
        HERDR_LOG="$herdr_log" \
        "$@"
}

runtime_key="$(printf '%s' "$socket" | cksum | awk '{print $1}')"
service_name="herdr-agent-timer-$runtime_key"
disabled_file="$state_dir/${service_name}.disabled"
pid_file="$state_dir/${service_name}.pid"

# An explicit stop must survive automatic ensure hooks.
run_timer MOCK_SYSTEMD_AVAILABLE=0 "$timer" --stop
[ -e "$disabled_file" ]
: >"$systemctl_log"
run_timer MOCK_SYSTEMD_AVAILABLE=0 "$timer" --ensure
[ ! -s "$systemctl_log" ]
run_timer MOCK_SYSTEMD_AVAILABLE=0 "$timer" --start
[ ! -e "$disabled_file" ]
grep -q -- '--user enable' "$systemctl_log"

# Toggle must stop a running fallback daemon without systemd.
rm -rf "$config_dir"
run_timer MOCK_SYSTEMD_AVAILABLE=1 "$timer" --daemon &
daemon_pid=$!
for _ in $(seq 1 50); do
    [ -s "$pid_file" ] && break
    sleep 0.02
done
[ -s "$pid_file" ]
run_timer MOCK_SYSTEMD_AVAILABLE=1 "$timer" --toggle
for _ in $(seq 1 50); do
    ! kill -0 "$daemon_pid" 2>/dev/null && break
    sleep 0.02
done
! kill -0 "$daemon_pid" 2>/dev/null
wait "$daemon_pid" 2>/dev/null || true
[ -e "$disabled_file" ]

# A stale record must never kill a process that reused the PID.
sleep 30 &
unrelated_pid=$!
mkdir -p "$state_dir"
printf '%s 0\n' "$unrelated_pid" >"$pid_file"
run_timer MOCK_SYSTEMD_AVAILABLE=1 "$timer" --stop
kill -0 "$unrelated_pid"
[ ! -e "$pid_file" ]

# Herdr 0.8 reports approval and input waits as blocked. They remain part of
# the active run and must receive a label instead of clearing the timer.
status_file="$test_root/statuses"
printf 'blocked\n' >"$status_file"
socket="$test_root/herdr-blocked.sock"
state_dir="$test_root/blocked-state"
run_timer \
    MOCK_SYSTEMD_AVAILABLE=1 \
    MOCK_STATUS_FILE="$status_file" \
    "$timer" --daemon &
daemon_pid=$!
for _ in $(seq 1 50); do
    grep -q -- '--state-label blocked=blocked' "$herdr_log" && break
    sleep 0.02
done
grep -q -- '--state-label blocked=blocked' "$herdr_log"
kill "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true

# Zero-duration completed states keep their semantic label instead of cycling
# to a meaningless 00:00 after the first display phase.
: >"$herdr_log"
printf 'idle\n' >"$status_file"
socket="$test_root/herdr-idle.sock"
state_dir="$test_root/idle-state"
run_timer \
    MOCK_SYSTEMD_AVAILABLE=1 \
    MOCK_STATUS_FILE="$status_file" \
    "$timer" --daemon &
daemon_pid=$!
sleep 4
grep -q -- '--state-label idle=completed' "$herdr_log"
! grep -q -- '--state-label idle=00:00' "$herdr_log"
kill "$daemon_pid"
wait "$daemon_pid" 2>/dev/null || true

printf 'timer lifecycle tests passed\n'
