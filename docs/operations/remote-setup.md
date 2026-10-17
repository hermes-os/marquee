---
summary: Reference for the retired macOS theater host's Hammerspoon remote bridge; the Omarchy remote input path is not defined yet.
read_when:
  - Looking up how the retired macOS theater host translated its remote into Marquee keyboard events.
  - Defining the Omarchy remote input path and comparing it with the key map this bridge produced.
---

# Remote Setup

**Status: retired reference.** This describes the macOS theater host that ran the
Swift v2 app. Marquee v3 on Omarchy does not use Hammerspoon, and
`scripts/hammerspoon/` is unmaintained. v3 starts with keyboard and media-key
events; whether the theater remote needs a lower-level integration is an open
question tracked in `issues.md`. Nothing below is a v3 setup step.

Marquee's physical remote bridge was host-local. Shared behavior lives in
`scripts/hammerspoon/init.lua`; local network configuration stayed outside Git.

## Hardware prerequisites

- Pair the Satechi R2 as `Satechi BT Media Remote` in **System Preferences →
  Bluetooth**, and leave its side slider in **Media** mode for Marquee control.
- Keep the Mac and Roku TV on the same LAN. On the TV, set **Settings → System
  → Advanced system settings → Control by mobile apps → Network access** to
  **Default** or **Permissive** so Roku ECP keypress requests are accepted.
- Leave the R2 mic/mouse button unbound. On this theater setup it can disconnect
  and reconnect the TV display instead of producing an application-control key.

## Install

1. Install a Monterey-compatible Hammerspoon build on the theater Mac and grant
   the Accessibility permission it requests. The current host uses 1.0.0;
   verify macOS 12 support before upgrading it.
2. Copy `scripts/hammerspoon/config.example.lua` to
   `~/.hammerspoon/marquee-remote.local.lua`, set the Roku's fallback LAN
   address, and keep that local file out of Git. The fallback may be omitted
   when SSDP discovery is reliable.
3. Load `scripts/hammerspoon/init.lua` from the user's Hammerspoon
   configuration, either by requiring it or by making the local `init.lua` a
   symlink to the repository file.
4. Reload Hammerspoon and confirm its console reports the Marquee bindings.
5. Launch Marquee and verify Direction, Select, Menu/Back, and Play/Pause before
   attempting the full traversal checklist.

## Maintenance

Keep action-to-key translation in the repository script and app behavior in
Marquee's remote-input/focus components. Do not duplicate focus policy in
Hammerspoon. If the physical device emits different events, adapt only the
host-facing translation.

## Troubleshooting

- If Roku `/query/device-info` responds but `/keypress/...` returns HTTP 403,
  recheck the TV's **Network access** setting above.
- If the R2 stops responding, re-pair it, confirm **Media** mode, verify
  Hammerspoon Accessibility permission, and check for macOS secure input.
- If the TV display disconnects after a remote press, leave the mic/mouse button
  unbound and avoid it during playback; that behavior occurs below Marquee's
  input layer.
