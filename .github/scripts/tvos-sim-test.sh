#!/bin/bash
# Apple TV simulator test of "use your iPhone as a controller": installs the
# personal Apple TV app and launches it with --no-game (the simulator's Metal
# allows 31 buffers and RT64 needs 52, so the game itself cannot draw
# there), then a scripted "iPhone" finds it over Bonjour, joins and presses
# Start, and the TV app's own log must show it seated the phone as the same
# player the phone was told (1, or 2 if the simulator reports a gamepad) and
# received the presses. No screenshots leave the runner.
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
xcrun simctl launch --console-pty "$dev" "$bundle" --no-game > "$out/console.log" 2>&1 &
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

echo "== Waiting for the app to start"
sleep 15
grep -m1 "remote: listening" "$out/console.log" || failures+=("the TV app never started listening for iPhones")
shot boot-1

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

echo "== Screen (numbers only)"
python3 "$out/png_stats.py" "$out"/*.png || true

echo "== What the TV app logged"
grep "remote:" "$out/console.log" | sed 's/^.*\[GoldenPad\] //' | head -30 || true
player=$(sed -n 's/^ok: joined as Player \([1-4]\)$//p' "$out/phone.log" | head -n 1)
if [ -z "$player" ]; then
  failures+=("the scripted iPhone was never given a player")
else
  echo "phone says it is Player $player"
  grep -q "remote: iPhone joined as Player $player" "$out/console.log" || failures+=("the TV app never seated the phone as Player $player")
  grep -q "remote: player $player buttons 0x1000" "$out/console.log" || failures+=("the TV app never received the phone's Start press")
  grep -q "remote: player $player buttons 0x0000" "$out/console.log" || failures+=("the TV app never saw Start released")
  grep -q "Player $player's iPhone left" "$out/console.log" || failures+=("the TV app did not notice the phone leaving")
fi
echo "--- console (last 25 lines) ---"
tail -n 25 "$out/console.log" || true

kill "$launcher" 2>/dev/null || true
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
rm -f "$out"/*.png

if [ "${#failures[@]}" -gt 0 ]; then
  for f in "${failures[@]}"; do echo "::error::$f"; done
  exit 1
fi
echo "PASS: the Apple TV app advertised itself, seated a scripted iPhone as Player $player, received its Start presses and saw it leave"
