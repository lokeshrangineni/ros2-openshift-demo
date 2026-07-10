#!/bin/bash
# Open-RMF Hotel Demo — Build Script for AWS Ubuntu VM (amd64)
# Run this on an Ubuntu 22.04/24.04 amd64 machine with Docker/Podman installed.
#
# Prerequisites:
#   - Docker or Podman installed
#   - Logged into quay.io: podman login quay.io (or docker login quay.io)
#   - At least 20GB free disk space
#
# Usage:
#   chmod +x build-on-vm.sh
#   ./build-on-vm.sh

set -eo pipefail

REGISTRY="quay.io/lrangine/ros2-demo"
TAG="openrmf-hotel"
IMAGE="${REGISTRY}:${TAG}"

echo "=============================================="
echo " Building Open-RMF Hotel Demo Image"
echo " Target: ${IMAGE}"
echo "=============================================="

# Detect container runtime
if command -v podman &>/dev/null; then
  CTR="podman"
elif command -v docker &>/dev/null; then
  CTR="docker"
else
  echo "ERROR: Neither podman nor docker found. Install one first."
  echo "  sudo apt-get install -y podman"
  echo "  # or"
  echo "  sudo apt-get install -y docker.io"
  exit 1
fi

echo "[build] Using container runtime: ${CTR}"

# Build the image
echo "[build] Starting build..."
${CTR} build -t "${IMAGE}" -f Containerfile .

echo ""
echo "=============================================="
echo " Build complete!"
echo " Image: ${IMAGE}"
echo "=============================================="
echo ""

# Push to registry
read -p "Push to ${REGISTRY}? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "[push] Pushing ${IMAGE}..."
  ${CTR} push "${IMAGE}"
  echo "[push] Done! Image available at ${IMAGE}"
fi
