#!/bin/bash
set -euo pipefail

INSTANCE_ID="$(cd "$(dirname "$0")/infra" && tofu output -raw instance_id 2>/dev/null)" || {
  echo "Error: Could not read instance_id from tofu state. Run 'tofu apply' in infra/ first."
  exit 1
}
REGION="us-east-1"
KEY="$(dirname "$0")/infra/$(cd "$(dirname "$0")/infra" && tofu output -raw ssh_private_key_path 2>/dev/null)"

echo "Starting EC2 instance ${INSTANCE_ID}..."
aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Instance running at ${IP}"
echo "Waiting for SSH to be ready..."
for i in $(seq 1 30); do
  if ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ubuntu@"$IP" "true" 2>/dev/null; then
    break
  fi
  sleep 5
done

echo "Ensuring DCV services are running..."
ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@"$IP" '
  sudo systemctl start dcvsimpleextauth dcvserver
  sleep 5
  sudo systemctl is-active dcvserver || { echo "ERROR: dcvserver failed to start"; sudo journalctl -u dcvserver -n 20 --no-pager; exit 1; }
  # Create DCV session if it does not already exist
  sudo dcv list-sessions 2>/dev/null | grep -q ros2-desktop || \
    sudo dcv create-session --type virtual --owner ubuntu --name "ROS2 Desktop" ros2-desktop
'

echo "Generating DCV login token (valid for 1 hour)..."
# Remove stale token file and recreate as dcv user so the server can read it
TOKEN=$(openssl rand -hex 32)
ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@"$IP" \
  "sudo rm -f /var/run/dcvsimpleextauth/ros2-desktop && echo '${TOKEN}' | sudo -u dcv dcvsimpleextauth add-user --session ros2-desktop --auth-dir /var/run/dcvsimpleextauth/ --user ubuntu"

URL="https://${IP}:8443?authToken=${TOKEN}#ros2-desktop"

echo ""
echo "============================================"
echo "  ROS2 VM is ready!"
echo "============================================"
echo ""
echo "  Desktop (opens in browser):"
echo "  ${URL}"
echo ""
echo "  SSH:"
echo "  ssh -i ${KEY} ubuntu@${IP}"
echo ""
echo "  Cursor Remote-SSH:"
echo "  Host: ubuntu@${IP}"
echo "  Key:  ${KEY}"
echo ""
echo "  Token expires when VM is stopped."
echo "============================================"

if command -v open &> /dev/null; then
  read -p "Open desktop in browser now? [Y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    open "$URL"
  fi
fi
