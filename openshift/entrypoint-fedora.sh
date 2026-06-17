#!/usr/bin/env bash
set -eo pipefail

# OpenShift runs containers as an arbitrary non-root UID.
# ROS2 needs a writable HOME for logging and cache.
export HOME="/tmp/ros-home"
mkdir -p "${HOME}" "${HOME}/.ros" "${HOME}/.gazebo" "${HOME}/.config" "${HOME}/.gz/sim/8"
export ROS_HOME="${HOME}/.ros"
export ROS_LOG_DIR="${HOME}/.ros/log"

# Pre-populate Gazebo server config (vendor package has broken hardcoded build paths)
if [ -f /etc/gz/sim/8/server.config ]; then
  cp /etc/gz/sim/8/server.config "${HOME}/.gz/sim/8/server.config"
fi

# Source ROS2 setup before enabling nounset (-u) because
# setup.bash references AMENT_TRACE_SETUP_FILES which may be unset.
ROS_PREFIX="${ROS_PREFIX:-/opt/ros/${ROS_DISTRO}}"

# Ensure vendor library paths are in LD_LIBRARY_PATH for Gazebo plugins
for d in /usr/lib64/ros2-jazzy/opt/*/lib64; do
  [ -d "$d" ] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
done

source "${ROS_PREFIX}/setup.bash"

set -u

export TURTLEBOT3_MODEL="${TURTLEBOT3_MODEL:-waffle}"
export GZ_SIM_RESOURCE_PATH="${ROS_PREFIX}/share/nav2_minimal_tb3_sim/models:${GZ_SIM_RESOURCE_PATH:-}"

# Detect GPU availability and configure rendering accordingly
if nvidia-smi &>/dev/null; then
  echo "[ros2-demo] NVIDIA GPU detected, configuring GPU rendering..."
  export __NV_PRIME_RENDER_OFFLOAD=1
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  GPU_AVAILABLE=true
else
  echo "[ros2-demo] No GPU detected, using software rendering..."
  export LIBGL_ALWAYS_SOFTWARE=1
  export GALLIUM_DRIVER=llvmpipe
  GPU_AVAILABLE=false
fi

WEB_PORT="${WEB_PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
WORLD_NAME="${WORLD_NAME:-tb3_sandbox}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
RESOLUTION="${RESOLUTION:-1280x720x24}"

export DISPLAY=":${DISPLAY_NUM}"

# --- 1. Virtual framebuffer ---
if [ "${GPU_AVAILABLE}" = "true" ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
echo "[ros2-demo] Starting Xvfb on display ${DISPLAY} at ${RESOLUTION}..."
Xvfb "${DISPLAY}" -screen 0 "${RESOLUTION}" +extension GLX +render -noreset &
XVFB_PID=$!
unset __EGL_VENDOR_LIBRARY_FILENAMES
sleep 2

# --- 2. Lightweight window manager ---
echo "[ros2-demo] Starting openbox window manager..."
openbox &

# --- 3. VNC server ---
echo "[ros2-demo] Starting x11vnc on port ${VNC_PORT}..."
x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" -shared -forever -nopw -noxdamage -noscr &

# --- 4. noVNC web proxy ---
echo "[ros2-demo] Starting noVNC on port ${NOVNC_PORT}..."
websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &

# --- 5. Web landing page ---
echo "[ros2-demo] Starting web landing page on port ${WEB_PORT}..."
python3 -m http.server "${WEB_PORT}" --directory /opt/ros2-demo/www &

# --- 6. Nav2 + Gazebo simulation (headless server for reliable sensors) ---
echo "[ros2-demo] Launching Nav2 TurtleBot3 simulation (headless server)..."
ros2 launch nav2_bringup tb3_simulation_launch.py \
  headless:=True \
  use_rviz:=False \
  use_sim_time:=True \
  world:="/opt/ros2-demo/worlds/tb3_sandbox.sdf.xacro" &
NAV2_PID=$!

# --- 7. Wait for Gazebo server, then launch GUI client for visualization ---
echo "[ros2-demo] Waiting for Gazebo server to start..."
for i in $(seq 1 60); do
  if gz topic -l 2>/dev/null | grep -q "/world/${WORLD_NAME}/"; then
    echo "[ros2-demo] Gazebo server detected after ${i}s, launching GUI client..."
    gz sim -g &
    GZ_GUI_PID=$!
    break
  fi
  sleep 2
done

# --- 8. Set initial pose and activate Nav2 after sensors are ready ---
(
  echo "[ros2-demo] Waiting for scan data before setting initial pose..."
  for i in $(seq 1 120); do
    if timeout 10 ros2 topic echo /scan --once 2>/dev/null | grep -q "ranges"; then
      echo "[ros2-demo] Scan data detected (attempt ${i}), setting initial pose..."
      sleep 3
      ros2 topic pub /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
        "{header: {frame_id: 'map'}, pose: {pose: {position: {x: -2.0, y: -0.5, z: 0.0}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, covariance: [0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.06853892]}}" --once 2>&1

      echo "[ros2-demo] Waiting for AMCL to publish map->odom transform..."
      for j in $(seq 1 30); do
        if timeout 5 ros2 run tf2_ros tf2_echo map odom 2>&1 | grep -q "Translation"; then
          echo "[ros2-demo] Localization active, activating navigation nodes..."
          ros2 lifecycle set /planner_server activate 2>&1 || true
          ros2 lifecycle set /bt_navigator activate 2>&1 || true
          ros2 lifecycle set /behavior_server activate 2>&1 || true
          ros2 lifecycle set /velocity_smoother activate 2>&1 || true
          ros2 lifecycle set /collision_monitor activate 2>&1 || true
          echo "[ros2-demo] Navigation stack fully ready."
          break
        fi
        sleep 2
      done
      break
    fi
    sleep 5
  done
) &

term_handler() {
  echo "[ros2-demo] Shutting down..."
  kill "${GZ_GUI_PID:-}" "${NAV2_PID}" "${XVFB_PID}" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  wait "${NAV2_PID}" 2>/dev/null || true
}

trap term_handler SIGTERM SIGINT

wait "${NAV2_PID}"
