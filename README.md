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
