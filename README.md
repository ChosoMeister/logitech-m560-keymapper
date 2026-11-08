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
instead of a click. Captures showed it uses two, and uses them erratically:

- left Option and left Command pressed together, with no key event at all
- Control+Command+Tab

Neither is an edge of the button. Some presses send only the first, some only
the second, and some send both with the second 320-480ms behind. Each one is
suppressed and emits a complete middle click — `otherMouseDown` then
`otherMouseUp` 20ms later, button 2, click state 1, no modifier flags — and a
500ms window collapses the presses that send both.

The active app receives what a physical three-button mouse sends, so its own
middle-click behavior applies: closing a tab, opening a link in a background
tab, panning in a 3D app.

### What this cannot do

Deliberate taps land 540ms or more apart and paired chords 320-480ms apart.
Those ranges nearly touch, so a very fast double tap can be read as a single
press. Holding is worse: the firmware sends nothing that marks the button as
still down, so a hold cannot be told from a tap, and middle-drag is not
available.

The clean fix is HID++: ask the device over the receiver's vendor collection
to divert the wheel button, so it reports a raw notification with real press
and release edges instead of a keyboard chord. That is not possible here.
macOS refuses output reports to that collection (`0xe0005000`) from an
ordinary app, whatever the signature; Logitech's own agent carries
`com.apple.developer.hid.virtual.device`, a restricted entitlement that only
Apple can grant and that a self-signed certificate cannot hold.

### Logi Options+

If Logi Options+ is running it maps the same wheel press independently, which
closes a second tab a moment after this helper's click. Quit it, or clear its
mapping for that button. Quitting from its menu bar icon is not enough,
because launchd restarts it:

```sh
launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr
```

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
