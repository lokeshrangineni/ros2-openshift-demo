# Deploying ROS2 with Gazebo Simulation on OpenShift

## Goal

Demonstrate how OpenShift can serve as a platform for running ROS2 robotics simulations with Gazebo, targeting audiences who want to see how container orchestration applies to the robotics/simulation domain.

---

## Table of Contents

1. [Key Open Questions & Analysis](#1-key-open-questions--analysis)
2. [OS Strategy: RHEL/Fedora vs Ubuntu](#2-os-strategy-rhelfedora-vs-ubuntu)
3. [Gazebo Visualization: How Do Users See the Simulation?](#3-gazebo-visualization-how-do-users-see-the-simulation)
4. [GPU Requirements: Can We Demo Without a GPU?](#4-gpu-requirements-can-we-demo-without-a-gpu)
5. [Demo Application Candidates](#5-demo-application-candidates)
6. [Proposed Architecture on OpenShift](#6-proposed-architecture-on-openshift)
7. [Recommended Path Forward](#7-recommended-path-forward)
8. [Risk Register](#8-risk-register)
9. [Reference Links](#9-reference-links)

---

## 1. Key Open Questions & Analysis

| Question | Short Answer | Details Section |
|----------|-------------|-----------------|
| How can users see the Gazebo simulation? | GzWeb (browser-based) or noVNC | [Section 3](#3-gazebo-visualization-how-do-users-see-the-simulation) |
| Can we run without a GPU? | Yes, with software rendering (Mesa LLVMpipe) | [Section 4](#4-gpu-requirements-can-we-demo-without-a-gpu) |
| Can we run on RHEL/Fedora? | ROS2 yes (RHEL 9), Gazebo no (containers only) | [Section 2](#2-os-strategy-rhelfedora-vs-ubuntu) |
| What demo is the right complexity? | TurtleBot3 with Nav2 navigation | [Section 5](#5-demo-application-candidates) |

---

## 2. OS Strategy: RHEL/Fedora vs Ubuntu

### RHEL Support History: Not New — 5 Years of Sustained Investment

RHEL support is **not a recent addition**. It was introduced in Galactic (May 2021) and has been present in every single ROS2 release since — spanning 5 consecutive releases over 5 years. This is a deliberate, sustained platform commitment defined in [REP 2000](https://www.ros.org/reps/rep-2000.html), the governing document for ROS2 platform targets.

| ROS2 Release | Release Date | RHEL Version | Tier | Status |
|---|---|---|---|---|
| Foxy Fitzroy | May 2020 | **No RHEL** | — | EOL |
| **Galactic Geochelone** | May 2021 | **RHEL 8** | **Tier 2** | EOL (first RHEL support) |
| Humble Hawksbill (LTS) | May 2022 | RHEL 8 | Tier 2 | Active until May 2027 |
| Iron Irwini | May 2023 | RHEL 9 | Tier 2 | EOL |
| Jazzy Jalisco (LTS) | May 2024 | RHEL 9 | Tier 2 | Active until May 2029 |
| Kilted Kaiju | May 2025 | RHEL 9 | Tier 2 | Active until Nov 2026 |
| Rolling Ridley | Ongoing | **RHEL 10** | Tier 2 | Development branch |

**Key observations:**
- RHEL major versions are actively tracked: RHEL 8 → RHEL 9 → RHEL 10 on Rolling
- Rolling already targets RHEL 10, signaling continued support in the next LTS (Lyrical, expected May 2026)
- Tier 2 means real CI testing, official RPM packages, and best-effort bug fixes — not just "community reports it works"
- The ROS2 build farm actively produces RPM packages for every release (Kilted had 95 RHEL binary archive downloads within weeks of release)

**Conclusion: RHEL support is reliable and expected to continue indefinitely.** This is not experimental — it's a core platform target.

### Current State: What's Available on RHEL 9

| ROS2 Distro | Ubuntu | RHEL | Fedora | Support Tier on RHEL |
|-------------|--------|------|--------|---------------------|
| **Humble Hawksbill** (LTS, EOL May 2027) | 22.04 (Tier 1) | RHEL 8 (Tier 2) | Not official | RPM packages available |
| **Jazzy Jalisco** (LTS, EOL May 2029) | 24.04 (Tier 1) | RHEL 9 (Tier 2) | Not official | RPM packages available |
| **Kilted Kaiju** (EOL Nov 2026) | 24.04 (Tier 1) | RHEL 9 (Tier 2) | Not official | RPM packages available |
| **Rolling Ridley** | Latest | RHEL 10 | Not official | RPM packages available |

### RPM Package Availability for Our Demo (Verified)

The ROS2 RHEL 9 repository contains **964+ packages** for Jazzy ([status page](https://repo.ros2.org/status_page/ros_jazzy_rhel.html)). Critically, **every package we need for the TurtleBot3 + Nav2 demo is available as a RHEL 9 RPM**:

| Package Category | Available on RHEL 9? | Example Packages |
|---|---|---|
| **ROS2 Core** | Yes | `ros-jazzy-ros-base`, `ros-jazzy-desktop` |
| **Nav2 (full stack)** | Yes (30+ packages) | `ros-jazzy-nav2-amcl`, `ros-jazzy-nav2-bringup`, `ros-jazzy-nav2-costmap-2d`, `ros-jazzy-nav2-bt-navigator`, etc. |
| **TurtleBot3** | Yes (25+ packages) | `ros-jazzy-turtlebot3-gazebo`, `ros-jazzy-turtlebot3-navigation2`, `ros-jazzy-turtlebot3-simulations`, `ros-jazzy-turtlebot3-teleop` |
| **Gazebo vendor packages** | Yes | `ros-jazzy-gz-sim-vendor`, `ros-jazzy-gz-physics-vendor`, `ros-jazzy-gz-sensors-vendor`, `ros-jazzy-gz-transport-vendor` |
| **ROS-Gazebo bridge** | Yes | `ros-jazzy-ros-gz-bridge`, `ros-jazzy-ros-gz-sim`, `ros-jazzy-ros-gz-image`, `ros-jazzy-ros-gz-interfaces` |
| **Nav2 minimal TB3 sim** | Yes | `ros-jazzy-nav2-minimal-tb3-sim` |

**This is a major discovery**: the `gz_*_vendor` packages and `ros-gz` bridge are available as RHEL 9 RPMs. These are the ROS2-side wrappers that pull in Gazebo as a dependency. This means **we may not need separate Gazebo containers at all** — the ROS2 RPM repo may resolve Gazebo dependencies automatically through the vendor packages.

### Gazebo on RHEL/Fedora: The Hard Part

**Gazebo (Harmonic, Jetty, etc.) has NO official support for RHEL or Fedora.**

The Gazebo maintainers explicitly closed [this request](https://github.com/gazebosim/ros_gz/issues/729) in March 2026 with "no plan from the maintainers to support Fedora or RHEL." There are no RPM packages and no build targets.

### Workarounds for Gazebo on RHEL/Fedora

| Approach | Feasibility | Complexity | Notes |
|----------|-------------|------------|-------|
| **OCI container images (Ubuntu-based)** | High | Low | Official images at `ghcr.io/openrobotics/gazebo:{version}-full`. Works with podman/docker on any host OS. **This is the recommended approach.** |
| **conda-forge / pixi** | Medium | Medium | Cross-platform Gazebo builds exist on conda-forge. Less tested, not official ROS integration. |
| **Build from source on RHEL** | Low | Very High | Dependency hell. Gazebo has ~30 libraries. Not worth the effort for a demo. |
| **Fedora Copr (tavie/ros2)** | Medium | Medium | Community repo for Fedora 41-44. Full Gazebo stack available and verified working (see `ros2-fedora-rhel-ecosystem-analysis.md`). Requires path workarounds due to packaging bugs. |

### Official Pre-Built Container Images (Already Exist)

Before building any custom image, it's important to know that **official ROS2 container images already exist** on Docker Hub, maintained by the Open Source Robotics Foundation (OSRF):

| Image | Contents | Includes Gazebo? | Base OS |
|---|---|---|---|
| `ros:jazzy-ros-base` | Core ROS2 libraries, CLI tools | No | Ubuntu 24.04 |
| `ros:jazzy-perception` | ros-base + perception (OpenCV, PCL, etc.) | No | Ubuntu 24.04 |
| `osrf/ros:jazzy-simulation` | ros-base + **ros_gz_bridge, ros_gz_sim, ros_gz_image, ros_gz_interfaces** | **Yes** | Ubuntu 24.04 |
| `osrf/ros:jazzy-desktop` | ros-base + rviz2, rqt, teleop, tutorials | No | Ubuntu 24.04 |
| `osrf/ros:jazzy-desktop-full` | desktop + perception + **simulation** + gz_sim_demos | **Yes** | Ubuntu 24.04 |

These image variants are defined in [REP 2001](https://ros.org/reps/rep-2001.html) and are rebuilt regularly.

**The `osrf/ros:jazzy-simulation` image is almost exactly what we need** — it already has ROS2 Jazzy + Gazebo Harmonic + the ROS-Gazebo bridge pre-installed. The only things missing for our demo are **Nav2 and TurtleBot3 packages**, which can be added with a simple `apt-get install` layer.

There are also **official Gazebo-only OCI images** at `ghcr.io/openrobotics/gazebo:{version}-full` (Harmonic, Jetty, etc.), but the `osrf/ros:jazzy-simulation` image is more useful since it bundles both ROS2 and Gazebo together.

**Important caveat: All official images are Ubuntu-based (Noble 24.04).** There are no official RHEL/UBI-based ROS2 container images. This is the core tradeoff we need to decide on.

### Recommended OS Strategy: Two Paths

**Path A: Use Official Ubuntu Images (Fast, Easy — Recommended for First Demo)**

```dockerfile
FROM osrf/ros:jazzy-simulation

# Only need to add Nav2 + TurtleBot3 — everything else is pre-installed
RUN apt-get update && apt-get install -y \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-turtlebot3-gazebo \
      ros-jazzy-turtlebot3-simulations \
      ros-jazzy-nav2-minimal-tb3-sim && \
    rm -rf /var/lib/apt/lists/*

ENV LIBGL_ALWAYS_SOFTWARE=1
ENV GALLIUM_DRIVER=llvmpipe
```

- Pros: Minimal custom work. Official, tested, maintained upstream. Fastest path to a working demo.
- Cons: Ubuntu-based. The Red Hat story is limited to "OpenShift orchestrates the workload."
- Demo narrative: "OpenShift is the platform that orchestrates robotics simulations at scale."

**Path B: UBI 9 + RHEL RPMs (Stronger Red Hat Story — Stretch Goal)**

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi

# Install ROS2 + Gazebo + Nav2 + TurtleBot3 entirely from RHEL 9 RPMs
# (see "How RHEL Support Makes OpenShift Deployment Easier" section for full Containerfile)
RUN dnf install -y ... ros-jazzy-ros-base ros-jazzy-gz-sim-vendor \
      ros-jazzy-turtlebot3-gazebo ros-jazzy-nav2-bringup ... && \
    dnf clean all
```

- Pros: All Red Hat stack. Strongest enterprise narrative. UBI vulnerability scanning.
- Cons: Needs validation (gz_vendor RPMs resolving all deps on UBI 9). More work.
- Demo narrative: "ROS2 runs natively on RHEL 9. OpenShift orchestrates. Everything is Red Hat."

**Recommendation: Start with Path A to get a working demo fast, then attempt Path B as a polish step.** If Path B works, switch to it for the final demo — the narrative upgrade is worth it. If it doesn't, Path A is a perfectly good demo on its own.

### How RHEL Support Makes OpenShift Deployment Easier

The fact that ROS2 has official RHEL 9 RPM packages is a **significant advantage** for OpenShift deployment. Here's why:

**1. Native UBI 9 Container Images — No Cross-Distro Hacks**

UBI 9 (Universal Base Image) is RHEL 9 in container form. Since ROS2 Jazzy RPMs target RHEL 9, we can install them directly with `dnf`:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi

# Enable EPEL and CRB repos (required for ROS2 dependencies)
RUN dnf install -y \
      https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    /usr/bin/crb enable

# Add the ROS2 RPM repository
RUN dnf install -y curl && \
    export ROS_APT_SOURCE_VERSION=$(curl -s \
      https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
      | grep -F "tag_name" | awk -F'"' '{print $4}') && \
    dnf install -y \
      "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-release-${ROS_APT_SOURCE_VERSION}-1.noarch.rpm"

# Install ROS2 + Nav2 + TurtleBot3 — all native RHEL 9 RPMs
RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-nav2-bringup \
      ros-jazzy-turtlebot3-gazebo \
      ros-jazzy-turtlebot3-simulations \
      ros-jazzy-ros-gz-bridge \
      ros-jazzy-ros-gz-sim \
      mesa-libGL mesa-dri-drivers && \
    dnf clean all

ENV LIBGL_ALWAYS_SOFTWARE=1
ENV GALLIUM_DRIVER=llvmpipe
```

This is a clean, single-distro container image. No mixing Ubuntu packages into RHEL, no multi-stage cross-distro copies, no library compatibility issues.

**2. OpenShift Entitled Builds — Seamless RPM Access**

OpenShift clusters include RHEL entitlements automatically. This means:
- BuildConfig/Shipwright builds on OpenShift can access full RHEL repos without extra configuration
- The ROS2 RPM repo is a third-party repo (not Red Hat's), so it works without entitlement — it's publicly accessible
- EPEL is also publicly accessible
- **No subscription secrets or entitlement mounting needed** for our use case

**3. Consistent Supply Chain**

Using UBI 9 + RPMs gives us:
- **Vulnerability scanning** via Red Hat's container health index
- **Consistent base** with the OpenShift node OS (RHEL CoreOS)
- **`dnf update`** for security patches without rebuilding from scratch
- **Red Hat-supported base layers** — important for enterprise customers evaluating the demo

**4. The `gz_*_vendor` Packages Are the Key Enabler**

Starting with ROS2 Jazzy, Gazebo integration uses `gz_*_vendor` packages (e.g., `ros-jazzy-gz-sim-vendor`). These are ROS2 packages that **vendorize Gazebo libraries** — they bundle or resolve Gazebo dependencies within the ROS2 packaging system. Since these vendor packages are available as RHEL 9 RPMs, they likely pull in the necessary Gazebo libraries as RPM dependencies.

This needs verification (Phase 1 task), but if it works, the container image is dramatically simpler — a single `dnf install` pulls in everything.

**5. What This Means for the Demo**

| Aspect | Without RHEL RPMs | With RHEL RPMs |
|---|---|---|
| Base image | Ubuntu (foreign to OpenShift) | UBI 9 (native to OpenShift) |
| Package install | `apt-get` | `dnf` (native RHEL tooling) |
| Gazebo integration | Separate container or multi-stage build | Possibly single `dnf install` via vendor packages |
| Supply chain story | "We run Ubuntu containers on OpenShift" | "ROS2 runs natively on RHEL 9, OpenShift orchestrates" |
| Enterprise credibility | Lower | Higher — all Red Hat stack |
| Security scanning | Limited (Ubuntu base on RHEL platform) | Full (UBI base, Red Hat vulnerability data) |

**Bottom line: RHEL RPM support transforms this from "Ubuntu containers on OpenShift" to "ROS2 is a native RHEL workload that OpenShift orchestrates." That's a much stronger demo narrative.**

---

## 3. Gazebo Visualization: How Do Users See the Simulation?

This is the biggest UX challenge. Gazebo is traditionally a desktop GUI application. On OpenShift, there's no display server. Here are the viable options:

### Option A: GzWeb — Browser-Based 3D Visualization (Recommended)

**How it works:** Modern Gazebo (Harmonic/Jetty) includes a `WebsocketServer` system plugin. When enabled, it exposes the simulation state over WebSocket. A JavaScript library ([gzweb](https://github.com/gazebo-web/gzweb)) renders the 3D scene in the browser using Three.js.

**Architecture:**
```
┌─────────────────────────────────────────────────┐
│  OpenShift Pod                                   │
│  ┌──────────────────────┐  ┌──────────────────┐ │
│  │ Gazebo (headless)     │  │  Web App (gzweb) │ │
│  │ + WebsocketServer     │──│  serves static   │ │
│  │   plugin on port 9002 │  │  HTML/JS on 8080 │ │
│  └──────────────────────┘  └──────────────────┘ │
└──────────────────────┬──────────────┬────────────┘
                       │              │
              OpenShift Route   OpenShift Route
              (wss://9002)      (https://8080)
                       │              │
                       └──────┬───────┘
                         User Browser
                    (3D scene rendered via WebGL)
```

**Setup in SDF world file:**
```xml
<plugin name='gz::sim::systems::WebsocketServer'
        filename='gz-sim-websocket-server-system'>
  <port>9002</port>
  <sim_hz>30</sim_hz>
  <max_connections>-1</max_connections>
</plugin>
```

**Pros:**
- Most Kubernetes/OpenShift-native approach
- Lightweight — no desktop environment needed in the container
- Users just open a URL in their browser
- Official Gazebo project feature (not a hack)
- Available hosted at https://app.gazebosim.org/visualization (connect to any WebSocket endpoint)

**Cons:**
- gzweb 3D rendering fidelity is lower than native Gazebo GUI
- Some visual features (particles, advanced materials) may not render
- Relatively new feature (WebSocket server was ported to gz-sim in March 2025)
- Requires building a simple web frontend or using the hosted app.gazebosim.org

**Verdict: This is the recommended approach.** It best demonstrates the cloud-native value proposition.

### Option B: noVNC — Full Desktop in Browser

**How it works:** Run a full Linux desktop environment (XFCE/Openbox) + VNC server (TigerVNC) + noVNC web proxy inside the container. Users access a full desktop via browser where Gazebo GUI runs normally.

**Architecture:**
```
┌──────────────────────────────────────────────────┐
│  OpenShift Pod                                    │
│  ┌────────┐  ┌───────────┐  ┌──────────────────┐│
│  │ Xvfb   │──│ TigerVNC  │──│  noVNC (ws→vnc)  ││
│  │ display │  │ server    │  │  port 6080       ││
│  └───┬────┘  └───────────┘  └──────────────────┘│
│      │                                            │
│  ┌───┴──────────────────────────────────────────┐│
│  │  XFCE Desktop + Gazebo GUI + RViz2           ││
│  └──────────────────────────────────────────────┘│
└──────────────────────────────────────┬───────────┘
                                       │
                                OpenShift Route
                                (https://6080)
                                       │
                                  User Browser
                              (VNC stream in canvas)
```

**Pros:**
- Full-fidelity Gazebo GUI rendering
- Can also show RViz2, terminals, etc. — full desktop experience
- Proven pattern (many examples of noVNC on Kubernetes/OpenShift)
- Simpler to set up if you already have a working Gazebo desktop container

**Cons:**
- Heavy — requires full desktop environment in the container (larger image, more RAM/CPU)
- VNC-based streaming has noticeable latency
- Less "cloud-native" — basically just a remote desktop in a container
- Doesn't demonstrate the architectural advantages of OpenShift as well
- Resolution and frame rate limitations

**Verdict: Good fallback option.** Use this if gzweb proves too limited for the demo visuals, or as a secondary access method for debugging.

### Option C: Headless Simulation + Custom ROS2 Web Dashboard

**How it works:** Run Gazebo completely headless. Subscribe to ROS2 camera/sensor topics and stream them to a custom web dashboard via rosbridge WebSocket.

**Architecture:**
```
┌──────────────────────────────────────────────────┐
│  Gazebo Pod (headless)                            │
│  gz sim -s --headless-rendering world.sdf         │
│  Publishes: /camera, /lidar, /odom, /cmd_vel      │
└──────────────────────┬───────────────────────────┘
                       │ DDS (ROS2 topics)
┌──────────────────────┴───────────────────────────┐
│  ROS2 Bridge Pod                                  │
│  rosbridge_websocket + image compression          │
│  Exposes ROS2 topics via WebSocket on port 9090   │
└──────────────────────┬───────────────────────────┘
                       │ WebSocket
┌──────────────────────┴───────────────────────────┐
│  Web Dashboard Pod (React/Vue app)                │
│  Displays: camera feed, map, robot status, etc.   │
└──────────────────────────────────────────────────┘
```

**Pros:**
- Most architecturally interesting — shows microservices pattern
- Custom dashboard can be tailored to the demo narrative
- Lightest on resources (no 3D rendering in browser)
- Best for showing camera feeds, sensor data, robot telemetry

**Cons:**
- No 3D world visualization (only 2D sensor data feeds)
- Significant development effort to build the web dashboard
- Less visually impressive unless you invest in the frontend

**Verdict: Too much custom development for a first demo.** But elements of this (rosbridge + camera streaming) can complement Option A.

### Visualization Recommendation

**Start with Option A (gzweb)** for the primary demo. If it doesn't provide enough visual impact, augment with a camera feed from ROS2 topics, or fall back to Option B (noVNC) for full Gazebo GUI access.

---

## 4. GPU Requirements: Can We Demo Without a GPU?

### Short Answer: Yes, With Caveats

Gazebo supports CPU-only software rendering via Mesa 3D's LLVMpipe driver. This is a well-established approach.

### How Software Rendering Works

Set these environment variables in the container:
```bash
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
```

The Mesa LLVMpipe driver performs all OpenGL operations on the CPU using LLVM JIT compilation. It supports OpenGL 4.5+ which is sufficient for Gazebo's OGRE2 renderer.

### Performance Expectations Without GPU

| Scenario | CPU-Only Performance | Notes |
|----------|---------------------|-------|
| Simple world (few models, no cameras) | Smooth, real-time | Perfectly fine for demo |
| TurtleBot3 in a small world | Usable, 10-30 FPS | Acceptable for demo |
| Camera sensors rendering | Slow, 2-10 FPS per camera | Noticeable lag |
| Complex worlds (many models, lighting) | Very slow | Avoid for demo |
| Multiple camera sensors | Very slow | Limit to 1 camera if needed |

### Recommendation for the Demo

**A no-GPU demo is viable** under these conditions:
- Use a simple world (small room/warehouse with few objects)
- Limit camera sensors to one, or prefer LiDAR (LiDAR doesn't need GPU rendering)
- Use `--headless-rendering` with EGL if running server-only
- Choose Gazebo Harmonic or newer (better software rendering support)
- Allocate generous CPU (4+ cores) for the simulation pod

### If GPU Is Available (Nice to Have, Not Required)

If the OpenShift cluster has GPU nodes (NVIDIA), you can use the NVIDIA GPU Operator:
1. Install NVIDIA GPU Operator on OpenShift
2. Request GPU resources in the pod spec: `nvidia.com/gpu: 1`
3. Rendering will be hardware-accelerated

This would make the demo smoother and more visually impressive, but **it is not required** for a basic demo.

---

## 5. Demo Application Candidates

### Evaluation Criteria
- Visual appeal for a demo audience
- Complexity: not trivial, but not overwhelming
- No GPU requirement (works with software rendering)
- Well-documented and widely used in ROS2 tutorials
- Demonstrates meaningful robotics concepts

### Candidate Comparison

| Demo | Visual Appeal | Complexity | GPU Needed? | Demonstrates |
|------|--------------|------------|-------------|--------------|
| **TurtleBot3 + Nav2** | High | Medium | No | Autonomous navigation, obstacle avoidance, path planning |
| **Diff drive robot + LiDAR** | Medium | Low-Medium | No | Basic control, sensor visualization |
| **Simple talker/listener** | Very Low | Very Low | No | ROS2 pub/sub only, no simulation |
| **Multi-robot fleet** | Very High | High | Possibly | Multi-agent coordination |
| **Robot arm pick-and-place** | High | High | Yes (for camera) | Manipulation, planning |

### Recommended: TurtleBot3 with Nav2 Navigation

**Why this is the sweet spot:**

1. **Just right complexity**: Involves a robot, a world, sensors (LiDAR), path planning, and autonomous movement. Not trivial, but all built on standard ROS2 packages.

2. **No GPU needed**: TurtleBot3's primary sensor is a LiDAR scanner, which doesn't need rendering. Navigation works purely on LiDAR data.

3. **Visually compelling**: Watching a robot autonomously navigate around obstacles, plan paths, and reach goals is immediately understandable and impressive.

4. **All standard packages**: `nav2_bringup`, `turtlebot3_gazebo`, `turtlebot3_navigation2` — all available as pre-built packages.

5. **Interactive demo potential**: During the demo, you can set navigation goals via ROS2 CLI or a simple web interface, showing real-time interaction with the simulation running on OpenShift.

**Demo flow:**
1. Show the OpenShift console with the deployed pods
2. Open the gzweb visualization — audience sees the TurtleBot3 in a simulated environment
3. Send a navigation goal — the robot plans a path and moves autonomously
4. Show ROS2 topic data flowing (optional: rosbridge dashboard showing sensor feeds)
5. Scale up to multiple robots (stretch goal)

### Backup: Diff Drive Robot with LiDAR (Simpler)

If TurtleBot3 + Nav2 proves too heavy for software rendering, fall back to a basic diff drive robot:
- Spawn a simple robot in Gazebo
- Control it via `ros2 topic pub` on `/cmd_vel`
- Visualize LiDAR scan data
- Simpler but less autonomous/impressive

---

## 6. Proposed Architecture on OpenShift

### Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  OpenShift Cluster                                               │
│                                                                   │
│  ┌──────────────── Namespace: ros2-simulation ─────────────────┐ │
│  │                                                              │ │
│  │  ┌─────────────────────────────────────────┐                │ │
│  │  │  Pod: gazebo-sim                         │                │ │
│  │  │  ┌─────────────────────────────────────┐ │                │ │
│  │  │  │ Container: gazebo                    │ │                │ │
│  │  │  │ Image: osrf/ros:jazzy-simulation     │ │                │ │
│  │  │  │   (or UBI 9 + RPMs for RHEL story)   │ │                │ │
│  │  │  │ + Nav2 + TurtleBot3 (apt/dnf layer)  │ │                │ │
│  │  │  │ + WebsocketServer plugin             │ │                │ │
│  │  │  │                                      │ │                │ │
│  │  │  │ Ports: 9002 (websocket)              │ │                │ │
│  │  │  │ Env: LIBGL_ALWAYS_SOFTWARE=1         │ │                │ │
│  │  │  └─────────────────────────────────────┘ │                │ │
│  │  └─────────────────────────────────────────┘                │ │
│  │                                                              │ │
│  │  ┌─────────────────────────────────────────┐                │ │
│  │  │  Pod: gzweb-frontend                     │                │ │
│  │  │  Serves the gzweb visualization app      │                │ │
│  │  │  Port: 8080                              │                │ │
│  │  └─────────────────────────────────────────┘                │ │
│  │                                                              │ │
│  │  ┌──────────────┐  ┌──────────────────────┐                │ │
│  │  │ Service:      │  │ Service:              │                │ │
│  │  │ gazebo-ws     │  │ gzweb-frontend        │                │ │
│  │  │ port: 9002    │  │ port: 8080            │                │ │
│  │  └──────┬───────┘  └──────────┬───────────┘                │ │
│  │         │                      │                             │ │
│  │  ┌──────┴──────────────────────┴──────────┐                │ │
│  │  │  Route: ros2-demo.apps.cluster.example  │                │ │
│  │  │  Exposes both services to the browser   │                │ │
│  │  └────────────────────────────────────────┘                │ │
│  └──────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
```

### Container Image Strategy

**Option 1 (Recommended for first demo): Official `osrf/ros:jazzy-simulation` + Nav2/TB3**

The simplest path — extend the official image that already has ROS2 + Gazebo:

```dockerfile
FROM osrf/ros:jazzy-simulation

RUN apt-get update && apt-get install -y \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-turtlebot3-gazebo \
      ros-jazzy-turtlebot3-simulations \
      ros-jazzy-nav2-minimal-tb3-sim \
      mesa-utils && \
    rm -rf /var/lib/apt/lists/*

ENV LIBGL_ALWAYS_SOFTWARE=1
ENV GALLIUM_DRIVER=llvmpipe
ENV TURTLEBOT3_MODEL=waffle
```

This is Ubuntu-based but gets us to a working demo fastest.

**Option 2 (Stronger Red Hat story): UBI 9 + RHEL RPMs**

All-RHEL container using the official Jazzy RPMs:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi

RUN dnf install -y \
      https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    /usr/bin/crb enable && \
    dnf install -y curl && \
    export ROS_APT_SOURCE_VERSION=$(curl -s \
      https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
      | grep -F "tag_name" | awk -F'"' '{print $4}') && \
    dnf install -y \
      "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-release-${ROS_APT_SOURCE_VERSION}-1.noarch.rpm" && \
    dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-nav2-bringup \
      ros-jazzy-turtlebot3-gazebo \
      ros-jazzy-turtlebot3-simulations \
      ros-jazzy-ros-gz-bridge \
      ros-jazzy-ros-gz-sim \
      ros-jazzy-gz-sim-vendor \
      mesa-libGL mesa-dri-drivers && \
    dnf clean all

ENV LIBGL_ALWAYS_SOFTWARE=1
ENV GALLIUM_DRIVER=llvmpipe
ENV ROS_DISTRO=jazzy
```

This needs validation — the `gz_*_vendor` RPMs may or may not resolve all Gazebo shared library dependencies cleanly on UBI 9. Test this in Phase 1.

### Resource Requirements (Estimated)

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-----------|----------|---------------|-------------|
| gazebo-sim pod | 2 cores | 4 cores | 2 Gi | 4 Gi |
| gzweb-frontend pod | 0.1 cores | 0.5 cores | 128 Mi | 256 Mi |

These are estimates for a simple TurtleBot3 world with software rendering. Actual usage may vary.

---

## 7. Recommended Path Forward

### Phase 1: Proof of Concept (1-2 weeks)

1. **Start with the official image — get a working demo fast**
   - Pull `osrf/ros:jazzy-simulation` and layer Nav2 + TurtleBot3 on top (see Option 1 Containerfile)
   - This should "just work" since it's the officially supported Ubuntu-based stack

2. **Test locally with podman/docker**
   - Run `gz sim -s --headless-rendering turtlebot3_world.sdf`
   - Connect gzweb via https://app.gazebosim.org/visualization
   - Validate software rendering works (`LIBGL_ALWAYS_SOFTWARE=1`)
   - Verify the 3D scene renders in the browser

3. **Validate the demo flow**
   - Can you send navigation goals?
   - Does LiDAR-based navigation work headless?
   - Is the frame rate acceptable without GPU?

4. **Try the UBI 9 + RPM approach (parallel or after step 1-3)**
   - On a UBI 9 container, run: `dnf install ros-jazzy-gz-sim-vendor ros-jazzy-ros-gz-sim ros-jazzy-turtlebot3-gazebo`
   - Check: do the `gz_*_vendor` RPMs resolve all Gazebo shared libraries?
   - Check: can you run `gz sim` successfully after install?
   - If yes: switch to UBI 9-based image for the final demo (much stronger Red Hat story)
   - If no: proceed with the Ubuntu-based image from steps 1-3

### Phase 2: OpenShift Deployment (1 week)

4. **Create OpenShift manifests** (Deployment, Service, Route)
5. **Push container image** to an internal registry (quay.io or OpenShift internal registry)
6. **Deploy to OpenShift** and validate end-to-end
7. **Tune resource requests** based on actual usage

### Phase 3: Polish & Red Hat Story (1 week)

8. **Refine the container image** — optimize layer caching, minimize image size via multi-stage build
9. **Add demo narrative elements**: OpenShift console walkthrough, scaling demonstration, GitOps deployment
10. **Document the demo script** with talking points emphasizing the native RHEL/UBI story

### Stretch Goals

- Multi-robot simulation (scale the deployment)
- CI/CD pipeline building the container with OpenShift Pipelines (Tekton)
- GitOps deployment with ArgoCD
- Integration with OpenShift AI for ML model serving (e.g., object detection)

---

## 8. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Software rendering too slow for compelling demo | High | Medium | Test early. Fall back to simpler world. Consider GPU node if available. |
| GzWeb visualization quality insufficient | Medium | Medium | Fall back to noVNC approach. Or use rosbridge + camera feed. |
| Gazebo + ROS2 container image too large (>5 GB) | Low | High | Use multi-stage builds. Accept large image for demo (not production). |
| WebSocket routing through OpenShift Route fails | Medium | Low | Test early. May need to use NodePort or configure Route for WebSocket upgrade. |
| `gz_*_vendor` RPMs don't fully resolve Gazebo deps on UBI 9 | Medium | Medium | Test in Phase 1 step 1. Fall back to Ubuntu-based Gazebo OCI image. The vendor RPMs exist but haven't been tested on bare UBI 9. |
| Nav2 navigation fails in headless mode | Medium | Low | Nav2 doesn't need a display. LiDAR processing is purely computational. Should work. |
| DDS multicast issues in OpenShift pod network | Medium | Medium | Use CycloneDDS with unicast configuration. Set `ROS_DOMAIN_ID` per namespace. |

---

## 9. Reference Links

### Official ROS2 Container Images
- [Official ROS Docker images (Docker Hub)](https://hub.docker.com/_/ros) — ros-core, ros-base, perception
- [OSRF ROS Docker images (Docker Hub)](https://hub.docker.com/r/osrf/ros/tags) — simulation, desktop, desktop-full
- [REP 2001 — ROS2 Variants](https://ros.org/reps/rep-2001.html) (defines what's in each image variant)
- [Dockerfiles source repo (osrf/docker_images)](https://github.com/osrf/docker_images/)
- [ROS Jazzy Docker images announcement](https://discourse.openrobotics.org/t/ros-jazzy-docker-images/37879)
- [Nav2 Docker development tutorial](https://docs.nav2.org/tutorials/docs/docker_dev.html)

### ROS2 on RHEL
- [REP 2000 — ROS2 Releases and Target Platforms](https://www.ros.org/reps/rep-2000.html) (the authoritative source for RHEL support history)
- [ROS2 Jazzy on RHEL 9 (RPM install)](http://docs.ros.org/en/jazzy/Installation/RHEL-Install-RPMs.html)
- [ROS2 Kilted on RHEL 9 (RPM install)](https://docs.ros.org/en/ros2_documentation/kilted/Installation/RHEL-Install-RPMs.html)
- [ROS2 Humble on RHEL 8 (RPM install)](http://docs.ros.org/en/ros2_documentation/humble/Installation/RHEL-Install-RPMs.html)
- [ROS2 Jazzy RHEL package status page (964+ packages)](https://repo.ros2.org/status_page/ros_jazzy_rhel.html)
- [ROS2 Jazzy Release Notes (platform support)](https://docs.ros.org/en/jazzy/Releases/Release-Jazzy-Jalisco.html)
- [ROS2 Kilted Release Notes](https://docs.ros.org/en/kilted/Releases/Release-Kilted-Kaiju.html)
- [Platform Support Tiers definition](http://docs.ros.org/en/kilted/The-ROS2-Project/Platform-Support-Tiers.html)

### OpenShift / UBI Container Builds
- [Install RHEL packages in containers using Shipwright](https://developers.redhat.com/articles/2025/01/16/install-rhel-packages-container-images-using-shipwright)
- [Unlocking UBI to RHEL container images](https://developers.redhat.com/articles/2026/03/16/unlocking-ubi-red-hat-enterprise-linux-container-images)
- [Using Red Hat subscriptions in OpenShift builds](http://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/builds_using_buildconfig/running-entitled-builds)
- [Best practices for Red Hat container certification](https://developers.redhat.com/articles/2021/11/11/best-practices-building-images-pass-red-hat-container-certification)

### Gazebo
- [Gazebo OCI container images (official)](https://github.com/openrobotics/gz_oci_images)
- [Gazebo does not support RHEL/Fedora (issue #729)](https://github.com/gazebosim/ros_gz/issues/729)
- [Gazebo headless rendering documentation](https://gazebosim.org/api/gazebo/6/headless_rendering.html)
- [Gazebo WebSocket server for gzweb](https://gazebosim.org/api/sim/10/websocket_server.html)
- [Gazebo web visualization overview](https://gazebosim.org/docs/latest/web_visualization/)

### GzWeb (Browser Visualization)
- [gzweb library (modern Gazebo)](https://github.com/gazebo-web/gzweb)
- [gzweb on npm](https://www.npmjs.com/package/gzweb)
- [Hosted visualization app](https://app.gazebosim.org/visualization)

### Software Rendering
- [Mesa LLVMpipe in Docker (jamesbrink/docker-opengl)](https://github.com/jamesbrink/docker-opengl)
- [Headless Gazebo in Docker (nicolov)](https://github.com/nicolov/gazebo-headless-docker)
- [Chassy simulation containers (CPU fallback docs)](https://docs.chassy.io/reference/simulation-containers-reference)

### noVNC on Kubernetes
- [Micro-VM: noVNC desktop on GKE](https://github.com/Tikam02/Micro-VM)
- [KNIME with VNC on OpenShift](https://github.com/DrSnowbird/knime-vnc-docker)
- [kVDI: Kubernetes-native virtual desktops](https://github.com/aland-zhang/kvdi)

### Red Hat + Robotics Context
- [Red Hat blog: Humanoid robotics on RHEL with ROS2 (Summit 2026)](https://www.redhat.com/en/blog/research-lab-factory-floor-why-humanoid-robots-need-enterprise-grade-foundation)
- [Edge AI LEGO train demo on OpenShift (Summit Connect 2025)](https://github.com/Demo-AI-Edge-Crazy-Train/lego-summit-connect-2025-lab-statement)
- [Robotics K8s infrastructure with KubeEdge + ROS2](https://github.com/sqe/robotics-k8s-infra)

### Demo Examples
- [Nav2 TurtleBot3 getting started](https://docs.nav2.org/getting_started/index.html)
- [ROS2 + Gazebo simulation tutorial (official)](https://docs.ros.org/en/ros2_documentation/humble/Tutorials/Advanced/Simulators/Gazebo/Gazebo.html)
- [Anima ROS2 Sim Net (headless Gazebo + web viewer)](https://github.com/RobotFlow-Labs/anima-ros2-sim-net)

---

## Appendix A: Red Hat Summit 2026 Context

Red Hat is already investing in the ROS2 + RHEL narrative. At Summit 2026, session BO2392 ("The future of embodied AI: Humanoid robotics with Circulus Robotics, Intel, and Red Hat") demonstrates a Unitree G1 humanoid robot running ROS2 on RHEL with Intel Core Ultra processors. This demo aligns with that broader story — showing that OpenShift can be the platform for simulation and development workflows, not just production robot runtime.

## Appendix B: Gazebo Classic vs Modern Gazebo

There are two versions of Gazebo to be aware of:

| | Gazebo Classic | Gazebo (Harmonic, Jetty, etc.) |
|---|---|---|
| **Package names** | `gazebo`, `gazebo-ros-pkgs` | `gz-sim`, `ros-gz` |
| **ROS2 integration** | Via `gazebo_ros_pkgs` (legacy) | Via `gz_*_vendor` packages (official) |
| **Web visualization** | GzWeb (osrf/gzweb, legacy) | GzWeb (gazebo-web/gzweb, active) + WebsocketServer system |
| **Status** | Deprecated, EOL approaching | Actively developed |
| **RHEL support** | No | No (use containers) |

**Recommendation:** Use modern Gazebo (Harmonic) with ROS2 Jazzy. This is the officially supported pairing.

## Appendix C: Existing Infrastructure in This Repo

This repository already contains infrastructure for a ROS2 development VM on AWS:
- **OpenTofu IaC** provisioning a `t3.xlarge` EC2 instance with Ubuntu 22.04
- **ROS2 Humble + Gazebo Classic** installed via provisioners
- **NICE DCV** remote desktop for GUI access
- **Software rendering** already configured (`LIBGL_ALWAYS_SOFTWARE=1`)

The OpenShift demo is a separate effort but can reuse learnings about software rendering and headless operation from this VM setup. The VM can also serve as a development/testing environment for building the container images before deploying to OpenShift.
