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
