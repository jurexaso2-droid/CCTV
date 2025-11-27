#!/data/data/com.termux/files/usr/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
PORT=8080
QUALITY="medium"
AUTH_USER="admin"
AUTH_PASS="password123"
RECORDING_DIR="/sdcard/CCTVRecordings"

# Banner
echo -e "${GREEN}"
echo "   ____ ____ _______ _______ "
echo "  / ___|___ \__   __|__   __|"
echo " | |     __) | | |     | |   "
echo " | |___ / __/  | |     | |   "
echo "  \____|_____| |_|     |_|   "
echo -e "${NC}"
echo "Home CCTV System for Termux"
echo "============================"

# Function to install dependencies
install_dependencies() {
    echo -e "${YELLOW}[*] Installing dependencies...${NC}"
    pkg update && pkg upgrade -y
    pkg install -y python ffmpeg termux-api
    pip install flask flask-basicauth cv2-python requests
    
    # Create necessary directories
    mkdir -p $RECORDING_DIR
    mkdir -p ~/.cctv
    
    echo -e "${GREEN}[+] Dependencies installed successfully${NC}"
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
    
    # Save configuration
    cat > ~/.cctv/config << EOF
PORT=$PORT
AUTH_USER=$AUTH_USER
AUTH_PASS=$AUTH_PASS
RECORDING_DIR=$RECORDING_DIR
EOF
    
    echo -e "${GREEN}[+] Configuration saved${NC}"
}

# Function to get device IP
get_ip() {
    echo -e "${YELLOW}[*] Getting device IP address...${NC}"
    IP=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
    if [ -z "$IP" ]; then
        IP=$(ip route get 1 | awk '{print $7}')
    fi
    echo -e "${GREEN}[+] Your CCTV will be accessible at: ${BLUE}http://$IP:$PORT${NC}"
}

# Function to create Python CCTV server
create_server_script() {
    cat > cctv_server.py << EOF
#!/data/data/com.termux/files/usr/bin/python3

import cv2
import flask
from flask import Flask, Response, render_template_string
from flask_basicauth import BasicAuth
import os
import time
from datetime import datetime
import threading
import subprocess

app = Flask(__name__)

# Basic Authentication
app.config['BASIC_AUTH_USERNAME'] = '$AUTH_USER'
app.config['BASIC_AUTH_PASSWORD'] = '$AUTH_PASS'
app.config['BASIC_AUTH_FORCE'] = True

basic_auth = BasicAuth(app)

# Global variables
camera = None
is_recording = False
recording_process = None

# HTML Template
HTML_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>Home CCTV</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { margin: 0; padding: 20px; background: #1a1a1a; color: white; font-family: Arial, sans-serif; }
        .container { max-width: 100%; text-align: center; }
        .video-container { margin: 20px auto; max-width: 800px; }
        .controls { margin: 20px 0; }
        button { padding: 10px 20px; margin: 5px; border: none; border-radius: 5px; cursor: pointer; }
        .record-btn { background: #ff4444; color: white; }
        .snapshot-btn { background: #44ff44; color: black; }
        .status { margin: 10px 0; padding: 10px; border-radius: 5px; }
        .recording { background: #ff4444; }
        .idle { background: #44ff44; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏠 Home CCTV System</h1>
        <div class="controls">
            <button class="record-btn" onclick="toggleRecording()">
                {% if is_recording %}⏹️ Stop Recording{% else %}⏺️ Start Recording{% endif %}
            </button>
            <button class="snapshot-btn" onclick="takeSnapshot()">📸 Take Snapshot</button>
        </div>
        <div class="status {% if is_recording %}recording{% else %}idle{% endif %}">
            Status: {% if is_recording %}🔴 RECORDING{% else %}🟢 IDLE{% endif %}
        </div>
        <div class="video-container">
            <img src="{{ url_for('video_feed') }}" width="100%" style="max-width: 800px;">
        </div>
        <div style="margin-top: 20px;">
            <p>Last updated: <span id="time"></span></p>
        </div>
    </div>

    <script>
        function updateTime() {
            document.getElementById('time').textContent = new Date().toLocaleString();
        }
        setInterval(updateTime, 1000);
        updateTime();

        function toggleRecording() {
            fetch('/toggle_record')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        location.reload();
                    }
                });
        }

        function takeSnapshot() {
            fetch('/snapshot')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        alert('Snapshot saved!');
                    }
                });
        }
    </script>
</body>
</html>
'''

def get_camera():
    global camera
    if camera is None or not camera.isOpened():
        # Try different camera indices
        for i in range(0, 3):
            camera = cv2.VideoCapture(i)
            if camera.isOpened():
                print(f"Camera found at index {i}")
                # Set camera resolution
                camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
                camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
                break
        else:
            print("No camera found!")
            return None
    return camera

def generate_frames():
    camera = get_camera()
    if camera is None:
        return
    
    while True:
        success, frame = camera.read()
        if not success:
            break
        else:
            # Encode frame as JPEG
            ret, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            frame = buffer.tobytes()
            
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame + b'\r\n')

@app.route('/')
@basic_auth.required
def index():
    return render_template_string(HTML_TEMPLATE, is_recording=is_recording)

@app.route('/video_feed')
@basic_auth.required
def video_feed():
    return Response(generate_frames(),
                    mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/toggle_record')
@basic_auth.required
def toggle_record():
    global is_recording, recording_process
    
    if not is_recording:
        # Start recording
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"$RECORDING_DIR/recording_{timestamp}.mp4"
        
        # Use ffmpeg to record
        recording_process = subprocess.Popen([
            'ffmpeg', '-y',
            '-f', 'video4linux2',
            '-i', '/dev/video0',
            '-s', '640x480',
            '-c:v', 'libx264',
            '-preset', 'veryfast',
            '-crf', '25',
            filename
        ])
        is_recording = True
        return {'success': True, 'message': 'Recording started'}
    else:
        # Stop recording
        if recording_process:
            recording_process.terminate()
            recording_process.wait()
        is_recording = False
        return {'success': True, 'message': 'Recording stopped'}

@app.route('/snapshot')
@basic_auth.required
def take_snapshot():
    camera = get_camera()
    if camera:
        success, frame = camera.read()
        if success:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"$RECORDING_DIR/snapshot_{timestamp}.jpg"
            cv2.imwrite(filename, frame)
            return {'success': True, 'message': 'Snapshot saved'}
    return {'success': False, 'message': 'Failed to take snapshot'}

if __name__ == '__main__':
    print("Starting CCTV Server...")
    print("Username: $AUTH_USER")
    print("Password: $AUTH_PASS")
    app.run(host='0.0.0.0', port=$PORT, debug=False, threaded=True)
EOF

    chmod +x cctv_server.py
}

# Function to start CCTV server
start_server() {
    echo -e "${YELLOW}[*] Starting CCTV server...${NC}"
    
    # Check if configuration exists
    if [ ! -f ~/.cctv/config ]; then
        echo -e "${RED}[!] Configuration not found. Running setup...${NC}"
        setup_config
    fi
    
    # Load configuration
    source ~/.cctv/config
    
    get_ip
    create_server_script
    
    echo -e "${GREEN}[+] Server starting on port $PORT${NC}"
    echo -e "${YELLOW}[*] Username: $AUTH_USER${NC}"
    echo -e "${YELLOW}[*] Password: $AUTH_PASS${NC}"
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
        echo "Recording Directory: $RECORDING_DIR"
        
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

# Main menu
case "$1" in
    "install")
        install_dependencies
        setup_config
        ;;
    "start")
        start_server
        ;;
    "setup")
        setup_config
        ;;
    "status")
        show_status
        ;;
    "ip")
        get_ip
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 {install|start|setup|status|ip}${NC}"
        echo ""
        echo "Commands:"
        echo "  install - Install dependencies and setup"
        echo "  start   - Start the CCTV server"
        echo "  setup   - Configure settings"
        echo "  status  - Show current status"
        echo "  ip      - Show device IP address"
        echo ""
        echo "Quick Start:"
        echo "  1. Run: ./cctv.sh install"
        echo "  2. Run: ./cctv.sh start"
        echo "  3. Access the stream from another device using the shown URL"
        ;;
esac