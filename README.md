# ROS2 on OpenShift — Deployment Examples

Demonstrates deploying ROS2 (Jazzy) with Gazebo simulation on OpenShift, using a Red Hat-family OS (Fedora). Includes infrastructure-as-code for a development VM, container image definitions, OpenShift manifests, and detailed ecosystem documentation.

## Deployment Examples

### [Example 1: Monolithic Single-Pod](examples/monolithic/)

All-in-one deployment — Gazebo simulation, Nav2 navigation stack, and noVNC visualization in a single pod. Uses local DDS for inter-node communication. Best for demos, development, and single-robot scenarios.

```
Pod: [Gazebo + Nav2 + TurtleBot3 + noVNC]  ← everything in one container
```

**Status:** Deployed and working on OpenShift.

### [Example 2: Distributed Multi-Pod with Zenoh](examples/distributed-zenoh/)

Splits simulation and robot autonomy into separate pods connected via `zenoh-bridge-ros2dds` sidecars. Demonstrates a production-style distributed ROS2 architecture where each concern scales independently.

```
Pod A: [Gazebo + zenoh-bridge]  ←── Zenoh TCP ──→  Pod B: [Nav2 + zenoh-bridge]
```

**Status:** Planned (APPENG-5477).

## Development VM (AWS EC2)

OpenTofu configuration to launch an Ubuntu 22.04 EC2 instance with ROS2 Humble, Gazebo, and NICE DCV remote desktop.

| Component | Default |
|-----------|---------|
| Instance type | t3.xlarge (4 vCPU, 16 GB RAM) |
| OS | Ubuntu 22.04 LTS |
| Disk | 50 GB gp3 |
| Region | us-east-1 |

```bash
cd infra
tofu init && tofu apply

# Day-to-day
./start-ros2-vm.sh    # Start the VM
./stop-ros2-vm.sh     # Stop (save costs)
```

## Quick Access (Monolithic Example — Currently Deployed)

**Gazebo visualization (noVNC):**
```
https://ros2-demo-novnc-lokesh-ros2-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com/vnc_lite.html?autoconnect=true&resize=scale
```

**Navigate the robot:**
```bash
oc exec deployment/ros2-sim -n lokesh-ros2-demo -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose \
    "{pose: {header: {frame_id: \"map\"}, pose: {position: {x: -2.5, y: 0.5, z: 0.0}, orientation: {w: 1.0}}}}"'
```

**Direct velocity control:**
```bash
oc exec deployment/ros2-sim -n lokesh-ros2-demo -- bash -c '
  export HOME=/tmp/ros-home; source /usr/lib64/ros-jazzy/setup.bash
  ros2 topic pub /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 0.3}, angular: {z: 0.5}}" -t 20'
```

## Documentation

- [Deploying ROS2 to OpenShift](deploying-ros2-to-openshift.md) — architecture decisions, findings, and implementation details
- [ROS2 Fedora/RHEL Ecosystem Analysis](ros2-fedora-rhel-ecosystem-analysis.md) — gap analysis for running ROS2 on Red Hat platforms

## Repository Structure

```
├── examples/
│   ├── monolithic/                    # Example 1: single-pod deployment
│   │   ├── Containerfile              #   Ubuntu-based image
│   │   ├── Containerfile.fedora       #   Fedora 43 image (active)
│   │   ├── entrypoint.sh             #   Ubuntu entrypoint
│   │   ├── entrypoint-fedora.sh      #   Fedora entrypoint
│   │   ├── worlds/                    #   Gazebo SDF world files
│   │   ├── www/                       #   Web landing page
│   │   └── k8s/                       #   OpenShift manifests
│   └── distributed-zenoh/            # Example 2: multi-pod with Zenoh (planned)
│       └── README.md
├── infra/                             # OpenTofu IaC for AWS dev VM
├── deploying-ros2-to-openshift.md     # Primary documentation
├── ros2-fedora-rhel-ecosystem-analysis.md
├── start-ros2-vm.sh
└── stop-ros2-vm.sh
```
