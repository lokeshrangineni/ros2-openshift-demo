# ROS2 Gazebo Development VM (AWS EC2)

OpenTofu configuration to launch an Ubuntu 22.04 EC2 instance with ROS2 Humble,
Gazebo, and NICE DCV remote desktop. All setup is done via OpenTofu `remote-exec`
provisioners — no external scripts.

## Instance Specs

| Component | Default |
|-----------|---------|
| Instance type | t3.xlarge (4 vCPU, 16 GB RAM) |
| OS | Ubuntu 22.04 LTS |
| Disk | 50 GB gp3 |
| Region | us-east-1 |
| Cost | ~$0.17/hr |

## Deploy

```bash
cd infra
tofu init
tofu plan
tofu apply
```

## Day-to-day Usage

**Start the VM:**
```bash
./start-ros2-vm.sh
```

**Stop the VM (save costs):**
```bash
./stop-ros2-vm.sh
```

## Connecting

**Cursor Remote-SSH (recommended for development):**
1. Start the VM
2. In Cursor: `Cmd+Shift+P` → "Remote-SSH: Connect to Host"
3. Enter `ubuntu@<PUBLIC_IP>` with the key from `infra/`

**NICE DCV (for Gazebo visuals):**
- The `start-ros2-vm.sh` script generates a one-click token URL

**SSH (terminal):**
```bash
ssh -i infra/<prefix>-ros2-gazebo-dev-key.pem ubuntu@<PUBLIC_IP>
```

## Teardown

```bash
cd infra
tofu destroy
```

## OpenShift ROS2 Simulation Deployment

The project also includes an OpenShift deployment that runs TurtleBot3 with Nav2 navigation
in Gazebo, accessible via a browser through noVNC.

### Access the Simulation

**Gazebo visualization (noVNC):**
```
http://ros2-demo-novnc-lokesh-ros2-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com/vnc.html?autoconnect=true&resize=remote
```

### Navigation Commands

Replace `<pod-name>` with the current pod name (get it with `oc get pods -n lokesh-ros2-demo`).

**Send the robot to a position (obstacle-aware navigation):**
```bash
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose \
    "{pose: {header: {frame_id: \"map\"}, pose: {position: {x: -2.5, y: 0.5, z: 0.0}, orientation: {w: 1.0}}}}"'
```

**Safe goal positions** within the arena (green boxes form a ring):
- `(-2.5, 0.5)`, `(-1.5, -0.5)`, `(-1.0, -0.5)`, `(-2.0, 0.0)`
- Stay within ~1m of center at `(-2.0, -0.5)` to avoid obstacles

**Direct velocity control (no obstacle avoidance):**
```bash
# Move forward
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.2}, angular: {z: 0.0}}" --once'

# Rotate in place
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.0}, angular: {z: 0.5}}" --once'
```

### Troubleshooting

**Check robot position:**
```bash
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  gz model -m turtlebot3_waffle -p'
```

**Check navigation node status:**
```bash
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  ros2 lifecycle get /planner_server
  ros2 lifecycle get /bt_navigator
  ros2 lifecycle get /velocity_smoother
  ros2 lifecycle get /collision_monitor'
```

**Manually set initial pose (if navigation fails on restart):**
```bash
oc exec -n lokesh-ros2-demo <pod-name> -- bash -c '
  export HOME=/tmp/ros-home; source /opt/ros/jazzy/setup.bash
  ros2 topic pub /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
    "{header: {frame_id: \"map\"}, pose: {pose: {position: {x: -2.0, y: -0.5, z: 0.0}, orientation: {w: 1.0}}}}" --once'
```

### Rebuild & Redeploy

```bash
cd openshift
podman build -t ros2-nav2-demo:latest -f Containerfile .
podman tag localhost/ros2-nav2-demo:latest quay.io/lrangine/ros2-demo:latest
podman push quay.io/lrangine/ros2-demo:latest
oc rollout restart deployment/ros2-sim -n lokesh-ros2-demo
oc rollout status deployment/ros2-sim -n lokesh-ros2-demo --timeout=150s
```