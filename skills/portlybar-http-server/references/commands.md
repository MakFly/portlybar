# HTTP server commands

## PortlyBar interface

```sh
portlybar http-server '<command>' \
  --path '<absolute-directory>' \
  --name '<label>' \
  --min-port 49152 \
  --max-port 65535 \
  --health-path / \
  --startup-timeout 30s \
  --timeout 30m \
  --json
```

Any HTTP response proves readiness by default. Use `--expected-status 200` only when the task requires that exact status. Additional variables use repeated `--env KEY=VALUE` entries.

The JSON payload contains:

```json
{
  "ok": true,
  "data": {
    "job": { "id": "tmp_...", "pid": 1234, "state": "running" },
    "port": 52143,
    "url": "http://127.0.0.1:52143/"
  }
}
```

Stop only the returned job:

```sh
portlybar stop-temp 'tmp_...' --json
```

## Common command shapes

Use these only when they match the project and installed framework:

```sh
# Vite
npm run dev -- --port "$PORT" --host "$HOST"

# Next.js
npm run dev -- --port "$PORT" --hostname "$HOST"

# Python
python3 -m http.server "$PORT" --bind "$HOST"
```

For other frameworks, inspect the existing script or its local help. The final process must listen on `127.0.0.1:$PORT`.
