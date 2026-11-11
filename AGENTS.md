READ ~/.agents/AGENTS.md BEFORE ANYTHING (skip if missing).

# Marquee

Marquee is a home-theater app for a private local movie and TV library: offline-first, remote-first, ten-foot UI. The product is v3: C++23, Qt 6/QML, libmpv, SQLite, built with CMake and Ninja for Omarchy/Arch Linux.

The Swift v2 macOS app (`Marquee/`, `MarqueePatches/`, `Marquee.xcodeproj`, `Package.swift`, and the Xcode scripts in `scripts/`) is the reference for how Marquee looks and behaves. v3 clones it faithfully in the new stack; read it to match appearance and interaction, and do not change it. One exception: the public 2.0.2 macOS download is built on GitHub's macOS runners (`.github/workflows/`); changes that build needs are fine, behavior changes are not.

## Architecture
- C++ owns behavior and state. QML is presentation only: it never touches the filesystem, SQL, filename parsing, catalog identity, watch progress or the libmpv lifecycle.
- One focus authority per surface; the viewport follows focus, never the reverse. Motion uses `Theme` tokens and honors `SettingsStore.reduceMotion`.
- One libmpv handle per playback session. Stop, failure, reload and shutdown leave one known state and no `marquee`, `mpv`, `ffmpeg` or `ffprobe` process behind.
- Local sidecar artwork wins; online metadata is optional and never blocks browsing.
- A missing or partly scanned library root never deletes catalog rows. Catalog migrations are forward-only and transactional; never edit a shipped one.
- QML behavior tests load the shipped `Marquee` module, never a copy. Tests use `AppPaths::setRuntimeRoot`, `--test-mode` and synthetic media, never the real library.

## This repository is public
Every file, fixture and commit message is published. Never write credentials, people's names, email addresses, host or device names, IP addresses, or real home or media paths; use example values such as `/home/alex/Videos`. The history before the public root commit stays private (`docs/operations/source-publication.md`). Upstream copyright lines in `THIRD_PARTY_LICENSES.md` are the one exception: licences require them verbatim.

## Gate
```bash
./scripts/configure-v3-debug.sh       # once, and after CMake changes
cmake --build build/v3-debug
ctest --test-dir build/v3-debug --output-on-failure
docs-list --check "$PWD" && agent-repo-check --repo "$PWD" && git diff --check
```
`docs/QUALITY_GATES.md` maps each area to its tests. A skipped test is not a pass: offscreen runs cannot render libmpv or the focus ring, so display, remote, audio and hardware-decode claims need the theater host (`docs/RUNTIME_SMOKE_TEST.md`).

Design: `docs/ARCHITECTURE_V3.md`.
