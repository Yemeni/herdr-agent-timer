# Agent Timer

A Herdr plugin that alternates each agent's status label with its elapsed
time:

<img width="346" height="316" alt="image" src="https://github.com/user-attachments/assets/6f6fbed6-bc66-4df2-a033-df2eb4f44a90" />

```text
working  →  00:03  →  working  →  00:09
blocked  →  00:12  →  blocked  →  00:18
completed  →  01:24  →  completed  →  01:24
```

Each phase lasts three seconds. Working timers advance once per second and
continue advancing while an agent is blocked waiting for input or approval.
Completed timers freeze at the duration of the finished run. A zero-duration
timer is never displayed; the normal status label remains visible instead.

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
