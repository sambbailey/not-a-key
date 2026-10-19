# Plan 1 follow-ups (from task + final reviews)

## Check at the car (Task 11 / Task 12 step 5)
- Car advertises service 0211 + local name while the phone is locked in a pocket? If "Car not in range" next to the car: fall back to a nil-service scan / `peripheral.name` match.
- Pairing time; Secure Enclave key works (incl. phone locked after first unlock).
- Toggle latency ×4, with the official Tesla app's phone key active (BLE connection limit is 3).
- Asleep car (15+ min): does moveTrunk work, or add `.wake` first when `snapshot.isAsleep`?
- What MOVE does to a liftgate already moving — stop? If so, "Moving boot" copy should become "Stopping boot".
- Do replies arrive encrypted (firmware 2024.38+)? If yes, Plan 2 can reject unauthenticated replies once a session exists.
- Haptic on intent result: none / system / UINotificationFeedbackGenerator.
- Logs: Console.app, subsystem `com.dodimead.sentry` (enable "Include Debug Messages"). Debug screen shows raw error under the friendly copy.

## Plan 2 backlog
- Distinguish copy: "Sent – no confirmation" vs "Car refused (reason)" vs "Car didn't respond"; map nominal errors (boot blocked etc.) per spec.
- Keychain errors before first unlock → "Unlock your iPhone once, then try again" (not "Set up Sentry first"); same on home screen (no destructive re-pair prompt for transient errors).
- Require authenticated replies after a session exists (if car encrypts); log-and-continue on stale fault whose session-info tag fails (Go parity).
- FakeVehicle: encrypted replies (incl. multi-reply VCSEC), assert flags==2/expiresAt; replayed-counter test.
- Cache peripheral identifier → `retrievePeripherals` for faster Action Button connects; handle non-connectable beacon (max connections) distinctly; `.resetting` wait-out.
- Pairing: Cancel button, structured task.
- Hardening: `SessionKey.keyBytes` internal; epoch length == 16 check; resync throws on different public key; wrap CryptoKit errors in DomainSession.init; Framing precondition ≤1024; Metadata tag range guard.
- Tests: corrupt-key paths (KeyStore, pairing, intent), Framing boundaries, malformed peer key, UserDefaults suite cleanup.
- Style: single SWIFT_VERSION in project.yml; ClosureState top-level.
