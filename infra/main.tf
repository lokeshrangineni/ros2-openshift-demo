terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- SSH Key Pair ---

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ros2_dev" {
  key_name   = "${var.resource_prefix}-ros2-gazebo-dev-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/${var.resource_prefix}-ros2-gazebo-dev-key.pem"
  file_permission = "0600"
}

# --- Security Group ---

resource "aws_security_group" "ros2_dev" {
  name        = "${var.resource_prefix}-ros2-gazebo-dev-sg"
  description = "Security group for ROS2 Gazebo development instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "NICE DCV remote desktop"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.resource_prefix}-${var.instance_name}-sg"
  }
}

# --- EC2 Instance ---

resource "aws_instance" "ros2_dev" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.ros2_dev.key_name
  vpc_security_group_ids = [aws_security_group.ros2_dev.id]
  subnet_id              = data.aws_subnets.default.ids[0]

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.resource_prefix}-${var.instance_name}"
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.ssh.private_key_openssh
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common",
      "sudo add-apt-repository -y universe",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y xfce4 xfce4-goodies dbus-x11 mesa-utils libgl1-mesa-dri libgl1-mesa-glx",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "wget -q https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY",
      "gpg --import NICE-GPG-KEY",
      "wget -q https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2204-x86_64.tgz",
      "tar -xzf nice-dcv-ubuntu2204-x86_64.tgz",
      "cd nice-dcv-*-x86_64 && sudo apt-get install -y ./nice-dcv-server_*.deb ./nice-dcv-web-viewer_*.deb ./nice-xdcv_*.deb ./nice-dcv-simple-external-authenticator_*.deb",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /var/run/dcvsimpleextauth",
      <<-EOT
      sudo tee /etc/dcv/dcv.conf > /dev/null <<'DCVCONF'
      [license]
      [log]
      [session-management]
      create-session = false
      [session-management/defaults]
      [display]
      target-fps = 30
      [connectivity]
      web-port = 8443
      [security]
      auth-token-verifier = "http://127.0.0.1:8444"
      DCVCONF
      EOT
      ,
      "sudo systemctl enable dcvserver",
      "sudo systemctl enable dcvsimpleextauth",
      # Ensure DCV waits for network before starting (prevents race condition on boot)
      "sudo mkdir -p /etc/systemd/system/dcvserver.service.d /etc/systemd/system/dcvsimpleextauth.service.d",
      "printf '[Unit]\\nAfter=network-online.target\\nWants=network-online.target\\n' | sudo tee /etc/systemd/system/dcvserver.service.d/override.conf > /dev/null",
      "printf '[Unit]\\nAfter=network-online.target\\nWants=network-online.target\\n' | sudo tee /etc/systemd/system/dcvsimpleextauth.service.d/override.conf > /dev/null",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      sudo tee /etc/systemd/system/dcv-virtual-session.service > /dev/null <<'SVC'
      [Unit]
      Description=Create DCV Virtual Session
      After=dcvserver.service
      Requires=dcvserver.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStartPre=/bin/sleep 3
      ExecStart=/usr/bin/dcv create-session --type virtual --owner ubuntu --name "ROS2 Desktop" ros2-desktop
      ExecStop=/usr/bin/dcv close-session ros2-desktop

      [Install]
      WantedBy=multi-user.target
      SVC
      EOT
      ,
      "sudo systemctl daemon-reload",
      "sudo systemctl enable dcv-virtual-session.service",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common curl gnupg lsb-release",
      "curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key | sudo gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg",
      "echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main' | sudo tee /etc/apt/sources.list.d/ros2.list",
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ros-humble-desktop",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ros-humble-gazebo-ros-pkgs ros-humble-gazebo-ros2-control ros-humble-ros-gz",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-colcon-common-extensions python3-rosdep python3-vcstool python3-pip build-essential cmake git",
      "sudo rosdep init || true",
      "rosdep update",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      cat >> ~/.bashrc <<'BASHRC'

      source /opt/ros/humble/setup.bash
      export ROS_DOMAIN_ID=0
      export LIBGL_ALWAYS_SOFTWARE=1
      export GAZEBO_MODEL_PATH=/opt/ros/humble/share/gazebo_ros/models:$${GAZEBO_MODEL_PATH:-}
      source /usr/share/colcon_argcomplete/hook/colcon-argcomplete.bash 2>/dev/null || true
      BASHRC
      EOT
      ,
      "echo 'ubuntu:ros2dev' | sudo chpasswd",
      <<-EOT
      sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla > /dev/null <<'PKLA'
      [Allow Colord for all users]
      Identity=unix-user:*
      Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
      ResultAny=yes
      ResultInactive=yes
      ResultActive=yes
      PKLA
      EOT
      ,
      <<-EOT
      mkdir -p ~/.config/xfce4/xfconf/xfce-perchannel-xml
      cat > ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml <<'XML'
      <?xml version="1.0" encoding="UTF-8"?>
      <channel name="xfce4-screensaver" version="1.0">
        <property name="lock" type="empty">
          <property name="enabled" type="bool" value="false"/>
        </property>
        <property name="screensaver" type="empty">
          <property name="enabled" type="bool" value="false"/>
        </property>
      </channel>
      XML
      EOT
      ,
      "nohup sh -c 'sleep 3 && reboot' &>/dev/null &",
    ]
  }
}
