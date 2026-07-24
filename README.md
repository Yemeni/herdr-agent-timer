# Agent Timer

A Herdr plugin that alternates each agent's status label with its elapsed
time:


<img width="346" height="316" alt="image" src="https://github.com/user-attachments/assets/6f6fbed6-bc66-4df2-a033-df2eb4f44a90" />

```text
working  →  00:03  →  working  →  00:09
completed  →  01:24  →  completed  →  01:24
```

Each phase lasts three seconds. Working timers advance once per second.
Completed timers freeze at the duration of the finished run.

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

On Herdr versions with startup-hook support, the startup hook starts the
timer after every server restart. The pane-created hook provides the same
startup path on older Herdr versions and restarts it if the background
process exits.

## Actions

```bash
herdr plugin action invoke start --plugin yemeni.agent-timer
herdr plugin action invoke stop --plugin yemeni.agent-timer
herdr plugin action invoke toggle --plugin yemeni.agent-timer
```

Requires Bash, `jq`, and `flock`. On Linux with a user systemd instance,
the plugin uses a transient user service; otherwise it falls back to a
detached process.
