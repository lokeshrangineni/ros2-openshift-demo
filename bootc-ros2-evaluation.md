# Bootc Image Layering for ROS2 on Fedora/RHEL

## Executive Summary

This document evaluates the feasibility of layering ROS2 Fedora packages into a bootc-compatible image for deploying ROS2 on real robot hardware. Bootc (bootable containers) represents Red Hat's container-native approach to OS lifecycle management — delivering the entire operating system as an immutable OCI image with atomic updates and rollback capabilities.

> **Note:** Only the **Fedora 43 bootc** path has been validated hands-on (see `examples/bootc/TEST_RESULTS.md`). RHEL 9/10 paths are documented as realistic future options based on research, but have not been tested.

**Key findings:**

- **ROS2 runtime packages can be layered into a bootc image** using standard `dnf install` during the container build. The Fedora `tavie/ros2` Copr repository (5,991 packages on Fedora 43) and official RHEL 9 ROS2 RPMs (964 packages) both work within the bootc build model.
- **Conflicts exist but are manageable.** The primary tensions involve ROS2's plugin loading paths, workspace overlays requiring writable directories, and the Copr packaging bugs (hardcoded BUILDROOT paths). All have workable solutions within the bootc filesystem model.
- **A realistic deployment path exists** using RHEL 10 bootc for production robots (runtime only) or Fedora 43 bootc for development/simulation scenarios.

---

## Table of Contents

1. [What is Bootc?](#1-what-is-bootc)
2. [Bootc Filesystem Model](#2-bootc-filesystem-model)
3. [ROS2 Package Layering: How It Works](#3-ros2-package-layering-how-it-works)
4. [Conflicts Between Bootc and ROS2](#4-conflicts-between-bootc-and-ros2)
5. [Mitigation Strategies](#5-mitigation-strategies)
6. [Realistic Deployment Paths](#6-realistic-deployment-paths)
7. [Proof-of-Concept Containerfiles](#7-proof-of-concept-containerfiles)
8. [Comparison with Alternative Approaches](#8-comparison-with-alternative-approaches)
9. [Recommendations](#9-recommendations)
10. [References](#10-references)

---

## 1. What is Bootc?

Bootc is a transactional, in-place operating system update mechanism that uses OCI/Docker container images as the delivery format for the complete OS — kernel, bootloader, userspace, and applications. Unlike traditional containers that run isolated on a host, a bootc image *becomes* the host OS.

### Key Characteristics

| Aspect | Description |
|--------|-------------|
| **Image format** | Standard OCI container image (built with Podman/Buildah/Docker) |
| **Delivery** | Container registries (Quay.io, GHCR, private registries) |
| **Update mechanism** | `bootc upgrade` — atomic, transactional, with automatic rollback |
| **PID 1** | systemd (not a container runtime) |
| **Immutability** | Root filesystem read-only at runtime; `/etc` and `/var` are writable |
| **Base images** | `quay.io/fedora/fedora-bootc:{42,43,44}`, `registry.redhat.io/rhel10/rhel-bootc` |
| **Disk formats** | ISO, QCOW2, raw, AMI, VMDK, VHD (via `bootc-image-builder`) |

### Why Bootc for Robotics?

Traditional robot deployments suffer from:
- **Configuration drift** across fleet devices
- **Risky updates** that can brick remote hardware
- **Manual intervention** required for recovery

Bootc solves these by:
- Delivering the *entire* OS (including ROS2 stack) as a single versioned artifact
- Providing atomic updates with automatic rollback on boot failure
- Eliminating "works on my machine" through bit-for-bit reproducibility
- Leveraging existing container CI/CD pipelines for OS management

---

## 2. Bootc Filesystem Model

Understanding the bootc filesystem is critical for ROS2 compatibility:

```
/                     ← Read-only at runtime (from container image via composefs/ostree)
├── usr/              ← Immutable. All OS binaries, libraries, systemd units, ROS2 packages.
├── opt/              ← Immutable (same as /usr). Read-only at runtime.
├── etc/              ← Writable, persistent. Machine-local config. 3-way merged on updates.
├── var/              ← Writable, persistent. Data, logs, containers, home dirs.
│                       Content from image is only unpacked at initial install (like VOLUME).
├── tmp/              ← tmpfs (cleared on reboot)
├── boot/             ← Managed by bootc (kernel, initramfs)
└── home → /var/home  ← Symlink to writable area
```

### Critical Rules

| Path | Build time | Runtime | Survives updates? |
|------|-----------|---------|-------------------|
| `/usr/` | Writable | **Read-only** | Replaced entirely |
| `/opt/` | Writable | **Read-only** | Replaced entirely |
| `/etc/` | Writable | Writable | Yes (3-way merge) |
| `/var/` | Writable | Writable | Yes (never touched) |
| Everything else | Writable | **Read-only** | Replaced entirely |

### Implications for Software Installation

- **At build time** (`RUN dnf install ...`): The entire filesystem is writable. Packages install normally.
- **At runtime** (booted system): Only `/etc` and `/var` are writable. Software expecting to write to `/usr`, `/opt`, or other locations will fail.
- **Updates**: `bootc upgrade` replaces everything except `/etc` and `/var`. Any runtime modifications to read-only paths are lost.

---

## 3. ROS2 Package Layering: How It Works

### Build-Time Installation

ROS2 packages from either the official RHEL 9 repo or the Fedora `tavie/ros2` Copr install cleanly at build time:

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

RUN dnf install -y dnf-plugins-core && \
    dnf copr enable -y tavie/ros2

RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-teleop-twist-keyboard && \
    dnf clean all

RUN bootc container lint
```

This works because:
1. The Copr repository is enabled via standard dnf mechanisms
2. RPM packages install to `/usr/lib64/ros-jazzy/` (Fedora 43) which is within the immutable `/usr` tree
3. All shared libraries, plugins, and resource files land in paths that are managed by the container image

### Where ROS2 Packages Install (Fedora 43 Copr)

| Content Type | Install Path | Bootc Behavior |
|-------------|-------------|----------------|
| Binaries | `/usr/lib64/ros-jazzy/bin/` | Immutable ✓ |
| Libraries (`.so`) | `/usr/lib64/ros-jazzy/lib/` | Immutable ✓ |
| Vendor libs (Gazebo) | `/usr/lib64/ros-jazzy/opt/*/lib64/` | Immutable ✓ |
| Share data (models, configs) | `/usr/lib64/ros-jazzy/share/` | Immutable ✓ |
| Plugin descriptors | `/usr/lib64/ros-jazzy/share/*/plugins.xml` | Immutable ✓ |
| Ament index | `/usr/lib64/ros-jazzy/share/ament_index/` | Immutable ✓ |
| setup.bash | `/usr/lib64/ros-jazzy/setup.bash` | Immutable ✓ |

### Where ROS2 Packages Install (RHEL 9/10 Official)

| Content Type | Install Path | Bootc Behavior |
|-------------|-------------|----------------|
| All ROS2 content | `/opt/ros/jazzy/` | Immutable ✓ |

**Key insight:** Both installation paths land in immutable territory, which is exactly what bootc wants — the ROS2 stack is "lifecycle bound" to the OS image. Updates to ROS2 happen by building a new container image, not by running `dnf update` on a live system.

---

## 4. Conflicts Between Bootc and ROS2

### 4.1 Workspace Overlays (Development Use Case)

**The conflict:** ROS2 development relies on `colcon build` which produces a local workspace in a directory structure (e.g., `~/ros2_ws/install/`). Developers "overlay" this workspace on top of the system ROS2 installation by sourcing `install/setup.bash`. This workflow requires:
- A writable directory for the workspace (build artifacts, install tree)
- The ability to chain environment sourcing between underlay (system) and overlay (workspace)

**Impact on bootc:**
- The system ROS2 installation in `/usr/lib64/ros-jazzy/` is read-only — you cannot modify it at runtime
- Building workspaces requires writing to some location
- The ROS2 environment setup scripts (`setup.bash`) source paths that may reference immutable locations

**Severity:** **Medium** — This primarily affects development workflows, not production deployment. On a production robot, you typically deploy pre-built packages rather than building on-device.

### 4.2 ROS2 Plugin Loading (pluginlib)

**The conflict:** ROS2 uses `pluginlib` for dynamic plugin discovery and loading. The mechanism relies on:
1. **Ament resource index** — marker files in `share/ament_index/resource_index/` that register packages
2. **Plugin XML descriptors** — files declaring available plugins and their shared library paths
3. **dlopen()** — runtime loading of `.so` files

**Impact on bootc:**
- All plugin registration files and shared libraries are in immutable paths — this is **fine** for pre-installed packages
- Custom plugins developed on-device would need to be in a writable location with a searchable ament prefix
- The `AMENT_PREFIX_PATH` environment variable controls which prefixes are searched

**Severity:** **Low** — Pre-installed ROS2 plugins work without modification. Custom plugins require proper workspace management (see mitigations).

### 4.3 Gazebo Vendor Package BUILDROOT Bugs (Fedora Copr)

**The conflict:** The `tavie/ros2` Copr packages have hardcoded build-time paths baked into compiled binaries:
```
Binary expects:  /builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build/BUILDROOT/usr/lib64/...
Actual path:     /usr/lib64/ros-jazzy/opt/gz_rendering_vendor/share/gz/...
```

**Impact on bootc:**
- Symlink workarounds (creating `/builddir/build/BUILD/.../BUILDROOT → /`) work at build time
- Since `/` (and therefore `/builddir/...`) is read-only at runtime, these symlinks persist as part of the image
- This is actually **better** on bootc than mutable systems — the symlinks can never be accidentally deleted

**Severity:** **Low** — The same symlink workarounds used in our existing Containerfile work identically in a bootc image. The immutability guarantees they remain intact.

### 4.4 Shared Library Discovery

**The conflict:** ROS2 vendor packages install libraries to non-standard paths (`/usr/lib64/ros-jazzy/opt/*/lib64/`) that are not in the default `ld.so` search path.

**Impact on bootc:**
- The `ldconfig` cache (`/etc/ld.so.cache`) is generated at build time and persists
- Custom config (`/etc/ld.so.conf.d/gz-vendor.conf`) is in `/etc` which is writable
- At runtime, `ldconfig` cache lives in `/var/cache/ldconfig/` (writable) or is embedded in the image

**Severity:** **Low** — Running `ldconfig` at build time resolves this. The cache is baked into the image.

### 4.5 ROS2 Log Files and Runtime State

**The conflict:** ROS2 nodes write various runtime data:
- Log files (default: `~/.ros/log/`)
- Parameter dumps
- Bag recordings
- DDS discovery data

**Impact on bootc:**
- The default `~/.ros/` path resolves to `/var/home/<user>/.ros/` on bootc (writable ✓)
- Alternatively, `ROS_HOME` and `ROS_LOG_DIR` can redirect to `/var/log/ros2/`
- DDS shared memory segments use `/dev/shm` (tmpfs, always writable)

**Severity:** **None** — Standard ROS2 runtime paths already land in writable territory.

### 4.6 ROS2 Parameter Files and Launch Configurations

**The conflict:** Robot-specific parameters (URDF calibration, sensor offsets, map files) often need per-machine customization.

**Impact on bootc:**
- Static parameters baked into the image (in `/usr/`) are fleet-wide and immutable
- Machine-specific overrides need to live in `/etc/ros2/` or `/var/lib/ros2/`
- Launch files may need to check for local parameter overrides

**Severity:** **Low** — Solvable with a parameter overlay pattern (see mitigations).

### 4.7 DDS Configuration

**The conflict:** DDS (the ROS2 communication middleware) requires per-machine network configuration:
- `CYCLONEDDS_URI` or `FASTRTPS_DEFAULT_PROFILES_FILE` pointing to XML config
- Network interface binding
- Discovery peer lists

**Impact on bootc:**
- DDS config files should live in `/etc/cyclonedds/` or similar (writable, persistent)
- Environment variables can reference files in `/etc/`

**Severity:** **None** — This is a standard "/etc is for machine-local config" pattern.

---

## 5. Mitigation Strategies

### 5.1 Development Workspaces on Bootc

For developers building custom ROS2 packages on a bootc system:

**Option A: Build in `/var/lib/ros2_ws/` (Persistent)**
```bash
mkdir -p /var/lib/ros2_ws/src
cd /var/lib/ros2_ws
# Clone and build packages
colcon build --symlink-install
source install/setup.bash
```
- Workspace persists across reboots
- Not affected by OS updates
- Suitable for development robots

**Option B: Use `bootc usr-overlay` (Transient)**
```bash
bootc usr-overlay  # Makes /usr temporarily writable
dnf install ros-jazzy-my-custom-package
# Changes lost on reboot unless committed to a new image
```
- Useful for quick testing
- Not suitable for production

**Option C: Build externally, install via image (Production)**
```dockerfile
# In CI/CD pipeline
FROM quay.io/myorg/ros2-robot-base:latest
COPY --from=builder /ros2_ws/install/ /usr/lib64/ros-jazzy/
```
- The recommended production pattern
- Custom packages are baked into the image
- Tested and versioned together with the OS

### 5.2 Machine-Specific Configuration Pattern

```
/usr/lib64/ros-jazzy/share/my_robot/config/   ← Default params (immutable, from image)
/etc/ros2/my_robot/                           ← Machine-local overrides (writable, persistent)
/var/lib/ros2/maps/                           ← Runtime-generated data (writable, persistent)
```

Launch files should implement a parameter cascade:
```python
# In launch file
import os
default_config = os.path.join(get_package_share_directory('my_robot'), 'config', 'params.yaml')
local_config = '/etc/ros2/my_robot/params_override.yaml'

params = [default_config]
if os.path.exists(local_config):
    params.append(local_config)
```

### 5.3 Systemd Integration for ROS2 Nodes

Bootc expects services to be managed by systemd. ROS2 nodes should run as systemd units:

```ini
# /usr/lib/systemd/system/ros2-navigation.service
[Unit]
Description=ROS2 Navigation Stack
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
Environment="ROS_DOMAIN_ID=42"
Environment="RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
Environment="CYCLONEDDS_URI=/etc/cyclonedds/cyclonedds.xml"
ExecStart=/usr/lib64/ros-jazzy/bin/ros2 launch nav2_bringup navigation_launch.py
StateDirectory=ros2/nav2
LogsDirectory=ros2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

This pattern:
- Automatically creates `/var/lib/ros2/nav2/` for state (via `StateDirectory=`)
- Automatically creates `/var/log/ros2/` for logs (via `LogsDirectory=`)
- Integrates with bootc's lifecycle — starts on boot, restarts on failure

### 5.4 Handling the Copr BUILDROOT Bug

The symlink workaround works identically in bootc builds:

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

# ... install ROS2 packages ...

# Symlinks for hardcoded BUILDROOT paths (baked into immutable image)
RUN mkdir -p /builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build/BUILDROOT && \
    mkdir -p /builddir/build/BUILD/ros-jazzy-gz-ogre-next-vendor-0.0.5-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-ogre-next-vendor-0.0.5-build/BUILDROOT && \
    mkdir -p /builddir/build/BUILD/ros-jazzy-gz-sim-vendor-0.0.10-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-sim-vendor-0.0.10-build/BUILDROOT
```

On a bootc system, these symlinks are part of the immutable image and guaranteed to persist.

---

## 6. Realistic Deployment Paths

> **Tested:** Only Path 2 (Fedora 43 bootc) has been validated end-to-end. Paths 1, 3, and 4 are based on research and documented as future options.

### Path 1: RHEL 10 Bootc — Production Robot Runtime (No Simulation)

**Target:** Production robots running ROS2 navigation, perception, and control stacks on real hardware.

```
┌─────────────────────────────────────────────────────────────┐
│  RHEL 10 bootc image                                         │
│  registry.redhat.io/rhel10/rhel-bootc:latest                 │
│                                                               │
│  + ROS2 Jazzy (official RHEL RPMs, 964 packages)             │
│  + CycloneDDS or FastDDS                                     │
│  + Nav2 runtime (path planning, costmaps, controllers)       │
│  + Custom robot packages (baked in at build time)            │
│  + systemd units for node lifecycle                          │
│  + Hardware drivers (lidar, camera, IMU)                     │
│                                                               │
│  Deployed via: bootc-image-builder → ISO/raw → flash to SBC  │
│  Updated via:  bootc upgrade (atomic, rollback on failure)   │
└─────────────────────────────────────────────────────────────┘
```

**Advantages:**
- Full Red Hat support (RHEL 10 + official ROS2 Tier 2 RPMs)
- Enterprise security scanning and CVE patching
- Atomic updates safe for remote/unattended robots
- `bootc rollback` if an update causes issues

**Limitations:**
- No Gazebo simulation packages (RHEL RPMs don't include Gazebo)
- 964 packages vs. 5,991 on Fedora Copr — some niche packages may be missing

**Best for:** Warehouse AMRs, delivery robots, industrial manipulators — any production deployment where reliability > development convenience.

### Path 2: Fedora 43 Bootc — Development/Simulation (Full Stack)

**Target:** Development robots, simulation testbeds, and CI/CD environments where Gazebo simulation is needed.

```
┌─────────────────────────────────────────────────────────────┐
│  Fedora 43 bootc image                                       │
│  quay.io/fedora/fedora-bootc:43                              │
│                                                               │
│  + ROS2 Jazzy (tavie/ros2 Copr, 5,991 packages)             │
│  + Gazebo Harmonic (via gz_*_vendor packages)                │
│  + Nav2 (full stack including simulation launch files)       │
│  + TurtleBot3 simulation assets                              │
│  + Mesa software rendering (for headless Gazebo)             │
│  + BUILDROOT symlink workarounds                             │
│                                                               │
│  Deployed via: bootc-image-builder → QCOW2/raw              │
│  Updated via:  bootc upgrade                                 │
└─────────────────────────────────────────────────────────────┘
```

**Advantages:**
- Full simulation stack including Gazebo
- Matches our existing proven Containerfile.fedora approach
- 5,991 packages available (everything needed for ROS2 + simulation)
- Good for development robots where you iterate frequently

**Limitations:**
- Community-maintained Copr (no SLA, no guaranteed updates)
- Packaging bugs require workarounds (BUILDROOT symlinks)
- Not RHEL — weaker enterprise story
- Fedora 44+ may not have packages (currently empty Copr)

**Best for:** Development workstations, simulation testbeds, R&D robots, CI runners.

### Path 3: Hybrid — RHEL 10 Bootc + Podman Quadlet for Simulation

**Target:** RHEL 10 base system with Gazebo simulation running as an application container managed by Podman Quadlet.

```
┌─────────────────────────────────────────────────────────────┐
│  RHEL 10 bootc (host OS)                                     │
│  ├── ROS2 Jazzy runtime (native, in /opt/ros/jazzy/)        │
│  ├── DDS, Nav2 runtime, robot drivers                       │
│  ├── systemd units for production ROS2 nodes                │
│  │                                                           │
│  └── Podman Quadlet (application container)                  │
│      └── Gazebo simulation container (Ubuntu-based)          │
│          Connected to host ROS2 via shared DDS domain        │
└─────────────────────────────────────────────────────────────┘
```

**Advantages:**
- Enterprise RHEL base for production runtime
- Simulation available via container (Ubuntu-based Gazebo image)
- Clear separation: production code is native, simulation is containerized
- Quadlet integrates containers with systemd lifecycle

**Limitations:**
- Two different packaging approaches (native + container)
- DDS communication between host and container requires network configuration
- More complex architecture

**Best for:** Organizations that need both RHEL support and occasional simulation access on the same hardware.

### Path 4: Base Bootc Image + Runtime Package Addition (Reducing Image Variants)

**Target:** Organizations that want a single base bootc image for their fleet, with per-robot differentiation at runtime rather than at build time.

#### The Problem

Building a separate bootc image for every robot configuration (different sensors, different ROS2 packages) creates an explosion of image variants to maintain. Ideally, you'd build one base image and add packages at deployment or runtime.

#### Current Reality: What's Possible Today

| Method | How It Works | Persistence | Recommended? |
|--------|-------------|:-----------:|:---:|
| **`bootc usr-overlay` + `dnf install`** | Creates transient writable overlay on `/usr` | Lost on reboot | For debugging only |
| **`dnf --transient`** | Same mechanism, integrated into dnf | Lost on reboot | For debugging only |
| **`dnf-bootc install`** | Appends to local `/var/Containerfile`, rebuilds with podman, switches to new image | Persists across reboot; lost on `bootc upgrade` | Experimental |
| **Local `podman build` + `bootc switch`** | Manual image rebuild on-device then atomic switch | Persists until next upgrade | Yes (with caveats) |
| **Podman Quadlet app containers** | Additional ROS2 features run as containers on the base OS | Fully persistent | **Yes (recommended)** |

#### Why True Runtime Package Addition Is Difficult

Bootc's core design principle is that **the container image defines the entire system state**. The root filesystem (`/usr`, `/opt`, etc.) is read-only at runtime specifically to prevent drift. This is a feature, not a bug — it guarantees that every robot running image `v1.2.3` is identical.

However, this means `dnf install ros-jazzy-slam-toolbox` on a running bootc system will fail with:
```
error: can't create transaction lock on /usr/share/rpm/.rpm.lock (Read-only file system)
```

Persistent local package layering is being [actively developed for DNF5](https://gitlab.com/fedora/bootc/tracker/-/issues/4) (targeted for RHEL 10.1+ timeframe) but is not production-ready today.

#### Recommended Architecture: Base Image + Quadlet Containers

The most robust way to achieve "one base image, different capabilities per robot" today:

```
┌──────────────────────────────────────────────────────────────────┐
│  Bootc Host OS (single base image for entire fleet)               │
│  quay.io/myorg/ros2-robot-base:latest                            │
│                                                                    │
│  Contains:                                                         │
│  ├── ROS2 core (ros-jazzy-ros-base, DDS middleware)              │
│  ├── Hardware drivers (kernel modules, udev rules)               │
│  ├── Podman container runtime                                     │
│  ├── systemd (manages everything)                                │
│  └── Network configuration, security policies                    │
│                                                                    │
│  Per-robot differentiation via Quadlet containers:                │
│  /etc/containers/systemd/  (machine-local, writable, persistent)  │
│  ├── ros2-nav2.container        → Nav2 stack                     │
│  ├── ros2-slam.container        → SLAM toolbox                   │
│  ├── ros2-perception.container  → Camera/LiDAR pipeline          │
│  └── ros2-custom.container      → Robot-specific nodes           │
│                                                                    │
│  Each container:                                                   │
│  - Uses --network=host (DDS discovery works natively)            │
│  - Gets device access via AddDevice=                              │
│  - Auto-updates via podman auto-update (registry-based)          │
│  - Independently versioned and deployable                        │
└──────────────────────────────────────────────────────────────────┘
```

**Example Quadlet file** (`/etc/containers/systemd/ros2-nav2.container`):
```ini
[Unit]
Description=ROS2 Navigation Stack
After=network-online.target

[Container]
Image=quay.io/myorg/ros2-nav2:latest
Network=host
SecurityLabelDisable=true
Volume=/var/lib/ros2/maps:/maps:z
Volume=/etc/cyclonedds:/etc/cyclonedds:ro
Environment=ROS_DOMAIN_ID=42
Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
Environment=CYCLONEDDS_URI=/etc/cyclonedds/cyclonedds.xml
AutoUpdate=registry

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**Fleet differentiation example:**

| Robot Type | Base Image (same for all) | Quadlet Containers (robot-specific) |
|-----------|--------------------------|-------------------------------------|
| Warehouse AMR | `ros2-robot-base:latest` | nav2, slam, fleet-manager |
| Delivery Robot | `ros2-robot-base:latest` | nav2, outdoor-perception, gps |
| Inspection Drone | `ros2-robot-base:latest` | px4-bridge, camera-pipeline |
| Dev/Test Robot | `ros2-robot-base:latest` | nav2, slam, gazebo-sim, rviz2 |

**Advantages:**
- Single base bootc image for the entire fleet
- Per-robot capabilities defined by which Quadlet `.container` files exist in `/etc/`
- Independent update cadence: update Nav2 without touching the base OS or other containers
- `podman auto-update` provides automatic container image updates from registry
- Quadlet files can be deployed via cloud-init, Ansible, or any config management tool
- No on-device image rebuilds needed
- Full hardware access via `AddDevice=` and `--network=host`

**Limitations:**
- Slight container overhead (negligible with `--network=host` and direct device passthrough)
- Container images need to include ROS2 libraries (larger total disk usage)
- DDS communication between containers relies on shared network namespace
- More images to maintain (base + N feature containers) but each is independently versionable

#### Alternative: `dnf-bootc` for On-Device Customization

For simpler scenarios where container orchestration is overkill, [`dnf-bootc`](https://github.com/ericcurtin/dnf-bootc) provides a familiar package-manager experience:

```bash
# On the robot (one-time setup):
sudo /var/dnf-bootc install ros-jazzy-slam-toolbox ros-jazzy-cartographer
# Internally: appends to /var/Containerfile → podman build → bootc switch
# Reboot applies changes. Persists across reboots.
```

This is **experimental** and has caveats:
- Requires podman and sufficient disk space on the robot
- Changes are lost when you `bootc upgrade` to a new base image from the registry
- Build happens on potentially resource-constrained robot hardware
- No official support or SLA

#### Future: DNF5 Persistent Layering (Not Ready Today)

The Fedora/Red Hat teams are developing [persistent local package layering](https://gitlab.com/fedora/bootc/tracker/-/issues/4) for DNF5 that would eventually enable:

```bash
# Future capability (not available yet):
dnf5 --persist install ros-jazzy-slam-toolbox
# Persists across reboots AND survives bootc upgrade
```

This is tracked for the RHEL 10.1+ timeframe and would make bootc behave more like rpm-ostree's package layering feature.

---

## 7. Proof-of-Concept Containerfiles

### 7.1 RHEL 10 Bootc + ROS2 Runtime

```dockerfile
FROM registry.redhat.io/rhel10/rhel-bootc:latest

# Enable EPEL and ROS2 repository
RUN dnf install -y \
      https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm && \
    dnf install -y curl && \
    export ROS_APT_SOURCE_VERSION=$(curl -s \
      https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
      | grep -F "tag_name" | awk -F'"' '{print $4}') && \
    dnf install -y \
      "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-release-${ROS_APT_SOURCE_VERSION}-1.noarch.rpm"

# Install ROS2 runtime packages
RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-cyclonedds \
      ros-jazzy-rmw-cyclonedds-cpp && \
    dnf clean all

# Configure ROS2 environment via systemd environment generator
RUN mkdir -p /usr/lib/environment.d && \
    echo 'ROS_DISTRO=jazzy' > /usr/lib/environment.d/50-ros2.conf && \
    echo 'RMW_IMPLEMENTATION=rmw_cyclonedds_cpp' >> /usr/lib/environment.d/50-ros2.conf && \
    echo 'AMENT_PREFIX_PATH=/opt/ros/jazzy' >> /usr/lib/environment.d/50-ros2.conf && \
    echo 'PATH=/opt/ros/jazzy/bin:$PATH' >> /usr/lib/environment.d/50-ros2.conf

# Create directories for runtime state
RUN echo 'd /var/lib/ros2 0755 - - -' > /usr/lib/tmpfiles.d/ros2.conf && \
    echo 'd /var/log/ros2 0755 - - -' >> /usr/lib/tmpfiles.d/ros2.conf && \
    echo 'd /var/lib/ros2/maps 0755 - - -' >> /usr/lib/tmpfiles.d/ros2.conf

# DDS config location (machine-local, populated at deployment)
RUN mkdir -p /etc/cyclonedds

# Validate bootc compatibility
RUN bootc container lint

# systemd units for ROS2 nodes would be added here or in a derived image
```

### 7.2 Fedora 43 Bootc + Full Simulation Stack

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

# Enable tavie/ros2 Copr
RUN dnf install -y dnf-plugins-core && \
    dnf copr enable -y tavie/ros2

# Install ROS2 + Nav2 + Gazebo
RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-navigation2 \
      ros-jazzy-nav2-bringup \
      ros-jazzy-nav2-minimal-tb3-sim \
      ros-jazzy-teleop-twist-keyboard \
      ros-jazzy-ros-gz-bridge \
      ros-jazzy-ros-gz-sim \
      ros-jazzy-gz-sim-vendor && \
    dnf clean all

# Mesa for software rendering (headless Gazebo)
RUN dnf install -y \
      mesa-libGL mesa-dri-drivers mesa-libEGL && \
    dnf clean all

# Configure Gazebo plugin paths
ENV GZ_SIM_SYSTEM_PLUGIN_PATH=/usr/lib64/ros-jazzy/opt/gz_sim_vendor/lib64/gz-sim-8/plugins \
    GZ_SIM_PHYSICS_ENGINE_PATH=/usr/lib64/ros-jazzy/opt/gz_physics_vendor/lib64/gz-physics-7/engine-plugins \
    GZ_RENDERING_PLUGIN_PATH=/usr/lib64/ros-jazzy/opt/gz_rendering_vendor/lib64/gz-rendering-8/engine-plugins \
    GZ_GUI_PLUGIN_PATH=/usr/lib64/ros-jazzy/opt/gz_gui_vendor/lib64/gz-gui-8/plugins

# Register vendor libraries with ldconfig
RUN for d in /usr/lib64/ros-jazzy/opt/*/lib64; do \
      echo "$d" >> /etc/ld.so.conf.d/gz-vendor.conf; \
    done && ldconfig

# BUILDROOT symlink workarounds
RUN mkdir -p /builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-rendering-vendor-0.0.7-build/BUILDROOT && \
    mkdir -p /builddir/build/BUILD/ros-jazzy-gz-ogre-next-vendor-0.0.5-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-ogre-next-vendor-0.0.5-build/BUILDROOT && \
    mkdir -p /builddir/build/BUILD/ros-jazzy-gz-sim-vendor-0.0.10-build && \
    ln -s / /builddir/build/BUILD/ros-jazzy-gz-sim-vendor-0.0.10-build/BUILDROOT

# ROS2 environment
RUN mkdir -p /usr/lib/environment.d && \
    printf 'ROS_DISTRO=jazzy\nAMENT_PREFIX_PATH=/usr/lib64/ros-jazzy\nPATH=/usr/lib64/ros-jazzy/bin:${PATH}\nLD_LIBRARY_PATH=/usr/lib64/ros-jazzy/lib\nLIBGL_ALWAYS_SOFTWARE=1\nGALLIUM_DRIVER=llvmpipe\n' \
    > /usr/lib/environment.d/50-ros2.conf

# Runtime state directories
RUN echo 'd /var/lib/ros2 0755 - - -' > /usr/lib/tmpfiles.d/ros2.conf && \
    echo 'd /var/log/ros2 0755 - - -' >> /usr/lib/tmpfiles.d/ros2.conf

# Validate
RUN bootc container lint
```

### 7.3 Minimal Base Image + Quadlet Containers (One Image, Many Robots)

This approach builds a slim base bootc image and uses Podman Quadlet for per-robot differentiation:

```dockerfile
# Containerfile.bootc-base — Universal base for all robots
FROM quay.io/fedora/fedora-bootc:43

# Enable tavie/ros2 Copr
RUN dnf install -y dnf-plugins-core && \
    dnf copr enable -y tavie/ros2

# Only install ROS2 core + DDS + container runtime
RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-cyclonedds \
      ros-jazzy-rmw-cyclonedds-cpp \
      podman \
      && dnf clean all

# ROS2 environment for host-level nodes (if any)
RUN mkdir -p /usr/lib/environment.d && \
    printf 'ROS_DISTRO=jazzy\nRMW_IMPLEMENTATION=rmw_cyclonedds_cpp\nAMENT_PREFIX_PATH=/usr/lib64/ros-jazzy\nPATH=/usr/lib64/ros-jazzy/bin:${PATH}\n' \
    > /usr/lib/environment.d/50-ros2.conf

# Enable podman auto-update timer (updates Quadlet containers from registry)
RUN systemctl enable podman-auto-update.timer

# Runtime state directories
RUN echo 'd /var/lib/ros2 0755 - - -' > /usr/lib/tmpfiles.d/ros2.conf && \
    echo 'd /var/lib/ros2/maps 0755 - - -' >> /usr/lib/tmpfiles.d/ros2.conf && \
    echo 'd /var/log/ros2 0755 - - -' >> /usr/lib/tmpfiles.d/ros2.conf

# DDS config location (populated per-machine at deployment)
RUN mkdir -p /etc/cyclonedds

RUN bootc container lint
```

Then deploy Quadlet files to `/etc/containers/systemd/` per-robot (via cloud-init, Ansible, or USB provisioning):

```ini
# /etc/containers/systemd/ros2-nav2.container
[Unit]
Description=ROS2 Navigation Stack
After=network-online.target

[Container]
Image=quay.io/myorg/ros2-nav2:latest
Network=host
SecurityLabelDisable=true
AddDevice=/dev/rplidar0
Volume=/var/lib/ros2/maps:/maps:z
Volume=/etc/cyclonedds:/etc/cyclonedds:ro
Environment=ROS_DOMAIN_ID=42
Environment=RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
Environment=CYCLONEDDS_URI=/etc/cyclonedds/cyclonedds.xml
AutoUpdate=registry

[Service]
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 7.4 Deploying to Hardware

Once built, convert to a bootable disk image:

```bash
# Build the bootc container image
podman build -t quay.io/myorg/ros2-robot:latest -f Containerfile.bootc .

# Push to registry
podman push quay.io/myorg/ros2-robot:latest

# Generate a raw disk image for flashing to robot hardware
sudo podman run --rm -it --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./output:/output \
    -v ./config.toml:/config.toml:ro \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type raw \
    --rootfs ext4 \
    quay.io/myorg/ros2-robot:latest

# Flash to robot's disk (e.g., NVMe on a Jetson, eMMC on a Pi)
sudo dd if=./output/image/disk.raw of=/dev/sdX bs=4M status=progress
```

For fleet updates:
```bash
# On the robot (automatic via systemd timer, or manual):
bootc upgrade

# Or switch to a completely different image:
bootc switch quay.io/myorg/ros2-robot:v2.0
```

---

## 8. Comparison with Alternative Approaches

| Approach | Atomic Updates | Rollback | ROS2 Compat | Hardware Access | Fleet Mgmt | Red Hat Support |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|
| **RHEL bootc** | ✓ | ✓ | ✓ (runtime) | Full (native OS) | Built-in | ✓ |
| **Fedora bootc** | ✓ | ✓ | ✓ (full) | Full (native OS) | Built-in | Community |
| **Ubuntu Core (Snaps)** | ✓ | ✓ | ✓ (via snap) | Via snap slots | Canonical IoT | No |
| **Docker/Podman on RHEL** | Container only | Container only | ✓ | Requires privileges | External | ✓ (host) |
| **Mender/RAUC/SWUpdate** | ✓ | ✓ | ✓ | Full | Separate tool | No |
| **Traditional dnf/apt** | ✗ | ✗ | ✓ | Full | Manual | ✓ (RHEL) |

### Key Differentiators of Bootc for ROS2

1. **No container isolation overhead** — ROS2 runs natively as the OS, with direct hardware access (GPIO, USB, CAN bus, serial ports). No `--privileged` flags or device mounts needed.

2. **Standard container build pipeline** — Use existing Podman/Buildah CI/CD. No new tools to learn beyond the `FROM bootc-base` change.

3. **Registry-based delivery** — Push updates to Quay.io; robots pull atomically. Same infrastructure as application containers.

4. **Tight systemd integration** — ROS2 node lifecycle managed by systemd with watchdogs, dependencies, and resource limits.

---

## 9. Recommendations

### For Production Robots (Today)

**Use RHEL 10 bootc + official ROS2 RHEL RPMs.**

- Start from `registry.redhat.io/rhel10/rhel-bootc:latest`
- Install ROS2 core, Nav2 runtime, custom packages at build time
- Deploy via `bootc-image-builder` → raw/ISO → flash to hardware
- Manage updates via `bootc upgrade` with automatic rollback
- Use systemd units for node lifecycle
- Store maps, calibration data, logs in `/var/lib/ros2/`
- Machine-specific DDS config in `/etc/cyclonedds/`

### For Development/Simulation Robots

**Use Fedora 43 bootc + tavie/ros2 Copr.**

- Start from `quay.io/fedora/fedora-bootc:43`
- Full Gazebo + Nav2 + simulation tooling
- Accept the Copr packaging bugs (apply standard workarounds)
- Use for dev robots and CI simulation runners
- Plan migration to RHEL when packages catch up or Gazebo support improves

### For Incremental Adoption

1. **Start with containerized deployment on existing robots** — Run ROS2 in standard containers to validate the workflow
2. **Move to bootc for new hardware** — When provisioning new robots, use bootc from day one
3. **Build a base image hierarchy** — Create `ros2-robot-base` → `ros2-robot-nav` → `ros2-robot-myproduct` image chain
4. **Implement fleet update infrastructure** — Configure automatic `bootc upgrade` with canary rollout to subset of fleet

### Open Questions for Further Investigation

| Question | Priority | Next Step |
|----------|----------|-----------|
| Do RHEL 10 ROS2 RPMs include `ros-jazzy-navigation2`? | High | Test `dnf install` on RHEL 10 bootc image |
| Can Gazebo vendor packages work on RHEL 10 (if available)? | Medium | Wait for RHEL 10 ROS2 package list to stabilize |
| How does DDS multicast work on bootc with CycloneDDS? | Medium | Test network config in `/etc/cyclonedds/` |
| Can `bootc upgrade` be triggered from a fleet management platform? | Medium | Investigate integration with Ansible/Red Hat Satellite |
| What is the image size impact of full ROS2 + Gazebo on bootc? | Low | Build and measure |
| Does `ros2 bag` recording work correctly with `/var` paths? | Low | Test `ROS_HOME=/var/lib/ros2` |

---

## 10. References

### Bootc Documentation
- [bootc official documentation](https://bootc.dev/bootc/)
- [Building bootc images](https://bootc.dev/bootc/building/guidance.html)
- [Bootc filesystem layout](https://bootc.dev/bootc/filesystem.html)
- [Image layout requirements](https://bootc.dev/bootc/bootc-images.html)

### Red Hat Image Mode
- [Image Mode for RHEL 10 (full documentation)](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/index)
- [Deploying RHEL bootc images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/deploying-the-rhel-bootc-images)
- [Creating disk images with bootc-image-builder](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-by-using-bootc-image-builder)
- [Best practices for building bootable containers](https://developers.redhat.com/articles/2025/02/26/best-practices-building-bootable-containers)
- [Installing RHEL 10 from a bootc image](https://developers.redhat.com/articles/2026/06/05/installing-red-hat-enterprise-linux-10-bootc-image-bootc)

### Fedora Bootc
- [Fedora bootc documentation](https://docs.fedoraproject.org/en-US/bootc/)
- [Getting started with bootable containers](https://fedora.gitlab.io/bootc/docs/bootc/getting-started/)
- [Building derived bootc images](https://fedora.gitlab.io/bootc/docs/bootc/building-containers/)
- [Fedora bootc filesystem layout](https://fedora.gitlab.io/bootc/docs/bootc/filesystem/)
- [Building your own Atomic (bootc) Desktop](https://fedoramagazine.org/building-your-own-atomic-bootc-desktop/)

### ROS2 + OSTree/Bootc Prior Art
- [Fedora Robotics SIG: ROS2 + OSTree](https://hackmd.io/@fedora-robotics-sig/H1uUErR62) — Demonstrates ROS2 on Fedora CoreOS/Silverblue with bootable containers
- [Automatic Deployment of ROS2 to Remote Devices (Discourse)](https://discourse.openrobotics.org/t/automatic-deployment-of-ros2-based-system-to-remote-devices-dual-copy-or-containers/33884)

### Bootc Tooling
- [bootc-image-builder (GitHub)](https://github.com/osbuild/bootc-image-builder)
- [Podman Desktop bootc extension](https://github.com/containers/podman-desktop-extension-bootc)
- [bootc-foundry (derived images for clouds)](https://github.com/osbuild/bootc-foundry)
- [dnf-bootc (package-like UX for bootc)](https://github.com/ericcurtin/dnf-bootc)

### Base Images
- Fedora: `quay.io/fedora/fedora-bootc:43`
- CentOS Stream: `quay.io/centos-bootc/centos-bootc:stream10`
- RHEL 10: `registry.redhat.io/rhel10/rhel-bootc:latest`
- RHEL 9: `registry.redhat.io/rhel9/rhel-bootc:latest`

### ROS2 on RHEL
- [ROS2 Jazzy on RHEL 9 (RPM install)](http://docs.ros.org/en/jazzy/Installation/RHEL-Install-RPMs.html)
- [ROS2 Jazzy RHEL package status (964 packages)](https://repo.ros2.org/status_page/ros_jazzy_rhel.html)
- [REP 2000 — Platform targets](https://www.ros.org/reps/rep-2000.html)

### ROS2 Plugin System
- [Ament resource index](https://github.com/ament/ament_cmake/blob/rolling/ament_cmake_core/doc/resource_index.md)
- [pluginlib tutorial](http://docs.ros.org/en/humble/Tutorials/Beginner-Client-Libraries/Pluginlib.html)

### Edge & Fleet Management
- [The Role of Bootable Containers in Edge Computing (Avassa)](https://avassa.io/articles/the-role-of-bootable-containers-in-edge-computing/)
- [Eclipse Muto — ROS2 declarative orchestrator](https://github.com/eclipse-muto/muto)
- [RHEL for Edge with bootc](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html-single/composing_installing_and_managing_rhel_for_edge_images/index)

---

## Appendix A: Conflict Summary Matrix

| ROS2 Requirement | Bootc Constraint | Conflict? | Resolution |
|-----------------|-----------------|:---------:|------------|
| Install packages to `/usr/lib64/ros-jazzy/` | `/usr` is read-only at runtime | **No** | Packages installed at build time are immutable ✓ |
| Plugin shared libraries (`.so`) loaded via dlopen | Libraries must exist at fixed paths | **No** | Paths are baked into the image at build time ✓ |
| Ament index for package discovery | Index files in `share/ament_index/` | **No** | Static index baked into image ✓ |
| `colcon build` for custom packages | Requires writable install directory | **Yes** | Build in `/var/lib/ros2_ws/` or bake into image |
| Log files (`~/.ros/log/`) | Home dir must be writable | **No** | `/var/home/` is writable ✓ |
| DDS shared memory | `/dev/shm` must be writable | **No** | tmpfs always writable ✓ |
| Per-machine parameters | Robot-specific calibration data | **Mild** | Use `/etc/ros2/` for overrides |
| `ldconfig` cache | Generated library search cache | **No** | Generated at build time, persists in image ✓ |
| Gazebo BUILDROOT symlinks | Need symlinks at runtime | **No** | Symlinks baked into image, guaranteed to persist ✓ |
| Workspace overlays (development) | Need writable workspace directory | **Yes** | Use `/var/lib/` or build externally |
| ROS2 bag recording | Needs writable storage | **No** | Record to `/var/lib/ros2/bags/` ✓ |
| Map server (SLAM-generated maps) | Needs writable map storage | **No** | Store in `/var/lib/ros2/maps/` ✓ |

**Conclusion:** Of 12 identified requirements, only 2 have genuine conflicts (workspace overlays and custom package building), both of which affect development workflows rather than production deployment. All production runtime requirements are fully compatible with bootc's immutable model.

---

## Appendix B: Update Workflow for Robot Fleet

```
┌────────────────────────────────────────────────────────────────┐
│  CI/CD Pipeline (e.g., OpenShift Pipelines, GitHub Actions)     │
│                                                                  │
│  1. Developer pushes code change                                 │
│  2. Pipeline builds new bootc image (podman build)              │
│  3. Runs automated tests (in VM via bootc-image-builder)        │
│  4. Pushes to registry: quay.io/myorg/ros2-robot:v1.2.3        │
└────────────────────────────┬───────────────────────────────────┘
                             │
                    Container Registry
                    (quay.io / GHCR)
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
   │  Robot #1    │   │  Robot #2    │   │  Robot #3    │
   │  (canary)    │   │  (wave 2)   │   │  (wave 3)   │
   │              │   │              │   │              │
   │ bootc upgrade│   │ bootc upgrade│   │ bootc upgrade│
   │ (auto-       │   │ (after       │   │ (after       │
   │  rollback    │   │  canary OK)  │   │  wave 2 OK)  │
   │  on failure) │   │              │   │              │
   └─────────────┘   └─────────────┘   └─────────────┘
```

Each robot:
1. Pulls the new image from the registry
2. Stages the update (downloads in background)
3. Reboots into the new image
4. Runs health checks (systemd `greenboot` or custom)
5. If healthy: marks update successful
6. If unhealthy: automatically rolls back to previous image
