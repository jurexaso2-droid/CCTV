#!/data/data/com.termux/files/usr/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
PORT=8080
AUTH_USER="admin"
AUTH_PASS="password123"
RECORDING_DIR="/data/data/com.termux/files/home/storage/shared/CCTVRecordings"
USE_CLOUDFLARED=false
CLOUDFLARED_DIR="/data/data/com.termux/files/home/.cloudflared"
SNAPSHOT_INTERVAL=10
CAMERA_INDEX=0

# Banner
echo -e "${GREEN}"
cat << "EOF"
   ____ ____ _______ _______ 
  / ___|___ \__   __|__   __|
 | |     __) | | |     | |   
 | |___ / __/  | |     | |   
  \____|_____| |_|     |_|   
EOF
echo -e "${NC}"
echo "Home CCTV System for Termux"
echo "============================"

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing dependencies...${NC}"
    pkg update && pkg upgrade -y
    pkg install -y python ffmpeg termux-api wget
    
    echo -e "${YELLOW}[*] Installing Python packages...${NC}"
    pip install flask flask-basicauth requests pillow
    
    echo -e "${YELLOW}[*] Setting up storage permissions...${NC}"
    # Request storage permission
    termux-setup-storage
    
    # Create necessary directories
    mkdir -p $RECORDING_DIR
    mkdir -p ~/.cctv
    mkdir -p $CLOUDFLARED_DIR
    
    echo -e "${GREEN}[+] Dependencies installed successfully${NC}"
}

# Function to check camera permissions and access
check_camera_permission() {
    echo -e "${YELLOW}[*] Checking camera permissions...${NC}"
    
    # Test camera access using ffmpeg
    if timeout 10s ffmpeg -f video4linux2 -list_formats all -i /dev/video0 2>&1 | grep -q "Raw"; then
        echo -e "${GREEN}[+] Camera access confirmed${NC}"
        return 0
    else
        echo -e "${RED}[!] Camera access denied or no camera available${NC}"
        echo -e "${YELLOW}[*] Please grant camera permission to Termux:${NC}"
        echo -e "${CYAN}   1. Open Termux App${NC}"
        echo -e "${CYAN}   2. Tap the three dots menu (⋮)${NC}"
        echo -e "${CYAN}   3. Go to 'App Settings'${NC}"
        echo -e "${CYAN}   4. Tap 'Permissions'${NC}"
        echo -e "${CYAN}   5. Enable 'Camera' permission${NC}"
        echo -e "${CYAN}   6. Restart Termux${NC}"
        return 1
    fi
}

# Function to detect available cameras
detect_cameras() {
    echo -e "${YELLOW}[*] Detecting available cameras...${NC}"
    
    CAMERAS=()
    for i in {0..2}; do
        if [ -e "/dev/video$i" ]; then
            if timeout 5s ffmpeg -f video4linux2 -list_formats all -i /dev/video$i > /dev/null 2>&1; then
                CAMERA_INFO=$(timeout 5s ffmpeg -f video4linux2 -list_formats all -i /dev/video$i 2>&1 | head -10)
                if echo "$CAMERA_INFO" | grep -q "Raw"; then
                    echo -e "${GREEN}[+] Camera $i detected and accessible${NC}"
                    CAMERAS+=("$i")
                fi
            fi
        fi
    done
    
    if [ ${#CAMERAS[@]} -eq 0 ]; then
        echo -e "${RED}[!] No accessible cameras found${NC}"
        return 1
    else
        echo -e "${GREEN}[+] Found ${#CAMERAS[@]} camera(s): ${CAMERAS[*]}${NC}"
        return 0
    fi
}

# Function to test camera capture
test_camera_capture() {
    local camera_index=$1
    echo -e "${YELLOW}[*] Testing camera $camera_index capture...${NC}"
    
    TEST_FILE="/data/data/com.termux/files/home/test_camera_$camera_index.jpg"
    
    if timeout 15s ffmpeg -y -f video4linux2 -i /dev/video$camera_index -vframes 1 -s 640x480 -q:v 2 "$TEST_FILE" > /dev/null 2>&1; then
        if [ -f "$TEST_FILE" ] && [ $(stat -c%s "$TEST_FILE") -gt 1000 ]; then
            echo -e "${GREEN}[✅] Camera $camera_index capture successful${NC}"
            rm -f "$TEST_FILE"
            return 0
        else
            echo -e "${RED}[❌] Camera $camera_index capture failed (empty image)${NC}"
            rm -f "$TEST_FILE" 2>/dev/null
            return 1
        fi
    else
        echo -e "${RED}[❌] Camera $camera_index capture failed${NC}"
        rm -f "$TEST_FILE" 2>/dev/null
        return 1
    fi
}

# Function to install cloudflared
install_cloudflared() {
    echo -e "${YELLOW}[*] Installing Cloudflared...${NC}"
    
    # Download cloudflared
    ARCH=$(uname -m)
    case $ARCH in
        aarch64)
            ARCH="arm64"
            ;;
        armv7l|armv8l)
            ARCH="arm"
            ;;
        i686)
            ARCH="386"
            ;;
        x86_64)
            ARCH="amd64"
            ;;
        *)
            ARCH="arm64"
            ;;
    esac
    
    cd $CLOUDFLARED_DIR
    wget -q "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" -O cloudflared
    chmod +x cloudflared
    
    if [ -f "cloudflared" ]; then
        echo -e "${GREEN}[+] Cloudflared installed successfully${NC}"
        echo -e "${YELLOW}[*] To use Cloudflared tunnel, run: ./cctv.sh start --tunnel${NC}"
    else
        echo -e "${RED}[!] Cloudflared installation failed${NC}"
    fi
    
    cd - > /dev/null
}

# Function to setup configuration
setup_config() {
    echo -e "${YELLOW}[*] Setting up configuration...${NC}"
    
    read -p "Enter port number (default: 8080): " custom_port
    if [ ! -z "$custom_port" ]; then
        PORT=$custom_port
    fi
    
    read -p "Enter username (default: admin): " custom_user
    if [ ! -z "$custom_user" ]; then
        AUTH_USER=$custom_user
    fi
    
    read -p "Enter password (default: password123): " custom_pass
    if [ ! -z "$custom_pass" ]; then
        AUTH_PASS=$custom_pass
    fi
    
    read -p "Enter snapshot interval in seconds (default: 10): " custom_interval
    if [ ! -z "$custom_interval" ]; then
        SNAPSHOT_INTERVAL=$custom_interval
    fi
    
    # Camera detection and selection
    echo -e "${YELLOW}[*] Camera setup${NC}"
    if detect_cameras; then
        echo "Available cameras: ${CAMERAS[*]}"
        echo "Note: Camera 0 is usually back camera, Camera 1 is usually front camera"
        read -p "Select camera index (0, 1, etc.): " camera_choice
        if [[ " ${CAMERAS[*]} " =~ " ${camera_choice} " ]]; then
            CAMERA_INDEX=$camera_choice
            echo -e "${YELLOW}[*] Testing selected camera...${NC}"
            if test_camera_capture $CAMERA_INDEX; then
                echo -e "${GREEN}[+] Camera $CAMERA_INDEX selected and working${NC}"
            else
                echo -e "${RED}[!] Camera $CAMERA_INDEX test failed${NC}"
                read -p "Do you want to continue anyway? (y/n): " continue_anyway
                if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}[*] Please check camera permissions and try again${NC}"
                    exit 1
                fi
            fi
        else
            echo -e "${RED}[!] Invalid camera selection. Using default: 0${NC}"
            CAMERA_INDEX=0
        fi
    else
        echo -e "${RED}[!] No cameras detected. Using default camera index 0${NC}"
        CAMERA_INDEX=0
    fi
    
    echo -e "${YELLOW}[*] Storage location setup${NC}"
    echo "Options:"
    echo "1. Internal Storage (Recommended) - /storage/emulated/0/CCTVRecordings"
    echo "2. Termux Shared Storage - /data/data/com.termux/files/home/storage/shared/CCTVRecordings"
    echo "3. SD Card - /sdcard/CCTVRecordings"
    echo "4. Custom path"
    read -p "Choose storage option (1-4): " storage_choice
    
    case $storage_choice in
        1)
            RECORDING_DIR="/storage/emulated/0/CCTVRecordings"
            ;;
        2)
            RECORDING_DIR="/data/data/com.termux/files/home/storage/shared/CCTVRecordings"
            ;;
        3)
            RECORDING_DIR="/sdcard/CCTVRecordings"
            ;;
        4)
            read -p "Enter custom storage path: " custom_path
            RECORDING_DIR="$custom_path"
            ;;
        *)
            RECORDING_DIR="/storage/emulated/0/CCTVRecordings"
            echo -e "${YELLOW}[*] Using default: Internal Storage${NC}"
            ;;
    esac
    
    # Create the directory
    echo -e "${YELLOW}[*] Creating directory: $RECORDING_DIR${NC}"
    mkdir -p "$RECORDING_DIR"
    
    # Ask about Cloudflared
    echo -e "${YELLOW}[*] Cloudflared Tunnel Setup${NC}"
    read -p "Do you want to enable Cloudflared tunnel for remote access? (y/n): " enable_tunnel
    if [[ $enable_tunnel == "y" || $enable_tunnel == "Y" ]]; then
        USE_CLOUDFLARED=true
        install_cloudflared
    fi
    
    # Save configuration
    cat > ~/.cctv/config << EOF
PORT=$PORT
AUTH_USER=$AUTH_USER
AUTH_PASS=$AUTH_PASS
RECORDING_DIR=$RECORDING_DIR
USE_CLOUDFLARED=$USE_CLOUDFLARED
CLOUDFLARED_DIR=$CLOUDFLARED_DIR
SNAPSHOT_INTERVAL=$SNAPSHOT_INTERVAL
CAMERA_INDEX=$CAMERA_INDEX
EOF
    
    echo -e "${GREEN}[+] Configuration saved to ~/.cctv/config${NC}"
    echo -e "${GREEN}[+] Snapshots will be saved to: $RECORDING_DIR${NC}"
    echo -e "${GREEN}[+] Snapshot interval: $SNAPSHOT_INTERVAL seconds${NC}"
    echo -e "${GREEN}[+] Camera selected: /dev/video$CAMERA_INDEX${NC}"
    if [ "$USE_CLOUDFLARED" = true ]; then
        echo -e "${GREEN}[+] Cloudflared tunnel enabled${NC}"
    fi
}

# Function to get device IP
get_ip() {
    echo -e "${YELLOW}[*] Getting device IP address...${NC}"
    IP=$(ifconfig 2>/dev/null | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -n1)
    
    if [ -z "$IP" ]; then
        IP=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -n1)
    fi
    
    if [ -z "$IP" ]; then
        IP="Unable to detect. Use localhost or check connection"
    fi
    
    echo -e "${GREEN}[+] Local Access: ${BLUE}http://$IP:$PORT${NC}"
}

# Function to create enhanced HTML template
create_html_template() {
    cat > cctv_template.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home CCTV Security System</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a2a3a, #0d1b2a);
            color: #ffffff;
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        .header {
            text-align: center;
            margin-bottom: 30px;
            padding: 20px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(45deg, #4facfe, #00f2fe);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .status-bar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 15px;
            margin-bottom: 20px;
        }

        .status-item {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            flex: 1;
            min-width: 200px;
            text-align: center;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        .status-online {
            border-left: 4px solid #4CAF50;
        }

        .status-warning {
            border-left: 4px solid #FF9800;
        }

        .status-error {
            border-left: 4px solid #f44336;
        }

        .video-container {
            background: rgba(0, 0, 0, 0.5);
            border-radius: 15px;
            padding: 20px;
            margin-bottom: 20px;
            border: 2px solid rgba(255, 255, 255, 0.1);
            position: relative;
            text-align: center;
        }

        .video-feed {
            max-width: 100%;
            border-radius: 10px;
            background: #000;
            min-height: 400px;
            max-height: 600px;
        }

        .controls {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }

        .btn {
            padding: 15px 25px;
            border: none;
            border-radius: 10px;
            font-size: 16px;
            font-weight: bold;
            cursor: pointer;
            transition: all 0.3s ease;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }

        .btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(0, 0, 0, 0.3);
        }

        .btn-snapshot {
            background: linear-gradient(45deg, #4CAF50, #45a049);
            color: white;
        }

        .btn-stop {
            background: linear-gradient(45deg, #2196F3, #1976D2);
            color: white;
        }

        .btn-refresh {
            background: linear-gradient(45deg, #FF9800, #F57C00);
            color: white;
        }

        .btn-camera {
            background: linear-gradient(45deg, #9C27B0, #7B1FA2);
            color: white;
        }

        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
            transform: none;
        }

        .recordings {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            padding: 20px;
            margin-top: 20px;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        .recordings h3 {
            margin-bottom: 15px;
            color: #4facfe;
        }

        .file-list {
            max-height: 200px;
            overflow-y: auto;
        }

        .file-item {
            padding: 10px;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .file-item:last-child {
            border-bottom: none;
        }

        .notification {
            position: fixed;
            top: 20px;
            right: 20px;
            padding: 15px 25px;
            border-radius: 10px;
            background: #4CAF50;
            color: white;
            box-shadow: 0 5px 15px rgba(0, 0, 0, 0.3);
            transform: translateX(400px);
            transition: transform 0.3s ease;
            z-index: 1000;
        }

        .notification.show {
            transform: translateX(0);
        }

        .notification.error {
            background: #f44336;
        }

        .notification.warning {
            background: #FF9800;
        }

        .connection-info {
            background: rgba(255, 255, 255, 0.05);
            padding: 15px;
            border-radius: 10px;
            margin-top: 20px;
            font-family: monospace;
            font-size: 14px;
        }

        .auto-snapshot {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            margin: 15px 0;
            text-align: center;
        }

        .camera-info {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            margin: 10px 0;
            text-align: center;
        }

        .permission-guide {
            background: rgba(255, 193, 7, 0.2);
            border: 1px solid #FFC107;
            border-radius: 10px;
            padding: 15px;
            margin: 15px 0;
        }

        @media (max-width: 768px) {
            .status-bar {
                flex-direction: column;
            }
            
            .status-item {
                width: 100%;
            }
            
            .controls {
                grid-template-columns: 1fr;
            }
            
            .btn {
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Home CCTV Security System</h1>
            <p>Auto Snapshot Monitoring - Images update every {{ snapshot_interval }} seconds</p>
        </div>

        <div class="status-bar">
            <div class="status-item {{ status_class }}">
                <h3>{{ status_icon }} SYSTEM STATUS</h3>
                <p>{{ status_message }}</p>
            </div>
            <div class="status-item">
                <h3>📸 SNAPSHOT MODE</h3>
                <p>Interval: {{ snapshot_interval }}s</p>
            </div>
            <div class="status-item">
                <h3>📊 SYSTEM INFO</h3>
                <p>Storage: <span id="storage-info">Loading...</span></p>
            </div>
        </div>

        {% if not camera_working %}
        <div class="permission-guide">
            <h3>🔒 Camera Permission Required</h3>
            <p>To enable camera access:</p>
            <ol>
                <li>Open Termux App</li>
                <li>Tap the three dots menu (⋮)</li>
                <li>Go to 'App Settings' → 'Permissions'</li>
                <li>Enable 'Camera' permission</li>
                <li>Restart Termux and try again</li>
            </ol>
            <button class="btn btn-camera" onclick="retryCamera()">🔄 Retry Camera Access</button>
        </div>
        {% endif %}

        <div class="camera-info">
            <h3>📷 Camera: {{ camera_name }}</h3>
            <p>Device: /dev/video{{ camera_index }}</p>
        </div>

        <div class="auto-snapshot">
            <h3>🔄 Auto Snapshot Mode</h3>
            <p>Latest image automatically updates every {{ snapshot_interval }} seconds</p>
            <p>Last updated: <span id="last-update">Just now</span></p>
        </div>

        <div class="video-container">
            <img id="video-feed" class="video-feed" src="/latest_snapshot?t={{ timestamp }}" 
                 alt="Latest CCTV Snapshot" onerror="showCameraError()">
            <div style="margin-top: 10px;">
                <small>Image will auto-refresh every {{ snapshot_interval }} seconds</small>
            </div>
        </div>

        <div class="controls">
            <button class="btn btn-snapshot" onclick="takeSnapshot()" id="snapshot-btn">
                <span class="btn-icon">📸</span>
                <span class="btn-text">Take Manual Snapshot</span>
            </button>
            
            <button class="btn btn-camera" onclick="switchCamera()" id="camera-btn">
                <span class="btn-icon">🔄</span>
                <span class="btn-text">Switch Camera</span>
            </button>
            
            <button class="btn btn-refresh" onclick="refreshFeed()">
                <span class="btn-icon">🔄</span>
                <span class="btn-text">Refresh Now</span>
            </button>
            
            <button class="btn btn-stop" onclick="stopServer()">
                <span class="btn-icon">🛑</span>
                <span class="btn-text">Stop Server</span>
            </button>
        </div>

        <div class="connection-info">
            <strong>Connection Info:</strong><br>
            Device: {{ device_ip }}<br>
            Started: {{ start_time }}<br>
            Storage: {{ storage_path }}<br>
            Snapshot Interval: {{ snapshot_interval }} seconds<br>
            Camera: /dev/video{{ camera_index }} ({{ camera_name }})<br>
            {% if tunnel_url %}
            Public URL: <a href="{{ tunnel_url }}" target="_blank" style="color: #4facfe;">{{ tunnel_url }}</a><br>
            {% endif %}
        </div>

        <div class="recordings">
            <h3>📁 Recent Snapshots</h3>
            <div class="file-list" id="file-list">
                <div class="file-item">Loading files...</div>
            </div>
        </div>
    </div>

    <div id="notification" class="notification"></div>

    <script>
        let lastUpdateTime = new Date();
        let cameraWorking = {{ 'true' if camera_working else 'false' }};

        function updateLastUpdateTime() {
            const now = new Date();
            lastUpdateTime = now;
            document.getElementById('last-update').textContent = now.toLocaleTimeString();
        }

        function showNotification(message, isError = false, isWarning = false) {
            const notification = document.getElementById('notification');
            notification.textContent = message;
            notification.className = 'notification';
            if (isError) {
                notification.classList.add('error');
            } else if (isWarning) {
                notification.classList.add('warning');
            }
            notification.classList.add('show');
            
            setTimeout(() => {
                notification.classList.remove('show');
            }, 5000);
        }

        function takeSnapshot() {
            const btn = document.getElementById('snapshot-btn');
            btn.disabled = true;
            
            fetch('/manual_snapshot')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showNotification('Manual snapshot saved: ' + data.filename);
                        loadFileList();
                        refreshFeed();
                    } else {
                        showNotification('Error: ' + data.message, true);
                    }
                })
                .catch(error => {
                    showNotification('Network error: ' + error, true);
                })
                .finally(() => {
                    btn.disabled = false;
                });
        }

        function switchCamera() {
            fetch('/switch_camera')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        showNotification('Camera switched: ' + data.message, false, true);
                        setTimeout(() => {
                            location.reload();
                        }, 2000);
                    } else {
                        showNotification('Error: ' + data.message, true);
                    }
                })
                .catch(error => {
                    showNotification('Network error: ' + error, true);
                });
        }

        function retryCamera() {
            showNotification('Retrying camera access...', false, true);
            setTimeout(() => {
                location.reload();
            }, 1000);
        }

        function stopServer() {
            if (confirm('Are you sure you want to stop the CCTV server? This will disconnect all clients.')) {
                fetch('/stop_server')
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            showNotification('Server stopping...');
                            setTimeout(() => {
                                window.close();
                            }, 2000);
                        }
                    });
            }
        }

        function refreshFeed() {
            const videoFeed = document.getElementById('video-feed');
            const currentSrc = videoFeed.src.split('?')[0];
            videoFeed.src = currentSrc + '?t=' + new Date().getTime();
            updateLastUpdateTime();
            showNotification('Snapshot refreshed');
        }

        function showCameraError() {
            showNotification('Error loading snapshot. Camera may be unavailable.', true);
            cameraWorking = false;
        }

        function loadFileList() {
            fetch('/file_list')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        const fileList = document.getElementById('file-list');
                        fileList.innerHTML = '';
                        
                        if (data.files.length === 0) {
                            fileList.innerHTML = '<div class="file-item">No snapshots yet</div>';
                            return;
                        }
                        
                        data.files.forEach(file => {
                            const fileItem = document.createElement('div');
                            fileItem.className = 'file-item';
                            fileItem.innerHTML = `
                                <span>${file.name}</span>
                                <span>${file.size}</span>
                            `;
                            fileList.appendChild(fileItem);
                        });
                    }
                });
        }

        function updateStorageInfo() {
            fetch('/storage_info')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        document.getElementById('storage-info').textContent = 
                            `${data.used_mb} MB used (${data.file_count} files)`;
                    }
                });
        }

        // Auto-refresh the image
        function startAutoRefresh() {
            setInterval(() => {
                if (cameraWorking) {
                    refreshFeed();
                }
            }, {{ snapshot_interval * 1000 }});
        }

        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            updateLastUpdateTime();
            loadFileList();
            updateStorageInfo();
            
            if (cameraWorking) {
                startAutoRefresh();
            }
            
            // Refresh file list every 30 seconds
            setInterval(loadFileList, 30000);
            setInterval(updateStorageInfo, 60000);
        });

        // Handle page visibility change
        document.addEventListener('visibilitychange', function() {
            if (!document.hidden && cameraWorking) {
                refreshFeed();
            }
        });
    </script>
</body>
</html>
EOF
}

# Function to create Python CCTV server with camera management
create_server_script() {
    cat > cctv_server.py << EOF
#!/data/data/com.termux/files/usr/bin/python3

import flask
from flask import Flask, Response, render_template_string, jsonify, send_file, request
from flask_basicauth import BasicAuth
import os
import time
from datetime import datetime
import threading
import subprocess
import signal
import sys
import json

app = Flask(__name__)

# Basic Authentication
app.config['BASIC_AUTH_USERNAME'] = '$AUTH_USER'
app.config['BASIC_AUTH_PASSWORD'] = '$AUTH_PASS'
app.config['BASIC_AUTH_FORCE'] = True

basic_auth = BasicAuth(app)

# Global variables
tunnel_url = None
latest_snapshot = None
snapshot_interval = $SNAPSHOT_INTERVAL
camera_index = $CAMERA_INDEX
camera_working = False
available_cameras = [0, 1]  # Common camera indices

# Read HTML template
with open('cctv_template.html', 'r') as f:
    HTML_TEMPLATE = f.read()

def take_ffmpeg_snapshot(filename=None, retry_count=2):
    """Take a snapshot using ffmpeg with retry logic"""
    for attempt in range(retry_count + 1):
        try:
            if filename is None:
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                filename = f"snapshot_{timestamp}.jpg"
            
            filepath = os.path.join('$RECORDING_DIR', filename)
            
            # Use ffmpeg to capture image from camera
            result = subprocess.run([
                'ffmpeg', '-y',
                '-f', 'video4linux2',
                '-i', f'/dev/video{camera_index}',
                '-vframes', '1',
                '-s', '640x480',
                '-q:v', '2',
                filepath
            ], capture_output=True, text=True, timeout=15)
            
            if result.returncode == 0 and os.path.exists(filepath):
                file_size = os.path.getsize(filepath)
                if file_size > 1000:  # Ensure we have a valid image
                    return {'success': True, 'filename': filename, 'filepath': filepath}
                else:
                    os.remove(filepath)
                    print(f"Attempt {attempt + 1}: Empty image file")
            else:
                print(f"Attempt {attempt + 1}: FFmpeg failed with: {result.stderr}")
                
        except subprocess.TimeoutExpired:
            print(f"Attempt {attempt + 1}: Timeout capturing image")
        except Exception as e:
            print(f"Attempt {attempt + 1}: Error: {e}")
        
        if attempt < retry_count:
            time.sleep(2)  # Wait before retry
    
    return {'success': False, 'error': 'Failed after multiple attempts'}

def test_camera():
    """Test if current camera is working"""
    global camera_working
    try:
        result = take_ffmpeg_snapshot('test_camera.jpg')
        if result['success']:
            camera_working = True
            # Clean up test file
            test_file = os.path.join('$RECORDING_DIR', 'test_camera.jpg')
            if os.path.exists(test_file):
                os.remove(test_file)
            return True
        else:
            camera_working = False
            return False
    except:
        camera_working = False
        return False

def auto_snapshot_worker():
    """Background worker to take automatic snapshots"""
    global latest_snapshot, camera_working
    
    while True:
        try:
            result = take_ffmpeg_snapshot('latest.jpg')
            if result['success']:
                latest_snapshot = result['filepath']
                camera_working = True
                print(f"✅ Auto snapshot taken from camera {camera_index}: {datetime.now().strftime('%H:%M:%S')}")
            else:
                camera_working = False
                print(f"❌ Auto snapshot failed from camera {camera_index}: {result.get('error', 'Unknown error')}")
                
                # Try to recover by testing camera
                if not test_camera():
                    print("⚠️ Camera recovery failed")
                    
        except Exception as e:
            camera_working = False
            print(f"❌ Auto snapshot error: {e}")
        
        time.sleep(snapshot_interval)

def get_camera_name():
    """Get descriptive name for current camera"""
    if camera_index == 0:
        return "Back Camera"
    elif camera_index == 1:
        return "Front Camera"
    else:
        return f"Camera {camera_index}"

def get_system_status():
    """Get system status for display"""
    if camera_working:
        return "🟢 ONLINE", "System running normally", "status-online"
    else:
        return "🔴 OFFLINE", "Camera not accessible", "status-error"

@app.route('/')
@basic_auth.required
def index():
    import socket
    try:
        hostname = socket.gethostname()
        device_ip = socket.gethostbyname(hostname)
    except:
        device_ip = "Unknown"
    
    status_icon, status_message, status_class = get_system_status()
    camera_name = get_camera_name()
    
    return render_template_string(HTML_TEMPLATE, 
                                 device_ip=device_ip,
                                 start_time=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                                 storage_path='$RECORDING_DIR',
                                 tunnel_url=tunnel_url,
                                 snapshot_interval=snapshot_interval,
                                 camera_index=camera_index,
                                 camera_name=camera_name,
                                 camera_working=camera_working,
                                 status_icon=status_icon,
                                 status_message=status_message,
                                 status_class=status_class,
                                 timestamp=int(time.time()))

@app.route('/latest_snapshot')
@basic_auth.required
def latest_snapshot_route():
    """Serve the latest snapshot"""
    try:
        latest_path = os.path.join('$RECORDING_DIR', 'latest.jpg')
        if os.path.exists(latest_path) and os.path.getsize(latest_path) > 1000:
            return send_file(latest_path, mimetype='image/jpeg')
        else:
            # Return a placeholder image
            return send_file('placeholder.jpg', mimetype='image/jpeg')
    except:
        return "Snapshot not available", 404

@app.route('/manual_snapshot')
@basic_auth.required
def manual_snapshot():
    """Take a manual snapshot"""
    try:
        result = take_ffmpeg_snapshot()
        if result['success']:
            return {'success': True, 'message': 'Manual snapshot saved', 'filename': result['filename']}
        else:
            return {'success': False, 'message': f"Error: {result.get('error', 'Unknown error')}"}
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

@app.route('/switch_camera')
@basic_auth.required
def switch_camera():
    """Switch between available cameras"""
    global camera_index, camera_working
    
    # Try next camera
    old_index = camera_index
    camera_index = (camera_index + 1) % 2  # Switch between 0 and 1
    
    # Test new camera
    if test_camera():
        # Save new camera index to config
        with open('/data/data/com.termux/files/home/.cctv/config', 'r') as f:
            lines = f.readlines()
        
        with open('/data/data/com.termux/files/home/.cctv/config', 'w') as f:
            for line in lines:
                if line.startswith('CAMERA_INDEX='):
                    f.write(f'CAMERA_INDEX={camera_index}\\n')
                else:
                    f.write(line)
        
        return {'success': True, 'message': f'Switched to camera {camera_index} ({get_camera_name()})'}
    else:
        # Revert to old camera
        camera_index = old_index
        test_camera()  # Test old camera
        return {'success': False, 'message': f'Camera {camera_index} not available'}

@app.route('/file_list')
@basic_auth.required
def file_list():
    try:
        files = []
        if os.path.exists('$RECORDING_DIR'):
            # Get all jpg files, sorted by modification time (newest first)
            jpg_files = [f for f in os.listdir('$RECORDING_DIR') if f.endswith('.jpg') and f != 'latest.jpg']
            jpg_files.sort(key=lambda x: os.path.getmtime(os.path.join('$RECORDING_DIR', x)), reverse=True)
            
            for filename in jpg_files[:15]:  # Show last 15 files
                filepath = os.path.join('$RECORDING_DIR', filename)
                if os.path.isfile(filepath):
                    size = os.path.getsize(filepath)
                    size_str = f"{size // 1024} KB" if size < 1024*1024 else f"{size // (1024*1024)} MB"
                    mod_time = datetime.fromtimestamp(os.path.getmtime(filepath)).strftime('%H:%M:%S')
                    files.append({'name': filename, 'size': size_str, 'time': mod_time})
        
        return {'success': True, 'files': files}
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

@app.route('/storage_info')
@basic_auth.required
def storage_info():
    try:
        total_size = 0
        file_count = 0
        
        if os.path.exists('$RECORDING_DIR'):
            for filename in os.listdir('$RECORDING_DIR'):
                filepath = os.path.join('$RECORDING_DIR', filename)
                if os.path.isfile(filepath) and filename.endswith('.jpg'):
                    total_size += os.path.getsize(filepath)
                    file_count += 1
        
        return {'success': True, 'used_mb': total_size // (1024*1024), 'file_count': file_count}
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

@app.route('/stop_server')
@basic_auth.required
def stop_server():
    print("Server shutdown requested via web interface")
    # This will be handled by the signal handler
    os.kill(os.getpid(), signal.SIGINT)
    return {'success': True, 'message': 'Server stopping...'}

def start_cloudflared_tunnel():
    global tunnel_url
    try:
        cloudflared_path = os.path.join('$CLOUDFLARED_DIR', 'cloudflared')
        if not os.path.exists(cloudflared_path):
            print("❌ Cloudflared not found. Install with: ./cctv.sh install-cloudflared")
            return
        
        print("🚀 Starting Cloudflared tunnel...")
        process = subprocess.Popen([
            cloudflared_path, 'tunnel', '--url', 'http://localhost:$PORT'
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        
        # Wait for tunnel URL
        for line in process.stderr:
            if '.trycloudflare.com' in line:
                tunnel_url = line.strip().split(' ')[-1]
                print(f"🌐 Public URL: {tunnel_url}")
                break
        
        return process
    except Exception as e:
        print(f"❌ Cloudflared error: {e}")

def create_placeholder_image():
    """Create a placeholder image if needed"""
    placeholder_path = 'placeholder.jpg'
    if not os.path.exists(placeholder_path):
        # Create a simple placeholder using ffmpeg
        try:
            subprocess.run([
                'ffmpeg', '-y',
                '-f', 'lavfi',
                '-i', 'color=c=black:s=640x480',
                '-vf', 'drawtext=text="Camera\\nLoading...":fontcolor=white:fontsize=24:x=(w-text_w)/2:y=(h-text_h)/2',
                '-frames', '1',
                placeholder_path
            ], capture_output=True, timeout=10)
        except:
            # Create a simple text file as fallback
            with open(placeholder_path, 'wb') as f:
                f.write(b'Placeholder image')

def signal_handler(sig, frame):
    print('\\nShutting down CCTV server...')
    sys.exit(0)

if __name__ == '__main__':
    # Setup signal handler for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    
    print("🚀 Starting CCTV Server...")
    print(f"📝 Username: $AUTH_USER")
    print(f"🔑 Password: $AUTH_PASS")
    print(f"📁 Storage: $RECORDING_DIR")
    print(f"📸 Snapshot Interval: {snapshot_interval} seconds")
    print(f"📷 Camera: /dev/video{camera_index}")
    print("=" * 50)
    
    # Create placeholder image
    create_placeholder_image()
    
    # Test camera initially
    print("🔍 Testing camera access...")
    if test_camera():
        print("✅ Camera test successful")
    else:
        print("❌ Camera test failed")
        print("💡 Camera permission guide:")
        print("   1. Open Termux App")
        print("   2. Tap the three dots menu (⋮)")
        print("   3. Go to 'App Settings' → 'Permissions'")
        print("   4. Enable 'Camera' permission")
        print("   5. Restart Termux and try again")
    
    # Start Cloudflared tunnel if enabled
    cloudflared_process = None
    if '$USE_CLOUDFLARED' == 'true':
        cloudflared_process = start_cloudflared_tunnel()
    
    # Start auto snapshot worker
    print("📸 Starting auto snapshot worker...")
    snapshot_thread = threading.Thread(target=auto_snapshot_worker, daemon=True)
    snapshot_thread.start()
    
    print("✅ Server started successfully")
    print("💡 The system will automatically take snapshots every", snapshot_interval, "seconds")
    print("🌐 Web interface is accessible at the URLs shown above")
    
    try:
        app.run(host='0.0.0.0', port=$PORT, debug=False, threaded=True)
    finally:
        if cloudflared_process:
            cloudflared_process.terminate()
EOF

    chmod +x cctv_server.py
}

# Function to start CCTV server
start_server() {
    local use_tunnel=false
    
    # Check for --tunnel flag
    for arg in "$@"; do
        if [ "$arg" = "--tunnel" ] || [ "$arg" = "-t" ]; then
            use_tunnel=true
            break
        fi
    done
    
    echo -e "${YELLOW}[*] Starting CCTV server...${NC}"
    
    # Check if configuration exists
    if [ ! -f ~/.cctv/config ]; then
        echo -e "${RED}[!] Configuration not found. Running setup...${NC}"
        setup_config
    fi
    
    # Load configuration
    source ~/.cctv/config
    
    # Override tunnel setting if --tunnel flag is used
    if [ "$use_tunnel" = true ]; then
        USE_CLOUDFLARED=true
        # Check if cloudflared is installed
        if [ ! -f "$CLOUDFLARED_DIR/cloudflared" ]; then
            echo -e "${YELLOW}[*] Cloudflared not found. Installing...${NC}"
            install_cloudflared
        fi
    fi
    
    # Check if storage directory exists
    if [ ! -d "$RECORDING_DIR" ]; then
        echo -e "${YELLOW}[*] Creating storage directory...${NC}"
        mkdir -p "$RECORDING_DIR"
    fi
    
    # Check camera permission
    check_camera_permission
    
    # Create HTML template
    create_html_template
    
    get_ip
    create_server_script
    
    echo -e "${GREEN}[+] Server starting on port $PORT${NC}"
    echo -e "${YELLOW}[*] Username: $AUTH_USER${NC}"
    echo -e "${YELLOW}[*] Password: $AUTH_PASS${NC}"
    echo -e "${YELLOW}[*] Storage: $RECORDING_DIR${NC}"
    echo -e "${YELLOW}[*] Snapshot Interval: $SNAPSHOT_INTERVAL seconds${NC}"
    echo -e "${YELLOW}[*] Camera: /dev/video$CAMERA_INDEX${NC}"
    
    if [ "$USE_CLOUDFLARED" = true ]; then
        echo -e "${CYAN}[+] Cloudflared tunnel enabled${NC}"
        echo -e "${CYAN}[*] Public URL will be shown when tunnel is ready${NC}"
    fi
    
    echo -e "${YELLOW}[*] Press Ctrl+C to stop the server${NC}"
    
    python cctv_server.py
}

# Function to show status
show_status() {
    if [ -f ~/.cctv/config ]; then
        source ~/.cctv/config
        echo -e "${GREEN}[+] CCTV Configuration:${NC}"
        echo "Port: $PORT"
        echo "Username: $AUTH_USER"
        echo "Storage Directory: $RECORDING_DIR"
        echo "Snapshot Interval: $SNAPSHOT_INTERVAL seconds"
        echo "Camera Index: $CAMERA_INDEX"
        echo "Cloudflared: $USE_CLOUDFLARED"
        
        # Check if directory exists
        if [ -d "$RECORDING_DIR" ]; then
            file_count=$(find "$RECORDING_DIR" -name "*.jpg" -type f 2>/dev/null | wc -l)
            echo "Snapshots in storage: $file_count"
            
            # Show recent files
            echo -e "${YELLOW}[*] Recent snapshots:${NC}"
            ls -lt "$RECORDING_DIR"/*.jpg 2>/dev/null | head -10 || echo "No snapshots found"
        else
            echo -e "${RED}[!] Storage directory not found${NC}"
        fi
        
        # Check if server is running
        if pgrep -f "cctv_server.py" > /dev/null; then
            echo -e "${GREEN}[+] Server is running${NC}"
        else
            echo -e "${RED}[!] Server is not running${NC}"
        fi
    else
        echo -e "${RED}[!] Configuration not found. Run setup first.${NC}"
    fi
}

# Function to fix camera permissions
fix_camera() {
    echo -e "${YELLOW}[*] Fixing camera permissions...${NC}"
    
    # Check if termux-api is installed for permission requests
    if command -v termux-camera-photo > /dev/null 2>&1; then
        echo -e "${YELLOW}[*] Testing camera with termux-api...${NC}"
        termux-camera-photo -c 0 ~/camera_test.jpg 2>/dev/null
        if [ -f ~/camera_test.jpg ]; then
            echo -e "${GREEN}[+] Camera test successful with termux-api${NC}"
            rm -f ~/camera_test.jpg
        else
            echo -e "${RED}[!] Camera test failed with termux-api${NC}"
        fi
    fi
    
    echo -e "${YELLOW}[*] Camera permission guide:${NC}"
    echo -e "${CYAN}   1. Open Termux App${NC}"
    echo -e "${CYAN}   2. Tap the three dots menu (⋮)${NC}"
    echo -e "${CYAN}   3. Go to 'App Settings'${NC}"
    echo -e "${CYAN}   4. Tap 'Permissions'${NC}"
    echo -e "${CYAN}   5. Enable 'Camera' permission${NC}"
    echo -e "${CYAN}   6. Restart Termux and try again${NC}"
}

# Function to open storage directory
open_storage() {
    if [ -f ~/.cctv/config ]; then
        source ~/.cctv/config
        echo -e "${GREEN}[+] Opening storage directory: $RECORDING_DIR${NC}"
        
        if [ -d "$RECORDING_DIR" ]; then
            # Try to open with termux-open
            if command -v termux-open >/dev/null 2>&1; then
                termux-open "$RECORDING_DIR"
            else
                echo -e "${YELLOW}[*] Snapshots in storage:${NC}"
                ls -la "$RECORDING_DIR"/*.jpg 2>/dev/null | head -20 || echo "No snapshots found"
            fi
        else
            echo -e "${RED}[!] Storage directory not found${NC}"
        fi
    else
        echo -e "${RED}[!] Configuration not found${NC}"
    fi
}

# Main menu
case "$1" in
    "install")
        install_dependencies
        setup_config
        ;;
    "start")
        shift
        start_server "$@"
        ;;
    "setup")
        setup_config
        ;;
    "status")
        show_status
        ;;
    "storage")
        open_storage
        ;;
    "fix-camera")
        fix_camera
        ;;
    "install-cloudflared")
        install_cloudflared
        ;;
    "ip")
        get_ip
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 {install|start|setup|status|storage|fix-camera|install-cloudflared|ip}${NC}"
        echo ""
        echo "Commands:"
        echo "  install               - Install dependencies and setup"
        echo "  start [--tunnel|-t]   - Start CCTV server (optionally with cloudflared tunnel)"
        echo "  setup                 - Configure settings"
        echo "  status                - Show current status"
        echo "  storage               - Open storage directory"
        echo "  fix-camera            - Help fix camera permissions"
        echo "  install-cloudflared   - Install cloudflared for remote access"
        echo "  ip                    - Show device IP address"
        echo ""
        echo "Examples:"
        echo "  ./cctv.sh install                    # First-time setup"
        echo "  ./cctv.sh start                      # Start locally"
        echo "  ./cctv.sh start --tunnel            # Start with public URL"
        echo "  ./cctv.sh fix-camera                # Help with camera issues"
        echo ""
        echo "Quick Start:"
        echo "  1. Run: ./cctv.sh install"
        echo "  2. Run: ./cctv.sh start --tunnel"
        echo "  3. Access via local IP or public Cloudflared URL"
        ;;
esac