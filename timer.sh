#!/usr/bin/env bash

set -uo pipefail

source_id="plugin:yemeni.agent-timer"
herdr_bin="${HERDR_BIN_PATH:-herdr}"
plugin_root="${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
plugin_state_dir="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}}"
script_path="$plugin_root/timer.sh"

runtime_key() {
    printf '%s' "$HERDR_SOCKET_PATH" | cksum | awk '{print $1}'
}

unit_name() {
    printf 'herdr-agent-timer-%s' "$(runtime_key)"
}

ensure_daemon() {
    local service_name

    [ "${HERDR_ENV:-}" = 1 ] || return 0
    [ -n "${HERDR_SOCKET_PATH:-}" ] || return 0
    command -v "$herdr_bin" >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    service_name="$(unit_name)"

    if command -v systemd-run >/dev/null 2>&1 &&
        systemctl --user is-system-running >/dev/null 2>&1; then
        systemd-run \
            --user \
            --quiet \
            --collect \
            --unit "$service_name" \
            --setenv "HERDR_ENV=1" \
            --setenv "HERDR_SOCKET_PATH=$HERDR_SOCKET_PATH" \
            --setenv "HERDR_BIN_PATH=$herdr_bin" \
            --setenv "HERDR_PLUGIN_ID=${HERDR_PLUGIN_ID:-yemeni.agent-timer}" \
            --setenv "HERDR_PLUGIN_ROOT=$plugin_root" \
            --setenv "HERDR_PLUGIN_STATE_DIR=$plugin_state_dir" \
            --setenv "PATH=$PATH" \
            "$script_path" --daemon \
            >/dev/null 2>&1 || true
        return 0
    fi

    nohup "$script_path" --daemon >/dev/null 2>&1 &
}

stop_daemon() {
    local service_name pid_file pid
    service_name="$(unit_name)"
    pid_file="$plugin_state_dir/${service_name}.pid"

    if systemctl --user is-active "$service_name" >/dev/null 2>&1; then
        systemctl --user stop "$service_name" >/dev/null 2>&1 || true
        return 0
    fi

    if [ -r "$pid_file" ]; then
        IFS= read -r pid <"$pid_file" || true
        case "$pid" in
            ''|*[!0-9]*) return 0 ;;
        esac
        kill "$pid" 2>/dev/null || true
    fi
}

run_daemon() {
    local service_name lock_file pid_file
    service_name="$(unit_name)"
    lock_file="$plugin_state_dir/${service_name}.lock"
    pid_file="$plugin_state_dir/${service_name}.pid"

    exec 9>"$lock_file"
    flock -n 9 || return 0
    printf '%s\n' "$$" >"$pid_file"
    trap 'rm -f "$pid_file"' EXIT

    declare -A started_at=()
    declare -A completed_after=()
    declare -A phase_started_at=()
    declare -A status_family=()
    declare -A last_label=()
    declare -A seen=()

    while true; do
        local panes_json now pane_id status family elapsed phase label
        panes_json="$("$herdr_bin" pane list 2>/dev/null)" || {
            sleep 1
            continue
        }
        now="$(date +%s)"
        seen=()

        while IFS=$'\t' read -r pane_id status; do
            [ -n "$pane_id" ] || continue
            seen["$pane_id"]=1

            case "$status" in
                working)
                    family="working"
                    if [ "${status_family[$pane_id]:-}" != "$family" ]; then
                        started_at["$pane_id"]="$now"
                        phase_started_at["$pane_id"]="$now"
                        unset 'completed_after[$pane_id]'
                    fi
                    elapsed=$((now - ${started_at[$pane_id]}))
                    ;;
                done|idle)
                    family="completed"
                    if [ "${status_family[$pane_id]:-}" = "working" ]; then
                        completed_after["$pane_id"]=$((now - ${started_at[$pane_id]}))
                        phase_started_at["$pane_id"]="$now"
                    elif [ "${status_family[$pane_id]:-}" != "$family" ]; then
                        completed_after["$pane_id"]=0
                        phase_started_at["$pane_id"]="$now"
                    fi
                    elapsed="${completed_after[$pane_id]:-0}"
                    ;;
                *)
                    if [ -n "${last_label[$pane_id]:-}" ]; then
                        "$herdr_bin" pane report-metadata "$pane_id" \
                            --source "$source_id" \
                            --clear-state-labels \
                            --ttl-ms 1000 \
                            >/dev/null 2>&1 || true
                    fi
                    unset 'status_family[$pane_id]' 'last_label[$pane_id]'
                    continue
                    ;;
            esac

            status_family["$pane_id"]="$family"
            phase=$(((now - ${phase_started_at[$pane_id]}) / 3 % 2))
            if [ "$phase" -eq 0 ]; then
                label="$family"
            else
                printf -v label '%02d:%02d' "$((elapsed / 60))" "$((elapsed % 60))"
            fi

            if [ "${last_label[$pane_id]:-}" != "$status:$label" ]; then
                "$herdr_bin" pane report-metadata "$pane_id" \
                    --source "$source_id" \
                    --state-label "$status=$label" \
                    --ttl-ms 5000 \
                    >/dev/null 2>&1 || true
                last_label["$pane_id"]="$status:$label"
            fi
        done < <(
            jq -r '.result.panes[]? | [.pane_id, .agent_status] | @tsv' \
                <<<"$panes_json"
        )

        for pane_id in "${!status_family[@]}"; do
            if [ -z "${seen[$pane_id]:-}" ]; then
                unset \
                    'started_at[$pane_id]' \
                    'completed_after[$pane_id]' \
                    'phase_started_at[$pane_id]' \
                    'status_family[$pane_id]' \
                    'last_label[$pane_id]'
            fi
        done

        sleep 1
    done
}

case "${1:-}" in
    --start|--ensure)
        ensure_daemon
        ;;
    --stop)
        stop_daemon
        ;;
    --toggle)
        if systemctl --user is-active "$(unit_name)" >/dev/null 2>&1; then
            stop_daemon
        else
            ensure_daemon
        fi
        ;;
    --daemon)
        run_daemon
        ;;
    *)
        printf 'usage: %s --start|--stop|--toggle|--daemon\n' "${0##*/}" >&2
        exit 2
        ;;
esac
