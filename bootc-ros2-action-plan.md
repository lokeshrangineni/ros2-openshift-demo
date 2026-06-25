# Action Plan: ROS2 on Fedora Bootc

## JIRAs

- Research bootc image layering for ROS2 on Fedora (documentation/research)
- Build a minimal Fedora bootc image that boots a VM and runs a ROS2 node (proof-of-concept)

## Approach

Work on both tasks in parallel — the research informs the hands-on PoC, and hands-on work validates the research. Each step below is small, testable, and builds on the previous one.

---

## Prerequisites

Before starting, ensure you have:

- [ ] A Linux machine (or Mac with Podman Machine) with `podman` installed
- [ ] At least 20 GB free disk space (bootc images are ~2-4 GB)
- [ ] Access to `quay.io` for pulling/pushing images
- [ ] KVM/QEMU available for testing VMs (or access to a VM environment)
  - On Fedora/RHEL: `sudo dnf install qemu-kvm libvirt virt-install virt-manager`
  - On Mac: Podman Machine or a remote Linux host
- [ ] The `bootc-image-builder` container image pulled:
  ```bash
  podman pull quay.io/centos-bootc/bootc-image-builder:latest
  ```

---

## Phase 1: Validate Base Bootc Image Builds (Day 1)

**Goal:** Confirm that you can build a derived bootc image and boot it in a VM. No ROS2 yet — just validate the toolchain works.

### Step 1.1: Build a minimal derived bootc image

Create `examples/bootc/Containerfile.base-test`:

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

# Add a simple test: install cowsay so we know the image is ours
RUN dnf install -y cowsay && dnf clean all

# Validate bootc compatibility
RUN bootc container lint
```

**Test:**
```bash
cd examples/bootc
podman build --platform linux/amd64 -t localhost/bootc-test:latest -f Containerfile.base-test .
```

**Success criteria:**
- [ ] Build completes without errors
- [ ] `bootc container lint` passes (no warnings in build output)

### Step 1.2: Convert to a QCOW2 VM disk image

```bash
# Create output directory
mkdir -p output

# Create a config.toml with a test user (needed to log into the VM)
cat > config.toml <<'EOF'
[[customizations.user]]
name = "ros2"
password = "changeme"  # Demo only — use SSH keys in production
groups = ["wheel"]
EOF

# Build QCOW2 disk image
sudo podman run --rm -it --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./config.toml:/config.toml:ro \
    -v ./output:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --rootfs ext4 \
    --config /config.toml \
    localhost/bootc-test:latest
```

**Test:**
- [ ] A file appears at `output/qcow2/disk.qcow2`

### Step 1.3: Boot the QCOW2 in a VM

```bash
# Boot with QEMU (adjust RAM/CPU as needed)
qemu-system-x86_64 \
    -m 4096 \
    -smp 2 \
    -cpu host \
    -enable-kvm \
    -drive file=output/qcow2/disk.qcow2,format=qcow2 \
    -nographic \
    -nic user,hostfwd=tcp::2222-:22
```

Or use `virt-install`:
```bash
sudo virt-install \
    --name bootc-test \
    --memory 4096 \
    --vcpus 2 \
    --disk path=output/qcow2/disk.qcow2 \
    --import \
    --os-variant fedora43 \
    --network default \
    --noautoconsole
```

**Test:**
- [ ] VM boots to a login prompt
- [ ] You can log in as `ros2` / `changeme`
- [ ] Running `cowsay "bootc works"` succeeds (confirms our custom layer is present)
- [ ] Running `bootc status` shows the image info
- [ ] Filesystem `/usr` is read-only: `touch /usr/test` should fail with "Read-only file system"

### Step 1.4: Document findings

Update `bootc-ros2-evaluation.md` with:
- Any issues encountered during build
- VM boot behavior observations
- Image size (`ls -lh output/qcow2/disk.qcow2`)

---

## Phase 2: Add ROS2 Core to the Bootc Image (Day 2-3)

**Goal:** Layer ROS2 packages into the bootc image and confirm they are accessible after boot.

### Step 2.1: Build bootc image with ROS2

Create `examples/bootc/Containerfile.ros2`:

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

# Enable the tavie/ros2 Copr repository
RUN dnf install -y dnf-plugins-core && \
    dnf copr enable -y tavie/ros2

# Install ROS2 base
RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-demo-nodes-cpp \
      ros-jazzy-demo-nodes-py \
      && dnf clean all

# Register ROS2 libraries with ldconfig
RUN echo "/usr/lib64/ros-jazzy/lib" > /etc/ld.so.conf.d/ros2.conf && \
    ldconfig

# Create ROS2 environment profile (sourced on login)
RUN echo 'source /usr/lib64/ros-jazzy/setup.bash' > /etc/profile.d/ros2.sh && \
    chmod +x /etc/profile.d/ros2.sh

# Validate
RUN bootc container lint
```

**Test:**
```bash
podman build --platform linux/amd64 -t localhost/bootc-ros2:latest -f Containerfile.ros2 .
```

**Success criteria:**
- [ ] Build succeeds
- [ ] `bootc container lint` passes
- [ ] Note the image size: `podman images localhost/bootc-ros2`

### Step 2.2: Quick validation in container mode (before creating VM)

Before spending time on QCOW2 generation, do a quick sanity check by running the image as a regular container:

```bash
podman run --rm -it localhost/bootc-ros2:latest bash -c \
    "source /usr/lib64/ros-jazzy/setup.bash && ros2 --help"
```

**Success criteria:**
- [ ] `ros2 --help` prints the ROS2 CLI help text
- [ ] No missing library errors

### Step 2.3: Test ROS2 node execution in container mode

```bash
# Terminal 1: Run talker
podman run --rm -it --network=host localhost/bootc-ros2:latest bash -c \
    "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp talker"

# Terminal 2: Run listener (in another terminal)
podman run --rm -it --network=host localhost/bootc-ros2:latest bash -c \
    "source /usr/lib64/ros-jazzy/setup.bash && ros2 run demo_nodes_cpp listener"
```

**Success criteria:**
- [ ] Talker prints: `Publishing: 'Hello World: 1'`, `'Hello World: 2'`, etc.
- [ ] Listener prints: `I heard: [Hello World: 1]`, etc.
- [ ] This confirms DDS communication works between two instances of the image

### Step 2.4: Generate QCOW2 and boot VM with ROS2

```bash
sudo podman run --rm -it --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v ./config.toml:/config.toml:ro \
    -v ./output-ros2:/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --rootfs ext4 \
    --config /config.toml \
    localhost/bootc-ros2:latest
```

Boot the VM and log in, then:

```bash
# After logging in as ros2:
source /usr/lib64/ros-jazzy/setup.bash
ros2 run demo_nodes_cpp talker
```

**Success criteria:**
- [ ] VM boots successfully
- [ ] `source /usr/lib64/ros-jazzy/setup.bash` works
- [ ] `ros2 run demo_nodes_cpp talker` publishes messages
- [ ] `ros2 topic list` shows `/chatter`
- [ ] `/usr` is still read-only (immutable)

---

## Phase 3: Systemd Integration — ROS2 as a Service (Day 3-4)

**Goal:** Run a ROS2 node automatically at boot via systemd (the bootc-native way to run services).

### Step 3.1: Create a systemd unit for the talker node

Create `examples/bootc/ros2-talker.service`:

```ini
[Unit]
Description=ROS2 Demo Talker Node
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
Environment="ROS_DISTRO=jazzy"
Environment="AMENT_PREFIX_PATH=/usr/lib64/ros-jazzy"
Environment="PATH=/usr/lib64/ros-jazzy/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/usr/lib64/ros-jazzy/lib"
Environment="PYTHONPATH=/usr/lib64/ros-jazzy/lib/python3.13/site-packages"
Environment="ROS_DOMAIN_ID=42"
ExecStart=/usr/lib64/ros-jazzy/lib/demo_nodes_cpp/talker
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Step 3.2: Bake the systemd unit into the image

Update the Containerfile to include it:

```dockerfile
FROM quay.io/fedora/fedora-bootc:43

RUN dnf install -y dnf-plugins-core && \
    dnf copr enable -y tavie/ros2

RUN dnf install -y \
      ros-jazzy-ros-base \
      ros-jazzy-demo-nodes-cpp \
      ros-jazzy-demo-nodes-py \
      && dnf clean all

RUN echo "/usr/lib64/ros-jazzy/lib" > /etc/ld.so.conf.d/ros2.conf && \
    ldconfig

RUN echo 'source /usr/lib64/ros-jazzy/setup.bash' > /etc/profile.d/ros2.sh && \
    chmod +x /etc/profile.d/ros2.sh

# Install systemd unit for the talker node
COPY ros2-talker.service /usr/lib/systemd/system/ros2-talker.service
RUN systemctl enable ros2-talker.service

RUN bootc container lint
```

**Test (container quick-check):**
```bash
podman build --platform linux/amd64 -t localhost/bootc-ros2-systemd:latest -f Containerfile.ros2-systemd .

# Verify the unit file is in place
podman run --rm localhost/bootc-ros2-systemd:latest \
    cat /usr/lib/systemd/system/ros2-talker.service
```

### Step 3.3: Boot VM and verify auto-start

Generate QCOW2, boot the VM, then verify:

```bash
# After VM boots, check that the talker is running:
systemctl status ros2-talker

# Check the logs:
journalctl -u ros2-talker -f

# Verify topics are being published:
source /usr/lib64/ros-jazzy/setup.bash
ros2 topic list
ros2 topic echo /chatter
```

**Success criteria:**
- [ ] `ros2-talker.service` is active and running after boot (no manual start needed)
- [ ] `journalctl -u ros2-talker` shows "Publishing: 'Hello World: N'" messages
- [ ] `ros2 topic list` shows `/chatter`
- [ ] Service auto-restarts if killed: `sudo kill $(pgrep talker)` → check it restarts within 5s

---

## Phase 4: Cross-Network Communication (Day 4-5)

**Goal:** Validate that the ROS2 node inside the bootc VM can communicate with an external ROS2 system (fulfills the requirement of communicating with an external ROS2 system).

### Step 4.1: Configure DDS for cross-host communication

Create `examples/bootc/cyclonedds.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CycloneDDS xmlns="https://cdds.io/config">
  <Domain>
    <General>
      <Interfaces>
        <NetworkInterface autodetermine="true" />
      </Interfaces>
      <AllowMulticast>default</AllowMulticast>
    </General>
    <Discovery>
      <ParticipantIndex>auto</ParticipantIndex>
    </Discovery>
  </Domain>
</CycloneDDS>
```

### Step 4.2: Update Containerfile with CycloneDDS

```dockerfile
# Add to the existing Containerfile:
RUN dnf install -y ros-jazzy-cyclonedds ros-jazzy-rmw-cyclonedds-cpp && \
    dnf clean all

COPY cyclonedds.xml /etc/cyclonedds/cyclonedds.xml

# Update service to use CycloneDDS
# (add to the Environment lines in ros2-talker.service)
# Environment="RMW_IMPLEMENTATION=rmw_cyclonedds_cpp"
# Environment="CYCLONEDDS_URI=file:///etc/cyclonedds/cyclonedds.xml"
```

### Step 4.3: Test communication from host to VM

From your host machine (or another container with ROS2):

```bash
# On the host (with ROS2 installed or in a ROS2 container):
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
ros2 topic list        # Should discover /chatter from the VM
ros2 topic echo /chatter   # Should receive messages from the VM's talker
```

**Success criteria:**
- [ ] Host can discover topics published by the VM
- [ ] `ros2 topic echo /chatter` on the host receives messages from the VM
- [ ] Latency is reasonable (sub-second for LAN)

### Step 4.4: Test bidirectional communication

```bash
# On the host: start a listener
ros2 run demo_nodes_cpp listener
# Should print messages from the VM's talker

# On the host: publish to the VM
ros2 topic pub /cmd_vel geometry_msgs/msg/Twist '{linear: {x: 1.0}}'

# In the VM: verify the host's message is received
ros2 topic echo /cmd_vel
```

**Success criteria:**
- [ ] VM → Host communication works (talker → listener)
- [ ] Host → VM communication works (pub → echo)
- [ ] This proves the bootc VM participates fully in the ROS2 network

---

## Phase 5: Validate Immutability and Update Flow (Day 5-6)

**Goal:** Demonstrate bootc's value proposition — immutability, atomic updates, and rollback.

### Step 5.1: Confirm immutability

Inside the running VM:

```bash
# These should all FAIL with "Read-only file system":
touch /usr/test
dnf install vim             # Should fail
rm /usr/lib64/ros-jazzy/setup.bash   # Should fail

# These should SUCCEED (writable areas):
echo "test" > /etc/my-config
echo "data" > /var/lib/ros2/test
```

### Step 5.2: Perform an atomic update

```bash
# Build v2 of the image (add teleop_twist_keyboard for example)
# On your build machine:
# (modify Containerfile to add ros-jazzy-teleop-twist-keyboard)
podman build --platform linux/amd64 -t localhost/bootc-ros2-systemd:v2 -f Containerfile.ros2-systemd .

# Push to a registry (or use local transport)
# For local testing without a registry, copy into the VM:
# Option A: Push to quay.io
podman push localhost/bootc-ros2-systemd:v2 quay.io/<your-org>/ros2-bootc:v2

# In the VM:
sudo bootc switch quay.io/<your-org>/ros2-bootc:v2
sudo reboot

# After reboot:
rpm -q ros-jazzy-teleop-twist-keyboard   # Should be installed now
```

### Step 5.3: Test rollback

```bash
# In the VM after upgrading to v2:
sudo bootc rollback
sudo reboot

# After reboot: back on v1
rpm -q ros-jazzy-teleop-twist-keyboard   # Should NOT be found (we're back on v1)
```

**Success criteria:**
- [ ] `bootc switch` downloads and stages a new image
- [ ] After reboot, the new packages are available
- [ ] `bootc rollback` + reboot returns to the previous state
- [ ] `/var` data persists across both operations

---

## Phase 6: Documentation and Wrap-Up (Day 6-7)

**Goal:** Finalize documentation for both JIRAs.

### For Research (already mostly done)

- [ ] Review and finalize `bootc-ros2-evaluation.md` based on hands-on findings
- [ ] Add a "Validated Findings" section documenting what was actually tested vs. theoretical
- [ ] Note any unexpected issues or deviations from the research

### For PoC (Proof of Concept)

- [ ] Commit all Containerfiles, systemd units, and config files to `examples/bootc/`
- [ ] Write a README in `examples/bootc/README.md` with build/test instructions
- [ ] Record the image sizes, boot times, and any performance observations
- [ ] Capture screenshots or log excerpts showing:
  - ROS2 node starting at boot
  - Topic communication working
  - Cross-host DDS discovery
  - Immutability (read-only filesystem errors)
  - Successful update/rollback cycle

---

## File Structure (After Completion)

```
examples/bootc/
├── README.md                    # Build and test instructions
├── Containerfile.ros2           # Minimal ROS2 bootc image
├── Containerfile.ros2-systemd   # ROS2 with systemd auto-start
├── ros2-talker.service          # systemd unit for talker node
├── cyclonedds.xml               # DDS network configuration
├── config.toml                  # bootc-image-builder user config
└── output/                      # (gitignored) generated disk images
```

---

## Quick Reference: Key Commands

| Action | Command |
|--------|---------|
| Build bootc image | `podman build --platform linux/amd64 -t localhost/bootc-ros2:latest -f Containerfile.ros2 .` |
| Quick test (no VM) | `podman run --rm -it localhost/bootc-ros2:latest bash` |
| Generate QCOW2 | `sudo podman run --rm -it --privileged ... bootc-image-builder --type qcow2 ...` |
| Boot VM | `qemu-system-x86_64 -m 4096 -smp 2 -enable-kvm -drive file=disk.qcow2,format=qcow2 -nographic` |
| SSH into VM | `ssh -p 2222 ros2@localhost` (if using QEMU user networking) |
| Check bootc status | `bootc status` (inside the VM) |
| Update image | `bootc switch <new-image>` or `bootc upgrade` |
| Rollback | `bootc rollback` |

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| `bootc-image-builder` fails on ARM Mac | Use `--platform linux/amd64` for build; run `bootc-image-builder` on a Linux machine or in CI |
| Copr packages have dependency issues | Test in container mode first (Step 2.2) before spending time on VM generation |
| VM networking prevents DDS discovery | Use bridged networking (not NAT) or configure CycloneDDS unicast peers |
| QCOW2 generation is slow (~10-20 min) | Validate everything in container mode first; only generate QCOW2 when confident |
| ROS2 `setup.bash` doesn't work in systemd | Use explicit `Environment=` lines in the unit file instead of sourcing bash |
| Fedora 43 Copr path (`/usr/lib64/ros-jazzy/`) differs from standard | Already documented; use explicit paths in systemd units and profile scripts |

---

## Definition of Done

### Research ✓ when:
- [ ] `bootc-ros2-evaluation.md` is complete with validated findings
- [ ] Conflicts documented with severity and mitigations
- [ ] Realistic deployment paths described (RHEL 10 + Fedora 43)
- [ ] References to official docs and prior art included

### PoC ✓ when:
- [ ] A bootc image with ROS2 can be built from a Containerfile
- [ ] The image boots in a VM (QCOW2)
- [ ] A ROS2 node starts automatically at boot (systemd)
- [ ] The node publishes topics (verified via `ros2 topic list/echo`)
- [ ] The node can communicate with an external ROS2 system (cross-host DDS)
- [ ] Bootc immutability is demonstrated (`/usr` is read-only)
- [ ] Build instructions are documented in `examples/bootc/README.md`
