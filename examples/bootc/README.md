# Bootc ROS2 Example — Fedora 43 Bootable Container

This example builds a minimal Fedora 43 bootc-compatible image with ROS2 Jazzy installed from the `tavie/ros2` Copr repository. The image passes `bootc container lint` and can be deployed to real hardware as a bootable OS via QCOW2 disk images.

**Published image:** `quay.io/lrangine/ros2-demo:bootc`

## Files

| File | Purpose |
|------|---------|
| `Containerfile.ros2` | Minimal bootc + ROS2 (no DDS config, no systemd) |
| `Containerfile.ros2-systemd` | Adds systemd service — talker auto-starts at boot |
| `Containerfile.ros2-dds` | Full image: CycloneDDS + systemd + QCOW2 support **(recommended)** |
| `ros2-talker.service` | Basic systemd unit for the talker node |
| `ros2-talker-dds.service` | Systemd unit with CycloneDDS environment configured |
| `cyclonedds.xml` | CycloneDDS network discovery configuration |
| `TEST_RESULTS.md` | Full validation evidence with command outputs |

## Quick Start

### Option 1: Pull the pre-built image

```bash
podman pull quay.io/lrangine/ros2-demo:bootc
```

### Option 2: Build locally

```bash
# Minimal (no systemd, no DDS)
podman build -t localhost/bootc-ros2:latest -f Containerfile.ros2 .

# With systemd auto-start
podman build -t localhost/bootc-ros2-systemd:latest -f Containerfile.ros2-systemd .

# Full — with CycloneDDS + systemd + QCOW2 support (recommended)
podman build -t localhost/bootc-ros2-dds:latest -f Containerfile.ros2-dds .
```

## Testing

### Run the talker node

```bash
podman run --rm --network host -e HOME=/tmp/ros-home -e ROS_DOMAIN_ID=42 \
  quay.io/lrangine/ros2-demo:bootc \
  bash -c "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp talker"
```

### Run publisher + subscriber in separate containers

```bash
# Terminal 1: Publisher (talker)
podman run --rm --network host -e HOME=/tmp/ros-home -e ROS_DOMAIN_ID=42 \
  quay.io/lrangine/ros2-demo:bootc \
  bash -c "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp talker"

# Terminal 2: Subscriber (listener) — receives messages from the publisher
podman run --rm --network host -e HOME=/tmp/ros-home -e ROS_DOMAIN_ID=42 \
  quay.io/lrangine/ros2-demo:bootc \
  bash -c "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp listener"

# Expected listener output:
# [INFO] [listener]: I heard: [Hello World: 1]
# [INFO] [listener]: I heard: [Hello World: 2]
```

### Test systemd auto-start (boot simulation)

```bash
podman run -d --name bootc-test --privileged --network host \
  quay.io/lrangine/ros2-demo:bootc /sbin/init

# Wait for boot, then check:
podman exec bootc-test systemctl status ros2-talker.service
podman exec bootc-test journalctl -u ros2-talker --no-pager -n 10

# Clean up
podman rm -f bootc-test
```

### Convert to bootable VM disk (requires Linux host)

```bash
sudo podman run --rm --privileged \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --local localhost/bootc-ros2-dds:latest
```

## Key Details

| Item | Value |
|------|-------|
| Base image | `quay.io/fedora/fedora-bootc:43` |
| ROS2 source | `tavie/ros2` Copr (Fedora 43) |
| ROS2 prefix | `/usr/lib64/ros-jazzy/` |
| DDS middleware | CycloneDDS (in `Containerfile.ros2-dds`) |
| Image size | ~3.4 GB |
| QCOW2 size | ~1.8 GB |
| Package manager | DNF5 (requires `dnf5-command(copr)` plugin) |
| Registry | `quay.io/lrangine/ros2-demo:bootc` |

## Known Issues / Workarounds

1. **DNF5 vs DNF4**: Fedora 43 uses DNF5 by default. The `copr` subcommand requires installing `dnf5-command(copr)` first — the old `dnf-plugins-core` approach does not work.

2. **ROS2 logging directory**: ROS2 nodes expect to write logs to `$HOME/.ros/log`. In containers without a writable home, set `HOME=/tmp/ros-home`.

3. **CycloneDDS library path**: CycloneDDS installs `libddsc.so.0` in `/usr/lib64/ros-jazzy/lib64/` (not `/lib/`). Both paths must be in `ld.so.conf.d` and `LD_LIBRARY_PATH`.

4. **Python version**: Fedora 43 ships Python 3.14. The `PYTHONPATH` in systemd units must reference `python3.14` (not `python3.13`).

5. **Systemd in containers**: `NetworkManager-wait-online.service` blocks boot in containers. Mask it for container testing (`systemctl mask NetworkManager-wait-online.service`). This is not an issue on real hardware.

6. **QCOW2 generation**: `bootc-image-builder` requires `/usr/lib/bootc/install/00-default.toml` with `root-fs-type = "xfs"` in the image. This is included in `Containerfile.ros2-dds`.

## Related

- [Test Results](./TEST_RESULTS.md) — Full validation evidence
- [Action Plan](../../bootc-ros2-action-plan.md) — Phased implementation plan
- [Bootc Evaluation](../../bootc-ros2-evaluation.md) — Research and conflict analysis
- [Monolithic Example](../monolithic/) — OpenShift deployment (non-bootc)
