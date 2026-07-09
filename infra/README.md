# ROS2 Gazebo Development VM (OpenTofu)

Provisions an AWS EC2 instance pre-configured with ROS 2 Humble, Gazebo, and NICE DCV remote desktop — accessible via browser.

## What You Get

| Component | Details |
|-----------|---------|
| OS | Ubuntu 22.04 (Jammy) |
| ROS 2 | Humble Desktop (full) |
| Simulation | Gazebo + ros-gz integration |
| Desktop | XFCE4 via NICE DCV (browser-based, port 8443) |
| Dev tools | colcon, rosdep, vcstool, pip, cmake, git |
| Instance type | `t3.xlarge` (4 vCPU, 16 GB RAM) by default |
| Rendering | Software (LLVMpipe) — no GPU required |

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.6.0
- AWS CLI configured with credentials (`aws configure`)
- Sufficient AWS permissions to create: EC2 instances, key pairs, security groups

## Quick Start

```bash
cd infra/

# Initialize providers
tofu init

# Preview what will be created
tofu plan

# Create the VM
tofu apply
```

After `tofu apply` completes, the instance will reboot once to finalize DCV setup (~1-2 minutes).

## Connecting to the VM

### Remote Desktop (Browser)

1. Get the DCV URL:
   ```bash
   tofu output nice_dcv_url
   ```
2. Open the URL in your browser (accept the self-signed certificate)
3. Log in with:
   - **Username:** `ubuntu`
   - **Password:** `ros2dev`

### SSH

```bash
ssh -i $(tofu output -raw ssh_private_key_path) ubuntu@$(tofu output -raw public_ip)
```

### Cursor Remote-SSH

Add to `~/.ssh/config`:
```
Host ros2-dev
  HostName <public_ip from tofu output>
  User ubuntu
  IdentityFile <path to .pem from tofu output>
```

## Configuration

Override defaults by creating a `terraform.tfvars` file:

```hcl
resource_prefix  = "myname"          # Prefix for AWS resource names
aws_region       = "us-east-1"       # AWS region
instance_type    = "t3.xlarge"       # Instance size
volume_size      = 50                # Root volume in GB
allowed_ssh_cidrs = ["1.2.3.4/32"]  # Restrict SSH/DCV access to your IP
```

| Variable | Default | Description |
|----------|---------|-------------|
| `resource_prefix` | `loki` | Prefix for all resource names |
| `aws_region` | `us-east-1` | AWS region |
| `instance_type` | `t3.xlarge` | EC2 instance type |
| `instance_name` | `ros2-gazebo-dev` | Instance name suffix |
| `volume_size` | `50` | Root EBS volume size (GB) |
| `allowed_ssh_cidrs` | `["0.0.0.0/0"]` | CIDRs allowed for SSH and DCV |

## Managing the VM

```bash
# Get instance info
tofu output

# Stop the instance (saves cost, keeps data)
aws ec2 stop-instances --instance-ids $(tofu output -raw instance_id) --region us-east-1

# Start it again
aws ec2 start-instances --instance-ids $(tofu output -raw instance_id) --region us-east-1

# Destroy everything
tofu destroy
```

Note: The public IP changes when the instance is stopped/started. Re-run `tofu output` to get the new IP.

## Security Notes

- The default `allowed_ssh_cidrs` is open (`0.0.0.0/0`). Restrict this to your IP in production.
- The DCV password (`ros2dev`) is a development convenience. Change it after first login:
  ```bash
  sudo passwd ubuntu
  ```
- The SSH private key (`.pem`) is generated locally and excluded from git via `.gitignore`.

## Cost Estimate

| State | Approximate Cost |
|-------|-----------------|
| Running (`t3.xlarge`) | ~$0.17/hr (~$122/month) |
| Stopped | ~$4/month (EBS storage only) |

Remember to stop or destroy the instance when not in use.
