# Agent Timer

A Herdr plugin that cycles each agent's label through its status, active agent
time, total run time, and interruption count:

```text
working   →  00:03 agent time  →  00:09 total time  →  2 interruptions
blocked   →  00:03 agent time  →  00:18 total time  →  2 interruptions
completed →  01:24 agent time  →  01:24 total time  →  2 interruptions
```

Each phase lasts three seconds. Agent time advances only while the agent is
working; it pauses while the agent is blocked waiting for input or approval.
Total time includes both working and blocked periods. Completed timers freeze
at the final agent duration, total duration, and interruption count. An
interruption is counted once each time an agent enters the `blocked` state.

## Install

Link this checkout during development:

```bash
herdr plugin link ~/dotfiles/herdr-plugins/agent-timer
herdr plugin action invoke start --plugin yemeni.agent-timer
```

Install the published plugin directly from GitHub:

```bash
herdr plugin install Yemeni/herdr-agent-timer
```

The first start creates and enables a systemd user service. It starts
automatically after login, survives machine reboots, and keeps retrying
while the Herdr server is unavailable. The startup and pane-created hooks
also ensure the service exists after installing or updating the plugin.

## Actions

```bash
herdr plugin action invoke start --plugin yemeni.agent-timer
herdr plugin action invoke stop --plugin yemeni.agent-timer
herdr plugin action invoke toggle --plugin yemeni.agent-timer
```

Requires Bash, `jq`, and `flock`. On Linux with a user systemd instance,
the plugin installs an enabled user service. The **Stop agent timer**
action disables it, and **Start agent timer** enables it again. Without
systemd, the plugin falls back to a detached process and relies on Herdr's
startup hook after reboot.
