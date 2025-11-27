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
SNAPSHOT_INTERVAL=5
GENERATED_LINKS_FILE="/data/data/com.termux/files/home/.cctv/links.txt"

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
echo "Home CCTV System - Browser-Based Camera"
echo "========================================"

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing dependencies...${NC}"
    pkg update && pkg upgrade -y
    pkg install -y python wget
    
    echo -e "${YELLOW}[*] Installing Python packages...${NC}"
    pip install flask flask-basicauth requests qrcode[pil]
    
    echo -e "${YELLOW}[*] Setting up storage permissions...${NC}"
    # Request storage permission
    termux-setup-storage
    
    # Create necessary directories
    mkdir -p $RECORDING_DIR
    mkdir -p ~/.cctv
    mkdir -p $CLOUDFLARED_DIR
    
    echo -e "${GREEN}[+] Dependencies installed successfully${NC}"
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
    
    read -p "Enter admin username (default: admin): " custom_user
    if [ ! -z "$custom_user" ]; then
        AUTH_USER=$custom_user
    fi
    
    read -p "Enter admin password (default: password123): " custom_pass
    if [ ! -z "$custom_pass" ]; then
        AUTH_PASS=$custom_pass
    fi
    
    read -p "Enter snapshot interval in seconds (default: 5): " custom_interval
    if [ ! -z "$custom_interval" ]; then
        SNAPSHOT_INTERVAL=$custom_interval
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
EOF
    
    echo -e "${GREEN}[+] Configuration saved to ~/.cctv/config${NC}"
    echo -e "${GREEN}[+] Snapshots will be saved to: $RECORDING_DIR${NC}"
    echo -e "${GREEN}[+] Snapshot interval: $SNAPSHOT_INTERVAL seconds${NC}"
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
    echo $IP
}

# Function to generate access links
generate_access_links() {
    local local_ip=$1
    local tunnel_url=$2
    
    echo -e "${YELLOW}[*] Generating access links...${NC}"
    
    # Create links directory
    mkdir -p ~/.cctv/links
    
    # Generate unique access codes
    LOCAL_CODE=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    if [ ! -z "$tunnel_url" ]; then
        REMOTE_CODE=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
    fi
    
    # Save links to file
    cat > $GENERATED_LINKS_FILE << EOF
=== CCTV ACCESS LINKS ===
Generated: $(date)

ADMIN PANEL:
Local: http://$local_ip:$PORT/admin
$(if [ ! -z "$tunnel_url" ]; then echo "Remote: $tunnel_url/admin"; fi)

CAMERA VIEWER LINKS:
Local: http://$local_ip:$PORT/view/$LOCAL_CODE
$(if [ ! -z "$tunnel_url" ]; then echo "Remote: $tunnel_url/view/$REMOTE_CODE"; fi)

EOF

    echo -e "${GREEN}[+] Access links generated:${NC}"
    echo -e "${CYAN}Admin Panel (Local):  ${BLUE}http://$local_ip:$PORT/admin${NC}"
    if [ ! -z "$tunnel_url" ]; then
        echo -e "${CYAN}Admin Panel (Remote): ${BLUE}$tunnel_url/admin${NC}"
    fi
    echo -e "${CYAN}Camera Viewer (Local): ${BLUE}http://$local_ip:$PORT/view/$LOCAL_CODE${NC}"
    if [ ! -z "$tunnel_url" ]; then
        echo -e "${CYAN}Camera Viewer (Remote):${BLUE}$tunnel_url/view/$REMOTE_CODE${NC}"
    fi
    
    # Generate QR codes
    generate_qr_codes "$local_ip" "$tunnel_url" "$LOCAL_CODE" "$REMOTE_CODE"
}

# Function to generate QR codes
generate_qr_codes() {
    local local_ip=$1
    local tunnel_url=$2
    local local_code=$3
    local remote_code=$4
    
    echo -e "${YELLOW}[*] Generating QR codes...${NC}"
    
    # Create QR code for local access
    python3 -c "
import qrcode
qr = qrcode.QRCode(version=1, box_size=10, border=5)
qr.add_data('http://$local_ip:$PORT/view/$local_code')
qr.make(fit=True)
img = qr.make_image(fill_color='black', back_color='white')
img.save('/data/data/com.termux/files/home/.cctv/links/local_qr.png')
print('Local QR code generated')
" 2>/dev/null || echo "QR code generation failed - install qrcode[pil] package"

    # Create QR code for remote access if available
    if [ ! -z "$tunnel_url" ]; then
        python3 -c "
import qrcode
qr = qrcode.QRCode(version=1, box_size=10, border=5)
qr.add_data('$tunnel_url/view/$remote_code')
qr.make(fit=True)
img = qr.make_image(fill_color='black', back_color='white')
img.save('/data/data/com.termux/files/home/.cctv/links/remote_qr.png')
print('Remote QR code generated')
" 2>/dev/null || echo "QR code generation failed - install qrcode[pil] package"
    fi
    
    echo -e "${GREEN}[+] QR codes saved to ~/.cctv/links/${NC}"
}

# Function to create HTML templates
create_html_templates() {
    # Admin Panel Template
    cat > admin_panel.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CCTV Admin Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a2a3a, #0d1b2a);
            color: #ffffff;
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        .header { 
            text-align: center; 
            margin-bottom: 30px; 
            padding: 20px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            backdrop-filter: blur(10px);
        }
        .header h1 { 
            font-size: 2.5em; 
            margin-bottom: 10px;
            background: linear-gradient(45deg, #4facfe, #00f2fe);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .card {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            padding: 25px;
            margin-bottom: 20px;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        .links-container { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .link-box { 
            background: rgba(255, 255, 255, 0.05); 
            padding: 20px; 
            border-radius: 10px; 
            border-left: 4px solid #4facfe;
        }
        .btn {
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            background: linear-gradient(45deg, #4facfe, #00f2fe);
            color: white;
            font-weight: bold;
            cursor: pointer;
            margin: 5px;
            text-decoration: none;
            display: inline-block;
        }
        .qr-section { text-align: center; margin: 20px 0; }
        .qr-code { max-width: 200px; border-radius: 10px; }
        .status-bar {
            display: flex;
            justify-content: space-around;
            flex-wrap: wrap;
            gap: 15px;
            margin: 20px 0;
        }
        .status-item {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            text-align: center;
            flex: 1;
            min-width: 150px;
        }
        .online { border-left: 4px solid #4CAF50; }
        .viewers { border-left: 4px solid #2196F3; }
        .storage { border-left: 4px solid #FF9800; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📱 CCTV Admin Panel</h1>
            <p>Manage your home surveillance system</p>
        </div>

        <div class="status-bar">
            <div class="status-item online">
                <h3>🟢 SYSTEM ONLINE</h3>
                <p id="status">Running</p>
            </div>
            <div class="status-item viewers">
                <h3>👁️ ACTIVE VIEWERS</h3>
                <p id="viewer-count">0</p>
            </div>
            <div class="status-item storage">
                <h3>💾 STORAGE</h3>
                <p id="storage-info">Loading...</p>
            </div>
        </div>

        <div class="card">
            <h2>🔗 Generated Access Links</h2>
            <p>Share these links with devices that will view the camera:</p>
            
            <div class="links-container">
                <div class="link-box">
                    <h3>📱 Camera Viewer Links</h3>
                    <p><strong>Local Network:</strong></p>
                    <input type="text" id="local-link" value="{{ local_viewer_link }}" readonly style="width: 100%; padding: 8px; margin: 5px 0; border-radius: 5px; border: 1px solid #ccc;">
                    <button class="btn" onclick="copyLink('local-link')">📋 Copy</button>
                    
                    {% if remote_viewer_link %}
                    <p><strong>Remote Access:</strong></p>
                    <input type="text" id="remote-link" value="{{ remote_viewer_link }}" readonly style="width: 100%; padding: 8px; margin: 5px 0; border-radius: 5px; border: 1px solid #ccc;">
                    <button class="btn" onclick="copyLink('remote-link')">📋 Copy</button>
                    {% endif %}
                </div>
            </div>

            <div class="qr-section">
                <h3>📲 QR Codes for Easy Access</h3>
                <div style="display: flex; justify-content: center; gap: 20px; flex-wrap: wrap;">
                    <div>
                        <p>Local Access</p>
                        <img src="/admin/local_qr" class="qr-code" alt="Local QR Code">
                    </div>
                    {% if remote_viewer_link %}
                    <div>
                        <p>Remote Access</p>
                        <img src="/admin/remote_qr" class="qr-code" alt="Remote QR Code">
                    </div>
                    {% endif %}
                </div>
            </div>
        </div>

        <div class="card">
            <h2>⚙️ System Controls</h2>
            <button class="btn" onclick="generateNewLinks()">🔄 Generate New Links</button>
            <button class="btn" onclick="showLinksFile()">📄 Show Links File</button>
            <button class="btn" onclick="stopServer()">🛑 Stop Server</button>
        </div>

        <div class="card">
            <h2>📊 System Information</h2>
            <p><strong>Server Started:</strong> {{ start_time }}</p>
            <p><strong>Local IP:</strong> {{ local_ip }}</p>
            <p><strong>Storage Path:</strong> {{ storage_path }}</p>
            <p><strong>Snapshot Interval:</strong> {{ snapshot_interval }} seconds</p>
            {% if tunnel_url %}
            <p><strong>Tunnel URL:</strong> {{ tunnel_url }}</p>
            {% endif %}
        </div>
    </div>

    <script>
        function copyLink(elementId) {
            const element = document.getElementById(elementId);
            element.select();
            element.setSelectionRange(0, 99999);
            document.execCommand('copy');
            alert('Link copied to clipboard!');
        }

        function generateNewLinks() {
            if (confirm('Generate new access links? Old links will stop working.')) {
                fetch('/admin/generate_new_links', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            alert('New links generated!');
                            location.reload();
                        }
                    });
            }
        }

        function showLinksFile() {
            window.open('/admin/links_file', '_blank');
        }

        function stopServer() {
            if (confirm('Stop the CCTV server?')) {
                fetch('/admin/stop_server')
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            alert('Server stopping...');
                        }
                    });
            }
        }

        function updateStats() {
            fetch('/admin/stats')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        document.getElementById('viewer-count').textContent = data.active_viewers;
                        document.getElementById('storage-info').textContent = data.storage_info;
                    }
                });
        }

        // Update stats every 10 seconds
        setInterval(updateStats, 10000);
        updateStats();
    </script>
</body>
</html>
EOF

    # Camera Viewer Template (Uses Browser Camera)
    cat > camera_viewer.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home CCTV Viewer</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #1a1a1a;
            color: #ffffff;
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 800px; margin: 0 auto; text-align: center; }
        .header { margin-bottom: 20px; }
        .video-container {
            background: #000;
            border-radius: 15px;
            padding: 10px;
            margin: 20px 0;
            position: relative;
        }
        #videoElement {
            width: 100%;
            max-width: 640px;
            border-radius: 10px;
            background: #000;
        }
        .controls {
            margin: 20px 0;
        }
        .btn {
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            background: linear-gradient(45deg, #4CAF50, #45a049);
            color: white;
            font-weight: bold;
            cursor: pointer;
            margin: 5px;
        }
        .btn-capture {
            background: linear-gradient(45deg, #2196F3, #1976D2);
        }
        .status {
            background: rgba(255, 255, 255, 0.1);
            padding: 15px;
            border-radius: 10px;
            margin: 15px 0;
        }
        .permission-guide {
            background: rgba(255, 193, 7, 0.2);
            border: 1px solid #FFC107;
            border-radius: 10px;
            padding: 20px;
            margin: 20px 0;
        }
        .snapshots {
            margin: 20px 0;
        }
        .snapshot-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 10px;
            margin-top: 10px;
        }
        .snapshot-item {
            border-radius: 8px;
            overflow: hidden;
            background: #333;
        }
        .snapshot-item img {
            width: 100%;
            height: 120px;
            object-fit: cover;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Home CCTV Viewer</h1>
            <p>Live camera feed from your phone</p>
        </div>

        <div id="permissionGuide" class="permission-guide" style="display: none;">
            <h3>📷 Camera Access Required</h3>
            <p>Please allow camera access to view the live feed.</p>
            <p>Look for the camera permission prompt in your browser.</p>
            <button class="btn" onclick="initCamera()">🔄 Retry Camera</button>
        </div>

        <div class="status" id="statusMessage">
            <p>Initializing camera...</p>
        </div>

        <div class="video-container">
            <video id="videoElement" autoplay playsinline></video>
        </div>

        <div class="controls">
            <button class="btn" onclick="captureSnapshot()">📸 Take Snapshot</button>
            <button class="btn btn-capture" onclick="toggleCamera()">🔄 Switch Camera</button>
            <button class="btn" onclick="toggleFullscreen()">📺 Fullscreen</button>
        </div>

        <div class="snapshots">
            <h3>Recent Snapshots</h3>
            <div class="snapshot-grid" id="snapshotGrid">
                <!-- Snapshots will appear here -->
            </div>
        </div>
    </div>

    <script>
        let videoElement = document.getElementById('videoElement');
        let currentStream = null;
        let facingMode = 'environment'; // Start with back camera
        let snapshots = [];

        async function initCamera() {
            document.getElementById('permissionGuide').style.display = 'none';
            document.getElementById('statusMessage').innerHTML = '<p>Requesting camera access...</p>';

            // Stop any existing stream
            if (currentStream) {
                currentStream.getTracks().forEach(track => track.stop());
            }

            const constraints = {
                video: {
                    facingMode: facingMode,
                    width: { ideal: 1280 },
                    height: { ideal: 720 }
                },
                audio: false
            };

            try {
                const stream = await navigator.mediaDevices.getUserMedia(constraints);
                currentStream = stream;
                videoElement.srcObject = stream;
                
                document.getElementById('statusMessage').innerHTML = 
                    `<p>✅ Camera active (${facingMode === 'environment' ? 'Back' : 'Front'})</p>`;
                
                // Hide permission guide
                document.getElementById('permissionGuide').style.display = 'none';
                
            } catch (error) {
                console.error('Camera error:', error);
                document.getElementById('statusMessage').innerHTML = 
                    `<p>❌ Camera error: ${error.message}</p>`;
                document.getElementById('permissionGuide').style.display = 'block';
            }
        }

        function toggleCamera() {
            facingMode = facingMode === 'environment' ? 'user' : 'environment';
            initCamera();
        }

        function captureSnapshot() {
            const canvas = document.createElement('canvas');
            canvas.width = videoElement.videoWidth;
            canvas.height = videoElement.videoHeight;
            const context = canvas.getContext('2d');
            
            context.drawImage(videoElement, 0, 0, canvas.width, canvas.height);
            
            canvas.toBlob(function(blob) {
                const formData = new FormData();
                formData.append('snapshot', blob);
                
                fetch('/viewer/upload_snapshot', {
                    method: 'POST',
                    body: formData
                })
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        addSnapshotToGrid(data.filename, canvas);
                    }
                })
                .catch(error => {
                    console.error('Upload error:', error);
                });
            }, 'image/jpeg', 0.8);
        }

        function addSnapshotToGrid(filename, canvas) {
            const snapshotGrid = document.getElementById('snapshotGrid');
            const snapshotItem = document.createElement('div');
            snapshotItem.className = 'snapshot-item';
            
            const img = document.createElement('img');
            img.src = canvas.toDataURL('image/jpeg');
            img.alt = 'Snapshot';
            
            snapshotItem.appendChild(img);
            snapshotGrid.insertBefore(snapshotItem, snapshotGrid.firstChild);
            
            // Keep only last 6 snapshots
            if (snapshotGrid.children.length > 6) {
                snapshotGrid.removeChild(snapshotGrid.lastChild);
            }
        }

        function toggleFullscreen() {
            if (!document.fullscreenElement) {
                videoElement.requestFullscreen().catch(err => {
                    console.error('Fullscreen error:', err);
                });
            } else {
                document.exitFullscreen();
            }
        }

        // Handle visibility change
        document.addEventListener('visibilitychange', function() {
            if (!document.hidden && !currentStream) {
                initCamera();
            }
        });

        // Initialize camera when page loads
        document.addEventListener('DOMContentLoaded', initCamera);

        // Auto-capture every 30 seconds (optional)
        setInterval(captureSnapshot, 30000);
    </script>
</body>
</html>
EOF

    echo -e "${GREEN}[+] HTML templates created${NC}"
}

# Function to create Python server
create_server_script() {
    cat > cctv_server.py << EOF
#!/data/data/com.termux/files/usr/bin/python3

import flask
from flask import Flask, render_template_string, jsonify, send_file, request, send_from_directory
from flask_basicauth import BasicAuth
import os
import time
from datetime import datetime
import threading
import signal
import sys
import random
import string

app = Flask(__name__)

# Basic Authentication for admin panel
app.config['BASIC_AUTH_USERNAME'] = '$AUTH_USER'
app.config['BASIC_AUTH_PASSWORD'] = '$AUTH_PASS'
app.config['BASIC_AUTH_FORCE'] = True

basic_auth = BasicAuth(app)

# Global variables
tunnel_url = None
active_viewers = 0
access_codes = {
    'local': ''.join(random.choices(string.ascii_letters + string.digits, k=8)),
    'remote': ''.join(random.choices(string.ascii_letters + string.digits, k=8)) if '$USE_CLOUDFLARED' == 'true' else None
}

# Read HTML templates
with open('admin_panel.html', 'r') as f:
    ADMIN_TEMPLATE = f.read()

with open('camera_viewer.html', 'r') as f:
    VIEWER_TEMPLATE = f.read()

@app.route('/')
def index():
    return redirect_to_admin()

@app.route('/admin')
@basic_auth.required
def admin_panel():
    import socket
    try:
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
    except:
        local_ip = "Unknown"
    
    # Generate viewer links
    local_viewer_link = f"http://{local_ip}:$PORT/view/{access_codes['local']}"
    remote_viewer_link = f"{tunnel_url}/view/{access_codes['remote']}" if tunnel_url and access_codes['remote'] else None
    
    return render_template_string(ADMIN_TEMPLATE,
                                 local_ip=local_ip,
                                 start_time=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                                 storage_path='$RECORDING_DIR',
                                 tunnel_url=tunnel_url,
                                 snapshot_interval=$SNAPSHOT_INTERVAL,
                                 local_viewer_link=local_viewer_link,
                                 remote_viewer_link=remote_viewer_link)

@app.route('/admin/local_qr')
@basic_auth.required
def local_qr():
    try:
        return send_file('/data/data/com.termux/files/home/.cctv/links/local_qr.png')
    except:
        return "QR code not available", 404

@app.route('/admin/remote_qr')
@basic_auth.required
def remote_qr():
    try:
        return send_file('/data/data/com.termux/files/home/.cctv/links/remote_qr.png')
    except:
        return "QR code not available", 404

@app.route('/admin/links_file')
@basic_auth.required
def links_file():
    try:
        return send_file('$GENERATED_LINKS_FILE')
    except:
        return "Links file not available", 404

@app.route('/admin/generate_new_links', methods=['POST'])
@basic_auth.required
def generate_new_links():
    global access_codes
    access_codes['local'] = ''.join(random.choices(string.ascii_letters + string.digits, k=8))
    if '$USE_CLOUDFLARED' == 'true':
        access_codes['remote'] = ''.join(random.choices(string.ascii_letters + string.digits, k=8))
    
    # Regenerate links file and QR codes
    import socket
    try:
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
    except:
        local_ip = "Unknown"
    
    generate_links_file(local_ip, tunnel_url)
    generate_qr_codes(local_ip, tunnel_url)
    
    return {'success': True, 'message': 'New links generated'}

@app.route('/admin/stats')
@basic_auth.required
def admin_stats():
    # Calculate storage usage
    total_size = 0
    file_count = 0
    if os.path.exists('$RECORDING_DIR'):
        for filename in os.listdir('$RECORDING_DIR'):
            filepath = os.path.join('$RECORDING_DIR', filename)
            if os.path.isfile(filepath) and filename.endswith('.jpg'):
                total_size += os.path.getsize(filepath)
                file_count += 1
    
    storage_info = f"{total_size // (1024*1024)} MB ({file_count} files)"
    
    return {
        'success': True,
        'active_viewers': active_viewers,
        'storage_info': storage_info
    }

@app.route('/admin/stop_server')
@basic_auth.required
def stop_server():
    print("Server shutdown requested via admin panel")
    os.kill(os.getpid(), signal.SIGINT)
    return {'success': True, 'message': 'Server stopping...'}

@app.route('/view/<access_code>')
def camera_viewer(access_code):
    global active_viewers
    
    # Validate access code
    if access_code not in access_codes.values():
        return "Invalid access code", 403
    
    active_viewers += 1
    
    response = render_template_string(VIEWER_TEMPLATE)
    
    # Decrease viewer count when page unloads (this is approximate)
    @response.call_on_close
    def decrease_viewers():
        global active_viewers
        active_viewers = max(0, active_viewers - 1)
    
    return response

@app.route('/viewer/upload_snapshot', methods=['POST'])
def upload_snapshot():
    try:
        if 'snapshot' not in request.files:
            return {'success': False, 'message': 'No file provided'}
        
        file = request.files['snapshot']
        if file.filename == '':
            return {'success': False, 'message': 'No file selected'}
        
        # Generate filename with timestamp
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"snapshot_{timestamp}.jpg"
        filepath = os.path.join('$RECORDING_DIR', filename)
        
        # Save the file
        file.save(filepath)
        
        return {'success': True, 'filename': filename}
        
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

def generate_links_file(local_ip, tunnel_url):
    os.makedirs('/data/data/com.termux/files/home/.cctv', exist_ok=True)
    
    with open('$GENERATED_LINKS_FILE', 'w') as f:
        f.write("=== CCTV ACCESS LINKS ===\\n")
        f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\\n\\n")
        
        f.write("ADMIN PANEL:\\n")
        f.write(f"Local: http://{local_ip}:$PORT/admin\\n")
        if tunnel_url:
            f.write(f"Remote: {tunnel_url}/admin\\n")
        
        f.write("\\nCAMERA VIEWER LINKS:\\n")
        f.write(f"Local: http://{local_ip}:$PORT/view/{access_codes['local']}\\n")
        if tunnel_url and access_codes['remote']:
            f.write(f"Remote: {tunnel_url}/view/{access_codes['remote']}\\n")

def generate_qr_codes(local_ip, tunnel_url):
    try:
        import qrcode
        
        # Local QR code
        local_url = f"http://{local_ip}:$PORT/view/{access_codes['local']}"
        qr = qrcode.QRCode(version=1, box_size=10, border=5)
        qr.add_data(local_url)
        qr.make(fit=True)
        img = qr.make_image(fill_color='black', back_color='white')
        img.save('/data/data/com.termux/files/home/.cctv/links/local_qr.png')
        
        # Remote QR code
        if tunnel_url and access_codes['remote']:
            remote_url = f"{tunnel_url}/view/{access_codes['remote']}"
            qr = qrcode.QRCode(version=1, box_size=10, border=5)
            qr.add_data(remote_url)
            qr.make(fit=True)
            img = qr.make_image(fill_color='black', back_color='white')
            img.save('/data/data/com.termux/files/home/.cctv/links/remote_qr.png')
            
    except Exception as e:
        print(f"QR code generation failed: {e}")

def start_cloudflared_tunnel():
    global tunnel_url
    try:
        cloudflared_path = os.path.join('$CLOUDFLARED_DIR', 'cloudflared')
        if not os.path.exists(cloudflared_path):
            print("❌ Cloudflared not found")
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

def signal_handler(sig, frame):
    print('\\nShutting down CCTV server...')
    sys.exit(0)

if __name__ == '__main__':
    # Setup signal handler
    signal.signal(signal.SIGINT, signal_handler)
    
    print("🚀 Starting CCTV Server...")
    print(f"📝 Admin: $AUTH_USER")
    print(f"🔑 Password: $AUTH_PASS")
    print(f"📁 Storage: $RECORDING_DIR")
    print("=" * 50)
    
    # Generate initial links file
    import socket
    try:
        hostname = socket.gethostname()
        local_ip = socket.gethostbyname(hostname)
    except:
        local_ip = "Unknown"
    
    generate_links_file(local_ip, None)
    
    # Start Cloudflared if enabled
    cloudflared_process = None
    if '$USE_CLOUDFLARED' == 'true':
        cloudflared_process = start_cloudflared_tunnel()
        # Update links file with tunnel URL
        if tunnel_url:
            generate_links_file(local_ip, tunnel_url)
            generate_qr_codes(local_ip, tunnel_url)
    
    print("✅ Server started successfully")
    print("💡 Camera permissions are handled by the browser on viewing devices")
    print("📱 Share the viewer links with devices that will access the camera")
    
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
    
    # Create HTML templates
    create_html_templates
    
    # Get IP and generate initial links
    LOCAL_IP=$(get_ip)
    
    # Create server script
    create_server_script
    
    echo -e "${GREEN}[+] Server starting on port $PORT${NC}"
    echo -e "${YELLOW}[*] Admin Username: $AUTH_USER${NC}"
    echo -e "${YELLOW}[*] Admin Password: $AUTH_PASS${NC}"
    echo -e "${YELLOW}[*] Storage: $RECORDING_DIR${NC}"
    
    if [ "$USE_CLOUDFLARED" = true ]; then
        echo -e "${CYAN}[+] Cloudflared tunnel enabled${NC}"
        echo -e "${CYAN}[*] Public URL will be shown when tunnel is ready${NC}"
    fi
    
    echo -e "${YELLOW}[*] Press Ctrl+C to stop the server${NC}"
    echo ""
    echo -e "${GREEN}📱 NEXT STEPS:${NC}"
    echo -e "${CYAN}1. Open Admin Panel in your browser:${NC}"
    echo -e "${BLUE}   http://$LOCAL_IP:$PORT/admin${NC}"
    echo -e "${CYAN}2. Use the generated viewer links on other devices${NC}"
    echo -e "${CYAN}3. Camera permissions will be handled by each device's browser${NC}"
    
    python cctv_server.py
}

# Function to show status
show_status() {
    if [ -f ~/.cctv/config ]; then
        source ~/.cctv/config
        echo -e "${GREEN}[+] CCTV Configuration:${NC}"
        echo "Port: $PORT"
        echo "Admin Username: $AUTH_USER"
        echo "Storage Directory: $RECORDING_DIR"
        echo "Cloudflared: $USE_CLOUDFLARED"
        
        # Check if directory exists
        if [ -d "$RECORDING_DIR" ]; then
            file_count=$(find "$RECORDING_DIR" -name "*.jpg" -type f 2>/dev/null | wc -l)
            echo "Snapshots in storage: $file_count"
        else
            echo -e "${RED}[!] Storage directory not found${NC}"
        fi
        
        # Check if server is running
        if pgrep -f "cctv_server.py" > /dev/null; then
            echo -e "${GREEN}[+] Server is running${NC}"
            
            # Show generated links if available
            if [ -f "$GENERATED_LINKS_FILE" ]; then
                echo -e "${YELLOW}[*] Generated Links:${NC}"
                cat "$GENERATED_LINKS_FILE"
            fi
        else
            echo -e "${RED}[!] Server is not running${NC}"
        fi
    else
        echo -e "${RED}[!] Configuration not found. Run setup first.${NC}"
    fi
}

# Function to show generated links
show_links() {
    if [ -f "$GENERATED_LINKS_FILE" ]; then
        echo -e "${GREEN}[+] Generated Access Links:${NC}"
        cat "$GENERATED_LINKS_FILE"
    else
        echo -e "${RED}[!] No links file found. Start the server first.${NC}"
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
    "links")
        show_links
        ;;
    "install-cloudflared")
        install_cloudflared
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 {install|start|setup|status|links|install-cloudflared}${NC}"
        echo ""
        echo "Commands:"
        echo "  install               - Install dependencies and setup"
        echo "  start [--tunnel|-t]   - Start CCTV server with browser-based camera"
        echo "  setup                 - Configure settings"
        echo "  status                - Show current status and links"
        echo "  links                 - Show generated access links"
        echo "  install-cloudflared   - Install cloudflared for remote access"
        echo ""
        echo "Key Features:"
        echo "  📱 Browser-based camera - No Termux camera permissions needed"
        echo "  🔗 Generated access links - Secure links for viewer devices"
        echo "  📊 Admin panel - Manage your CCTV system"
        echo "  🌐 Remote access - Via Cloudflared tunnel"
        echo ""
        echo "Quick Start:"
        echo "  1. Run: ./cctv.sh install"
        echo "  2. Run: ./cctv.sh start --tunnel"
        echo "  3. Access Admin Panel and share viewer links"
        echo "  4. Camera permissions handled by each device's browser"
        ;;
esac
