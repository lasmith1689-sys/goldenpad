#!/bin/bash
# Apple TV simulator test of "use your iPhone as a controller": installs the
# personal Apple TV app and launches it with --no-game (the simulator's Metal
# allows 31 buffers and RT64 needs 52, so the game itself cannot draw
# there), then a scripted "iPhone" finds it over Bonjour, joins and presses
# Start, and the TV app's own log must show it seated the phone as the same
# player the phone was told (1, or 2 if the simulator reports a gamepad) and
# received the presses. Then a stand-in save (random bytes) is put where the
# game writes it, the app must keep a copy outside Caches, Caches is wiped as
# tvOS does when space runs low, and after a relaunch the save must be back
# byte for byte. Last, the app crashes on purpose (--crash-test): it must
# record the signal and a backtrace, and the next launch must show the crash
# report instead of starting the game. Throughout, the app's Application
# Support and Documents folders are read-only, as on a real Apple TV (only
# Caches and tmp are writable there; the simulator normally allows all), and
# finally the game itself is started once: the simulator cannot draw it (31
# Metal buffers), but RT64 must get past creating its data folder, which is
# what crashed on the Apple TV. No screenshots leave the runner.
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
# Apple TV hardware: Library/Application Support cannot be created and
# Documents is not writable.
data=$(xcrun simctl get_app_container "$dev" "$bundle" data)
rm -rf "$data/Library/Application Support"
mkdir -p "$data/Library/Application Support" "$data/Documents"
chmod 555 "$data/Library/Application Support" "$data/Documents"
if touch "$data/Documents/probe" 2>/dev/null; then echo "::warning::could not make Documents read-only"; fi
xcrun simctl launch --console-pty "$dev" "$bundle" --no-game --keep-console > "$out/console.log" 2>&1 &
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
player=$(sed -n 's/^ok: joined as Player \([1-4]\)$/\1/p' "$out/phone.log" | head -n 1)
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

echo "== Save survives tvOS clearing Caches"
data=$(xcrun simctl get_app_container "$dev" "$bundle" data)
saves="$data/Library/Caches/GoldenPadRecomp/saves"
mkdir -p "$saves"
head -c 512 /dev/urandom > "$out/save.bin"
cp "$out/save.bin" "$saves/ge007.us.bin"
sleep 8
grep -q "saves: kept ge007.us.bin" "$out/console.log" || failures+=("the TV app did not keep the save outside Caches")
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
kill "$launcher" 2>/dev/null || true
sleep 3
rm -rf "$data/Library/Caches/GoldenPadRecomp"
[ ! -e "$saves/ge007.us.bin" ] && echo "Caches cleared"
xcrun simctl launch --console-pty "$dev" "$bundle" --no-game --keep-console > "$out/console2.log" 2>&1 &
launcher=$!
sleep 12
if cmp -s "$out/save.bin" "$saves/ge007.us.bin"; then
  echo "save is back after relaunch, same 512 bytes"
else
  failures+=("the save was not restored after Caches was cleared")
fi
grep -q "saves: restored ge007.us.bin" "$out/console2.log" || failures+=("the relaunched app did not log restoring the save")
grep "saves:" "$out/console.log" "$out/console2.log" | sed 's/^.*\[GoldenPad\] //' || true

echo "== Crash is recorded and shown on the next launch"
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
kill "$launcher" 2>/dev/null || true
sleep 3
logs="$data/Library/Caches/GoldenPadRecomp/Logs"
xcrun simctl launch --console-pty "$dev" "$bundle" --no-game --crash-test > "$out/console3.log" 2>&1 &
launcher=$!
sleep 10
echo "--- crash-latest.txt (first 12 lines) ---"
head -n 12 "$logs/crash-latest.txt" 2>/dev/null || echo "(missing)"
grep -q "crash: SIGSEGV" "$logs/crash-latest.txt" 2>/dev/null || failures+=("the crash recorder did not write the signal")
grep -q "last stage: crash test" "$logs/crash-latest.txt" 2>/dev/null || failures+=("the crash recorder did not write the last stage")
grep -q "backtrace:" "$logs/crash-latest.txt" 2>/dev/null || failures+=("the crash recorder did not write a backtrace")
grep -q "goldenpad_crash_test" "$logs/crash-latest.txt" 2>/dev/null || echo "::warning::the backtrace has no symbol names (stripped build?)"
grep -q "crash capture ready" "$logs/stdio-latest.log" 2>/dev/null || failures+=("stdout/stderr were not sent to the app's log file")
grep -q "stage: app launched" "$logs/stdio-latest.log" 2>/dev/null || failures+=("start-up stages were not logged")
grep "crash capture ready" "$logs/stdio-latest.log" 2>/dev/null | sed 's/^.*\[GoldenPad\] //' || true
kill "$launcher" 2>/dev/null || true
xcrun simctl launch --console-pty "$dev" "$bundle" --no-game --keep-console > "$out/console4.log" 2>&1 &
launcher=$!
sleep 12
grep "crash report:" "$out/console4.log" | sed 's/^.*\[GoldenPad\] //' || true
grep -q "crash report: the previous launch crash: SIGSEGV" "$out/console4.log" || failures+=("the next launch did not pick up the crash")
grep -q "crash report: on screen" "$out/console4.log" || failures+=("the next launch did not show the crash report")

echo "== Game start with Apple TV folder rules"
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
kill "$launcher" 2>/dev/null || true
sleep 3
# (clear the crash-test leftovers so the game starts instead of the report)
rm -f "$logs"/crash-*.txt "$logs/tv-game-starting.marker"
xcrun simctl launch --console-pty "$dev" "$bundle" --ignore-tv-gamepads > "$out/console5.log" 2>&1 &
launcher=$!
sleep 30
echo "--- start-up stages (last 25) ---"
grep -h "stage:\|RT64\|crash" "$logs/stdio-latest.log" 2>/dev/null | sed 's/^.*\[GoldenPad\] //' | tail -n 25 || true
echo "--- crash-latest.txt ---"
head -n 8 "$logs/crash-latest.txt" 2>/dev/null || echo "(no crash recorded)"
if [ -d "$data/Library/Caches/GoldenPadRecompRT64" ]; then
  echo "RT64 data folder is in Caches"
else
  failures+=("RT64 did not create its data folder in Caches")
fi
if grep -qi "filesystem\|Application Support" "$logs/crash-latest.txt" 2>/dev/null; then
  failures+=("the game start still crashed on a folder it cannot create")
fi
grep -q "stage: game: starting the recompiled runtime" "$logs/stdio-latest.log" 2>/dev/null \
  || failures+=("the game never got as far as starting the runtime")

echo "== Gameplay driven by a scripted iPhone (Player 1)"
# The simulator build uses RT64's reduced resource set (no ray-tracing
# descriptors), so the game can draw here. The phone presses Start through
# the front end until the TV says it is in gameplay, then walks and turns.
if PHONE_SCRIPT=solo-walk PHONE_GAMEPLAY_TIMEOUT=180 "$out/phone" | tee "$out/phone-walk.log"; then
  echo "scripted phone reached gameplay"
else
  failures+=("the scripted phone could not play a level on the TV")
fi
diag="$logs/goldenpad-recomp-latest.log"
echo "--- TV runtime log: input (last 60) ---"
grep -h -e "input-context" -e "left stick" -e "controller 1 buttons" -e "phone controllers" "$diag" 2>/dev/null | tail -n 60 || echo "(no runtime log at $diag)"
echo "--- TV runtime log: player position (last 30) ---"
grep -h -o -e "pos=([^)]*)" -e "yaw=[-0-9.]*" "$diag" 2>/dev/null | paste - - | tail -n 30 || true
echo "--- crash-latest.txt ---"
head -n 8 "$logs/crash-latest.txt" 2>/dev/null || echo "(no crash recorded)"

kill "$launcher" 2>/dev/null || true
xcrun simctl terminate "$dev" "$bundle" 2>/dev/null || true
rm -f "$out"/*.png "$out/save.bin"

if [ "${#failures[@]}" -gt 0 ]; then
  for f in "${failures[@]}"; do echo "::error::$f"; done
  exit 1
fi
echo "PASS: the Apple TV app advertised itself, seated a scripted iPhone as Player $player, received its Start presses and saw it leave; a save survived Caches being cleared; a crash was recorded and shown on the next launch; RT64 started with Apple TV folder rules"
