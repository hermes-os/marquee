# MarqueePatches

Source for Marquee's small MPVKit compatibility shim. Generated frameworks and
historical binary backups stay outside Git.

## Contents

- `standalone-mac-bridge-stub.c` — bridge stub used with MPVKit's macOS build to
  satisfy missing symbols for the standalone (non-iOS) target.

## Why it lives here

`Vendor/MPVKit-local/` and `MarqueePatches/Libmpv.xcframework/` are gitignored
because generated dependency binaries require exact corresponding source,
build flags, and third-party notices before redistribution.

## Restore procedure

After preparing an MPVKit source checkout under `Vendor/MPVKit-local/`, copy the
bridge source into that checkout's local patch area before running its build:

```bash
# From repo root
cp MarqueePatches/standalone-mac-bridge-stub.c \
   Vendor/MPVKit-local/MarqueePatches/
```

Apply the shim through the local MPVKit build in the same place the released
app's build previously injected it, then clean-build in Xcode. Record the exact
MPVKit revision and build flags before distributing any resulting binary.
