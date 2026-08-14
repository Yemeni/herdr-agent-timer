#!/usr/bin/env bash

set -uo pipefail

source_id="plugin:yemeni.agent-timer"
autopilot_idle_grace_seconds=10
startup_restore_grace_seconds=60
herdr_bin="${HERDR_BIN_PATH:-herdr}"
plugin_root="${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
default_state_root="${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}"
default_state_root="${default_state_root:-${TMPDIR:-/tmp}/herdr-agent-timer-$UID}"
plugin_state_dir="${HERDR_PLUGIN_STATE_DIR:-$default_state_root/herdr-agent-timer}"
script_path="$plugin_root/timer.sh"

runtime_key() {
    printf '%s' "$HERDR_SOCKET_PATH" | cksum | awk '{print $1}'
}

unit_name() {
    printf 'herdr-agent-timer-%s' "$(runtime_key)"
}

ensure_state_dir() {
    (umask 077 && mkdir -p "$plugin_state_dir")
}

disabled_path() {
    printf '%s/%s.disabled' "$plugin_state_dir" "$(unit_name)"
}

mark_disabled() {
    ensure_state_dir || return 1
    : >"$(disabled_path)"
}

clear_disabled() {
    rm -f "$(disabled_path)"
}

is_disabled() {
    [ -e "$(disabled_path)" ]
}

process_start_time() {
    local stat
    [ -r "/proc/$1/stat" ] || return 1
    IFS= read -r stat <"/proc/$1/stat" || return 1
    stat="${stat##*) }"
    awk '{print $20}' <<<"$stat"
}

fallback_daemon_active() {
    local service_name pid_file pid recorded_start_time current_start_time
    service_name="$(unit_name)"
    pid_file="$plugin_state_dir/${service_name}.pid"

    [ -r "$pid_file" ] || return 1
    read -r pid recorded_start_time <"$pid_file" || return 1
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$recorded_start_time" in
        ''|*[!0-9]*) return 1 ;;
    esac

    current_start_time="$(process_start_time "$pid")" || return 1
    [ "$current_start_time" = "$recorded_start_time" ]
}

daemon_active() {
    local service_name
    service_name="$(unit_name)"

    if command -v systemctl >/dev/null 2>&1 &&
        systemctl --user is-active "$service_name" >/dev/null 2>&1; then
        return 0
    fi

    fallback_daemon_active
}

unit_path() {
    local config_home
    config_home="${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}"
    [ -n "$config_home" ] || return 1
    printf '%s/systemd/user/%s.service' "$config_home" "$(unit_name)"
}

systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '"%s"' "$value"
}

install_service() {
    local service_name service_path service_dir candidate
    service_name="$(unit_name)"
    service_path="$(unit_path)" || return 1
    service_dir="${service_path%/*}"

    mkdir -p "$service_dir"
    candidate="$(mktemp "$service_dir/.${service_name}.XXXXXX")" || return 1
    trap 'rm -f "$candidate"' RETURN

    {
        printf '[Unit]\n'
        printf 'Description=Herdr Agent Timer\n'
        printf 'After=default.target\n\n'
        printf '[Service]\n'
        printf 'Type=simple\n'
        printf 'ExecStart=%s --daemon\n' "$(systemd_quote "$script_path")"
        printf 'Restart=always\n'
        printf 'RestartSec=2\n'
        printf 'Environment=%s\n' "$(systemd_quote "HERDR_ENV=1")"
        printf 'Environment=%s\n' "$(systemd_quote "HERDR_SOCKET_PATH=$HERDR_SOCKET_PATH")"
        printf 'Environment=%s\n' "$(systemd_quote "HERDR_BIN_PATH=$herdr_bin")"
        printf 'Environment=%s\n' \
            "$(systemd_quote "HERDR_PLUGIN_ID=${HERDR_PLUGIN_ID:-yemeni.agent-timer}")"
        printf 'Environment=%s\n' "$(systemd_quote "HERDR_PLUGIN_ROOT=$plugin_root")"
        printf 'Environment=%s\n' "$(systemd_quote "HERDR_PLUGIN_STATE_DIR=$plugin_state_dir")"
        printf 'Environment=%s\n\n' "$(systemd_quote "PATH=$PATH")"
        printf '[Install]\n'
        printf 'WantedBy=default.target\n'
    } >"$candidate"
    chmod 0644 "$candidate"

    if [ -r "$service_path" ] && cmp -s "$candidate" "$service_path"; then
        rm -f "$candidate"
        trap - RETURN
        systemctl --user enable "$service_name" >/dev/null 2>&1 || return 1
        systemctl --user is-active "$service_name" >/dev/null 2>&1 ||
            systemctl --user start "$service_name" >/dev/null 2>&1
        return
    fi

    mv "$candidate" "$service_path"
    trap - RETURN
    systemctl --user daemon-reload >/dev/null 2>&1 || return 1
    systemctl --user enable "$service_name" >/dev/null 2>&1 || return 1
    systemctl --user restart "$service_name" >/dev/null 2>&1
}

ensure_daemon() {
    [ "${HERDR_ENV:-}" = 1 ] || return 0
    [ -n "${HERDR_SOCKET_PATH:-}" ] || return 0
    command -v "$herdr_bin" >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    ensure_state_dir || return 0
    is_disabled && return 0

    if command -v systemctl >/dev/null 2>&1 &&
        systemctl --user show-environment >/dev/null 2>&1; then
        install_service || true
        return
    fi

    nohup "$script_path" --daemon >/dev/null 2>&1 &
}

start_daemon() {
    ensure_state_dir || return 0
    clear_disabled
    ensure_daemon
}

stop_daemon() {
    local service_name service_path pid_file pid
    service_name="$(unit_name)"
    pid_file="$plugin_state_dir/${service_name}.pid"
    mark_disabled || return 0

    if command -v systemctl >/dev/null 2>&1 &&
        service_path="$(unit_path 2>/dev/null)" &&
        [ -e "$service_path" ]; then
        systemctl --user disable --now "$service_name" >/dev/null 2>&1 || true
        return 0
    fi

    if fallback_daemon_active; then
        read -r pid _ <"$pid_file" || true
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
}

run_daemon() {
    local service_name lock_file pid_file start_time state_file state_dirty last_state_save daemon_started_at
    ensure_state_dir || return 0
    service_name="$(unit_name)"
    lock_file="$plugin_state_dir/${service_name}.lock"
    pid_file="$plugin_state_dir/${service_name}.pid"
    state_file="$plugin_state_dir/${service_name}.state"

    exec 9>"$lock_file"
    flock -n 9 || return 0
    start_time="$(process_start_time "$$")" || return 0
    daemon_started_at="$(date +%s)"
    printf '%s %s\n' "$$" "$start_time" >"$pid_file"
    trap 'rm -f "$pid_file"' EXIT

    declare -A started_at=()
    declare -A agent_started_at=()
    declare -A agent_elapsed=()
    declare -A interruptions=()
    declare -A completed_after=()
    declare -A completed_agent_elapsed=()
    declare -A completed_interruptions=()
    declare -A phase_started_at=()
    declare -A status_family=()
    declare -A last_status=()
    declare -A last_label=()
    declare -A seen=()
    declare -A idle_since=()
    declare -A restored=()

    load_state() {
        local pane_id family status saved_at saved_now
        local saved_started_at saved_agent_started_at saved_agent_elapsed
        local saved_interruptions saved_completed_after
        local saved_completed_agent_elapsed saved_completed_interruptions
        local saved_phase_started_at

        [ -r "$state_file" ] || return 0
        saved_now="$(date +%s)"
        while IFS=$'\t' read -r pane_id family status saved_at saved_started_at \
            saved_agent_started_at saved_agent_elapsed saved_interruptions \
            saved_completed_after saved_completed_agent_elapsed \
            saved_completed_interruptions saved_phase_started_at; do
            [ -n "$pane_id" ] || continue
            case "$saved_at:$saved_started_at:$saved_agent_started_at:$saved_agent_elapsed:$saved_interruptions:$saved_completed_after:$saved_completed_agent_elapsed:$saved_completed_interruptions:$saved_phase_started_at" in
                *[!0-9:]*|:*) continue ;;
            esac
            status_family["$pane_id"]="$family"
            last_status["$pane_id"]="$status"
            started_at["$pane_id"]="$saved_started_at"
            agent_started_at["$pane_id"]="$saved_agent_started_at"
            agent_elapsed["$pane_id"]="$saved_agent_elapsed"
            interruptions["$pane_id"]="$saved_interruptions"
            completed_after["$pane_id"]="$saved_completed_after"
            completed_agent_elapsed["$pane_id"]="$saved_completed_agent_elapsed"
            completed_interruptions["$pane_id"]="$saved_completed_interruptions"
            phase_started_at["$pane_id"]="$saved_phase_started_at"
            restored["$pane_id"]=1
            if [ "$family" = "working" ] && [ "$status" = "working" ]; then
                agent_started_at["$pane_id"]="$saved_now"
            fi
        done <"$state_file"
    }

    save_state() {
        local state_tmp pane_id
        state_tmp="$(mktemp "$state_file.XXXXXX")" || return 1
        chmod 0600 "$state_tmp" || {
            rm -f "$state_tmp"
            return 1
        }
        for pane_id in "${!status_family[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$pane_id" \
                "${status_family[$pane_id]}" \
                "${last_status[$pane_id]:-}" \
                "$(date +%s)" \
                "${started_at[$pane_id]:-0}" \
                "${agent_started_at[$pane_id]:-0}" \
                "${agent_elapsed[$pane_id]:-0}" \
                "${interruptions[$pane_id]:-0}" \
                "${completed_after[$pane_id]:-0}" \
                "${completed_agent_elapsed[$pane_id]:-0}" \
                "${completed_interruptions[$pane_id]:-0}" \
                "${phase_started_at[$pane_id]:-0}" \
                >>"$state_tmp" || {
                    rm -f "$state_tmp"
                    return 1
                }
        done
        mv -f "$state_tmp" "$state_file" || {
            rm -f "$state_tmp"
            return 1
        }
    }

    load_state
    state_dirty=0
    last_state_save=0

    while true; do
        local panes_json now pane_id status display_status family elapsed agent_time interruption_count phase label
        local display_count display_phase display_slot grace_active
        panes_json="$("$herdr_bin" pane list 2>/dev/null)" || {
            sleep 1
            continue
        }
        now="$(date +%s)"
        seen=()

        while IFS=$'\t' read -r pane_id status; do
            [ -n "$pane_id" ] || continue
            seen["$pane_id"]=1
            display_status="$status"
            grace_active=0

            case "$status" in
                working|blocked)
                    family="working"
                    unset 'idle_since[$pane_id]'
                    if [ "${status_family[$pane_id]:-}" != "$family" ]; then
                        started_at["$pane_id"]="$now"
                        phase_started_at["$pane_id"]="$now"
                        agent_elapsed["$pane_id"]=0
                        interruptions["$pane_id"]=0
                        unset 'completed_after[$pane_id]'
                        unset 'completed_agent_elapsed[$pane_id]'
                        unset 'completed_interruptions[$pane_id]'
                        state_dirty=1
                    fi
                    if [ "$status" = "working" ] &&
                        [ "${last_status[$pane_id]:-}" != "working" ]; then
                        agent_started_at["$pane_id"]="$now"
                        state_dirty=1
                    elif [ "$status" = "blocked" ] &&
                        [ "${last_status[$pane_id]:-}" = "working" ]; then
                        agent_elapsed["$pane_id"]=$(( ${agent_elapsed[$pane_id]:-0} + now - ${agent_started_at[$pane_id]} ))
                        state_dirty=1
                    fi
                    if [ "$status" = "blocked" ] &&
                        [ "${last_status[$pane_id]:-}" != "blocked" ]; then
                        interruptions["$pane_id"]=$(( ${interruptions[$pane_id]:-0} + 1 ))
                        state_dirty=1
                    fi
                    elapsed=$((now - ${started_at[$pane_id]}))
                    if [ "$status" = "working" ]; then
                        agent_time=$(( ${agent_elapsed[$pane_id]:-0} + now - ${agent_started_at[$pane_id]} ))
                    else
                        agent_time="${agent_elapsed[$pane_id]:-0}"
                    fi
                    ;;
                done|idle)
                    family="completed"
                    if [ "$status" = "idle" ] &&
                        [ "${status_family[$pane_id]:-}" = "working" ]; then
                        if [ -z "${idle_since[$pane_id]:-}" ]; then
                            idle_since["$pane_id"]="$now"
                            if [ "${last_status[$pane_id]:-}" = "working" ]; then
                                agent_elapsed["$pane_id"]=$((
                                    ${agent_elapsed[$pane_id]:-0} + now - ${agent_started_at[$pane_id]}
                                ))
                            fi
                            state_dirty=1
                        fi
                        restore_grace_active=0
                        if [ "${restored[$pane_id]:-0}" -eq 1 ] &&
                            [ $((now - daemon_started_at)) -lt "$startup_restore_grace_seconds" ]; then
                            restore_grace_active=1
                        fi
                        if [ "$restore_grace_active" -eq 1 ] ||
                            [ $((now - idle_since[$pane_id])) -lt "$autopilot_idle_grace_seconds" ]; then
                            family="working"
                            display_status="working"
                            elapsed=$((now - ${started_at[$pane_id]}))
                            agent_time="${agent_elapsed[$pane_id]:-0}"
                            interruption_count="${interruptions[$pane_id]:-0}"
                            grace_active=1
                        fi
                    fi
                    if [ "$grace_active" -eq 0 ] &&
                        [ "${status_family[$pane_id]:-}" = "working" ]; then
                        completed_after["$pane_id"]=$(( now - ${started_at[$pane_id]} ))
                        if [ "${last_status[$pane_id]:-}" = "working" ]; then
                            agent_elapsed["$pane_id"]=$(( ${agent_elapsed[$pane_id]:-0} + now - ${agent_started_at[$pane_id]} ))
                        fi
                        completed_agent_elapsed["$pane_id"]="${agent_elapsed[$pane_id]:-0}"
                        completed_interruptions["$pane_id"]="${interruptions[$pane_id]:-0}"
                        phase_started_at["$pane_id"]="$now"
                        state_dirty=1
                    elif [ "$grace_active" -eq 0 ] &&
                        [ "${status_family[$pane_id]:-}" != "$family" ]; then
                        completed_after["$pane_id"]=0
                        completed_agent_elapsed["$pane_id"]=0
                        completed_interruptions["$pane_id"]=0
                        phase_started_at["$pane_id"]="$now"
                        state_dirty=1
                    fi
                    if [ "$grace_active" -eq 0 ]; then
                        elapsed="${completed_after[$pane_id]:-0}"
                        agent_time="${completed_agent_elapsed[$pane_id]:-0}"
                        interruption_count="${completed_interruptions[$pane_id]:-0}"
                    fi
                    unset 'restored[$pane_id]'
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
            last_status["$pane_id"]="$status"
            if [ "$family" = "working" ]; then
                interruption_count="${interruptions[$pane_id]:-0}"
            fi
            display_count=1
            [ "$agent_time" -gt 0 ] && display_count=$((display_count + 1))
            [ "$elapsed" -gt 0 ] && display_count=$((display_count + 1))
            [ "$interruption_count" -gt 0 ] && display_count=$((display_count + 1))
            display_phase=$(((now - ${phase_started_at[$pane_id]}) / 3 % display_count))
            label=""

            if [ "$display_phase" -eq 0 ]; then
                if [ "$family" = "working" ]; then
                    label="$display_status"
                else
                    label="$family"
                fi
            else
                display_slot=1
                if [ "$agent_time" -gt 0 ]; then
                    if [ "$display_phase" -eq "$display_slot" ]; then
                        printf -v label '%02d:%02d agent time' "$((agent_time / 60))" "$((agent_time % 60))"
                    else
                        display_slot=$((display_slot + 1))
                    fi
                fi
                if [ -z "${label:-}" ] && [ "$elapsed" -gt 0 ]; then
                    if [ "$display_phase" -eq "$display_slot" ]; then
                        printf -v label '%02d:%02d total time' "$((elapsed / 60))" "$((elapsed % 60))"
                    else
                        display_slot=$((display_slot + 1))
                    fi
                fi
                if [ -z "${label:-}" ] && [ "$interruption_count" -gt 0 ]; then
                    label="$interruption_count interruptions"
                fi
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
                    'agent_started_at[$pane_id]' \
                    'agent_elapsed[$pane_id]' \
                    'interruptions[$pane_id]' \
                    'completed_after[$pane_id]' \
                    'completed_agent_elapsed[$pane_id]' \
                    'completed_interruptions[$pane_id]' \
                    'phase_started_at[$pane_id]' \
                    'status_family[$pane_id]' \
                    'last_status[$pane_id]' \
                    'last_label[$pane_id]'
            fi
        done

        if [ "$state_dirty" -eq 1 ] || [ $((now - last_state_save)) -ge 5 ]; then
            for pane_id in "${!status_family[@]}"; do
                if [ "${status_family[$pane_id]}" = "working" ] &&
                    [ "${last_status[$pane_id]:-}" = "working" ]; then
                    agent_elapsed["$pane_id"]=$((
                        ${agent_elapsed[$pane_id]:-0} + now - ${agent_started_at[$pane_id]}
                    ))
                    agent_started_at["$pane_id"]="$now"
                fi
            done
            if save_state; then
                state_dirty=0
                last_state_save="$now"
            fi
        fi

        sleep 1
    done
}

case "${1:-}" in
    --start)
        start_daemon
        ;;
    --ensure)
        ensure_daemon
        ;;
    --stop)
        stop_daemon
        ;;
    --toggle)
        if daemon_active; then
            stop_daemon
        else
            start_daemon
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
