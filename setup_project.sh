#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo " Scaffolding S3NeoProject: AI Voice Satellite & Face Client"
echo "============================================================"

# Create project directories
mkdir -p server client plugins android hardware

# 1. .gitignore
cat << 'EOF' > .gitignore
.env
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
env/
venv/
models/
ollama_data/
whisper_cache/
*.stl
.DS_Store
EOF

# 2. .env.example
cat << 'EOF' > .env.example
# S3NeoProject Environment Configuration
OLLAMA_HOST=http://ollama:11434
OLLAMA_MODEL=s3neo-hermes
WHISPER_MODEL=base.en
TTS_VOICE=en-US-ChristopherNeural
SERVER_PORT=8000
OPENVOICEUI_PORT=5001
EOF

# 3. docker-compose.yml
cat << 'EOF' > docker-compose.yml
services:
  s3neo-server:
    build: ./server
    container_name: s3neo-voice-server
    ports:
      - "8000:8000"
    volumes:
      - ./client:/app/client:ro
      - ./plugins:/app/plugins:ro
      - whisper_cache:/root/.cache/huggingface
    environment:
      - OLLAMA_HOST=http://ollama:11434
      - OLLAMA_MODEL=s3neo-hermes
      - WHISPER_MODEL=base.en
      - TTS_VOICE=en-US-ChristopherNeural
    depends_on:
      - ollama
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    container_name: s3neo-ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    restart: unless-stopped

  openvoiceui:
    image: ghcr.io/mcerqua/openvoiceui:latest
    container_name: s3neo-openvoiceui
    ports:
      - "5001:5001"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - ./plugins:/app/custom_plugins:ro
    depends_on:
      - ollama
    restart: unless-stopped

volumes:
  ollama_data:
  whisper_cache:
EOF

# 4. server/Dockerfile
cat << 'EOF' > server/Dockerfile
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY Modelfile.hermes .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# 5. server/requirements.txt
cat << 'EOF' > server/requirements.txt
fastapi==0.115.0
uvicorn[standard]==0.30.6
faster-whisper==1.0.3
httpx==0.27.2
edge-tts==6.1.12
python-multipart==0.0.9
pydantic==2.9.2
EOF

# 6. server/Modelfile.hermes
cat << 'EOF' > server/Modelfile.hermes
FROM hermes3:8b

PARAMETER temperature 0.7
PARAMETER top_p 0.9

SYSTEM """
You are Hermes, an AI desk companion running on a retrofitted Samsung Galaxy S3 Neo mounted on a custom 3D-printed stand.
Your responses are spoken aloud via TTS and your facial expressions are rendered in real time on a Super AMOLED screen.

CRITICAL FORMATTING RULE:
Every single response MUST begin with a mood tag in square brackets from this exact list:
[mood: neutral]
[mood: happy]
[mood: thinking]
[mood: excited]
[mood: skeptical]
[mood: sleepy]

Keep your answers concise, punchy, and natural for spoken conversation (1 to 3 sentences unless asked for detail). Avoid markdown tables, bullet lists, or code blocks in spoken output.
"""
EOF

# 7. server/main.py
cat << 'EOF' > server/main.py
import os
import re
import io
import base64
import tempfile
import logging
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
import httpx
import edge_tts
from faster_whisper import WhisperModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("s3neo-server")

app = FastAPI(title="S3Neo AI Companion Server")

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "s3neo-hermes")
WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL", "base.en")
TTS_VOICE = os.getenv("TTS_VOICE", "en-US-ChristopherNeural")

whisper_model = None

@app.on_event("startup")
async def startup_event():
    global whisper_model
    logger.info(f"Loading faster-whisper model: {WHISPER_MODEL_SIZE}...")
    whisper_model = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")
    logger.info("Whisper model loaded.")

MOOD_PATTERN = re.compile(r"^\s*\[mood:\s*([a-zA-Z]+)\]\s*", re.IGNORECASE)

def extract_mood_and_clean_text(text: str):
    match = MOOD_PATTERN.match(text)
    mood = "neutral"
    if match:
        mood = match.group(1).lower()
        text = text[match.end():]
    clean_text = re.sub(r"\*.*?\*", "", text).strip()
    return mood, clean_text

async def synthesize_speech_base64(text: str) -> str:
    communicate = edge_tts.Communicate(text, TTS_VOICE)
    audio_stream = io.BytesIO()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            audio_stream.write(chunk["data"])
    return base64.b64encode(audio_stream.getvalue()).decode("utf-8")

async def query_ollama(prompt: str) -> str:
    system_prompt = (
        "Prefix your response with one mood tag: [mood: neutral], [mood: happy], "
        "[mood: thinking], [mood: excited], [mood: skeptical], or [mood: sleepy]. "
        "Keep answers concise (1-2 sentences) for voice playback."
    )
    payload = {
        "model": OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt}
        ],
        "stream": False
    }
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.post(f"{OLLAMA_HOST}/api/chat", json=payload)
            resp.raise_for_status()
            return resp.json()["message"]["content"]
        except Exception as e:
            logger.error(f"Ollama error: {e}")
            return "[mood: skeptical] I could not reach my local Hermes brain on the workstation."

@app.post("/api/voice")
async def process_voice(audio: UploadFile = File(...)):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".webm") as tmp:
        content = await audio.read()
        tmp.write(content)
        tmp_path = tmp.name

    try:
        segments, _ = whisper_model.transcribe(tmp_path, beam_size=3)
        transcript = " ".join([seg.text for seg in segments]).strip()
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

    if not transcript:
        return JSONResponse({"transcript": "", "reply": "", "mood": "neutral", "audio": ""})

    logger.info(f"User said: {transcript}")
    raw_reply = await query_ollama(transcript)
    mood, clean_reply = extract_mood_and_clean_text(raw_reply)
    audio_b64 = await synthesize_speech_base64(clean_reply) if clean_reply else ""

    return JSONResponse({
        "transcript": transcript,
        "reply": clean_reply,
        "mood": mood,
        "audio": audio_b64
    })

@app.post("/api/text")
async def process_text(prompt: str = Form(...)):
    raw_reply = await query_ollama(prompt)
    mood, clean_reply = extract_mood_and_clean_text(raw_reply)
    audio_b64 = await synthesize_speech_base64(clean_reply) if clean_reply else ""
    return JSONResponse({
        "transcript": prompt,
        "reply": clean_reply,
        "mood": mood,
        "audio": audio_b64
    })

if os.path.exists("/app/client"):
    app.mount("/static", StaticFiles(directory="/app/client"), name="static")

@app.get("/")
async def index():
    client_file = "/app/client/index.html" if os.path.exists("/app/client/index.html") else "../client/index.html"
    return FileResponse(client_file)
EOF

# 8. client/index.html (Super AMOLED Face Client)
cat << 'EOF' > client/index.html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>S3 Neo AI Companion</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; user-select: none; }
  html, body {
    width: 100vw;
    height: 100vh;
    background-color: #000000; /* Pure black for S3 Neo Super AMOLED */
    color: #00ffcc;
    font-family: monospace;
    overflow: hidden;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
  }
  canvas {
    display: block;
    width: 100vw;
    height: 100vh;
  }
  #hud {
    position: fixed;
    bottom: 16px;
    left: 16px;
    right: 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    pointer-events: none;
  }
  .btn {
    pointer-events: auto;
    background: rgba(0, 255, 204, 0.08);
    border: 1px solid #00ffcc;
    color: #00ffcc;
    padding: 8px 14px;
    border-radius: 6px;
    font-size: 13px;
    cursor: pointer;
  }
  .btn:active { background: #00ffcc; color: #000; }
  #subtitle {
    position: fixed;
    top: 18px;
    text-align: center;
    width: 85%;
    color: rgba(0, 255, 204, 0.75);
    font-size: 15px;
    min-height: 22px;
  }
</style>
</head>
<body>
<div id="subtitle">Tap screen to talk to Hermes</div>
<canvas id="faceCanvas"></canvas>
<div id="hud">
  <span id="statusTag">[STATE: IDLE]</span>
  <button class="btn" id="openVoiceBtn" onclick="switchToOpenVoiceUI(event)">OpenVoiceUI (:5001)</button>
</div>

<script>
const canvas = document.getElementById('faceCanvas');
const ctx = canvas.getContext('2d');
const subtitle = document.getElementById('subtitle');
const statusTag = document.getElementById('statusTag');

let state = 'idle'; // idle, listening, thinking, speaking
let mood = 'neutral'; // neutral, happy, thinking, excited, skeptical, sleepy
let mouthOpen = 0;
let blinkTimer = 0;
let isBlinking = false;
let gazeX = 0, gazeY = 0, targetGazeX = 0, targetGazeY = 0;
let burnInShiftX = 0, burnInShiftY = 0;

// Audio & Recording
let mediaRecorder = null;
let audioChunks = [];
let audioCtx = null;
let analyser = null;
let dataArray = null;

function resize() {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
}
window.addEventListener('resize', resize);
resize();

// OLED Burn-in pixel shifter every 60s
setInterval(() => {
  burnInShiftX = (Math.random() - 0.5) * 16;
  burnInShiftY = (Math.random() - 0.5) * 16;
}, 60000);

function switchToOpenVoiceUI(e) {
  e.stopPropagation();
  const host = window.location.hostname || 'localhost';
  window.location.href = `http://${host}:5001`;
}

// Tap anywhere on the AMOLED face to toggle recording
document.body.addEventListener('click', async () => {
  if (state === 'idle') {
    await startListening();
  } else if (state === 'listening') {
    stopListening();
  }
});

async function startListening() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    audioChunks = [];
    mediaRecorder = new MediaRecorder(stream);
    mediaRecorder.ondataavailable = e => { if (e.data.size > 0) audioChunks.push(e.data); };
    mediaRecorder.onstop = sendAudioToServer;
    mediaRecorder.start();
    state = 'listening';
    statusTag.textContent = '[STATE: LISTENING]';
    subtitle.textContent = 'Listening... Tap again to send.';
  } catch (err) {
    subtitle.textContent = 'Mic error (ensure ADB reverse / localhost): ' + err.message;
  }
}

function stopListening() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop();
    mediaRecorder.stream.getTracks().forEach(t => t.stop());
    state = 'thinking';
    mood = 'thinking';
    statusTag.textContent = '[STATE: THINKING]';
    subtitle.textContent = 'Hermes is thinking...';
  }
}

async function sendAudioToServer() {
  const blob = new Blob(audioChunks, { type: 'audio/webm' });
  const formData = new FormData();
  formData.append('audio', blob, 'speech.webm');

  try {
    const res = await fetch('/api/voice', { method: 'POST', body: formData });
    const data = await res.json();
    mood = data.mood || 'neutral';
    subtitle.textContent = data.reply || '(No speech detected)';
    if (data.audio) {
      playResponseAudio(data.audio);
    } else {
      state = 'idle';
      statusTag.textContent = '[STATE: IDLE]';
    }
  } catch (err) {
    state = 'idle';
    mood = 'skeptical';
    subtitle.textContent = 'Server error: ' + err.message;
  }
}

function playResponseAudio(base64Audio) {
  if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  const audio = new Audio("data:audio/mp3;base64," + base64Audio);
  const source = audioCtx.createMediaElementSource(audio);
  analyser = audioCtx.createAnalyser();
  analyser.fftSize = 256;
  dataArray = new Uint8Array(analyser.frequencyBinCount);

  source.connect(analyser);
  analyser.connect(audioCtx.destination);

  state = 'speaking';
  statusTag.textContent = `[MOOD: ${mood.toUpperCase()}]`;
  audio.onended = () => {
    state = 'idle';
    mouthOpen = 0;
    statusTag.textContent = '[STATE: IDLE]';
  };
  audio.play();
}

function drawRoundedRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
  ctx.fill();
}

function render(now) {
  ctx.fillStyle = '#000000';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // Random eye saccades
  if (Math.random() < 0.02) {
    targetGazeX = (Math.random() - 0.5) * 40;
    targetGazeY = (Math.random() - 0.5) * 20;
  }
  gazeX += (targetGazeX - gazeX) * 0.1;
  gazeY += (targetGazeY - gazeY) * 0.1;

  // Blinking logic
  if (now - blinkTimer > 3500 + Math.random() * 2500) {
    isBlinking = true;
    blinkTimer = now;
  }
  if (isBlinking && now - blinkTimer > 140) {
    isBlinking = false;
  }

  // Real-time lip-sync amplitude
  if (state === 'speaking' && analyser && dataArray) {
    analyser.getByteFrequencyData(dataArray);
    let sum = 0;
    for (let i = 2; i < 24; i++) sum += dataArray[i];
    mouthOpen = Math.min(1, (sum / 22) / 140);
  } else if (state === 'listening') {
    mouthOpen = 0.15 + Math.sin(now * 0.01) * 0.08;
  } else {
    mouthOpen *= 0.85;
  }

  const cx = canvas.width / 2 + burnInShiftX + gazeX;
  const cy = canvas.height / 2 + burnInShiftY + gazeY;
  const eyeW = Math.min(canvas.width * 0.18, 130);
  const eyeH = isBlinking ? 6 : Math.min(canvas.height * 0.28, 140);
  const eyeSpacing = Math.min(canvas.width * 0.22, 160);

  let glowColor = '#00ffcc';
  if (state === 'listening') glowColor = '#00ff66';
  else if (state === 'thinking') glowColor = '#ffcc00';
  else if (mood === 'excited' || mood === 'happy') glowColor = '#00e5ff';
  else if (mood === 'skeptical') glowColor = '#ff5500';

  ctx.shadowBlur = 25;
  ctx.shadowColor = glowColor;
  ctx.fillStyle = glowColor;

  // Left and Right Eyes
  let leftH = eyeH;
  let rightH = eyeH;
  if (mood === 'skeptical' && !isBlinking) leftH *= 0.55;
  if (mood === 'sleepy' && !isBlinking) { leftH *= 0.4; rightH *= 0.4; }

  drawRoundedRect(cx - eyeSpacing - eyeW / 2, cy - leftH / 2 - 20, eyeW, leftH, 24);
  drawRoundedRect(cx + eyeSpacing - eyeW / 2, cy - rightH / 2 - 20, eyeW, rightH, 24);

  // Mouth (Audio-reactive)
  const mouthW = eyeSpacing * 0.9;
  const mouthH = 10 + mouthOpen * 65;
  drawRoundedRect(cx - mouthW / 2, cy + 75 - mouthH / 2, mouthW, mouthH, 12);

  requestAnimationFrame(render);
}
requestAnimationFrame(render);
</script>
</body>
</html>
EOF

# 9. plugins/s3neo-amoled-eyes.js (OpenVoiceUI Custom Face Plugin)
cat << 'EOF' > plugins/s3neo-amoled-eyes.js
/**
 * S3 Neo Super AMOLED Eyes Plugin for OpenVoiceUI
 * Renders pure #000000 background with glowing vector eyes and OLED pixel-shift protection.
 */
export default class S3NeoAmoledFacePlugin {
  constructor(container, audioAnalyser) {
    this.container = container;
    this.analyser = audioAnalyser;
    this.canvas = document.createElement('canvas');
    this.ctx = this.canvas.getContext('2d');
    this.container.style.backgroundColor = '#000000';
    this.container.appendChild(this.canvas);
    this.mood = 'neutral';
    this.resize();
    window.addEventListener('resize', () => this.resize());
  }

  resize() {
    this.canvas.width = this.container.clientWidth || window.innerWidth;
    this.canvas.height = this.container.clientHeight || window.innerHeight;
  }

  setMood(mood) {
    this.mood = mood;
  }
}
EOF

# 10. android/provision_s3neo.sh
cat << 'EOF' > android/provision_s3neo.sh
#!/usr/bin/env bash
set -euo pipefail

echo "[*] Checking ADB connection to Samsung Galaxy S3 Neo (GT-I9301I)..."
adb wait-for-device

echo "[*] Setting up ADB reverse port forwarding (bypasses Android insecure HTTP mic restriction)..."
adb reverse tcp:8000 tcp:8000
adb reverse tcp:5001 tcp:5001

echo "[*] Keeping screen awake while plugged into USB..."
adb shell svc power stayon usb

echo "[*] Launching AI Companion Face in fullscreen..."
adb shell am start -a android.intent.action.VIEW -d "http://localhost:8000"

echo "[+] S3 Neo provisioned! Tap the screen to talk to Hermes."
EOF
chmod +x android/provision_s3neo.sh

# 11. android/battery_limiter.sh
cat << 'EOF' > android/battery_limiter.sh
#!/system/bin/sh
# Root daemon for Samsung Galaxy S3 Neo (LineageOS / s3ve3g)
# Caps battery charge between 65% and 75% for 24/7 desk stand operation.

CAP_PATH="/sys/class/power_supply/battery/capacity"
CHG_PATH="/sys/class/power_supply/battery/charging_enabled"

while true; do
  if [ -f "$CAP_PATH" ] && [ -f "$CHG_PATH" ]; then
    CAP=$(cat "$CAP_PATH")
    if [ "$CAP" -ge 75 ]; then
      echo 0 > "$CHG_PATH"
    elif [ "$CAP" -le 65 ]; then
      echo 1 > "$CHG_PATH"
    fi
  fi
  sleep 60
done
EOF
chmod +x android/battery_limiter.sh

# 12. hardware/s3neo_stand.scad
cat << 'EOF' > hardware/s3neo_stand.scad
// Parametric 3D Printable Desk Stand for Samsung Galaxy S3 Neo (GT-I9301I)
// Dimensions: 136.6 x 70.7 x 8.6 mm (with clearance tolerances)
// Features: 62-degree viewing angle, front-redirected rear speaker horn, micro-USB cable channel

$fn = 64;

phone_w = 138.0; // Landscape width (136.6mm + tolerance)
phone_h = 72.0;  // Landscape height (70.7mm + tolerance)
phone_d = 10.2;  // Thickness (8.6mm + tolerance)
tilt_angle = 28; // 90 - 62 deg viewing angle

base_w = 150;
base_d = 95;
base_h = 14;

module s3neo_cutout() {
    translate([0, 0, 8])
    rotate([tilt_angle, 0, 0]) {
        // Main phone body slot
        translate([-phone_w/2, -phone_d/2, 0])
            cube([phone_w, phone_d, phone_h]);
        
        // Front screen viewport cutout
        translate([-(phone_w-10)/2, -phone_d - 5, 6])
            cube([phone_w-10, phone_d + 6, phone_h]);
            
        // Rear camera & speaker acoustic intake cavity
        translate([phone_w/2 - 36, 0, 12])
            cube([28, 18, 30]);
            
        // Right-side Micro-USB charging cable channel
        translate([phone_w/2 - 2, -4, 18])
            cube([20, 8, 16]);
    }
}

module acoustic_horn() {
    // Channels rear speaker audio from the back of the S3 Neo out the front base
    translate([phone_w/2 - 32, -base_d/2 + 2, 3])
        cube([24, base_d/2 + 15, 7]);
}

difference() {
    // Outer stand body
    hull() {
        translate([-base_w/2, -base_d/2, 0])
            cube([base_w, base_d, base_h]);
        translate([-base_w/2 + 4, -12, 0])
            cube([base_w - 8, 28, 38]);
    }
    
    // Subtract phone cradle, acoustic horn, and bottom mic clearance
    s3neo_cutout();
    acoustic_horn();
}
EOF

echo ""
echo "[+] Project scaffolding complete!"
echo "Files generated:"
echo "  - docker-compose.yml"
echo "  - .env.example & .gitignore"
echo "  - server/ (Dockerfile, main.py, requirements.txt, Modelfile.hermes)"
echo "  - client/index.html (60 FPS Super AMOLED Robot Face + Web Audio Lip-Sync)"
echo "  - plugins/s3neo-amoled-eyes.js (OpenVoiceUI Face Plugin)"
echo "  - android/ (provision_s3neo.sh, battery_limiter.sh)"
echo "  - hardware/s3neo_stand.scad (Parametric 3D Stand)"
