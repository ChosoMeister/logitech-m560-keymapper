# M560 Mapper

A small macOS-only helper for the Logitech M560 on Unifying receiver `046d:c52b`.
It does not send HID++ commands or change the mouse firmware mode. It filters
keyboard events by the Logitech receiver's IOKit identity and remaps only the
M560 side buttons:

- M560 side button near the wheel (right Command) → Control+Left (previous Space)
- M560 side button near the palm (Command+D) → Control+Right (next Space)
Wheel tilt left/right are translated to Command+[ / Command+] so apps such as
Safari and Finder can use their native Back/Forward shortcuts. These tilt
events can lack a direct HID sender on macOS, so the helper uses the last
attributed pointer device and fails open when that source was not the M560.

Build and run from Terminal:

```sh
swiftc -framework AppKit -framework CoreGraphics -framework IOKit -framework CoreFoundation main.swift -o M560Mapper
./M560Mapper
```

macOS may ask for Accessibility and Input Monitoring permission for the app
that launches it. The helper runs in the foreground; Control-C stops it. It
does not install a login item or modify system settings.

This receiver currently has only the M560 paired. If another device is paired
to this same receiver later, its events may share the receiver identity and
should be checked before using this helper in that configuration.
