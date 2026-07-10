#!/bin/bash
set -euo pipefail

INSTANCE_ID="$(cd "$(dirname "$0")/infra" && tofu output -raw instance_id 2>/dev/null)" || {
  echo "Error: Could not read instance_id from tofu state. Run 'tofu apply' in infra/ first."
  exit 1
}
REGION="us-east-1"

echo "Stopping EC2 instance ${INSTANCE_ID}..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

echo "Instance is stopping. You'll only be charged for EBS storage (~\$4/month) while stopped."
