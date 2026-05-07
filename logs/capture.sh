#!/bin/bash
# HubCore Chat log capture — reads adb logcat from all connected devices simultaneously.
# Output: logs/<device_id>_<timestamp>.log
# Usage: ./logs/capture.sh
# Stop:  Ctrl+C

LOGS_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
FILTER='flutter|GoLog|YggdrasilService'
EXCLUDE='barhopper|TensorFlow|XNNPACK|EdgeLight|StackLog|BubblesManager|InterruptionState|ApplicationPolicy|oned_decoder'

echo "=== HubCore Chat Log Capture === $TIMESTAMP"

DEVICES=$(adb devices | awk '/\tdevice$/{print $1}')

if [ -z "$DEVICES" ]; then
  echo "ERROR: No devices connected"
  exit 1
fi

PIDS=()

for DEVICE in $DEVICES; do
  LOGFILE="$LOGS_DIR/${DEVICE}_${TIMESTAMP}.log"
  echo "Device: $DEVICE → $LOGFILE"
  adb -s "$DEVICE" logcat -c 2>/dev/null
  adb -s "$DEVICE" logcat -v time 2>/dev/null | grep --line-buffered -E "$FILTER" | grep --line-buffered -vE "$EXCLUDE" > "$LOGFILE" &
  PIDS+=($!)
done

echo "Capturing... Ctrl+C to stop."

trap "kill ${PIDS[*]} 2>/dev/null; echo 'Stopped.'; exit 0" INT TERM
wait
