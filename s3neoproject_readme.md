# 🤖 S3NeoProject — AI Voice Companion & Desk Satellite

Turn an old **Samsung Galaxy S3 Neo (`GT-I9301I` / `s3ve3g`)** into a dedicated, hands-free AI desk companion with an animated, expressive face powered by [**OpenVoiceUI**](https://github.com/MCERQUA/OpenVoiceUI), local LLMs (**Hermes 3 / Ollama**), and a custom 3D-printed acoustic dock.

---

## ✨ Overview

Because the Samsung Galaxy S3 Neo runs a 32-bit ARM Cortex-A7 processor (`Snapdragon 400 MSM8226`) with $1.5\text{ GB}$ of RAM, running modern 64-bit LLMs directly on the device isn't feasible. Instead, **S3NeoProject** repurposes the phone's best hardware features—its vibrant **$4.8\text{"}$ Super AMOLED display ($1280 \times 720$)**, microphone, and speaker—into a dedicated physical AI satellite, while offloading heavy voice and LLM processing to a local PC or home server.

### Key Features

* **👁️ Animated Super AMOLED Face:** Uses OpenVoiceUI's expressive avatar system (plus a custom ultra-lightweight 60 FPS AMOLED face plugin built for older Android WebViews). True `#000000` black backgrounds turn off the Super AMOLED pixels completely, making the glowing eyes appear to float on your desk.
* **🎭 Emotion & Lip-Sync Engine:** Driven by **Hermes 3** mood tags (`[mood: happy]`, `[mood: thinking]`, `[mood: sarcastic]`, etc.) and real-time `Web Audio API` frequency analysis for zero-latency eye and mouth reactivity.
* **🗣️ Real-Time Voice Pipeline:** Supports both full **OpenVoiceUI** integration (port `5001`) and a lightweight **S3 Neo Satellite Bridge** (port `8080`) using `faster-whisper` (STT), `Ollama` (`hermes3`), and `Piper` / `Edge-TTS`.
* **🖨️ Parametric 3D-Printed Stand (`hardware/s3neo_stand.scad`):** Custom OpenSCAD desk dock tailored to the S3 Neo ($136.6 \times 70.6 \times 8.6\text{ mm}$) with an internal acoustic horn that routes rear-speaker sound toward the front and a channel for a $90^\circ$ Micro-USB cable.
* **🔋 24/7 Battery Protection (`android/s3neo_provision.sh`):** Automated ADB script that enables immersive fullscreen, sets up `adb reverse` port forwarding, and caps battery charging at $75\%$ on rooted LineageOS kernels to prevent battery swelling.

---

## 📁 Repository Structure

```text
S3NeoProject/
├── README.md                        # Project documentation
├── .env.example                     # Environment configuration template
├── .gitignore                       # Git ignore rules
├── docker-compose.yml               # Docker stack (Satellite Bridge + Faster-Whisper + Piper TTS)
├── start.sh                         # One-command host startup & Hermes model builder
├── config/
│   ├── Modelfile.hermes             # Custom Ollama Modelfile for S3Neo Hermes Agent
│   └── openvoiceui.env.example      # Config preset for MCERQUA/OpenVoiceUI
├── server/
│   ├── Dockerfile                   # Container build for the S3Neo Satellite Bridge
│   ├── requirements.txt             # Python dependencies (FastAPI, WebSockets, httpx, edge-tts)
│   └── app.py                       # Voice/LLM WebSocket bridge & emotion tag parser
├── client/
│   └── index.html                   # 60FPS Super AMOLED Face UI & Voice Kiosk Client
├── plugins/
│   └── s3neo-amoled-face.js         # Custom AMOLED Face Plugin for OpenVoiceUI
├── android/
│   ├── s3neo_provision.sh           # ADB setup script (Kiosk mode, port reverse, battery limit)
│   └── battery_guardian.sh          # On-device root daemon to cap battery between 65% and 75%
└── hardware/
    └── s3neo_stand.scad             # Parametric OpenSCAD 3D model for the S3 Neo acoustic dock
```

---

## 🏗️ System Architecture

```text
+-----------------------------------+          Wi-Fi / USB ADB Reverse           +---------------------------------------+
|     Samsung Galaxy S3 Neo         | <========================================> |         Host PC / Home Server         |
|  (Physical Desk Satellite Node)   |                                            |       (AI Compute & Docker Host)      |
+-----------------------------------+                                            +---------------------------------------+
| • Custom ROM (LineageOS 14.1+)    |   1. Streams raw mic audio (WebRTC/WS) ->  | • OpenVoiceUI (:5001) / Bridge (:8080)|
| • Fullscreen Kiosk Browser        |                                            | • STT: faster-whisper (:8000)         |
| • Super AMOLED Animated Face UI   |   <------------- 2. Mood & Canvas state    | • LLM: Ollama (s3neo-hermes :11434)   |
| • 3D-Printed Acoustic Stand       |   <------------- 3. TTS audio stream       | • TTS: Edge-TTS / Piper               |
+-----------------------------------+                                            +---------------------------------------+
```

---

## 🚀 Quick Start

### 1. Host PC Setup

1. **Install Prerequisites:**
   * [Docker & Docker Compose](https://docs.docker.com/get-docker/)
   * [Ollama](https://ollama.com/)
   * Node.js 18+ (if running `npx openvoiceui setup`)

2. **Build the Hermes Persona & Launch the Stack:**
   ```bash
   chmod +x start.sh
   ./start.sh
   ```
   This script will:
   * Pull `hermes3` in Ollama and build the custom `s3neo-hermes` model using `config/Modelfile.hermes`.
   * Generate your `.env` file from `.env.example`.
   * Start the Docker services (`s3neo-satellite` on port `8080` and `faster-whisper` on port `8000`).
   * Optionally clone and launch [**OpenVoiceUI**](https://github.com/MCERQUA/OpenVoiceUI) on port `5001`.

### 2. Samsung S3 Neo Provisioning (ADB)

Connect your Samsung S3 Neo via USB with **USB Debugging** enabled in Developer Options, then run:

```bash
chmod +x android/s3neo_provision.sh
./android/s3neo_provision.sh
```

**Why this script is important:**
Modern browsers block microphone access (`navigator.mediaDevices.getUserMedia`) on insecure LAN IPs (`http://192.168.x.x`). The provisioning script sets up `adb reverse tcp:8080 tcp:8080` and `adb reverse tcp:5001 tcp:5001`, allowing the phone to connect via `http://localhost:8080` or `http://localhost:5001` with full microphone permissions, zero Wi-Fi latency, and automatic USB power management.

---

## 🖨️ 3D Printing the Acoustic Stand

1. Open `hardware/s3neo_stand.scad` in [OpenSCAD](https://openscad.org/).
2. Press **F6** to render and export as `s3neo_stand.stl`.
3. **Recommended Slicer Settings:**
   * **Material:** PLA or PETG
   * **Layer Height:** $0.2\text{ mm}$
   * **Infill:** $15\%$ Gyroid (enhances acoustic resonance inside the speaker horn)
   * **Supports:** Tree supports touching buildplate only (for the USB channel overhang)

---

## 📄 License

MIT License — Free to modify, self-host, and hack on!