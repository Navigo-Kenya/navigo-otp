#!/usr/bin/env bash
# Rebuild the OTP graph from the files in graphs/default and restart OTP.
#
# Runs where the API runs it (its queue container, with /var/otp and the
# Docker socket mounted, via OTP_BUILD_CMD=/var/otp/rebuild.sh) or by hand on
# the OTP host. It needs the serve container (navigo-otp) to exist: the build
# uses the same image and the same host folder as that container, read from
# `docker inspect`, so it works the same in production (/var/otp) and on a
# development machine (any path, Windows included), without Docker Compose.
#
#   1. checks the inputs (an .osm.pbf and at least one .gtfs.zip)
#   2. backs up graph.obj
#   3. stops OTP (the build needs its memory), builds, starts OTP again
#   4. on failure or interruption (SIGTERM from a cancel in the console),
#      puts the previous graph back and restarts OTP
#
# Environment: OTP_DIR (/var/otp), OTP_CONTAINER (navigo-otp),
#              OTP_BUILD_JAVA_OPTS (-Xmx6G -Xms1G -XX:+UseG1GC)
set -euo pipefail

OTP_DIR="${OTP_DIR:-/var/otp}"
OTP_DATA="${OTP_DIR}/graphs/default"
SERVE="${OTP_CONTAINER:-navigo-otp}"
BUILDER="${SERVE}-build"
JAVA_OPTS="${OTP_BUILD_JAVA_OPTS:--Xmx6G -Xms1G -XX:+UseG1GC}"
GRAPH="${OTP_DATA}/graph.obj"
GRAPH_BAK="${OTP_DATA}/graph.obj.bak"

log() { echo "[otp-rebuild] $*"; }

log "Starting $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ── Inputs ────────────────────────────────────────────────────────────────
shopt -s nullglob
pbfs=("${OTP_DATA}"/*.osm.pbf)
feeds=("${OTP_DATA}"/*.gtfs.zip)
if [ ${#pbfs[@]} -eq 0 ]; then log "ERROR: no *.osm.pbf in ${OTP_DATA}"; exit 1; fi
if [ ${#feeds[@]} -eq 0 ]; then log "ERROR: no *.gtfs.zip feed in ${OTP_DATA}"; exit 1; fi
log "OSM: $(for f in "${pbfs[@]}"; do printf '%s ' "$(basename "$f")"; done)"
log "Feeds: $(for f in "${feeds[@]}"; do printf '%s ' "$(basename "$f")"; done)"

# ── How OTP runs: image, host folder, network ─────────────────────────────
if ! docker inspect "$SERVE" >/dev/null 2>&1; then
  log "ERROR: container ${SERVE} not found. Start OTP once (docker compose up -d otp) so its image and folder are known."
  exit 1
fi
IMAGE=$(docker inspect -f '{{.Config.Image}}' "$SERVE")
HOST_DATA=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/opentripplanner"}}{{.Source}}{{end}}{{end}}' "$SERVE")
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$SERVE" | awk '{print $1}')
if [ -z "$HOST_DATA" ]; then log "ERROR: ${SERVE} has no /var/opentripplanner mount"; exit 1; fi
log "Image ${IMAGE}, data ${HOST_DATA}"

# ── Failure / interruption: previous graph back, OTP running ──────────────
BUILD_PID=""
restore() {
  if [ -f "$GRAPH_BAK" ]; then
    cp "$GRAPH_BAK" "$GRAPH"
    log "Put the previous graph back"
  fi
  docker start "$SERVE" >/dev/null 2>&1 || true
  log "${SERVE} restarted"
}
on_signal() {
  log "Interrupted: stopping the build"
  [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
  docker rm -f "$BUILDER" >/dev/null 2>&1 || true
  restore
  exit 130
}
trap on_signal INT TERM

if [ -f "$GRAPH" ]; then
  cp "$GRAPH" "$GRAPH_BAK"
  log "Backed up graph.obj"
fi

log "Stopping ${SERVE} (the build needs its memory)"
docker stop "$SERVE" >/dev/null || true

# ── Build ─────────────────────────────────────────────────────────────────
log "Building the graph (4-10 min)"
START=$(date +%s)
docker rm -f "$BUILDER" >/dev/null 2>&1 || true
# In the background + wait, so a SIGTERM is handled at once (bash runs traps
# only between commands; `wait` returns as soon as a signal arrives).
docker run --rm --name "$BUILDER" ${NETWORK:+--network "$NETWORK"} \
  -e JAVA_TOOL_OPTIONS="$JAVA_OPTS" \
  --mount "type=bind,source=${HOST_DATA},target=/var/opentripplanner" \
  "$IMAGE" --build --save &
BUILD_PID=$!
if ! wait "$BUILD_PID"; then
  log "ERROR: the build failed"
  restore
  exit 1
fi
BUILD_PID=""
log "Built in $(( $(date +%s) - START )) s"

# ── Serve ─────────────────────────────────────────────────────────────────
docker start "$SERVE" >/dev/null
log "${SERVE} started; it loads the graph in 1-3 min"
