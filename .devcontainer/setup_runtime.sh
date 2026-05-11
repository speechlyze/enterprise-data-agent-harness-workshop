#!/bin/bash
# postCreateCommand — runs ONCE after the Codespace is built.
# Boots Oracle, bootstraps the AGENT user / vector pool / ONNX embedder,
# seeds SUPPLYCHAIN + the skillbox.

set -e

echo "============================================"
echo "  Enterprise Data Agent Workshop — Runtime Setup (one-time)"
echo "============================================"

WORKSPACE="${WORKSPACE:-$(pwd)}"

# --- 1. Wait for Docker daemon ---
echo ""
echo "[1/5] Waiting for Docker daemon..."
for i in $(seq 1 15); do
  docker info > /dev/null 2>&1 && echo "  Docker is ready." && break \
    || { [ $i -lt 15 ] && echo "  Waiting for Docker... (attempt $i/15)" && sleep 3; }
done

# --- 2. Start Oracle container ---
echo ""
echo "[2/5] Starting Oracle AI Database (this can take 3-5 minutes on first run)..."
docker rm -f oracle-free > /dev/null 2>&1 || true
docker compose -f "$WORKSPACE/.devcontainer/docker-compose.yml" up -d oracle 2>/dev/null
echo "  Container started."

# --- 3. Wait for Oracle to be ready ---
echo ""
echo "[3/5] Waiting for Oracle to accept connections..."
ORACLE_UP=0
for i in $(seq 1 30); do
  docker exec oracle-free healthcheck.sh > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "  Oracle is accepting connections."
    ORACLE_UP=1
    break
  else
    echo "  Attempt $i/30 — waiting 10s..."
    sleep 10
  fi
done

if [ $ORACLE_UP -eq 0 ]; then
  echo "  ERROR: Oracle did not start. Run: docker logs oracle-free"
  exit 1
fi

# Existing volumes may keep old credentials; normalise to workshop defaults.
echo "  Resetting database password to workshop default..."
docker exec oracle-free resetPassword OraclePwd_2025 > /dev/null 2>&1 || true

# --- 4. Run app/scripts/bootstrap.py — creates AGENT user, vector pool, ONNX embedder, DBFS ---
echo ""
echo "[4/6] Running app/scripts/bootstrap.py (AGENT user + vector pool + ONNX + DBFS)..."
cd "$WORKSPACE/app"
python scripts/bootstrap.py
cd "$WORKSPACE"

# --- 5. Run app/scripts/seed.py — SUPPLYCHAIN + duality views + skill ingestion + scan ---
echo ""
echo "[5/6] Running app/scripts/seed.py (SUPPLYCHAIN + duality views + oracle/skills)..."

# The .env file is what the app reads; create it from the example if missing,
# then ensure the LLM keys are set from the Codespace secrets (devcontainer.json
# remoteEnv injects them into the shell).
if [ ! -f "$WORKSPACE/app/.env" ]; then
  cp "$WORKSPACE/app/.env.example" "$WORKSPACE/app/.env"
fi

# Patch in the OCI/OpenAI key from the Codespace env if present.
python3 - <<'PYEOF'
import os, pathlib

env_path = pathlib.Path(os.environ.get("WORKSPACE", os.getcwd())) / "app" / ".env"
text = env_path.read_text()

def set_kv(text, key, value):
    if not value:
        return text
    lines = text.splitlines()
    found = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith(f"{key}="):
            lines[i] = f"{key}={value}"
            found = True
            break
    if not found:
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"

# Pick the right LLM provider based on which key is set.
if os.environ.get("OCI_GENAI_API_KEY"):
    text = set_kv(text, "LLM_PROVIDER", "oci")
    text = set_kv(text, "OCI_GENAI_API_KEY", os.environ["OCI_GENAI_API_KEY"])
    if os.environ.get("OCI_GENAI_ENDPOINT"):
        text = set_kv(text, "OCI_GENAI_ENDPOINT", os.environ["OCI_GENAI_ENDPOINT"])
elif os.environ.get("OPENAI_API_KEY"):
    text = set_kv(text, "LLM_PROVIDER", "openai")
    text = set_kv(text, "OPENAI_API_KEY", os.environ["OPENAI_API_KEY"])

if os.environ.get("TAVILY_API_KEY"):
    text = set_kv(text, "TAVILY_API_KEY", os.environ["TAVILY_API_KEY"])

env_path.write_text(text)
print(f"  patched {env_path} with available secrets")
PYEOF

cd "$WORKSPACE/app"
python scripts/seed.py
cd "$WORKSPACE"

# --- 6. Run app/scripts/setup_advanced.py — Oracle Text index + DDS + scheduler ---
echo ""
echo "[6/6] Running app/scripts/setup_advanced.py (text index + DDS policies + scheduler)..."
cd "$WORKSPACE/app"
python scripts/setup_advanced.py
cd "$WORKSPACE"

echo ""
echo "============================================"
echo "  Workshop is ready!"
echo ""
echo "  • Notebook:  workshop/notebook_student.ipynb"
echo "  • App will start automatically on every Codespace launch"
echo "    (postStartCommand → start_app.sh)"
echo "  • Backend:  http://localhost:8000"
echo "  • Frontend: http://localhost:3000  (auto-forwarded)"
echo "============================================"
