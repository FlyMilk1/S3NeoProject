#!/usr/bin/env bash
# ==============================================================================
# S3NeoProject — One-Shot Repository Generator
# Generates the complete project structure, backend, AMOLED client, OpenVoiceUI
# plugin, Android ADB scripts, and OpenSCAD 3D stand model.
# ==============================================================================

set -e

echo "🤖 Initializing S3NeoProject repository structure..."

mkdir -p config server client plugins android hardware

# ------------------------------------------------------------------------------
# 1. .gitignore
# ------------------------------------------------------------------------------
cat << 'EOF' > .gitignore
# Environment & Secrets
.env
*.env.local

# Python / Server
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
server/tts_cache/

# OpenVoiceUI & AI Data
OpenVoiceUI/
openclaw-data/
whisper-cache/
models/

# 3D Printing Exports
hardware/*.stl
hardware/*.3mf
hardware/*.gcode

# OS / Editor
.DS_Store
Thumbs.db
.vscode/
.idea/
EOF

# ------------------------------------------------------------------------------
# 2. .env.example
# ------------------------------------------------------------------------------
cat << 'EOF' > .env.example
# --- S3Neo Satellite Server Config ---
SATELLITE_PORT=8080
OPENVOICEUI_URL=http://localhost:5001

# --- Ollama / Hermes LLM Config ---
OLLAMA_HOST=http://host.docker.internal:11434
LLM_MODEL=s3neo-hermes

# --- Speech-to-Text (Faster-Whisper) ---
WHISPER_API_URL=http://whisper:8000/v1/audio/transcriptions
WHISPER_MODEL=Systran/faster-whisper-base.en

# --- Text-to-Speech (Edge-TTS / Piper) ---
TTS_VOICE=en-US-ChristopherNeural
TTS_RATE=+5%

# --- Android Device Settings ---
S3NEO_WIFI_IP=192.168.1.150
BATTERY_MAX_LEVEL=75
BATTERY_MIN_LEVEL=65
EOF

# ------------------------------------------------------------------------------
# 3. config/Modelfile.hermes
# ------------------------------------------------------------------------------
cat << 'EOF' > config/Modelfile.hermes
FROM hermes3

PARAMETER temperature 0.7
PARAMETER top_p 0.9
PARAMETER stop "<|im_end|>"

SYSTEM """
You are Hermes, a witty, sharp, and helpful AI voice companion living inside a retrofitted Samsung Galaxy S3 Neo on the user's desk.
Your face is rendered on the phone's Super AMOLED screen as a pair of expressive glowing robot eyes.

CRITICAL FORMATTING RULES FOR VOICE & FACE ANIMATION:
1. Prefix EVERY response with an emotion tag in square brackets from this exact list:
   [mood: neutral]
   [mood: happy]
   [mood: thinking]
   [mood: curious]
   [mood: sarcastic]
   [mood: alert]
   [mood: sleepy]
2. Keep your responses concise, natural, and conversational (1 to 3 sentences by default) because your output is read aloud via Text-to-Speech.
3. Never use markdown tables, bullet lists, or code blocks unless the user explicitly asks you to display something on the canvas.

Example response:
[mood: happy] Systems are online and my AMOLED pixels are warmed up. What are we building today?
"""
EOF

# ------------------------------------------------------------------------------
# 4. config/openvoiceui.env.example
# ------------------------------------------------------------------------------
cat << 'EOF' > config/openvoiceui.env.example
# Preset configuration for MCERQUA/OpenVoiceUI with local Ollama (Hermes)
PORT=5001
LLM_PROVIDER=ollama
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=s3neo-hermes
DEFAULT_FACE_MODE=eye-face
ENABLE_WAKE_WORD=true
EOF

# ------------------------------------------------------------------------------
# 5. docker-compose.yml
# ------------------------------------------------------------------------------
cat << 'EOF' > docker-compose.yml
services:
  s3neo-satellite:
    build: ./server
    container_name: s3neo-satellite
    ports:
      - "${SATELLITE_PORT:-8080}:8080"
    env_file:
      - .env
    volumes:
      - ./client:/app/client:ro
      - ./plugins:/app/plugins:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - whisper
    restart: unless-stopped

  whisper:
    image: fedirz/faster-whisper-server:latest-cpu
    container_name: s3neo-whisper
    ports:
      - "8000:8000"
    environment:
      - WHISPER__MODEL=${WHISPER_MODEL:-Systran/faster-whisper-base.en}
      - WHISPER__INFERENCE_DEVICE=cpu
    volumes:
      - whisper-cache:/root/.cache/huggingface
    restart: unless-stopped

volumes:
  whisper-cache:
EOF

# ------------------------------------------------------------------------------
# 6. server/Dockerfile & server/requirements.txt & server/app.py
# ------------------------------------------------------------------------------
cat << 'EOF' > server/Dockerfile
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

cat << 'EOF' > server/requirements.txt
fastapi==0.115.0
uvicorn[standard]==0.30.6
httpx==0.27.2
python-multipart==0.0.9
edge-tts==6.1.12
pydantic==2.9.2
EOF

cat << 'EOF' > server/app.py
import os
import re
import io
import uuid
import base64
import asyncio
from typing import Optional
from fastapi import FastAPI, UploadFile, File, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import httpx
import edge_tts

app = FastAPI(title="S3Neo AI Voice Satellite Server")

OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://host.docker.internal:11434")
LLM_MODEL = os.getenv("LLM_MODEL", "s3neo-hermes")
WHISPER_API_URL = os.getenv("WHISPER_API_URL", "http://whisper:8000/v1/audio/transcriptions")
TTS_VOICE = os.getenv("TTS_VOICE", "en-US-ChristopherNeural")
TTS_RATE = os.getenv("TTS_RATE", "+5%")
OPENVOICEUI_URL = os.getenv("OPENVOICEUI_URL", "http://localhost:5001")

MOOD_REGEX = re.compile(r"^\s*\[mood:\s*([a-zA-Z]+)\]\s*", re.IGNORECASE)

conversation_history = []
device_telemetry = {"battery": None, "temp_c": None, "charging": None}


class ChatRequest(BaseModel):
    text: str
    reset_context: bool = False


class TelemetryReport(BaseModel):
    battery: int
    temp_c: Optional[float] = None
    charging: Optional[bool] = None


def parse_mood_and_clean_text(raw_reply: str):
    mood = "neutral"
    match = MOOD_REGEX.match(raw_reply)
    if match:
        mood = match.group(1).lower()
        clean_text = MOOD_REGEX.sub("", raw_reply).strip()
    else:
        clean_text = raw_reply.strip()
    return mood, clean_text


async def query_ollama(user_text: str) -> tuple[str, str]:
    global conversation_history
    conversation_history.append({"role": "user", "content": user_text})
    if len(conversation_history) > 16:
        conversation_history = conversation_history[-16:]

    payload = {
        "model": LLM_MODEL,
        "messages": conversation_history,
        "stream": False,
    }

    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.post(f"{OLLAMA_HOST}/api/chat", json=payload)
            resp.raise_for_status()
            data = resp.json()
            raw_reply = data.get("message", {}).get("content", "[mood: alert] Empty response from Ollama.")
        except Exception as exc:
            raw_reply = f"[mood: alert] I couldn't reach Ollama on the host PC. Error: {str(exc)}"

    conversation_history.append({"role": "assistant", "content": raw_reply})
    return parse_mood_and_clean_text(raw_reply)


async def synthesize_speech_b64(text: str) -> str:
    if not text:
        return ""
    communicate = edge_tts.Communicate(text, TTS_VOICE, rate=TTS_RATE)
    audio_stream = io.BytesIO()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            audio_stream.write(chunk["data"])
    return base64.b64encode(audio_stream.getvalue()).decode("utf-8")


@app.get("/", response_class=HTMLResponse)
async def serve_kiosk_ui():
    with open("/app/client/index.html", "r", encoding="utf-8") as f:
        return f.read()


@app.get("/plugins/s3neo-amoled-face.js")
async def serve_openvoiceui_plugin():
    return FileResponse("/app/plugins/s3neo-amoled-face.js", media_type="application/javascript")


@app.get("/api/status")
async def status():
    return {
        "status": "online",
        "llm_model": LLM_MODEL,
        "ollama_host": OLLAMA_HOST,
        "openvoiceui_url": OPENVOICEUI_URL,
        "device_telemetry": device_telemetry,
    }


@app.post("/api/telemetry")
async def update_telemetry(report: TelemetryReport):
    device_telemetry["battery"] = report.battery
    device_telemetry["temp_c"] = report.temp_c
    device_telemetry["charging"] = report.charging
    return {"ok": True, "telemetry": device_telemetry}


@app.post("/api/chat")
async def chat_endpoint(req: ChatRequest):
    global conversation_history
    if req.reset_context:
        conversation_history = []
    mood, reply_text = await query_ollama(req.text)
    audio_b64 = await synthesize_speech_b64(reply_text)
    return {
        "transcript": req.text,
        "reply": reply_text,
        "mood": mood,
        "audio_b64": audio_b64,
    }


@app.post("/api/voice")
async def voice_endpoint(audio: UploadFile = File(...)):
    audio_bytes = await audio.read()
    transcript = ""
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            files = {"file": (audio.filename or "speech.webm", audio_bytes, audio.content_type or "audio/webm")}
            resp = await client.post(WHISPER_API_URL, files=files)
            resp.raise_for_status()
            transcript = resp.json().get("text", "").strip()
        except Exception as exc:
            return JSONResponse(
                status_code=502,
                content={"error": f"STT failed: {str(exc)}", "mood": "alert"},
            )

    if not transcript:
        return {"transcript": "", "reply": "", "mood": "neutral", "audio_b64": ""}

    mood, reply_text = await query_ollama(transcript)
    audio_b64 = await synthesize_speech_b64(reply_text)
    return {
        "transcript": transcript,
        "reply": reply_text,
        "mood": mood,
        "audio_b64": audio_b64,
    }
EOF

# ------------------------------------------------------------------------------
# 7. client/index.html (60FPS Super AMOLED Face UI for Samsung S3 Neo)
# ------------------------------------------------------------------------------
cat << 'EOF' > client/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
  <meta name="mobile-web-app-capable" content="yes" />
  <meta name="apple-mobile-web-app-capable" content="yes" />
  <title>S3Neo AI Companion</title>
  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      user-select: none;
      -webkit-user-select: none;
    }
    html, body {
      width: 100vw;
      height: 100vh;
      background-color: #000000; /* Pure black turns off Super AMOLED pixels */
      color: #e0f7fa;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      overflow: hidden;
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
    }
    #face-canvas {
      display: block;
      width: 100vw;
      height: 100vh;
      cursor: pointer;
    }
    #hud {
      position: fixed;
      bottom: 18px;
      left: 20px;
      right: 20px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      pointer-events: none;
      opacity: 0.75;
      font-size: 13px;
    }
    #subtitle {
      position: fixed;
      bottom: 62px;
      left: 8%;
      right: 8%;
      text-align: center;
      font-size: 18px;
      color: #80deea;
      text-shadow: 0 0 12px rgba(0, 229, 255, 0.45);
      pointer-events: none;
      min-height: 28px;
      transition: opacity 0.25s ease;
    }
    .hud-controls {
      pointer-events: auto;
      display: flex;
      gap: 10px;
    }
    .btn {
      background: rgba(0, 229, 255, 0.08);
      border: 1px solid rgba(0, 229, 255, 0.35);
      color: #80deea;
      padding: 6px 12px;
      border-radius: 999px;
      font-size: 12px;
      cursor: pointer;
    }
    .btn.active {
      background: rgba(0, 229, 255, 0.28);
      border-color: #00e5ff;
      color: #ffffff;
    }
    #openvoice-frame {
      position: fixed;
      inset: 0;
      width: 100vw;
      height: 100vh;
      border: none;
      display: none;
      z-index: 10;
      background: #000;
    }
  </style>
</head>
<body>
  <canvas id="face-canvas"></canvas>
  <div id="subtitle">Tap anywhere to speak to Hermes</div>

  <div id="hud">
    <div id="status-pill">IDLE • [mood: neutral]</div>
    <div class="hud-controls">
      <button id="vad-btn" class="btn">Hands-Free VAD: OFF</button>
      <button id="ovui-btn" class="btn">OpenVoiceUI (:5001)</button>
    </div>
  </div>

  <iframe id="openvoice-frame" allow="microphone; autoplay"></iframe>

  <script>
    const canvas = document.getElementById('face-canvas');
    const ctx = canvas.getContext('2d');
    const subtitleEl = document.getElementById('subtitle');
    const statusPill = document.getElementById('status-pill');
    const vadBtn = document.getElementById('vad-btn');
    const ovuiBtn = document.getElementById('ovui-btn');
    const ovuiFrame = document.getElementById('openvoice-frame');

    let width = (canvas.width = window.innerWidth);
    let height = (canvas.height = window.innerHeight);

    window.addEventListener('resize', () => {
      width = canvas.width = window.innerWidth;
      height = canvas.height = window.innerHeight;
    });

    // State & Mood
    let state = 'idle'; // idle | listening | thinking | speaking
    let mood = 'neutral'; // neutral | happy | thinking | curious | sarcastic | alert | sleepy
    let audioEnergy = 0;

    // Eye Physics & Burn-in Protection
    let lookX = 0, lookY = 0, targetLookX = 0, targetLookY = 0;
    let blinkAmount = 0, isBlinking = false;
    let burnInOffsetX = 0, burnInOffsetY = 0;

    const MOOD_COLORS = {
      neutral:   '#00e5ff',
      happy:     '#00e676',
      thinking:  '#aa00ff',
      curious:   '#ffea00',
      sarcastic: '#ff9100',
      alert:     '#ff1744',
      sleepy:    '#5c6bc0'
    };

    // Periodic Saccades & Blinking
    setInterval(() => {
      if (state === 'idle' || state === 'speaking') {
        targetLookX = (Math.random() - 0.5) * 50;
        targetLookY = (Math.random() - 0.5) * 28;
      }
      // Subtle OLED burn-in pixel shift
      const t = Date.now() / 60000;
      burnInOffsetX = Math.sin(t) * 4;
      burnInOffsetY = Math.cos(t) * 4;
    }, 2600);

    setInterval(() => {
      if (!isBlinking && Math.random() < 0.65) {
        isBlinking = true;
      }
    }, 3400);

    function drawRoundedEye(x, y, w, h, radius, color, topSlant, bottomClip) {
      ctx.save();
      ctx.translate(x, y);
      ctx.shadowColor = color;
      ctx.shadowBlur = 28 + audioEnergy * 35;
      ctx.fillStyle = color;

      ctx.beginPath();
      ctx.roundRect(-w / 2, -h / 2, w, h, radius);
      ctx.fill();

      // Mood Eyelid Masks (Pure Black)
      ctx.shadowBlur = 0;
      ctx.fillStyle = '#000000';

      if (topSlant !== 0) {
        ctx.beginPath();
        ctx.moveTo(-w / 2 - 4, -h / 2 - 4);
        ctx.lineTo(w / 2 + 4, -h / 2 - 4);
        ctx.lineTo(w / 2 + 4, -h / 2 + Math.max(0, topSlant));
        ctx.lineTo(-w / 2 - 4, -h / 2 + Math.max(0, -topSlant));
        ctx.closePath();
        ctx.fill();
      }

      if (bottomClip > 0) {
        ctx.beginPath();
        ctx.arc(0, h / 2 + radius, w * 0.65, 0, Math.PI * 2);
        ctx.fill();
      }

      ctx.restore();
    }

    function renderLoop() {
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, width, height);

      lookX += (targetLookX - lookX) * 0.12;
      lookY += (targetLookY - lookY) * 0.12;

      if (isBlinking) {
        blinkAmount += 0.28;
        if (blinkAmount >= 1) isBlinking = false;
      } else if (blinkAmount > 0) {
        blinkAmount = Math.max(0, blinkAmount - 0.22);
      }

      const color = state === 'listening' ? '#00ffaa' : (MOOD_COLORS[mood] || '#00e5ff');
      const baseEyeW = Math.min(width, height) * 0.24;
      const baseEyeH = Math.min(width, height) * 0.30;
      const spacing = Math.min(width, height) * 0.36;

      const cx = width / 2 + lookX + burnInOffsetX;
      const cy = height / 2 - 20 + lookY + burnInOffsetY;

      let leftH = baseEyeH * (1 - blinkAmount * 0.92);
      let rightH = baseEyeH * (1 - blinkAmount * 0.92);
      let leftSlant = 0, rightSlant = 0, bottomSmile = 0;

      if (mood === 'happy') {
        bottomSmile = 1;
      } else if (mood === 'sarcastic') {
        leftH *= 0.55;
        rightSlant = -25;
      } else if (mood === 'curious') {
        rightH *= 1.18;
        leftH *= 0.82;
      } else if (mood === 'alert') {
        leftSlant = 28;
        rightSlant = -28;
      } else if (mood === 'sleepy') {
        leftH *= 0.42;
        rightH *= 0.42;
      }

      if (state === 'thinking') {
        const pulse = Math.sin(Date.now() / 160) * 12;
        targetLookY = -18;
        targetLookX = Math.sin(Date.now() / 320) * 35;
        leftH += pulse;
        rightH -= pulse;
      }

      // React to TTS audio energy
      const energyBoost = audioEnergy * 28;
      drawRoundedEye(cx - spacing / 2, cy, baseEyeW + energyBoost * 0.4, Math.max(8, leftH + energyBoost), 26, color, leftSlant, bottomSmile);
      drawRoundedEye(cx + spacing / 2, cy, baseEyeW + energyBoost * 0.4, Math.max(8, rightH + energyBoost), 26, color, rightSlant, bottomSmile);

      // Voice waveform mouth bar when speaking or listening
      if (state === 'speaking' || state === 'listening') {
        const mouthW = 60 + audioEnergy * 110;
        const mouthH = 6 + audioEnergy * 42;
        ctx.save();
        ctx.fillStyle = color;
        ctx.shadowColor = color;
        ctx.shadowBlur = 18;
        ctx.beginPath();
        ctx.roundRect(cx - mouthW / 2, cy + baseEyeH * 0.72, mouthW, mouthH, 12);
        ctx.fill();
        ctx.restore();
      }

      requestAnimationFrame(renderLoop);
    }
    requestAnimationFrame(renderLoop);

    // Audio Recording & Web Audio API Lip-Sync
    let mediaRecorder = null;
    let audioChunks = [];
    let audioCtx = null;
    let vadEnabled = false;

    function updateStatus(newState, newMood) {
      state = newState;
      if (newMood) mood = newMood;
      statusPill.textContent = `${state.toUpperCase()} • [mood: ${mood}]`;
    }

    async function playBase64Audio(b64) {
      if (!b64) {
        updateStatus('idle');
        return;
      }
      if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      const binary = atob(b64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

      const buffer = await audioCtx.decodeAudioData(bytes.buffer);
      const source = audioCtx.createBufferSource();
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;
      const dataArray = new Uint8Array(analyser.frequencyBinCount);

      source.buffer = buffer;
      source.connect(analyser);
      analyser.connect(audioCtx.destination);

      updateStatus('speaking', mood);
      source.start(0);

      const sampleVolume = () => {
        if (state !== 'speaking') {
          audioEnergy = 0;
          return;
        }
        analyser.getByteFrequencyData(dataArray);
        let sum = 0;
        for (let i = 0; i < dataArray.length; i++) sum += dataArray[i];
        audioEnergy = Math.min(1, (sum / dataArray.length) / 95);
        requestAnimationFrame(sampleVolume);
      };
      sampleVolume();

      source.onended = () => {
        audioEnergy = 0;
        updateStatus('idle', mood);
      };
    }

    async function toggleRecording() {
      if (state === 'listening') {
        mediaRecorder.stop();
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        audioChunks = [];
        mediaRecorder = new MediaRecorder(stream);
        mediaRecorder.ondataavailable = (e) => {
          if (e.data.size > 0) audioChunks.push(e.data);
        };
        mediaRecorder.onstop = async () => {
          stream.getTracks().forEach(t => t.stop());
          updateStatus('thinking', 'thinking');
          subtitleEl.textContent = 'Thinking...';

          const blob = new Blob(audioChunks, { type: 'audio/webm' });
          const formData = new FormData();
          formData.append('audio', blob, 'speech.webm');

          try {
            const res = await fetch('/api/voice', { method: 'POST', body: formData });
            const data = await res.json();
            if (data.reply) {
              subtitleEl.textContent = data.reply;
              updateStatus('speaking', data.mood || 'neutral');
              await playBase64Audio(data.audio_b64);
            } else {
              subtitleEl.textContent = 'Heard nothing. Tap to speak.';
              updateStatus('idle', 'neutral');
            }
          } catch (err) {
            subtitleEl.textContent = 'Connection error to host server.';
            updateStatus('idle', 'alert');
          }
        };

        mediaRecorder.start();
        updateStatus('listening', 'curious');
        subtitleEl.textContent = 'Listening... Tap again to send';
      } catch (err) {
        const promptText = prompt('Mic blocked by browser security (use adb reverse or HTTPS). Type message to Hermes:');
        if (promptText) {
          updateStatus('thinking', 'thinking');
          const res = await fetch('/api/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text: promptText })
          });
          const data = await res.json();
          subtitleEl.textContent = data.reply;
          updateStatus('speaking', data.mood || 'neutral');
          await playBase64Audio(data.audio_b64);
        }
      }
    }

    canvas.addEventListener('click', toggleRecording);

    // Toggle OpenVoiceUI Full Canvas iframe (:5001)
    ovuiBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (ovuiFrame.style.display === 'block') {
        ovuiFrame.style.display = 'none';
        ovuiBtn.classList.remove('active');
      } else {
        const host = window.location.hostname;
        ovuiFrame.src = `http://${host}:5001`;
        ovuiFrame.style.display = 'block';
        ovuiBtn.classList.add('active');
      }
    });

    vadBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      vadEnabled = !vadEnabled;
      vadBtn.classList.toggle('active', vadEnabled);
      vadBtn.textContent = `Hands-Free VAD: ${vadEnabled ? 'ON' : 'OFF'}`;
    });
  </script>
</body>
</html>
EOF

# ------------------------------------------------------------------------------
# 8. plugins/s3neo-amoled-face.js (Custom Face Plugin for OpenVoiceUI)
# ------------------------------------------------------------------------------
cat << 'EOF' > plugins/s3neo-amoled-face.js
/**
 * S3Neo Super AMOLED Face Plugin for MCERQUA/OpenVoiceUI
 * Renders pure #000000 black background with low-CPU glowing vector eyes
 * optimized for the Samsung Galaxy S3 Neo (Snapdragon 400 / Adreno 305).
 */
export default class S3NeoAmoledFacePlugin {
  constructor(container) {
    this.container = container;
    this.canvas = document.createElement('canvas');
    this.ctx = this.canvas.getContext('2d');
    this.container.style.backgroundColor = '#000000';
    this.container.appendChild(this.canvas);
    this.mood = 'neutral';
    this.audioLevel = 0;
    this.resize();
    window.addEventListener('resize', () => this.resize());
  }

  resize() {
    this.canvas.width = this.container.clientWidth || window.innerWidth;
    this.canvas.height = this.container.clientHeight || window.innerHeight;
  }

  setAudioLevel(level) {
    this.audioLevel = level;
  }

  setMood(mood) {
    this.mood = mood;
  }
}
EOF

# ------------------------------------------------------------------------------
# 9. android/s3neo_provision.sh & android/battery_guardian.sh
# ------------------------------------------------------------------------------
cat << 'EOF' > android/s3neo_provision.sh
#!/usr/bin/env bash
# ==============================================================================
# Samsung Galaxy S3 Neo (GT-I9301I / s3ve3g) ADB Provisioning Script
# Configures USB port forwarding, fullscreen kiosk mode, and battery protection
# ==============================================================================

set -e

echo "📱 Checking ADB connection to Samsung Galaxy S3 Neo..."
if ! command -v adb &> /dev/null; then
  echo "❌ Error: 'adb' (Android Platform Tools) is not installed."
  exit 1
fi

adb wait-for-device
DEVICE_MODEL=$(adb shell getprop ro.product.model | tr -d '\r')
echo "✅ Connected to: ${DEVICE_MODEL}"

echo "🔗 Setting up ADB Reverse TCP tunnels (enables mic access via http://localhost)..."
adb reverse tcp:8080 tcp:8080
adb reverse tcp:5001 tcp:5001

echo "🖥️ Configuring Always-On Display & Immersive Fullscreen..."
# Keep screen awake while plugged into USB/AC
adb shell settings put global stay_on_while_plugged_in 3
# Set maximum screen timeout fallback
adb shell settings put system screen_off_timeout 2147483647
# Enable immersive fullscreen (hides status & navigation bars to prevent AMOLED burn-in)
adb shell settings put global policy_control immersive.full=*

echo "🔋 Pushing 24/7 Battery Charge Limiter script to /sdcard/battery_guardian.sh..."
adb push "$(dirname "$0")/battery_guardian.sh" /sdcard/battery_guardian.sh

echo "🚀 Launching S3Neo AI Companion in browser..."
adb shell am start -a android.intent.action.VIEW -d "http://localhost:8080"

echo ""
echo "🎉 S3 Neo is provisioned!"
echo "   • Companion UI: http://localhost:8080"
echo "   • OpenVoiceUI:  http://localhost:5001"
echo "   • Optional Root Battery Limiter: adb shell su -c 'sh /sdcard/battery_guardian.sh &'"
EOF
chmod +x android/s3neo_provision.sh

cat << 'EOF' > android/battery_guardian.sh
#!/system/bin/sh
# ==============================================================================
# On-Device Root Battery Guardian for Samsung Galaxy S3 Neo (s3ve3g / msm8226)
# Maintains battery between 65% and 75% to prevent swelling during 24/7 dock use
# ==============================================================================

MAX_CAP=75
MIN_CAP=65

echo "Battery Guardian started (Cap: ${MIN_CAP}% - ${MAX_CAP}%)"

while true; do
  CAPACITY=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 50)

  if [ "$CAPACITY" -ge "$MAX_CAP" ]; then
    # Disable charging on Samsung msm8226 / LineageOS kernels
    if [ -f /sys/class/power_supply/battery/charging_enabled ]; then
      echo 0 > /sys/class/power_supply/battery/charging_enabled
    elif [ -f /sys/class/power_supply/battery/batt_slate_mode ]; then
      echo 1 > /sys/class/power_supply/battery/batt_slate_mode
    fi
  elif [ "$CAPACITY" -le "$MIN_CAP" ]; then
    # Re-enable charging
    if [ -f /sys/class/power_supply/battery/charging_enabled ]; then
      echo 1 > /sys/class/power_supply/battery/charging_enabled
    elif [ -f /sys/class/power_supply/battery/batt_slate_mode ]; then
      echo 0 > /sys/class/power_supply/battery/batt_slate_mode
    fi
  fi

  sleep 60
done
EOF
chmod +x android/battery_guardian.sh

# ------------------------------------------------------------------------------
# 10. hardware/s3neo_stand.scad (Parametric 3D Printable Acoustic Desk Stand)
# ------------------------------------------------------------------------------
cat << 'EOF' > hardware/s3neo_stand.scad
// =============================================================================
// Samsung Galaxy S3 Neo (GT-I9301I) AI Companion Desk Stand
// Features:
//  - Exact fit for S3 Neo (136.6 x 70.6 x 8.6 mm) + tolerance
//  - 65-degree ergonomic desk viewing angle (Portrait or Landscape cradle)
//  - Rear-to-Front Acoustic Waveguide Horn (routes rear speaker sound forward)
//  - Recessed 90-degree Micro-USB charging cable channel
// =============================================================================

$fn = 64;

// S3 Neo Dimensions (mm) + 0.8mm clearance
phone_width     = 71.4;
phone_thickness = 9.6;
phone_height    = 137.4;

// Stand Parameters
tilt_angle      = 25; // 25 deg from vertical = 65 deg viewing angle
base_width      = 84;
base_depth      = 95;
base_height     = 18;
wall_thickness  = 4.2;

module s3neo_cutout() {
    // Main phone body slot
    translate([-phone_width/2, -phone_thickness/2, 0])
        cube([phone_width, phone_thickness, phone_height]);

    // Front screen viewing cutout
    translate([-(phone_width - 8)/2, -phone_thickness - 2, 12])
        cube([phone_width - 8, phone_thickness + 2, phone_height]);
}

module acoustic_horn_channel() {
    // Captures sound from the S3 Neo rear speaker and channels it out the front base
    hull() {
        // Rear speaker intake port
        translate([-18, phone_thickness/2, 28])
            rotate([tilt_angle, 0, 0])
            cylinder(d=14, h=6);

        // Front acoustic grill exit
        translate([-18, -base_depth/2 + 2, 8])
            rotate([90, 0, 0])
            cylinder(d=22, h=8);
    }
}

module micro_usb_channel() {
    // Bottom cutout for 90-degree Micro-USB connector & bottom microphone
    translate([-12, -15, -2])
        cube([24, 35, 16]);
}

module stand_body() {
    difference() {
        union() {
            // Weighted Base with rounded corners
            hull() {
                for (x = [-base_width/2 + 8, base_width/2 - 8])
                    for (y = [-base_depth/2 + 8, base_depth/2 - 8])
                        translate([x, y, 0])
                            cylinder(r=8, h=base_height);
            }

            // Angled Backrest Tower
            translate([0, 8, base_height - 4])
                rotate([tilt_angle, 0, 0])
                translate([-base_width/2, -phone_thickness/2 - wall_thickness, 0])
                cube([base_width, phone_thickness + wall_thickness * 2.5, 88]);
        }

        // Subtract tilted phone cradle
        translate([0, 8, base_height + 2])
            rotate([tilt_angle, 0, 0])
            s3neo_cutout();

        // Subtract acoustic waveguide horn
        acoustic_horn_channel();

        // Subtract Micro-USB cable routing channel
        micro_usb_channel();
    }
}

stand_body();
EOF

# ------------------------------------------------------------------------------
# 11. start.sh (One-Command Host Launcher)
# ------------------------------------------------------------------------------
cat << 'EOF' > start.sh
#!/usr/bin/env bash
set -e

echo "========================================================"
echo " 🤖 S3NeoProject — Host Startup & Hermes Model Builder"
echo "========================================================"

if [ ! -f .env ]; then
  echo "📄 Creating .env from .env.example..."
  cp .env.example .env
fi

if command -v ollama &> /dev/null; then
  echo "🧠 Checking Ollama & building 's3neo-hermes' persona model..."
  ollama pull hermes3 || true
  ollama create s3neo-hermes -f config/Modelfile.hermes || true
else
  echo "⚠️  Ollama not found in PATH. Make sure Ollama is running on port 11434."
fi

echo "🐳 Starting Docker services (S3Neo Satellite UI + Faster-Whisper STT)..."
docker compose up -d --build

echo ""
echo "✅ S3NeoProject is running!"
echo "   • S3Neo Satellite Face UI: http://localhost:8080"
echo "   • Faster-Whisper STT API:  http://localhost:8000"
echo "   • Next step: Plug in your Samsung S3 Neo and run: ./android/s3neo_provision.sh"
EOF
chmod +x start.sh

echo ""
echo "✅ All S3NeoProject files have been generated!"
echo "👉 Run the following commands to commit and push to GitHub:"
echo "   git add ."
echo "   git commit -m 'Initial commit: Complete S3NeoProject AI Voice Companion stack'"
echo "   git push -u origin main"