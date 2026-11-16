# Ship my GoldenPad to TestFlight

GitHub's Mac build servers build GoldenPad from my own US GoldenEye 007 ROM, sign it with Apple's
cloud signing and upload it to TestFlight, the same way Glass Rail, Ai Sky and HaloPad ship. No Mac,
certificates or provisioning profiles are involved. This repo must stay **private**: the build
contains game code translated from the ROM, so the build is personal and must never be published.

| What | Value |
|---|---|
| App ID | `com.lasmith1689.goldenpad` |
| Team ID | `U3CTV4FLKM` |
| TestFlight group | `Me` (internal, automatic distribution) |

## What GitHub needs

Five repository secrets under **Settings** ▸ **Secrets and variables** ▸ **Actions**:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | `U3CTV4FLKM` |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key (Admin access), the same one Glass Rail uses |
| `ASC_ISSUER_ID` | Issuer ID shown above the key list |
| `ASC_KEY_P8` | The whole text of `AuthKey_XXXXXXXXXX.p8`, including the `BEGIN` and `END` lines |
| `ROM_KEY` | Passphrase for the encrypted ROM below |

The ROM is the release asset `rom.z64.enc` on the `rom-input` release: my ROM converted to `.z64`
(SHA-1 `abe01e4aeb033b6c0836819f549c791b26cfde83`) and encrypted with
`openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 -md sha256 -pass env:ROM_KEY`. The runner
decrypts it only for the build, and nothing derived from it is cached or kept as an artifact.

## Ship a build

On GitHub, open **Actions** ▸ **TestFlight** ▸ **Run workflow** (branch `main`). Nothing else uploads.
Without the App Store Connect secrets the run stops after building the archive, saying
"Nothing was uploaded".

The build takes much longer than Glass Rail (the ROM's code is translated and the RT64 renderer
compiled from source). Apple then processes the build, usually within 5 to 30 minutes, and
TestFlight on the iPhone offers it. Each build number is `<run number> × 10 + <attempt>`.

The build puts the ROM inside the app (`GoldenEye_retail.z64`), so on first launch GoldenPad
imports it by itself and opens straight into the game, with no ROM picker.

## Updating from upstream

`upstream` is `chrissotraidis/goldenpad`. Merge `upstream/main` into `main`, push, then run the workflow.

## If a build fails

| Message | Fix |
|---|---|
| "The App Store Connect app record for com.lasmith1689.goldenpad was not found" | The app record's bundle ID must match exactly. |
| "Check the API key…" | The key needs **Admin** access, and all three values must come from the same key. |
| "That build number was already used" | Click **Re-run all jobs**. |
| "bad decrypt" | `ROM_KEY` doesn't match the uploaded `rom.z64.enc`; re-encrypt and upload both again. |

## Controller

This build is tuned for a modern dual-stick controller (Xbox, PlayStation or MFi): left stick moves
and strafes, right stick looks, RT fires, LT aims (the right stick keeps turning the view at 0.6×
while aiming), A and LB use/open doors, X reloads, B crouches, Y and RB change weapon. GoldenEye's
own Rumble Pak effects play on the controller. Settings ▸ Controller has look speed, full-tilt turn
boost and rumble; Button mapping can reassign every face button, bumper and trigger.

## Apple TV

Run **TestFlight (Apple TV)** (`testflight-tvos.yml`). It uploads to the same App Store Connect app
(tvOS platform); Apple TV build numbers are run × 10 + attempt + 5. Install it from the TestFlight
app on the Apple TV. The Siri Remote's Back button opens and closes GoldenPad's menu.

## iPhones as controllers (up to four players)

Open GoldenPad on the Apple TV, then open it on each iPhone on the same Wi-Fi. The iPhone offers
**Be a controller for <Apple TV>**; tap it and the phone shows the usual touch controls, which now
drive the TV (the game does not run on the phone). The TV seats phones as Players 1–4; a game
controller paired with the TV keeps Player 1 and phones take 2–4. Each phone buzzes with that
player's Rumble Pak. **Leave** returns to the choice; **Play on this iPhone** plays on the phone.
The first launch asks for Local Network permission on both devices: allow it.

Tests: **Checks** (every push) runs the message-format and player-seating tests, a real phone-to-TV
Bonjour/TCP loopback, a Swift type-check for iPhone and Apple TV, and the Apple TV icon compile.
**Apple TV simulator test** runs the real Apple TV app (with `--no-game`, because the simulator's
Metal cannot run RT64) and joins it from a scripted iPhone. Neither uploads screenshots.
