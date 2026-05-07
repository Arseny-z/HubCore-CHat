#!/usr/bin/env bash
# YGG-BUILD-2: Rebuild yggbind.aar when yggbind/ sources change.
# Usage: ./rebuild.sh              — always rebuild
#        ./rebuild.sh --check      — rebuild only if sources changed since last AAR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AAR_OUT="$SCRIPT_DIR/../client/android/libs/yggbind.aar"
UNITY_JDK="/home/ars/Unity/Hub/Editor/6000.3.8f1/Editor/Data/PlaybackEngines/AndroidPlayer/OpenJDK/bin"
NDK="/media/ars/Storage-1t/android-sdk/ndk/28.2.13676358"

if [[ "${1:-}" == "--check" ]]; then
  # Only rebuild if any .go file or go.mod/go.sum is newer than the AAR.
  if [[ ! -f "$AAR_OUT" ]]; then
    echo "[yggbind] AAR not found — building."
  else
    LATEST=$(find "$SCRIPT_DIR" -maxdepth 1 \( -name "*.go" -o -name "go.mod" -o -name "go.sum" \) \
             -newer "$AAR_OUT" | head -1)
    if [[ -z "$LATEST" ]]; then
      echo "[yggbind] Up to date."
      exit 0
    fi
    echo "[yggbind] Changed: $LATEST — rebuilding."
  fi
fi

echo "[yggbind] Building AAR…"
cd "$SCRIPT_DIR"
PATH="$UNITY_JDK:$PATH" ANDROID_NDK_HOME="$NDK" \
  gomobile bind -target=android/arm64 -androidapi 21 -o "$AAR_OUT"

echo "[yggbind] Done → $AAR_OUT"
