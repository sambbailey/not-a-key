# Festive Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Seasonal (1 Dec – 6 Jan) wintry palette for three neutral `Paper` colours, sparse snowfall on the home screen, and a Settings checkbox to turn it off.

**Architecture:** An `@Observable` `Festive` singleton owns the setting and the season check. `Paper.background`, `Paper.card` and `Paper.rule` become `@MainActor` computed statics that read `Festive.shared.isActive`, so SwiftUI's observation tracking re-renders every view using them when the setting flips — no per-screen edits. A `Snowfall` view (`TimelineView` + `Canvas`) sits in the home screen's background.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, iOS 18, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-17-festive-theme-design.md`

## Global Constraints

- XcodeGen-managed: never hand-edit `NotAKey.xcodeproj`; run `xcodegen generate` after adding files.
- Test command: `xcodebuild test -project NotAKey.xcodeproj -scheme NotAKey -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -collect-test-diagnostics never -quiet`
- Season window: 1 December – 6 January inclusive, local calendar, spans New Year.
- Setting: absent = follow season; explicit on lasts until the season it falls in/before ends (after 6 Jan); explicit off persists. Keys `notakey.festiveTheme`, `notakey.festiveThemeChosenAt`. (Revised 2026-11-17, see spec.)
- Festive palette (light / dark): `background` `F6F1E7` / `0F1A14`; `card` `ECE4D4` / `17241C`; `rule` `E3D9C6` / `1F2E25`.
- No other `Paper` token changes. Snow on the home screen only.

## Review Focus

1. App left open across midnight 30 Nov → 1 Dec (or 6 → 7 Jan): theme should switch on next return to foreground, not only after relaunch. → test in Task 1 (`refreshSeasonPicksUpNewDate`).
2. Toggling the setting while on Settings: background/rules there must change immediately. → covered by Observation design; manual check in Task 2.
3. Fresh install (no stored value): festive on. → test in Task 1 (`defaultsToEnabled`).
4. Reduce Motion on: no snow at all. → manual check in Task 3; `Snowfall` returns `EmptyView` path.
5. Snow intercepting taps on controls or pull-to-refresh. → `allowsHitTesting(false)`; manual check in Task 3.

---

### Task 1: `Festive` state + seasonal `Paper` colours

**Files:**
- Create: `NotAKey/Home/Festive.swift`
- Modify: `NotAKey/Home/Paper.swift` (lines 6, 8, 13 — `background`, `rule`, `card`)
- Test: `NotAKeyTests/FestiveTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class Festive`
    - `static let shared: Festive`
    - `static let settingKey = "notakey.festiveTheme"`
    - `init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init)`
    - `var isEnabled: Bool` (persists in `didSet`)
    - `private(set) var isInSeason: Bool`
    - `var isActive: Bool { isEnabled && isInSeason }`
    - `func refreshSeason()` — re-evaluates `isInSeason` from `now()`
    - `nonisolated static func isInSeason(_ date: Date, calendar: Calendar = .current) -> Bool`
  - `Paper.background`, `Paper.card`, `Paper.rule` become `@MainActor static var … : Color`.

- [ ] **Step 1: Write the failing tests** in `NotAKeyTests/FestiveTests.swift` (Swift Testing, `@MainActor struct FestiveTests`, fresh `UserDefaults(suiteName:)` per test like `HomeModelTests`). Dates built with a Gregorian calendar in `TimeZone.current`.

```swift
@Test(arguments: [(12, 1), (12, 25), (12, 31), (1, 1), (1, 6)])
func inSeason(month: Int, day: Int) { #expect(Festive.isInSeason(date(2026, month, day))) }

@Test(arguments: [(11, 30), (1, 7), (6, 15)])
func outOfSeason(month: Int, day: Int) { #expect(!Festive.isInSeason(date(2026, month, day))) }

@Test func defaultsToEnabled() { #expect(Festive(defaults: defaults).isEnabled) }

@Test func disablingPersists() {
    Festive(defaults: defaults).isEnabled = false
    #expect(!Festive(defaults: defaults).isEnabled)
}

@Test func activeNeedsSeasonAndSetting() {
    let festive = Festive(defaults: defaults, now: { date(2026, 12, 10) })
    #expect(festive.isActive)
    festive.isEnabled = false
    #expect(!festive.isActive)
    #expect(!Festive(defaults: defaults, now: { date(2026, 7, 1) }).isActive)
}

@Test func refreshSeasonPicksUpNewDate() {
    var today = date(2026, 11, 30)
    let festive = Festive(defaults: defaults, now: { today })
    #expect(!festive.isInSeason)
    today = date(2026, 12, 1)
    festive.refreshSeason()
    #expect(festive.isInSeason)
}
```

- [ ] **Step 2: Run** `xcodegen generate` then the test command. Expected: build FAIL, "cannot find 'Festive' in scope".

- [ ] **Step 3: Implement `Festive`** in `NotAKey/Home/Festive.swift` per Interfaces. `isEnabled` reads `defaults.object(forKey:) as? Bool ?? true`. Mark `defaults` and `now` `@ObservationIgnored`. Doc comment: "The Christmas look: on from 1 December to Twelfth Night unless turned off in Settings."

- [ ] **Step 4: Make the three `Paper` tokens seasonal.** Replace the `static let` for `background`, `card`, `rule` with `@MainActor static var` returning the festive `Color(light:dark:)` when `Festive.shared.isActive`, else the existing values. Keep the festive and plain colours as `private static let` constants so no `UIColor` is rebuilt per access. If any non-MainActor caller fails to compile, report it rather than removing `@MainActor`.

- [ ] **Step 5: Refresh season on foreground.** In `HomeView`'s existing `.onChange(of: scenePhase)`, call `Festive.shared.refreshSeason()` in the `.active` case (before the `where wasInBackground` case, so it runs on every activation — split into its own `if phase == .active` above the `switch`).

- [ ] **Step 6: Run the test command.** Expected: all tests PASS, including the existing suites.

- [ ] **Step 7: Commit**

```bash
git add NotAKey/Home/Festive.swift NotAKey/Home/Paper.swift NotAKey/Home/HomeView.swift NotAKeyTests/FestiveTests.swift NotAKey.xcodeproj
git commit -m "feat: seasonal festive palette for paper background, cards and rules"
```

---

### Task 2: "Appearance" section in Settings

**Files:**
- Modify: `NotAKey/Home/SettingsView.swift` (insert after the "Security" section, ~line 29)

**Interfaces:**
- Consumes: `Festive.shared.isEnabled`, `Festive.shared.isInSeason`.

- [ ] **Step 1: Add the section**, always shown (revised — see spec):
  - `settingsSection("Appearance")` containing a `Toggle` bound to `Festive.shared.isEnabled` (use `@Bindable var festive = Festive.shared` inside `body`, or a `Binding(get:set:)` — implementer's choice), styled exactly like the Face ID row: title `"Festive theme"` (`.geist(16, .medium)`), subtitle `"On by itself from 1 December to Twelfth Night"` (`.geist(13)`, `Paper.secondary`), `CheckboxToggleStyle()`, `minHeight: 72`, bottom `Paper.rule` overlay.

- [ ] **Step 2: Build and run the test command.** Expected: PASS.

- [ ] **Step 3: Manual check** on simulator with the date in season (set simulator/Mac date to 10 Dec, or temporarily force `isInSeason`; revert any forcing before commit): open Settings, untick "Festive theme" — Settings background and dividers return to plain immediately; re-tick — cream/pine returns. Both light and dark mode.

- [ ] **Step 4: Commit**

```bash
git add NotAKey/Home/SettingsView.swift
git commit -m "feat: festive theme checkbox in settings"
```

---

### Task 3: Home-screen snowfall

**Files:**
- Create: `NotAKey/Home/Snowfall.swift`
- Modify: `NotAKey/Home/HomeView.swift:90` (`.background(Paper.background)`)
- Test: `NotAKeyTests/FestiveTests.swift` (add `SnowfallTests` struct)

**Interfaces:**
- Consumes: `Festive.shared.isActive`.
- Produces:
  - `struct Snowfall: View` — no parameters.
  - `struct Snowfall.Flake { let x: Double; let size: Double; let period: Double; let phase: Double; let drift: Double }` — `x`, `phase` in 0…1; `size` 2…4 pt; `period` 8…14 s; `drift` ≤ 12 pt.
  - `static let flakes: [Flake]` — 30 flakes from a fixed-seed generator so layout is stable between launches.
  - `static func position(of flake: Flake, at time: TimeInterval, in size: CGSize) -> CGPoint`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func thirtyFlakesWithinSpec() {
    #expect(Snowfall.flakes.count == 30)
    for f in Snowfall.flakes {
        #expect((2...4).contains(f.size)); #expect((8...14).contains(f.period))
        #expect((0...1).contains(f.x)); #expect((0...1).contains(f.phase))
    }
}

@Test func flakeStaysOnScreenAndWraps() {
    let size = CGSize(width: 400, height: 800)
    let f = Snowfall.Flake(x: 0.5, size: 3, period: 10, phase: 0, drift: 10)
    for t in stride(from: 0.0, through: 30, by: 0.5) {
        let p = Snowfall.position(of: f, at: t, in: size)
        #expect((-f.size...size.height + f.size).contains(p.y))
        #expect((0...size.width).contains(p.x))
    }
    #expect(Snowfall.position(of: f, at: 0, in: size).y == Snowfall.position(of: f, at: 10, in: size).y)
}
```

- [ ] **Step 2: Run** `xcodegen generate` then the test command. Expected: FAIL, "cannot find 'Snowfall' in scope".

- [ ] **Step 3: Implement `Snowfall`.**
  - `position`: progress = `((time / period) + phase).truncatingRemainder(dividingBy: 1)`; y runs from `-size` to `height + size`; x = `x * width + sin(progress * 2π) * drift`, clamped to `0...width`.
  - `body`: if `accessibilityReduceMotion` or scene phase isn't `.active` or `!Festive.shared.isActive`, render nothing. Otherwise `TimelineView(.animation)` + `Canvas` filling circles in `Paper.ink` at opacity 0.12 (light) / 0.25 (dark, via `colorScheme`). `.allowsHitTesting(false)`, `.accessibilityHidden(true)`, `.ignoresSafeArea()`.

- [ ] **Step 4: Put it behind the home content.** At `HomeView.swift:90` change to `.background { ZStack { Paper.background; Snowfall() }.ignoresSafeArea() }` — check `Paper.background` already extended under the safe areas before; keep that behaviour identical.

- [ ] **Step 5: Run the test command.** Expected: all PASS.

- [ ] **Step 6: Manual check** in season on simulator, light and dark: flakes fall slowly behind hero and rows, never drawn over the alarm banner or filled buttons; every control and pull-to-refresh still works; Settings › Accessibility › Reduce Motion on → no flakes; untick Festive theme → flakes and colours gone; Climate/Charging/Settings screens show no snow.

- [ ] **Step 7: Commit**

```bash
git add NotAKey/Home/Snowfall.swift NotAKey/Home/HomeView.swift NotAKeyTests/FestiveTests.swift NotAKey.xcodeproj
git commit -m "feat: light snowfall behind the home screen in festive season"
```
