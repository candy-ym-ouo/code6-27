#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORKSPACE"

if [[ "$WORKSPACE" == *"Code6-27-B"* ]]; then
  VARIANT="b"
else
  VARIANT="a"
fi

STATE_DIR="${HOME}/.cache/code6-27-${VARIANT}"
mkdir -p "$STATE_DIR"
printf '' > "$STATE_DIR/api-url"
printf '' > "$STATE_DIR/web-url"
unlink "$STATE_DIR/data.json" 2>/dev/null || true
: > "$STATE_DIR/api.log"

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 22 )); then
  echo "Node.js 22+ is required for this recording harness." >&2
  exit 1
fi

if [[ ! -x "$WORKSPACE/node_modules/.bin/tsx" || ! -x "$WORKSPACE/node_modules/.bin/vite" ]]; then
  if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
    echo "Dependencies are missing and SKIP_INSTALL=1 was set." >&2
    exit 1
  fi
  npm install --no-audit --no-fund
fi

echo "[start-local] building workspace" >&2
npm run build > "$STATE_DIR/build.log" 2>&1

API_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
WEB_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

cat > "$STATE_DIR/proxy.mjs" <<'EOF'
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const apiPort = Number(process.env.API_PORT);
const proxyPort = Number(process.env.PROXY_PORT);
const staticRoot = path.resolve(process.env.STATIC_ROOT);
const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2'
};

function forward(req, res) {
  const upstream = http.request({
    host: '127.0.0.1',
    port: apiPort,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `127.0.0.1:${apiPort}` }
  }, (response) => {
    res.writeHead(response.statusCode || 502, response.headers);
    response.pipe(res);
  });
  upstream.on('error', () => {
    res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{"code":"API_UNAVAILABLE","message":"API is restarting"}');
  });
  req.pipe(upstream);
}

const server = http.createServer((req, res) => {
  const requestUrl = req.url || '/';
  if (requestUrl === '/health/ready') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end('{"ok":true}');
    return;
  }
  if (requestUrl.startsWith('/api/') || requestUrl.startsWith('/health/')) {
    forward(req, res);
    return;
  }

  let pathname;
  try {
    pathname = decodeURIComponent(new URL(requestUrl, 'http://127.0.0.1').pathname);
  } catch {
    res.writeHead(400);
    res.end('bad request');
    return;
  }

  const relative = pathname.replace(/^\/+/, '') || 'index.html';
  let filePath = path.resolve(staticRoot, relative);
  if (!(filePath === staticRoot || filePath.startsWith(`${staticRoot}${path.sep}`))) {
    res.writeHead(403);
    res.end('forbidden');
    return;
  }

  fs.stat(filePath, (statError, stat) => {
    if (statError || stat.isDirectory()) filePath = path.join(staticRoot, 'index.html');
    fs.readFile(filePath, (readError, data) => {
      if (readError) {
        res.writeHead(404);
        res.end('not found');
        return;
      }
      res.writeHead(200, { 'Content-Type': mime[path.extname(filePath)] || 'application/octet-stream' });
      res.end(data);
    });
  });
});

server.listen(proxyPort, '127.0.0.1', () => {
  console.log(`proxy ready: http://127.0.0.1:${proxyPort} -> ${apiPort}`);
});
EOF

cleanup() {
  if [[ -f "$STATE_DIR/api.pid" ]]; then
    api_pid="$(cat "$STATE_DIR/api.pid" 2>/dev/null || true)"
    if [[ -n "${api_pid:-}" ]]; then kill "$api_pid" 2>/dev/null || true; fi
  fi
  if [[ -n "${PROXY_PID:-}" ]]; then kill "$PROXY_PID" 2>/dev/null || true; fi
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

SERVER_ENTRY="$WORKSPACE/api/server.ts"
if [[ "$VARIANT" == "b" ]]; then
  mkdir -p "$STATE_DIR/api-runtime"
  unlink "$STATE_DIR/node_modules" 2>/dev/null || true
  ln -s "$WORKSPACE/node_modules" "$STATE_DIR/node_modules"
  cp "$WORKSPACE/api/server.ts" "$STATE_DIR/api-runtime/server.ts"
  cp "$WORKSPACE/api/content.ts" "$STATE_DIR/api-runtime/content.ts"
  python3 - "$STATE_DIR/api-runtime/server.ts" <<'PATCH'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("app.listen(3001,", "app.listen(Number(process.env.PORT)||3001,")
path.write_text(text)
PATCH
  SERVER_ENTRY="$STATE_DIR/api-runtime/server.ts"
fi

(
  cd "$STATE_DIR"
  exec env DATA_FILE=data.json PORT="$API_PORT" "$WORKSPACE/node_modules/.bin/tsx" "$SERVER_ENTRY"
) > "$STATE_DIR/api.log" 2>&1 &
API_PID=$!
printf '%s\n' "$API_PID" > "$STATE_DIR/api.pid"

API_PORT="$API_PORT" PROXY_PORT="$WEB_PORT" STATIC_ROOT="$WORKSPACE/dist-web" \
  node "$STATE_DIR/proxy.mjs" > "$STATE_DIR/proxy.log" 2>&1 &
PROXY_PID=$!

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${API_PORT}/health/live" >/dev/null 2>&1 && \
     curl -fsS "http://127.0.0.1:${WEB_PORT}/health/ready" >/dev/null 2>&1; then
    printf 'http://127.0.0.1:%s\n' "$WEB_PORT" > "$STATE_DIR/api-url"
    printf 'http://127.0.0.1:%s\n' "$WEB_PORT" > "$STATE_DIR/web-url"
    printf '%s\n' "$API_PORT" > "$STATE_DIR/api-port"
    echo "[start-local] ready web=http://127.0.0.1:${WEB_PORT} api=http://127.0.0.1:${API_PORT}" >&2
    wait "$PROXY_PID"
    exit 0
  fi
  sleep 0.5
done

echo "[start-local] timed out waiting for API and web readiness" >&2
exit 1
