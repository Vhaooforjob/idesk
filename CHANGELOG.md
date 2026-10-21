# Changelog

## v1.2.1 — 2026-10-21

- Restore the native macOS menu bar foreground for the iDesk icon and desktop name, fixing black text on a light-text menu bar introduced in v1.2.0.
- Keep custom desktop icons on the menu bar and custom colors inside the desktop menu, line, search and banner.
- Cut long desktop names in the menu bar to 24 characters; the tooltip and VoiceOver now give the full name.
- Keep an unreadable `settings.json` as `settings.json.bak` instead of overwriting your desktop names.
- Report a desktop switch that never arrives, with the likely cause.
- Stop re-reading desktops every two seconds while the screens sleep.
- Accept `-`, `` ` ``, arrow, Tab and Return keys in shortcuts, and reject shortcuts macOS uses to switch desktops.
- Save desktop previews in the background.

## v1.2.0 — 2026-10-20

- Add desktop search (⌃⌥S) and previous-desktop switching (⌃⌥P), tracked per display.
- Add Move without Follow and keyboard destination selection to the window picker.
- Record shortcuts directly and report invalid, duplicate or unavailable combinations.
- Personalize desktop colors and icons across the line, menu, search and banner.
- Show preview capture times, refresh current previews, clear the cache and support memory-only storage.
- Add built-in and saved workspace presets for appearance, line visibility and screen arrangements; preserve display confirmation and recovery.
- Localize new controls in English and Vietnamese.

## v1.1.2 — 2026-10-15

- Restore disabled screens before system sleep and retry on wake, including when the external-only screen was unplugged while asleep.
- Pause automatic layout changes while screens sleep and briefly after wake, preserving the external-only preference for reconnection.

## v1.1.1 — 2026-10-14

- Replace continuous pointer polling with mouse events and one-shot hover timers.
- Capture desktop previews on demand instead of every 20 seconds, coalesce repeated captures, and capture multiple displays independently.
- Pause Settings preview animation when its window is hidden or covered; pause idle animation when screens sleep or Reduce Motion is enabled.
- Lower idle animation to 15 FPS in Low Power Mode and stop unused wind and display-recovery timers.
- Keep automatic screen recovery active when iDesk has disabled a display.

## v1.1.0 — 2026-10-11

- Add a searchable window picker, opened with `⌃⌥M`, to move an application window to another desktop and follow it.
- Move windows from the menu bar and Desktop Line, with support for the window's current desktop as the source.
- Group menu options under **Desktop Actions** and **Appearance**.
- Restore the main display when an external-only setup loses its screen, and restore that external-only setup when the same display reconnects.
- Add recovery checks for partially failed display changes and verify window moves before switching desktops.
