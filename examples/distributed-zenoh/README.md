# Example 2: Distributed Multi-Pod Deployment with Zenoh

> **Status:** Planned — see [APPENG-5477]

Splits the simulation and robot autonomy into separate OpenShift pods, connected via [zenoh-bridge-ros2dds](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) sidecars. This demonstrates a production-style distributed ROS2 architecture on Kubernetes.

## Target Architecture

```
┌─── Pod: gazebo-sim ──────────────────┐       ┌─── Pod: robot-nav ──────────────────┐
│                                       │       │                                      │
│  ┌─ Container: gazebo ─────────────┐ │       │  ┌─ Container: nav2 ──────────────┐ │
│  │  Gazebo server (physics)        │ │       │  │  AMCL (localization)            │ │
│  │  ros_gz_bridge                  │ │       │  │  planner_server                 │ │
│  │  robot_state_publisher          │ │       │  │  controller_server              │ │
│  │  Xvfb + noVNC (visualization)  │ │       │  │  bt_navigator                   │ │
│  └─────────────────────────────────┘ │       │  │  map_server                     │ │
│  ┌─ Sidecar: zenoh-bridge ────────┐ │       │  │  velocity_smoother              │ │
│  │  zenoh-bridge-ros2dds           │ │ Zenoh │  │  collision_monitor              │ │
│  │  mode: router                   │◄┼──TCP──┼►│  └────────────────────────────────┘ │
│  │  listen: tcp/0.0.0.0:7447      │ │ 7447  │  ┌─ Sidecar: zenoh-bridge ────────┐ │
│  └─────────────────────────────────┘ │       │  │  zenoh-bridge-ros2dds           │ │
│                                       │       │  │  mode: client                   │ │
└───────────────────────────────────────┘       │  │  connect: tcp/gazebo-sim:7447   │ │
                                                │  └────────────────────────────────┘ │
                                                └──────────────────────────────────────┘
```

## Key Data Flows

**Gazebo --> Robot (sensor inputs):**
- `/scan` (LaserScan), `/odom` (Odometry), `/tf`, `/tf_static`, `/clock`, `/imu`

**Robot --> Gazebo (motor commands):**
- `/cmd_vel` (Twist)

## Prerequisites

- Jianrong's zenoh-bridge-ros2dds sidecar setup (APPENG-5460)
- Working monolithic deployment (Example 1) as baseline

## TODO

- [ ] Split entrypoint into gazebo-side and nav2-side scripts
- [ ] Create Gazebo-only and Nav2-only Containerfiles (or parameterize one image)
- [ ] Create zenoh-bridge-ros2dds configuration (JSON5)
- [ ] Create K8s manifests: two Deployments with zenoh sidecar containers
- [ ] Create K8s Service for zenoh endpoint discovery
- [ ] Validate bidirectional topic flow across pods
- [ ] Validate `/clock` synchronization with `use_sim_time`
- [ ] Performance comparison vs monolithic (latency on `/scan`, `/tf`)
