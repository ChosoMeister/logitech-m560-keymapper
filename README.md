# M560 Mapper

A macOS menu bar agent for the Logitech M560 on Unifying receiver `046d:c52b`.
It does not send HID++ commands or change the mouse firmware mode. It filters
events by the Logitech receiver's IOKit identity and remaps only M560 buttons:

- Wheel button → a real middle mouse button (press, hold, drag and release)
- Side button near the wheel → Control+Left (previous Space)
- Side button near the palm → Control+Right (next Space)
- Wheel tilt left/right → Command+[ / Command+] (Back / Forward)

## Why the wheel button needs translating

On this mouse the wheel button does not report a mouse button at all. Its
firmware sends a keyboard chord, which is why macOS sees a key combination
instead of a click. A read-only capture showed it uses two of them:

- left Option and left Command pressed together, with no key event at all
- Control+Command+Tab

The helper recognizes both coming from the Logitech receiver, suppresses their
key and modifier events, and emits mouse button 2 events in their place:

- chord pressed → `otherMouseDown`, button 2, click state 1, no modifier flags
- pointer moves while held → `otherMouseDragged`, so middle-drag and autoscroll work
- chord released (or Command/Control released) → `otherMouseUp`

The active app receives the same event stream as a physical three-button mouse,
so its own middle-click behavior applies — closing a tab, opening a link in a
background tab, pasting the X11 selection, panning in a 3D app, and so on.
Because the button is held rather than clicked-and-released instantly, gestures
that depend on holding the middle button work too.

## Build and run

```sh
./build.sh
```

```sh
open M560Mapper.app
```

The build produces `M560Mapper.app`, a background agent with no Dock icon. It
appears in the menu bar as a mouse glyph. Clicking it opens a Liquid Glass
panel with:

- a master on/off switch that starts and stops the event tap live
- individual switches for middle click, Space switching and tilt navigation
- **Launch at login**, registered through `SMAppService`
- Quit

macOS asks for Accessibility permission the first time the mapper is enabled.
Grant it under System Settings → Privacy & Security → Accessibility.

The build is ad-hoc signed, and TCC binds an ad-hoc grant to the binary's
cdhash, so **every rebuild voids the Accessibility grant**. After rebuilding,
remove the old M560Mapper entry with `−` and let the app's own prompt register
the new binary; re-ticking the stale entry grants nothing. The app only tries
to create its tap at launch, so quit and reopen it once the grant is in place.

## Log

The app writes `~/Library/Logs/M560Mapper.log`, created `0600` and truncated
past 256KB. It records the tap's lifecycle and each mapping decision, none of
which carries key information.

The tap sees every key the machine types, so raw per-event detail, including
key codes, is written only when tracing is switched on explicitly:

```sh
defaults write com.mustafa.m560mapper trace -bool YES
```

## Command line modes

```sh
./M560Mapper.app/Contents/MacOS/M560Mapper --diagnose
```

```sh
./M560Mapper.app/Contents/MacOS/M560Mapper --headless --trace
```

`--diagnose` prints every eligible event read-only without remapping anything,
which is how the wheel chord above was identified. `--headless` runs the mapper
with no menu bar item. `--check-permissions` prints the Accessibility status
and exits.

## Notes

Wheel tilt events can lack a direct HID sender on macOS, so the helper uses the
last attributed pointer device and fails open when that source was not the
M560. This receiver currently has only the M560 paired; if another device is
paired to the same receiver later, its events share the receiver identity and
should be checked before using this helper in that configuration.
