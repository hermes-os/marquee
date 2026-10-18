READ ~/.agents/AGENTS.md BEFORE ANYTHING (skip if missing).

# Marquee

Marquee is a home-theater app for a private local movie and TV library:
offline-first, remote-first, ten-foot UI. The product is v3: C++23, Qt 6/QML,
libmpv, SQLite, built with CMake and Ninja for Omarchy/Arch Linux.

The Swift v2 macOS app (`Marquee/`, `MarqueePatches/`, `Marquee.xcodeproj`,
`Package.swift`, and the Xcode/Mac scripts in `scripts/`) is a frozen read-only
behavior oracle. No fixes, builds, tests, or Mac gates; read it to match
appearance and interaction. One exception: the public 2.0.2 macOS download is
built on GitHub's macOS runners (`.github/workflows/`); changes that build
needs are allowed, product behavior changes are not. Do not mix in the separate
streaming-platform checkout.

## Gate

```bash
./scripts/configure-v3-debug.sh       # once, and after CMake changes
cmake --build build/v3-debug
ctest --test-dir build/v3-debug --output-on-failure
docs-list --check "$PWD" && agent-repo-check --repo "$PWD" && git diff --check
```

Docs-only changes run only the last line. `docs/QUALITY_GATES.md` maps each
area to its CTest targets. A skipped test is not a pass: the offscreen platform
cannot render libmpv or the OpenGL focus ring, so `tst_playback` render cases
skip without a display-backed session. Display, remote, audio, and hardware-decode
claims need the theater host (`docs/RUNTIME_SMOKE_TEST.md`).

## Invariants

- C++ owns behavior and state, QML presentation only, libmpv playback, SQLite
  durable data. QML never touches the filesystem, SQL, filename parsing, catalog
  identity, watch progress, or libmpv lifecycle.
- One logical focus authority per surface; the viewport follows focus, never the
  reverse. Motion uses `Theme` tokens and honors `SettingsStore.reduceMotion`
  with the same focus-derived final target.
- QML behavior tests load the shipped `Marquee` module, never a replica scene.
- Local sidecar artwork is authoritative; online metadata is optional and never
  blocks browsing.
- A missing, unreadable, or partially scanned root never deletes catalog rows.
  Catalog migrations are forward-only and transactional; never edit a shipped one.
- One libmpv handle per playback session, one normal backend. Stop, failure,
  reload, and shutdown leave one known state and no `marquee`, `mpv`, `ffmpeg`,
  or `ffprobe` process behind.
- Tests use Qt test paths (`AppPaths::setRuntimeRoot`, `--test-mode`) and
  synthetic media, never the live catalog or theater library.
- No credentials in source, logs, settings, the catalog, or diagnostics.
- This repository is public. Every file, test fixture and commit message is
  published: never write credentials, people's names, email addresses, host or
  device names, IP addresses, or real home or media paths. Use example values
  (`/Volumes/FixtureDisk`, `/home/alex/Videos`). The history from before the
  public root commit is kept private and is never pushed here
  (`docs/operations/source-publication.md`). Binary publishing is disabled
  (same doc). There is no package or deploy artifact yet (`issues.md`).

## Where things are

- `docs/ARCHITECTURE_V3.md`: v3 design, product contract, acceptance bar.
- `docs/ARCHITECTURE.md`, `docs/ARCHITECTURE_DECISIONS.md`: the frozen Swift app.
- `issues.md`: open bugs and gaps. `CHANGELOG.md`: user-facing changes.

## Delivery
Work on `main`. Contributors commit; a reviewer reads the commits before they
land; only the maintainer pushes, tags releases, and packages or deploys when a
path exists.
