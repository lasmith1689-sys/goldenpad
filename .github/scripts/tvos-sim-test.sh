#!/bin/bash
# Apple TV simulator launch test: installs the personal Apple TV app (my ROM
# inside, never uploaded), checks the game starts and draws changing
# frames, then plays it with a scripted "iPhone" over Bonjour and checks the
# TV seated it as a player. Prints numbers only: no screenshots leave the
# runner, since they would show the game.
#
# Usage: tvos-sim-test.sh GoldenPad.app
set -euo pipefail
app=$1
bundle=$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")
out="${RUNNER_TEMP:-/tmp}/tvos-sim"
rm -rf "$out"; mkdir -p "$out"
failures=()

dev=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
c = [x for k, v in d.items() if "tvOS" in k for x in v if "Apple TV 4K" in x["name"]]
print(c[-1]["udid"] if c else "")')
if [ -z "$dev" ]; then
  xcrun simctl list runtimes
  echo "::error::No Apple TV simulator is installed on this runner."; exit 1
fi
echo "Simulator $dev"
xcrun simctl boot "$dev" 2>/dev/null || true
xcrun simctl bootstatus "$dev" -b > /dev/null
xcrun simctl install "$dev" "$app"
xcrun simctl launch --console-pty "$dev" "$bundle" > "$out/console.log" 2>&1 &
launcher=$!

# A tiny PNG reader (no Pillow on the runner): fraction of non-black pixels
# and a fingerprint, so two screenshots can be compared.
cat > "$out/png_stats.py" <<'PY'
import hashlib, struct, sys, zlib
def pixels(path):
    data = open(path, 'rb').read()
    pos, idat, w, h, bpp = 8, b'', 0, 0, 0
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, color = struct.unpack('>IIBB', body[:10])
            bpp = {2: 3, 6: 4}[color]
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, bpp, rows
for path in sys.argv[1:]:
    w, h, bpp, rows = pixels(path)
    lit = total = 0
    for y in range(0, h, 4):
        r = rows[y]
        for x in range(0, w, 4):
            i = x * bpp
            total += 1
            if r[i] + r[i + 1] + r[i + 2] > 48: lit += 1
    print(f"{path.rsplit('/', 1)[-1]} {w}x{h} lit={lit / total:.3f} hash={hashlib.sha1(b''.join(rows)).hexdigest()[:12]}")
PY
shot() { xcrun simctl io "$dev" screenshot --type=png "$out/$1.png" > /dev/null 2>&1 || echo "(screenshot $1 failed)"; }

echo "== Waiting for the game to boot"
sleep 30
shot boot-1; sleep 4; shot boot-2

echo "== Scripted iPhone joins the Apple TV"
xcrun swiftc -O Sources/RemoteControllerProtocol.swift Sources/RemoteControllerTransport.swift \
  Tests/RemoteControllerPhoneScript.swift -parse-as-library -o "$out/phone"
if ! PHONE_SECONDS=20 "$out/phone" | tee "$out/phone.log"; then failures+=("scripted iPhone could not play"); fi
shot after-phone

echo "== App still running?"
if xcrun simctl spawn "$dev" launchctl list 2>/dev/null | grep -q "$bundle"; then
  echo "yes"
else
  echo "no"; failures+=("the app is not running after the test (crashed?)")
fi

echo "== Frames"
python3 "$out/png_stats.py" "$out"/*.png | tee "$out/frames.txt" || failures+=("could not read screenshots")
lit_max=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^lit=/) {sub("lit=","",$i); if ($i>m) m=$i}} END{print m+0}' "$out/frames.txt")
hashes=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^hash=/) print $i}' "$out/frames.txt" | sort -u | wc -l | tr -d ' ')
echo "brightest frame: $lit_max of pixels lit; distinct frames: $hashes"
awk -v m="$lit_max" 'BEGIN{exit !(m >= 0.05)}' || failures+=("the screen stayed black")
[ "$hashes" -ge 2 ] || failures+=("the picture never changed")

echo "== Game log"
container=$(xcrun simctl get_app_container "$dev" "$bundle" data 2>/dev/null || true)
log="$container/Library/Caches/GoldenPadRecomp/goldenpad-recomp-latest.log"
if [ -f "$log" ]; then
  wc -l < "$log"
  grep -iE "phone controllers|external controller|AOT runtime error|error|renderer|rt64|first frame|presented" "$log" | head -40 || true
  grep -q "phone controllers now hold ports mask 0x1" "$log" || failures+=("the game never registered the phone as Player 1")
else
  echo "(no game log at $log)"
  ls -R "$container/Library" 2>/dev/null | head -30 || true
  failures+=("no game log")
fi
echo "--- console (last 40 lines) ---"
tail -n 40 "$out/console.log" || true

kill "$launcher" 2>/dev/null || true
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
rm -f "$out"/*.png

if [ "${#failures[@]}" -gt 0 ]; then
  for f in "${failures[@]}"; do echo "::error::$f"; done
  exit 1
fi
echo "PASS: the Apple TV app boots, draws changing frames, and took a scripted iPhone as Player 1"
