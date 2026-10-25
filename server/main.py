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
