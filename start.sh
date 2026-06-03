#!/bin/bash
# python-vue template launcher.
# Boots backend (uvicorn) on $PORT+1, waits for /healthz, then starts Vite on $PORT.
# Vite proxies /api + /ws + /healthz to the backend (see frontend/vite.config.js).
set -uo pipefail

PORT=3000
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --port) PORT="$2"; shift ;;
  esac
  shift
done

BACKEND_PORT=$((PORT + 1))
DIR="$(cd "$(dirname "$0")" && pwd)"
export VITE_API_PORT=$BACKEND_PORT

echo "[start.sh] python-vue: frontend=$PORT backend=$BACKEND_PORT"

# ── 1. Backend deps + launch ──────────────────────────────
cd "$DIR/backend"
echo "[start.sh] installing python deps..."
pip install -r requirements.txt -q --no-input 2>&1 | tail -3 \
  || pip3 install -r requirements.txt -q --no-input 2>&1 | tail -3 \
  || echo "[start.sh] WARNING: pip install reported failures, continuing"

echo "[start.sh] launching uvicorn on $BACKEND_PORT..."
python -m uvicorn main:app --host 0.0.0.0 --port "$BACKEND_PORT" --no-access-log &
BACK_PID=$!

# ── 2. Wait for backend /healthz (max 60s) ────────────────
# Block frontend startup until backend is genuinely listening, so the
# first browser request never races the still-warming uvicorn process
# and gets a misleading 502 "backend not found" error.
echo "[start.sh] waiting for backend /healthz..."
for i in $(seq 1 60); do
  if curl -sf -o /dev/null -m 1 "http://127.0.0.1:$BACKEND_PORT/healthz"; then
    echo "[start.sh] backend ready in ${i}s"
    break
  fi
  if ! kill -0 $BACK_PID 2>/dev/null; then
    echo "[start.sh] backend died during startup, aborting"
    exit 1
  fi
  sleep 1
done

# ── 3. Frontend deps + launch ─────────────────────────────
cd "$DIR/frontend"
if [ ! -d node_modules ]; then
  # Hardlink from preheated cache image layer if present (10x faster than npm install).
  if cp -al /opt/cache/node_modules ./node_modules 2>/dev/null; then
    echo "[start.sh] hardlinked node_modules from /opt/cache"
  else
    echo "[start.sh] running npm install..."
    npm install --prefer-offline --no-audit --progress=false 2>&1 | tail -5
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
      echo "[start.sh] ERROR: npm install failed"
      kill $BACK_PID 2>/dev/null
      exit 1
    fi
  fi
fi

echo "[start.sh] launching vite on $PORT..."
npx vite --host 0.0.0.0 --port "$PORT" --strictPort &
FRONT_PID=$!

trap "kill $BACK_PID $FRONT_PID 2>/dev/null" EXIT
wait $BACK_PID $FRONT_PID
