---
name: portlybar
description: Manage existing PortlyBar projects, supervised processes, ports, logs, health, Docker visibility, and resource limits through the macOS app and `portlybar` CLI. Use when an agent needs to inspect, stop, restart, reuse, configure, or safely take over existing local infrastructure. Do not use to launch a new temporary HTTP development or preview server; use `portlybar-http-server` for that workflow.
---

# PortlyBar

Use PortlyBar as the single source of truth for local development processes. Keep reusable servers supervised instead of starting duplicate background commands from a shell.

## Workflow

1. Verify the CLI with `command -v portlybar`; report a clear installation error if it is absent.
2. Run `portlybar status`. Add `--details` only when the full configured inventory is needed and `--json` for machine-readable state.
3. Reuse a healthy managed server. Do not start a second copy because another port is available.
4. For persistent work, register the project and server, then start its `project/server` selector.
5. For a bounded non-HTTP build, test, or generated artifact, use `portlybar temp` followed by `portlybar wait`. Use `portlybar-http-server` for a new temporary HTTP server.
6. Inspect logs and health before changing configuration or restarting a failed service.

Read [references/cli.md](references/cli.md) when exact commands or flags are needed.

## Safety

- Never terminate an external listener without explicit user approval.
- Before takeover, run `portlybar port <port> --json` and report the command, PID, user, and working directory.
- Use `take-over --confirm` only after approval. PortlyBar revalidates ownership before sending SIGTERM.
- Use `kill-port --expected-pid <pid> --confirm` only for an explicitly approved external target.
- Never add `--force` unless the user separately approves SIGKILL after SIGTERM failed.
- Do not remove projects or servers while they are running.
- Do not edit `~/.config/portlybar/config.json` concurrently with an API or CLI mutation.

## Completion

Verify the resulting state with `portlybar status --json`. For an HTTP server, confirm the configured health state rather than treating a live PID as success. Report any command exit code, timeout, port conflict, or permission error directly.
