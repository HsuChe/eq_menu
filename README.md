# EQMenuBar

A menu-bar system-wide 10-band equalizer for macOS 14.2+. It captures all system audio with a Core Audio process tap, runs it through peaking filters at 31 Hz to 16 kHz, and plays the result on the current output device (AirPods, speakers, anything).

No BlackHole or driver install is needed.

## Run

```sh
./build-app.sh
open EQMenuBar.app
```

The first time you switch the EQ on, macOS asks for **System Audio Recording** permission. Grant it in System Settings → Privacy & Security, then toggle the EQ on again.

## How it works

- `SystemAudioEQ.swift`: creates a global tap (`CATapDescription`, muted at the source), wraps it in a private aggregate device with the default output as the sub-device, and runs an IO proc that EQs the samples in place.
- `Biquad.swift`: RBJ Audio EQ Cookbook peaking filter, Q = 1.41, one per band per channel.
- `EQMenuBarApp.swift`: `MenuBarExtra` UI with a draggable response curve and ten ±12 dB faders. Restarts the tap when the default output device changes.
- `LookaheadLimiter.swift`: the peak limiter described below.
- `build-app.sh`: builds the release binary and wraps it in an ad-hoc signed `EQMenuBar.app` with `Info.plist`. macOS only asks for System Audio Recording permission for a bundled, signed app.

## Limits

- Only interleaved or planar 32-bit float tap formats are processed. Anything else makes the EQ refuse to start.
- Up to 8 channels.
- Built with the Command Line Tools only. `@State` doesn't compile without the full Xcode toolchain, so the app holds its controller as a plain property.
- The app is ad-hoc signed, so every rebuild invalidates the System Audio Recording permission. Re-allow it (or remove and re-add EQMenuBar under Privacy & Security → System Audio Recording Only) after rebuilding. Launch with `open EQMenuBar.app`; running the binary directly makes macOS check Terminal's permission instead.

## Clipping protection

- **Auto headroom (off by default):** when checked, the whole signal is turned down by the peak of the combined EQ curve (overlapping boosts add up). Safest, but quieter.
- **Limiter (always on):** a stereo-linked lookahead limiter (`LookaheadLimiter.swift`). Audio is delayed 2 ms so the gain ramps down before a peak arrives and lands it exactly at the ceiling, then recovers over about 100 ms. Adds 2 ms of latency.
  - The ceiling is 4.0 (+12 dB over full scale), not 1.0. The tap delivers the mix before the output's volume is applied, and Bluetooth headphones such as AirPods Max take full-level audio and apply volume themselves, so normal music peaks at 2–3 here without clipping. A 1.0 ceiling limited ordinary music by up to 11 dB and made the volume pump.
- **Smoothing:** band gains and headroom glide to new values over about 40 ms, so dragging doesn't crackle.

## Known issues

- **Brief crackle at some song starts.** When an app starts playing, the tap can deliver a few empty blocks before the stream settles. It's much reduced with drift compensation on, but not gone. A virtual audio driver (BlackHole-style) would avoid the tap entirely.
- **Keep tap drift compensation on.** The tapped mix and the output device don't share a clock; with `kAudioSubTapDriftCompensationKey` off, the input broke into ~150 ms dropouts every 0.16 s.
- **Turn off Headphone Accommodations** (Accessibility → Audio) when using this. It boosts soft sounds inside the headphones and makes the level uneven on top of the EQ.

## Diagnostics

Launch with a log path to record one line per audio block:

```sh
open --env EQ_DEBUG="$PWD/eq-debug.log" EQMenuBar.app
```

Columns: host seconds, input clock step, output clock step, previous frames, frames, input peak, output peak, limiter gain. A clock step that isn't the previous block's frame count is a dropout; runs of zero input peaks during music are tap gaps. Leave it off for normal use: it formats strings on the audio thread.

## YouTube Music EQ (iPhone / iPad) — untested

`web/ytm-eq.js` is the same EQ (bands, Q, headroom math) running inside the YouTube Music page with Web Audio, with a status line that reports whether audio is actually flowing through it. `web/make-bookmarklet.sh` turns it into a bookmarklet and copies it to the clipboard. It's a feasibility test for an iOS app that wraps YouTube Music in a web view; it hasn't been run on an iPhone yet.
