# Navigo · OTP Routing Engine

[![OpenTripPlanner](https://img.shields.io/badge/OpenTripPlanner-2.4.0-1565C0?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMSAxNy45M1Y0LjA3YzMuOTQuNDkgNyAzLjg1IDcgNy45M3MtMy4wNiA3LjQ0LTcgNy45M3oiLz48L3N2Zz4=)](https://www.opentripplanner.org)
[![Docker](https://img.shields.io/badge/Docker-required-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com)
[![Java](https://img.shields.io/badge/JVM-17%2B%20%C2%B7%2020%20GB%2B%20heap-ED8B00?style=flat-square&logo=openjdk&logoColor=white)](https://openjdk.org)
[![GTFS](https://img.shields.io/badge/GTFS-Multi--Feed-43A047?style=flat-square)](https://gtfs.org)
[![OSM](https://img.shields.io/badge/OpenStreetMap-Kenya-7EBC6F?style=flat-square&logo=openstreetmap&logoColor=white)](https://www.openstreetmap.org)
[![Region](https://img.shields.io/badge/Region-Kenya%20%E2%86%92%20Global-FF6F00?style=flat-square)](https://navigo.co.ke)

---

The **Navigo OTP Engine** is the standalone transit routing core of the [Navigo](https://navigo.co.ke) platform. Decoupled from `navigo-api`, it runs [OpenTripPlanner 2.4](https://www.opentripplanner.org) in Docker, loaded with modular Kenyan transit feeds (urban Matatus + intercity buses, SGR trains, and domestic flights) alongside the national street network (OpenStreetMap), and answers every "get me from A to B" request in real time.

Navigo launches across **Kenya**—combining complex urban matatu networks like Nairobi and Nakuru with national intercity corridors—and is designed to scale to any new city or region simply by adding a new `*-urban.gtfs.zip` feed or regional OSM extract.

---

## Contents

- [Architecture & separation from Navigo-api](#architecture--separation-from-navigo-api)
- [How OTP works](#how-otp-works)
- [Data directory](#data-directory)
- [First-time setup](#first-time-setup)
- [Normal operation](#normal-operation)
- [Automated sync via Navigo-api](#automated-sync-via-navigo-api)
- [Scaling to new regions](#scaling-to-new-regions)
- [Production deployment](#production-deployment)
- [Troubleshooting](#troubleshooting)

---

## Architecture & separation from Navigo-api

`navigo-otp` runs as an independent Docker Compose stack (`/var/otp`) separate from the Laravel backend (`navigo-api`):

1. **Resource Isolation:** OTP graph compilation and in-memory routing are JVM-intensive. Isolating OTP in its own Compose stack prevents graph rebuilds from starving PHP-FPM, PostgreSQL, or Redis.
2. **Deployment Flexibility:** `navigo-otp` can run on the same host as `navigo-api` (communicating over the shared `navigo_net` Docker network) or on a dedicated high-memory VPS.
3. **Standalone `docker-compose.yml` (Tuned for 32 GB RAM Server):**

```yaml
version: "3.9"

services:
  # ── OpenTripPlanner (serve) ───────────────────────────────────────────────
  otp:
    image: opentripplanner/opentripplanner:2.4.0
    container_name: navigo-otp
    ports:
      - "127.0.0.1:8080:8080"
    environment:
      # 20GB heap with ZGC ensures sub-millisecond GC pauses under high routing traffic
      - JAVA_OPTS=-Xmx20G -Xms4G -XX:+UseZGC
    volumes:
      - /var/otp/graphs/default:/var/opentripplanner
    command: --load
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 24G
        reservations:
          memory: 16G
    networks:
      - navigo_net

  # ── OpenTripPlanner (graph builder, on-demand) ────────────────────────────
  otp-build:
    image: opentripplanner/opentripplanner:2.4.0
    container_name: navigo-otp-build
    profiles: ["build"]
    environment:
      # Generous heap for parsing large national OSM extracts & multi-feed GTFS zips
      - JAVA_OPTS=-Xmx20G -Xms4G -XX:+UseG1GC
    volumes:
      - /var/otp/graphs/default:/var/opentripplanner
    command: --build --save
    deploy:
      resources:
        limits:
          memory: 24G
    networks:
      - navigo_net

networks:
  navigo_net:
    name: navigo_net
    external: true
```

---

## How OTP works

OTP 2.x has exactly **two operating modes**. Understanding both is required.

### Mode 1 `--build --save` (graph compilation)

OTP reads the raw OSM and multi-feed GTFS input files from `/var/otp/graphs/default/`, computes a unified street + transit routing graph (including cross-feed transfers between urban matatus and intercity terminals), and serialises the result to `graph.obj`. This is a one-time, offline, blocking operation—the HTTP server is **not available** inside the builder container while it runs.

```
/var/otp/graphs/default/
  kenya-latest.osm.pbf      ─┐
  nairobi-urban.gtfs.zip    ─┤
  nakuru-urban.gtfs.zip     ─┼──► [--build --save]  ──►  graph.obj
  kenya-intercity.gtfs.zip  ─┤       (4 – 10 min)
  build-config.json         ─┘
```

### Mode 2 `--load` (graph serving)

OTP reads the pre-built `graph.obj` into memory and opens an HTTP server on port 8080. All route-planning requests are answered from RAM with sub-second latency.

```
graph.obj  ──►  [--load]  ──►  HTTP :8080
                (60 – 120 s startup)
```

**The critical rule:** every time any `.gtfs.zip` feed changes (new routes, updated timetables, added stops), `graph.obj` must be **rebuilt** from scratch. Simply restarting the `--load` container without rebuilding serves stale transit data.

---

## Data directory

Everything OTP reads or writes lives on the host in `/var/otp/graphs/default/` (or `./graphs/default/` in local development), volume-mounted into the container at `/var/opentripplanner`.

```
/var/otp/graphs/default/
├── kenya-latest.osm.pbf       # Réseau routier/piéton complet (OSM)
├── nairobi-urban.gtfs.zip     # Uniquement les Matatus intra-Nairobi
├── nakuru-urban.gtfs.zip      # Uniquement les Matatus intra-Nakuru
├── kenya-intercity.gtfs.zip   # TOUS les bus longs trajets, SGR (train) et vols
├── graph.obj                  # Compiled routing graph (output of --build --save)
├── build-config.json          # (Optional) OTP build-time settings
└── router-config.json         # (Optional) OTP runtime tuning
```

### `kenya-latest.osm.pbf`

The full Kenyan street network from [Geofabrik](https://download.geofabrik.de/africa/kenya.html). OTP uses it to model every pedestrian and cycling leg of a trip—footpaths, crossings, road widths, turn restrictions—and to link transit stops from all GTFS feeds to physical streets. It changes infrequently; update it when significant new infrastructure is added (e.g. a new BRT corridor or major pedestrian bridge). A full graph rebuild is required after replacement.

For a single-city local test instance (e.g. Nairobi only), you can extract a smaller `.pbf` with [osmium](https://osmcode.org/osmium-tool/) to reduce build time:

```bash
osmium extract --bbox=36.65,-1.45,37.10,-1.15 kenya-latest.osm.pbf -o nairobi.osm.pbf
```

### Modular GTFS feeds (`*.gtfs.zip`)

Instead of a single monolithic zip, transit schedules are split into modular archives by operational scope:

| Archive | Scope | Modes Covered |
|---------|-------|---------------|
| `nairobi-urban.gtfs.zip` | Greater Nairobi metropolitan area | Intra-Nairobi Matatus & city buses |
| `nakuru-urban.gtfs.zip` | Nakuru metropolitan area | Intra-Nakuru Matatus |
| `kenya-intercity.gtfs.zip` | National intercity corridors | Long-distance buses, SGR trains, and domestic flights |

Each `.gtfs.zip` archive is a standard GTFS feed containing 9 files (plus an optional `feed_info.txt` to namespace feed IDs):

| File | Contents |
|------|----------|
| `agency.txt` | Transit operators (Navigo, SACCOs, intercity coach operators, Kenya Railways, airlines) |
| `stops.txt` | Bus / matatu stages, SGR stations, and airports with GPS coordinates |
| `routes.txt` | Named routes and colour coding |
| `trips.txt` | Individual trip patterns per route |
| `stop_times.txt` | Arrival and departure times per trip |
| `calendar.txt` | Service day patterns (Mon–Fri, weekends, public holidays) |
| `calendar_dates.txt` | One-off service exceptions |
| `frequencies.txt` | Headway-based scheduling for high-frequency routes |
| `shapes.txt` | Polyline geometry for map display |

**These files are managed automatically by `navigo-api`.** The console's Export & Sync pipeline exports them from PostgreSQL, validates them, and delivers them to `/var/otp/graphs/default/`. Do not edit them manually.

### `graph.obj`

The compiled binary graph—typically 250–900 MB depending on the number of active regional feeds. Produced by `--build --save`; loaded by `--load`. Binary format, not human-readable.

---

## First-time setup

Use this when `graph.obj` does not yet exist, or after replacing the OSM extract.

### 1. Create the directory & get the OSM extract

```bash
sudo mkdir -p /var/otp/graphs/default
sudo chown -R $USER:$USER /var/otp

# Full Kenya (recommended — covers all urban & intercity feeds)
curl -L [https://download.geofabrik.de/africa/kenya-latest.osm.pbf](https://download.geofabrik.de/africa/kenya-latest.osm.pbf) \
     -o /var/otp/graphs/default/kenya-latest.osm.pbf

# Nairobi-only extract (faster local builds, smaller file, Nairobi only)
# osmium extract --bbox=36.65,-1.45,37.10,-1.15 /var/otp/graphs/default/kenya-latest.osm.pbf \
#         -o /var/otp/graphs/default/nairobi.osm.pbf
```

### 2. Get the GTFS feeds

Either trigger a manual export from the Navigo console (**GTFS → Export & Sync**), or copy `nairobi-urban.gtfs.zip`, `nakuru-urban.gtfs.zip`, and `kenya-intercity.gtfs.zip` into `/var/otp/graphs/default/`.

### 3. Build the graph

You can compile `graph.obj` using the Docker Compose `build` profile or directly via `docker run`:

```bash
# Option A: Docker Compose (Linux / macOS / WSL / Windows)
cd /var/otp
docker compose --profile build run --rm otp-build

# Option B: Standalone Docker CLI (Linux server)
docker run --rm \
  -e JAVA_OPTS="-Xmx20G -Xms4G -XX:+UseG1GC" \
  -v /var/otp/graphs/default:/var/opentripplanner \
  opentripplanner/opentripplanner:2.4.0 --build --save

# Option C: Standalone Docker CLI (Windows PowerShell)
docker run --rm `
  -e JAVA_OPTS="-Xmx20G" `
  -v "C:\navigo\navigo-otp\graphs\default:/var/opentripplanner" `
  opentripplanner/opentripplanner:2.4.0 --build --save

# Option D: Standalone Docker CLI (Windows cmd.exe)
docker run --rm ^
  -e JAVA_OPTS="-Xmx20G" ^
  -v "C:\navigo\navigo-otp\graphs\default:/var/opentripplanner" ^
  opentripplanner/opentripplanner:2.4.0 --build --save
```

Watch the output—OTP will log OSM parsing, GTFS parsing for each `.gtfs.zip` archive, street-to-transit graph linkage, and finally `"Graph written"`. The container exits with code `0` on success and writes `graph.obj` to `/var/otp/graphs/default/graph.obj`.

### 4. Start the serve container

```bash
cd /var/otp
docker compose up -d otp
```

OTP takes **60–120 seconds** to load `graph.obj` and open its HTTP port. Poll readiness:

```bash
curl [http://127.0.0.1:8080/otp](http://127.0.0.1:8080/otp)
# Returns JSON with version info and buildTime when ready
```

---

## Normal operation

```bash
# Start (detached)
docker compose up -d otp

# Stop gracefully
docker compose stop otp

# Live logs
docker logs -f navigo-otp

# Check status
curl -s [http://127.0.0.1:8080/otp](http://127.0.0.1:8080/otp) | jq '{version: .serverVersion.version, built: .serverVersion.buildTime}'
```

### Manual graph rebuild

Required after any `.gtfs.zip` or `.osm.pbf` change.

```bash
# Preferred — Linux / macOS / WSL helper script
chmod +x /var/otp/rebuild.sh && /var/otp/rebuild.sh

# Manual steps — Docker Compose (any OS)
cd /var/otp
docker compose stop otp
docker compose --profile build run --rm otp-build
docker compose up -d otp

# Manual steps — Standalone Docker CLI one-liner (Linux)
docker stop navigo-otp || true && \
docker run --rm -e JAVA_OPTS="-Xmx20G" -v /var/otp/graphs/default:/var/opentripplanner opentripplanner/opentripplanner:2.4.0 --build --save && \
docker start navigo-otp
```

`rebuild.sh` handles the sequence atomically: stop serve → build (blocking) → start serve. The `navigo-api` health poller then confirms OTP is accepting requests before marking the sync complete.

---

## Automated sync via Navigo-api

The **Export & Sync** button in the Navigo console triggers a fully automated pipeline managed by a Laravel queue job (`navigo_queue`):

```
Step 1  Validate GTFS data integrity against PostgreSQL
Step 2  Export modular GTFS archives to storage/app/gtfs/:
          ├── nairobi-urban.gtfs.zip
          ├── nakuru-urban.gtfs.zip
          └── kenya-intercity.gtfs.zip
Step 3  Deliver *.gtfs.zip files to /var/otp/graphs/default/ (local copy or SCP)
Step 4  Run OTP_BUILD_CMD  (stop serve → rebuild graph → start serve)
Step 5  Poll OTP_HEALTH_CHECK_URL until HTTP 200  (up to 5 minutes)
Step 6  Write sync timestamp to cache and mark job complete
```

Every step produces a log entry in `otp_logs` (visible in the console activity log). The job can be cancelled between steps.

### Environment variables (in `navigo-api` `.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `OTP_DEPLOY_DRIVER` | `local` | `local` copy on same machine; `scp` SSH transfer; `none` skip delivery |
| `OTP_DATA_PATH` | `/var/otp/graphs/default` | Absolute path to the OTP graph directory on the local host |
| `OTP_SCP_TARGET` | _(required for `scp`)_ | `user@host:/var/otp/graphs/default/` |
| `OTP_SCP_KEY` | _(optional)_ | Absolute path to SSH private key |
| `OTP_BUILD_CMD` | _(empty = skip rebuild)_ | Shell command executed after delivery |
| `OTP_HEALTH_CHECK_URL` | `http://127.0.0.1:8080/otp` | Endpoint polled for readiness |
| `OTP_HEALTH_CHECK_RETRIES` | `30` | Max polling attempts |
| `OTP_HEALTH_CHECK_DELAY` | `10` | Seconds between attempts |

### Local development (Windows)

```dotenv
OTP_DEPLOY_DRIVER=local
OTP_DATA_PATH=/var/otp/graphs/default
OTP_BUILD_CMD='docker stop navigo-otp & docker run --rm -e JAVA_OPTS="-Xmx20G" -v "/var/otp/graphs/default:/var/opentripplanner" opentripplanner/opentripplanner:2.4.0 --build --save && docker start navigo-otp'
OTP_HEALTH_CHECK_URL=[http://127.0.0.1:8080/otp](http://127.0.0.1:8080/otp)
OTP_HEALTH_CHECK_RETRIES=30
OTP_HEALTH_CHECK_DELAY=10
```

> **Shell syntax note:** The Windows `OTP_BUILD_CMD` uses `cmd.exe` syntax where `&` means "run next command regardless of exit code." On Linux, `&` means "run in background"—a completely different semantic. **On a Linux server, always set `OTP_BUILD_CMD` to the path of `/var/otp/rebuild.sh`**, never copy the Windows cmd string.

### Same-host production server (Decoupled stacks on one Linux VPS)

```dotenv
OTP_DEPLOY_DRIVER=local
OTP_DATA_PATH=/var/otp/graphs/default
OTP_BUILD_CMD=/var/otp/rebuild.sh
OTP_HEALTH_CHECK_URL=http://navigo-otp:8080/otp
OTP_HEALTH_CHECK_RETRIES=30
OTP_HEALTH_CHECK_DELAY=10
```

### Remote production server (Dedicated OTP VPS)

```dotenv
OTP_DEPLOY_DRIVER=scp
OTP_SCP_TARGET=ubuntu@otp.yourdomain.com:/var/otp/graphs/default/
OTP_SCP_KEY=/home/deploy/.ssh/otp_key
OTP_BUILD_CMD='ssh -i /home/deploy/.ssh/otp_key -o StrictHostKeyChecking=no ubuntu@otp.yourdomain.com "/var/otp/rebuild.sh"'
OTP_HEALTH_CHECK_URL=[http://otp.yourdomain.com:8080/otp](http://otp.yourdomain.com:8080/otp)
OTP_HEALTH_CHECK_RETRIES=40
OTP_HEALTH_CHECK_DELAY=15
```

---

## Scaling to new regions

Navigo is built to expand across Kenya and East Africa:

1. **Adding a new Kenyan city (e.g. Mombasa, Kisumu, Eldoret):** No OSM change is needed because `kenya-latest.osm.pbf` and `kenya-intercity.gtfs.zip` already cover the country. Simply export the new urban feed (e.g. `mombasa-urban.gtfs.zip`) into `/var/otp/graphs/default/` and rebuild.
2. **Adding a new country:** Download or merge the relevant OSM `.pbf` extract from Geofabrik into `/var/otp/graphs/default/` (remove old standalone `.pbf` files if replaced by a merged regional extract) and drop in the corresponding `*.gtfs.zip` feeds.
3. **Rebuild the graph:** Run `/var/otp/rebuild.sh` or trigger **Export & Sync** from the console.
4. **Adjust JVM memory (`JAVA_OPTS`):** Larger OSM extracts, 3D elevation data (GeoTIFF DEM), and high query concurrency require more heap in `/var/otp/docker-compose.yml`:

   | Scope / Server Tier | Recommended `JAVA_OPTS` | Notes |
   |---------------------|-------------------------|-------|
   | Single city (Nairobi only) | `-Xmx4G -Xms512m -XX:+UseG1GC` | Fits on 8 GB RAM host |
   | Kenya national (Multi-urban + Intercity) | `-Xmx6G -Xms1G -XX:+UseG1GC` | Fits on 8–16 GB RAM host |
   | East Africa multi-country | `-Xmx10G -Xms2G -XX:+UseG1GC` | Requires 16 GB+ RAM host |
   | High-concurrency / 32 GB RAM server (Sequential build) | `-Xmx20G -Xms4G -XX:+UseZGC` | Stop `otp` before running `otp-build` so only one 20 GB JVM runs at a time (leaves ~12 GB for OS & off-heap overhead) |

5. **Separate instances per region** _(optional)_: For high-traffic multi-country deployments, run one OTP container per country behind a routing proxy that selects the instance based on origin/destination coordinates.

---

## Production deployment

### Recommended server spec (32 GB RAM Hetzner CPX32 / CCX33)

| Component | Minimum | Recommended | High-Capacity |
|-----------|---------|-------------|---------------|
| RAM | 8 GB | 16 GB | **32 GB** |
| CPU | 4 cores | 8 cores | **8–16 cores** |
| Disk | SSD, 15 GB | NVMe SSD, 30 GB | **NVMe SSD, 60 GB** |
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04 / 24.04 LTS | **Ubuntu 24.04 LTS** |

### Setup checklist

- [ ] Docker Engine installed (`docker compose` v2+)
- [ ] `/var/otp/graphs/default/` contains `kenya-latest.osm.pbf`, `nairobi-urban.gtfs.zip`, `nakuru-urban.gtfs.zip`, and `kenya-intercity.gtfs.zip`
- [ ] Initial graph built (`/var/otp/rebuild.sh`)
- [ ] Container running (`docker compose up -d otp`)
- [ ] Port 8080 accessible **only from the Laravel API server**, not from the public internet
- [ ] `OTP_BUILD_CMD` in `navigo-api` `.env` points to `/var/otp/rebuild.sh` on this server
- [ ] SSH key for deploy user added to `~/.ssh/authorized_keys` (if using `scp` driver)
- [ ] `/var/otp/rebuild.sh` is executable (`chmod +x /var/otp/rebuild.sh`)
- [ ] (Optional) Supervisor / systemd watchdog configured for the Docker daemon

### Keeping OTP behind a firewall

OTP has no authentication. It must never be exposed directly to the internet. The Laravel API proxies all requests and enforces auth. Restrict port 8080 at the firewall to the API server's IP only:

```bash
ufw allow from <api-server-ip> to any port 8080
ufw deny 8080
```

---

## Troubleshooting

### OTP fails to start after rebuild

```bash
docker logs navigo-otp
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| `OutOfMemoryError` | Heap too small | Increase `JAVA_OPTS=-Xmx20G` in `docker-compose.yml` |
| `graph.obj not found` | Build did not complete | Check build logs; rerun `--build --save` |
| `Duplicate stop/trip ID` | ID collision across multiple `.gtfs.zip` files | Ensure each zip defines a unique `feed_id` in `feed_info.txt` |
| `Address already in use: 8080` | Port conflict | `netstat -tulpn \| grep 8080` and kill the process |
| Container exits immediately | Corrupted `graph.obj` | Delete `graph.obj` and rebuild |

### Build fails — no input data

OTP aborts if it finds no `.zip` (GTFS) or no `.pbf` (OSM) in `/var/otp/graphs/default/`. Confirm all files exist before building:

```bash
ls -lh /var/otp/graphs/default/
# Should show:
# kenya-latest.osm.pbf
# nairobi-urban.gtfs.zip
# nakuru-urban.gtfs.zip
# kenya-intercity.gtfs.zip
```

### Verify all GTFS feeds loaded into the graph

Confirm that OTP compiled and loaded all urban and intercity feeds:

```bash
curl -s -X POST [http://127.0.0.1:8080/otp/routers/default/index/graphql](http://127.0.0.1:8080/otp/routers/default/index/graphql) \
  -H "Content-Type: application/json" \
  -d '{"query": "{ feeds { feedId agencies { name } } }"}' | jq
```

### Health check times out after rebuild

OTP's load time scales with graph size. If 30 × 10 s = 5 minutes is not enough:

```dotenv
OTP_HEALTH_CHECK_RETRIES=60
OTP_HEALTH_CHECK_DELAY=15
```

### Route plans return stale results after a sync

Verify the rebuild actually completed and OTP loaded the new graph:

```bash
# Check graph build timestamp (Unix ms)
curl -s [http://127.0.0.1:8080/otp](http://127.0.0.1:8080/otp) | jq '.serverVersion.buildTime'

# Compare to graph.obj file modification time
stat /var/otp/graphs/default/graph.obj
```

If the timestamps don't match, the serve container restarted without a new graph—check the `otp_build` log entry in the console activity log for errors.

### Force a full rebuild from scratch

```bash
cd /var/otp
docker compose stop otp
rm -f /var/otp/graphs/default/graph.obj   # force rebuild even if file exists
docker compose --profile build run --rm otp-build
docker compose up -d otp
```