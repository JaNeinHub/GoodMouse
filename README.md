# GoodMouse

A small menu bar app that makes a normal mouse feel right on macOS: Windows-style smooth scrolling, a reversed wheel that leaves the trackpad alone, middle-click autoscroll, working back/forward buttons and a few more things macOS doesn't do on its own.

Free and open source (GPL-3.0). macOS 13 Ventura or newer, Apple Silicon and Intel.

## Features

- **Reverse the wheel for the mouse only.** The trackpad keeps natural scrolling.
- **Smooth scrolling like on Windows.** Every notch scrolls a fixed distance with a short glide. No fake trackpad gestures and no momentum, so pages don't suddenly jump.
- **Bounce filter.** Many mouse wheels sometimes send a single tick in the wrong direction. GoodMouse drops it.
- **Middle-click autoscroll.** Click to toggle, or hold and drag. The speed depends on how far the pointer is from where you clicked, and the page you started on keeps scrolling even if the pointer moves onto the toolbar or out of the window. Middle-click on links still opens them in a new tab.
- **Side buttons for back and forward.** Works in Safari, Finder and other Apple apps, Firefox and others, with any keyboard layout. A switch swaps the two buttons if your mouse reports them the other way round.
- **Zoom with a key + wheel** (off by default). Pick any modifier combination; one zoom step per notch, like Ctrl + wheel on Windows. The key + middle click resets to 100 %.
- **Finer tracking speed** than the slider in System Settings.
- **Move an app to this screen from the Dock.** Middle-click a running app's Dock icon (or click it while holding a modifier combination, default ⌃⌥) and its windows move to the display under the pointer. This also works for windows hidden on another desktop of the other screen, e.g. behind a full-screen app: the window comes over without that screen switching away from what it shows.
- **App rules.** Per app: smooth, classic (plain notches) or off, zoom allowed or not, and whether Shift + wheel scrolls sideways (turn that off for games where Shift does something else).

Trackpads, the Magic Mouse and mice with their own smooth scrolling driver (e.g. Logi Options+) are left alone.

## Install

> **Not signed yet:** current releases are not signed with an Apple Developer ID or notarized, so macOS blocks the first launch ("Apple could not verify…"). Open it anyway once: try to open GoodMouse, then go to System Settings → Privacy & Security, scroll down and click **Open Anyway**. Also, until releases are signed, macOS forgets the Accessibility permission with every update; turn GoodMouse on there again after updating. Signed releases are planned.

1. Download `GoodMouse-<version>.zip` from the [latest release](https://github.com/JaNeinHub/GoodMouse/releases/latest) and unzip it.
2. Move **GoodMouse.app** into your **Applications** folder and open it.
3. macOS asks for **Accessibility** access. Open System Settings → Privacy & Security → Accessibility and turn on GoodMouse. GoodMouse starts working within a few seconds; no restart needed.
4. The mouse icon in the menu bar opens the settings. Turn on **Launch at login** there if you want.

Accessibility access is what lets GoodMouse see and change wheel and button events. Without it, GoodMouse does nothing.

### Updating from a build before 2.6

Builds before 2.6 were shared privately under a different app ID. 2.6 takes over your settings automatically. After installing it:

- Turn on GoodMouse under Accessibility again (and remove the old entry with "–").
- Turn on **Launch at login** again in GoodMouse.
- Delete the old copy of GoodMouse. If an old copy starts anyway, 2.6 quits it, so the two never run at the same time.

## Uninstall

Quit GoodMouse (menu bar icon → Quit), then move it to the Trash. Optionally remove it from the Accessibility list and delete its settings with `defaults delete io.github.janeinhub.GoodMouse`.

## Privacy

GoodMouse has no network code. It collects nothing and sends nothing. Settings stay in your user preferences.

Its event handling only ever sees the wheel and the middle/side buttons. Pointer movement, left and right clicks and the keyboard never pass through it. Two exceptions, both only while they are needed: left/right clicks and Esc while autoscroll is running (to stop it), and modifier keys while the Dock modifier-click is turned on.

## Known limits

- **Chrome and other Chromium browsers:** a middle click on a tab starts autoscroll instead of closing the tab, because these browsers don't tell macOS where their tabs are. Links work everywhere.
- **Dock move:** a window on a hidden desktop can be pulled over quietly once GoodMouse has seen it, i.e. once its app was in front while GoodMouse was running. For a window that has been hidden since before GoodMouse started, GoodMouse searches for up to 1.5 s; if it can't find it, the click acts like a normal Dock click (macOS switches to that desktop), and from then on the window is known. Windows of full-screen apps stay where they are.
- **Zoom** uses the app's own zoom steps (⌘+ / ⌘−), so it can't glide.

## Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`); Xcode itself is not required.

```sh
git clone https://github.com/JaNeinHub/GoodMouse.git
cd GoodMouse
./build-app.sh
```

The app is written to `dist/GoodMouse <version>/GoodMouse.app` (universal, ad-hoc signed). A self-built copy works the same, but macOS asks for Accessibility access again after every rebuild, because ad-hoc signatures change with each build.

Quit a running GoodMouse before you replace or rebuild it. An app that holds an active event tap and disappears from disk can leave macOS rejecting input until you log out. GoodMouse guards against this (it quits itself when its app file changes), and `build-app.sh` quits a running copy first, but it's safest not to rely on that.

## Credits

The navigation swipe for the back/forward buttons and the list of apps that need it follow [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT license). Reaching windows on hidden desktops follows [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0).

## License

GoodMouse is licensed under the [GNU General Public License v3.0](LICENSE).
