# CLAUDE.md — Project Context for AI Agents

## Project Overview

This repository demonstrates deploying ROS2 (Jazzy) with Gazebo simulation on OpenShift, using a Red Hat-family OS (Fedora). It includes infrastructure-as-code for a development VM, container image definitions for OpenShift deployment, and detailed documentation of ecosystem findings.

## Repository Structure

```
├── deploying-ros2-to-openshift.md # Primary documentation: architecture, strategy, findings
├── ros2-fedora-rhel-ecosystem-analysis.md # Ecosystem gap analysis for ROS2 on Fedora/RHEL
├── README.md # Quick-start guide
├── examples/
│ ├── monolithic/ # Example 1: single-pod (all-in-one) deployment
│ │ ├── Containerfile.fedora # Fedora 43 + tavie/ros2 Copr (active, deployed)
│ │ ├── Containerfile # Ubuntu-based alternative (Path A)
│ │ ├── entrypoint-fedora.sh # Runtime entrypoint for Fedora image
│ │ ├── entrypoint.sh # Runtime entrypoint for Ubuntu image
│ │ ├── worlds/ # Custom Gazebo SDF world files
│ │ ├── www/ # Web landing page served on port 8080
│ │ └── k8s/ # OpenShift manifests (deployment, service, route)
│ └── distributed-zenoh/ # Example 2: multi-pod with zenoh-bridge-ros2dds
│ ├── Containerfile.fedora # Single image for both pods
│ ├── entrypoint-gazebo.sh # Gazebo pod entrypoint
│ ├── entrypoint-nav2.sh # Nav2 pod entrypoint
│ ├── zenoh-bridge-*.json5 # Zenoh bridge configs
│ ├── worlds/ # Gazebo world files
│ ├── www/ # Web landing page
│ └── k8s/ # OpenShift manifests (2 deployments, services, routes)
├── infra/ # OpenTofu IaC for AWS dev VM (ROS2 Humble + Gazebo Classic)
├── start-ros2-vm.sh # Helper to start the AWS dev VM
└── stop-ros2-vm.sh # Helper to stop the AWS dev VM
```

## Key Technical Details

### Example 1: Monolithic Deployment (Fedora 43) — Currently Active

- **Base image:** `registry.fedoraproject.org/fedora:43`
- **ROS2 packages source:** `tavie/ros2` Copr (community-maintained, 5,991 packages)
- **ROS2 install prefix:** `/usr/lib64/ros-jazzy/` (NOT the standard `/opt/ros/jazzy/`)
- **Container registry:** `quay.io/lrangine/ros2-demo:fedora`
- **OpenShift namespace:** `lokesh-ros2-demo`
- **Visualization:** noVNC (vnc_lite.html) via x11vnc + websockify
- **Files:** `examples/monolithic/`

### Example 2: Distributed Zenoh Deployment — Active

- **Architecture:** Gazebo sim pod + Robot nav pod, connected via zenoh-bridge-ros2dds sidecars
- **Jira:** APPENG-5477 (depends on APPENG-5460 for Zenoh sidecar setup)
- **Container registry:** `quay.io/lrangine/ros2-demo:distributed`
- **OpenShift namespace:** `lokesh-ros2-distributed-demo`
- **Zenoh bridge image:** `eclipse/zenoh-bridge-ros2dds:latest`
- **Nav2 launch mode:** non-composed (`use_composition:=False`)
- **Zenoh topology:** Gazebo pod (router mode, listen 7447) ↔ Nav2 pod (peer mode, connect to router)
- **noVNC:** `https://ros2-distributed-novnc-lokesh-ros2-distributed-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com`
- **Web:** `https://ros2-distributed-web-lokesh-ros2-distributed-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com`
- **Files:** `examples/distributed-zenoh/`

### Critical Workarounds (Fedora 43 Copr packaging bugs)

1. **BUILDROOT hardcoded paths** — Ogre2 shaders have build-time paths baked into binaries. Fixed with symlinks:
   - `/builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build/BUILDROOT` → `/`
   - `/builddir/build/BUILD/ros-jazzy-gz-ogre-next-vendor-0.0.5-build/BUILDROOT` → `/`
   - `/builddir/build/BUILD/ros-jazzy-gz-sim-vendor-0.0.10-build/BUILDROOT` → `/`

2. **Plugin/library discovery** — ENV vars must be set explicitly:
   - `GZ_SIM_SYSTEM_PLUGIN_PATH`, `GZ_SIM_PHYSICS_ENGINE_PATH`, `GZ_RENDERING_PLUGIN_PATH`, `GZ_GUI_PLUGIN_PATH`
   - `ldconfig` configured via `/etc/ld.so.conf.d/gz-vendor.conf`

3. **noVNC 1.5.0 bug** — Clipboard handler references null DOM element. Fixed by replacing `index.html` with a redirect to `vnc_lite.html`.

4. **Non-root OpenShift** — Container runs as arbitrary UID; all writable paths go to `/tmp/ros-home/`.

### Fedora Version Compatibility

| Version | Works? | ROS Prefix | Notes |
|---------|--------|------------|-------|
| Fedora 42 | Yes | `/usr/lib64/ros2-jazzy/` | Stable |
| Fedora 43 | Yes | `/usr/lib64/ros-jazzy/` | **Currently deployed** — path and package naming changed |
| Fedora 44 | No | N/A | Copr repo is empty (0 packages built) |

### Build & Deploy Commands (Example 1: Monolithic)

```bash
# Build the image (must use --platform linux/amd64 on ARM Macs)
cd examples/monolithic
podman build --platform linux/amd64 -t ros2-gz-fedora:43 -f Containerfile.fedora .

# Push to registry
podman tag localhost/ros2-gz-fedora:43 quay.io/lrangine/ros2-demo:fedora
podman push quay.io/lrangine/ros2-demo:fedora

# Deploy to OpenShift
oc project lokesh-ros2-demo
oc rollout restart deployment/ros2-sim

# Move the robot
oc exec deployment/ros2-sim -- bash -c "export HOME=/tmp/ros-home && source /usr/lib64/ros-jazzy/setup.bash && ros2 topic pub /cmd_vel geometry_msgs/msg/Twist '{linear: {x: 0.3}, angular: {z: 0.5}}' -t 20"
```

### Access URLs (OpenShift Routes)

- **noVNC simulation view:** `https://ros2-demo-novnc-lokesh-ros2-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com`
- **Web landing page:** `https://ros2-demo-web-lokesh-ros2-demo.apps.ai-dev02.kni.syseng.devcluster.openshift.com`

## Conventions

- Container images target `linux/amd64` architecture
- All documentation is in Markdown at the repo root
- Each example is self-contained under `examples/<name>/` with its own Containerfiles, entrypoints, and K8s manifests
- OpenShift manifests: monolithic uses `lokesh-ros2-demo`, distributed uses `lokesh-ros2-distributed-demo`
- The entrypoint script handles GPU detection and falls back to software rendering (LLVMpipe)
- Gazebo runs in headless server mode; GUI client connects separately for visualization
