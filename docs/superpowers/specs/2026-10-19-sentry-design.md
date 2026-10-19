# Sentry — Design

**Date:** 2026-10-19
**Status:** Draft for approval
**Working name:** Sentry (not final; rename before any App Store release; "Sentry" collides with sentry.io and a Tesla feature name)

## Intent

A personal iPhone app that turns the phone into a Bluetooth key for the owner's Tesla. The seed use case: **one press of the iPhone Action Button toggles the boot** — opens it if closed, closes it if open — exactly like holding the boot button on an old car key fob.

It's meant to grow. The owner wants to keep adding features over time, so the app is built as a general car-key/controls app with the boot as its first control, not as a one-trick boot button.

## The car

- 2026 Tesla Model Y Long Range AWD ("Juniper" refresh)
- Has a power liftgate, so the boot can close itself
- One car only in v1

## Goals (v1)

1. **Pair the phone as a Bluetooth key** with the car, once, approved by tapping the Tesla key card on the console.
2. **Action Button shortcut "Toggle Boot"**: press → boot opens if closed, closes if open. Feedback is a haptic **and** a banner ("Opening boot…" → "Boot open ✓").
3. **Other controls over Bluetooth**: lock, unlock, open frunk, climate on, climate off. Each is also exposed as a Shortcut so any of them can be put on the Action Button instead.
4. **Home screen** in a clean Tesla-like style (layout "C · Minimal + drawer", below) showing live car state.
5. **Works with no internet**: phone talks directly to the car over Bluetooth Low Energy (BLE). No Tesla account login, no server.

## Non-goals (v1)

- **Internet / remote control** (Tesla Fleet API). Explicitly deferred; owner doesn't have time for the developer-account, hosted-key, and billing setup now. Architecture should leave room for it (see "Transport").
- Multiple cars
- App Store release (personal device / TestFlight only)
- Apple Watch, widgets, Live Activities, CarPlay
- Charging controls, location, Sentry-mode controls, media, etc. (future additions)
- Frunk **close**: Tesla has no frunk-close command; the frunk is shut by hand.

## Anti-goals (would be failure even if it "works")

- **Slow or flaky Action Button.** If pressing it near the car doesn't reliably move the boot in a couple of seconds, the app has failed its main job.
- **Wrong state shown.** Showing "boot closed" when it's open (or toggling the wrong way) breaks trust. State on screen must come from the car, with clear "last updated" or "not connected" when stale.
- **Cluttered UI.** The owner explicitly asked for a much cleaner look than first mockups. Restraint over features-on-screen.
- **Weak key security.** The phone becomes a real car key. The private key must never leave the device.

## How it works

### Bluetooth protocol

Tesla publishes its vehicle command protocol as open source: https://github.com/teslamotors/vehicle-command (Go). That repo is the reference implementation. Verified (from `cmd/tesla-control/commands.go`) that all of these work over BLE without Fleet API:

| Need | Tesla command |
|------|---------------|
| Read state | `state` with categories incl. `charge`, `climate`, `closures`; `body-controller-state` (limited state, works without auth) |
| Toggle boot | `trunk-move` (toggles open/closed; close is supported on power liftgates) |
| Lock / unlock | `lock`, `unlock` |
| Frunk | `frunk-open` (no close exists) |
| Climate | `climate-on`, `climate-off` |
| Wake car | `wake` |
| Pair | `add-key-request` (car asks for NFC key-card tap to approve the new public key) |

**There is no Swift implementation.** The core of this project is a Swift port of the parts of the protocol above:
- Protobuf message definitions from the Go repo, compiled with `swift-protobuf`
- Session handshake, message authentication and encryption (ECDH P-256 + AES-GCM per Tesla's protocol docs in the repo) using **CryptoKit**
- BLE transport using **CoreBluetooth**: discovery (car advertises a local name derived from the VIN), connect, chunked read/write on Tesla's GATT characteristics

The owner will supply the VIN once during setup (needed for discovery and for message addressing).

### Transport (room for internet later)

Commands go through a transport abstraction. v1 has one implementation, BLE. A future Fleet API transport can be added without touching UI or intents ("try Bluetooth, fall back to internet" was the owner's original wish).

### Key storage

- Private key generated on device, stored in the **Secure Enclave** (CryptoKit `SecureEnclave.P256.KeyAgreement`), never exported.
- If Secure Enclave can't satisfy the protocol's needs, fall back to a Keychain-stored key marked this-device-only, and note it.
- **Usable while the phone is locked** (owner's decision). Access control: available after first unlock, this device only, no biometric requirement on the key itself. This is fixed at key creation; changing it means re-pairing with the key card.
- **All commands run on a locked phone, including Unlock** (owner's decision). Accepted trade-off: someone holding the owner's locked phone near the car could unlock it.
- Builder's call: add a settings toggle "Require Face ID to unlock" (default **off**), enforced in software via LocalAuthentication inside the Unlock intent. This lets the owner tighten security later without re-pairing.

### Pairing flow

1. Owner enters VIN (or pastes it).
2. App finds the car over BLE and sends the add-key request.
3. App tells owner: "Tap your key card on the centre console." Car screen shows the approval prompt.
4. App confirms the car accepted the key (session handshake succeeds) and lands on home.

Handle clearly: car not found, card not tapped in time, request rejected.

### Action Button / Shortcuts

App Intents, all run **without opening the app**:

- **Toggle Boot** (the headline one)
- Lock, Unlock, Open Frunk, Climate On, Climate Off

Each intent: connect over BLE → wake if needed → send command → read back state where useful → return a result.

Feedback:
- Success: haptic + banner, e.g. "Boot opening" / "Boot closing" / "Locked ✓"
- Failure: a distinct haptic + banner with the reason: "Car not in range", "Key not paired", "Boot blocked", "Car didn't respond"
- No silent retry loops. One sensible retry on a dropped connection is fine; then report.

The owner assigns "Toggle Boot" via Settings → Action Button → Shortcut.

### Home screen (layout C · Minimal + drawer)

Chosen from mockups. Dark, near-empty, Tesla-app feel:

- Top: model name in small spaced caps ("MODEL Y"), battery % large and thin, a status line ("Parked · Locked")
- Middle: a car image, side profile
- Bottom: a pull-up drawer holding the controls as icon + label: **Boot, Lock, Frunk, Climate** (more slot in later). Each shows its state and toggles on tap.
- Connection state visible but quiet ("Nearby" / "Not in range").
- **Refresh model** (owner's decision): opening the app (or returning it to foreground) connects, **wakes the car once**, reads fresh state (charge, climate, closures, lock), then lets the car sleep. No constant live connection. State is cached and shown with its age when stale or out of range. After any command, re-read the affected state.

### Coexistence with the official Tesla app

The official Tesla app **stays installed as the owner's primary phone key** (owner's decision). It keeps doing walk-up unlock / walk-away lock. Sentry does **explicit commands only**: no background presence detection, no auto-lock/unlock. Both apps will hold BLE links to the car; the builder must test Sentry's connect-and-command latency with the Tesla app active, early, on real hardware.

Mockup reference: `.superpowers/brainstorm/*/content/home-screen-v2.html`, option C. The mockup was a direction, not a pixel spec; the bar is "much cleaner," not "match the mockup."

### Platform

- SwiftUI, iOS app, single target plus whatever App Intents need
- Minimum iOS: 18 (builder's call; Action Button exists on iPhone 15 Pro and later)
- Dependencies: `swift-protobuf`; everything else Apple frameworks (CoreBluetooth, CryptoKit, AppIntents)
- Repo: `~/Development/sentry`, trunk branch `master`
- Distributed to the owner's own phone via Xcode / TestFlight using their Apple Developer account

## Success looks like

Owner walks to the car, presses the Action Button without unlocking the phone screen or opening the app, and the boot opens. Presses again, it closes. Banner and buzz confirm each time. Opening the app shows correct battery, lock, and boot state, with lock/frunk/climate a tap away.

## Risks / unknowns for the builder

1. **Protocol port is the bulk of the work and the main risk.** Port incrementally, with unit tests driven by test vectors/fixtures from the Go repo before touching real hardware. A quick spike against the real car (pair + `body-controller-state`) early is worth it to de-risk.
2. **App Intents + BLE timing.** Intent must connect, wake and command within the system's intent time budget. Measure early.
3. **Haptics from a background intent** may be limited by iOS. The banner (intent result dialog) is the guaranteed feedback; verify what haptic is possible and use the best available.
4. **Secure Enclave compatibility** with Tesla's key agreement: verify early.
5. **Coexisting BLE connection** with the official Tesla app (see above).
6. **Key role when pairing** (owner vs driver role): pick what the reference tool does by default and is sufficient for all v1 commands.

## Left to the builder

- Code architecture, module boundaries, test strategy details
- Exact copy for banners and errors (keep it short, plain)
- Icons, car artwork (SF Symbols fine; car image can be a clean vector/render)
- Exact retry/timeout values

## Later list (owner wants to keep growing it)

- Internet fallback via Tesla Fleet API (needs developer account, a domain to host the public key, small per-use fees)
- Charging controls (charge port, start/stop, limit)
- Widgets / Lock Screen controls / Control Centre controls
- Apple Watch
- Final name and App Store release
