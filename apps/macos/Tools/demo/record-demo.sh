#!/bin/bash
# record-demo.sh - record the README's demo GIF on this Mac.
#
#   ./record-demo.sh <out-dir>
#
# What it shows is the real pipeline: TypeLeast (installed at ~/Applications)
# records, the local service recognises, your cleanup model rewrites, and the
# text is pasted into a plain editor window. The "voice" is macOS's synthetic
# Mandarin voice fed in place of the microphone (TYPELEAST_DEMO_WAV), so nobody's
# real voice is involved and no microphone is opened.
#
# Needs: TypeLeast installed with Accessibility permission and a cleanup model
# configured; Screen Recording permission for the terminal running this script.
# Do not touch the mouse or keyboard while it records (about 20 s).
set -euo pipefail

OUT="${1:?usage: record-demo.sh <out-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
APP="$HOME/Applications/TypeLeast.app"
SENTENCE="嗯，那个，我们明天下午三点开会，呃，不对，是后天上午十点。然后呢，大家记得把上周的数据带上。"

# The editor as a small app bundle, so LaunchServices brings it to the front.
EDITOR_APP="$WORK/DemoEditor.app"
mkdir -p "$EDITOR_APP/Contents/MacOS"
/usr/bin/swiftc -O -swift-version 5 "$HERE/DemoEditor.swift" -o "$EDITOR_APP/Contents/MacOS/DemoEditor"
cat > "$EDITOR_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DemoEditor</string>
<key>CFBundleIdentifier</key><string>dev.typeleast.demo-editor</string>
<key>CFBundleName</key><string>DemoEditor</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
/usr/bin/swiftc -O -swift-version 5 "$HERE/MakeGif.swift" -o "$WORK/make-gif"

# The synthetic voice, as the canonical 16 kHz mono WAV the service accepts.
say -v Tingting -r 185 -o "$WORK/voice.wav" --data-format=LEI16@16000 "$SENTENCE"
/usr/bin/python3 - "$WORK/voice.wav" "$WORK/demo.wav" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
off, fmt, pcm = 12, None, None
while off + 8 <= len(data):
    cid, size = data[off:off+4], struct.unpack("<I", data[off+4:off+8])[0]
    if cid == b"fmt ": fmt = data[off+8:off+24]
    if cid == b"data": pcm = data[off+8:off+8+size]
    off += 8 + size + (size % 2)
open(sys.argv[2], "wb").write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<I", 16) + fmt + b"data" + struct.pack("<I", len(pcm)) + pcm)
PY

# Only one TypeLeast at a time: quit the running copy for the duration.
pkill -x TypeLeast 2>/dev/null || true
sleep 3

open -n "$EDITOR_APP" --args "$WORK/rect.txt" "会议通知" ""
for _ in $(seq 1 60); do [ -s "$WORK/rect.txt" ] && break; sleep 0.1; done
RECT="$(cat "$WORK/rect.txt" 2>/dev/null || echo "BLOCKED no answer")"
if [[ "$RECT" == BLOCKED* ]]; then
  pkill -f "DemoEditor.app/Contents/MacOS/DemoEditor" 2>/dev/null || true
  open "$APP"
  echo "not recording: the editor is not alone in front ($RECT)" >&2
  exit 3
fi
sleep 0.5

screencapture -x -v -V 22 -R "$RECT" "$WORK/demo.mov" &
CAPTURE_PID=$!
sleep 0.5
# Started by LaunchServices (so macOS applies TypeLeast's own Accessibility
# permission) and in the background (-g), so the editor keeps the focus.
# -ApplePersistenceIgnoreState: no window of a previous session is restored.
open -n -g --env TYPELEAST_DEMO_WAV="$WORK/demo.wav" --env TYPELEAST_DEMO_DELAY=2.5 "$APP" --args -ApplePersistenceIgnoreState YES
wait "$CAPTURE_PID"
pkill -x TypeLeast 2>/dev/null || true
pkill -f "DemoEditor.app/Contents/MacOS/DemoEditor" 2>/dev/null || true
sleep 3
open "$APP"

cp "$WORK/demo.mov" "$OUT/demo.mov"
# Check the recording before using it: frames are written next to it for review.
# Caption times are relative to "start"; they fit this script's timing (the voice
# starts about 3.7 s into the recording and the text lands about 16 s in).
cat > "$WORK/gif.json" <<JSON
{"width": 880, "fps": 10, "start": 0.5, "end": 22.0,
 "captions": [
  {"from": 0,    "to": 3.2,  "title": "在任何输入框里，按一下 fn", "detail": "TypeLeast 开始听你说话（演示用的是系统合成语音）"},
  {"from": 3.2,  "to": 14.7, "title": "随口说，说错了就改口", "detail": "「嗯，那个，我们明天下午三点开会，呃，不对，是后天上午十点。然后呢，大家记得把上周的数据带上。」"},
  {"from": 14.7, "to": 30,   "title": "本机识别，你的模型整理，直接写进光标处", "detail": "口头禅去掉了，改口也照办了"}
 ]}
JSON
"$WORK/make-gif" "$WORK/demo.mov" "$OUT/demo.gif" "$WORK/gif.json"
echo "record-demo.sh: done -> $OUT"
