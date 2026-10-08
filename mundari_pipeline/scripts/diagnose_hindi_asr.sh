#!/usr/bin/env bash
# ==============================================================================
# Hindi (hi-IN) Offline ASR Hardware & OS Readiness Diagnostic Script
# Targeted for low-end Android devices (2 GB RAM constraint)
# ==============================================================================

set -euo pipefail

# ANSI color codes
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Find ADB binary
find_adb() {
    if command -v adb &>/dev/null; then
        echo "adb"
        return
    fi
    local candidates=(
        "$HOME/Library/Android/sdk/platform-tools/adb"
        "$HOME/Android/Sdk/platform-tools/adb"
        "/opt/android-sdk/platform-tools/adb"
    )
    for c in "${candidates[@]}"; do
        if [[ -x "$c" ]]; then
            echo "$c"
            return
        fi
    done
    echo ""
}

ADB_BIN=$(find_adb)

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}   OFFLINE HINDI (hi-IN) ASR & ASSET PACK SYSTEM DIAGNOSTIC     ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

if [[ -z "$ADB_BIN" ]]; then
    echo -e "${RED}[ERROR] adb binary not found in PATH or standard Android SDK directories.${NC}"
    echo "Please set ANDROID_HOME or add platform-tools to your PATH."
    exit 1
fi

echo -e "${BLUE}[INFO] Using adb:${NC} $ADB_BIN"

# Check connected devices
DEVICES=($("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}'))

if [[ ${#DEVICES[@]} -eq 0 ]]; then
    echo -e "${RED}[ERROR] No authorized Android devices found.${NC}"
    echo "Please connect a device with USB debugging enabled, or start an emulator."
    exit 1
fi

DEVICE_ID="${1:-${DEVICES[0]}}"
echo -e "${GREEN}[OK] Target Device:${NC} $DEVICE_ID (Total attached: ${#DEVICES[@]})"
echo "----------------------------------------------------------------"

# 1. Device Hardware & RAM Analysis
echo -e "${BOLD}[1/5] Hardware & RAM Constraints Check${NC}"
MODEL=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.product.model | tr -d '\r')
MANUFACTURER=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.product.manufacturer | tr -d '\r')
CPU_ABI=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.product.cpu.abi | tr -d '\r')

MEMINFO=$("$ADB_BIN" -s "$DEVICE_ID" shell cat /proc/meminfo | tr -d '\r')
TOTAL_KB=$(echo "$MEMINFO" | awk '/MemTotal:/ {print $2}')
AVAIL_KB=$(echo "$MEMINFO" | awk '/MemAvailable:/ {print $2}')
FREE_KB=$(echo "$MEMINFO" | awk '/MemFree:/ {print $2}')

TOTAL_MB=$((TOTAL_KB / 1024))
AVAIL_MB=$((AVAIL_KB / 1024))
FREE_MB=$((FREE_KB / 1024))

echo "   Device: $MANUFACTURER $MODEL ($CPU_ABI)"
echo "   RAM Total:     ${TOTAL_MB} MB (~$(( (TOTAL_MB + 512) / 1024 )) GB)"
echo "   RAM Available: ${AVAIL_MB} MB"
echo "   RAM Free:      ${FREE_MB} MB"

if [[ $TOTAL_MB -le 2500 ]]; then
    echo -e "   ${YELLOW}[WARNING] Target device has <= 2.5 GB RAM!${NC}"
    echo "   Strict unbinding (speechRecognizer.destroy()) is REQUIRED to avoid OOM."
else
    echo -e "   ${GREEN}[OK] Sufficient device RAM detected.${NC}"
fi

echo "----------------------------------------------------------------"

# 2. Android OS API Level Check
echo -e "${BOLD}[2/5] Android OS & Recognition API Level Check${NC}"
OS_RELEASE=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.build.version.release | tr -d '\r')
SDK_INT=$("$ADB_BIN" -s "$DEVICE_ID" shell getprop ro.build.version.sdk | tr -d '\r')

echo "   Android OS Release: $OS_RELEASE"
echo "   SDK / API Level:    $SDK_INT"

if [[ "$SDK_INT" -lt 31 ]]; then
    echo -e "   ${RED}[FAIL] API level $SDK_INT < 31 (Android 12).${NC}"
    echo "   SpeechRecognizer.isOnDeviceRecognitionAvailable() is NOT supported by OS."
    echo "   Native diagnostic verdict: NOT_SUPPORTED"
elif [[ "$SDK_INT" -lt 33 ]]; then
    echo -e "   ${YELLOW}[PARTIAL] API level $SDK_INT is Android 12 (31/32).${NC}"
    echo "   SpeechRecognizer.isOnDeviceRecognitionAvailable is present,"
    echo "   but checkRecognitionSupport() requires API 33+ (Android 13+)."
    echo "   Detailed offline Hindi asset pack status cannot be verified via standard API."
else
    echo -e "   ${GREEN}[OK] API level $SDK_INT >= 33 (Android 13+).${NC}"
    echo "   Full support for SpeechRecognizer.checkRecognitionSupport() and RecognitionSupportCallback."
fi

echo "----------------------------------------------------------------"

# 3. Speech Recognition Service Provider Check
echo -e "${BOLD}[3/5] Speech Recognition Engine Provider${NC}"
RECOG_SERVICES=$("$ADB_BIN" -s "$DEVICE_ID" shell pm query-services -a android.speech.RecognitionService | tr -d '\r')

if echo "$RECOG_SERVICES" | grep -q "com.google.android.tts"; then
    echo -e "   ${GREEN}[FOUND] Speech Services by Google (com.google.android.tts)${NC}"
    TTS_VER=$("$ADB_BIN" -s "$DEVICE_ID" shell dumpsys package com.google.android.tts | grep -i "versionName" | head -n 1 | awk -F'=' '{print $2}' | tr -d '\r')
    echo "   Google TTS Version: $TTS_VER"
elif echo "$RECOG_SERVICES" | grep -q "com.google.android.googlequicksearchbox"; then
    echo -e "   ${GREEN}[FOUND] Google App Speech Recognizer (com.google.android.googlequicksearchbox)${NC}"
    GSA_VER=$("$ADB_BIN" -s "$DEVICE_ID" shell dumpsys package com.google.android.googlequicksearchbox | grep -i "versionName" | head -n 1 | awk -F'=' '{print $2}' | tr -d '\r')
    echo "   Google App Version: $GSA_VER"
else
    echo -e "   ${RED}[MISSING] No standard Google speech recognition service found.${NC}"
    echo "   Details:"
    echo "$RECOG_SERVICES"
fi

echo "----------------------------------------------------------------"

# 4. Localized Language Pack & Asset Status
echo -e "${BOLD}[4/5] Localized Offline Asset Pack Readiness Check${NC}"

# Check DownloadActivity existence
DOWNLOAD_ACT=$("$ADB_BIN" -s "$DEVICE_ID" shell dumpsys package com.google.android.tts | grep -i "languagepack.*DownloadActivity" || true)
if [[ -n "$DOWNLOAD_ACT" ]]; then
    echo -e "   ${GREEN}[OK] Speech Services Language Pack Manager component is available.${NC}"
else
    echo -e "   ${YELLOW}[INFO] Custom/legacy language pack component path.${NC}"
fi

echo "----------------------------------------------------------------"

# 5. Diagnostic Summary & Recommended Next Actions
echo -e "${BOLD}[5/5] Diagnostic Verdict & Action Plan${NC}"

if [[ "$SDK_INT" -ge 33 ]]; then
    echo -e "   Status Engine: ${GREEN}READY TO QUERY VIA FLUTTER METHODCHANNEL${NC}"
    echo "   When your Flutter app calls AsrChecker.instance.checkHindiSupport():"
    echo "   -> If Hindi model is downloaded: returns 'READY_OFFLINE'"
    echo "   -> If engine supports Hindi but model not downloaded: returns 'NEEDS_DOWNLOAD'"
    echo "   -> If engine lacks on-device support: returns 'NOT_SUPPORTED'"
else
    echo -e "   Status Engine: ${YELLOW}LIMITED BY OS API ($SDK_INT < 33)${NC}"
    echo "   The app safely falls back to 'NOT_SUPPORTED' to prevent crashes."
fi

echo ""
echo -e "${BOLD}Helpful Commands:${NC}"
echo "1. To open Voice Input / Offline Speech settings on the device:"
echo "   $ADB_BIN -s $DEVICE_ID shell am start -a android.settings.VOICE_INPUT_SETTINGS"
echo ""
echo "2. To test the Flutter AsrChecker integration:"
echo "   cd mundari_pipeline && flutter test test/asr_checker_test.dart"
echo -e "${BOLD}${CYAN}================================================================${NC}"
