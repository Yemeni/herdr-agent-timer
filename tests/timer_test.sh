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
    'exit 1' \
    >"$mock_bin/herdr"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    >"$mock_bin/jq"

chmod +x "$mock_bin/systemctl" "$mock_bin/herdr" "$mock_bin/jq"

socket="$test_root/herdr.sock"
state_dir="$test_root/state"
config_dir="$test_root/config"
systemctl_log="$test_root/systemctl.log"
touch "$systemctl_log"

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

printf 'timer lifecycle tests passed\n'
