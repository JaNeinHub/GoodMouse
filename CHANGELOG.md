# Changelog

## 2.8 (2026-11-23): first release on GitHub
- Not signed with a Developer ID yet; see the note in the README on how to open it.
- Dock move: windows on a hidden desktop of the other screen (e.g. behind a full-screen app) are pulled over too, quietly: the other screen keeps showing what it showed, nothing slides.
- If the screen you move a window to shows a full-screen app, it now switches to the moved window instead of leaving it hidden behind.
- 2.7, shared privately, did the same by sliding the other screen to the window and back; that way and its "Switch back" setting are gone.

## 2.6 (2026-11-15)
- Prepared for publishing under the GPL-3.0.
- Universal app: runs natively on Apple Silicon and Intel Macs.
- New app ID `io.github.janeinhub.GoodMouse`. Settings from earlier builds are taken over on first launch; an old copy that is still running or starts later is quit, so two copies never reverse the wheel twice.
- Internal self-test mode removed.

## Before 2.6
Private builds shared with friends. Highlights of that period:
- **2.5:** app rules also match an app's file name, for apps that ship without a name or bundle ID (e.g. Victoria 3 → `victoria3`).
- **2.4:** autoscroll keeps scrolling the page it started on when the pointer moves over the toolbar, into another frame or out of the window.
- **2.0 – 2.3:** quick panel under the menu bar icon, separate Advanced options window, option to hide the menu bar icon.
- **1.8:** per-app switch for Shift + wheel (games).
- **1.3:** move an app's windows to this screen from the Dock; finer tracking speed.
- **1.2:** per-app rules (smooth / classic / off, zoom on/off); zoom trigger can be any modifier combination.
- **1.1:** app picker, tracking speed slider, middle-click on links in Chrome, zoom with a key + wheel.
- **1.0:** wheel reversal for the mouse only, Windows-style smooth scrolling, bounce filter, autoscroll, back/forward buttons.
