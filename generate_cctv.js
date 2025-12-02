const fs = require('fs');
const path = require('path');

// Configuration - adjust these values as needed
const config = {
  serverPort: 8080,
  cameraResolution: "1280x720",
  streamQuality: "medium",
  recordingEnabled: true,
  adminPassword: "admin123"
};

// Create directory if it doesn't exist
const outputDir = './cctv-setup';
if (!fs.existsSync(outputDir)) {
  fs.mkdirSync(outputDir, { recursive: true });
}

// 1. Termux installation script
const installScript = `#!/data/data/com.termux/files/usr/bin/bash

echo "======================================"
echo "Termux CCTV Setup - Installation Script"
echo "======================================"

# Update packages
echo "Updating package lists..."
pkg update -y

# Install required packages
echo "Installing required packages..."
pkg install -y nodejs npm ffmpeg termux-api python git wget

# Install additional utilities
pkg install -y openssh rsync curl

# Create project directory
mkdir -p ~/cctv-setup
cd ~/cctv-setup

# Initialize npm project
npm init -y

# Install Node.js dependencies
echo "Installing Node.js dependencies..."
npm install express socket.io multer fs-extra moment node-schedule basic-auth

# Set up directories
mkdir -p recordings
mkdir -p logs
mkdir -p public

# Set permissions for Termux API
echo "Setting up Termux API permissions..."
echo "Please grant camera and storage permissions when prompted."

# Create startup script
cat > start_cctv.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/cctv-setup
echo "Starting CCTV Server..."
node server.js
EOF

chmod +x start_cctv.sh

echo "======================================"
echo "Installation complete!"
echo "Run './start_cctv.sh' to start the CCTV server"
echo "======================================"
`;

// 2. Node.js server code
const serverCode = `const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const fs = require('fs-extra');
const path = require('path');
const { spawn } = require('child_process');
const moment = require('moment');
const schedule = require('node-schedule');
const auth = require('basic-auth');

const app = express();
const server = http.createServer(app);
const io = socketIo(server);

const PORT = ${config.serverPort};
const ADMIN_PASSWORD = "${config.adminPassword}";
const RESOLUTION = "${config.cameraResolution}";
const RECORDING_ENABLED = ${config.recordingEnabled};

// Middleware for authentication
const authenticate = (req, res, next) => {
  const credentials = auth(req);
  if (!credentials || credentials.pass !== ADMIN_PASSWORD) {
    res.statusCode = 401;
    res.setHeader('WWW-Authenticate', 'Basic realm="CCTV Admin"');
    res.end('Access denied');
  } else {
    next();
  }
};

// Serve static files
app.use('/public', express.static('public'));
app.use('/recordings', authenticate, express.static('recordings'));

// Main admin interface
app.get('/', authenticate, (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// API endpoints
app.get('/api/status', authenticate, (req, res) => {
  const status = {
    server: 'running',
    time: moment().format('YYYY-MM-DD HH:mm:ss'),
    recordings: RECORDING_ENABLED,
    resolution: RESOLUTION,
    port: PORT
  };
  res.json(status);
});

app.get('/api/recordings', authenticate, async (req, res) => {
  try {
    const recordings = await fs.readdir('recordings');
    const recordingList = recordings
      .filter(file => file.endsWith('.mp4'))
      .map(file => ({
        name: file,
        date: file.split('_')[1]?.split('.')[0] || 'unknown',
        size: fs.statSync(path.join('recordings', file)).size
      }));
    res.json(recordingList);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch recordings' });
  }
});

app.post('/api/start-recording', authenticate, (req, res) => {
  startRecording();
  res.json({ message: 'Recording started' });
});

app.post('/api/stop-recording', authenticate, (req, res) => {
  stopRecording();
  res.json({ message: 'Recording stopped' });
});

// Camera streaming
let streamProcess = null;
let recordingProcess = null;

const startStream = () => {
  console.log('Starting camera stream...');
  
  // Use termux-camera-photo for Android camera access
  streamProcess = spawn('termux-camera-photo', [
    '-c', '0',
    '-o', '/dev/stdout'
  ]);

  const ffmpegStream = spawn('ffmpeg', [
    '-i', '-',
    '-f', 'mjpeg',
    '-q:v', getQualityValue(),
    '-'
  ]);

  streamProcess.stdout.pipe(ffmpegStream.stdin);

  ffmpegStream.stdout.on('data', (data) => {
    // Broadcast video data to connected clients
    io.emit('video_frame', data);
  });

  ffmpegStream.stderr.on('data', (data) => {
    console.error('Stream error:', data.toString());
  });

  ffmpegStream.on('close', (code) => {
    console.log('Stream process exited with code', code);
    // Restart stream if it crashes
    setTimeout(startStream, 5000);
  });
};

const startRecording = () => {
  if (!RECORDING_ENABLED || recordingProcess) return;

  const timestamp = moment().format('YYYY-MM-DD_HH-mm-ss');
  const filename = \`recording_\${timestamp}.mp4\`;
  const filepath = path.join('recordings', filename);

  console.log(\`Starting recording: \${filename}\`);

  recordingProcess = spawn('termux-camera-photo', [
    '-c', '0',
    '-o', '/dev/stdout'
  ]);

  const ffmpegRecord = spawn('ffmpeg', [
    '-i', '-',
    '-c:v', 'libx264',
    '-preset', 'fast',
    '-crf', '23',
    '-s', RESOLUTION,
    filepath
  ]);

  recordingProcess.stdout.pipe(ffmpegRecord.stdin);

  ffmpegRecord.on('close', (code) => {
    console.log(\`Recording saved: \${filename}\`);
    recordingProcess = null;
  });
};

const stopRecording = () => {
  if (recordingProcess) {
    recordingProcess.kill('SIGINT');
    recordingProcess = null;
    console.log('Recording stopped');
  }
};

const getQualityValue = () => {
  switch("${config.streamQuality}") {
    case 'high': return '2';
    case 'low': return '10';
    default: return '5';
  }
};

// Socket.io connection handling
io.on('connection', (socket) => {
  console.log('Client connected');
  
  socket.on('disconnect', () => {
    console.log('Client disconnected');
  });
});

// Schedule automatic recordings (every hour)
if (RECORDING_ENABLED) {
  schedule.scheduleJob('0 * * * *', () => {
    stopRecording();
    setTimeout(startRecording, 1000);
  });
}

// Start server
server.listen(PORT, '0.0.0.0', () => {
  console.log(\`CCTV Server running on port \${PORT}\`);
  console.log(\`Access admin interface at: http://localhost:\${PORT}\`);
  console.log(\`External access: http://[YOUR_PHONE_IP]:\${PORT}\`);
  
  // Start camera stream
  setTimeout(startStream, 2000);
  
  // Start recording if enabled
  if (RECORDING_ENABLED) {
    setTimeout(startRecording, 5000);
  }
});

// Cleanup on exit
process.on('SIGINT', () => {
  console.log('Shutting down server...');
  if (streamProcess) streamProcess.kill();
  if (recordingProcess) recordingProcess.kill();
  process.exit(0);
});
`;

// 3. HTML admin interface
const htmlInterface = `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Termux CCTV Admin</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: Arial, sans-serif;
            background: #1a1a1a;
            color: #fff;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .status-panel {
            background: #2a2a2a;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
        }
        
        .video-container {
            background: #000;
            border-radius: 10px;
            padding: 20px;
            text-align: center;
            margin-bottom: 20px;
        }
        
        #videoFeed {
            max-width: 100%;
            height: auto;
            border-radius: 10px;
        }
        
        .controls {
            display: flex;
            gap: 10px;
            justify-content: center;
            flex-wrap: wrap;
            margin-bottom: 20px;
        }
        
        .btn {
            padding: 10px 20px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-size: 16px;
            transition: background 0.3s;
        }
        
        .btn-primary {
            background: #007bff;
            color: white;
        }
        
        .btn-danger {
            background: #dc3545;
            color: white;
        }
        
        .btn-success {
            background: #28a745;
            color: white;
        }
        
        .btn:hover {
            opacity: 0.8;
        }
        
        .recordings-panel {
            background: #2a2a2a;
            padding: 20px;
            border-radius: 10px;
        }
        
        .recording-item {
            background: #3a3a3a;
            padding: 10px;
            margin: 10px 0;
            border-radius: 5px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-right: 10px;
        }
        
        .status-online {
            background: #28a745;
        }
        
        .status-offline {
            background: #dc3545;
        }
        
        @media (max-width: 768px) {
            .controls {
                flex-direction: column;
            }
            
            .btn {
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🏠 Termux CCTV System</h1>
        <p>Home Security Camera Dashboard</p>
    </div>

    <div class="status-panel">
        <h3>📊 System Status</h3>
        <div id="statusInfo">
            <span class="status-indicator status-online"></span>
            <span>Server Online</span> | 
            <span id="currentTime"></span> | 
            <span>Resolution: ${config.cameraResolution}</span>
        </div>
    </div>

    <div class="video-container">
        <h3>📹 Live Camera Feed</h3>
        <canvas id="videoFeed" width="640" height="480"></canvas>
        <p id="streamStatus">Connecting to camera...</p>
    </div>

    <div class="controls">
        <button class="btn btn-success" onclick="startRecording()">🔴 Start Recording</button>
        <button class="btn btn-danger" onclick="stopRecording()">⏹️ Stop Recording</button>
        <button class="btn btn-primary" onclick="refreshStream()">🔄 Refresh Stream</button>
        <button class="btn btn-primary" onclick="loadRecordings()">📂 Load Recordings</button>
    </div>

    <div class="recordings-panel">
        <h3>📁 Recorded Videos</h3>
        <div id="recordingsList">
            <p>Loading recordings...</p>
        </div>
    </div>

    <script src="/socket.io/socket.io.js"></script>
    <script>
        const socket = io();
        const canvas = document.getElementById('videoFeed');
        const ctx = canvas.getContext('2d');
        
        // Update current time
        setInterval(() => {
            document.getElementById('currentTime').textContent = new Date().toLocaleString();
        }, 1000);
        
        // Socket events
        socket.on('connect', () => {
            document.getElementById('streamStatus').textContent = 'Connected to server';
        });
        
        socket.on('disconnect', () => {
            document.getElementById('streamStatus').textContent = 'Disconnected from server';
        });
        
        socket.on('video_frame', (data) => {
            const img = new Image();
            const blob = new Blob([data], { type: 'image/jpeg' });
            const url = URL.createObjectURL(blob);
            
            img.onload = () => {
                ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
                URL.revokeObjectURL(url);
            };
            
            img.src = url;
            document.getElementById('streamStatus').textContent = 'Live stream active';
        });
        
        // Control functions
        function startRecording() {
            fetch('/api/start-recording', { method: 'POST' })
                .then(response => response.json())
                .then(data => alert(data.message))
                .catch(error => alert('Error starting recording'));
        }
        
        function stopRecording() {
            fetch('/api/stop-recording', { method: 'POST' })
                .then(response => response.json())
                .then(data => alert(data.message))
                .catch(error => alert('Error stopping recording'));
        }
        
        function refreshStream() {
            socket.disconnect();
            socket.connect();
        }
        
        function loadRecordings() {
            fetch('/api/recordings')
                .then(response => response.json())
                .then(recordings => {
                    const container = document.getElementById('recordingsList');
                    if (recordings.length === 0) {
                        container.innerHTML = '<p>No recordings found</p>';
                        return;
                    }
                    
                    container.innerHTML = recordings.map(recording => \`
                        <div class="recording-item">
                            <div>
                                <strong>\${recording.name}</strong><br>
                                <small>Date: \${recording.date} | Size: \${Math.round(recording.size / 1024 / 1024)}MB</small>
                            </div>
                            <a href="/recordings/\${recording.name}" download class="btn btn-primary">Download</a>
                        </div>
                    \`).join('');
                })
                .catch(error => {
                    document.getElementById('recordingsList').innerHTML = '<p>Error loading recordings</p>';
                });
        }
        
        // Load initial data
        loadRecordings();
    </script>
</body>
</html>`;

// 4. Setup instructions
const setupInstructions = `# Termux CCTV Setup Instructions

## Prerequisites
- Old Android phone (Android 7+)
- Termux app installed from F-Droid or Play Store
- Good WiFi connection
- Phone charger for continuous power

## Step 1: Install Termux
1. Download Termux from F-Droid (recommended) or Google Play Store
2. Open Termux and wait for initial setup

## Step 2: Grant Permissions
1. In Android settings, go to Apps > Termux > Permissions
2. Enable Camera, Storage, and Microphone permissions

## Step 3: Run Installation Script
1. Copy the install.sh file to your phone
2. In Termux, run:
   \`\`\`bash
   bash install.sh
   \`\`\`
3. Wait for installation to complete (may take 10-15 minutes)

## Step 4: Copy Server Files
1. Copy server.js to ~/cctv-setup/
2. Copy index.html to ~/cctv-setup/public/
3. Set proper file permissions

## Step 5: Start CCTV Server
1. In Termux, run:
   \`\`\`bash
   cd ~/cctv-setup
   ./start_cctv.sh
   \`\`\`

## Step 6: Access Camera Interface
1. Find your phone's IP address:
   \`\`\`bash
   ip addr show wlan0 | grep inet
   \`\`\`
2. Open browser on another device
3. Go to: http://[PHONE_IP]:${config.serverPort}
4. Login with password: ${config.adminPassword}

## Troubleshooting
- Camera permission issues: Re-grant camera permissions in Android settings
- Network access: Ensure phone and viewing device are on same WiFi
- Port conflicts: Change port in server.js if ${config.serverPort} is in use
- Performance issues: Lower resolution or quality settings

## Advanced Features
- Recordings are saved to ~/cctv-setup/recordings/
- Server starts automatically with start_cctv.sh
- Web interface accessible from any device on network
- Basic authentication protects camera access

## Security Notes
- Change default admin password
- Use firewall rules if phone has internet access
- Keep Termux and packages updated
- Monitor storage usage for recordings

## Remote Access Setup (Optional)
1. Set up port forwarding on router
2. Configure dynamic DNS service
3. Use VPN for secure access
4. Enable SSH for remote management
`;

// 5. Package.json for the project
const packageJson = `{
  "name": "termux-cctv",
  "version": "1.0.0",
  "description": "Termux-based CCTV system for old Android phones",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "install-termux": "bash install.sh"
  },
  "keywords": ["cctv", "termux", "android", "security", "camera"],
  "dependencies": {
    "express": "^4.18.2",
    "socket.io": "^4.7.2",
    "multer": "^1.4.5",
    "fs-extra": "^11.1.1",
    "moment": "^2.29.4",
    "node-schedule": "^2.1.1",
    "basic-auth": "^2.0.1"
  }
}`;

// 6. Camera utilities script
const cameraUtils = `#!/data/data/com.termux/files/usr/bin/bash

# Camera utilities for Termux CCTV

check_camera() {
    echo "Checking camera availability..."
    termux-camera-info
}

test_camera() {
    echo "Testing camera capture..."
    termux-camera-photo ~/test_photo.jpg
    echo "Test photo saved as ~/test_photo.jpg"
}

list_cameras() {
    echo "Available cameras:"
    termux-camera-info | grep -E "(Camera|ID)"
}

set_permissions() {
    echo "Setting up camera permissions..."
    termux-setup-storage
    echo "Please grant camera permission when prompted"
}

monitor_stream() {
    echo "Monitoring camera stream..."
    while true; do
        termux-camera-photo /dev/stdout | wc -c
        sleep 5
    done
}

case "$1" in
    "check")
        check_camera
        ;;
    "test")
        test_camera
        ;;
    "list")
        list_cameras
        ;;
    "permissions")
        set_permissions
        ;;
    "monitor")
        monitor_stream
        ;;
    *)
        echo "Usage: $0 {check|test|list|permissions|monitor}"
        echo "  check      - Check camera availability"
        echo "  test       - Take test photo"
        echo "  list       - List available cameras"
        echo "  permissions - Set up permissions"
        echo "  monitor    - Monitor camera stream"
        ;;
esac
`;

// Write all files
fs.writeFileSync(path.join(outputDir, 'install.sh'), installScript);
fs.writeFileSync(path.join(outputDir, 'server.js'), serverCode);
fs.writeFileSync(path.join(outputDir, 'index.html'), htmlInterface);
fs.writeFileSync(path.join(outputDir, 'setup_instructions.md'), setupInstructions);
fs.writeFileSync(path.join(outputDir, 'package.json'), packageJson);
fs.writeFileSync(path.join(outputDir, 'camera_utils.sh'), cameraUtils);

// Make scripts executable
fs.chmodSync(path.join(outputDir, 'install.sh'), '755');
fs.chmodSync(path.join(outputDir, 'camera_utils.sh'), '755');

console.log('======================================');
console.log('Termux CCTV Setup Files Generated!');
console.log('======================================');
console.log(`Files saved to: ${path.resolve(outputDir)}`);
console.log(`Server will run on port: ${config.serverPort}`);
console.log(`Camera resolution: ${config.cameraResolution}`);
console.log(`Admin password: ${config.adminPassword}`);
console.log('\nNext Steps:');
console.log('1. cd into the cctv-setup directory');
console.log('2. Run: bash install.sh');
console.log('3. Then run: ./start_cctv.sh');
console.log('======================================');
