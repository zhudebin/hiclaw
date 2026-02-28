#!/bin/bash
# worker-entrypoint.sh - Worker Agent startup
# Pulls config from centralized file system, starts file sync, launches OpenClaw.
#
# HOME is set to the Worker workspace so all agent-generated files are synced to MinIO:
#   ~/ = /root/hiclaw-fs/agents/<WORKER_NAME>/  (SOUL.md, openclaw.json, memory/)
#   /root/hiclaw-fs/shared/                     = Shared tasks, knowledge, collaboration data

set -e

WORKER_NAME="${HICLAW_WORKER_NAME:?HICLAW_WORKER_NAME is required}"
FS_ENDPOINT="${HICLAW_FS_ENDPOINT:?HICLAW_FS_ENDPOINT is required}"
FS_ACCESS_KEY="${HICLAW_FS_ACCESS_KEY:?HICLAW_FS_ACCESS_KEY is required}"
FS_SECRET_KEY="${HICLAW_FS_SECRET_KEY:?HICLAW_FS_SECRET_KEY is required}"

log() {
    echo "[hiclaw-worker $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Use absolute path because HOME is set to the workspace directory via docker run
HICLAW_ROOT="/root/hiclaw-fs"
WORKSPACE="${HICLAW_ROOT}/agents/${WORKER_NAME}"

# ============================================================
# Step 1: Configure mc alias for centralized file system
# ============================================================
log "Configuring mc alias..."
mc alias set hiclaw "${FS_ENDPOINT}" "${FS_ACCESS_KEY}" "${FS_SECRET_KEY}"

# ============================================================
# Step 2: Pull Worker config and shared data from centralized storage
# ============================================================
mkdir -p "${WORKSPACE}" "${HICLAW_ROOT}/shared"

log "Pulling Worker config from centralized storage..."
mc mirror "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" "${WORKSPACE}/" --overwrite
mc mirror "hiclaw/hiclaw-storage/shared/" "${HICLAW_ROOT}/shared/" --overwrite 2>/dev/null || true

# Verify essential files exist, retry if sync is still in progress
RETRY=0
while [ ! -f "${WORKSPACE}/openclaw.json" ] || [ ! -f "${WORKSPACE}/SOUL.md" ] \
      || [ ! -f "${WORKSPACE}/AGENTS.md" ]; do
    RETRY=$((RETRY + 1))
    if [ "${RETRY}" -gt 6 ]; then
        log "ERROR: openclaw.json, SOUL.md or AGENTS.md not found after retries. Manager may not have created this Worker's config yet."
        exit 1
    fi
    log "Waiting for config files to appear in MinIO (attempt ${RETRY}/6)..."
    sleep 5
    mc mirror "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" "${WORKSPACE}/" --overwrite 2>/dev/null || true
done

# HOME is already set to WORKSPACE via docker run -e HOME=...
# Symlink to default OpenClaw config path so CLI commands find the config
mkdir -p "${HOME}/.openclaw"
ln -sf "${WORKSPACE}/openclaw.json" "${HOME}/.openclaw/openclaw.json"

log "Worker config pulled successfully"

# Ensure hiclaw-sync symlink is functional (wrapper script calls workspace path)
ln -sf "${WORKSPACE}/skills/file-sync/scripts/hiclaw-sync.sh" /usr/local/bin/hiclaw-sync 2>/dev/null || true

log "HOME set to ${HOME} (workspace files will be synced to MinIO)"

# ============================================================
# Step 3: Start file sync
# ============================================================

# Local -> Remote: real-time watch for Worker-generated content only
# Exclude Manager-managed configs (shared/ is separate, not under workspace)
mc mirror --watch "${WORKSPACE}/" "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" --overwrite \
    --exclude "openclaw.json" --exclude "AGENTS.md" --exclude "SOUL.md" \
    --exclude "mcporter-servers.json" --exclude "skills/**" \
    --exclude ".openclaw/**" --exclude ".cache/**" --exclude ".npm/**" \
    --exclude ".local/**" --exclude ".mc/**" &
log "Local->Remote sync started (PID: $!)"

# Remote -> Local: periodic pull (configs from Manager + shared data)
# On-demand pull via file-sync skill when Manager notifies
(
    while true; do
        sleep 300
        mc mirror "hiclaw/hiclaw-storage/agents/${WORKER_NAME}/" "${WORKSPACE}/" --overwrite --newer-than "5m" 2>/dev/null || true
        mc mirror "hiclaw/hiclaw-storage/shared/" "${HICLAW_ROOT}/shared/" --overwrite --newer-than "5m" 2>/dev/null || true
    done
) &
log "Remote->Local periodic sync started (every 5m, PID: $!)"

# ============================================================
# Step 4: Configure mcporter (MCP tool CLI)
# ============================================================
if [ -f "${WORKSPACE}/mcporter-servers.json" ]; then
    log "Configuring mcporter with MCP Server endpoints..."
    export MCPORTER_CONFIG="${WORKSPACE}/mcporter-servers.json"
fi

# ============================================================
# Step 5: Launch OpenClaw Worker Agent
# ============================================================
log "Starting Worker Agent: ${WORKER_NAME}"
export OPENCLAW_CONFIG_PATH="${WORKSPACE}/openclaw.json"
cd "${WORKSPACE}"
exec openclaw gateway run --verbose --force
