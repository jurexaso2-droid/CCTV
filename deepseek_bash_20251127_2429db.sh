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
RECORDING_DIR="/data/data/com.termux/files/home/storage/shared/CCTVRecordings"

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
    
    # Install Python packages
    pip install flask flask-basicauth opencv-python requests
    
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
    
    echo -e "${YELLOW}[*] Storage location setup${NC}"
    echo "1. Internal Storage (Recommended)"
    echo "2. SD Card (if available)"
    read -p "Choose storage location (1-2): " storage_choice
    
    case $storage_choice in
        2)
            RECORDING_DIR="/sdcard/CCTVRecordings"
            ;;
        *)
            RECORDING_DIR="/data/data/com.termux/files/home/storage/shared/CCTVRecordings"
            ;;
    esac
    
    # Create the directory
    mkdir -p $RECORDING_DIR
    
    # Save configuration
    cat > ~/.cctv/config << EOF
PORT=$PORT
AUTH_USER=$AUTH_USER
AUTH_PASS=$AUTH_PASS
RECORDING_DIR=$RECORDING_DIR
EOF
    
    echo -e "${GREEN}[+] Configuration saved to ~/.cctv/config${NC}"
    echo -e "${GREEN}[+] Recordings will be saved to: $RECORDING_DIR${NC}"
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
import signal
import sys

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
        body { 
            margin: 0; 
            padding: 20px; 
            background: #1a1a1a; 
            color: white; 
            font-family: Arial, sans-serif; 
        }
        .container { 
            max-width: 100%; 
            text-align: center; 
        }
        .video-container { 
            margin: 20px auto; 
            max-width: 800px; 
            border: 2px solid #333;
            border-radius: 10px;
            overflow: hidden;
        }
        .controls { 
            margin: 20px 0; 
        }
        button { 
            padding: 12px 24px; 
            margin: 5px; 
            border: none; 
            border-radius: 5px; 
            cursor: pointer; 
            font-size: 16px;
            font-weight: bold;
        }
        .record-btn { 
            background: #ff4444; 
            color: white; 
        }
        .snapshot-btn { 
            background: #44ff44; 
            color: black; 
        }
        .stop-btn { 
            background: #4444ff; 
            color: white; 
        }
        .status { 
            margin: 10px 0; 
            padding: 15px; 
            border-radius: 5px; 
            font-weight: bold;
        }
        .recording { 
            background: #ff4444; 
        }
        .idle { 
            background: #44ff44; 
            color: black;
        }
        .info {
            background: #333;
            padding: 10px;
            border-radius: 5px;
            margin: 10px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏠 Home CCTV System</h1>
        
        <div class="info">
            <p>📱 Device: {{ device_ip }}</p>
            <p>🕒 Started: {{ start_time }}</p>
        </div>
        
        <div class="controls">
            <button class="record-btn" onclick="toggleRecording()">
                {% if is_recording %}⏹️ Stop Recording{% else %}⏺️ Start Recording{% endif %}
            </button>
            <button class="snapshot-btn" onclick="takeSnapshot()">📸 Take Snapshot</button>
            <button class="stop-btn" onclick="stopServer()">🛑 Stop Server</button>
        </div>
        
        <div class="status {% if is_recording %}recording{% else %}idle{% endif %}">
            {% if is_recording %}🔴 RECORDING - {{ recording_file }}{% else %}🟢 IDLE - Ready{% endif %}
        </div>
        
        <div class="video-container">
            <img src="{{ url_for('video_feed') }}" width="100%" style="max-width: 800px;">
        </div>
        
        <div style="margin-top: 20px;">
            <p>Last updated: <span id="time"></span></p>
            <p>📁 Storage: {{ storage_path }}</p>
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
                    } else {
                        alert('Error: ' + data.message);
                    }
                });
        }

        function takeSnapshot() {
            fetch('/snapshot')
                .then(response => response.json())
                .then(data => {
                    if (data.success) {
                        alert('Snapshot saved: ' + data.filename);
                    } else {
                        alert('Error: ' + data.message);
                    }
                });
        }

        function stopServer() {
            if (confirm('Are you sure you want to stop the CCTV server?')) {
                fetch('/stop_server')
                    .then(response => response.json())
                    .then(data => {
                        if (data.success) {
                            alert('Server stopped. You can close this tab.');
                        }
                    });
            }
        }
    </script>
</body>
</html>
'''

def get_camera():
    global camera
    try:
        if camera is None or not camera.isOpened():
            print("Initializing camera...")
            # Try different camera indices - most phones use 0, some use 1
            for i in range(0, 3):
                try:
                    camera = cv2.VideoCapture(i)
                    if camera.isOpened():
                        # Test if we can read a frame
                        ret, frame = camera.read()
                        if ret:
                            print(f"✅ Camera successfully opened at index {i}")
                            # Set camera resolution
                            camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
                            camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
                            return camera
                        else:
                            camera.release()
                except Exception as e:
                    print(f"Error with camera index {i}: {e}")
                    if camera:
                        camera.release()
            
            print("❌ No working camera found!")
            return None
    except Exception as e:
        print(f"❌ Error initializing camera: {e}")
        return None
    
    return camera

def generate_frames():
    while True:
        try:
            camera = get_camera()
            if camera is None:
                # Return a black frame or error image
                time.sleep(1)
                continue
            
            success, frame = camera.read()
            if not success:
                print("Failed to read frame from camera")
                time.sleep(0.1)
                continue
            
            # Encode frame as JPEG
            ret, buffer = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            if not ret:
                print("Failed to encode frame")
                time.sleep(0.1)
                continue
                
            frame_bytes = buffer.tobytes()
            
            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + frame_bytes + b'\r\n')
            
        except Exception as e:
            print(f"Error in frame generation: {e}")
            time.sleep(0.1)
            continue

@app.route('/')
@basic_auth.required
def index():
    import socket
    try:
        hostname = socket.gethostname()
        device_ip = socket.gethostbyname(hostname)
    except:
        device_ip = "Unknown"
    
    return render_template_string(HTML_TEMPLATE, 
                                 is_recording=is_recording,
                                 device_ip=device_ip,
                                 start_time=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                                 storage_path='$RECORDING_DIR',
                                 recording_file=getattr(recording_process, 'filename', 'N/A'))

@app.route('/video_feed')
@basic_auth.required
def video_feed():
    return Response(generate_frames(),
                    mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/toggle_record')
@basic_auth.required
def toggle_record():
    global is_recording, recording_process
    
    try:
        if not is_recording:
            # Start recording
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = os.path.join('$RECORDING_DIR', f"recording_{timestamp}.mp4")
            
            print(f"Starting recording: {filename}")
            
            # Use ffmpeg to record
            recording_process = subprocess.Popen([
                'ffmpeg', '-y',
                '-f', 'video4linux2',
                '-i', '/dev/video0',
                '-s', '640x480',
                '-c:v', 'libx264',
                '-preset', 'veryfast',
                '-crf', '25',
                '-r', '15',
                filename
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            
            recording_process.filename = filename
            is_recording = True
            return {'success': True, 'message': 'Recording started', 'filename': filename}
        else:
            # Stop recording
            if recording_process:
                recording_process.terminate()
                recording_process.wait()
                filename = getattr(recording_process, 'filename', 'Unknown')
                is_recording = False
                return {'success': True, 'message': 'Recording stopped', 'filename': filename}
            else:
                is_recording = False
                return {'success': False, 'message': 'No recording process found'}
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

@app.route('/snapshot')
@basic_auth.required
def take_snapshot():
    try:
        camera = get_camera()
        if camera:
            success, frame = camera.read()
            if success:
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                filename = f"snapshot_{timestamp}.jpg"
                filepath = os.path.join('$RECORDING_DIR', filename)
                cv2.imwrite(filepath, frame)
                return {'success': True, 'message': 'Snapshot saved', 'filename': filename}
            else:
                return {'success': False, 'message': 'Failed to read frame from camera'}
        else:
            return {'success': False, 'message': 'Camera not available'}
    except Exception as e:
        return {'success': False, 'message': f'Error: {str(e)}'}

@app.route('/stop_server')
@basic_auth.required
def stop_server():
    print("Server shutdown requested via web interface")
    # This will be handled by the signal handler
    os.kill(os.getpid(), signal.SIGINT)
    return {'success': True, 'message': 'Server stopping...'}

def signal_handler(sig, frame):
    print('\nShutting down CCTV server...')
    global camera, recording_process
    if camera:
        camera.release()
    if recording_process:
        recording_process.terminate()
    sys.exit(0)

if __name__ == '__main__':
    # Setup signal handler for graceful shutdown
    signal.signal(signal.SIGINT, signal_handler)
    
    print("🚀 Starting CCTV Server...")
    print(f"📝 Username: $AUTH_USER")
    print(f"🔑 Password: $AUTH_PASS")
    print(f"📁 Storage: $RECORDING_DIR")
    print("=" * 50)
    
    # Test camera
    cam = get_camera()
    if cam:
        print("✅ Camera initialized successfully")
    else:
        print("❌ Warning: Could not initialize camera")
    
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
    
    # Check if storage directory exists
    if [ ! -d "$RECORDING_DIR" ]; then
        echo -e "${YELLOW}[*] Creating storage directory...${NC}"
        mkdir -p "$RECORDING_DIR"
    fi
    
    get_ip
    create_server_script
    
    echo -e "${GREEN}[+] Server starting on port $PORT${NC}"
    echo -e "${YELLOW}[*] Username: $AUTH_USER${NC}"
    echo -e "${YELLOW}[*] Password: $AUTH_PASS${NC}"
    echo -e "${YELLOW}[*] Storage: $RECORDING_DIR${NC}"
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
        
        # Check if directory exists
        if [ -d "$RECORDING_DIR" ]; then
            file_count=$(find "$RECORDING_DIR" -type f | wc -l)
            echo "Files in storage: $file_count"
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
                echo -e "${YELLOW}[*] Files in storage:${NC}"
                ls -la "$RECORDING_DIR"
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
        start_server
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
    "ip")
        get_ip
        ;;
    *)
        echo -e "${YELLOW}Usage: $0 {install|start|setup|status|storage|ip}${NC}"
        echo ""
        echo "Commands:"
        echo "  install - Install dependencies and setup"
        echo "  start   - Start the CCTV server"
        echo "  setup   - Configure settings"
        echo "  status  - Show current status"
        echo "  storage - Open storage directory"
        echo "  ip      - Show device IP address"
        echo ""
        echo "Quick Start:"
        echo "  1. Run: ./cctv.sh install"
        echo "  2. Run: ./cctv.sh start"
        echo "  3. Access the stream from another device using the shown URL"
        ;;
esac