# Example 1: Monolithic Single-Pod Deployment

All-in-one deployment of TurtleBot3 with Nav2 navigation and Gazebo simulation in a single OpenShift pod. Everything runs within one container — Gazebo physics, Nav2 autonomy stack, ROS-Gazebo bridge, and noVNC visualization.

## Architecture

```
┌─── Pod: ros2-sim ──────────────────────────────────┐
│                                                      │
│  ┌─ Container: ros2-sim ─────────────────────────┐  │
│  │  Gazebo server (physics + sensors)             │  │
│  │  ros_gz_bridge                                 │  │
│  │  Nav2 stack (AMCL, planner, controller, BT)    │  │
│  │  robot_state_publisher + map_server            │  │
│  │  Xvfb + openbox + x11vnc + noVNC (port 6080)  │  │
│  │  Web landing page (port 8080)                  │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
└──────────────────────────────────────────────────────┘
```

All ROS2 nodes communicate via local DDS (shared memory), requiring zero network configuration.

## Container Images

| Containerfile | Base Image | Notes |
|---|---|---|
| `Containerfile.fedora` | Fedora 43 + tavie/ros2 Copr | **Currently deployed** |
| `Containerfile` | `osrf/ros:jazzy-simulation` (Ubuntu) | Alternative |

## Build & Deploy

```bash
# Build (Fedora — use --platform linux/amd64 on ARM Macs)
cd examples/monolithic
podman build --platform linux/amd64 -t ros2-gz-fedora:43 -f Containerfile.fedora .

# Push
podman tag localhost/ros2-gz-fedora:43 quay.io/lrangine/ros2-demo:fedora
podman push quay.io/lrangine/ros2-demo:fedora

# Deploy to OpenShift
oc apply -f k8s/
oc rollout restart deployment/ros2-sim -n lokesh-ros2-demo
```

## Access

- **noVNC:** `https://ros2-demo-novnc-lokesh-ros2-demo.apps.<cluster>/vnc_lite.html?autoconnect=true&resize=scale`
- **Web landing page:** `https://ros2-demo-web-lokesh-ros2-demo.apps.<cluster>/`

## Move the Robot

```bash
# Navigate to a position (obstacle-aware)
oc exec deployment/ros2-sim -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose \
    "{pose: {header: {frame_id: \"map\"}, pose: {position: {x: -2.5, y: 0.5, z: 0.0}, orientation: {w: 1.0}}}}"'

# Direct velocity (no obstacle avoidance)
oc exec deployment/ros2-sim -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.3}, angular: {z: 0.5}}" -t 20'
```

## When to Use This Example

- Quick demos and presentations
- Single-robot simulation
- Development and testing
- When you don't need to scale simulation and autonomy independently
