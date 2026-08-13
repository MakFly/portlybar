# PortlyBar CLI reference

## Persistent servers

```sh
portlybar status
portlybar status --details
portlybar status --json
portlybar add-project --name demo --path /absolute/path --json
portlybar add-server --project demo --name web --command 'npm run dev' --port 3000 --start --json
portlybar start demo/web --json
portlybar stop demo/web --json
portlybar restart demo/web --json
portlybar logs demo/web --tail 200
```

Use `--project` with start, stop, or restart to act on every server in a project. Use `stop --all` for every supervised process.

## Temporary jobs

```sh
job_id="$(portlybar temp 'npm test' --name tests --path /absolute/path --timeout 20m)"
portlybar wait "$job_id"
```

`wait` returns the process exit code. A timeout returns `124`.

New temporary HTTP servers belong to the dedicated `portlybar-http-server` skill:

```sh
portlybar http-server 'npm run dev -- --port "$PORT" --host "$HOST"' --path /absolute/path --json
portlybar stop-temp tmp_example --json
```

## Ports and takeover

```sh
portlybar port 3000 --json
portlybar take-over demo/web --confirm --json
portlybar kill-port 3000 --expected-pid 12345 --confirm --json
portlybar kill-port 3000 --expected-pid 12345 --confirm --force --json
```

Treat `--confirm` and `--force` as approval gates, not convenience flags.

## Configuration and lifecycle

```sh
portlybar memory-limit 5GB
portlybar memory-limit inherit --project demo
portlybar memory-limit off --project demo
portlybar config
portlybar open
portlybar forever enable --app-path /Applications/PortlyBar.app
portlybar forever status
portlybar forever disable --confirm
portlybar quit --confirm
```

The control API listens only on `127.0.0.1:7738`. Persistent configuration is stored in `~/.config/portlybar/config.json` and logs in `~/.config/portlybar/logs/`.
