# Changelog

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
