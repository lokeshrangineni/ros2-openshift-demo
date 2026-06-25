# Bootc ROS2 Example — Fedora 43 Bootable Container

This example builds a minimal Fedora 43 bootc-compatible image with ROS2 Jazzy installed from the `tavie/ros2` Copr repository. The image passes `bootc container lint` and can be used as a base for bootable OS deployments on real hardware.

## Quick Start

### Build the image

```bash
podman build -t localhost/bootc-ros2:latest -f Containerfile.ros2 .
```

### Test ROS2 in container mode

```bash
# Verify ROS2 CLI works
podman run --rm localhost/bootc-ros2:latest bash -c \
  "source /usr/lib64/ros-jazzy/setup.bash && ros2 --help"

# Run talker node
podman run --rm localhost/bootc-ros2:latest bash -c \
  "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp talker"

# Test talker + listener communication (same container)
podman run --rm --network host localhost/bootc-ros2:latest bash -c \
  "source /usr/lib64/ros-jazzy/setup.bash && \
   /usr/lib64/ros-jazzy/lib/demo_nodes_cpp/talker & \
   sleep 2 && \
   /usr/lib64/ros-jazzy/lib/demo_nodes_cpp/listener & \
   sleep 8 && kill %1 %2 2>/dev/null; wait"
```

### Convert to bootable VM disk (requires Linux host with KVM)

```bash
# Install bootc-image-builder
podman pull quay.io/centos-bootc/bootc-image-builder:latest

# Generate QCOW2 disk image
sudo podman run --rm -it --privileged \
  --pull=newer \
  -v ./output:/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/bootc-ros2:latest
```

## Key Details

| Item | Value |
|------|-------|
| Base image | `quay.io/fedora/fedora-bootc:43` |
| ROS2 source | `tavie/ros2` Copr (Fedora 43) |
| ROS2 prefix | `/usr/lib64/ros-jazzy/` |
| Image size | ~3.4 GB |
| Package manager | DNF5 (requires `dnf5-command(copr)` plugin) |

## Known Issues / Workarounds

1. **DNF5 vs DNF4**: Fedora 43 uses DNF5 by default. The `copr` subcommand requires installing `dnf5-command(copr)` first — the old `dnf-plugins-core` approach does not work.

2. **ROS2 logging directory**: ROS2 nodes expect to write logs to `$HOME/.ros/log`. In containers without a writable home, set `HOME=/tmp/ros-home`.

3. **DDS discovery across containers**: Running talker and listener in separate `podman run` containers may not work even with `--network host` due to DDS multicast isolation. Use `--ipc=host` or run both nodes in the same container for testing.

## Next Steps

- Add systemd service files for running ROS2 nodes at boot (Phase 3)
- Generate QCOW2 and boot in a VM (Phase 4)
- Test cross-host DDS communication (Phase 5)

## Related

- [Action Plan](../../bootc-ros2-action-plan.md)
- [Bootc Evaluation](../../bootc-ros2-evaluation.md)
- [Monolithic Example](../monolithic/) — OpenShift deployment (non-bootc)
