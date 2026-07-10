# Open-RMF Hotel Demo on OpenShift

Multi-robot fleet orchestration on OpenShift using the [rmf_demos Hotel world](https://github.com/open-rmf/rmf_demos). Demonstrates 3 robot fleets (4 robots) coordinating across a 3-level hotel with lifts, doors, and traffic negotiation — all without GPU.

## What This Demo Shows

- **3 fleets, 4 robots** — delivery bot, patrol bot, 2 cleaner bots
- **Lifts** — robots take elevators between floors
- **Doors** — automatically open/close as robots approach
- **Traffic negotiation** — robots from different fleets yield to each other
- **Task dispatch** — patrol, delivery, and cleaning tasks via web dashboard
- **Web dashboard** — real-time fleet monitoring and control (rmf-web)
- **No GPU required** — headless Gazebo + slot car plugin

## Architecture (Single Pod)

```
┌──────────────────────────────────────────────────────────────────┐
│  Single Pod (Ubuntu 24.04 + ROS 2 Jazzy)                         │
│                                                                    │
│  Gazebo Server (headless) ─── Hotel world (3 levels, slot car)   │
│  RMF Core ─── traffic schedule + door/lift supervisors           │
│  Fleet Adapters x3 ─── tinyRobot, deliveryRobot, cleanerBotA    │
│  rmf-web API (:8000) ─── FastAPI backend                         │
│  rmf-web Dashboard (:3000) ─── React frontend                    │
│  RViz2 + noVNC (:6080) ─── optional schedule visualizer          │
│  Landing page (:8080)                                             │
│                                                                    │
│  All communication: localhost DDS (no Zenoh, no cross-pod)        │
└──────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- OpenShift cluster (no GPU node required)
- `oc` CLI logged in
- `podman` for building images
- Registry access to `quay.io/lrangine/ros2-demo`

## Quick Start

```bash
cd examples/open-rmf

# Build the all-in-one image
podman build --platform linux/amd64 \
  -t quay.io/lrangine/ros2-demo:openrmf-hotel \
  -f Containerfile .

# Push to registry
podman push quay.io/lrangine/ros2-demo:openrmf-hotel

# Deploy to OpenShift
oc apply -f k8s/
oc -n lokesh-ros2-openrmf-demo get pods
oc -n lokesh-ros2-openrmf-demo get routes
```

## Demo Walkthrough

1. Open the **rmf-web dashboard** route in browser
2. See the hotel map with all 4 robots at their stations
3. Dispatch tasks (see below)
4. Watch robots move in **real-time** via noVNC/RViz2

---

## Assigning Tasks

Tasks are dispatched via CLI using `oc exec` into the running pod. Robots are idle until they receive a task.

### Setup

```bash
# Prefix for all task commands (exec into the pod)
OC_EXEC="oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- bash -c"

# All commands need the ROS 2 environment sourced
ROS_ENV="export HOME=/tmp/ros-home && source /opt/ros/jazzy/setup.bash && source /opt/rmf_demos/install/setup.bash"
```

### Patrol Tasks

Send a robot through a sequence of waypoints:

```bash
# tinyBot patrol: lobby → restaurant → shop (1 round)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol \
  -p lobby restaurant shop -n 1 --use_sim_time"

# deliveryBot multi-floor: kitchen → L2 master suite (robot uses lift)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol \
  -p kitchen L2_master_suite -n 1 --use_sim_time"

# deliveryBot cross-floor loop: kitchen → L3 room → back (2 rounds)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol \
  -p kitchen L3_master_suite L3_room1 -n 2 --use_sim_time"
```

### Cleaning Tasks

Assign a cleaner bot to clean a specific zone:

```bash
# Clean the lobby
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_clean \
  -cs clean_lobby --use_sim_time"

# Clean the restaurant
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_clean \
  -cs clean_restaurant --use_sim_time"

# Clean the waiting area
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_clean \
  -cs clean_waiting_area --use_sim_time"
```

### Delivery Tasks

```bash
# Delivery from kitchen to L3 master suite
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_delivery \
  -p kitchen -ph coke -d L3_master_suite -dh coke --use_sim_time"

# Delivery from kitchen to L2 room
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_delivery \
  -p kitchen -ph food -d L2_room1 -dh food --use_sim_time"
```

### Available Waypoints

Each fleet has its own navigation graph. Tasks are auto-assigned to the fleet whose graph contains the requested waypoints.

| Fleet | Graph | L1 Waypoints | L2/L3 Waypoints |
|-------|-------|--------------|-----------------|
| tinyRobot | 0 | `lobby`, `shop`, `restaurant`, `tinybot_charger` | `L2_room1`, `L2_master_suite`, `L2_room15`, `L3_room1`, `L3_master_suite`, `L3_room15` |
| cleanerBotA | 1 | `clean_lobby`, `clean_restaurant`, `clean_waiting_area`, `cleanerbot_charger1`, `cleanerbot_charger2` | — |
| deliveryRobot | 2 | `kitchen`, `restaurant`, `deliverybot_charger` | `L2_room1`, `L2_master_suite`, `L2_room15`, `L3_room1`, `L3_master_suite`, `L3_room15` |

### Available Clean Zones

| Zone ID | Description |
|---------|-------------|
| `clean_lobby` | Lobby area cleaning route |
| `clean_restaurant` | Restaurant cleaning route |
| `clean_waiting_area` | Waiting area cleaning route |

---

## Viewing Robot Traversal in Real-Time

### Option 1: noVNC / RViz2 (recommended for real-time)

The best way to see robots moving live. RViz2 renders the schedule visualizer with robot markers traveling along their navigation paths.

**IMPORTANT: Use HTTP (not HTTPS) for the noVNC URL.** WebSocket upgrades through edge-terminated TLS routes fail on some OpenShift HAProxy versions.

```
http://openrmf-vnc-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/
```

What you'll see:
- Robot icons (colored arrows) moving along paths
- Navigation graph with waypoints and lanes
- Lifts and doors changing state as robots interact with them
- Multiple robots negotiating shared corridors

### Option 2: Dashboard Map (position snapshots)

The rmf-web dashboard shows the hotel map with robot positions. Due to the reverse proxy not supporting WebSocket, positions update on page refresh rather than live streaming.

```
https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/
```

What you'll see:
- Hotel floor plan with robot markers
- Task queue and status (queued → executing → completed)
- Fleet status panel

**Tip:** Refresh the page periodically to see updated positions.

### Option 3: CLI Fleet State Stream (text-based, fully real-time)

Stream raw fleet data including robot positions, battery, and current task:

```bash
# Stream fleet states (Ctrl+C to stop)
$OC_EXEC "$ROS_ENV && ros2 topic echo /fleet_states"

# Check task status
$OC_EXEC "$ROS_ENV && ros2 topic echo /task_api_responses --once"
```

### Option 4: REST API (programmatic)

Query the API server directly for fleet and task data:

```bash
# Get all fleets and robot positions
curl -sk https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/fleets

# Get all tasks and their statuses
curl -sk https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/tasks
```

---

## Full Demo Script (Copy-Paste)

Run this sequence for an impressive demo showing multi-robot coordination.

### One-Time Setup (paste once into your terminal)

```bash
export NAMESPACE="lokesh-ros2-openrmf-demo"
export OC_EXEC="oc -n $NAMESPACE exec deployment/openrmf-hotel -- bash -c"
export ROS_ENV="export HOME=/tmp/ros-home && source /opt/ros/jazzy/setup.bash && source /opt/rmf_demos/install/setup.bash"
```

### Individual Tasks (paste any one to dispatch)

```bash
# Patrol: tinyBot (lobby → restaurant → shop, 2 rounds)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol -p lobby restaurant shop -n 2 --use_sim_time"

# Patrol: deliveryBot (kitchen → restaurant, 2 rounds)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol -p kitchen restaurant -n 2 --use_sim_time"

# Clean: cleanerBot cleans the lobby
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_clean -cs clean_lobby --use_sim_time"

# Clean: cleanerBot cleans the restaurant
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_clean -cs clean_restaurant --use_sim_time"

# Cross-floor: deliveryBot uses lift to reach L3 (impressive!)
$OC_EXEC "$ROS_ENV && ros2 run rmf_demos_tasks dispatch_patrol -p kitchen L3_master_suite -n 1 --use_sim_time"
```

### Launch All Tasks at Once (maximum wow factor)

```bash
$OC_EXEC "$ROS_ENV && \
  ros2 run rmf_demos_tasks dispatch_patrol -p lobby restaurant shop -n 2 --use_sim_time & \
  sleep 2 && \
  ros2 run rmf_demos_tasks dispatch_patrol -p kitchen restaurant -n 2 --use_sim_time & \
  sleep 2 && \
  ros2 run rmf_demos_tasks dispatch_clean -cs clean_lobby --use_sim_time & \
  wait"
```

### Watch Robots Move

```bash
# Open noVNC in browser (MUST use HTTP, not HTTPS):
echo "http://openrmf-vnc-$NAMESPACE.apps.<cluster-domain>/"

# Dashboard (task status, map view):
echo "https://openrmf-dashboard-$NAMESPACE.apps.<cluster-domain>/"
```

> **Note:** If robots don't move (tasks stuck in "queued"), batteries may be depleted.
> Fix: `oc -n $NAMESPACE rollout restart deployment/openrmf-hotel` (resets simulation fresh).

## Key Technologies

| Component | Technology |
|-----------|-----------|
| Simulation | Gazebo (headless) + slot car plugin |
| Fleet Management | Open-RMF (traffic schedule, task dispatch, door/lift supervisors) |
| Fleet Adapters | rmf_demos_fleet_adapter (Python, REST-based) |
| Dashboard | rmf-web (React + FastAPI) |
| Communication | ROS 2 DDS (localhost, single pod) |
| Container | Ubuntu 24.04 + ROS 2 Jazzy |

## Resource Requirements

| Resource | Requests | Limits |
|----------|----------|--------|
| CPU | 6 cores | 12 cores |
| RAM | 8 GB | 16 GB |
| GPU | None | None |
| Disk (image) | ~5-8 GB | — |

RViz2 with software rendering (LLVMpipe) consumes ~120% CPU. The extra headroom prevents Xvnc from being starved and dropping VNC connections.

## Known Issues & Fixes Baked In

| Issue | Root Cause | Fix Applied |
|-------|-----------|-------------|
| noVNC shows "connection closed" | Xvnc default 60fps overwhelms VNC protocol when RViz2 renders via software | `-FrameRate 5 -CompareFB 1` on Xvnc |
| noVNC "Something went wrong" immediately | Xvnc blacklists IPs after repeated aborted connections (HAProxy health checks) | `-BlacklistThreshold 0` on Xvnc |
| WebSocket upgrade hangs (HTTPS) | HAProxy edge TLS termination breaks WebSocket on some clusters | Use HTTP (not HTTPS) for noVNC; route has `insecureEdgeTerminationPolicy: Allow` |
| VNC shows black screen | RViz2 window not managed without WM | `openbox` starts before RViz2 |
| WebSocket fails through route | HAProxy needs explicit WebSocket support | `haproxy.router.openshift.io/websocket: "true"` annotation |
| Robots don't move (tasks queued) | Battery depleted after long sim runtime | Restart pod to reset simulation fresh |
| Dashboard not real-time | Reverse proxy doesn't support socket.io WebSocket | Refresh page to see updated positions |

---

## Troubleshooting Guide

### noVNC Not Connecting / "Something went wrong, connection is closed"

**Symptoms:** The noVNC page loads but shows "Something went wrong, connection is closed" or hangs on "Connecting..."

**Most common cause:** Using HTTPS instead of HTTP. WebSocket upgrades through edge-terminated TLS fail on this cluster. **Always use `http://` (not `https://`) for the noVNC URL.**

**Second most common cause:** Xvnc IP blacklisting from too many aborted connections (e.g., HAProxy health checks). The entrypoint now includes `-BlacklistThreshold 0` to prevent this.

**Diagnosis:**

```bash
# 1. Check if Xvnc is running
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- \
  bash -c 'pgrep -a Xvnc && netstat -tlnp | grep 5900'

# 2. Check websockify
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- \
  bash -c 'pgrep -a websockify && netstat -tlnp | grep 6080'

# 3. Check websockify logs for "Connection reset by peer"
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- \
  bash -c 'cat /tmp/ws*.log 2>/dev/null'

# 4. Test WebSocket handshake externally
curl -sk -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" --max-time 5 -D - \
  http://openrmf-vnc-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/websockify | head -8
# Expected: HTTP/1.1 101 Switching Protocols + "RFB 003.008"
```

**Common fixes:**

```bash
# If Xvnc is dead — restart it with frame rate limiting
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- bash -c '
  Xvnc :99 -geometry 1280x800 -depth 24 -rfbport 5900 \
    -SecurityTypes None -ac -pn -AlwaysShared \
    -FrameRate 5 -CompareFB 1 &
  sleep 2 && pgrep Xvnc && echo "Xvnc started"'

# If websockify is dead — restart it
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- bash -c '
  nohup /usr/bin/python3 /usr/bin/websockify --web /usr/share/novnc 6080 localhost:5900 &
  sleep 1 && netstat -tlnp | grep 6080'

# If RViz2 is dead — restart it (openbox must be running)
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- bash -c '
  export HOME=/tmp/ros-home DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1 MESA_GL_VERSION_OVERRIDE=3.3
  source /opt/ros/jazzy/setup.bash && source /opt/rmf_demos/install/setup.bash
  pgrep openbox || openbox &
  nohup rviz2 -d /opt/rmf_demos/install/rmf_demos/share/rmf_demos/include/hotel/hotel.rviz \
    --ros-args -p use_sim_time:=true &'

# If route is broken — ensure WebSocket annotation exists
oc -n lokesh-ros2-openrmf-demo annotate route openrmf-novnc \
  haproxy.router.openshift.io/websocket=true --overwrite
```

### VNC Connected But Black Screen

**Root cause:** RViz2 started before the window manager (`openbox`), so its window isn't mapped.

```bash
# Check if openbox is running
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- pgrep -a openbox

# If not running, start it then restart RViz2
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- bash -c '
  export DISPLAY=:99 HOME=/tmp/ros-home
  openbox &
  sleep 1
  kill $(pgrep rviz2) 2>/dev/null
  sleep 2
  source /opt/ros/jazzy/setup.bash && source /opt/rmf_demos/install/setup.bash
  export LIBGL_ALWAYS_SOFTWARE=1 MESA_GL_VERSION_OVERRIDE=3.3
  nohup rviz2 -d /opt/rmf_demos/install/rmf_demos/share/rmf_demos/include/hotel/hotel.rviz \
    --ros-args -p use_sim_time:=true &'
```

### Robots Not Moving (Tasks Stuck in Queue)

**Root cause:** Battery depleted. The Hotel demo simulates battery drain; after ~30 min of sim time, robots reach low battery and refuse new tasks.

```bash
# Check battery levels
curl -sk https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/fleets | \
  python3 -c "
import sys, json
for f in json.load(sys.stdin):
    print(f['name'])
    for r,d in f.get('robots',{}).items():
        print(f'  {r}: battery={d.get(\"battery\",\"?\")}% status={d.get(\"status\")}')
"

# Fix: restart the pod to reset simulation (batteries start at 100%)
oc -n lokesh-ros2-openrmf-demo rollout restart deployment/openrmf-hotel
```

### Task Dispatch Returns "waypoint not found"

**Root cause:** Using waypoint names that don't exist in the fleet's navigation graph.

```bash
# Get actual waypoints from the building map
curl -sk https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/building_map | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for level in data.get('levels', []):
    print(f'Level: {level[\"name\"]}')
    for g in level.get('nav_graphs', []):
        names = [v['name'] for v in g.get('vertices',[]) if v.get('name')]
        if names: print(f'  Graph {g[\"name\"]}: {names}')
"
```

Valid waypoints per fleet are documented in the "Available Waypoints" section above.

### Dashboard Shows Login Screen

**Root cause:** Authentication bypass not applied. The Containerfile patches `api_server/authenticator.py` to bypass JWT. If the patch failed during build, the login screen appears.

```bash
# Verify auth bypass is working
curl -sk https://openrmf-dashboard-lokesh-ros2-openrmf-demo.apps.<cluster-domain>/user
# Should return: {"username":"admin","is_admin":true}
# If it returns 401, the auth bypass wasn't applied in the build
```

### "Unable to retrieve building map images"

**Root cause:** The API server's `public_url` is set to `http://localhost:8000`, causing mixed content errors on HTTPS. The Containerfile patches this to an empty string for relative URLs.

```bash
# Verify the fix
oc -n lokesh-ros2-openrmf-demo exec deployment/openrmf-hotel -- \
  grep public_url /opt/rmf-web/packages/api-server/api_server/default_config.py
# Should show: "public_url": ""
```

## Design Decisions

See [DEMO-REQUIREMENTS.md](DEMO-REQUIREMENTS.md) for full details including:
- Why Hotel world over Office/Airport
- Trade-off analysis: Slot Car vs TurtleBot3 + Nav2
- Why single pod over distributed architecture

## File Structure

```
examples/open-rmf/
├── README.md                 # This file
├── DEMO-REQUIREMENTS.md      # Full requirements & design decisions
├── Containerfile             # Single all-in-one container image
├── entrypoint.sh             # Launches all components
└── k8s/
    └── all-in-one.yaml       # Deployment, service, and routes
```
