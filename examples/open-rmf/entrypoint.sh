#!/usr/bin/env bash
set -eo pipefail

export HOME="/tmp/ros-home"
mkdir -p "${HOME}/.ros" "${HOME}/.gz" "${HOME}/.config"
export ROS_HOME="${HOME}/.ros"
export ROS_LOG_DIR="${HOME}/.ros/log"

# Source ROS 2 + rmf_demos workspace
source /opt/ros/${ROS_DISTRO:-jazzy}/setup.bash
if [ -f /opt/rmf_demos/install/setup.bash ]; then
  source /opt/rmf_demos/install/setup.bash
fi

export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_fastrtps_cpp}"

# Gazebo model paths (needed for model://Open-RMF/* and other model URIs)
export GZ_SIM_RESOURCE_PATH="/opt/fuel_models:/opt/rmf_models:/opt/rmf_demos/install/rmf_demos_assets/share/rmf_demos_assets/models:/opt/rmf_demos/install/rmf_demos_maps/share/rmf_demos_maps/maps/hotel/models${GZ_SIM_RESOURCE_PATH:+:$GZ_SIM_RESOURCE_PATH}"
export GZ_FUEL_CACHE_PATH="${GZ_FUEL_CACHE_PATH:-/opt/gz_fuel_cache}"

# --- Configuration ---
WEB_PORT="${WEB_PORT:-8080}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
RESOLUTION="${RESOLUTION:-1280x800x24}"
export DISPLAY=":${DISPLAY_NUM}"

echo "=============================================="
echo " Open-RMF Hotel Demo"
echo " 3 fleets | 4 robots | lifts | doors"
echo "=============================================="

# --- 1. Virtual display + VNC (for RViz2 schedule visualizer) ---
echo "[demo] Starting Xvnc on display ${DISPLAY}..."
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM}

Xvnc "${DISPLAY}" -geometry "${RESOLUTION%x*}" -depth 24 \
  -rfbport "${VNC_PORT}" -SecurityTypes None -ac -pn -AlwaysShared \
  -FrameRate 5 -CompareFB 1 -UseBlacklist 0 2>/dev/null &
XVNC_PID=$!
sleep 2

# Window manager (must start before RViz2 so windows are managed/visible)
openbox &
sleep 1

# noVNC web proxy
websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" 2>/dev/null &
echo "[demo] noVNC available at http://localhost:${NOVNC_PORT}"

# --- 2. Landing page ---
echo "[demo] Starting landing page on port ${WEB_PORT}..."
python3 -m http.server "${WEB_PORT}" --directory /opt/ros2-demo/www 2>/dev/null &

# --- 3. rmf-web API server + Dashboard (single port, no proxy) ---
echo "[demo] Starting rmf-web API server + dashboard on port 8000..."
mkdir -p /opt/rmf-web/packages/api-server/run/cache 2>/dev/null || \
  mkdir -p /tmp/ros-home/api-cache

DASHBOARD_DIR=""
if [ -d /opt/rmf-web/dashboard-dist ]; then
  DASHBOARD_DIR="/opt/rmf-web/dashboard-dist"
  # Replace hardcoded localhost URLs with window.location.origin so Socket.IO
  # connects to the correct server (new URL("") throws TypeError in browsers)
  find "${DASHBOARD_DIR}" -name "*.js" -exec sed -i 's|"http://localhost:8000"|window.location.origin|g' {} + 2>/dev/null || true
  find "${DASHBOARD_DIR}" -name "*.js" -exec sed -i 's|"http://localhost:8006"|window.location.origin|g' {} + 2>/dev/null || true
fi

if [ -d /opt/rmf-web/packages/api-server ]; then
  cd /opt/rmf-web/packages/api-server
  if [ ! -w run/cache ]; then
    mkdir -p /tmp/ros-home/api-cache
    ln -sf /tmp/ros-home/api-cache run/cache 2>/dev/null || true
  fi
  python3 /opt/rmf-web/serve_all.py &
  API_PID=$!
  cd /opt/ros2-demo
else
  echo "[demo] WARN: rmf-web API server not found, skipping"
  API_PID=""
fi
sleep 2

# --- 4. Launch rmf_demos Hotel (headless Gazebo + RMF core + fleet adapters) ---
echo "[demo] Launching Hotel world (headless Gazebo + slot car + RMF)..."

ros2 launch rmf_demos_gz hotel.launch.xml \
  headless:=true \
  ${API_PID:+server_uri:=ws://localhost:8000/_internal} \
  use_sim_time:=true &
SIM_PID=$!

# --- 5. RViz2 schedule visualizer (optional, software-rendered) ---
(
  echo "[demo] Waiting for simulation to start before launching RViz2..."
  sleep 30

  if command -v rviz2 &>/dev/null; then
    echo "[demo] Launching RViz2 schedule visualizer..."
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    export MESA_GL_VERSION_OVERRIDE=3.3
    RVIZ_CONFIG="/opt/rmf_demos/install/rmf_demos/share/rmf_demos/include/hotel/hotel.rviz"
    if [ -f "$RVIZ_CONFIG" ]; then
      nice -n 19 rviz2 -d "$RVIZ_CONFIG" --ros-args -p use_sim_time:=true 2>/dev/null &
    else
      nice -n 19 rviz2 -d /opt/ros/jazzy/share/rmf_visualization_schedule/config/rmf.rviz --ros-args -p use_sim_time:=true 2>/dev/null &
    fi
  else
    echo "[demo] WARN: rviz2 not available"
  fi
) &

echo ""
echo "=============================================="
echo " Demo is starting up..."
echo ""
echo " Dashboard:  http://localhost:8000"
echo " noVNC:      http://localhost:${NOVNC_PORT}"
echo " Landing:    http://localhost:${WEB_PORT}"
echo ""
echo " Dispatch tasks via CLI:"
echo "   ros2 run rmf_demos_tasks dispatch_patrol \\"
echo "     -p lobby restaurant shop -n 1 --use_sim_time"
echo "   ros2 run rmf_demos_tasks dispatch_clean \\"
echo "     -cs clean_lobby --use_sim_time"
echo "=============================================="

# --- Signal handling ---
term_handler() {
  echo "[demo] Shutting down..."
  kill "${SIM_PID:-}" "${API_PID:-}" "${XVNC_PID:-}" 2>/dev/null || true
  pkill -P $$ 2>/dev/null || true
  wait "${SIM_PID}" 2>/dev/null || true
}

trap term_handler SIGTERM SIGINT

wait "${SIM_PID}"
