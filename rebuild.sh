#!/usr/bin/env bash
# Runs on the OTP host (via SSH) or inside navigo_queue (if /var/otp and docker.sock are mounted).
# Safe to run manually: /var/otp/rebuild.sh
#
# --project-name otp ensures docker compose always targets the standalone OTP stack
# regardless of the caller's working directory.
set -euo pipefail

OTP_DIR="/var/otp"
OTP_DATA="${OTP_DIR}/graphs/default"
COMPOSE="docker compose -f ${OTP_DIR}/docker-compose.prod.yml --project-name otp"

GRAPH="${OTP_DATA}/graph.obj"
GRAPH_BAK="${OTP_DATA}/graph.obj.bak"

echo "[otp-rebuild] ── Starting Navigo OTP graph rebuild ──────────────────"
echo "[otp-rebuild] Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── Pre-flight validation: verify OSM and GTFS inputs exist ───────────────────
if ! compgen -G "${OTP_DATA}/*.osm.pbf" > /dev/null; then
  echo "[otp-rebuild] ERROR: No *.osm.pbf file found in ${OTP_DATA}. Aborting."
  exit 1
fi

if ! compgen -G "${OTP_DATA}/*.gtfs.zip" > /dev/null; then
  echo "[otp-rebuild] ERROR: No *.gtfs.zip feeds found in ${OTP_DATA}. Aborting."
  exit 1
fi

echo "[otp-rebuild] Detected input files:"
ls -lh "${OTP_DATA}"/*.osm.pbf "${OTP_DATA}"/*.gtfs.zip

# ── Back up current graph ─────────────────────────────────────────────────────
if [ -f "${GRAPH}" ]; then
  echo "[otp-rebuild] Backing up graph.obj → graph.obj.bak"
  cp "${GRAPH}" "${GRAPH_BAK}"
fi

# ── Stop serve container ──────────────────────────────────────────────────────
echo "[otp-rebuild] Stopping navigo-otp serve container"
${COMPOSE} stop otp || true

# ── Build graph ───────────────────────────────────────────────────────────────
echo "[otp-rebuild] Building unified multi-feed graph (this may take 4–10 minutes)"
BUILD_START=$(date +%s)

if ! ${COMPOSE} --profile build run --rm otp-build; then
  echo "[otp-rebuild] ERROR: otp-build failed, restoring backup graph"
  if [ -f "${GRAPH_BAK}" ]; then
    cp "${GRAPH_BAK}" "${GRAPH}"
    ${COMPOSE} up -d otp
    echo "[otp-rebuild] Restored graph.obj.bak and restarted navigo-otp"
  else
    echo "[otp-rebuild] No backup available, navigo-otp will remain stopped"
  fi
  exit 1
fi

BUILD_END=$(date +%s)
echo "[otp-rebuild] Build completed in $(( BUILD_END - BUILD_START ))s"

# ── Start serve container ─────────────────────────────────────────────────────
echo "[otp-rebuild] Starting navigo-otp serve container"
${COMPOSE} up -d otp

echo "[otp-rebuild] ── Rebuild complete, navigo-otp starting up ───────────"