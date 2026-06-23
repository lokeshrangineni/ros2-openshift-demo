#!/usr/bin/env bash
set -eo pipefail

# Nav2 robot pod entrypoint for the distributed deployment.
# Runs: Nav2 navigation stack (AMCL, planner, controller, BT navigator,
#       map server, behavior server, velocity smoother, collision monitor).
# Gazebo runs in a separate pod; topics arrive via zenoh-bridge-ros2dds.

export HOME="/tmp/ros-home"
mkdir -p "${HOME}" "${HOME}/.ros" "${HOME}/.config"
export ROS_HOME="${HOME}/.ros"
export ROS_LOG_DIR="${HOME}/.ros/log"

ROS_PREFIX="${ROS_PREFIX:-/opt/ros/${ROS_DISTRO}}"

for d in /usr/lib64/ros-jazzy/opt/*/lib64; do
  [ -d "$d" ] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
done

source "${ROS_PREFIX}/setup.bash"

set -u

export TURTLEBOT3_MODEL="${TURTLEBOT3_MODEL:-waffle}"

BRINGUP_DIR="${ROS_PREFIX}/share/nav2_bringup"

echo "[nav2-pod] Launching Nav2 bringup (navigation + localization)..."
ros2 launch nav2_bringup bringup_launch.py \
  use_sim_time:=True \
  autostart:=True \
  use_composition:=False \
  map:="${BRINGUP_DIR}/maps/tb3_sandbox.yaml" \
  params_file:="${BRINGUP_DIR}/params/nav2_params.yaml" &
NAV2_PID=$!

# Wait for Nav2 nodes to load, then set initial pose so AMCL can localize
(
  echo "[nav2-pod] Waiting for AMCL node to load before setting initial pose..."
  for i in $(seq 1 180); do
    if ros2 node list 2>/dev/null | grep -q "/amcl"; then
      echo "[nav2-pod] AMCL node detected (attempt ${i}), waiting for it to activate..."
      sleep 10

      echo "[nav2-pod] Publishing initial pose..."
      ros2 topic pub /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
        "{header: {frame_id: 'map'}, pose: {pose: {position: {x: -2.0, y: -0.5, z: 0.0}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, covariance: [0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.06853892]}}" --once 2>&1

      echo "[nav2-pod] Waiting for AMCL to publish map->odom transform..."
      for j in $(seq 1 60); do
        if timeout 5 ros2 run tf2_ros tf2_echo map odom 2>&1 | grep -q "Translation"; then
          echo "[nav2-pod] Localization active, navigation stack ready."
          break
        fi
        sleep 2
      done
      break
    fi
    sleep 5
  done
) &

echo "[nav2-pod] Nav2 robot pod started."

term_handler() {
  echo "[nav2-pod] Shutting down..."
  kill "${NAV2_PID}" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  wait "${NAV2_PID}" 2>/dev/null || true
}

trap term_handler SIGTERM SIGINT

wait "${NAV2_PID}"
