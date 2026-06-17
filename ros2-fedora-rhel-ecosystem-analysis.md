# ROS2 on Fedora/RHEL: Ecosystem Analysis & Gaps

## Summary

This document captures findings from our attempt to deploy a ROS2 Jazzy + Gazebo + Nav2 TurtleBot3 simulation on a Red Hat-family OS (targeting OpenShift). The primary goal was to evaluate whether RHEL or Fedora can serve as a viable base OS for ROS2 simulation workloads, comparable to what Ubuntu provides out of the box.

**Bottom line:** We got it working on Fedora 41 using a community Copr repository, but it required significant workarounds for packaging bugs. RHEL 9 alone cannot run this workload due to missing simulation packages in the official repos.

---

## Repository Landscape

### 1. Official ROS2 RHEL 9 Repository

| Attribute | Details |
|-----------|---------|
| **URL** | `http://packages.ros.org/ros2/rhel/9/x86_64/` |
| **Maintainer** | Open Robotics / ROS2 Build Farm |
| **Architecture** | x86_64 only (no aarch64) |
| **Total packages** | ~964 for Jazzy |
| **Tier** | Tier 2 (CI-tested, official RPMs) |

**What's available:**
- ROS2 core (`ros-jazzy-ros-base`, `ros-jazzy-desktop`)
- Basic tooling, middleware, DDS implementations
- Some perception and control packages

**What's missing (critical for simulation):**
| Missing Package | Why It Matters |
|----------------|----------------|
| `ros-jazzy-navigation2` | Full Nav2 stack (path planning, costmaps, behavior trees) |
| `ros-jazzy-nav2-bringup` | Launch files for Nav2 + simulation |
| `ros-jazzy-nav2-minimal-tb3-sim` | TurtleBot3 world/models for the demo |
| `ros-jazzy-turtlebot3-gazebo` | TB3 Gazebo integration |
| `ros-jazzy-turtlebot3-simulations` | TB3 simulation assets |
| `ros-jazzy-ros-gz-bridge` | ROS2-Gazebo communication bridge |
| `ros-jazzy-ros-gz-sim` | ROS2 wrappers for spawning in Gazebo |
| `ros-jazzy-gz-sim-vendor` | Gazebo simulator (vendored build) |

**Conclusion:** The official RHEL 9 repo provides ROS2 core but lacks the simulation and navigation packages needed for any meaningful robotics demo.

### 2. Fedora Copr: `tavie/ros2`

| Attribute | Details |
|-----------|---------|
| **URL** | `https://copr.fedorainfracloud.org/coprs/tavie/ros2/` |
| **Maintainer** | Community member "tavie" (Tavia Kirshenbaum) |
| **Base OS** | Fedora 41-44 |
| **Status** | Active, regularly updated |
| **Official?** | No — community-maintained, not endorsed by Open Robotics |

**What's available (that the official RHEL repo lacks):**
- Full Nav2 stack (`ros-jazzy-navigation2`, `ros-jazzy-nav2-bringup`, etc.)
- Gazebo vendor packages (`ros-jazzy-gz-sim-vendor`, physics, rendering, sensors)
- ROS-Gazebo bridge (`ros-jazzy-ros-gz-bridge`, `ros-jazzy-ros-gz-sim`)
- TurtleBot3 minimal sim (`ros-jazzy-nav2-minimal-tb3-sim`)
- Teleop tools (`ros-jazzy-teleop-twist-keyboard`)

**What's still missing (even in Copr):**
| Missing Package | Impact |
|----------------|--------|
| `ros-jazzy-turtlebot3-gazebo` | Not critical — `nav2-minimal-tb3-sim` provides needed world/models |
| `ros-jazzy-turtlebot3-simulations` | Not critical — same as above |

### 3. Official Gazebo Repositories

**There are no official Gazebo RPMs for Fedora or RHEL.** The Gazebo maintainers explicitly stated in [gazebosim/ros_gz#729](https://github.com/gazebosim/ros_gz/issues/729) (March 2026): *"no plan from the maintainers to support Fedora or RHEL."*

The only officially supported platforms for Gazebo are:
- Ubuntu (apt packages via `packages.osrfoundation.org`)
- macOS (Homebrew)
- Source builds (any platform, extremely complex)

### 4. Fedora Native Repositories

Fedora's official repos do **not** contain modern Gazebo (Harmonic/Jetty/gz-sim). They contain legacy Gazebo Classic (gazebo11) which is EOL and incompatible with modern ROS2.

---

## Fedora Copr Packaging: Known Issues & Workarounds

The `tavie/ros2` Copr packages have several packaging bugs that required workarounds in our deployment. These stem from hardcoded build-time paths that leak into the installed binaries and config files.

### Issue 1: Non-Standard Install Prefix

| Aspect | Ubuntu (official) | Fedora Copr |
|--------|-------------------|-------------|
| **Install path** | `/opt/ros/jazzy/` | `/usr/lib64/ros2-jazzy/` |
| **setup.bash** | `/opt/ros/jazzy/setup.bash` | `/usr/lib64/ros2-jazzy/setup.bash` |
| **Share directory** | `/opt/ros/jazzy/share/` | `/usr/lib64/ros2-jazzy/share/` |

**Impact:** Any script or config that hardcodes `/opt/ros/jazzy/` will fail.
**Workaround:** Set `ROS_PREFIX=/usr/lib64/ros2-jazzy` environment variable and use it in entrypoint scripts.

### Issue 2: Gazebo Plugin Discovery Failure

The Gazebo vendor packages install plugins to non-standard paths that the `gz sim` binary cannot find by default.

| Plugin Type | Expected Path (by binary) | Actual Install Path |
|-------------|--------------------------|---------------------|
| System plugins | Standard `lib/gz-sim-8/plugins/` | `/usr/lib64/ros2-jazzy/opt/gz_sim_vendor/lib64/gz-sim-8/plugins/` |
| Physics engine | Standard lookup | `/usr/lib64/ros2-jazzy/opt/gz_physics_vendor/lib64/gz-physics-7/engine-plugins/` |
| Rendering engine | Standard lookup | `/usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/lib64/gz-rendering-8/engine-plugins/` |
| GUI plugins | Standard lookup | `/usr/lib64/ros2-jazzy/opt/gz_gui_vendor/lib64/gz-gui-8/plugins/` |

**Impact:** Gazebo crashes at startup: `Failed to load system plugin [gz-sim-physics-system] : Could not find shared library.`
**Workaround:** Set environment variables:
```bash
GZ_SIM_SYSTEM_PLUGIN_PATH=/usr/lib64/ros2-jazzy/opt/gz_sim_vendor/lib64/gz-sim-8/plugins
GZ_SIM_PHYSICS_ENGINE_PATH=/usr/lib64/ros2-jazzy/opt/gz_physics_vendor/lib64/gz-physics-7/engine-plugins
GZ_RENDERING_PLUGIN_PATH=/usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/lib64/gz-rendering-8/engine-plugins
GZ_GUI_PLUGIN_PATH=/usr/lib64/ros2-jazzy/opt/gz_gui_vendor/lib64/gz-gui-8/plugins
```

### Issue 3: Hardcoded BUILDROOT Paths in Binaries

The most serious packaging bug. Compiled binaries reference the Fedora build farm's `BUILDROOT` directory instead of the actual install path:

```
Expected by binary:  /builddir/build/BUILD/ros2-jazzy-gz_rendering_vendor-0.0.6-build/BUILDROOT/usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/share/gz/gz-rendering8/ogre2/src/media/Hlms/Unlit/GLSL
Actual file location: /usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/share/gz/gz-rendering8/ogre2/media/Hlms/Unlit/GLSL
```

This affects at least three packages:
- `gz_rendering_vendor` (Ogre2 shader resources)
- `gz_ogre_next_vendor` (Ogre2 rendering library)
- `gz_sim_vendor` (server.config path)

**Impact:** Gazebo segfaults during rendering initialization.
**Workaround:** Create symlinks to make the broken paths resolve:
```dockerfile
RUN mkdir -p /builddir/build/BUILD/ros2-jazzy-gz_rendering_vendor-0.0.6-build && \
    ln -s / /builddir/build/BUILD/ros2-jazzy-gz_rendering_vendor-0.0.6-build/BUILDROOT && \
    mkdir -p /usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/share/gz/gz-rendering8/ogre2/src && \
    ln -s ../media /usr/lib64/ros2-jazzy/opt/gz_rendering_vendor/share/gz/gz-rendering8/ogre2/src/media
```

### Issue 4: Shared Library Resolution

All vendor packages install their libraries under isolated paths (`/usr/lib64/ros2-jazzy/opt/*/lib64/`) that are not in the system's default library search path.

**Impact:** Plugins fail to load at runtime with "cannot open shared object file" errors.
**Workaround:** Register all vendor lib directories with `ldconfig`:
```dockerfile
RUN for d in /usr/lib64/ros2-jazzy/opt/*/lib64; do
      echo "$d" >> /etc/ld.so.conf.d/gz-vendor.conf
    done && ldconfig
```

---

## Side-by-Side Comparison: Ubuntu vs Fedora Deployment

| Dimension | Ubuntu (Path A) | Fedora (Path B) |
|-----------|----------------|-----------------|
| **Base image** | `osrf/ros:jazzy-simulation` | `registry.fedoraproject.org/fedora:41` |
| **Package source** | Official OSRF apt repos | Community Copr (`tavie/ros2`) |
| **Official support** | Tier 1 (fully tested, officially maintained) | None (community-maintained) |
| **Packages to install** | 5-6 (Nav2 + TB3 only) | 8+ (ROS2 base + Nav2 + Gazebo + bridge) |
| **Image size** | ~3.2 GB | ~4.6 GB |
| **Workarounds needed** | 0 | 4 major (see above) |
| **Containerfile complexity** | 20 lines | 77 lines |
| **Time to first working image** | ~10 minutes | ~2 days of debugging |
| **Rendering works OOTB** | Yes | No (symlink workarounds) |
| **Architecture support** | amd64 + arm64 | amd64 only |
| **Risk of breakage on update** | Low (stable, versioned) | High (Copr versions may change, breaking symlinks) |
| **Enterprise supportability** | OSRF backing | No support — you're on your own |

---

## Gap Analysis: What Red Hat Ecosystem Lacks

### Critical Gaps (Block Simulation Workloads)

1. **No official Gazebo packages for RHEL or Fedora**
   - The Gazebo project has no plans to produce RPMs
   - The only RPM source is the community `tavie/ros2` Copr (Fedora only, not RHEL)

2. **Official RHEL repo missing Nav2 and simulation packages**
   - The ROS2 RHEL 9 repo (~964 packages) lacks the full navigation stack
   - No `nav2-*`, no `turtlebot3-*`, no `ros-gz-*` packages in official repos
   - Only ROS2 core/middleware available

3. **No RHEL equivalent of `osrf/ros:jazzy-simulation` container**
   - All official ROS2 container images are Ubuntu-based
   - No UBI/RHEL-based simulation images exist

### Moderate Gaps (Require Workarounds)

4. **Copr packages have broken paths**
   - Hardcoded BUILDROOT paths in compiled binaries
   - Non-standard install prefix (`/usr/lib64/ros2-jazzy/` vs `/opt/ros/jazzy/`)
   - Plugin discovery requires manual environment variable configuration

5. **Architecture limitation**
   - ROS2 RHEL packages are x86_64 only (no aarch64)
   - Cannot run natively on ARM-based systems

### Minor Gaps

6. **Some TB3 packages missing from Copr**
   - `turtlebot3-gazebo` and `turtlebot3-simulations` not packaged
   - `nav2-minimal-tb3-sim` provides sufficient models for the demo

---

## Who Maintains the Copr Repository?

The `tavie/ros2` Copr is maintained by **Tavia Kirshenbaum** (GitHub: `@tavie`), a community contributor. Key facts:

- **Not affiliated with Open Robotics or Red Hat**
- Builds ROS2 Jazzy packages for Fedora 41-44
- Includes the full simulation stack (Gazebo vendor packages, Nav2, ros-gz bridge)
- Active as of June 2026
- No SLA, no guaranteed updates, no security patching commitment
- Package versions may lag behind official Ubuntu releases

**Risk assessment:** This repository could become unmaintained at any time. The packaging bugs we encountered suggest limited testing of the full simulation workflow. It is suitable for prototyping but not for production or customer-facing deployments.

---

## Recommendations

### For Demos and POCs (Today)

Use **Ubuntu-based containers** (Path A). The `osrf/ros:jazzy-simulation` image provides everything out of the box with zero workarounds. Deploy on OpenShift — the host OS doesn't need to be RHEL for the containers to run.

### For "RHEL Story" Messaging

The accurate messaging is:
> ROS2 core runs natively on RHEL 9 with official Tier 2 support. For simulation workloads requiring Gazebo, the recommended approach is Ubuntu-based OCI containers deployed on OpenShift/RHEL hosts. A Fedora-based container option exists using community packages but requires workarounds and carries maintenance risk.

### For Future Investment (If RHEL-Native Simulation is Required)

1. **Engage with Gazebo maintainers** to advocate for official Fedora/RHEL package support
2. **Contribute fixes to the `tavie/ros2` Copr** to resolve the BUILDROOT path bugs
3. **Evaluate alternative simulators** (e.g., NVIDIA Isaac Sim, which supports RHEL) if Gazebo RPM support doesn't materialize
4. **Monitor ROS2 Rolling on RHEL 10** — the expanded package set may eventually include Nav2 and simulation packages

---

## Files Created for Fedora Deployment

| File | Purpose |
|------|---------|
| `openshift/Containerfile.fedora` | Fedora 41-based Containerfile with all workarounds |
| `openshift/entrypoint-fedora.sh` | Modified entrypoint handling Copr-specific paths |

These are functional and deployed, but should be considered **experimental** given the fragility of the upstream Copr packaging.

---

## References

- [REP 2000 — ROS2 Platform Targets](https://www.ros.org/reps/rep-2000.html)
- [ROS2 Jazzy RHEL Status Page](https://repo.ros2.org/status_page/ros_jazzy_rhel.html)
- [Gazebo: No RHEL/Fedora support (GitHub issue)](https://github.com/gazebosim/ros_gz/issues/729)
- [tavie/ros2 Copr Repository](https://copr.fedorainfracloud.org/coprs/tavie/ros2/)
- [ROS2 Official Container Images](https://hub.docker.com/_/ros)
