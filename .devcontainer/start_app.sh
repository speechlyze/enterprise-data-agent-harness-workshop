#!/bin/bash
# postStartCommand — runs every time the Codespace starts.
# Ensures Oracle is up, then launches the agent backend + frontend in the background
# so the learner can open the running app immediately.

set -e

echo "============================================"
echo "  Enterprise Data Agent — App Auto-Start"
echo "============================================"

WORKSPACE="${WORKSPACE:-$(pwd)}"
LOG_DIR="$WORKSPACE/.devcontainer/logs"
mkdir -p "$LOG_DIR"

# --- 1. Make sure Oracle is up (it should be, but the container can sleep) ---
echo ""
echo "[1/3] Ensuring Oracle is running..."
if ! docker ps --format '{{.Names}}' | grep -q '^oracle-free$'; then
  echo "  oracle-free not running — starting it..."
  docker compose -f "$WORKSPACE/.devcontainer/docker-compose.yml" up -d oracle 2>/dev/null
fi

# Wait briefly for the listener
for i in $(seq 1 10); do
  docker exec oracle-free healthcheck.sh > /dev/null 2>&1 && break
  echo "  waiting for Oracle... ($i/10)"
  sleep 5
done
echo "  Oracle ready."

# --- 2. Start the backend (Flask + Socket.IO) ---
echo ""
echo "[2/3] Starting agent backend on :8000 (logs → $LOG_DIR/backend.log)..."

# Kill any prior backend if a previous postStartCommand left one running.
pkill -f "python app.py" 2>/dev/null || true
sleep 1

cd "$WORKSPACE/app/backend"
nohup python app.py > "$LOG_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
cd "$WORKSPACE"
echo "  backend PID: $BACKEND_PID"

# Wait until the backend is responsive
for i in $(seq 1 30); do
  if curl -sf http://localhost:8000/api/health > /dev/null 2>&1; then
    echo "  backend ready."
    break
  fi
  if [ $i -eq 30 ]; then
    echo "  WARNING: backend didn't respond on /api/health within 30s. Check $LOG_DIR/backend.log"
  fi
  sleep 1
done

# --- 3. Start the frontend (Vite dev server) ---
echo ""
echo "[3/3] Starting agent UI on :3000 (logs → $LOG_DIR/frontend.log)..."

# Kill any prior frontend
pkill -f "vite" 2>/dev/null || true
sleep 1

cd "$WORKSPACE/app/frontend"
nohup npm run dev -- --host 0.0.0.0 > "$LOG_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!
cd "$WORKSPACE"
echo "  frontend PID: $FRONTEND_PID"

# Wait until Vite is serving
for i in $(seq 1 30); do
  if curl -sf http://localhost:3000 > /dev/null 2>&1; then
    echo "  frontend ready."
    break
  fi
  sleep 1
done

echo ""
echo "============================================"
echo "  App auto-start complete."
echo ""
echo "  • Frontend (UI):   http://localhost:3000   (auto-forwarded by Codespaces)"
echo "  • Backend (API):   http://localhost:8000"
echo "  • Notebook:        workshop/notebook_student.ipynb"
echo ""
echo "  Logs: $LOG_DIR/{backend,frontend}.log"
echo "  To restart manually:  bash .devcontainer/start_app.sh"
echo "============================================"
