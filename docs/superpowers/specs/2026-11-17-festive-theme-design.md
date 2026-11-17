# Festive theme — design

Approved 2026-11-17.

## Intent

A seasonal Christmas touch for NotAKey that fits the restrained "Paper" look. Sam handed the design over ("you design it"); everything below is Claude's call, approved as a whole.

## Goals

- Neutral colours shift to a warm, wintry palette over the festive season, automatically.
- Light, sparse snowfall on the home screen.
- Users can turn it off, or on early.

## Non-goals

- No alternate app icon, festive copy, or theme picker.
- No snow on Climate, Charging, Settings, Onboarding or Driving screens.

## Anti-goals

- Never recolour anything that signals car state: `ink`, `secondary`, `nearby`, `onNearby`, `alarm*`, `onAlarm*`, `warning*`, `danger`, `stale*`, `disabled*`, `outline`, `bannerSecondary`. Red/green decoration must not blur "car nearby" or "danger".
- Snow must never cover or intercept taps on controls, and must not run with Reduce Motion on or while backgrounded.

## Approaches considered

- **A. Palette only** — cheapest; too subtle to notice.
- **B. Palette + home-screen snow + off switch** — chosen. Visible, contained, and cheap, because every screen already reads colours from `Paper`.
- **C. Theme picker + alternate icon** — needs new icon art and a theme-switching flow; too much for a seasonal touch.

## Design

**Season window:** 1 December to 6 January inclusive, local calendar, any year (it spans New Year).

**Setting:** new "Appearance" section in `SettingsView` with a "Festive theme" checkbox (existing `CheckboxToggleStyle`), subtitle "On by itself from 1 December to Twelfth Night". Always shown. *Changed 2026-11-17 at Sam's request ("I want to be able to turn it on now"): originally season-only.*

- Untouched: follows the season window.
- Unticked: stays off.
- Ticked early (or during the season): on immediately, until that season ends (after 6 January), then back to following the season. *Claude's call: so an early "on" can't leave the app festive all year.*

Stored in `UserDefaults`: `notakey.festiveTheme` (Bool, absent = follow season) and `notakey.festiveThemeChosenAt` (Date).

**Active** = the checkbox's value.

**Palette when active** (only these four tokens change):

| Token | Light | Dark |
|---|---|---|
| `background` | `F6F1E7` | `0F1A14` |
| `card` | `ECE4D4` | `17241C` |
| `rule` | `E3D9C6` | `1F2E25` |
| `warningCard` | unchanged | unchanged |

*Claude's call: `card` values were derived to sit between background and rule, as the current palette does.*

**Snow:** new view on the home screen, layered behind the scroll content (background layer), `allowsHitTesting(false)`. About 30 flakes, 2–4 pt circles, ink at ~12% opacity in light and ~25% in dark, slow fall (8–14 s top to bottom) with slight horizontal drift. Drawn with `TimelineView` + `Canvas`. Hidden when `accessibilityReduceMotion` is on; stops when the scene isn't active.

**Code shape:** `Paper` decides seasonal colours itself, so the screens using `Paper.background`/`card`/`rule` need no edits. Changing the setting must update the open UI immediately (not only after relaunch). How to achieve that is left to the plan.

## Left to the builder

- Mechanism for live update of `Paper` colours when the setting toggles.
- Exact flake motion maths, as long as it meets the above.
- Test approach for the season window (inject the date).
