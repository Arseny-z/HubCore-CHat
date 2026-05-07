#!/usr/bin/env bash
# RNS-BUILD: Rebuild rnsbind.aar when sources change.
# Usage: ./rebuild.sh              — always rebuild
#        ./rebuild.sh --check      — rebuild only if sources changed since last AAR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAR_OUT="$SCRIPT_DIR/../client/android/libs/rnsbind.aar"
UNITY_JDK="/home/ars/Unity/Hub/Editor/6000.3.8f1/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin"
NDK="/media/ars/Storage-1t/android-sdk/ndk/28.2.13676358"

if [[ "${1:-}" == "--check" ]]; then
  if [[ ! -f "$AAR_OUT" ]]; then
    echo "[rnsbind] AAR not found — building."
  else
    LATEST=$(find "$SCRIPT_DIR" -maxdepth 1 \( -name "*.go" -o -name "go.mod" -o -name "go.sum" \) \
             -newer "$AAR_OUT" | head -1)
    if [[ -z "$LATEST" ]]; then
      echo "[rnsbind] Up to date."
      exit 0
    fi
    echo "[rnsbind] Changed: $LATEST — rebuilding."
  fi
fi

echo "[rnsbind] Building AAR…"
cd "$SCRIPT_DIR"
PATH="$UNITY_JDK:$PATH" ANDROID_NDK_HOME="$NDK" \
  gomobile bind -target=android/arm64 -androidapi 21 -o "$AAR_OUT"

echo "[rnsbind] Done → $AAR_OUT"
