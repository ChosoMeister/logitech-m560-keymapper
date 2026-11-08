# M560 Mapper

A macOS menu bar agent for the Logitech M560 on Unifying receiver `046d:c52b`.
It does not send HID++ commands or change the mouse firmware mode. It filters
events by the Logitech receiver's IOKit identity and remaps only M560 buttons:

- Wheel button → a real middle mouse button (press, hold, drag and release)
- Side button near the wheel → Control+Left (previous Space)
- Side button near the palm → Control+Right (next Space)
- Wheel tilt left/right → Command+[ / Command+] (Back / Forward)

## How the wheel button is read

The wheel button does not report as a mouse button through the normal HID
path, and its firmware also emits keyboard chords — left Option with left
Command, and Control+Command+Tab — which is why macOS saw key combinations
instead of a click.

Mapping those chords does not work. Captures showed the firmware sending one
chord, the other, or both, and dropping them entirely on half of all presses,
with nothing marking the button as held.

The button does report itself reliably somewhere else: the receiver's vendor
collection, as a HID++ notification.

    11 01 0a 00 00 af     long report 0x11, device 1, feature index 0x0a,
                          control id 0x00af — button down
    11 01 0a 00 00 00     all diverted buttons up

Four presses gave four clean pairs where the chords gave two. So the helper
reads those reports directly and posts mouse button 2 — `otherMouseDown`,
`otherMouseUp`, and `otherMouseDragged` while held, with click state 1 and no
modifier flags. The edges are real, so holding and middle-dragging work. The
keyboard chords are still suppressed, otherwise Control+Command+Tab would
reach the system as a shortcut.

Only reading is needed. Writing to that collection — which is what diverting a
button normally requires — is refused by macOS with `0xe0005000`, from a shell
and from a signed bundle alike. Logitech's agent carries
`com.apple.developer.hid.virtual.device`, a restricted entitlement only Apple
grants, which a self-signed certificate cannot hold. This button already
reports this way, so no write is necessary.

### Other software on the same mouse

Anything else mapping this button adds a second action to every press:

- **Logi Options+** maps it independently, which closed a second browser tab a
  moment after this helper's click. Quitting from its menu bar icon is not
  enough, because launchd restarts it:

  ```sh
  launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr
  ```

- **LinearMouse** configured with `button 2 → middle click` is mapping the
  event this helper already posts, not anything from the mouse. Remove that
  mapping; without this helper running it has nothing to act on.

## Install

Download `M560Mapper-<version>.zip` from the
[releases](https://github.com/ChosoMeister/logitech-m560-keymapper/releases),
unzip it and move `M560Mapper.app` to `/Applications`.

The app is signed ad-hoc, not with an Apple Developer ID, and is not notarized,
so macOS quarantines it and refuses the first launch. Open it once from the
Finder with right-click → Open and confirm, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/M560Mapper.app
```

Then:

1. Open the app. It appears in the menu bar as a mouse glyph.
2. Grant Accessibility when macOS asks, under System Settings → Privacy &
   Security → Accessibility. The app retries every two seconds, so it starts
   working without being relaunched.
3. Pick your mouse from **Mouse** in the panel. Only that device's buttons are
   touched; everything else passes through untouched.
4. Turn on **Launch at login** if you want it to start with macOS.

### Does it work with other mice?

It was written for the Logitech M560 on a Unifying receiver, and that is the
default selection, but nothing is hardcoded to it. Any mouse whose extra
buttons arrive as HID++ notifications on a vendor collection should work once
selected. To see what is attached:

```sh
/Applications/M560Mapper.app/Contents/MacOS/M560Mapper --devices
```

A device listed without a vendor collection has no channel for these reports,
so the middle-click mapping will have nothing to read.

## Build and run

```sh
./build.sh --install
```

```sh
open /Applications/M560Mapper.app
```

`--install` copies the bundle to `/Applications`, which is where a login-item
agent belongs. The Accessibility grant follows the signing certificate rather
than the path, so moving the app does not disturb it.

The build produces `M560Mapper.app`, a background agent with no Dock icon. It
appears in the menu bar as a mouse glyph. Clicking it opens a Liquid Glass
panel with:

- a master on/off switch that starts and stops the event tap live
- individual switches for middle click, Space switching and tilt navigation
- **Launch at login**, registered through `SMAppService`
- Quit

macOS asks for Accessibility permission the first time the mapper is enabled.
Grant it under System Settings → Privacy & Security → Accessibility.

The app retries the tap every two seconds while it is switched on, so it picks
the grant up on its own without being quit and reopened.

## Signing

TCC binds an Accessibility grant to the signing identity. Ad-hoc signing has no
identity beyond the binary's cdhash, so every rebuild voided the grant. The
build therefore signs with a local self-signed certificate, which keeps one
identity across rebuilds:

```
designated => identifier "com.mustafa.m560mapper" and certificate leaf = H"..."
```

Create it once, then rebuild and grant Accessibility a final time:

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 \
	-nodes -subj "/CN=M560Mapper Self-Signed" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning"
```

```sh
openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:m560 \
	-name "M560Mapper Self-Signed" \
	-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
```

```sh
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P m560 -T /usr/bin/codesign
```

```sh
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
```

Delete `key.pem` and `id.p12` afterwards; the private key lives in the keychain.
Apple's keychain import rejects modern PKCS#12 encryption, which is why the
legacy `-certpbe`/`-keypbe`/`-macalg` flags are needed. Without this identity
the build falls back to ad-hoc and says so.

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
