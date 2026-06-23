#!/usr/bin/env bash
set -eo pipefail

# Gazebo simulation pod entrypoint for the distributed deployment.
# Runs: Gazebo server, robot spawn, ros_gz_bridge, robot_state_publisher,
#       display stack (Xvfb + VNC + noVNC), and web landing page.
# Nav2 runs in a separate pod; topics are bridged via zenoh-bridge-ros2dds.

export HOME="/tmp/ros-home"
mkdir -p "${HOME}" "${HOME}/.ros" "${HOME}/.gazebo" "${HOME}/.config" "${HOME}/.gz/sim/8"
export ROS_HOME="${HOME}/.ros"
export ROS_LOG_DIR="${HOME}/.ros/log"

if [ -f /etc/gz/sim/8/server.config ]; then
  cp /etc/gz/sim/8/server.config "${HOME}/.gz/sim/8/server.config"
fi

ROS_PREFIX="${ROS_PREFIX:-/opt/ros/${ROS_DISTRO}}"

for d in /usr/lib64/ros-jazzy/opt/*/lib64; do
  [ -d "$d" ] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
done

source "${ROS_PREFIX}/setup.bash"

set -u

export TURTLEBOT3_MODEL="${TURTLEBOT3_MODEL:-waffle}"
export GZ_SIM_RESOURCE_PATH="${ROS_PREFIX}/share:${ROS_PREFIX}/share/nav2_minimal_tb3_sim/models:${GZ_SIM_RESOURCE_PATH:-}"

if nvidia-smi &>/dev/null; then
  echo "[gazebo-pod] NVIDIA GPU detected, configuring GPU rendering..."
  export __NV_PRIME_RENDER_OFFLOAD=1
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  GPU_AVAILABLE=true
else
  echo "[gazebo-pod] No GPU detected, using software rendering..."
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
echo "[gazebo-pod] Starting Xvfb on display ${DISPLAY} at ${RESOLUTION}..."
Xvfb "${DISPLAY}" -screen 0 "${RESOLUTION}" +extension GLX +render -noreset &
XVFB_PID=$!
unset __EGL_VENDOR_LIBRARY_FILENAMES
sleep 2

# --- 2. Window manager ---
echo "[gazebo-pod] Starting openbox window manager..."
openbox &

# --- 3. VNC server ---
echo "[gazebo-pod] Starting x11vnc on port ${VNC_PORT}..."
x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" -shared -forever -nopw -noxdamage -noscr &

# --- 4. noVNC web proxy ---
echo "[gazebo-pod] Starting noVNC on port ${NOVNC_PORT}..."
websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &

# --- 5. Web landing page ---
echo "[gazebo-pod] Starting web landing page on port ${WEB_PORT}..."
python3 -m http.server "${WEB_PORT}" --directory /opt/ros2-demo/www &

# --- 6. Process world xacro and start Gazebo server ---
SIM_DIR="${ROS_PREFIX}/share/nav2_minimal_tb3_sim"
WORLD_SDF="/tmp/ros-home/world.sdf"

echo "[gazebo-pod] Processing world xacro..."
xacro -o "${WORLD_SDF}" "headless:=True" \
  "/opt/ros2-demo/worlds/tb3_sandbox.sdf.xacro"

echo "[gazebo-pod] Starting Gazebo server..."
gz sim -r -s "${WORLD_SDF}" &
GZ_SERVER_PID=$!

# --- 7. Wait for Gazebo, then spawn robot + start ros_gz_bridge ---
echo "[gazebo-pod] Waiting for Gazebo server to start..."
for i in $(seq 1 60); do
  if gz topic -l 2>/dev/null | grep -q "/world/${WORLD_NAME}/"; then
    echo "[gazebo-pod] Gazebo server detected after $((i * 2))s"
    break
  fi
  sleep 2
done

echo "[gazebo-pod] Spawning TurtleBot3 and starting ros_gz_bridge..."
ros2 launch nav2_minimal_tb3_sim spawn_tb3.launch.py \
  use_sim_time:=True \
  robot_name:=turtlebot3_waffle \
  x_pose:=-2.00 y_pose:=-0.50 z_pose:=0.01 &
SPAWN_PID=$!

# --- 8. Start robot_state_publisher ---
URDF_FILE="${SIM_DIR}/urdf/turtlebot3_waffle.urdf"
echo "[gazebo-pod] Starting robot_state_publisher..."
ros2 run robot_state_publisher robot_state_publisher \
  --ros-args \
  -p use_sim_time:=true \
  -p "robot_description:=$(cat "${URDF_FILE}")" &

# --- 9. Launch Gazebo GUI client for visualization ---
echo "[gazebo-pod] Waiting for Gazebo topics, then launching GUI..."
for i in $(seq 1 30); do
  if gz topic -l 2>/dev/null | grep -q "/world/${WORLD_NAME}/"; then
    gz sim -g &
    GZ_GUI_PID=$!
    echo "[gazebo-pod] Gazebo GUI launched."
    break
  fi
  sleep 2
done

echo "[gazebo-pod] Gazebo simulation pod ready."

term_handler() {
  echo "[gazebo-pod] Shutting down..."
  kill "${GZ_GUI_PID:-}" "${SPAWN_PID:-}" "${GZ_SERVER_PID}" "${XVFB_PID}" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  wait "${GZ_SERVER_PID}" 2>/dev/null || true
}

trap term_handler SIGTERM SIGINT

wait "${GZ_SERVER_PID}"
