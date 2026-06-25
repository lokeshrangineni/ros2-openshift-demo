# Example 2: Distributed Multi-Pod Deployment with Zenoh

> Multi-pod ROS2 deployment with zenoh-bridge-ros2dds for cross-pod DDS communication.

Splits the simulation and robot autonomy into separate OpenShift pods, connected via [zenoh-bridge-ros2dds](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) sidecars. This validates bidirectional communication: the robot receives simulated sensor inputs from Gazebo and sends motor commands back.

## Architecture

```
┌─── Pod: gazebo-sim ──────────────────────┐       ┌─── Pod: robot-nav ──────────────────┐
│                                           │       │                                      │
│  ┌─ Container: gazebo ─────────────────┐ │       │  ┌─ Container: nav2 ──────────────┐ │
│  │  Gazebo server (physics + sensors)  │ │       │  │  AMCL (localization)            │ │
│  │  ros_gz_bridge (Gz↔ROS2)           │ │       │  │  planner_server                 │ │
│  │  robot_state_publisher (TF)        │ │       │  │  controller_server              │ │
│  │  Xvfb + VNC + noVNC (port 6080)   │ │       │  │  bt_navigator                   │ │
│  │  Web landing page (port 8080)      │ │       │  │  map_server                     │ │
│  └─────────────────────────────────────┘ │       │  │  velocity_smoother              │ │
│  ┌─ Sidecar: zenoh-bridge ────────────┐ │       │  │  collision_monitor              │ │
│  │  zenoh-bridge-ros2dds              │ │ Zenoh │  └────────────────────────────────┘ │
│  │  mode: router                      │◄┼──TCP──┼► ┌─ Sidecar: zenoh-bridge ────────┐ │
│  │  listen: tcp/0.0.0.0:7447         │ │ 7447  │  │  zenoh-bridge-ros2dds           │ │
│  └─────────────────────────────────────┘ │       │  │  mode: peer                     │ │
│                                           │       │  │  connect: tcp/gazebo-sim:7447   │ │
└───────────────────────────────────────────┘       │  └────────────────────────────────┘ │
                                                    └──────────────────────────────────────┘
```

## Data Flows Bridged via Zenoh

**Gazebo pod --> Robot pod (sensor inputs):**

| Topic | Type | Rate | Description |
|---|---|---|---|
| `/scan` | `sensor_msgs/LaserScan` | ~10 Hz | Lidar from simulated sensor |
| `/odom` | `nav_msgs/Odometry` | ~50 Hz | Wheel odometry |
| `/tf` | `tf2_msgs/TFTransform` | ~50 Hz | Transform tree |
| `/tf_static` | `tf2_msgs/TFTransform` | Latched | Static transforms (robot URDF) |
| `/clock` | `rosgraph_msgs/Clock` | High freq | Simulation time (critical) |
| `/imu` | `sensor_msgs/Imu` | ~100 Hz | IMU data |

**Robot pod --> Gazebo pod (motor commands):**

| Topic | Type | Rate | Description |
|---|---|---|---|
| `/cmd_vel` | `geometry_msgs/Twist` | ~20 Hz | Velocity commands |

## How It Works

1. **Within each pod**, ROS2 nodes communicate via standard DDS (localhost, shared memory). The zenoh-bridge-ros2dds sidecar discovers all local DDS topics automatically.

2. **Between pods**, the bridge translates DDS topics into Zenoh key expressions and routes them over TCP. This solves the "DDS multicast doesn't cross pod boundaries" problem on Kubernetes.

3. **Transparent to ROS2 nodes** — nodes publish/subscribe via DDS as usual. The bridge handles cross-pod routing invisibly.

## Files

```
├── Containerfile.fedora          # Single image for both pods (two entrypoints)
├── entrypoint-gazebo.sh          # Gazebo pod: simulation + viz + ros_gz_bridge
├── entrypoint-nav2.sh            # Nav2 pod: navigation stack only
├── zenoh-bridge-gazebo.json5     # Zenoh bridge config (router mode)
├── zenoh-bridge-nav2.json5       # Zenoh bridge config (peer mode)
├── worlds/                          # Gazebo world files (copied from monolithic)
├── www/                             # Web landing page (copied from monolithic)
└── k8s/
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── configmap-zenoh.yaml      # Zenoh bridge configs as ConfigMap
    ├── deployment-gazebo.yaml    # Gazebo pod + zenoh sidecar
    ├── deployment-nav2.yaml      # Nav2 pod + zenoh sidecar
    ├── service.yaml              # Services: zenoh (7447), noVNC (6080), web (8080)
    └── route.yaml                # OpenShift routes for browser access
```

## Build & Deploy

### 1. Build the container image

```bash
cd examples/distributed-zenoh
podman build --platform linux/amd64 -t ros2-distributed:latest -f Containerfile.fedora .
```

### 2. Push to registry

```bash
podman tag localhost/ros2-distributed:latest quay.io/lrangine/ros2-demo:distributed
podman push quay.io/lrangine/ros2-demo:distributed
```

### 3. Deploy to OpenShift

```bash
oc project lokesh-ros2-distributed-demo

# Apply all manifests
oc apply -f k8s/namespace.yaml
oc apply -f k8s/serviceaccount.yaml
oc apply -f k8s/configmap-zenoh.yaml
oc apply -f k8s/service.yaml
oc apply -f k8s/route.yaml
oc apply -f k8s/deployment-gazebo.yaml
oc apply -f k8s/deployment-nav2.yaml

# Watch rollout
oc rollout status deployment/gazebo-sim
oc rollout status deployment/robot-nav
```

### 4. Verify bidirectional communication

```bash
# Check Gazebo pod is publishing sensor data
oc exec deployment/gazebo-sim -c gazebo -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 topic list'

# Check Nav2 pod receives /scan from Gazebo (via Zenoh)
oc exec deployment/robot-nav -c nav2 -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  timeout 10 ros2 topic echo /scan --once'

# Check Nav2 pod can send /cmd_vel back to Gazebo (via Zenoh)
oc exec deployment/robot-nav -c nav2 -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.2}}" -t 5'
```

## Key Differences from Monolithic Example

| Aspect | Monolithic (Example 1) | Distributed (Example 2) |
|---|---|---|
| **Pods** | 1 pod, 1 container | 2 pods, each with app + zenoh sidecar |
| **Inter-node comms** | Local DDS (shared memory) | DDS within pod, Zenoh between pods |
| **Scalability** | Scale entire simulation | Scale simulation and autonomy independently |
| **Latency** | Minimal (localhost) | Network hop via Zenoh (~1-2ms on same node) |
| **Complexity** | Low | Medium (Zenoh config, split entrypoints) |
| **Image** | `quay.io/lrangine/ros2-demo:fedora` | `quay.io/lrangine/ros2-demo:distributed` |

### 5. Access the simulation

- **noVNC (simulation view):** `https://<novnc-route>.<cluster-domain>`
- **Web landing page:** `https://<web-route>.<cluster-domain>`

### 6. Move the robot (from Nav2 pod via Zenoh)

```bash
oc exec deployment/robot-nav -c nav2 -n lokesh-ros2-distributed-demo -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.3}, angular: {z: 0.5}}" -t 20'
```

## Deployment Details

- **OpenShift namespace:** `lokesh-ros2-distributed-demo`
- **Container image:** `quay.io/lrangine/ros2-demo:distributed`
- **Zenoh bridge image:** `eclipse/zenoh-bridge-ros2dds:latest`
- **Nav2 launch mode:** non-composed (`use_composition:=False`) for reliability in distributed setup

## Known Risks

- **`/clock` latency**: With `use_sim_time:=True`, Nav2 depends on the `/clock` topic from Gazebo. Zenoh adds some latency to clock distribution.
- **`/tf` bridging**: TF is high-frequency and Nav2 is sensitive to TF delays. Monitor for transform timeout warnings.
- **Zenoh bridge image**: Uses `eclipse/zenoh-bridge-ros2dds:latest` — pin to a specific version for production.
