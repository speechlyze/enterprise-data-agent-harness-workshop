#!/bin/bash
# postStartCommand — runs every time the Codespace starts.
# Ensures Oracle is up, runs bootstrap if it hasn't been run yet (fresh container
# without persistent volume), then launches backend + frontend in the background.
#
# Tolerant of partial failures: each step prints clear status, and the script
# does NOT `set -e` so one bad step won't leave the user with neither service.

set +e
set -u

echo "============================================"
echo "  Enterprise Data Agent — App Auto-Start"
echo "============================================"

WORKSPACE="${WORKSPACE:-$(pwd)}"
LOG_DIR="$WORKSPACE/.devcontainer/logs"
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# 1. Oracle
# -----------------------------------------------------------------------------
echo ""
echo "[1/4] Ensuring Oracle is running..."
if ! docker ps --format '{{.Names}}' | grep -q '^oracle-free$'; then
  if docker ps -a --format '{{.Names}}' | grep -q '^oracle-free$'; then
    echo "  oracle-free exists but stopped — starting..."
    docker start oracle-free > /dev/null 2>&1
  else
    echo "  oracle-free doesn't exist — bringing up via compose..."
    docker compose -f "$WORKSPACE/.devcontainer/docker-compose.yml" up -d oracle > /dev/null 2>&1
  fi
fi

# Wait up to 3 minutes for the listener to come up
echo "  waiting for Oracle to accept connections (up to 180s)..."
ORACLE_OK=0
for i in $(seq 1 36); do
  if docker exec oracle-free healthcheck.sh > /dev/null 2>&1; then
    echo "  Oracle ready ($((i * 5))s)."
    ORACLE_OK=1
    break
  fi
  sleep 5
done

if [ $ORACLE_OK -eq 0 ]; then
  echo "  ERROR: Oracle did not become healthy in 180s."
  echo "         Run:  docker logs oracle-free 2>&1 | tail -50"
  exit 1
fi

# -----------------------------------------------------------------------------
# 2. Was bootstrap ever run on this Oracle? If not, run it now.
#    (This handles a fresh container without a persistent volume, OR a Codespace
#     where setup_runtime.sh failed half-way through.)
# -----------------------------------------------------------------------------
echo ""
echo "[2/4] Checking that AGENT user + ONNX embedder exist..."

python3 - <<'PYEOF'
import sys
try:
    import oracledb
    conn = oracledb.connect(user="AGENT", password="AgentPwd_2025", dsn="localhost:1521/FREEPDB1")
    cur = conn.cursor()
    cur.execute("SELECT COUNT(*) FROM user_mining_models WHERE model_name = 'ALL_MINILM_L12_V2'")
    has_embedder = cur.fetchone()[0] > 0
    cur.execute("SELECT COUNT(*) FROM user_tables WHERE table_name = 'TOOLBOX'")
    has_toolbox = cur.fetchone()[0] > 0
    conn.close()
    sys.exit(0 if (has_embedder and has_toolbox) else 1)
except Exception:
    sys.exit(1)
PYEOF
BOOTSTRAP_OK=$?

if [ $BOOTSTRAP_OK -ne 0 ]; then
  echo "  AGENT/ONNX/toolbox not in place — running bootstrap + seed + setup_advanced now..."
  cd "$WORKSPACE/app"

  # .env file required by config.py — create from example if missing
  if [ ! -f "$WORKSPACE/app/.env" ]; then
    cp "$WORKSPACE/app/.env.example" "$WORKSPACE/app/.env"
  fi

  python scripts/bootstrap.py 2>&1 | tee -a "$LOG_DIR/bootstrap.log"
  python scripts/seed.py 2>&1 | tee -a "$LOG_DIR/seed.log"
  python scripts/setup_advanced.py 2>&1 | tee -a "$LOG_DIR/setup_advanced.log"
  cd "$WORKSPACE"
else
  echo "  AGENT user + ONNX embedder + toolbox table present."
fi

# -----------------------------------------------------------------------------
# 3. Backend
# -----------------------------------------------------------------------------
echo ""
echo "[3/4] Starting agent backend on :8000 (logs → $LOG_DIR/backend.log)..."

pkill -f "python app.py" 2>/dev/null
sleep 1

cd "$WORKSPACE/app/backend"
nohup python app.py > "$LOG_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
cd "$WORKSPACE"
echo "  backend PID: $BACKEND_PID"

# Wait up to 120s for /api/health to respond
BACKEND_OK=0
for i in $(seq 1 120); do
  if curl -sf http://localhost:8000/api/health > /dev/null 2>&1; then
    echo "  backend ready (${i}s)."
    BACKEND_OK=1
    break
  fi
  # If the process died early, surface it fast.
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo "  ERROR: backend process exited. Last 40 lines:"
    tail -40 "$LOG_DIR/backend.log" | sed 's/^/    /'
    break
  fi
  sleep 1
done

if [ $BACKEND_OK -eq 0 ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
  echo "  WARNING: backend hasn't answered /api/health within 120s. Tail of log:"
  tail -20 "$LOG_DIR/backend.log" | sed 's/^/    /'
  echo "  (Continuing — the backend may still come up. Frontend will start regardless.)"
fi

# -----------------------------------------------------------------------------
# 4. Frontend
# -----------------------------------------------------------------------------
echo ""
echo "[4/4] Starting agent UI on :3000 (logs → $LOG_DIR/frontend.log)..."

# node_modules may not exist on a fresh container.
if [ ! -d "$WORKSPACE/app/frontend/node_modules" ]; then
  echo "  node_modules missing — running 'npm install'..."
  cd "$WORKSPACE/app/frontend"
  npm install --no-audit --no-fund --silent 2>&1 | tee -a "$LOG_DIR/npm-install.log"
  cd "$WORKSPACE"
fi

pkill -f "vite" 2>/dev/null
sleep 1

cd "$WORKSPACE/app/frontend"
nohup npm run dev -- --host 0.0.0.0 > "$LOG_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!
cd "$WORKSPACE"
echo "  frontend PID: $FRONTEND_PID"

# Wait up to 60s for Vite to bind to :3000
FRONTEND_OK=0
for i in $(seq 1 60); do
  if curl -sf http://localhost:3000 > /dev/null 2>&1; then
    echo "  frontend ready (${i}s)."
    FRONTEND_OK=1
    break
  fi
  if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
    echo "  ERROR: frontend process exited. Last 40 lines:"
    tail -40 "$LOG_DIR/frontend.log" | sed 's/^/    /'
    break
  fi
  sleep 1
done

if [ $FRONTEND_OK -eq 0 ] && kill -0 "$FRONTEND_PID" 2>/dev/null; then
  echo "  WARNING: frontend didn't bind to :3000 within 60s. Tail of log:"
  tail -20 "$LOG_DIR/frontend.log" | sed 's/^/    /'
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Status:"
echo "    Oracle:   $([ $ORACLE_OK   -eq 1 ] && echo OK || echo FAIL)"
echo "    Backend:  $([ $BACKEND_OK  -eq 1 ] && echo OK || echo 'NOT READY (check log)')"
echo "    Frontend: $([ $FRONTEND_OK -eq 1 ] && echo OK || echo 'NOT READY (check log)')"
echo ""
echo "  • Frontend (UI):   http://localhost:3000   (auto-forwarded by Codespaces)"
echo "  • Backend (API):   http://localhost:8000"
echo "  • Notebook:        workshop/notebook_student.ipynb"
echo ""
echo "  Logs:              $LOG_DIR/{backend,frontend,npm-install,bootstrap,seed,setup_advanced}.log"
echo "  Restart manually:  bash .devcontainer/start_app.sh"
echo "============================================"
