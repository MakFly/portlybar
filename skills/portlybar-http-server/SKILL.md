---
name: portlybar-http-server
description: Launch a new local HTTP development or preview server under PortlyBar supervision on an automatically selected free loopback port. Use only when a coding harness is about to start an HTTP server for development, browser checks, UI previews, or local API verification. Do not use for inspecting an existing server, managing Docker, reading logs, resolving a port conflict, running a non-HTTP command, or general PortlyBar administration.
---

# PortlyBar HTTP Server

Launch new HTTP servers through PortlyBar instead of choosing a fixed port or starting an unmanaged background process.

## Start

1. Inspect the project to identify the existing server command. Do not install packages or invent a replacement server.
2. Ensure the command reads `PORT` and binds to `HOST`. Add the framework's existing CLI flags inside the supervised command when required.
3. Run `portlybar http-server '<command>' --path '<absolute-project-path>' --json`.
4. Parse `data.url` and `data.job.id`. Do not report readiness before this command succeeds.
5. Use the returned loopback URL for the current task.

The supervised shell receives `PORT`, `HOST=127.0.0.1`, `PORTLYBAR=1`, and `PORTLYBAR_SERVER`. Keep `$PORT` and `$HOST` quoted so the supervised shell expands them, for example:

```sh
portlybar http-server 'npm run dev -- --port "$PORT" --host "$HOST"' \
  --path '/absolute/project' --json
```

Read [references/commands.md](references/commands.md) for the exact options and common framework command shapes.

## Stop

When the HTTP-dependent work is complete, run:

```sh
portlybar stop-temp '<job-id>' --json
```

Confirm that the response contains no running PID. If the harness exits unexpectedly, PortlyBar enforces the default 30-minute lifetime.

## Failures

- Surface PortlyBar's error and recent server output verbatim enough to identify the failing command.
- Do not fall back to `&`, `nohup`, a fixed port, or terminating another listener.
- If the command ignores `PORT`, correct its supported arguments and retry; do not claim the chosen port was honored.
- Never terminate an external process or take over its port from this skill.
